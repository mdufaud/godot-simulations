extends Node3D
## Fire Demo Controller — Fire-X combustion, volumetrically raymarched.

const FireWater = preload("res://scripts/fire/fire_water.gd")
##
## The solver lives entirely in RenderingDevice textures (see FireGpuSolver);
## this node queues grid emitters, binds the display volume to the shader and
## drives the light and UI from the solver's reduced stats.
##
## Fire-X: Wrede et al., ACM TOG 44(6) art. 268 (SIGGRAPH Asia 2025).

# --- Node references ---
@onready var fire_volume: MeshInstance3D = $FireVolume
@onready var spark_particles: GPUParticles3D = $SparkParticles
@onready var fire_light: OmniLight3D = $FireLight
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu

var stats_label: Label
var probe_label: Label
var timing_label: Label
var debug_info := false
var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar

var solver: FireGpuSolver
var water: FireWater
var volume_material: ShaderMaterial
var volume_texture: Texture3DRD
var texture_bound := false

var droplet_mesh: MultiMesh
var droplet_material: ShaderMaterial
var droplet_texture: Texture2DRD

# --- Quality presets ---
## Physical extent of the simulated box, held constant across presets so the
## flame keeps the same size on screen and only the resolution moves.
## The walls used to cut through the camp: the seat logs sit at r ~ 3.2 m and the
## boulders at r ~ 5-6 m, both outside the old 6.4 m box, and the smoke visibly
## piled up against a 9.6 m ceiling. Doubled on every axis so the plume leaves the
## domain through open air rather than through a wall.
const DOMAIN_SIZE := Vector3(12.8, 19.2, 12.8)
## Cell size per preset. Tab. 3 allows 0.1-10.0 m, and 0.1 is the flame fidelity
## the domain was sized around; the coarser two exist because the domain grew 8x
## in volume at fixed cell size.
##
## Cost is cubic in the inverse: doubling the cell is 8x fewer cells for ~8x less
## GPU time, and the Jacobi pressure loop alone is half of it.
const QUALITY_CELLS := [0.4, 0.2, 0.1]
const QUALITY_NAMES := ["Low (32x48x32)", "Medium (64x96x64)", "High (128x192x128)"]

# --- Grid emitter (Fire-X Tab. 3 "Grid Emitter Parameter") ---
var emitter_position := Vector3(0, 0.3, 0)
var emitter_radius := 0.8
## Fuel mass fraction injected per simulated second (NON-PAPER: Tab. 3 gives an
## emitter mass fraction, not a rate). A diffusion flame is mixing limited, so
## this has to stay below what the entrained oxygen can burn — flooding the
## domain with fuel gives a fuel-rich core that just accumulates heat.
##
## PROVISIONAL. Chosen so the burner-region fuel peaks near stoichiometric
## propane (Y_fuel = 0.06); measured peak 0.052. The flame still puff-cycles with
## a large amplitude at every rate tried (0.2-0.5), because oxygen entrainment is
## limited by a pressure projection whose gradient is not the adjoint of its
## divergence. Retune after the MAC rewrite, not before.
var emitter_rate := 0.2

# --- Water nozzle (Fire-X Fig. 8) ---
## The paper finds the spray aimed at the flame base is what stops the fire, so all
## three intensity presets aim there and vary how much water arrives per second.
## Each level sets the SPH emitter's frequency, velocity and spray cone; more water
## means a wider, faster, denser stream.
var jet_enabled := false
const JET_NOZZLE_POS := Vector3(4.5, 5.0, 0.0)
const JET_AIM_BASE := Vector3(0.0, 0.35, 0.0)
# Frequency is particles/second, so it doubles as how dense the stream looks; the
# heavier presets run past Tab. 3's 100 Hz cap (game feel over the paper's nozzle)
# to build a visible torrent rather than a dotted line.
const WATER_PRESETS := {
	1: {"freq": 30.0, "vel": 3.5, "spray": 8.0},    # Light  — trickle, hisses, survives
	2: {"freq": 90.0, "vel": 6.0, "spray": 25.0},   # Medium — big steam, strong knockdown
	3: {"freq": 170.0, "vel": 8.5, "spray": 40.0},  # Heavy  — torrent
}
var _water_level := 0
var _water_buttons := {}

