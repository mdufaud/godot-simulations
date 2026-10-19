extends Node3D

const Scenery := preload("res://scripts/demos/river/river_scenery.gd")
const MenuBuilder := preload("res://scripts/demos/river/river_menu.gd")
const Interactions := preload("res://scripts/demos/river/river_interactions.gd")
const WaterfallLandscape := preload("res://scripts/demos/river/river_waterfall_landscape.gd")
const TorrentLandscape := preload("res://scripts/demos/river/river_torrent_landscape.gd")
const WindowOverlay := preload("res://scripts/demos/river/river_window_overlay.gd")
const STEEP_SCENE := 3
const CHANNEL_GRADES := [0.05, 0.15, 0.30]
const CHANNEL_HEADINGS := [Vector2(0.0, -1.0), Vector2(1.0, 0.0), Vector2(1.0, -1.0)]
const STEEP_GUIDANCE_HZ := Vector2(1.0, 5.0)
const STEEP_WINDOW_M := Vector2(16.0, 24.0)
const STEEP_RANGE_M := 24.0
const STEEP_EDGE_FADE_M := 2.0
const FIELD_CACHE_SIZE := 6
const STEEP_VIEWS := {
	"default": Vector3(20.0, -50.0, 20.0), "near": Vector3(10.0, -30.0, 20.0), "top": Vector3(34.0, -88.0, 0.0),
	"far": Vector3(48.0, -50.0, 20.0), "low": Vector3(12.0, -14.0, 215.0), "low_down": Vector3(14.0, -24.0, 35.0),
}
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
var scene_index := 0
var waterfall_angles := PackedFloat32Array([0.0, 50.0, 90.0])
var channel_grade_index := 1
var channel_heading_index := 2
var steep_guidance := true
var steep_window := false
var _quality_reflection_scale := 0.5
var window_overlay := WindowOverlay.new()
var _quality_tier := 1
var _scenery := Scenery.new()
var _menu_builder := MenuBuilder.new()
var interactions := Interactions.new()
var _profile := false
var _fields: Dictionary = {}
var _previous_fps_limit := 60
var _frames := 0
var _sample_count := 0
var _frame_seconds := 0.0
var _gpu_ms := 0.0
var _solver_ms := 0.0
var _solver_cpu_ms := 0.0
var _reflection_ms := 0.0


func _ready() -> void:
	world_environment.environment = world_environment.environment.duplicate() as Environment
	LoadingPump.stage("Applying quality profile")
	quality.setup(RiverQualityProfile, "river_quality_profile", _apply_quality)
	quality.restore()
	camera.cull_mask |= 4
	set_capture_view("default")
	_scenery.build(self)
	_fields[[0]] = _scenery.field
	LoadingPump.stage("Loading water textures")
	config = PRESETS[1].duplicate() as RiverConfig
	river.config = config
	river.field = _scenery.field
	river.micro_normal = load("res://resources/ocean/micro_normal.png")
	river.foam_filaments = load("res://resources/ocean/foam_variant_03_flowing_filaments.png")
	river.foam_bubbles = load("res://resources/ocean/foam_variant_01_microbubbles.png")
	river.riverbed_albedo = load("res://resources/materials/clean_pebbles/clean_pebbles_diff_2k.jpg")
	river.scenery_materials = _scenery.materials
	river.loading_stage = func(label: String) -> void: LoadingPump.stage(label)
	river.compute_available = GpuPreflight.available()
	river.camera = camera
	river.reflection_anchor_z_m = orbit.target.z
	river.scene_world = camera.get_world_3d()
	river.render_size = get_window().size
	LoadingPump.stage("Starting river simulation")
	add_child(river)
	river.start()
	interactions.river = river
	interactions.camera = camera
	add_child(interactions)
	window_overlay.river = river
	window_overlay.visible = false
	add_child(window_overlay)
	LoadingPump.stage("Building menu")
	_menu_builder.build(menu, self, PRESETS)
	LoadingPump.stage("Applying river preset")
	apply_preset(1)
	river.simulation_changed.connect(func(): _menu_builder.sync_flow(river.swe))
	process_priority = 30


