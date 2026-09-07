extends Node3D

const EXHIBIT_NAMES := [
	"1 · Impossible Storage",
	"2 · Infinite Staircase",
	"3 · Spherical Curvature",
	"4 · Growing Corridor",
	"5 · Perspective Grip",
	"6 · Wrap Garden",
	"7 · Holonomy Loop",
]

@onready var player: NonEuclideanPlayer = $Player
@onready var render_manager: PortalRenderManager = $PortalRenderManager
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI
@onready var _viewport := ViewportGuard.attach(self)

var _cells: Node3D
var _materials: Dictionary = {}
var _current_exhibit := 0
var _reserve := ExhibitReserve.new()
var _staircase := ExhibitStaircase.new()
var _garden := ExhibitGarden.new()
var _corridor := ExhibitGrowingCorridor.new()
var _grip := ExhibitGripRoom.new()
var _wrap := ExhibitWrapWorld.new()
var _holonomy := ExhibitHolonomyLoop.new()
var _grab := GrabController3D.new()
var _hud := NonEuclideanHud.new()


func _ready() -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_BILINEAR, 1.0)
	_build_materials()
	_cells = Node3D.new()
	_cells.name = "Cells"
	add_child(_cells)
	_reserve.build(_cells, _materials)
	_staircase.build(_cells, _materials, player)
	_garden.build(_cells, _materials)
	_corridor.build(_cells, _materials)
	_grip.build(_cells, _materials)
	_wrap.build(_cells, _materials)
	_holonomy.build(_cells, _materials)
	_hud.build(self, EXHIBIT_NAMES)
	render_manager.set_camera(player.get_camera())
	_go_to_case(0)
	_update_hud()


func _physics_process(delta: float) -> void:
	if _current_exhibit == 1 and _staircase.track(player):
		_update_hud()
	elif _current_exhibit == 3 and _corridor.track(player):
		_update_hud()
	elif _current_exhibit == 4:
		_grab.physics_update(player.get_camera())
		_hud.set_grab_hint(_grab.aim_target(player.get_camera(), 1,
			[player.get_rid()]) != null)
	elif _current_exhibit == 5 and _wrap.track(player, delta):
		_update_hud()
	elif _current_exhibit == 6 and _holonomy.track(player):
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		menu.toggle_panel()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("grab") and _current_exhibit == 4:
		var exclude: Array[RID] = [player.get_rid()]
		_grab.try_grab(player.get_camera(), 1, exclude)
	elif event.is_action_released("grab"):
		_grab.release()


func _process(_delta: float) -> void:
	if _hud.is_debug_visible():
		_hud.set_debug_text(render_manager.get_debug_text())


func _exit_tree() -> void:
	_materials.clear()


## Shared palette. Every exhibit draws from it, so a material downloaded once is
## reused across the three cells.
func _build_materials() -> void:
	_materials["concrete"] = GeometryKit.make_downloaded_material("concrete_wall_001",
		Color(0.24, 0.27, 0.3), 0.0, 0.82, 2.5)
	_materials["concrete_dark"] = GeometryKit.make_material(Color(0.075, 0.09, 0.11), 0.0, 0.88)
	_materials["tile"] = GeometryKit.make_downloaded_material("grey_tiles",
		Color(0.16, 0.19, 0.22), 0.05, 0.46, 4.0)
	_materials["metal"] = GeometryKit.make_material(Color(0.065, 0.08, 0.1), 0.88, 0.25)
	_materials["white"] = GeometryKit.make_material(Color(0.58, 0.62, 0.66), 0.0, 0.58)
	_materials["blue"] = GeometryKit.make_material(Color(0.025, 0.11, 0.18), 0.35, 0.26,
		Color(0.05, 0.55, 1.0), 3.2)
	_materials["orange"] = GeometryKit.make_material(Color(0.18, 0.065, 0.02), 0.3, 0.3,
		Color(1.0, 0.26, 0.04), 3.2)
	_materials["green"] = GeometryKit.make_material(Color(0.025, 0.13, 0.08), 0.3, 0.3,
		Color(0.1, 1.0, 0.45), 3.2)
	_materials["stair_plain"] = GeometryKit.make_material(Color(0.2, 0.24, 0.23), 0.0, 0.84)
	_materials["measure"] = GeometryKit.make_material(Color(0.08, 0.13, 0.16), 0.15, 0.38,
		Color(0.12, 0.58, 0.86), 0.65)
	_materials["corridor_light"] = GeometryKit.make_material(Color(0.12, 0.14, 0.16),
		0.2, 0.25, Color(0.5, 0.85, 1.0), 3.5)


