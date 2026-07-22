class_name WoodPile
extends Node3D
## Solid fuel bed for the campfire: the logs that feed the Fire-X gas solver.
##
## Fire-X (Wrede et al., SIGGRAPH Asia 2025) only models the gas phase — its
## scenes are driven by a grid emitter that injects a fuel mass fraction out of
## nowhere (Tab. 3, "Grid Emitter Parameter"). A camp fire is not fed by a gas
## line, so this class supplies what the paper leaves out: the solid that
## produces the gas. Everything here is NON-PAPER.
##
## One log is a lumped solid with a surface that pyrolyses:
##
##   1. FLAME HEATS THE SURFACE. The gas temperature around the log comes back
##      from the GPU (FireGpuSolver's per-log probes, reduced in fire_display),
##      so the coupling is to the flame the solver actually produced. The net
##      flux is radiative plus convective, scaled by a view factor — a log sees
##      the flame over a fraction of its hemisphere, not from every direction,
##      and dropping that factor puts 250 kW/m^2 on a stick sitting next to a
##      1500 K plume, an order of magnitude past what a real fire delivers.
##   2. THE SURFACE HEATS UP. Only a thin layer takes part: wood conducts badly
##      (alpha ~ 1.5e-7 m^2/s, so the thermal wave reaches ~5 mm in 100 s) and
##      lumping the whole log's mass into the capacity makes it take ten minutes
##      to reach pyrolysis.
##   3. IT GASIFIES, FLUX LIMITED. At the pyrolysis onset the surface pins there
##      — the endothermic gasification holds it — and the whole net flux goes
##      into volatiles, mdot = A.q_net/dH_g (Tewarson's heat of gasification).
##      Deliberately NOT a lumped Arrhenius law: A.exp(-Ea/RT) over a whole log
##      is 0.03 1/s at 700 K and 0.5 1/s at 800 K, i.e. it detonates the log over
##      a 100 K change, because real wood is heat-transfer limited at the surface
##      and not kinetics limited. The flux form is also what makes "more wood =
##      more fire" fall out as a sum over exposed AREA rather than as a fudge.
##   4. VOLATILES GONE, CHAR GLOWS. Char oxidises heterogeneously at the surface,
##      so it releases heat with no gas-phase flame: the log stops emitting fuel
##      and only holds its cells hot (the pilot).  Then ash: nothing.
##
## The mesh never changes size at any stage — the fire consumes the wood, it does
## not shrink it. Only the albedo (fresh -> charcoal) and the emission (ember
## glow) move.

## Fire-X's grid emitter is a gas one, so the volatiles have to be handed over as
## a fuel mass fraction. Wood volatiles are a CO/CH4/tar mix and methane is the
## usual surrogate, which is why the campfire pins the solver to methane.
const FUEL_INDEX_METHANE := 1

