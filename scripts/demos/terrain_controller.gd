extends Node3D
## Water & Stone demo: a multi-material heightfield terrain (sand, water, snow,
## suspended sediment) relaxed on the GPU. This scene renders it as a
## displaced surface (heights never leave the GPU: compute image ->
## Texture2DRD -> vertex shader), aims the user brush, runs the preset's
## automatic sand/water pours and applies the preset ambience.

const WORLD := 4.0
const MICRO_NORMAL := preload("res://resources/ocean/micro_normal.png")
const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const BALL_COLORS := [
	Color(0.72, 0.45, 0.28), Color(0.85, 0.33, 0.25),
	Color(0.30, 0.52, 0.75), Color(0.92, 0.78, 0.35),
]
# Invisible boundary walls: [centre, size]. Keep thrown balls in the sandbox.
const BALL_WALLS := [
	[Vector3(0.0, 0.25, -WORLD * 0.5 - 0.1), Vector3(WORLD + 0.4, 1.6, 0.2)],
	[Vector3(0.0, 0.25, WORLD * 0.5 + 0.1), Vector3(WORLD + 0.4, 1.6, 0.2)],
	[Vector3(-WORLD * 0.5 - 0.1, 0.25, 0.0), Vector3(0.2, 1.6, WORLD + 0.4)],
	[Vector3(WORLD * 0.5 + 0.1, 0.25, 0.0), Vector3(0.2, 1.6, WORLD + 0.4)],
]
# Preset track enums are a subset of the brush modes but the numbers differ
# (BallTrack.PACK is 2, TerrainBrush.PACK is 5): map explicitly.
const TRACK_TO_BRUSH := {
	TerrainPreset.BallTrack.NONE: TerrainBrush.NONE,
	TerrainPreset.BallTrack.DIG: TerrainBrush.DIG,
	TerrainPreset.BallTrack.PACK: TerrainBrush.PACK,
}

