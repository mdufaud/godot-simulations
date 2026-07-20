class_name FireGpuSolver
extends RefCounted
## GPU combustion solver implementing Fire-X (Wrede et al., SIGGRAPH Asia 2025,
## ACM TOG 44(6) art. 268), DOI 10.1145/3763338.
##
## Global one-step stoichiometric combustion in real units: mass fractions and
## molar concentrations, Arrhenius kinetics from the paper's Table 1, Boussinesq
## buoyancy, vorticity confinement, MacCormack advection and a Jacobi pressure
## projection. Every physical constant below is traceable to the paper or to the
## reference it cites; anything that is not is marked NON-PAPER.
##
## All methods except [method push_event] and [method get_stats] must run on the
## rendering thread (RenderingDevice is not thread safe).

const SHADER_DIR := "res://shaders/fire/"
const STAGES: Array[String] = [
	"inject", "advect", "maccormack", "forces", "curl", "vorticity", "vortapply",
	"combustion", "diffusion", "divergence", "pressure", "project", "display",
]
## Stages that touch the staggered velocity faces, and so must be dispatched
## over the face grid (dims + 1 on every axis) rather than the cell grid. Each
## one guards its own writes, since the three face textures have different
## extents and none of them fills the dispatch.
const FACE_STAGES := ["inject", "advect", "maccormack", "forces", "vortapply",
	"diffusion", "project"]
## Workgroup is 8x8x4; grid dimensions must stay multiples of these.
const WG := Vector3i(8, 8, 4)
const STATS_WORDS := 9
const CONFIG_VEC4S := 10

enum { EVENT_FUEL = 1, EVENT_IGNITE = 2, EVENT_WATER = 3, EVENT_SMOTHER = 4 }

## Concentration units the Arrhenius pre-exponential factor is expressed in.
## Westbrook & Dryer Tab. I states "Units are cm-sec-mole-kcal-Kelvins", so the
## published A values are CGS. Fire-X reproduces those numbers verbatim while
## its nomenclature gives concentrations in mol/m^3 without mentioning a
## conversion, so both readings are offered and compared.
enum { UNITS_CGS = 0, UNITS_SI_AS_PRINTED = 1 }

# =========================================================================
#  FUEL TABLE — Fire-X Tab. 1, activation energy from Westbrook & Dryer Tab. I
# =========================================================================
# Columns: D_f [m^2/s], A (as printed, CGS), a, b, dcH [J/mol],
#          q_f, q_o, q_CO2, q_H2O, M_f [kg/mol], Cp [J/(kg.K)], k [W/(m.K)]
#
# Every dcH equals -417 kJ/mol x (moles of O2), i.e. Fire-X Eq. 4
# dcH = -417(c + 0.25h - 0.5o), verified against all six rows.
#
# Ea = 30.0 kcal/mol for all six: Westbrook & Dryer Tab. I, corroborated in
# their text ("All of the previous calculations were carried out with
# Ea = 30 kcal/mole"). Their (A, a, b) rows match Fire-X Tab. 1 exactly, so the
# provenance of the Fire-X values is certain.
#
# Cp for acetylene (63) and cyclopropane (114) are printed as such in Fire-X
# Tab. 1 but match neither the mass-specific nor the molar value for those gases
# (the other four rows are correct mass-specific figures). Reproduced verbatim;
# they are only weighted by the fuel mass fraction in the mixture average.
const FUELS: Array[Dictionary] = [
	{"name": "Propane (C3H8)", "d_f": 1.14e-5, "a_factor": 8.60e11, "a": 0.10, "b": 1.65,
		"dch": -2.0850e6, "q": [-1.0, -5.0, 3.0, 4.0], "m_f": 4.410e-2, "cp": 1670.0, "k": 0.016},
	{"name": "Methane (CH4)", "d_f": 2.10e-5, "a_factor": 8.30e5, "a": -0.30, "b": 1.30,
		"dch": -0.8340e6, "q": [-1.0, -2.0, 1.0, 2.0], "m_f": 1.604e-2, "cp": 2230.0, "k": 0.034},
	{"name": "Acetylene (C2H2)", "d_f": 1.46e-5, "a_factor": 6.50e12, "a": 0.50, "b": 1.25,
		"dch": -1.0425e6, "q": [-2.0, -5.0, 4.0, 2.0], "m_f": 2.600e-2, "cp": 63.0, "k": 0.024},
	{"name": "Butane (C4H10)", "d_f": 1.00e-5, "a_factor": 7.40e11, "a": 0.15, "b": 1.60,
		"dch": -2.7105e6, "q": [-2.0, -13.0, 8.0, 10.0], "m_f": 5.812e-2, "cp": 1720.0, "k": 0.015},
	{"name": "Cyclopropane (C3H6)", "d_f": 1.14e-5, "a_factor": 4.20e11, "a": -0.10, "b": 1.85,
		"dch": -1.8765e6, "q": [-2.0, -9.0, 6.0, 6.0], "m_f": 4.200e-2, "cp": 114.0, "k": 0.015},
	{"name": "Ethylene (C2H4)", "d_f": 1.63e-5, "a_factor": 2.00e12, "a": 0.10, "b": 1.65,
		"dch": -1.2510e6, "q": [-1.0, -3.0, 2.0, 2.0], "m_f": 2.805e-2, "cp": 1550.0, "k": 0.019},
]