func _set_render_scale(v: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, v)


func _on_menu_panel_toggled(open: bool) -> void:
	player.set_controls_enabled(not open)
	_hud.set_touch_visible(not open)


## Teleporting is the whole navigation, so it gets a strip button.
func _next_case() -> void:
	_hud.choose_case((_current_exhibit + 1) % EXHIBIT_NAMES.size())


func _go_to_case(index: int) -> void:
	if index < 0 or index >= EXHIBIT_NAMES.size():
		return
	_current_exhibit = index
	var pose := _spawn_pose(index)
	var gravity := Vector3.DOWN * 12.0
	if index == 2:
		gravity = _garden.gravity_field.sample_gravity(pose.origin)
	player.set_pose(pose, gravity)
	_staircase.set_active(index == 1, player)
	_corridor.set_active(index == 3, player)
	if index != 4:
		_grab.release()
		_hud.set_grab_hint(false)
	if index == 2:
		player.set_gravity_field(_garden.gravity_field)
	# Only the active exhibit occupies the two portal render slots.
	match index:
		0:
			render_manager.configure_portals(_reserve.portals)
		_:
			render_manager.configure_portals([] as Array[Portal3D])
	_hud.select_case(index)
	_update_hud()
	if menu.is_panel_open():
		menu.toggle_panel()


func _reset_current_case() -> void:
	if _current_exhibit == 0:
		_reserve.reset()
	elif _current_exhibit == 1:
		_staircase.reset()
	elif _current_exhibit == 3:
		_corridor.reset()
	elif _current_exhibit == 4:
		_grab.release()
		_grip.reset()
	elif _current_exhibit == 5:
		_wrap.reset()
	elif _current_exhibit == 6:
		_holonomy.reset()
	_go_to_case(_current_exhibit)


func _spawn_pose(index: int) -> Transform3D:
	match index:
		1:
			return _staircase.spawn_pose
		2:
			return _garden.spawn_pose
		3:
			return _corridor.spawn_pose
		4:
			return _grip.spawn_pose
		5:
			return _wrap.spawn_pose
		6:
			return _holonomy.spawn_pose
	return _reserve.spawn_pose


func _update_hud() -> void:
	match _current_exhibit:
		0:
			_hud.set_status("%s\nWalk around the 6 × 8 m building, then enter its 22 × 30 m interior." % EXHIBIT_NAMES[0])
		1:
			_hud.set_status("%s\nAscents: %d · Turn around and the climb never happened." % [
				EXHIBIT_NAMES[1], _staircase.ascent_count])
		2:
			_hud.set_status("%s\nWalk a great circle. Gravity remains radial." % EXHIBIT_NAMES[2])
		3:
			_hud.set_status("%s\nCrossings: %d · Virtual distance: %.0f m — every threshold opens a bigger space." % [
				EXHIBIT_NAMES[3], _corridor.crossing_count, _corridor.virtual_distance])
		4:
			_hud.set_status("%s\nHold to grab — its size resolves where it lands. Grab close, place far: it grows." %
				EXHIBIT_NAMES[4])
		5:
			_hud.set_status("%s\nLoops: %d · Ball wraps: %d — walk straight to return to the HOME beacon\nLast seam: %s — space repeats every 40 m" % [
				EXHIBIT_NAMES[5], _wrap.wrap_count, _wrap.prop_wraps,
				"none yet" if _wrap.last_seam.is_empty() else _wrap.last_seam])
		6:
			_hud.set_status("%s\nCrossings: %d — three lefts and a straight: the square comes back turned 90°." % [
				EXHIBIT_NAMES[6], _holonomy.crossing_count])
