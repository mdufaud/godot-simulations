class_name GrabController3D extends RefCounted
## Superliminal-style grip: a raycast picks a [class GripBall], freezes it
## kinematically and keeps its angular size constant while held. The real size
## resolves at the discrete events only, from the distance of the surface
## involved — put down against the far wall the ball becomes huge, dropped on
## the floor at the feet it stays tiny. A wall closer than the hold point
## resolves the same way while still held. Collision, mass and CCD only move at
## those events, never per frame on a free body.
##
## Driven by the host: [method try_grab] on the grab action, [method
## physics_update] every physics frame, [method release] on action release.
##
##     var grab := GrabController3D.new()
##     if grab.try_grab(camera, 1, [player.get_rid()]):
##         grab.physics_update(camera)

const HOLD_REACH := 3.2
const MIN_HOLD_DISTANCE := 0.9
## The contact probe reaches a hair past the ball surface, so grazing surfaces
## still resolve instead of jittering one frame before the meet.
const CONTACT_MARGIN := 0.08
## How far a put-down can look for the surface it resolves against.
const RESOLVE_REACH := 40.0

## The ball currently held, or null.
var held_body: GripBall = null

var _camera: Camera3D
var _hold_distance := 2.0
var _grab_distance := 2.0
var _mask := 1
var _exclude: Array[RID] = []


## Casts the view ray and picks the first grip ball within reach. Returns
## [code]false[/code] when nothing grabbable is aimed at, or when already
## holding.
func try_grab(camera: Camera3D, mask: int, exclude: Array[RID]) -> bool:
	if held_body != null:
		return false
	var origin := camera.global_position
	var direction := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin,
		origin + direction * HOLD_REACH, mask, exclude)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var body := hit.collider as GripBall
	if body == null:
		return false
	held_body = body
	_camera = camera
	_mask = mask
	_exclude = exclude
	held_body.begin_hold()
	_grab_distance = origin.distance_to(hit.position)
	_hold_distance = clampf(_grab_distance, MIN_HOLD_DISTANCE, HOLD_REACH)
	held_body.set_display_radius(ApparentScale.hold_radius(
		held_body.base_radius(), _grab_distance, _hold_distance))
	return true


## Keeps the ball on the view ray at the hold distance with its angular size
## frozen (mesh child only), and resolves the size when the held ball meets a
## surface closer than the hold point.
func physics_update(camera: Camera3D) -> void:
	if held_body == null:
		return
	_camera = camera
	var origin := camera.global_position
	var direction := -camera.global_basis.z
	var radius := held_body.display_radius()
	var desired := _hold_distance
	var reach := desired + radius + CONTACT_MARGIN
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * reach,
		_mask, _exclude)
	query.exclude.append(held_body.get_rid())
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	# intersect_ray carries no distance key; measure from the eye along the ray.
	var hit_distance := origin.distance_to(hit.position) if not hit.is_empty() else -1.0
	if hit_distance >= 0.0 and hit_distance < desired + radius + CONTACT_MARGIN:
		# A wall closer than the hold point: press the ball against it and let
		# its apparent size at that distance become its real size.
		_hold_to(camera, maxf(hit_distance - radius, MIN_HOLD_DISTANCE))
		_resolve(hit_distance)
		held_body.end_hold()
		held_body = null
		return
	_hold_to(camera, desired)
	held_body.set_display_radius(ApparentScale.hold_radius(
		held_body.base_radius(), _grab_distance, desired))


## Puts the held ball down onto the surface under the crosshair, at the size it
## appeared to have at that surface's distance. With nothing in reach the ball
## keeps its in-hand size and drops where it is.
func release() -> void:
	if held_body == null:
		return
	if not _resolve_along_ray():
		_resolve(_hold_distance)
	held_body.end_hold()
	held_body = null


func _hold_to(camera: Camera3D, distance: float) -> void:
	var origin := camera.global_position
	var direction := -camera.global_basis.z
	held_body.hold_to(origin + direction * distance)


## Commits the apparent size at [param distance] — the only door to collision,
## mass and CCD.
func _resolve(distance: float) -> void:
	held_body.commit_scale(ApparentScale.hold_radius(
		held_body.base_radius(), _hold_distance, distance))


func _resolve_along_ray() -> bool:
	if _camera == null:
		return false
	var origin := _camera.global_position
	var direction := -_camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin,
		origin + direction * RESOLVE_REACH, _mask, _exclude)
	query.exclude.append(held_body.get_rid())
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	_resolve(origin.distance_to(hit.position))
	held_body.place_at(hit.position + hit.normal * (held_body.display_radius() + 0.02))
	return true