## Activation energy, Westbrook & Dryer Tab. I (kcal/mol -> J/mol).
const ACTIVATION_ENERGY := 30.0 * 4184.0
const R_GAS := 8.314 ## Fire-X nomenclature
const P_AMBIENT := 101325.0 ## Standard atmosphere

# Molar masses [kg/mol] of the non-fuel species. Their specific heats are
# temperature dependent and live in the shader as NIST-JANAF Shomate fits
# (see fire_common.comp), matching Fire-X Tab. 4's "mixture temperature
# averaged" specification.
const M_O2 := 0.032
const M_CO2 := 0.044
const M_H2O := 0.018
const M_N2 := 0.028

## Air composition by mass, from Fire-X Tab. 4 (21 % O2 / 79 % N2 by volume).
const Y_O2_AIR := 0.233

# =========================================================================
#  CONFIGURABLE PARAMETERS — ranges from Fire-X Tab. 3
# =========================================================================

## 64x96x64. Fire-X Tab. 3 runs 64^3 up to 200x300x400.
##
## The domain is 12.8 x 19.2 x 12.8 m either way; this is the middle of the three
## quality presets in the demo controller. 128x192x128 at 0.1 m is the same box at
## the paper's cell size and works, but costs 86 ms a frame on a Radeon 760M
## against 10 ms here, so it is the High preset rather than the default.
var grid_dims := Vector3i(64, 96, 64)
var cell_size := 0.2 ## Grid length 12.8 x 19.2 x 12.8 m; Tab. 3 allows 0.1-10.0 m

var fuel_index := 0
var units_convention := UNITS_CGS

var ambient_temperature := 300.0 ## Fire-X Tab. 3
var timestep := 1.0 / 120.0 ## Fire-X Tab. 3 "Delta Time"
var substeps := 1 ## Fire-X Tab. 3 "Update Multiplier", range 1-4
var pressure_iterations := 64 ## Fire-X Tab. 3, range 64-128

var radiation_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-6.0
var heat_efficiency := 1.0 ## phi in Eq. 6; Fire-X Tab. 3, range 0.0-1.0
var co2_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var h2o_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var residual_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var temperature_clamp := 3000.0 ## Tab. 3 "Density temperature coupling limit"
var emitter_temperature := 1500.0 ## Tab. 3 grid emitter, range 300-1500 K

var vorticity_strength := 8.0 ## Fire-X Tab. 3, range 0.0-50.0
var vorticity_velocity_lo := 0.0 ## Fire-X Tab. 3, range 0.0-0.1
var vorticity_velocity_hi := 5.0 ## Fire-X Tab. 3, range 0.0-5.0
var vorticity_temperature_lo := 301.0 ## Fire-X Tab. 3

