class_name SmokePointer extends Node
## Mouse and touch for the smoke demo. Added after the camera, so it sees each
## unhandled event first: a press on a Jolt body grabs it; with blow on, a press on
## empty space pushes the air, otherwise the camera orbits. Right drag always
## pushes the air.

const PUSH_RELAX_HZ := 30.0

var camera: Camera3D
var props: SmokeProps
## Centre of the camera-facing plane the push strokes paint on.
var focus_m := Vector3.ZERO
var blow := false
var radius_m := 0.4
var push_mps := 6.0

var _held: RigidBody3D
var _grab_distance := 0.0
var _grab_target := Vector3.ZERO
var _pushing := false
var _stroke_point := Vector3.ZERO
var _stroke_previous := Vector3.ZERO
var _stroke_velocity := Vector3.ZERO
var _touch_index := -1


func _unhandled_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventMouseMotion) \
			and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	var handled := false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			handled = _press(button.position) if button.pressed else _release()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			handled = _begin_stroke(button.position) if button.pressed else _end_stroke()
	elif event is InputEventMouseMotion:
		handled = _drag((event as InputEventMouseMotion).position)
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and _touch_index < 0 and _press(touch.position):
			_touch_index = touch.index
			handled = true
		elif not touch.pressed and touch.index == _touch_index:
			_touch_index = -1
			handled = _release()
	elif event is InputEventScreenDrag and (event as InputEventScreenDrag).index == _touch_index:
		handled = _drag((event as InputEventScreenDrag).position)
	if handled:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_stroke_velocity = ((_stroke_point - _stroke_previous) / maxf(delta, 1e-4)).limit_length(push_mps)
	_stroke_previous = _stroke_point


## The push stroke as one solver source, applied on every substep while it lasts,
## so its strength does not depend on how many substeps a frame runs.
func pack_source() -> PackedFloat32Array:
	if _pushing and _stroke_velocity.length() > 0.05:
		return SmokeSolver.pack_source(_stroke_point, Vector3.ONE * radius_m, 0.0, 0.0,
			_stroke_velocity, PUSH_RELAX_HZ)
	return PackedFloat32Array()


func _physics_process(_delta: float) -> void:
	if _held == null:
		return
	if not is_instance_valid(_held):
		_held = null
		return
	_held.apply_central_force((_grab_target - _held.global_position) * 40.0 * _held.mass
		- _held.linear_velocity * 8.0 * _held.mass - _held.get_gravity() * _held.mass)


func _press(screen_pos: Vector2) -> bool:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + dir * 200.0))
	if not hit.is_empty() and props.is_grabbable(hit.collider):
		_held = hit.collider
		_grab_distance = from.distance_to(hit.position)
		_grab_target = _held.global_position
		return true
	return blow and _begin_stroke(screen_pos)


func _begin_stroke(screen_pos: Vector2) -> bool:
	if not _project(screen_pos):
		return false
	_pushing = true
	_stroke_previous = _stroke_point
	return true


func _release() -> bool:
	var held := _held != null
	_held = null
	return _end_stroke() or held


func _end_stroke() -> bool:
	var engaged := _pushing
	_pushing = false
	return engaged


func _drag(screen_pos: Vector2) -> bool:
	if _held != null:
		_grab_target = camera.project_ray_origin(screen_pos) \
			+ camera.project_ray_normal(screen_pos) * _grab_distance
		_grab_target.y = maxf(_grab_target.y, 0.05)
		return true
	if _pushing:
		_project(screen_pos)
		return true
	return false


## Hit of the screen ray on the camera-facing plane through focus_m.
func _project(screen_pos: Vector2) -> bool:
	var hit = splat_hit(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos),
		focus_m, -camera.global_basis.z)
	if hit == null:
		return false
	_stroke_point = hit
	return true


## Ray / plane intersection, null when the ray is parallel or points away.
static func splat_hit(origin: Vector3, direction: Vector3, plane_point: Vector3,
		plane_normal: Vector3) -> Variant:
	var denom := direction.dot(plane_normal)
	if absf(denom) < 1e-6:
		return null
	var t := (plane_point - origin).dot(plane_normal) / denom
	return origin + direction * t if t > 0.0 else null