const RHO_WOOD := 500.0 ## Softwood, dry [kg/m^3]
const C_WOOD := 1600.0 ## [J/(kg.K)]
## Depth of the thermally active layer [m]; see the header, step 2. Wood's
## thermal wave (alpha ~ 1.5e-7 m^2/s) reaches ~6 mm in the first four minutes,
## and this is what sets how long a log thrown on a burning bed takes to catch:
## the flux ceiling over this capacity is ~17 K/s, so ~18 s from cold.
const THERMAL_DEPTH := 0.006
## Fraction of the hemisphere above the log surface that the flame fills.
const VIEW_FACTOR := 0.15
const EMISSIVITY := 0.9
const SIGMA_SB := 5.67e-8
## Convective coefficient against the hot gas [W/(m^2.K)].
const H_CONV := 15.0
## Flame heat flux saturates, which stops the feedback loop (hotter flame -> more
## volatiles -> hotter flame) from running away. This is the term that actually
## sets the burning rate: the probe feeding it is the PEAK gas temperature in the
## emitter sphere, i.e. the flame core at 2000-2900 K, so the radiative term is
## always far past the ceiling and the view factor never gets a say. 40 kW/m^2 is
## what a free-burning wood surface receives back from its own flame (the 80 of a
## large pool fire put the bed at 500 kW, five times a camp fire, with a flame
## that left the top of the screen).
const MAX_FLUX := 4.0e4
## Effective heat of gasification of wood [J/kg] (Tewarson, 3.7-6.7 for wood
## products). NOT the 1.8e6 of dry pyrolysis alone: what the surface flux has to
## pay for is also driving the moisture off and heating the char layer the
## volatiles pass through. At 1.8e6 the bed releases 22 g/(m^2.s), against the
## 5-11 a free-burning wood surface actually loses.
const DH_GAS := 4.5e6
## Lower heating value of wood volatiles [J/kg]. They leave the log as a
## CO/CH4/tar mix at ~16 MJ/kg, while the solver burns them as methane at
## 52 MJ/kg, so the release has to be handed over as the METHANE-EQUIVALENT mass
## that carries the same energy — a third of it. Passing the volatile mass
## straight through put the bed three times over its real heat release, and the
## fuel-rich core that came with it burned where it finally met air, metres up:
## a gas jet, not a camp fire.
const HC_VOLATILES := 16.0e6
## Surface temperature the pyrolysis front pins at [K].
const T_PYROLYSIS := 600.0
## Glowing combustion consumes char at a few g/(m^2.s).
const CHAR_FLUX := 0.004
## Char surface temperature when glowing hard [K].
const T_GLOW := 1150.0
## How fast the char layer reaches its glowing temperature once the log is
## burning, and how slowly it gives that heat up afterwards [s].
##
## The gap between the two is what makes a wood fire recover from a lull. The
## solver's flame puff-cycles hard (see FireGpuSolver's emitter notes), and a
## char layer that followed the flux instantaneously fed that straight back:
## flame dips -> release stops -> nothing holds the bed hot -> the fire dies with
## 15 kg of wood still in it, measured, inside 30 s. A real bed of embers holds
## its heat for many minutes and is what relights the volatiles, which is exactly
## what the slow side of this models.
const TAU_CHAR_HEAT := 5.0
const TAU_CHAR_COOL := 15.0
## Char stops glowing and the log goes to ash below this [K].
const T_CHAR_OUT := 700.0
## The pilot is handed to the grid at this same temperature, and raising it does
## NOT make the bed relight, which is worth recording because the Arrhenius
## argument says it should: the rate at the char's 1150 K is exp(-15097/1150) =
## 2.0e-6 and loses to the ~86 K/s radiative loss there, while Fire-X runs its own
## grid emitter at 1500 K (Tab. 3) where the rate is 22x higher. Handing the pilot
## over at 1500 K instead measured WORSE — peak gas 2911 K -> 1626 K, reaction
## 3.15 -> 0.18, fuel fraction 9e-5 -> 3e-5 — because the buoyancy the hotter
## pilot adds sweeps the volatiles out of the emitter sphere and the turbulent
## mixing dilutes them below flammability before they can react. The bed not
## relighting is a mixing problem, not a temperature one.
## Density of the mixture the volatiles are released into [kg/m^3], used to turn
## a release in kg/s into the mass fraction per second the grid emitter takes.
##
## Air at the pyrolysis front temperature (~600 K): the emitter DISPLACES the
## local mixture (see add_fuel in fire_inject.comp), and what the volatiles are
## released into is the boundary layer at the log surface — neither the flame
## core (0.3 kg/m^3) nor entrained ambient air (1.18).
##
## The reading matters, because it is the whole conversion from kg/s to the
## solver's mass fraction. Measured against the calibrated gas burner, which
## settles at ~200-400 mol/(m^3.s): 0.3 puts the bed five times over it (peak
## 1900, temperature pinned on its 3000 K clamp, and a fuel-rich backlog still
## burning fifteen seconds after the last log was spent), while 1.18 starves it
## (~80, and the flame blows out inside 30 s with 15 kg of wood still in the bed).
const RHO_EMIT := 0.6

const COLOR_FRESH := Color(0.22, 0.12, 0.06)
const COLOR_CHAR := Color(0.045, 0.04, 0.038)
const COLOR_EMBER := Color(1.0, 0.32, 0.05)