# --- Interaction state ---
## A human click is far shorter than the flame's fuel residence time, so a
## one-shot ignite burns out before it is seen. The toggle keeps depositing fuel
## and pilot heat every frame while it is on.
var is_igniting := false
var is_smothering := false

## The toggle gates the sliders rather than writing the wind itself, so turning
## it off stays off no matter where the sliders sit.
var _wind_enabled := false
var _wind_vector := Vector3(2.0, 0.0, 0.5)


func _apply_wind() -> void:
	solver.wind = _wind_vector if _wind_enabled else Vector3.ZERO


func _ready() -> void:
	solver = FireGpuSolver.new()
	volume_material = fire_volume.material_override as ShaderMaterial
	if volume_material:
		volume_material.set_shader_parameter("box_size",
			Vector3(solver.grid_dims) * solver.cell_size)
		# The volume stores temperature normalised against these, so the shader
		# needs them to turn the red channel back into kelvins.
		volume_material.set_shader_parameter("ambient_temperature", solver.ambient_temperature)
		volume_material.set_shader_parameter("display_temperature", solver.display_temperature)

	RenderingServer.call_on_render_thread(solver.init_render)

	# P3/P4: SPH water droplets and their coupling to the grid. More particles than
	# the coupling strictly needs, so a held jet builds a connected sheet of water
	# rather than a scatter of beads once the blob shader merges them.
	water = FireWater.new()
	water.particle_count = 4096
	water.evaporation_active = solver.evaporation_enabled
	RenderingServer.call_on_render_thread(water.init_render.bind(solver.grid_dims, solver.cell_size))

	_setup_droplet_render()
	_light_fire()
	_setup_ui()

	orbit_cam.target = Vector3(0, 3.5, 0)
	orbit_cam.distance = 15.0
	orbit_cam.pitch = -10.0
	orbit_cam.yaw = 30.0
	orbit_cam.min_distance = 5.0
	# The plume now has 19.2 m of headroom, so the whole column has to fit in
	# frame at full zoom out.
	orbit_cam.max_distance = 40.0


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		volume_texture = Texture3DRD.new()
		volume_texture.texture_rd_rid = solver.get_display_tex_rid()
		if volume_material:
			volume_material.set_shader_parameter("volume_tex", volume_texture)
		texture_bound = true

	# Rates are per simulated second, so they must follow the solver's clock and
	# not the frame delta — see FireGpuSolver.sim_delta.
	var sim_dt := solver.sim_delta(delta)
	solver.push_event(FireGpuSolver.EVENT_FUEL, emitter_position,
		emitter_radius, emitter_rate * sim_dt)
	if is_igniting:
		solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0),
			1.0, 2.0 * sim_dt)
	if is_smothering:
		solver.push_event(FireGpuSolver.EVENT_SMOTHER, Vector3.ZERO, 2.0, 20.0 * sim_dt)

	# P3: water particle↔grid coupling. Algorithm 1 puts the scatter and the gather
	# both ahead of the grid loop (lines 13-14) so the solver reads the liquid field
	# built this frame, and the return after it (lines 23-24).
	if water.initialized:
		if jet_enabled:
			# Simulated time, not frame time: emitting per wall-clock second makes
			# the droplet count a function of the frame rate, and two runs of the
			# same nozzle then disagree by a couple of hundred kelvin.
			RenderingServer.call_on_render_thread(water.emit_jet.bind(sim_dt))
		RenderingServer.call_on_render_thread(water.step_droplets.bind(delta))
		RenderingServer.call_on_render_thread(water.scatter_render)
		RenderingServer.call_on_render_thread(water.gather_render.bind(
			solver.get_texture_rid("liquid_scal"),
			solver.get_texture_rid("liquid_vel")))

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))

	if water.initialized:
		RenderingServer.call_on_render_thread(water.return_render)

	if water.initialized:
		if droplet_texture == null:
			droplet_texture = Texture2DRD.new()
			droplet_texture.texture_rd_rid = water.sph_position_tex_rid()
			droplet_material.set_shader_parameter("position_tex", droplet_texture)
		droplet_mesh.visible_instance_count = water.particles_active

	var stats := solver.get_stats()
	_update_light(stats)
	_update_ui_stats(stats)
	if spark_particles:
		spark_particles.emitting = stats["max_reaction"] > 0.1



