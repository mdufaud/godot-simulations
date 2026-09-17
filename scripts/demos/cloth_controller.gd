extends Node3D

const REST_SPACING := 0.055
const PRESETS: Array[ClothPreset] = [
	preload("res://resources/cloth/presets/red_flag.tres"),
	preload("res://resources/cloth/presets/blue_flag.tres"),
	preload("res://resources/cloth/presets/gold_flag.tres"),
	preload("res://resources/cloth/presets/linen_a.tres"),
	preload("res://resources/cloth/presets/linen_b.tres"),
	preload("res://resources/cloth/presets/tarp.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var _viewport := ViewportGuard.attach(self)

var wind := ClothWind.new()
var wind_enabled := true
var quality := SimQualityState.new()
## The active tier's values, kept so cloths built after the launch restore
## (or a tier switch) pick the solver fields up.
var _quality_values := {}
var solvers: Array[ClothSolver] = []
var renderers: Array[ClothRenderer] = []
var profiler := SimProfiler.new()
var cloth_menu := ClothMenu.new()
var _time := 0.0
var _step_clock := SimStepClock.new()


func _ready() -> void:
	# No RenderingDevice means every compute dispatch silently no-ops: say so
	# instead of booting into a black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return

	orbit_cam.target = Vector3(0.0, 3.0, 1.0)
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -14.0
	orbit_cam.yaw = 30.0
	orbit_cam.min_distance = 3.0
	orbit_cam.max_distance = 60.0
	quality.setup(ClothQualityProfile, "cloth_quality_profile", _apply_quality)
	quality.restore()
	_build_cloths()
	_apply_solver_quality()
	var props := ClothProps.new()
	add_child(props)
	props.build(PRESETS)
	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(_on_profiler_enabled)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	cloth_menu.build(menu, solvers, {
		wind_enabled = wind_enabled,
		wind_speed = wind.speed,
		gustiness = wind.gustiness,
		turbulence = wind.turbulence,
		wind_wander = wind.wander,
		wind_dir_deg = rad_to_deg(wind.direction_rad),
	}, {
		reset = _restart,
		wind_toggled = _on_wind_toggled,
		unpin = _unpin_all,
		wind_speed = _set_wind_speed,
		gustiness = _set_gustiness,
		turbulence = _set_turbulence,
		wind_wander = _set_wind_wander,
		wind_dir = _set_wind_direction,
		set_drag = _set_drag,
		set_damping = _set_damping,
		set_iterations = _set_iterations,
		set_substeps = _set_substeps,
		set_relaxation = _set_relaxation,
		stretch = _on_stretch,
		bending = _on_bending,
		render_scale = _set_render_scale,
		initial_render_scale = _viewport.render_scale(),
		quality = quality,
	}, profiler)
	_init_solvers()
	cloth_menu.update_status(solvers)


func _build_cloths() -> void:
	var surface_shader: Shader = load("res://shaders/cloth/cloth_surface.gdshader")
	for index in PRESETS.size():
		var preset := PRESETS[index]
		var error := preset.validate()
		if error != "":
			push_error("Cloth preset '%s': %s" % [preset.display_name, error])
			continue
		var solver := ClothSolver.new()
		solver.profile_key = "cloth%d" % index
		solver.rest_spacing = REST_SPACING
		var dims := preset.grid_dims(REST_SPACING)
		solver.grid_w = dims.x
		solver.grid_h = dims.y
		solver.set_seed(preset.build_seed(dims.x, dims.y))
		if preset.boulder_radius_m > 0.0:
			solver.sphere_center = preset.boulder_center()
			solver.sphere_radius = preset.boulder_radius_m
		solvers.append(solver)

		var renderer := ClothRenderer.new()
		renderer.setup(solver, preset, surface_shader, REST_SPACING)
		add_child(renderer)
		renderers.append(renderer)


func _init_solvers() -> void:
	for solver in solvers:
		RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solvers() -> void:
	for renderer in renderers:
		renderer.release()
	for solver in solvers:
		RenderingServer.call_on_render_thread(solver.free_render)


func _restart() -> void:
	_teardown_solvers()
	for index in PRESETS.size():
		var dims := PRESETS[index].grid_dims(REST_SPACING)
		solvers[index].set_seed(PRESETS[index].build_seed(dims.x, dims.y))
	_time = 0.0
	_step_clock.reset()
	_init_solvers()
	cloth_menu.update_status(solvers)


func _on_wind_toggled(on: bool) -> void:
	wind_enabled = on
	for solver in solvers:
		solver.wind_enabled = on


func _set_wind_speed(value: float) -> void:
	wind.speed = value


func _set_gustiness(value: float) -> void:
	wind.gustiness = value


func _set_turbulence(value: float) -> void:
	wind.turbulence = value


func _set_wind_wander(on: bool) -> void:
	wind.wander = on


func _set_wind_direction(degrees: float) -> void:
	wind.direction_rad = deg_to_rad(degrees)


func _set_drag(value: float) -> void:
	for solver in solvers:
		solver.drag = value
	cloth_menu.update_status(solvers)


func _set_damping(value: float) -> void:
	for solver in solvers:
		solver.damping = value
	cloth_menu.update_status(solvers)


func _set_iterations(value: float) -> void:
	for solver in solvers:
		solver.iterations = int(round(value))
	cloth_menu.update_status(solvers)


func _set_substeps(value: float) -> void:
	for solver in solvers:
		solver.substeps = int(round(value))
	cloth_menu.update_status(solvers)


func _set_relaxation(value: float) -> void:
	for solver in solvers:
		solver.relaxation = value
	cloth_menu.update_status(solvers)


func _on_stretch(value: float) -> void:
	for solver in solvers:
		solver.stretch_compliance = pow(10.0, -9.0 + value)


func _on_bending(value: float) -> void:
	for solver in solvers:
		solver.bend_compliance = pow(10.0, -6.0 + value * 0.7)


func _unpin_all() -> void:
	for solver in solvers:
		RenderingServer.call_on_render_thread(solver.unpin_all_render)


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


## Stores the tier's values and pushes the solver fields to every live cloth;
## at launch the solvers may not exist yet, so _apply_solver_quality runs
## again after _build_cloths.
func _apply_quality(values: Dictionary) -> void:
	_quality_values = values
	_apply_solver_quality()


func _apply_solver_quality() -> void:
	for solver in solvers:
		solver.iterations = int(_quality_values.iterations)
		solver.substeps = int(_quality_values.substeps)
	if not _quality_values.is_empty():
		_set_render_scale(_quality_values.render_scale)


func _on_profiler_enabled(on: bool) -> void:
	for solver in solvers:
		solver.profiling = on


func _profiler_lines() -> PackedStringArray:
	var total := 0.0
	var stages := {predict = 0.0, solve = 0.0, apply = 0.0}
	for solver in solvers:
		var timings := solver.get_timings()
		total += timings.get("total", 0.0)
		for key in stages:
			stages[key] += timings.get(key, 0.0)
	return PackedStringArray([
		"sim GPU %.2f ms (%d sheets)" % [total, solvers.size()],
		"  predict %.2f | solve %.2f | apply %.2f" % [
			stages.predict, stages.solve, stages.apply,
		],
	])


func _process(delta: float) -> void:
	for solver in solvers:
		if not solver.initialized:
			return
	for index in renderers.size():
		if renderers[index].position_texture == null:
			renderers[index].bind_texture(solvers[index])
			return

	# Advance sim time in fixed quanta so the sheets run at the same speed at
	# any frame rate; the wind is sampled at the quantum-aligned _time.
	var quanta := _step_clock.advance(delta)
	for i in quanta:
		_time += 1.0 / 60.0
	var current_wind := wind.vector(_time)
	cloth_menu.update_wind(current_wind)
	for solver in solvers:
		solver.wind_enabled = wind_enabled
		solver.wind = current_wind
		solver.wind_gust = wind.gustiness
		solver.wind_turb = wind.turbulence
		solver.time = _time
		for i in quanta:
			RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
	profiler.poll(delta)


func _exit_tree() -> void:
	_teardown_solvers()
