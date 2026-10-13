extends Node3D

const Scenery := preload("res://scripts/demos/river/river_scenery.gd")
const MenuBuilder := preload("res://scripts/demos/river/river_menu.gd")
const Interactions := preload("res://scripts/demos/river/river_interactions.gd")
const PRESETS := [
	preload("res://resources/river/presets/calm.tres"),
	preload("res://resources/river/presets/natural_flow.tres"),
	preload("res://resources/river/presets/rapids.tres"),
	preload("res://resources/river/presets/high_water.tres"),
]

@onready var orbit: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var menu: SimMenu = $UI/SimMenu
@onready var viewport_guard := ViewportGuard.attach(self)

var river := RiverSystem.new()
var config: RiverConfig
var quality := SimQualityState.new()
var preset_index := 1
var _scenery := Scenery.new()
var _menu_builder := MenuBuilder.new()
var interactions := Interactions.new()
var _profile := false
var _previous_fps_limit := 60
var _frames := 0
var _sample_count := 0
var _frame_seconds := 0.0
var _gpu_ms := 0.0
var _solver_ms := 0.0


func _ready() -> void:
	world_environment.environment = world_environment.environment.duplicate() as Environment
	quality.setup(RiverQualityProfile, "river_quality_profile", _apply_quality)
	quality.restore()
	camera.cull_mask |= 4
	set_capture_view("default")
	_scenery.build(self)
	config = PRESETS[1].duplicate() as RiverConfig
	river.config = config
	river.field = _scenery.field
	river.micro_normal = load("res://resources/ocean/micro_normal.png")
	river.foam_filaments = load("res://resources/ocean/foam_variant_03_flowing_filaments.png")
	river.foam_bubbles = load("res://resources/ocean/foam_variant_01_microbubbles.png")
	river.riverbed_albedo = load("res://resources/materials/clean_pebbles/clean_pebbles_diff_2k.jpg")
	river.scenery_materials = _scenery.materials
	river.compute_available = GpuPreflight.available()
	river.camera = camera
	river.reflection_anchor_z_m = orbit.target.z
	river.scene_world = camera.get_world_3d()
	river.render_size = get_window().size
	add_child(river)
	river.start()
	interactions.river = river
	interactions.camera = camera
	add_child(interactions)
	_menu_builder.build(menu, self, PRESETS)
	apply_preset(1)
	river.simulation_changed.connect(func(): _menu_builder.sync_flow(river.swe))
	process_priority = 30


func _process(delta: float) -> void:
	orbit.target.x = clampf(orbit.target.x, -18.0, 18.0)
	orbit.target.z = clampf(orbit.target.z, -30.0, 30.0)
	orbit.target.y = RiverLandscape.water_height(Vector2(orbit.target.x, orbit.target.z), 0.65) + 0.1
	river.render_size = get_window().size
	river.reflection_anchor_z_m = orbit.target.z
	_scenery.tick(river.simulation_time_s, river.flow_distance_m)
	_frames += 1
	if _profile and _frames > 90:
		_sample_count += 1
		_frame_seconds += delta
		_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		_gpu_ms += river.reflection_gpu_ms()
		_solver_ms += river.swe.gpu_ms()


func apply_preset(index: int) -> void:
	preset_index = clampi(index, 0, PRESETS.size() - 1)
	config = PRESETS[preset_index].duplicate() as RiverConfig
	river.apply_config(config)
	_scenery.set_water_level(config.water_level_m)
	_scenery.set_water_clarity(config.clarity)
	_menu_builder.sync(config, preset_index)
	river.reset()


func cycle_preset() -> void:
	apply_preset((preset_index + 1) % PRESETS.size())


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)
	_menu_builder.quality_option.select(quality.requested)


func quality_profile_label() -> String:
	return quality.label()


func set_render_scale(value: float) -> void:
	viewport_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _apply_quality(values: Dictionary) -> void:
	viewport_guard.set_msaa(values.msaa)
	world_environment.environment.ssao_enabled = values.ssao
	viewport_guard.set_taa(false)
	world_environment.environment.glow_enabled = values.surface_detail == 1.0
	world_environment.environment.glow_intensity = 0.28
	world_environment.environment.glow_bloom = 0.0
	world_environment.environment.glow_hdr_threshold = 1.5
	_scenery.set_grass_quality(values.grass_density, values.grass_distance_m,
		values.grass_detail, values.grass_shadows)
	_scenery.set_water_detail(values.surface_detail)
	river.set_surface_cell_size_m(values.water_cell_size_m)
	river.set_foam_size_px(values.foam_size_px)
	river.set_foam_detail(values.foam_detail)
	river.rapids_reflection = values.rapids_reflection
	river.set_surface_detail(values.surface_detail)
	river.set_reflection_plane_count(values.reflection_planes)
	river.set_reflection_scale(values.reflection_scale)