var wind := Vector3.ZERO ## NON-PAPER: inflow boundary condition for the demo
var gravity := 9.81 ## Buoyancy magnitude in Eq. 1
var kinematic_viscosity := 1.5e-5 ## NON-PAPER: air at ambient, Eq. 1 nu
var drag := 0.0 ## NON-PAPER: stability aid, 0 = disabled
var oxygen_replenish := 6.0 ## NON-PAPER: open-boundary inflow rate [1/s]
var residual_dissipation := 0.03 ## NON-PAPER: soot settling in cold cells
var display_temperature := 2600.0 ## Renderer normalisation only
var reaction_reference := 50.0 ## Renderer normalisation only [mol/(m^3.s)]

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := {}
var _stats_buf := RID()
var _config_buf := RID()
var _parity := 0
var _groups := Vector3i.ZERO
var _groups_face := Vector3i.ZERO

var _events: Array[Dictionary] = []
var _events_mutex := Mutex.new()
var _stats := PackedInt64Array()
var _stats_mutex := Mutex.new()
var _stats_pending := false
var _timings := {}
var _timings_mutex := Mutex.new()


func _init() -> void:
	_stats.resize(STATS_WORDS)


func get_display_tex_rid() -> RID:
	return _tex.get("display", RID())


## Field texture by name, for the stages that live outside this class (the liquid
## coupling in FireWater). Invalid until init_render has run on the render thread.
func get_texture_rid(key: String) -> RID:
	return _tex.get(key, RID())


func current_fuel() -> Dictionary:
	return FUELS[clampi(fuel_index, 0, FUELS.size() - 1)]


## Arrhenius pre-exponential factor in the units the shader works in.
##
## Westbrook & Dryer publish A in CGS (mol/cm^3). Converting to SI with
## v_si = 1e6.v_cgs and c_cgs = 1e-6.c_si gives A_si = A_cgs.10^(6(1-a-b)).
## Methane has a+b = 1.0 exactly, so it is unaffected; the other five all have
## a+b = 1.75, a factor of 10^-4.5.
func effective_pre_exponential() -> float:
	var f := current_fuel()
	if units_convention == UNITS_SI_AS_PRINTED:
		return f["a_factor"]
	return f["a_factor"] * pow(10.0, 6.0 * (1.0 - f["a"] - f["b"]))


## Simulated time a frame of length [param delta] will advance.
##
## The solver runs whole steps of [member timestep] rather than stretching dt, so
## simulated time and wall-clock time diverge whenever the frame rate is not
## 120 Hz. Emitters must scale their rate by this, not by the frame delta: doing
## otherwise injects more fuel per simulated second the slower the frame rate
## gets, which floods the burner and starves it of oxygen.
func sim_delta(delta: float) -> float:
	return float(clampi(int(delta / timestep), 1, substeps)) * timestep


## Queue a grid interaction; consumed by the next [method step_render].
## Safe to call from the main thread.
func push_event(mode: int, position: Vector3, radius: float, amount: float) -> void:
	_events_mutex.lock()
	# Bounded: the caller queues one emitter event per frame, so an unconsumed
	# queue means the solver never came up and events would pile up forever.
	if _events.size() < 64:
		_events.append({"mode": mode, "pos": position, "radius": radius, "amount": amount})
	_events_mutex.unlock()


## Last reduced frame. Safe to call from the main thread.
func get_stats() -> Dictionary:
	_stats_mutex.lock()
	var s := _stats.duplicate()
	_stats_mutex.unlock()
	var region := maxf(float(s[5]), 1.0)
	var column := maxf(float(s[7]), 1.0)
	return {
		"max_temperature": float(s[0]),
		"total_reaction": float(s[1]) * 0.001,
		"max_reaction": float(s[2]) * 0.001,
		"avg_fuel": float(s[3]) * 0.001 / region,
		"avg_oxygen": float(s[4]) * 0.001 / region,
		"mass_fraction_sum": float(s[6]) * 0.001 / column,
		# Peak |div u| left over after the projection, in 1/s. The falsifiable
		# check on the staggered discretisation: with the gradient the exact
		# adjoint of the divergence this is the Jacobi residual and nothing else,
		# so it must fall when pressure_iterations rises. A collocated grid leaves
		# a checkerboard the projection cannot see, and the value stalls instead.
		"max_divergence": float(s[8]) * 0.001,
	}


