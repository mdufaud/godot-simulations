class_name SoftBodyGrab extends Node
## Mouse or one-finger grab: a press on a soft body picks the surface vertex under
## the pointer (one blocking position readback) and a spring pulls it toward the
## pointer at its picked depth until release. A press that misses falls through
## to the orbit camera.

const PICK_RADIUS_M := 0.15

var camera: Camera3D
var solver: SoftBodySolver

var _vertex := -1
var _depth := 0.0
var _screen := Vector2.ZERO
var _touch_index := -1


func is_grabbing() -> bool:
	return _vertex >= 0


func release() -> void:
	_vertex = -1
	_touch_index = -1
	if solver != null:
		solver.release_grab()


func _unhandled_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventMouseMotion) \
			and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	var handled := false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			handled = _press(button.position) if button.pressed else _release()
	elif event is InputEventMouseMotion and is_grabbing():
		_screen = (event as InputEventMouseMotion).position
		handled = true
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and _touch_index < 0 and _press(touch.position):
			_touch_index = touch.index
			handled = true
		elif not touch.pressed and touch.index == _touch_index:
			handled = _release()
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _touch_index:
		_screen = (event as InputEventScreenDrag).position
		handled = true
	if handled:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if is_grabbing():
		var origin := camera.project_ray_origin(_screen)
		solver.set_grab(_vertex, origin + camera.project_ray_normal(_screen) * _depth)


func _press(screen: Vector2) -> bool:
	if solver == null or not solver.is_ready():
		return false
	var origin := camera.project_ray_origin(screen)
	var direction := camera.project_ray_normal(screen)
	var positions := solver.read_positions()
	var vertex := solver.nearest_vertex(positions, origin, direction, PICK_RADIUS_M)
	if vertex < 0:
		return false
	_vertex = vertex
	_screen = screen
	var p := Vector3(positions[vertex * 4], positions[vertex * 4 + 1], positions[vertex * 4 + 2])
	_depth = (p - origin).dot(direction)
	return true


func _release() -> bool:
	if not is_grabbing():
		return false
	release()
	return true