## Radius of each log's grid emitter [m]. Kept at least two cells wide by the
## controller, or a coarse grid misses the sphere entirely.
var emit_radius := 0.45
## Volatile mass a fresh log carries [kg]: 75 % of the log's own mass, which for
## the default 0.09 x 0.85 m softwood cylinder is 8 of its 10.8 kg. The front
## reaches 7.4 cm into a 9 cm radius over that, so the log really is spent by the
## end rather than stopping at a scaled-down shell. A six-log bed then holds
## ~48 kg and burns for the ~50 minutes a real load of wood lasts, at the
## measured 8.9 g/(m^2.s) — which is the free-burning rate, so nothing here is
## time-scaled and the flame size stays the physical one.
var log_fuel := 8.0

var _logs: Array[Dictionary] = []
var _mesh: CylinderMesh
var _stacked_log_count := 0
var _stack_base_top_y := 0.0

const STACK_SLOTS := [
	Vector2(-0.16, 0.0), Vector2(0.16, 0.0), Vector2(0.0, 0.16)]


## Add a log lying on its side, [param yaw] radians around Y, tilted by
## [param tilt] radians so a pile reads as a heap rather than a stack.
func add_log(pos: Vector3, yaw: float, tilt := 0.0, radius := 0.09,
		length := 0.85) -> void:
	if _logs.size() >= FireGpuSolver.MAX_LOGS:
		return

	if _mesh == null:
		_mesh = CylinderMesh.new()
		_mesh.radial_segments = 8
		_mesh.rings = 1

	var mesh_instance := MeshInstance3D.new()
	var log_mesh: CylinderMesh = _mesh.duplicate()
	log_mesh.top_radius = radius
	log_mesh.bottom_radius = radius * 1.15
	log_mesh.height = length
	mesh_instance.mesh = log_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR_FRESH
	mat.roughness = 0.92
	mat.emission_enabled = true
	mat.emission = COLOR_EMBER
	mat.emission_energy_multiplier = 0.0
	mesh_instance.material_override = mat

	# The cylinder's own axis is Y, so it is laid down before it is spun.
	mesh_instance.transform = Transform3D(
		Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, PI * 0.5 + tilt), pos)
	add_child(mesh_instance)

	# Only the upper half of the lateral surface faces the flame, plus the two
	# ends, which is what sets how much gas the log can release.
	var area := PI * radius * length + 2.0 * PI * radius * radius
	_logs.append({
		"node": mesh_instance,
		"mat": mat,
		"pos": pos,
		"radius": radius,
		"length": length,
		"tilt": tilt,
		"area": area,
		"t_solid": 300.0,
		"t_char": 300.0,
		"m_volatile": log_fuel,
		"m_volatile_max": log_fuel,
		"m_char": log_fuel * 0.25,
		"m_ash": 0.0,
		"rate": 0.0,
		"pilot": 0.0,
	})


func log_ground_center_y(tilt := 0.0, radius := 0.09, length := 0.85) -> float:
	return _log_vertical_extent(radius, length, tilt)


func add_log_on_pile(yaw: float, tilt := 0.0, radius := 0.09,
		length := 0.85) -> void:
	if _logs.size() >= FireGpuSolver.MAX_LOGS:
		return
	if _stacked_log_count == 0:
		_stack_base_top_y = _pile_top_y()

	var slot := _stacked_log_count % STACK_SLOTS.size()
	var layer := _stacked_log_count / STACK_SLOTS.size()
	var offset: Vector2 = STACK_SLOTS[slot]
	if layer % 2 == 1:
		offset = Vector2(-offset.y, offset.x)
	var center_y := _stack_base_top_y + layer * radius * 2.3 \
		+ _log_vertical_extent(radius, length, tilt)
	add_log(Vector3(offset.x, center_y, offset.y), yaw, tilt, radius, length)
	_stacked_log_count += 1


func _pile_top_y() -> float:
	var top := 0.0
	for entry in _logs:
		top = maxf(top, float(entry["pos"].y) + _log_vertical_extent(
			float(entry["radius"]), float(entry["length"]), float(entry["tilt"])))
	return top


