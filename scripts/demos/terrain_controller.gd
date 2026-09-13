extends Node3D
## Sand & Snow demo: a multi-material heightfield terrain (sand, water, snow,
## suspended sediment) relaxed on the GPU. This scene renders it as a
## displaced surface (heights never leave the GPU: compute image ->
## Texture2DRD -> vertex shader), aims the user brush, runs the preset's
## automatic sand/water pours and applies the preset ambience.

const WORLD := 4.0
const MICRO_NORMAL := preload("res://resources/ocean/micro_normal.png")
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

var preset_idx := 0
var tool_choice := TerrainBrush.DIG
var auto_pour := true
var auto_water := true
var balls_enabled := false

var height_texture: Texture2DRD
var texture_bound := false

var _menu_builder := TerrainMenu.new()
var _preset: TerrainPreset = PRESETS[0]
var _time := 0.0
var _dragging := false
var _aim := Vector2.ZERO
var _strength := 1.2
var _balls: Array[SurfaceBall] = []
var _ball_root: Node3D
var _walls: StaticBody3D
var _held_ball: SurfaceBall
var _grab_target := Vector3.ZERO


func _ready() -> void:
	solver.config = config
	quality.setup(TerrainQualityProfile, "terrain_quality_profile", _apply_quality)
	quality.restore()
	solver.world_size = WORLD
	_ball_root = Node3D.new()
	_ball_root.name = "Balls"
	add_child(_ball_root)

	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 35.0
	orbit_cam.min_distance = 0.5
	orbit_cam.max_distance = 40.0
	orbit_cam.move_speed = 2.0

	view.build(self, WORLD, mesh_n)
	sun.shadow_enabled = true
	view.sand_mat.set_shader_parameter("micro_normal_tex", MICRO_NORMAL)

	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(func(on: bool): solver.profiling = on)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid())

	_setup_ui()
	# apply_preset seeds the field and brings the solver up; no separate init here.
	apply_preset(preset_idx)


func _exit_tree() -> void:
	if height_texture != null:
		height_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		height_texture = Texture2DRD.new()
		height_texture.texture_rd_rid = solver.get_height_tex_rid()
		view.sand_mat.set_shader_parameter("height_tex", height_texture)
		texture_bound = true
		return

	_time += delta
	var watering := _preset.waters_by_itself() and auto_water and not _dragging
	var pouring := not watering and _preset.pours_by_itself() and auto_pour and not _dragging
	if _dragging:
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

	view.marker.position = Vector3(_aim.x, 0.6, _aim.y)
	view.marker.visible = not (pouring or watering) or _dragging
	view.dust.position = Vector3(solver.brush.pos_m.x, 0.45, solver.brush.pos_m.y)
	var digging := solver.brush.mode == TerrainBrush.DIG or solver.brush.mode == TerrainBrush.POUR
	view.dust.emitting = digging and not solver.brush.idle()

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))
	profiler.poll(delta)


func apply_preset(index: int) -> void:
	var preset: TerrainPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Terrain preset '%s': %s" % [preset.display_name, error])
		return
	preset_idx = index
	_preset = preset
	restart()


## Reseeds the field from the active preset and brings the solver back up. Also
## the ↺ action: the terrain is only ever reset by rebuilding it. Every scene
## starts from the config defaults — slider drags from a previous preset must
## never leak into this one — then the preset layers its overrides on top.
func restart() -> void:
	_teardown_solver()
	tool_choice = _preset.default_tool
	solver.brush.clear()
	var state := _preset.build_state(solver.grid_n, WORLD)
	solver.set_seed_channels(state.sand, state.water, state.snow)
	# Config defaults first, then the preset's negative-means-keep overrides;
	# the solver object outlives presets, so both paths run every restart.
	solver.reset_to_config()
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
	view.walls.visible = _preset.walls_visible
	view.apply_ambience(environment, sun, _preset)
	view.set_snowfall(_preset.snowfall)
	view.sand_mat.set_shader_parameter("color_light", _preset.sand_light)
	view.sand_mat.set_shader_parameter("color_dark", _preset.sand_dark)
	view.sand_mat.set_shader_parameter("grid_n", float(solver.grid_n))
	_time = 0.0
	_menu_builder.sync_tool(tool_choice)
	_menu_builder.sync_params()
	_menu_builder.set_hint(_preset.hint)
	view.set_marker_radius(solver.brush.radius_m)
	balls_enabled = _preset.balls_enabled
	_respawn_balls()
	_menu_builder.sync_balls(balls_enabled)
	_update_status()
	RenderingServer.call_on_render_thread(solver.init_render)


func select_tool(mode: int) -> void:
	tool_choice = mode
	_menu_builder.sync_tool(mode)


func set_auto_pour(on: bool) -> void:
	auto_pour = on


func set_auto_water(on: bool) -> void:
	auto_water = on


func set_strength(value: float) -> void:
	_strength = value


func set_brush_size(value: float) -> void:
	solver.brush.radius_m = value
	view.set_marker_radius(value)


func set_repose(value: float) -> void:
	solver.repose_deg = value
	_update_status()


func set_water_flow(value: float) -> void:
	solver.water_flow_rate = value


func set_erosion(value: float) -> void:
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
	solver.melt_rate_m_s = value


func set_snowfall(value: float) -> void:
	solver.snowfall_rate_m_s = value


func set_freeze(value: float) -> void:
	solver.freeze_rate_m_s = value


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


## What the viewport is actually scaled to, for seeding the menu slider.
func render_scale() -> float:
	return _viewport.render_scale()


## Sets the fields a quality tier bundles. Before the solver runs the values
## land directly (the launch restart below picks them up); afterwards a grid
## change reseeds through the same restart path, and a sheet change rebuilds
## the displaced mesh.
func _apply_quality(values: Dictionary) -> void:
	set_render_scale(values.render_scale)
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
	var origin := main_cam.project_ray_origin(screen_pos)
	var dir := main_cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-4:
		return
	var t := -origin.y / dir.y
	if t < 0.0:
		return
	var hit := origin + dir * t
	var limit := WORLD * 0.5
	_aim = Vector2(clampf(hit.x, -limit, limit), clampf(hit.z, -limit, limit))


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
	var limit := WORLD * 0.5 - 0.1
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
	var ceiling := _preset.base_height_m + _preset.dune_amplitude_m + _preset.snow_depth_m + 0.4
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
	for def in BALL_WALLS:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = def[1]
		shape.shape = box
		shape.position = def[0]
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
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _update_status() -> void:
	_menu_builder.set_status("%d² cells · %.1f mm/cell · repose %.0f° sand / %.0f° snow" % [
		solver.grid_n, solver.cell_size() * 1000.0, solver.repose_deg, solver.snow_repose_deg,
	])


func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	return lines