func _process(delta: float) -> void:
	var bounds := Vector2(18.0, 30.0) if scene_index == 0 else (Vector2(22.0, 22.0) if scene_index == STEEP_SCENE else Vector2(10.0, 22.0))
	orbit.target.x = clampf(orbit.target.x, -bounds.x, bounds.x)
	orbit.target.z = clampf(orbit.target.z, -bounds.y, bounds.y)
	if scene_index == 0:
		orbit.target.y = RiverLandscape.water_height(Vector2(orbit.target.x, orbit.target.z), 0.65) + 0.1
	elif scene_index == STEEP_SCENE:
		orbit.target.y = river.field.sample_height(Vector2(orbit.target.x, orbit.target.z), config.water_level_m) + 0.1
	river.render_size = get_window().size
	river.reflection_anchor_z_m = orbit.target.z
	_scenery.tick(river.simulation_time_s, river.flow_distance_m)
	_frames += 1
	if _profile and _frames > 90:
		_sample_count += 1
		_frame_seconds += delta
		_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
		_gpu_ms += river.reflection_gpu_ms()
		_reflection_ms += river.reflection_gpu_ms()
		_solver_ms += river.swe.gpu_ms()
		_solver_cpu_ms += river.swe.cpu_ms()


func apply_preset(index: int) -> void:
	preset_index = clampi(index, 0, PRESETS.size() - 1)
	config = PRESETS[preset_index].duplicate() as RiverConfig
	_apply_guidance()
	river.apply_config(config)
	_scenery.set_water_level(config.water_level_m)
	_scenery.set_water_clarity(config.clarity)
	_menu_builder.sync(config, preset_index)
	river.reset()


func cycle_preset() -> void:
	apply_preset((preset_index + 1) % PRESETS.size())


func cycle_scene() -> void:
	set_scene((scene_index + 1) % MenuBuilder.SCENES.size())


func set_scene(index: int) -> void:
	index = clampi(index, 0, MenuBuilder.SCENES.size() - 1)
	if index == scene_index and (index == 0 or index == STEEP_SCENE or is_equal_approx(river.field.waterfall.angle_degrees, waterfall_angles[index])):
		return
	_build_scene(index)


func _build_scene(index: int) -> void:
	var was_steep := scene_index == STEEP_SCENE
	var live := river.swe.enabled
	interactions.clear()
	river.stop()
	_scenery.clear()
	scene_index = index
	var selected := _field_for(index)
	_scenery.build(self, selected)
	river.field = selected
	river.swe_window_m = STEEP_WINDOW_M if index == STEEP_SCENE and steep_window else Vector2.ZERO
	river.swe_range_m = STEEP_RANGE_M if index == STEEP_SCENE and steep_window else 0.0
	river.scenery_materials = _scenery.materials
	river.reflection_plane_count = RiverQualityProfile.REFLECTION_PLANES[_quality_tier] if index == 0 else (2 if _quality_tier >= 2 else 1)
	river.start()
	river.water_material.set_shader_parameter("domain_edge_fade_m", STEEP_EDGE_FADE_M if index == STEEP_SCENE else 0.0)
	river.swe.enabled = live
	river.swe.profiling = _profile
	river.set_reflection_profiling(_profile)
	if was_steep or index == STEEP_SCENE:
		river.set_reflection_scale(0.0 if index == STEEP_SCENE else _quality_reflection_scale)
	_apply_guidance()
	river.apply_config(config)
	river.reset()
	window_overlay.visible = index == STEEP_SCENE and steep_window
	_scenery.set_water_level(config.water_level_m)
	_scenery.set_water_clarity(config.clarity)
	_menu_builder.sync_scene(index, waterfall_angles)
	_menu_builder.sync_flow(river.swe)
	set_capture_view("default")