func get_timings() -> Dictionary:
	_timings_mutex.lock()
	var copy := _timings.duplicate()
	_timings_mutex.unlock()
	return copy


# =========================================================================
#  SETUP
# =========================================================================

func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Fire solver needs a RenderingDevice (Forward+ or Mobile renderer).")
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "fire_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "fire_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "fire_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Fire stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	_create_textures()

	var stats_bytes := PackedByteArray()
	stats_bytes.resize(STATS_WORDS * 4)
	_stats_buf = _rd.storage_buffer_create(stats_bytes.size(), stats_bytes)

	var config_bytes := PackedByteArray()
	config_bytes.resize(CONFIG_VEC4S * 16)
	_config_buf = _rd.storage_buffer_create(config_bytes.size(), config_bytes)

	_build_uniform_sets()
	_update_groups()
	_parity = 0
	initialized = true


## Rebuild every field at a new resolution. Rendering thread only.
##
## The domain is [member grid_dims] * [member cell_size], so a caller that wants
## to keep the same box must change both. Shaders, pipelines and the stats/config
## buffers are resolution independent and survive; the fields are cleared, since
## resampling a reacting mixture onto a different grid has no meaning that would
## survive the mass-fraction closure check.
##
## Callers must clear their own references to [method get_display_tex_rid] and
## stop stepping before queueing this — the old textures are freed here.
func set_resolution(dims: Vector3i, cell: float) -> void:
	if _rd == null:
		return
	initialized = false
	for stage in _sets:
		for set_rid in _sets[stage]:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
	_sets.clear()
	for key in _tex:
		if _tex[key].is_valid():
			_rd.free_rid(_tex[key])
	_tex.clear()

	grid_dims = dims
	cell_size = cell
	_create_textures()
	_build_uniform_sets()
	_update_groups()
	_parity = 0
	initialized = true


## Cell dims are multiples of the workgroup, face dims (dims + 1) never are, so
## the face dispatch always overshoots and every face stage bounds-checks its
## own writes.
func _update_groups() -> void:
	_groups = Vector3i(
		ceili(float(grid_dims.x) / WG.x),
		ceili(float(grid_dims.y) / WG.y),
		ceili(float(grid_dims.z) / WG.z))
	_groups_face = Vector3i(
		ceili(float(grid_dims.x + 1) / WG.x),
		ceili(float(grid_dims.y + 1) / WG.y),
		ceili(float(grid_dims.z + 1) / WG.z))


func _create_textures() -> void:
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	var keys_rgba := ["scal_a", "scal_b", "scal2_a", "scal2_b",
		"scal_fwd", "scal2_fwd", "curl"]
	for key in keys_rgba:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, usage, grid_dims),
			RDTextureView.new(), [])

	# Staggered MAC velocity (Fire-X Sec. 5.1, Bridson 2015): one scalar per face
	# centre instead of a vector per cell centre. A u-face sits between cells i-1
	# and i on x, so there is one more of them than there are cells on that axis.
	var face_offsets: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	for axis in 3:
		var face_dims: Vector3i = grid_dims + face_offsets[axis]
		for suffix in ["_a", "_b", "_fwd"]:
			_tex["uvw"[axis] + suffix] = _rd.texture_create(
				_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, face_dims),
				RDTextureView.new(), [])

	for key in ["press_a", "press_b", "diverg"]:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, grid_dims),
			RDTextureView.new(), [])

	# P3: Liquid phase coupling (SPH ↔ fire grid). Eq. 18-25.
	for key in ["liquid_scal", "liquid_vel"]:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, usage, grid_dims),
			RDTextureView.new(), [])

	_tex["display"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, usage, grid_dims),
		RDTextureView.new(), [])

	clear_fields()