func _log_vertical_extent(radius: float, length: float, tilt: float) -> float:
	return length * 0.5 * absf(sin(tilt)) + radius * 1.15 * absf(cos(tilt))


## Light whatever lies under the match: brings nearby surfaces straight to the
## pyrolysis onset instead of waiting out the ~80 s a cold log needs to conduct
## its way there. This is the kindling a real fire is started with.
func ignite_at(pos: Vector3, radius: float) -> void:
	for entry in _logs:
		if entry["pos"].distance_to(pos) <= radius and entry["m_volatile"] > 0.0:
			entry["t_solid"] = maxf(entry["t_solid"], T_PYROLYSIS)
			# The kindling is already burning: start the char glowing so the pilot
			# and the flame holder (fire_combustion) are live from the first frame.
			# Without this the fire took ~12 s to build from a cold char and was no
			# fun to watch; the fuel cap in fire_inject means a hot start still
			# cannot flash into a jet. This is the "embers already hot" assumption.
			entry["t_char"] = maxf(entry["t_char"], T_GLOW)
			entry["pilot"] = entry["t_char"]


func clear() -> void:
	for entry in _logs:
		entry["node"].queue_free()
	_logs.clear()
	_stacked_log_count = 0
	_stack_base_top_y = 0.0


func log_count() -> int:
	return _logs.size()


func is_full() -> bool:
	return _logs.size() >= FireGpuSolver.MAX_LOGS


func total_fuel() -> float:
	var total := 0.0
	for entry in _logs:
		total += entry["m_volatile"]
	return total


func initial_fuel() -> float:
	var total := 0.0
	for entry in _logs:
		total += entry["m_volatile_max"]
	return total


func burning_count() -> int:
	var count := 0
	for entry in _logs:
		if entry["rate"] > 0.0:
			count += 1
	return count


## Hottest char layer in the bed [K]: what is actually glowing, and the thing
## that keeps the volatiles lighting between the flame's puffs.
func hottest_surface() -> float:
	var hottest := 0.0
	for entry in _logs:
		hottest = maxf(hottest, entry["t_char"])
	return hottest


## Advance every log by [param delta], driven by the per-log gas temperatures the
## solver probed last frame (kelvins, indexed the same way [method emitters] is).
func update(delta: float, gas_temperatures: PackedFloat32Array,
		ambient := 300.0) -> void:
	for i in _logs.size():
		var entry: Dictionary = _logs[i]
		var t_gas := ambient
		if i < gas_temperatures.size():
			t_gas = maxf(gas_temperatures[i], ambient)
		_step_log(entry, delta, t_gas, ambient)
		_update_look(entry)