func _field_for(index: int) -> RiverField:
	var key := [index] if index == 0 else ([index, channel_grade_index, channel_heading_index] if index == STEEP_SCENE else [index, waterfall_angles[index]])
	var selected: RiverField = _fields.get(key)
	if selected == null:
		selected = RiverLandscape.new() if index == 0 else (TorrentLandscape.new(CHANNEL_GRADES[channel_grade_index],
			CHANNEL_HEADINGS[channel_heading_index], Vector2(56.0, 56.0)) if index == STEEP_SCENE else WaterfallLandscape.new(waterfall_angles[index]))
	_fields.erase(key)
	_fields[key] = selected
	if _fields.size() > FIELD_CACHE_SIZE:
		var oldest: Array = _fields.keys()[0]
		_scenery.ground_cache.erase(_fields[oldest])
		_fields.erase(oldest)
	return selected


func set_channel_grade(index: int) -> void:
	channel_grade_index = clampi(index, 0, CHANNEL_GRADES.size() - 1)
	if scene_index == STEEP_SCENE:
		_build_scene(STEEP_SCENE)


func set_channel_heading(index: int) -> void:
	channel_heading_index = clampi(index, 0, CHANNEL_HEADINGS.size() - 1)
	if scene_index == STEEP_SCENE:
		_build_scene(STEEP_SCENE)


func set_steep_guidance(enabled: bool) -> void:
	steep_guidance = enabled
	_apply_guidance()
	river.apply_config(config)
	river.reset()


func set_steep_window(enabled: bool) -> void:
	steep_window = enabled
	if scene_index == STEEP_SCENE:
		_build_scene(STEEP_SCENE)


func _apply_guidance() -> void:
	var base: RiverConfig = PRESETS[preset_index]
	var steep := scene_index == STEEP_SCENE and steep_guidance
	config.current_guidance_hz = STEEP_GUIDANCE_HZ.x if steep else base.current_guidance_hz
	config.level_guidance_hz = STEEP_GUIDANCE_HZ.y if steep else base.level_guidance_hz


func set_waterfall_angle(value: float) -> void:
	if scene_index == 0 or scene_index == STEEP_SCENE or not is_finite(value):
		return
	waterfall_angles[scene_index] = clampf(value, 20.0, 90.0)
	set_scene(scene_index)


func set_capture_scene(index: int) -> void:
	set_scene(index)


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)
	_menu_builder.quality_option.select(quality.requested)


func quality_profile_label() -> String:
	return quality.label()


func set_render_scale(value: float) -> void:
	viewport_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _apply_quality(values: Dictionary) -> void:
	_quality_tier = RiverQualityProfile.WATER_CELL_SIZE_M.find(values.water_cell_size_m)
	viewport_guard.set_msaa(values.msaa)
	world_environment.environment.ssao_enabled = values.ssao
	world_environment.environment.volumetric_fog_enabled = values.volumetric_mist
	world_environment.environment.volumetric_fog_density = 0.0
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
	river.set_reflection_plane_count(values.reflection_planes if scene_index == 0 else (2 if _quality_tier >= 2 else 1))
	_quality_reflection_scale = values.reflection_scale
	river.set_reflection_scale(0.0 if scene_index == STEEP_SCENE else values.reflection_scale)
	river.set_waterfall_quality(_quality_tier)


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


func set_mist_density(value: float) -> void:
	config.mist_density = value
	river.apply_config(config)


func set_grass_enabled(enabled: bool) -> void:
	_scenery.set_grass_enabled(enabled)