func _exit_tree() -> void:
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	# Same reason: free_render drops the SPH position texture, and a material left
	# pointing at it makes the renderer build a uniform set around a dead RID.
	if droplet_texture != null:
		droplet_texture.texture_rd_rid = RID()
	# Water first: its uniform sets bind the solver's liquid textures, and freeing
	# those first makes Godot drop the dependent sets on its own — FireWater then
	# frees RIDs that are already gone ("Attempted to free invalid ID").
	RenderingServer.call_on_render_thread(water.free_render)
	RenderingServer.call_on_render_thread(solver.free_render)


# =========================================================================
#  SCENE SETUP
# =========================================================================

## Sphere impostors over the SPH position texture, one instance per particle.
##
## The texture RID only exists once the queued init_render has run on the render
## thread, so the binding is deferred to _process like the fire volume's is.
## visible_instance_count follows the pour: the solver only writes the active
## slots, and the rest of the texture is whatever was in it before.
func _setup_droplet_render() -> void:
	droplet_material = ShaderMaterial.new()
	droplet_material.shader = load("res://shaders/fire/water_droplet.gdshader")
	droplet_material.set_shader_parameter("tex_width", water.sph_tex_width())
	# Larger than the SPH spacing so neighbouring droplets overlap and the blob
	# shader reads them as one body of water instead of separate spheres.
	droplet_material.set_shader_parameter("particle_radius", 0.13)

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	droplet_mesh = MultiMesh.new()
	droplet_mesh.transform_format = MultiMesh.TRANSFORM_3D
	droplet_mesh.mesh = quad
	droplet_mesh.instance_count = water.particle_count
	droplet_mesh.visible_instance_count = 0
	# The vertex shader takes the position straight from the texture and ignores
	# the instance transform, so every instance carries the same identity matrix.
	var buf := PackedFloat32Array()
	buf.resize(water.particle_count * 12)
	for i in water.particle_count:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	droplet_mesh.buffer = buf

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = droplet_mesh
	mmi.material_override = droplet_material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Instances sit at the origin as far as the culler is concerned, since the
	# real positions only exist on the GPU.
	mmi.custom_aabb = AABB(Vector3(-0.5, 0.0, -0.5) * DOMAIN_SIZE, DOMAIN_SIZE)
	add_child(mmi)


## The three water buttons are a radio group: turning one on selects that intensity
## and clears the others; turning the active one off stops the jet.
func _set_water_level(level: int, on: bool) -> void:
	if not on:
		if _water_level == level:
			jet_enabled = false
			_water_level = 0
		return
	_water_level = level
	jet_enabled = true
	var p: Dictionary = WATER_PRESETS[level]
	water.jet_frequency = p.freq
	water.jet_velocity = p.vel
	water.jet_spray_angle = p.spray
	water.jet_position = JET_NOZZLE_POS
	water.jet_direction = JET_AIM_BASE - JET_NOZZLE_POS
	for lv in _water_buttons:
		if lv != level:
			_water_buttons[lv].set_pressed_no_signal(false)


func _light_fire() -> void:
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)


