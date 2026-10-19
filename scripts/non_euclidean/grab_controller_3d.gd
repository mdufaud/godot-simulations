class_name GrabController3D extends RefCounted
## Superliminal-style grip: a held [class GripBall] keeps its grabbed angular
## size ([code]ratio * distance[/code]) and sits where its view cone first meets
## something. Release commits exactly what is on screen.
##
## Driven by the host: [method try_grab] on the grab action, [method
## physics_update] every physics frame, [method release] on action release,
## [method aim_target] while idle for the crosshair hint.

const HOLD_REACH := 4.5
const RESOLVE_REACH := 40.0
const MIN_FIT_DISTANCE := 0.3
const FIT_GROWTH := 1.15
const FIT_REFINE_STEPS := 4
const SURFACE_GAP := 0.02

## The ball currently held, or null.
var held_body: GripBall = null

var _camera: Camera3D
## Radius over eye distance at grab time: the angular size the hold preserves.
var _ratio := 0.2
var _mask := 1
var _exclude: Array[RID] = []
var _probe := SphereShape3D.new()


## Picks the grip ball under the crosshair within reach. Returns
## [code]false[/code] when nothing grabbable is aimed at, or when already
## holding.
func try_grab(camera: Camera3D, mask: int, exclude: Array[RID]) -> bool:
	if held_body != null:
		return false
	var body := _view_ray(camera, HOLD_REACH, mask, exclude).get("collider") as GripBall
	if body == null:
		return false
	held_body = body
	_camera = camera
	_mask = mask
	# Rays and probes must skip the held ball; the list is fixed at create() time.
	_exclude = exclude.duplicate()
	_exclude.append(body.get_rid())
	_ratio = body.display_radius() / camera.global_position.distance_to(body.global_position)
	body.begin_hold()
	_project()
	return true


func physics_update(camera: Camera3D) -> void:
	if held_body == null:
		return
	_camera = camera
	_project()


## The grip ball under the crosshair within reach, or null.
func aim_target(camera: Camera3D, mask: int, exclude: Array[RID]) -> GripBall:
	if held_body != null:
		return null
	return _view_ray(camera, HOLD_REACH, mask, exclude).get("collider") as GripBall


func release() -> void:
	if held_body == null:
		return
	held_body.commit_scale(_ratio * _project())
	held_body.end_hold()
	held_body = null


## Past [constant GripBall.RADIUS_MAX] the ball sits closer instead of popping.
func _project() -> float:
	var distance := _fit_distance(minf(RESOLVE_REACH, GripBall.RADIUS_MAX / _ratio))
	held_body.place_at(_view_point(distance))
	held_body.set_display_radius(_ratio * distance)
	return distance


## Grows the ball outward from the eye until it would touch something, so
## nothing ever stands between a held ball and the eye.
func _fit_distance(max_distance: float) -> float:
	var hit := _view_ray(_camera, max_distance * (1.0 + _ratio), _mask, _exclude)
	if not hit.is_empty():
		var surface := _camera.global_position.distance_to(hit.position) - SURFACE_GAP
		max_distance = minf(max_distance, surface / (1.0 + _ratio))
	var clear := MIN_FIT_DISTANCE
	var blocked := INF
	while clear < max_distance:
		var next := minf(clear * FIT_GROWTH, max_distance)
		if _overlaps(next):
			blocked = next
			break
		clear = next
	if is_inf(blocked):
		return clear
	for _step in FIT_REFINE_STEPS:
		var middle := (clear + blocked) * 0.5
		if _overlaps(middle):
			blocked = middle
		else:
			clear = middle
	return clear


func _overlaps(distance: float) -> bool:
	_probe.radius = _ratio * distance
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _probe
	query.transform = Transform3D(Basis.IDENTITY, _view_point(distance))
	query.collision_mask = _mask
	query.exclude = _exclude
	return not _camera.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _view_point(distance: float) -> Vector3:
	return _camera.global_position - _camera.global_basis.z * distance


func _view_ray(camera: Camera3D, length: float, mask: int, exclude: Array[RID]) -> Dictionary:
	var origin := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(origin,
		origin - camera.global_basis.z * length, mask, exclude)
	return camera.get_world_3d().direct_space_state.intersect_ray(query)