func set_speed(value: float) -> void:
	config.speed_m_s = value
	river.apply_config(config)


func set_level(value: float) -> void:
	config.water_level_m = value
	river.apply_config(config)
	_scenery.set_water_level(value)


func set_clarity(value: float) -> void:
	config.clarity = value
	river.apply_config(config)
	_scenery.set_water_clarity(value)


func set_foam(value: float) -> void:
	config.foam_amount = value
	river.apply_config(config)


func set_grass_enabled(enabled: bool) -> void:
	_scenery.set_grass_enabled(enabled)


func set_capture_params(parameters: Dictionary) -> void:
	if parameters.has("swe"):
		river.swe.set_enabled(bool(parameters["swe"]))
	if parameters.has("grass"):
		set_grass_enabled(bool(parameters["grass"]))
	if parameters.has("foam"):
		set_foam(float(parameters["foam"]))
	if parameters.has("crates"):
		for index in int(parameters["crates"]):
			interactions.throw_crate()


func set_frozen(value: bool) -> void:
	river.frozen = value
	if _menu_builder.pause_button != null:
		_menu_builder.pause_button.set_pressed_no_signal(value)


func reset_river() -> void:
	interactions.clear()
	apply_preset(preset_index)
	set_frozen(false)


func set_capture_time(value: float) -> void:
	river.simulation_time_s = value
	river.flow_distance_m = value * config.speed_m_s
	river.water_material.set_shader_parameter("flow_distance_m", river.flow_distance_m)
	river.water_material.set_shader_parameter("simulation_time_s", value)


func set_capture_fixed_delta(value: float) -> void:
	river.fixed_delta_s = value


func capture_image_metrics(_image: Image) -> String:
	return "CAPTURE IMAGE river time_s=%.3f flow_distance_m=%.3f" % [river.simulation_time_s, river.flow_distance_m]


func set_capture_view(view: String) -> void:
	orbit.target = Vector3(-0.5, 0.0, 5.0)
	orbit.distance = 12.0
	orbit.pitch = -20.0
	orbit.yaw = -32.0
	if view == "near":
		orbit.target = Vector3(-0.9, 0.0, 5.5)
		orbit.distance = 9.0
		orbit.pitch = -18.0
		orbit.yaw = -25.0
	elif view == "wide":
		orbit.target = Vector3(0.0, 0.0, 0.0)
		orbit.distance = 48.0
		orbit.pitch = -38.0
		orbit.yaw = 32.0
	elif view == "rocks":
		orbit.target = Vector3(1.5, 0.0, 8.0)
		orbit.distance = 7.0
		orbit.pitch = -42.0
		orbit.yaw = -30.0
	orbit.target.y = RiverLandscape.water_height(Vector2(orbit.target.x, orbit.target.z), 0.65) + 0.1
	orbit._update_transform()


func move_capture_camera(offset: Vector3) -> void:
	orbit.target += offset


func capture_ready() -> bool:
	return river.water_material != null and (not river.swe.available or river.swe.initialized)


func set_capture_ui(visible_ui: bool) -> void:
	menu.visible = visible_ui


func set_capture_reflection(enabled: bool) -> void:
	river.set_reflection_enabled(enabled)


func set_capture_foam(enabled: bool) -> void:
	river.water_material.set_shader_parameter("foam_enabled", enabled)


func set_capture_profiling(enabled: bool) -> void:
	if enabled == _profile:
		return
	if enabled:
		_previous_fps_limit = Engine.max_fps
		Engine.max_fps = 0
	else:
		Engine.max_fps = _previous_fps_limit
	_profile = enabled
	_frames = 0
	_sample_count = 0
	_frame_seconds = 0.0
	_gpu_ms = 0.0
	_solver_ms = 0.0
	viewport_guard.set_measure_render_time(enabled)
	river.set_reflection_profiling(enabled)
	river.swe.profiling = enabled


func capture_metadata(_path: String) -> String:
	return "CAPTURE META river preset=%s quality=%s swe=%s grid=%s vertices=%d samples=%d fps=%.2f gpu_ms=%.2f solver_ms=%.2f size=%s window=%s" % [config.display_name.replace(" ", "_"), quality.label(), river.swe.active, river.swe.solver.grid,
		river._surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(), _sample_count, float(_sample_count) / maxf(_frame_seconds, 0.001),
		(_gpu_ms + _solver_ms) / maxf(_sample_count, 1.0), _solver_ms / maxf(_sample_count, 1.0), river.render_size, get_tree().root.size]


func _exit_tree() -> void:
	if _profile:
		Engine.max_fps = _previous_fps_limit