## The P4 qualitative test: a packet of droplets thrown down onto the flame. The
## whole particle budget goes at once — the SPH solver has no streaming emitter,
## so a second pour replaces the first rather than adding to it.
##
## Queued rather than called, because init_render is itself queued: calling
## directly would run against a FireWater that has not allocated its buffers yet
## and spawn nothing.
func _pour_water() -> void:
	# A bucket of water lobbed onto the fire, not a packed ball dropped straight
	# down: the old version put the whole budget in a 0.4 m sphere, whose SPH
	# pressure detonated it into an explosion. The water now starts off to the side
	# and above, spread over a wide loose volume so the solver does not blow it
	# apart, and is thrown in an arc at the flame base.
	var origin := Vector3(-4.5, 4.5, 0.0)
	var target := Vector3(0.0, 0.5, 0.0)
	var throw := (target - origin).normalized() * 8.0
	RenderingServer.call_on_render_thread(water.spawn_droplets.bind(
		mini(water.particle_count, 1800), origin, 0.9, throw))


## Swap the field resolution without moving the domain walls.
##
## The display texture is freed on the render thread, so the binding is dropped
## and stepping suspended here, on the main thread, before the rebuild is queued.
## [member FireGpuSolver.initialized] comes back true at the end of the rebuild
## and [method _process] picks the new texture up on the next frame.
func _set_quality(index: int) -> void:
	var cell: float = QUALITY_CELLS[index]
	var dims := Vector3i((DOMAIN_SIZE / cell).round())
	if dims == solver.grid_dims:
		return

	solver.initialized = false
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.set_resolution.bind(dims, cell))
	_light_fire()


func _reset_simulation() -> void:
	RenderingServer.call_on_render_thread(solver.clear_fields)
	_smooth_light_energy = 0.0
	_smooth_light_range = 8.0
	_light_fire()


# =========================================================================
#  LIGHT
# =========================================================================

var _smooth_light_energy := 0.0
var _smooth_light_range := 8.0

func _update_light(stats: Dictionary) -> void:
	if not fire_light:
		return

	var dt := get_process_delta_time()
	var light_blend := clampf(3.0 * dt, 0.0, 1.0)

	var temp_norm := clampf(
		(stats["max_temperature"] - solver.ambient_temperature)
			/ (solver.display_temperature - solver.ambient_temperature),
		0.0, 1.0
	)

	_smooth_light_energy = lerpf(_smooth_light_energy, temp_norm * 8.0, light_blend)
	_smooth_light_range = lerpf(_smooth_light_range, 8.0 + temp_norm * 14.0, light_blend)

	fire_light.light_energy = _smooth_light_energy
	fire_light.omni_range = _smooth_light_range

	# Planck-like mapping: dull red embers through to near-white at peak.
	var light_color := Color(1.0, 0.55, 0.15)
	if temp_norm > 0.7:
		light_color = light_color.lerp(Color(1.0, 0.9, 0.7), (temp_norm - 0.7) / 0.3)
	elif temp_norm < 0.3:
		light_color = light_color.lerp(Color(0.8, 0.3, 0.1), 1.0 - temp_norm / 0.3)
	fire_light.light_color = light_color

	var flicker := 1.0 - 0.02 * sin(Time.get_ticks_msec() * 0.01) * cos(Time.get_ticks_msec() * 0.017)
	fire_light.light_energy *= flicker


# =========================================================================
#  UI
# =========================================================================

