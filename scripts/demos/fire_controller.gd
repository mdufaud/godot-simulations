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
var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar

var solver: FireGpuSolver
var water: FireWater
var volume_material: ShaderMaterial
var volume_texture: Texture3DRD
var texture_bound := false

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

# --- Interaction state ---
var is_adding_water := false
var is_smothering := false
var water_position := Vector3(0, 0.5, 0)

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

	# P3: water droplets (stub for now)
	water = FireWater.new()
	RenderingServer.call_on_render_thread(water.init_render.bind(solver.grid_dims, solver.cell_size))

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
	if is_adding_water:
		solver.push_event(FireGpuSolver.EVENT_WATER, water_position, 1.5, 2.0 * sim_dt)
	if is_smothering:
		solver.push_event(FireGpuSolver.EVENT_SMOTHER, Vector3.ZERO, 2.0, 20.0 * sim_dt)

	# P3: water particle↔grid coupling. Algorithm 1 puts the scatter and the gather
	# both ahead of the grid loop (lines 13-14) so the solver reads the liquid field
	# built this frame, and the return after it (lines 23-24).
	if water.initialized:
		RenderingServer.call_on_render_thread(water.step_droplets.bind(delta))
		RenderingServer.call_on_render_thread(water.scatter_render)
		RenderingServer.call_on_render_thread(water.gather_render.bind(
			solver.get_texture_rid("liquid_scal"),
			solver.get_texture_rid("liquid_vel")))

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))

	if water.initialized:
		RenderingServer.call_on_render_thread(water.return_render)

	var stats := solver.get_stats()
	_update_light(stats)
	_update_ui_stats(stats)
	if spark_particles:
		spark_particles.emitting = stats["max_reaction"] > 0.1



func _exit_tree() -> void:
	if volume_texture != null:
		volume_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
	RenderingServer.call_on_render_thread(water.free_render)


# =========================================================================
#  SCENE SETUP
# =========================================================================

func _light_fire() -> void:
	solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4)
	# P3: spawn test droplets above the fire. Queued rather than called, because
	# init_render is itself queued — calling directly would run against a
	# FireWater that has not allocated its buffers yet and spawn nothing.
	RenderingServer.call_on_render_thread(
		water.spawn_droplets.bind(100, Vector3(0, 2.0, 0), 0.5))


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

	stats_label.text = "T max: %d K | reaction %.2f mol/(m³·s)" % [
		int(max_temp), stats["total_reaction"]]

	# Mass-fraction closure: a running check that species transport conserves
	# mass. Drifts away from 1.0 only if a product coefficient is off default.
	# Timings are empty unless profiling is on, so the readout disappears with the
	# toggle instead of freezing on the last profiled frame.
	var timings := solver.get_timings()
	var probe_text := "ΣY = %.4f" % stats["mass_fraction_sum"]
	if water.mass_measured_once:
		probe_text += " | Σm_p err %.5f%%" % (water.mass_error * 100.0)
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
	timing_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	menu.add_button("Ignite", func() -> void:
		solver.push_event(FireGpuSolver.EVENT_IGNITE, Vector3(0, 0.5, 0), 1.0, 0.4))
	menu.add_toggle("Wind", false, func(on: bool) -> void:
		_wind_enabled = on
		_apply_wind())
	menu.add_toggle("Extinguish", false, func(on: bool) -> void:
		is_adding_water = on)
	menu.add_toggle("Smother", false, func(on: bool) -> void:
		is_smothering = on)
	menu.add_toggle("GPU profiling", false, func(on: bool) -> void:
		solver.profiling = on)

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