func _step_log(entry: Dictionary, delta: float, t_gas: float, ambient: float) -> void:
	var t_s: float = entry["t_solid"]
	var area: float = entry["area"]
	# Net flux onto the surface: radiation through the view factor, plus
	# convection from the gas moving past it. Negative once the log is hotter
	# than its surroundings, which is what cools a spent log back down.
	var q := VIEW_FACTOR * EMISSIVITY * SIGMA_SB * (pow(t_gas, 4.0) - pow(t_s, 4.0)) \
		+ H_CONV * (t_gas - t_s)
	q = minf(q, MAX_FLUX)

	# Thermal capacity of the layer that actually takes part, not of the log.
	var capacity := RHO_WOOD * area * THERMAL_DEPTH * C_WOOD

	entry["rate"] = 0.0
	## Whether the surface is burning at all this step, either phase: it is what
	## the char layer heats on.
	var alight := false

	if entry["m_volatile"] > 0.0:
		if t_s < T_PYROLYSIS:
			t_s = minf(t_s + q * area / capacity * delta, T_PYROLYSIS)
		else:
			# Pinned at the front temperature: everything arriving goes into
			# gasification rather than into sensible heat.
			t_s = T_PYROLYSIS
			var mdot := area * maxf(q, 0.0) / DH_GAS
			if mdot > 0.0:
				entry["m_volatile"] = maxf(entry["m_volatile"] - mdot * delta, 0.0)
				entry["rate"] = _mass_flow_to_fraction(mdot)
				alight = true
			else:
				# Starved of heat: the front cools off the pinned temperature.
				t_s += q * area / capacity * delta
	elif entry["m_char"] > 0.0:
		# Glowing combustion: heat and no flame, so no fuel goes to the grid, and
		# the char layer is what carries the log from here on.
		if float(entry["t_char"]) > T_CHAR_OUT:
			entry["m_char"] = maxf(entry["m_char"] - area * CHAR_FLUX * delta, 0.0)
			alight = true
		t_s += q * area / capacity * delta
	else:
		entry["m_ash"] = 1.0
		t_s += q * area / capacity * delta

	# The char layer: quick to light, slow to let go. Once the log is out it
	# settles back onto whatever the gas around it is doing, which is how the
	# water eventually kills a bed of embers rather than merely steaming on it.
	var t_char: float = entry["t_char"]
	if alight:
		t_char = lerpf(t_char, T_GLOW, 1.0 - exp(-delta / TAU_CHAR_HEAT))
	else:
		# Capped at the glowing temperature either way: a char surface sitting in
		# a 2900 K flame does not itself reach 2900 K, and letting it try turned
		# the pilot into a heat source hotter than the fire it came from.
		t_char = lerpf(t_char, minf(t_gas, T_GLOW), 1.0 - exp(-delta / TAU_CHAR_COOL))
	entry["t_char"] = t_char
	entry["pilot"] = t_char if t_char > T_CHAR_OUT else 0.0

	entry["t_solid"] = clampf(t_s, ambient, 2000.0)


## GAME LOOK, NOT PHYSICS: the physical pyrolysis flux gives a tiny flame (the
## bed injects ~60x less fuel than the gas burner, so react peaks ~0.3 against the
## burner's ~20). A campfire is supposed to have a body of flame that wraps the
## logs, so the grid injection is boosted well past the real release. This only
## scales what the flame LOOKS like — it is applied to the emitter rate alone, not
## to the volatile mass the log loses (that stays on the physical mdot), so a
## bigger flame does not burn the wood away any faster. Raise for a taller/wider
## flame; the per-cell fuel cap in fire_inject keeps it from becoming a gas jet.
const FLAME_BOOST := 80.0


## Release in kg/s -> the fuel mass fraction per second the grid emitter injects,
## spread over the emitter sphere's worth of hot gas, and converted to the
## methane mass that carries the same energy as those volatiles.
func _mass_flow_to_fraction(mdot: float) -> float:
	var fuel: Dictionary = FireGpuSolver.FUELS[FUEL_INDEX_METHANE]
	var hc_methane: float = -float(fuel["dch"]) / float(fuel["m_f"])
	var volume := 4.0 / 3.0 * PI * pow(emit_radius, 3.0)
	return FLAME_BOOST * mdot * HC_VOLATILES / hc_methane / maxf(RHO_EMIT * volume, 1e-4)


## Char progress darkens the log and the pilot lights it from within. Size never
## changes: the fire consumes the wood, it does not shrink it.
func _update_look(entry: Dictionary) -> void:
	var mat: StandardMaterial3D = entry["mat"]
	var charred: float = 1.0 - float(entry["m_volatile"]) / maxf(entry["m_volatile_max"], 1e-4)
	mat.albedo_color = COLOR_FRESH.lerp(COLOR_CHAR, clampf(charred, 0.0, 1.0))
	# Glow tracks the surface temperature over the band where charcoal visibly
	# goes from dull red to bright orange.
	var glow := clampf((float(entry["t_char"]) - 700.0) / (T_GLOW - 700.0), 0.0, 1.0)
	mat.emission_energy_multiplier = glow * 1.4


## The table the solver uploads: one emitter (and one temperature probe) per log,
## including the cold and spent ones — a log with no slot has no probe, and with
## no probe it can never be heated in the first place.
func emitters() -> Array:
	var out := []
	for entry in _logs:
		out.append({
			"pos": entry["pos"],
			"radius": emit_radius,
			"rate": entry["rate"],
			"pilot": entry["pilot"],
		})
	return out
