extends Node3D
## Heightfield sand demo. The solver relaxes a GPU grid of column heights
## toward the angle of repose; this scene renders it as a displaced surface
## (heights never leave the GPU: compute image -> Texture2DRD -> vertex
## shader) and aims the brush.

const WORLD := 4.0
const MESH_N := 512

const PRESETS := [
	preload("res://resources/sand/presets/sandbox.tres"),
	preload("res://resources/sand/presets/dunes.tres"),
	preload("res://resources/sand/presets/pouring.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var _viewport := ViewportGuard.attach(self)

var solver := HeightfieldSand.new()
var view := SandScenery.new()
var profiler := SimProfiler.new()

var preset_idx := 0
var tool_choice := SandBrush.DIG
var auto_pour := true

var height_texture: Texture2DRD
var texture_bound := false

var _menu_builder := SandMenu.new()
var _preset: SandPreset = PRESETS[0]
var _time := 0.0
var _dragging := false
var _aim := Vector2.ZERO
var _strength := 1.2


func _ready() -> void:
	solver.grid_n = GameManager.get_setting("sand_grid_n", 512)
	solver.world_size = WORLD

	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 35.0
	orbit_cam.min_distance = 0.5
	orbit_cam.max_distance = 40.0
	orbit_cam.move_speed = 2.0

	view.build(self, WORLD, MESH_N)
	sun.shadow_enabled = true

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
	var pouring := _preset.pours_by_itself() and auto_pour and not _dragging
	if _dragging:
		solver.brush.mode = tool_choice
		solver.brush.pos_m = _aim
		solver.brush.strength = _strength
	elif pouring:
		# A slow orbit leaves a ridge of overlapping cones — the repose angle
		# is what shapes it, so this doubles as the physics showcase.
		var angle := _time * _preset.auto_pour_rate_rad_s
		solver.brush.mode = SandBrush.POUR
		solver.brush.pos_m = Vector2(cos(angle), sin(angle)) * _preset.auto_pour_radius_m
		solver.brush.strength = _preset.auto_pour_strength
	else:
		solver.brush.clear()

	view.marker.position = Vector3(_aim.x, 0.6, _aim.y)
	view.marker.visible = not pouring or _dragging
	view.dust.position = Vector3(solver.brush.pos_m.x, 0.45, solver.brush.pos_m.y)
	view.dust.emitting = not solver.brush.idle() and solver.brush.mode != SandBrush.SMOOTH

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))
	profiler.poll(delta)


func apply_preset(index: int) -> void:
	var preset: SandPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Sand preset '%s': %s" % [preset.display_name, error])
		return
	preset_idx = index
	_preset = preset
	restart()


## Reseeds the field from the active preset and brings the solver back up. Also
## the ↺ action: the sand is only ever reset by rebuilding it.
func restart() -> void:
	_teardown_solver()
	tool_choice = _preset.default_tool
	solver.brush.clear()
	solver.set_seed(_preset.build_seed(solver.grid_n, WORLD))
	orbit_cam.target = _preset.camera_target_m
	orbit_cam.distance = _preset.camera_distance_m
	view.walls.visible = _preset.walls_visible
	view.sand_mat.set_shader_parameter("grid_n", float(solver.grid_n))
	_time = 0.0
	_menu_builder.sync_tool(tool_choice)
	view.set_marker_radius(solver.brush.radius_m)
	_update_status()
	RenderingServer.call_on_render_thread(solver.init_render)


func select_tool(mode: int) -> void:
	tool_choice = mode
	_menu_builder.sync_tool(mode)


func set_auto_pour(on: bool) -> void:
	auto_pour = on


func set_strength(value: float) -> void:
	_strength = value


func set_brush_size(value: float) -> void:
	solver.brush.radius_m = value
	view.set_marker_radius(value)


func set_repose(value: float) -> void:
	solver.repose_deg = value
	_update_status()


func set_grid_n(n: int) -> void:
	if n == solver.grid_n:
		return
	solver.grid_n = n
	GameManager.set_setting("sand_grid_n", n)
	restart()


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = event.pressed
		if _dragging:
			_aim_tool(event.position)
	elif event is InputEventMouseMotion:
		_aim_tool(event.position)


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
	_menu_builder.set_status("%d² cells · %.1f mm/cell · repose %.0f°" % [
		solver.grid_n, solver.cell_size() * 1000.0, solver.repose_deg,
	])


func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	return lines