const PRESETS := [
	preload("res://resources/terrain/presets/sandbox.tres"),
	preload("res://resources/terrain/presets/dunes.tres"),
	preload("res://resources/terrain/presets/pouring.tres"),
	preload("res://resources/terrain/presets/beach.tres"),
	preload("res://resources/terrain/presets/river.tres"),
	preload("res://resources/terrain/presets/powder.tres"),
	preload("res://resources/terrain/presets/avalanche.tres"),
	preload("res://resources/terrain/presets/thaw.tres"),
	preload("res://resources/terrain/presets/squall.tres"),
	preload("res://resources/terrain/presets/montagne.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var environment: Environment = $WorldEnvironment.environment
@onready var _viewport := ViewportGuard.attach(self)

var solver := HeightfieldTerrain.new()
var config: TerrainConfig = TerrainConfig.new()
var quality := SimQualityState.new()
## Vertex grid of the displaced sheet, independent of the solver grid; the
## quality tier owns it (see TerrainQualityProfile).
var mesh_n := 512
var view := TerrainScenery.new()
var profiler := SimProfiler.new()

var preset_idx := 9
var tool_choice := TerrainBrush.DIG
var auto_pour := true
var auto_water := true
var balls_enabled := false

var height_texture: Texture2DRD
var velocity_texture: Texture2DRD
var texture_bound := false
var _seed_max_height := 0.0
var _added_height_budget := 0.0

var _menu_builder := TerrainMenu.new()
var _preset: TerrainPreset = PRESETS[9]
var _time := 0.0
var _frozen := false
var _fixed_delta := -1.0
var _capture_profiling := false
var _profile_last_usec := 0
var _profile_count := 0
var _profile_sum := Vector3.ZERO
var _mountain_seed := 7
var mountain_world_size_m := 64.0
var mountain_height_m := 12.0
var mountain_density := 2.4
var mountain_ruggedness := 0.46
var mountain_valley_width_fraction := 0.16
var mountain_valley_depth_fraction := 0.72
var mountain_ridge_irregularity := 0.12
var mountain_surface_detail := 1.0
var rain_enabled := false
var mountain_rain_rate_m_s := 0.0025
var erosion_running := false
var mountain_erosion_rate := 1.2
var summit_water := false
var summit_rate_m_s := 0.12
var drying_enabled := false
var drying_rate_m_s := 0.15
var _source_request := 0
var _step_clock := SimStepClock.new()
var _dragging := false
var _aim := Vector2.ZERO
var _aim_height := 0.0
var _aim_valid := false
var _aim_screen := Vector2.ZERO
var _pick_samples := PackedVector3Array()
var _pick_revision := 0
var _pick_pending := false
var _strength := 1.2
var _balls: Array[SurfaceBall] = []
var _ball_root: Node3D
var _walls: StaticBody3D
var _held_ball: SurfaceBall
var _grab_target := Vector3.ZERO


func _ready() -> void:
	# No RenderingDevice means every compute dispatch silently no-ops: say so
	# instead of booting into a black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return
	preset_idx = clampi(int(menu.stored_value("Scene", "Preset", 9)), 0, PRESETS.size() - 1)
	_preset = PRESETS[preset_idx]
	_restore_generation_settings()

	solver.config = config
	quality.setup(TerrainQualityProfile, "terrain_quality_profile", _apply_quality)
	quality.restore()
	solver.world_size = _preset.world_size_m
	_ball_root = Node3D.new()
	_ball_root.name = "Balls"
	add_child(_ball_root)

	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 35.0
	orbit_cam.min_distance = 0.5
	orbit_cam.max_distance = 40.0
	orbit_cam.move_speed = 2.0

	view.build(self, solver.world_size, mesh_n)
	sun.shadow_enabled = true

	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(func(on: bool): solver.profiling = on)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)

	_setup_ui()
	# apply_preset seeds the field and brings the solver up; no separate init here.
	apply_preset(preset_idx)


func _exit_tree() -> void:
	_menu_builder.release()
	if height_texture != null:
		height_texture.texture_rd_rid = RID()
	if velocity_texture != null:
		velocity_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		height_texture = Texture2DRD.new()
		height_texture.texture_rd_rid = solver.get_height_tex_rid()
		view.sand_mat.set_shader_parameter("height_tex", height_texture)
		velocity_texture = Texture2DRD.new()
		velocity_texture.texture_rd_rid = solver.get_velocity_tex_rid()
		view.water_mat.set_shader_parameter("height_tex", height_texture)
		view.water_mat.set_shader_parameter("velocity_tex", velocity_texture)
		view.water_mat.set_shader_parameter("world_size", solver.world_size)
		view.water_mat.set_shader_parameter("grid_n", float(solver.grid_n))
		view.water_mat.set_shader_parameter("micro_normal_tex", MICRO_NORMAL)
		texture_bound = true
		return
	if _frozen:
		return
	if preset_idx == 9:
		_update_mountain_aim()
	if _capture_profiling:
		var now := Time.get_ticks_usec()
		if _profile_last_usec > 0:
			_profile_sum += Vector3(float(now - _profile_last_usec) / 1000.0,
				solver.get_timings().get("total", 0.0),
				RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
			_profile_count += 1
		_profile_last_usec = now

	# Sim time and transports advance in fixed quanta so pours, melt, erosion
	# and the orbiting sources run at the same speed at any frame rate.
	var quanta := _step_clock.advance(_fixed_delta if _fixed_delta >= 0.0 else delta)
	_time += _step_clock.reference_step * float(quanta)
	var watering := _preset.waters_by_itself() and auto_water and not _dragging
	var pouring := not watering and _preset.pours_by_itself() and auto_pour and not _dragging
	if _dragging and (preset_idx != 9 or _aim_valid):
		solver.brush.mode = tool_choice
		solver.brush.pos_m = _aim
		solver.brush.strength = _strength
	elif watering:
		# A water source orbits the field: rivers cut, deltas build, snow melts.
		var angle := _time * _preset.auto_water_rate_rad_s
		solver.brush.mode = TerrainBrush.WATER
		solver.brush.pos_m = Vector2(cos(angle), sin(angle)) * _preset.auto_water_radius_m
		solver.brush.strength = _preset.auto_water_strength
	elif pouring:
		# A slow orbit leaves a ridge of overlapping cones — the repose angle
		# is what shapes it, so this doubles as the physics showcase. Snow
		# presets heap snow instead, overloading the slab until it lets go.
		var angle := _time * _preset.auto_pour_rate_rad_s
		solver.brush.mode = TerrainBrush.SNOW if _preset.auto_pour_snow else TerrainBrush.POUR
		solver.brush.pos_m = Vector2(cos(angle), sin(angle)) * _preset.auto_pour_radius_m
		solver.brush.strength = _preset.auto_pour_strength
	else:
		solver.brush.clear()

	view.marker.position = Vector3(_aim.x, _aim_height + 0.08 if preset_idx == 9 else 0.6, _aim.y)
	view.marker.visible = (not (pouring or watering) or _dragging) and (preset_idx != 9 or _aim_valid)
	view.dust.position = Vector3(solver.brush.pos_m.x,
		_aim_height + 0.1 if preset_idx == 9 else 0.45, solver.brush.pos_m.y)
	var digging := solver.brush.mode == TerrainBrush.DIG or solver.brush.mode == TerrainBrush.POUR \
		or solver.brush.mode == TerrainBrush.MOUNTAIN
	view.dust.emitting = digging and not solver.brush.idle()

	for i in quanta:
		_added_height_budget += _step_clock.reference_step * (
			solver.rain_rate_m_s + solver.snowfall_rate_m_s + solver.uplift_rate_m_s)
		for source in solver.summit_sources:
			_added_height_budget += source.w * _step_clock.reference_step
		if solver.brush.mode == TerrainBrush.POUR or solver.brush.mode == TerrainBrush.SNOW \
				or solver.brush.mode == TerrainBrush.MOUNTAIN:
			_added_height_budget += maxf(solver.brush.strength, 0.0) * _step_clock.reference_step \
				* (5.0 if solver.brush.mode == TerrainBrush.MOUNTAIN else 1.0)
		if solver.contact_brush.mode == TerrainBrush.POUR or solver.contact_brush.mode == TerrainBrush.SNOW:
			_added_height_budget += maxf(solver.contact_brush.strength, 0.0) * _step_clock.reference_step
		view.update_bounds(_seed_max_height + 2.0 * _added_height_budget + solver.world_size * 2.0)
		RenderingServer.call_on_render_thread(
			solver.step_render.bind(_step_clock.reference_step))
	profiler.poll(delta)


func cycle_preset() -> void:
	var index := (preset_idx + 1) % PRESETS.size()
	_menu_builder._preset_option.select(index)
	_menu_builder._preset_option.item_selected.emit(index)


func apply_preset(index: int, seed: int = -1) -> void:
	var preset: TerrainPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Terrain preset '%s': %s" % [preset.display_name, error])
		return
	preset_idx = index
	_preset = preset.duplicate() if index == 9 else preset
	if index == 9:
		_mountain_seed = seed if seed >= 0 else randi_range(0, 2147483646)
		_preset.alpine_seed = _mountain_seed
		_preset.world_size_m = mountain_world_size_m
		_preset.mountain_height_m = mountain_height_m
		_preset.alpine_density = mountain_density
		_preset.alpine_ruggedness = mountain_ruggedness
		_preset.alpine_valley_width_fraction = mountain_valley_width_fraction
		_preset.alpine_valley_depth_fraction = mountain_valley_depth_fraction
		_preset.alpine_ridge_irregularity = mountain_ridge_irregularity
		_preset.alpine_surface_detail = mountain_surface_detail
		_preset.camera_target_m = Vector3(0.0, mountain_height_m * 0.25, 0.0)
		_preset.camera_distance_m = mountain_world_size_m * 0.95
	if _menu_builder._preset_option != null:
		_menu_builder._preset_option.select(index)
	restart()


## Reseeds the field from the active preset and brings the solver back up. Also
## the ↺ action: the terrain is only ever reset by rebuilding it. Every scene
## starts from the config defaults — slider drags from a previous preset must
## never leak into this one — then the preset layers its overrides on top.
func restart() -> void:
	_teardown_solver()
	_source_request += 1
	summit_water = false
	rain_enabled = false
	erosion_running = false
	_dragging = false
	_pick_pending = false
	_pick_samples = PackedVector3Array()
	_pick_revision = solver.query_revision()
	_aim_valid = false
	_aim_screen = get_viewport().get_mouse_position()
	tool_choice = _preset.default_tool
	solver.brush.clear()
	solver.world_size = _preset.world_size_m
	view.set_world_size(solver.world_size, mesh_n)
	var state := _preset.build_state(solver.grid_n, solver.world_size)
	solver.set_seed_channels(state.sand, state.water, state.snow)
	# Config defaults first, then the preset's negative-means-keep overrides;
	# the solver object outlives presets, so both paths run every restart.
	solver.reset_to_config()
	drying_enabled = solver.infiltration_rate_m_s > 0.0
	solver.repose_deg = _preset.repose_angle_deg if _preset.repose_angle_deg >= 0.0 else solver.repose_deg
	solver.erosion_rate = _preset.erosion_rate if _preset.erosion_rate >= 0.0 else solver.erosion_rate
	if preset_idx == 9:
		mountain_erosion_rate = solver.erosion_rate
		solver.erosion_rate = 0.0
	solver.sediment_capacity = _preset.sediment_capacity if _preset.sediment_capacity >= 0.0 else solver.sediment_capacity
	solver.snow_enabled = _preset.snow_enabled
	solver.brush.radius_m = solver.world_size * 0.06 if preset_idx == 9 else 0.3
	solver.rain_rate_m_s = _preset.rain_rate_m_s if _preset.rain_rate_m_s >= 0.0 else solver.rain_rate_m_s
	solver.deposition_gain = _preset.deposition_gain if _preset.deposition_gain >= 0.0 else solver.deposition_gain
	solver.uplift_rate_m_s = _preset.uplift_rate_m_s if _preset.uplift_rate_m_s >= 0.0 else solver.uplift_rate_m_s
	solver.uplift_mode = _preset.uplift_mode if _preset.uplift_mode >= 0 else solver.uplift_mode
	solver.uplift_radius_fraction = _preset.uplift_radius_fraction if _preset.uplift_radius_fraction >= 0.0 else solver.uplift_radius_fraction
	solver.snowline_m = _preset.snowline_m if _preset.snowline_m >= 0.0 else solver.snowline_m
	solver.melt_rate_m_s = _preset.melt_rate_m_s if _preset.melt_rate_m_s >= 0.0 else solver.melt_rate_m_s
	solver.evap_rate_m_s = _preset.evap_rate_m_s if _preset.evap_rate_m_s >= 0.0 else solver.evap_rate_m_s
	solver.snowfall_rate_m_s = _preset.snowfall_rate_m_s if _preset.snowfall_rate_m_s >= 0.0 else solver.snowfall_rate_m_s
	solver.freeze_rate_m_s = _preset.freeze_rate_m_s if _preset.freeze_rate_m_s >= 0.0 else solver.freeze_rate_m_s
	solver.snow_repose_deg = _preset.snow_cohesion_deg if _preset.snow_cohesion_deg >= 0.0 else solver.snow_repose_deg
	solver.snow_flow_rate = _preset.snow_creep_rate if _preset.snow_creep_rate >= 0.0 else solver.snow_flow_rate
	solver.snow_cap = _preset.snow_creep_cap if _preset.snow_creep_cap >= 0.0 else solver.snow_cap
	solver.snow_iterations = int(_preset.snow_pass_iterations) if _preset.snow_pass_iterations >= 0.0 else solver.snow_iterations
	orbit_cam.target = _preset.camera_target_m
	orbit_cam.distance = _preset.camera_distance_m
	orbit_cam.max_distance = maxf(40.0, solver.world_size * 4.0)
	orbit_cam.move_speed = solver.world_size * 0.5
	orbit_cam.zoom_speed = maxf(1.0, solver.world_size * 0.06)
	orbit_cam.pitch = -35.0 if preset_idx == 9 else -30.0
	main_cam.far = maxf(200.0, solver.world_size * 6.0 + _preset.mountain_height_m * 4.0)
	view.walls.visible = _preset.walls_visible
	view.apply_ambience(environment, sun, _preset)
	view.set_snowfall(_preset.snowfall)
	view.sand_mat.set_shader_parameter("color_light", _preset.sand_light)
	view.sand_mat.set_shader_parameter("color_dark", _preset.sand_dark)
	view.sand_mat.set_shader_parameter("grid_n", float(solver.grid_n))
	view.sand_mat.set_shader_parameter("snowline_m", solver.snowline_m)
	view.sand_mat.set_shader_parameter("landscape_materials", _preset.landscape_materials)
	view.sand_mat.set_shader_parameter("snow_enabled", solver.snow_enabled)
	view.water_mat.set_shader_parameter("snow_enabled", solver.snow_enabled)
	view.water_mat.set_shader_parameter("landscape_water", _preset.landscape_materials)
	view.water.visible = true
	_seed_max_height = 0.0
	for i in state.sand.size():
		_seed_max_height = maxf(_seed_max_height, state.sand[i] + state.water[i] + state.snow[i])
	_added_height_budget = 0.0
	view.update_bounds(_seed_max_height + solver.world_size * 2.0)
	_time = 0.0
	_step_clock.reset()
	_menu_builder.sync_tool(tool_choice)
	_menu_builder.sync_params()
	_menu_builder.sync_mountain(preset_idx == 9, summit_water)
	_menu_builder.set_hint(_preset.hint)
	view.set_marker_radius(solver.brush.radius_m)
	view.marker.scale.y = 0.12 if preset_idx == 9 else 1.0
	balls_enabled = _preset.balls_enabled
	_respawn_balls()
	_menu_builder.sync_balls(balls_enabled)
	_update_status()
	RenderingServer.call_on_render_thread(solver.init_render)


func select_tool(mode: int) -> void:
	if not solver.snow_enabled and (mode == TerrainBrush.SNOW or mode == TerrainBrush.PACK):
		return
	tool_choice = mode
	_menu_builder.sync_tool(mode)


func generate_alpine(seed: int = -1) -> void:
	apply_preset(9, seed)


func regenerate() -> void:
	if preset_idx == 9:
		generate_alpine()
	else:
		restart()


func set_mountain_size(value: float) -> void:
	mountain_world_size_m = clampf(value, 1.0, 2000.0)


func set_mountain_height(value: float) -> void:
	mountain_height_m = clampf(value, 0.1, 1000.0)


func set_mountain_density(value: float) -> void:
	mountain_density = clampf(value, 0.5, 8.0)


func set_mountain_ruggedness(value: float) -> void:
	mountain_ruggedness = clampf(value, 0.1, 0.7)


func set_mountain_valley_width(value: float) -> void:
	mountain_valley_width_fraction = clampf(value, 0.04, 0.35)


func set_mountain_valley_depth(value: float) -> void:
	mountain_valley_depth_fraction = clampf(value, 0.0, 0.95)


func set_mountain_ridge_irregularity(value: float) -> void:
	mountain_ridge_irregularity = clampf(value, 0.0, 0.3)


func set_mountain_surface_detail(value: float) -> void:
	mountain_surface_detail = clampf(value, 0.0, 2.0)


func _restore_generation_settings() -> void:
	set_mountain_size(float(menu.stored_value("Terrain", "Terrain size m", 64.0)))
	set_mountain_height(float(menu.stored_value("Terrain", "Elevation m", 12.0)))
	set_mountain_density(float(menu.stored_value("Terrain", "Mountain density", 2.4)))
	set_mountain_ruggedness(float(menu.stored_value("Terrain", "Ruggedness", 0.46)))
	set_mountain_valley_width(float(menu.stored_value("Terrain", "Valley width", 0.16)))
	set_mountain_valley_depth(float(menu.stored_value("Terrain", "Valley depth", 0.72)))
	set_mountain_ridge_irregularity(float(menu.stored_value("Terrain", "Ridge irregularity", 0.12)))
	set_mountain_surface_detail(float(menu.stored_value("Terrain", "Surface detail", 1.0)))


func set_rain_enabled(on: bool) -> void:
	rain_enabled = on and preset_idx == 9
	if preset_idx == 9:
		solver.rain_rate_m_s = mountain_rain_rate_m_s if rain_enabled else 0.0
	_menu_builder.sync_params()
	_update_status()


func set_erosion_running(on: bool) -> void:
	erosion_running = on and preset_idx == 9
	if preset_idx == 9:
		solver.erosion_rate = mountain_erosion_rate if erosion_running else 0.0
	_menu_builder.sync_params()
	_update_status()


func set_drying(on: bool) -> void:
	drying_enabled = on
	solver.infiltration_rate_m_s = drying_rate_m_s if on else 0.0
	_menu_builder.sync_params()


func set_drying_rate(value: float) -> void:
	drying_rate_m_s = value
	if drying_enabled:
		solver.infiltration_rate_m_s = value


func set_summit_water(on: bool) -> void:
	_source_request += 1
	var request := _source_request
	summit_water = false
	solver.set_summit_sources(PackedVector2Array(), 1.0, 0.0)
	if on and preset_idx == 9 and solver.initialized:
		var n := solver.grid_n
		var bytes: PackedByteArray = await TextureReadback.new().read_layer(
			solver.get_height_tex_rid(), 0, n * n * 16)
		if request != _source_request or not is_inside_tree():
			return
		if not bytes.is_empty():
			var field := bytes.to_float32_array()
			var heights := PackedFloat32Array()
			heights.resize(n * n)
			for i in heights.size():
				heights[i] = field[i * 4] + field[i * 4 + 2]
			var peaks := _preset.find_summits(heights, n, solver.world_size)
			solver.set_summit_sources(peaks, solver.world_size * 0.025, summit_rate_m_s)
			summit_water = not peaks.is_empty()
	_menu_builder.sync_mountain(preset_idx == 9, summit_water)
	_menu_builder.set_hint("Raise mountains before starting summit water." if on and not summit_water else _preset.hint)
	_update_status()


func set_summit_rate(value: float) -> void:
	summit_rate_m_s = value
	var points := PackedVector2Array()
	for source in solver.summit_sources:
		points.append(Vector2(source.x, source.y))
	solver.set_summit_sources(points, solver.world_size * 0.025, value)


func set_auto_pour(on: bool) -> void:
	auto_pour = on


func set_auto_water(on: bool) -> void:
	auto_water = on


func set_strength(value: float) -> void:
	_strength = value


func set_brush_size(value: float) -> void:
	solver.brush.radius_m = value
	view.set_marker_radius(value)
	view.marker.scale.y = 0.12 if preset_idx == 9 else 1.0


func set_repose(value: float) -> void:
	solver.repose_deg = value
	_update_status()


func set_water_flow(value: float) -> void:
	solver.water_flow_rate = value


func set_rain(value: float) -> void:
	if preset_idx == 9:
		mountain_rain_rate_m_s = value
		solver.rain_rate_m_s = value if rain_enabled else 0.0
	else:
		solver.rain_rate_m_s = value


func set_deposition(value: float) -> void:
	solver.deposition_gain = value


func set_snowline(value: float) -> void:
	solver.snowline_m = value
	view.sand_mat.set_shader_parameter("snowline_m", value)


func set_uplift_rate(value: float) -> void:
	solver.uplift_rate_m_s = value


func set_uplift_mode(value: int) -> void:
	solver.uplift_mode = value


func set_uplift_radius(value: float) -> void:
	solver.uplift_radius_fraction = value


func set_erosion(value: float) -> void:
	if preset_idx == 9:
		mountain_erosion_rate = value
		solver.erosion_rate = value if erosion_running else 0.0
	else:
		solver.erosion_rate = value


func set_sediment_capacity(value: float) -> void:
	solver.sediment_capacity = value


func set_stochasticity(value: float) -> void:
	solver.stochasticity = value


func set_evaporation(value: float) -> void:
	solver.evap_rate_m_s = value


func set_snow_repose(value: float) -> void:
	solver.snow_repose_deg = value


func set_snow_flow(value: float) -> void:
	solver.snow_flow_rate = value


func set_melt(value: float) -> void:
	solver.melt_rate_m_s = value if solver.snow_enabled else 0.0


func set_snowfall(value: float) -> void:
	solver.snowfall_rate_m_s = value if solver.snow_enabled else 0.0


func set_freeze(value: float) -> void:
	solver.freeze_rate_m_s = value if solver.snow_enabled else 0.0


func set_grid_n(n: int) -> void:
	if n == solver.grid_n:
		return
	solver.grid_n = n
	restart()


func set_mesh_n(n: int) -> void:
	if n == mesh_n:
		return
	mesh_n = n
	if view.terrain != null:
		view.rebuild_terrain(mesh_n)


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func capture_ready() -> bool:
	return solver.initialized and texture_bound


func set_frozen(on: bool) -> void:
	_frozen = on


func set_capture_fixed_delta(value: float) -> void:
	_fixed_delta = value


func set_capture_ui(on: bool) -> void:
	$UI.visible = on


func set_capture_params(params: Dictionary) -> void:
	if params.has("terrain_size"):
		set_mountain_size(float(params.terrain_size))
	if params.has("elevation"):
		set_mountain_height(float(params.elevation))
	if params.has("density"):
		set_mountain_density(float(params.density))
	if params.has("ruggedness"):
		set_mountain_ruggedness(float(params.ruggedness))
	if params.has("valley_width"):
		set_mountain_valley_width(float(params.valley_width))
	if params.has("valley_depth"):
		set_mountain_valley_depth(float(params.valley_depth))
	if params.has("ridge_irregularity"):
		set_mountain_ridge_irregularity(float(params.ridge_irregularity))
	if params.has("surface_detail"):
		set_mountain_surface_detail(float(params.surface_detail))
	if params.has("alpine_seed"):
		generate_alpine(int(params.alpine_seed))
		var deadline := Time.get_ticks_msec() + 20000
		while not capture_ready() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not capture_ready():
			push_error("Terrain capture did not finish rebuilding")
			return
	if params.has("summit_rate"):
		set_summit_rate(float(params.summit_rate))
	if params.has("summit_water"):
		await set_summit_water(bool(params.summit_water))
	if params.has("drying"):
		set_drying(bool(params.drying))
	if params.has("erosion"):
		set_erosion_running(bool(params.erosion))
	if params.has("rain"):
		set_rain_enabled(bool(params.rain))


func set_capture_view(value: String) -> void:
	if preset_idx != 9:
		if value in ["near", "far"]:
			orbit_cam.distance = _preset.camera_distance_m * (0.6 if value == "near" else 1.4)
		return
	if value == "valley":
		orbit_cam.distance = solver.world_size * 0.65
		orbit_cam.pitch = -22.0
		orbit_cam.target = Vector3(0.0, _preset.mountain_height_m * 0.18, 0.0)
	elif value == "overview":
		orbit_cam.distance = solver.world_size * 1.45
		orbit_cam.pitch = -40.0
		orbit_cam.target = Vector3(0.0, _preset.mountain_height_m * 0.25, 0.0)


func set_capture_profiling(on: bool) -> void:
	solver.profiling = on
	_capture_profiling = on
	_viewport.set_measure_render_time(on)
	_profile_last_usec = 0
	_profile_count = 0
	_profile_sum = Vector3.ZERO


func capture_metadata(path: String) -> String:
	var average := _profile_sum / float(maxi(_profile_count, 1))
	var size := get_viewport().get_visible_rect().size
	return "CAPTURE META preset=%s grid=%d mesh=%d size=%dx%d time=%.3f samples=%d frame_mean_ms=%.3f sim_gpu_mean_ms=%.3f viewport_gpu_mean_ms=%.3f path=%s" % [
		_preset.display_name, solver.grid_n, mesh_n, int(size.x), int(size.y), _time,
		_profile_count, average.x, average.y, average.z, path]


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


## What the viewport is actually scaled to, for seeding the menu slider.
func render_scale() -> float:
	return _viewport.render_scale()


## Sets the fields a quality tier bundles. Before the solver runs the values
## land directly (the launch restart below picks them up); afterwards a grid
## change reseeds through the same restart path, and a sheet change rebuilds
## the displaced mesh.
func _apply_quality(values: Dictionary) -> void:
	solver.iterations = int(values.iterations)
	if solver.initialized and int(values.grid_n) != solver.grid_n:
		set_grid_n(int(values.grid_n))
	else:
		solver.grid_n = int(values.grid_n)
	set_mesh_n(int(values.mesh_n))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = event.pressed
		if _dragging:
			_aim_tool(event.position)
	elif event is InputEventMouseMotion:
		_aim_tool(event.position)


## Runs before the camera's _unhandled_input: grabbing a ball with the left
## button consumes the event so the orbit stays still during the drag.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
			and not event.pressed:
		_dragging = false
	if not balls_enabled or _balls.is_empty():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_held_ball = _pick_ball(event.position)
			if _held_ball != null:
				_grab_target = _held_ball.global_position
				get_viewport().set_input_as_handled()
		elif _held_ball != null:
			_held_ball = null
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _held_ball != null:
		_drag_grab_target(event.position)
		get_viewport().set_input_as_handled()


## Screen ray against the y = 0 plane, clamped to the domain: the sheet is
## displaced on the GPU, so there is no mesh to raycast.
func _aim_tool(screen_pos: Vector2) -> void:
	if preset_idx == 9:
		_aim_screen = screen_pos
		return
	var origin := main_cam.project_ray_origin(screen_pos)
	var dir := main_cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-4:
		return
	var t := -origin.y / dir.y
	if t < 0.0:
		return
	var hit := origin + dir * t
	var limit := solver.world_size * 0.5
	_aim = Vector2(clampf(hit.x, -limit, limit), clampf(hit.z, -limit, limit))


func _update_mountain_aim() -> void:
	if _pick_pending:
		if solver.query_revision() == _pick_revision:
			return
		_pick_pending = false
		var heights := solver.latest_results()
		_aim_valid = false
		if heights.size() == _pick_samples.size():
			var previous_gap := 0.0
			for i in heights.size():
				if heights[i].w < 0.5:
					continue
				var gap := _pick_samples[i].y - heights[i].x - heights[i].y
				if gap <= 0.0:
					var hit := _pick_samples[i]
					if i > 0:
						hit = _pick_samples[i - 1].lerp(hit,
							previous_gap / maxf(previous_gap - gap, 1e-6))
					else:
						hit.y = heights[i].x + heights[i].y
					_aim = Vector2(hit.x, hit.z)
					_aim_height = hit.y
					_aim_valid = true
					break
				previous_gap = gap
	var origin := main_cam.project_ray_origin(_aim_screen)
	var direction := main_cam.project_ray_normal(_aim_screen)
	var half := solver.world_size * 0.5
	var low := Vector3(-half, 0.0, -half)
	var high := Vector3(half, _seed_max_height + 2.0 * _added_height_budget + 2.0, half)
	var enter := 0.0
	var leave := main_cam.far
	for axis in 3:
		if absf(direction[axis]) < 1e-6:
			if origin[axis] < low[axis] or origin[axis] > high[axis]:
				_aim_valid = false
				return
		else:
			var first := (low[axis] - origin[axis]) / direction[axis]
			var last := (high[axis] - origin[axis]) / direction[axis]
			enter = maxf(enter, minf(first, last))
			leave = minf(leave, maxf(first, last))
	if enter >= leave:
		_aim_valid = false
		return
	var points := PackedVector2Array()
	_pick_samples = PackedVector3Array()
	for i in HeightfieldTerrain.MAX_QUERY_POINTS:
		var p := origin + direction * lerpf(enter, leave,
			float(i) / float(HeightfieldTerrain.MAX_QUERY_POINTS - 1))
		_pick_samples.append(p)
		points.append(Vector2(p.x, p.z))
	_pick_revision = solver.query_revision()
	_pick_pending = true
	solver.submit_queries(points)


## Drag plane at the held ball's height: the support spring keeps it on the
## surface, only the xz target is steered.
func _drag_grab_target(screen_pos: Vector2) -> void:
	var origin := main_cam.project_ray_origin(screen_pos)
	var dir := main_cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-4 or _held_ball == null:
		return
	var t := (_held_ball.global_position.y - origin.y) / dir.y
	if t < 0.0:
		return
	var hit := origin + dir * t
	var limit := solver.world_size * 0.5 - 0.1
	_grab_target = Vector3(clampf(hit.x, -limit, limit), _held_ball.global_position.y,
		clampf(hit.z, -limit, limit))


func _pick_ball(screen_pos: Vector2) -> SurfaceBall:
	var space := get_world_3d().direct_space_state
	var from := main_cam.project_ray_origin(screen_pos)
	var query := PhysicsRayQueryParameters3D.create(
		from, from + main_cam.project_ray_normal(screen_pos) * 60.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty() or not (hit.collider is SurfaceBall):
		return null
	return hit.collider


func _physics_process(_delta: float) -> void:
	if not solver.initialized or not balls_enabled or _balls.is_empty():
		return
	if _held_ball != null:
		# Spring to the steer point, damping on the body velocity; y follows
		# the terrain through the support spring, not through this force.
		_grab_target.y = _held_ball.global_position.y
		_held_ball.apply_central_force(
			(_grab_target - _held_ball.global_position) * 60.0 * _held_ball.mass
			- _held_ball.linear_velocity * 8.0 * _held_ball.mass)
	var points := PackedVector2Array()
	for ball in _balls:
		points.append_array(ball.query_points())
	solver.submit_queries(points)
	if not solver.query_results_valid():
		return
	var results := solver.latest_results()
	var best := {}
	for i in _balls.size():
		var c: Dictionary = _balls[i].apply_surface(results, i * SurfaceBall.PROBE_COUNT)
		if not c.is_empty() and (best.is_empty() or c.score > best.score):
			best = c
	# The track brush needs motion: a resting ball would keep digging in place.
	var track: int = TRACK_TO_BRUSH[_preset.ball_track]
	if best.is_empty() or best.speed < 0.08 or track == TerrainBrush.NONE:
		solver.contact_brush.clear()
		return
	solver.contact_brush.mode = track
	solver.contact_brush.pos_m = best.pos
	solver.contact_brush.radius_m = best.radius
	solver.contact_brush.strength = clampf(0.6 + best.pen * 30.0 + best.speed * 0.8, 0.5, 4.0)


func set_balls_enabled(on: bool) -> void:
	balls_enabled = on
	if on:
		_respawn_balls()
	else:
		_clear_balls()


## (Re)spawns the preset's balls in a small ring; spawn height clears the
## highest seeded feature so they settle through the support spring.
func _respawn_balls() -> void:
	_clear_balls()
	if not balls_enabled or _ball_root == null:
		return
	_ensure_walls()
	var ceiling := _seed_max_height + 0.4
	for i in _preset.ball_count:
		var ball := SurfaceBall.new(0.16 + 0.03 * float(i % 3), BALL_COLORS[i % BALL_COLORS.size()])
		var angle := TAU * float(i) / float(_preset.ball_count) + 0.7
		var ring := 0.9 + 0.3 * float(i % 2)
		ball.position = Vector3(cos(angle) * ring, ceiling, sin(angle) * ring)
		_ball_root.add_child(ball)
		_balls.append(ball)


func _clear_balls() -> void:
	for ball in _balls:
		ball.queue_free()
	_balls.clear()
	_held_ball = null
	solver.contact_brush.clear()
	if _walls != null:
		_walls.queue_free()
		_walls = null


func _ensure_walls() -> void:
	if _walls != null:
		return
	_walls = StaticBody3D.new()
	_walls.name = "BallWalls"
	var scale_xz := solver.world_size / WORLD
	for def in BALL_WALLS:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(def[1].x * scale_xz, def[1].y, def[1].z * scale_xz)
		shape.shape = box
		shape.position = Vector3(def[0].x * scale_xz, def[0].y, def[0].z * scale_xz)
		_walls.add_child(shape)
	_ball_root.add_child(_walls)


func _setup_ui() -> void:
	_menu_builder.solver = solver
	_menu_builder.profiler = profiler
	_menu_builder.host = self
	_menu_builder.build(menu, PRESETS, preset_idx, tool_choice, _strength, auto_pour)


func _teardown_solver() -> void:
	if height_texture != null:
		height_texture.texture_rd_rid = RID()
	if velocity_texture != null:
		velocity_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _update_status() -> void:
	if preset_idx == 9:
		_menu_builder.set_status("%.0f × %.0f m · %d² cells · %s" % [
			solver.world_size, solver.world_size, solver.grid_n,
			"erosion on" if erosion_running else "erosion off"])
	else:
		_menu_builder.set_status("%d² cells · %.1f mm/cell · repose %.0f° sand / %.0f° snow" % [
			solver.grid_n, solver.cell_size() * 1000.0, solver.repose_deg, solver.snow_repose_deg])


func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("hydraulic"):
		lines.append("sources + hydraulic GPU %.2f ms" % t["hydraulic"])
	return lines