func _update_ui_stats(stats: Dictionary) -> void:
	var max_temp: float = stats["max_temperature"]
	var temp_norm := (max_temp - solver.ambient_temperature) \
		/ (solver.display_temperature - solver.ambient_temperature)

	if debug_info:
		stats_label.text = "T max: %d K | reaction %.2f mol/(m³·s)" % [
			int(max_temp), stats["total_reaction"]]

		# Mass-fraction closure: a running check that species transport conserves
		# mass. Drifts away from 1.0 only if a product coefficient is off default.
		var timings := solver.get_timings()
		var probe_text := "ΣY = %.4f" % stats["mass_fraction_sum"]
		if water.mass_measured_once:
			probe_text += " | Σm_p %.3f kg" % water.measured_mass
		# The P4 criterion: the energy the gas loses has to be the latent plus
		# sensible heat the liquid gave up, to 1 %. Only shown once there is liquid
		# on the grid, since the ratio is 0/0 in a dry domain.
		if stats["energy_budget"] > 0.0:
			probe_text += " | ΔE err %.3f%%" % (stats["energy_residual"] * 100.0)
		if timings.has("total"):
			probe_text += " | GPU %.2f ms" % timings["total"]
		probe_label.text = probe_text
		timing_label.text = _format_timings(timings)

	fuel_bar.value = stats["avg_fuel"] * 100.0
	oxygen_bar.value = stats["avg_oxygen"] * 100.0
	temp_bar.value = clampf(temp_norm * 100.0, 0.0, 100.0)


## The five costliest stages, so the pressure loop's share of the frame is
## visible before the grid gets any bigger.
func _format_timings(timings: Dictionary) -> String:
	if timings.is_empty():
		return ""
	var rows := []
	for key in timings:
		if key != "total":
			rows.append([key, timings[key]])
	rows.sort_custom(func(a, b): return a[1] > b[1])

	var parts := []
	for i in mini(5, rows.size()):
		parts.append("%s %.1f" % [rows[i][0], rows[i][1]])
	return " · ".join(parts) + " ms"


