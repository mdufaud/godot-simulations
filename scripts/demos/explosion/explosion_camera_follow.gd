class_name ExplosionCameraFollow extends Node

const TOP_FILL := 0.8
## Height of the target in the box, floor to top, when the camera tracks the fireball.
const LOW_WEIGHT := 0.5
const MIN_TARGET_HALF_VIEW := 0.45
const MOVE_ACTIONS: Array[StringName] = [&"move_forward", &"move_back", &"move_left", &"move_right"]

var orbit: OrbitCamera
var camera: Camera3D
var volume: MeshInstance3D
var system: ExplosionSystem
var home_target_y := 0.0
var rate_per_s := 1.2
## Track the cloud's top (the cap) instead of the fireball low in the box.
var follow_top := false
## Aim at the middle of the cloud's box, not at the latest detonation: a chain of charges.
var follow_box := false

var _following := false
var _origin_xz := Vector3.ZERO


func start() -> void:
	assert(orbit != null and camera != null and volume != null and system != null)
	system.detonated.connect(_on_detonated)


func is_following() -> bool:
	return _following


func stop() -> void:
	_following = false


func _on_detonated(origin: Vector3, _charge: ExplosionCharge) -> void:
	_following = true
	_origin_xz = Vector3(origin.x, 0.0, origin.z)


## The follow lasts as long as the cloud: any camera input of the user (drag, wheel, touch, move keys) ends it.
func _unhandled_input(event: InputEvent) -> void:
	var drag := event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask != 0
	var wheel := event is InputEventMouseButton and (event as InputEventMouseButton).button_index in [
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
	var touch := event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed
	var gesture := event is InputEventMagnifyGesture or event is InputEventPanGesture
	if drag or wheel or touch or gesture or event is InputEventScreenDrag:
		stop()


## Eases the orbit target to the resident-tile box: low in it for a fireball, its top for a rising cap.
func _process(delta: float) -> void:
	if not _following:
		return
	for action in MOVE_ACTIONS:
		if Input.is_action_pressed(action):
			stop()
			return
	var size_m := (volume.mesh as BoxMesh).size
	if size_m.y <= 0.0:
		return
	var dt := system.step_s(delta)
	var centre := volume.position
	var bottom_m := centre.y - size_m.y * 0.5
	var top_m := centre.y + size_m.y * 0.5
	var half_view_m := orbit.distance * tan(deg_to_rad(camera.fov) * 0.5)
	var goal_y := lerpf(bottom_m, top_m, LOW_WEIGHT)
	if follow_top:
		goal_y = top_m - half_view_m * TOP_FILL
	goal_y = maxf(goal_y, minf(home_target_y, half_view_m * MIN_TARGET_HALF_VIEW))
	var anchor_xz := Vector3(centre.x, 0.0, centre.z) if follow_box else _origin_xz
	var goal := anchor_xz + Vector3(0.0, goal_y, 0.0)
	orbit.target = orbit.target.lerp(goal, 1.0 - exp(-rate_per_s * dt))