func _make_format(format: int, usage: int, dims: Vector3i) -> RDTextureFormat:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = dims.x
	fmt.height = dims.y
	fmt.depth = dims.z
	fmt.format = format
	fmt.usage_bits = usage
	return fmt


## Reset every field to still ambient air. Rendering thread only.
func clear_fields() -> void:
	# texture_clear takes a Color, so a cell's four floats go straight in:
	# scal = (T, Y_fuel, Y_O2, Y_CO2). Nitrogen is implied by the remainder.
	var air := Color(ambient_temperature, 0.0, Y_O2_AIR, 0.0)
	for key in ["scal_a", "scal_b"]:
		_rd.texture_clear(_tex[key], air, 0, 1, 0, 1)
	for key in _zeroed_keys():
		_rd.texture_clear(_tex[key], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_parity = 0


## Every field that starts at zero: still air, no pressure, nothing rendered.
func _zeroed_keys() -> Array:
	var keys := ["scal2_a", "scal2_b", "scal_fwd", "scal2_fwd", "curl",
		"press_a", "press_b", "diverg", "display", "liquid_scal", "liquid_vel"]
	for axis in "uvw":
		for suffix in ["_a", "_b", "_fwd"]:
			keys.append(axis + suffix)
	return keys


func _build_uniform_sets() -> void:
	# One binding layout for every stage (glslang keeps declared-but-unused
	# resources, so the shared header can declare them all). Variant 0/1 swaps
	# whichever pair the stage ping-pongs: the field textures for most stages,
	# the pressure pair for the Jacobi sweep.
	# Keyed by binding rather than by position: bindings 11 and 15 are the storage
	# buffers, so the image bindings are not contiguous and a positional array
	# needs a hole in it.
	var fields := {
		0: "u_a", 1: "u_b", 4: "u_fwd",
		16: "v_a", 17: "v_b", 18: "v_fwd",
		19: "w_a", 20: "w_b", 21: "w_fwd",
		2: "scal_a", 3: "scal_b", 5: "scal_fwd",
		12: "scal2_a", 13: "scal2_b", 14: "scal2_fwd",
		6: "curl", 7: "press_a", 8: "press_b", 9: "diverg", 10: "display",
	}
	var fields_flipped := fields.duplicate()
	for pair in [[0, 1], [16, 17], [19, 20], [2, 3], [12, 13]]:
		_swap_binding(fields_flipped, pair[0], pair[1])

	var pressure_flipped := fields.duplicate()
	_swap_binding(pressure_flipped, 7, 8)

	for stage in STAGES:
		var variants := [fields, pressure_flipped] if stage == "pressure" \
			else [fields, fields_flipped]
		var sets := []
		for variant in 2:
			var uniforms: Array[RDUniform] = []
			var order: Dictionary = variants[variant]
			for binding in order:
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.binding = binding
				u.add_id(_tex[order[binding]])
				uniforms.append(u)
			for pair in [[11, _stats_buf], [15, _config_buf]]:
				var b := RDUniform.new()
				b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				b.binding = pair[0]
				b.add_id(pair[1])
				uniforms.append(b)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_sets[stage] = sets


static func _swap_binding(table: Dictionary, a: int, b: int) -> void:
	var tmp: String = table[a]
	table[a] = table[b]
	table[b] = tmp


# =========================================================================
#  STEP — Fire-X Algorithm 1, lines 16-22
# =========================================================================

func step_render(delta: float) -> void:
	if not initialized:
		return
	_read_timings()
	_fetch_stats()
	_upload_config()

	# The paper fixes dt at 1/120 s with an update multiplier of 1-4; run as
	# many whole steps as the frame covers rather than stretching dt, which
	# would change the physics with the frame rate.
	var count := clampi(int(delta / timestep), 1, substeps)

	_events_mutex.lock()
	var events := _events.duplicate()
	_events.clear()
	_events_mutex.unlock()

	if profiling:
		_rd.capture_timestamp("fire/start")
	var cl := _rd.compute_list_begin()

	for i in count:
		# Events are injected once, on the first substep of the frame.
		if i == 0:
			for e in events:
				_dispatch(cl, "inject", _parity,
					_push_constant(e["mode"], e["pos"], e["radius"], e["amount"]))
		_substep(cl)

	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("fire/end")


func _substep(cl: int) -> void:
	var pc := _push_constant(0, Vector3.ZERO, 1.0, 0.0)
	var p := _parity

	# 16. Advection (MacCormack): src -> dst, then the fields swap roles.
	_dispatch(cl, "advect", p, pc)
	_dispatch(cl, "maccormack", p, pc)
	p = 1 - p

	# 17. Buoyancy (+ vorticity confinement, Tab. 3).
	_dispatch(cl, "forces", p, pc)
	if vorticity_strength > 0.0:
		# Three passes now: the confinement force is a cell-centred quantity but
		# the velocity it corrects lives on faces. Computing it once per cell into
		# a scratch buffer and scattering costs one dispatch; evaluating it again
		# per face would repeat the curl-gradient stencil six times per cell.
		_dispatch(cl, "curl", p, pc)
		_dispatch(cl, "vorticity", p, pc)
		_dispatch(cl, "vortapply", p, pc)

	# 18. Combustion, in place.
	_dispatch(cl, "combustion", p, pc)

	# 19-20. Diffusion + thermal radiation: also a stencil, so it swaps again.
	_dispatch(cl, "diffusion", p, pc)
	p = 1 - p

	# 21 is evaporation (not implemented: needs the SPH liquid phase).
	# 22. Pressure projection.
	_dispatch(cl, "divergence", p, pc)
	var iters := pressure_iterations + (pressure_iterations & 1)
	for i in iters:
		_dispatch(cl, "pressure", i & 1, pc, i == 0)
	_dispatch(cl, "project", p, pc)
	_dispatch(cl, "display", p, pc)

	_parity = p


## Timestamps bracket stages: each mark closes the previous stage's interval, so
## a stage's cost is the gap to the next mark. The Jacobi sweep is marked only on
## its first iteration, which makes the whole loop one interval — 64 separate
## marks would blow past the driver's timestamp query pool.
func _mark(stage: String) -> void:
	if profiling:
		_rd.capture_timestamp("fire/" + stage)


func _dispatch(cl: int, stage: String, variant: int, pc: PackedByteArray, mark := true) -> void:
	if mark:
		_mark(stage)
	var g := _groups_face if stage in FACE_STAGES else _groups
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage][variant], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, g.x, g.y, g.z)
	_rd.compute_list_add_barrier(cl)


