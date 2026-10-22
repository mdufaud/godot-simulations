class_name SmokePointer extends Node
## Mouse and touch for the smoke demo. Added after the camera, so it sees each
## unhandled event first: a press on a Jolt body grabs it, a press on empty space
## runs the brush (Orbit leaves it to the camera). Right drag pushes the smoke,
## Shift + right drag injects it, whatever the brush.

enum Brush { ORBIT, PUSH, INJECT }

const BRUSH_NAMES := ["Orbit", "Push", "Inject"]
const INJECT_HEAT_K_PER_S := 20.0
const PUSH_RELAX_HZ := 30.0

var camera: Camera3D
var props: SmokeProps
## Centre of the camera-facing plane the brush paints on.
var focus_m := Vector3.ZERO
var brush := Brush.ORBIT
var radius_m := 0.4
var push_mps := 6.0
var inject_per_s := 8.0

var _held: RigidBody3D
var _grab_distance := 0.0
var _grab_target := Vector3.ZERO
var _stroke := Brush.ORBIT
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
			handled = _press(button.position, brush) if button.pressed else _release()
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			handled = _begin_stroke(button.position,
				Brush.INJECT if button.shift_pressed else Brush.PUSH) if button.pressed else _end_stroke()
	elif event is InputEventMouseMotion:
		handled = _drag((event as InputEventMouseMotion).position)
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and _touch_index < 0 and _press(touch.position, brush):
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


## The brush as one solver source, applied on every substep while the stroke lasts,
## so its rate does not depend on how many substeps a frame runs.
func pack_source() -> PackedFloat32Array:
	if _stroke == Brush.PUSH and _stroke_velocity.length() > 0.05:
		return SmokeSolver.pack_source(_stroke_point, Vector3.ONE * radius_m, 0.0, 0.0,
			_stroke_velocity, PUSH_RELAX_HZ)
	if _stroke == Brush.INJECT:
		return SmokeSolver.pack_source(_stroke_point, Vector3.ONE * radius_m, inject_per_s,
			INJECT_HEAT_K_PER_S, Vector3.ZERO, 0.0)
	return PackedFloat32Array()


func _physics_process(_delta: float) -> void:
	if _held == null:
		return
	if not is_instance_valid(_held):
		_held = null
		return
	_held.apply_central_force((_grab_target - _held.global_position) * 40.0 * _held.mass
		- _held.linear_velocity * 8.0 * _held.mass - _held.get_gravity() * _held.mass)


func _press(screen_pos: Vector2, mode: Brush) -> bool:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(from, from + dir * 200.0))
	if not hit.is_empty() and props.is_grabbable(hit.collider):
		_held = hit.collider
		_grab_distance = from.distance_to(hit.position)
		_grab_target = _held.global_position
		return true
	return mode != Brush.ORBIT and _begin_stroke(screen_pos, mode)


func _begin_stroke(screen_pos: Vector2, mode: Brush) -> bool:
	if not _project(screen_pos):
		return false
	_stroke = mode
	_stroke_previous = _stroke_point
	return true


func _release() -> bool:
	var held := _held != null
	_held = null
	return _end_stroke() or held


func _end_stroke() -> bool:
	var engaged := _stroke != Brush.ORBIT
	_stroke = Brush.ORBIT
	return engaged


func _drag(screen_pos: Vector2) -> bool:
	if _held != null:
		_grab_target = camera.project_ray_origin(screen_pos) \
			+ camera.project_ray_normal(screen_pos) * _grab_distance
		_grab_target.y = maxf(_grab_target.y, 0.05)
		return true
	if _stroke != Brush.ORBIT:
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