func set_capture_params(parameters: Dictionary) -> void:
	if parameters.has("angle"):
		set_waterfall_angle(float(parameters.angle))
	if parameters.has("speed"):
		set_speed(float(parameters.speed))
	if parameters.has("level"):
		set_level(float(parameters.level))
	if parameters.has("swe"):
		river.swe.set_enabled(bool(parameters["swe"]))
	if parameters.has("grass"):
		set_grass_enabled(bool(parameters["grass"]))
	if parameters.has("foam"):
		set_foam(float(parameters["foam"]))
	if parameters.has("mist"):
		set_mist_density(float(parameters["mist"]))
	if parameters.has("grade"):
		set_channel_grade(int(parameters["grade"]))
	if parameters.has("heading"):
		set_channel_heading(int(parameters["heading"]))
	if parameters.has("guidance"):
		set_steep_guidance(bool(parameters["guidance"]))
	if parameters.has("window"):
		set_steep_window(bool(parameters["window"]))
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
	if scene_index == STEEP_SCENE:
		orbit.target = Vector3(0.0, river.field.sample_height(Vector2.ZERO, config.water_level_m), 0.0)
		var pose: Vector3 = STEEP_VIEWS.get(view, STEEP_VIEWS["default"])
		orbit.distance = pose.x
		orbit.pitch = pose.y
		orbit.yaw = pose.z
		orbit._update_transform()
		return
	if scene_index > 0:
		var profile := river.field.waterfall
		var impact := profile.crest_z_m - (profile.run_m() if not profile.is_vertical() else config.speed_m_s * sqrt(2.0 * profile.height_m / 9.81))
		orbit.target = Vector3(0.0, 3.0 + config.water_level_m, (profile.crest_z_m + impact) * 0.5)
		orbit.distance = maxf(21.0 if view == "wide" else 16.0, Vector2(profile.run_m(), profile.height_m).length() * 1.3)
		orbit.pitch = -16.0
		orbit.yaw = 168.0
		if view == "lip" or view == "near" or view == "lip_top":
			orbit.target = Vector3(0.0, 5.4 + config.water_level_m, profile.crest_z_m - 0.6)
			orbit.distance = 7.5
			orbit.pitch = -18.0
			if view == "lip_top":
				orbit.pitch = -45.0
		elif view == "impact":
			orbit.target = Vector3(0.0, 0.6 + config.water_level_m, impact - 0.6)
			orbit.distance = 8.0
			orbit.pitch = -16.0
		elif view == "front":
			orbit.distance = 10.0
			orbit.pitch = -12.0
			orbit.yaw = 180.0
		elif view == "side" or view == "underside":
			orbit.target = Vector3(0.0, 4.0 + config.water_level_m, profile.crest_z_m - 0.8)
			orbit.distance = 8.0
			orbit.pitch = -22.0 if view == "side" else 8.0
			orbit.yaw = 115.0
		elif view == "top":
			orbit.target = Vector3(0.0, 5.7 + config.water_level_m, profile.crest_z_m - 0.2)
			orbit.distance = 8.0
			orbit.pitch = -58.0
			orbit.yaw = 90.0
		elif view == "impact_top":
			orbit.target = Vector3(0.0, config.water_level_m, impact + 0.25)
			orbit.distance = 7.0
			orbit.pitch = -58.0
			orbit.yaw = 155.0
		orbit._update_transform()
		return
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


func set_capture_spray(enabled: bool) -> void:
	if river.waterfall != null:
		river.waterfall.set_effects_enabled(enabled)


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
	_solver_cpu_ms = 0.0
	_reflection_ms = 0.0
	viewport_guard.set_measure_render_time(enabled)
	river.set_reflection_profiling(enabled)
	river.swe.profiling = enabled


func capture_metadata(_path: String) -> String:
	return "CAPTURE META river scene=%d angle_deg=%.1f preset=%s quality=%s swe=%s grid=%s vertices=%d samples=%d fps=%.2f gpu_ms=%.2f solver_ms=%.2f solver_cpu_ms=%.2f reflection_ms=%.2f backlog_s=%.5f size=%s window=%s" % [scene_index, river.field.waterfall.angle_degrees if river.field.waterfall != null else 0.0, config.display_name.replace(" ", "_"), quality.label(), river.swe.active, river.swe.solver.grid,
		river._surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(), _sample_count, float(_sample_count) / maxf(_frame_seconds, 0.001),
		(_gpu_ms + _solver_ms) / maxf(_sample_count, 1.0), _solver_ms / maxf(_sample_count, 1.0), _solver_cpu_ms / maxf(_sample_count, 1.0), _reflection_ms / maxf(_sample_count, 1.0), float(river.swe.solver.snapshot().get("backlog_s", 0.0)), river.render_size, get_tree().root.size]


func _exit_tree() -> void:
	if _profile:
		Engine.max_fps = _previous_fps_limit