func _push_constant(mode: int, pos: Vector3, radius: float, amount: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(64)
	pc.encode_s32(0, grid_dims.x)
	pc.encode_s32(4, grid_dims.y)
	pc.encode_s32(8, grid_dims.z)
	pc.encode_s32(12, mode)
	pc.encode_float(16, cell_size)
	pc.encode_float(20, timestep)
	pc.encode_float(24, 1.0 / cell_size)
	pc.encode_float(28, 0.0)
	pc.encode_float(32, pos.x)
	pc.encode_float(36, pos.y)
	pc.encode_float(40, pos.z)
	pc.encode_float(44, radius)
	pc.encode_float(48, amount)
	pc.encode_float(52, 0.0)
	pc.encode_float(56, 0.0)
	pc.encode_float(60, 0.0)
	return pc


func _upload_config() -> void:
	var f := current_fuel()
	var q: Array = f["q"]
	var v := PackedFloat32Array()
	v.resize(CONFIG_VEC4S * 4)

	# kinetics: A (in shader units), Ea/R [K], a, b
	v[0] = effective_pre_exponential()
	v[1] = ACTIVATION_ENERGY / R_GAS
	v[2] = f["a"]
	v[3] = f["b"]
	# fuel: dcH [J/mol], M_f [kg/mol], Cp, k
	v[4] = f["dch"]
	v[5] = f["m_f"]
	v[6] = f["cp"]
	v[7] = f["k"]
	# stoich: q_f, q_o, q_CO2, q_H2O
	v[8] = q[0]
	v[9] = q[1]
	v[10] = q[2]
	v[11] = q[3]
	# coeffs: D_f, phi, residual, CO2
	v[12] = f["d_f"]
	v[13] = heat_efficiency
	v[14] = residual_coefficient
	v[15] = co2_coefficient
	# thermo: T_amb, radiation coeff, p_amb, T clamp
	v[16] = ambient_temperature
	v[17] = radiation_coefficient
	v[18] = P_AMBIENT
	v[19] = temperature_clamp
	# transport: buoyancy, vorticity, drag, nu
	v[20] = gravity
	v[21] = vorticity_strength
	v[22] = drag
	v[23] = kinematic_viscosity
	# vort thresholds + H2O coefficient
	v[24] = vorticity_velocity_lo
	v[25] = vorticity_velocity_hi
	v[26] = vorticity_temperature_lo
	v[27] = h2o_coefficient
	# wind + residual dissipation
	v[28] = wind.x
	v[29] = wind.y
	v[30] = wind.z
	v[31] = residual_dissipation
	# molar masses
	v[32] = M_O2
	v[33] = M_CO2
	v[34] = M_H2O
	v[35] = M_N2
	# misc: O2 replenish, display T, reaction reference, emitter T
	v[36] = oxygen_replenish
	v[37] = display_temperature
	v[38] = reaction_reference
	v[39] = emitter_temperature

	_rd.buffer_update(_config_buf, 0, v.size() * 4, v.to_byte_array())


# =========================================================================
#  READBACK
# =========================================================================

# Async so the reduction never stalls the render thread; the values lag a frame
# or two, which the light smoothing absorbs anyway.
func _fetch_stats() -> void:
	if _stats_pending or not _stats_buf.is_valid():
		return
	_stats_pending = true
	_rd.buffer_get_data_async(_stats_buf, _on_stats_ready, 0, STATS_WORDS * 4)


func _on_stats_ready(bytes: PackedByteArray) -> void:
	_stats_pending = false
	if bytes.size() < STATS_WORDS * 4:
		return
	_stats_mutex.lock()
	for i in STATS_WORDS:
		_stats[i] = bytes.decode_u32(i * 4)
	_stats_mutex.unlock()


func _read_timings() -> void:
	if not profiling:
		# Stale numbers outlive the toggle otherwise: nothing else ever writes
		# _timings, so the last profiled frame would stay on screen forever.
		if not _timings.is_empty():
			_timings_mutex.lock()
			_timings.clear()
			_timings_mutex.unlock()
		return
	var count := _rd.get_captured_timestamps_count()
	if count < 2:
		return

	var acc := {}
	var start_time := 0
	var prev_name := ""
	var prev_time := 0
	for i in count:
		var nm := _rd.get_captured_timestamp_name(i)
		var t := _rd.get_captured_timestamp_gpu_time(i)
		# A mark closes the interval opened by the previous one. "start" and "end"
		# only bracket the total, so they open no stage of their own.
		if prev_name.begins_with("fire/") and prev_name != "fire/start":
			var key: String = prev_name.substr(5)
			acc[key] = float(acc.get(key, 0.0)) + float(t - prev_time) / 1e6
		if nm == "fire/start":
			start_time = t
		elif nm == "fire/end":
			acc["total"] = float(t - start_time) / 1e6
		prev_name = nm
		prev_time = t

	_timings_mutex.lock()
	_timings = acc
	_timings_mutex.unlock()


func free_render() -> void:
	if _rd == null:
		return
	initialized = false
	for stage in _sets:
		for set_rid in _sets[stage]:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
	_sets.clear()
	for buf in [_stats_buf, _config_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_stats_buf = RID()
	_config_buf = RID()
	for key in _tex:
		if _tex[key].is_valid():
			_rd.free_rid(_tex[key])
	_tex.clear()
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	_pipelines.clear()
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_shaders.clear()