func _setup_ui() -> void:
	stats_label = menu.add_label("T max: 300 K")
	probe_label = menu.add_label("ΣY = 1.0000")
	timing_label = menu.add_label("")
	# Without this a Label reports its whole line as its minimum width, which
	# widens the panel past its anchored 300 px for as long as the text is set.
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	probe_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	timing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Debug readout is hidden until the Debug info toggle turns it on.
	stats_label.visible = false
	probe_label.visible = false
	timing_label.visible = false
	menu.add_separator()
	fuel_bar = menu.add_progress_bar("Fuel", 100.0)
	oxygen_bar = menu.add_progress_bar("Oxygen", 100.0)
	temp_bar = menu.add_progress_bar("Temperature", 100.0)

	menu.add_separator()
	menu.add_section("Quality")
	menu.add_option_button("Resolution", QUALITY_NAMES,
		QUALITY_CELLS.find(solver.cell_size), _set_quality)

	menu.add_separator()
	menu.add_section("Fuel")
	var fuel_names := []
	for f in FireGpuSolver.FUELS:
		fuel_names.append(f["name"])
	menu.add_option_button("Gas", fuel_names, solver.fuel_index,
		func(idx: int) -> void: solver.fuel_index = idx)
	menu.add_option_button("A units", ["CGS (Westbrook-Dryer)", "SI as printed"],
		solver.units_convention,
		func(idx: int) -> void: solver.units_convention = idx)

	menu.add_separator()
	menu.add_section("Actions")
	menu.add_button("Reset", _reset_simulation)
	menu.add_toggle("Ignite", false, func(on: bool) -> void:
		is_igniting = on)
	for level in [1, 2, 3]:
		var level_name: String = ["Light", "Medium", "Heavy"][level - 1]
		_water_buttons[level] = menu.add_toggle("Water: " + level_name, false,
			func(on: bool) -> void: _set_water_level(level, on))
	menu.add_button("Pour water", _pour_water)
	menu.add_toggle("Wind", false, func(on: bool) -> void:
		_wind_enabled = on
		_apply_wind())
	menu.add_toggle("Smother", false, func(on: bool) -> void:
		is_smothering = on)
	menu.add_toggle("Debug info", false, func(on: bool) -> void:
		debug_info = on
		solver.profiling = on
		stats_label.visible = on
		probe_label.visible = on
		timing_label.visible = on)

	# Ranges below are the paper's own (Fire-X Tab. 3) wherever it gives one.
	menu.add_separator()
	menu.add_section("Combustion")
	menu.add_slider("Heat efficiency φ", 0.0, 1.0, solver.heat_efficiency,
		func(v: float): solver.heat_efficiency = v)
	menu.add_slider("Radiation coeff", 0.0, 6.0, solver.radiation_coefficient,
		func(v: float): solver.radiation_coefficient = v)
	menu.add_slider("CO₂ coeff", 0.0, 10.0, solver.co2_coefficient,
		func(v: float): solver.co2_coefficient = v)
	menu.add_slider("Water vapor coeff", 0.0, 10.0, solver.h2o_coefficient,
		func(v: float): solver.h2o_coefficient = v)
	menu.add_slider("Residual coeff", 0.0, 10.0, solver.residual_coefficient,
		func(v: float): solver.residual_coefficient = v)
	menu.add_slider("Emitter temp (K)", 300.0, 1500.0, solver.emitter_temperature,
		func(v: float): solver.emitter_temperature = v)
	menu.add_slider("Fuel supply", 0.0, 5.0, emitter_rate,
		func(v: float): emitter_rate = v)

	menu.add_separator()
	menu.add_section("Evaporation")
	menu.add_toggle("Evaporation", solver.evaporation_enabled, func(on: bool) -> void:
		solver.evaporation_enabled = on
		water.evaporation_active = on)
	menu.add_slider("Droplet diameter (mm)", 0.5, 5.0,
		solver.droplet_diameter * 1000.0,
		func(v: float): solver.droplet_diameter = v * 0.001)
	# UNDEFINED IN PAPER: Eq. 10's k, read as a heat transfer coefficient.
	menu.add_slider("Droplet heat transfer", 0.0, 500.0, solver.droplet_heat_transfer,
		func(v: float): solver.droplet_heat_transfer = v)
	# NON-PAPER: wet-cell combustion suppression. Below ~20 water makes the fire
	# spread instead of die; see FireGpuSolver.water_suppression.
	menu.add_slider("Water suppression", 0.0, 100.0, solver.water_suppression,
		func(v: float): solver.water_suppression = v)
	# NON-PAPER: how fast a cold puddle drains away so the fire can recover; 0 keeps
	# the old behaviour where water pooled forever and half-smothered the flame.
	menu.add_slider("Water drain (1/s)", 0.0, 1.0, solver.liquid_drain_rate,
		func(v: float): solver.liquid_drain_rate = v)
	# Both ranges are Tab. 3's own for the particle emitter.
	menu.add_slider("Jet velocity (m/s)", 0.0, 10.0, water.jet_velocity,
		func(v: float): water.jet_velocity = v)
	menu.add_slider("Jet frequency (Hz)", 10.0, 100.0, water.jet_frequency,
		func(v: float): water.jet_frequency = v)

	menu.add_separator()
	menu.add_section("Flow")
	menu.add_slider("Vorticity strength", 0.0, 50.0, solver.vorticity_strength,
		func(v: float): solver.vorticity_strength = v)
	menu.add_slider("Buoyancy g", 0.0, 20.0, solver.gravity,
		func(v: float): solver.gravity = v)
	menu.add_slider("Pressure iters", 16.0, 128.0, float(solver.pressure_iterations),
		func(v: float): solver.pressure_iterations = int(v))
	menu.add_slider("Substeps", 1.0, 4.0, float(solver.substeps),
		func(v: float): solver.substeps = int(v))
	menu.add_slider("Wind X", -5.0, 5.0, _wind_vector.x,
		func(v: float):
			_wind_vector.x = v
			_apply_wind())
	menu.add_slider("Wind Z", -5.0, 5.0, _wind_vector.z,
		func(v: float):
			_wind_vector.z = v
			_apply_wind())

	menu.add_separator()
	menu.add_section("Performance")
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v

