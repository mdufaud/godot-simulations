extends "res://tests/test_case.gd"
## Integration tests for the grip exhibit over real physics: a ball at spawn
## range must be grabbable, a held ball must stay held frame after frame, and
## the size must only resolve at the discrete events. Runs under --headless —
## it needs Jolt rays, not pixels.

const DEMO_SCENE := preload("res://scenes/non_euclidean_demo.tscn")

var demo: Node3D
var player: NonEuclideanPlayer
var grab: GrabController3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed_scene := load("res://scenes/non_euclidean_demo.tscn") as PackedScene
	_check(packed_scene != null, "demo scene cannot be loaded")
	if packed_scene == null:
		_finish("grab_controller")
		return
	demo = packed_scene.instantiate()
	root.add_child(demo)
	await process_frame
	await physics_frame
	player = demo.get_node("Player") as NonEuclideanPlayer
	grab = demo._grab
	demo._go_to_case(4)
	await physics_frame

	await _test_spawn_range_grab()
	await _test_held_ball_stays_held()
	await _test_nothing_behind_wall_is_grabbable()
	await _test_release_commits_surface_size()
	await _test_wall_press_stays_clear()
	await _test_floor_grab_stays_held()
	await _test_regrab_keeps_apparent_size()
	await _test_corner_release_is_clear()
	await _test_cone_stops_at_first_obstruction()
	_finish("grab_controller")


## Puts the player at [param local_position] in the grip room and turns the
## camera onto [param ball].
func _aim_at_ball(ball: GripBall, local_position: Vector3) -> void:
	var room := demo.get_node("Cells/GripRoom") as Node3D
	player.set_pose(Transform3D(Basis.IDENTITY, room.to_global(local_position)))
	var camera := player.get_camera()
	var direction := (ball.global_position - camera.global_position).normalized()
	var yaw := atan2(-direction.x, -direction.z)
	player.global_basis = Basis(Vector3.UP, yaw).orthonormalized()
	(player.get_node("CameraPivot") as Node3D).rotation.x = asin(direction.y)
	await physics_frame


## From the spawn pose the near ball sits just inside reach: the exhibit must be
## playable without first walking a blind stretch, and the crosshair hint must
## agree.
func _test_spawn_range_grab() -> void:
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(0.0, 0.9, 5.5))
	var exclude: Array[RID] = [player.get_rid()]
	_check(grab.aim_target(player.get_camera(), 1, exclude) == ball,
		"near ball at spawn range is not the aim target")
	_check(grab.try_grab(player.get_camera(), 1, exclude),
		"near ball at spawn range cannot be grabbed")
	_check(grab.held_body == ball, "try_grab reported success without holding the ball")


## The hold must survive dozens of physics frames: any per-frame resolution in
## the open air breaks the exhibit.
func _test_held_ball_stays_held() -> void:
	var ball: GripBall = demo._grip.props[0]
	var grabbed_radius := ball.display_radius()
	for _frame in 60:
		await physics_frame
	_check(grab.held_body == ball, "held ball was dropped while in the open air")
	_check(absf(ball.display_radius() - grabbed_radius) < 0.001,
		"held ball size drifted in the open air")


## Rays that end on a wall must not pick anything.
func _test_nothing_behind_wall_is_grabbable() -> void:
	grab.release()
	var room := demo.get_node("Cells/GripRoom") as Node3D
	player.set_pose(Transform3D(Basis.IDENTITY, room.to_global(Vector3(0.0, 0.9, 5.5))))
	await physics_frame
	var exclude: Array[RID] = [player.get_rid()]
	_check(not grab.try_grab(player.get_camera(), 1, exclude),
		"something was grabbed while aiming at a bare wall")
	_check(grab.held_body == null, "wall grab left a body held")


## Releasing onto a farther surface commits the apparent size at that surface —
## grab close, place far, it grows.
func _test_release_commits_surface_size() -> void:
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(0.0, 0.9, 5.5))
	var exclude: Array[RID] = [player.get_rid()]
	if not grab.try_grab(player.get_camera(), 1, exclude):
		_check(false, "regrab for the release test failed")
		return
	var base := ball.base_radius()
	player.global_basis = Basis.IDENTITY
	(player.get_node("CameraPivot") as Node3D).rotation.x = 0.0
	await physics_frame
	grab.release()
	_check(grab.held_body == null, "release did not let go")
	_check(ball.display_radius() > base + 0.01,
		"ball placed against the far wall did not grow")
	_check(absf(ball.global_position.distance_to(player.global_position)) > 3.0,
		"released ball did not land at the aimed surface")


## Walking the held ball into the solid side wall keeps it held and in front of
## the wall: it shrinks with the distance instead of clipping or dropping.
func _test_wall_press_stays_clear() -> void:
	demo._grip.reset()
	await physics_frame
	var room := demo.get_node("Cells/GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(-1.0, 0.9, 4.2))
	var exclude: Array[RID] = [player.get_rid()]
	if not grab.try_grab(player.get_camera(), 1, exclude):
		_check(false, "near ball cannot be grabbed for the wall press test")
		return
	player.global_basis = Basis(Vector3.UP, PI * 0.5).orthonormalized()
	(player.get_node("CameraPivot") as Node3D).rotation.x = 0.0
	var deepest := INF
	for _frame in 60:
		player.global_position -= player.global_basis.z * 0.05
		await physics_frame
		deepest = minf(deepest, room.to_local(ball.global_position).x - ball.display_radius())
	_check(grab.held_body == ball, "ball pressed against the side wall was dropped")
	_check(deepest >= -ExhibitGripRoom.ROOM.x * 0.5 - 0.03,
		"held ball clipped into the side wall (deepest %.3f)" % deepest)
	grab.release()
	demo._grip.reset()


## A ball resting on the floor is grabbed looking down at it: the floor behind
## it must not knock it out of the hand.
func _test_floor_grab_stays_held() -> void:
	demo._grip.reset()
	await physics_frame
	var room := demo.get_node("Cells/GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(-2.6, 0.9, 4.2))
	var exclude: Array[RID] = [player.get_rid()]
	_check(grab.try_grab(player.get_camera(), 1, exclude), "floor ball cannot be grabbed")
	var lowest := INF
	for _frame in 30:
		await physics_frame
		lowest = minf(lowest, room.to_local(ball.global_position).y - ball.display_radius())
	_check(grab.held_body == ball, "floor ball fell out of the hand while looking down")
	_check(lowest >= -0.03, "held floor ball clipped into the floor (lowest %.3f)" % lowest)
	grab.release()
	demo._grip.reset()


## Re-grabbing a grown ball keeps the angular size it has on screen, never the
## size it was built with.
func _test_regrab_keeps_apparent_size() -> void:
	demo._grip.reset()
	await physics_frame
	var room := demo.get_node("Cells/GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	ball.commit_scale(1.6)
	ball.place_at(room.to_global(Vector3(0.0, 1.6, -2.0)))
	await _aim_at_ball(ball, Vector3(0.0, 0.9, 3.0))
	var eye := player.get_camera().global_position
	var before := ball.display_radius() / eye.distance_to(ball.global_position)
	var exclude: Array[RID] = [player.get_rid()]
	_check(grab.try_grab(player.get_camera(), 1, exclude), "grown ball cannot be grabbed")
	for _frame in 20:
		await physics_frame
	var after := ball.display_radius() / eye.distance_to(ball.global_position)
	_check(absf(after - before) <= before * 0.02,
		"re-grab changed the apparent size (%.3f -> %.3f)" % [before, after])
	_check(ball.display_radius() > ball.base_radius() * 2.0,
		"re-grab snapped the grown ball back toward its built size")
	grab.release()
	demo._grip.reset()


## Aimed just over the shelf ball at the alcove, the held ball stops in front of
## the shelf ball its cone grazes instead of hopping behind it: nothing may
## stand between a held ball and the eye.
func _test_cone_stops_at_first_obstruction() -> void:
	demo._grip.reset()
	await physics_frame
	var room := demo.get_node("Cells/GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(0.0, 0.9, 5.5))
	var exclude: Array[RID] = [player.get_rid()]
	if not grab.try_grab(player.get_camera(), 1, exclude):
		_check(false, "near ball cannot be grabbed for the cone test")
		return
	var camera := player.get_camera()
	var direction := (room.to_global(Vector3(0.0, 2.9, -12.0)) - camera.global_position).normalized()
	player.global_basis = Basis(Vector3.UP, atan2(-direction.x, -direction.z)).orthonormalized()
	(player.get_node("CameraPivot") as Node3D).rotation.x = asin(direction.y)
	await physics_frame
	var held_z := room.to_local(ball.global_position).z
	_check(held_z > -6.5, "held ball hopped behind the shelf ball (z %.2f)" % held_z)
	grab.release()
	demo._grip.reset()


## Releasing toward a floor-wall corner lands the ball clear of both: no
## overlap for the solver to resolve with a kick.
func _test_corner_release_is_clear() -> void:
	demo._grip.reset()
	await physics_frame
	var room := demo.get_node("Cells/GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(-1.4, 0.9, 4.6))
	var exclude: Array[RID] = [player.get_rid()]
	if not grab.try_grab(player.get_camera(), 1, exclude):
		_check(false, "near ball cannot be grabbed for the corner test")
		return
	var camera := player.get_camera()
	var corner := room.to_global(Vector3(-ExhibitGripRoom.ROOM.x * 0.5, 0.0, -6.0))
	var direction := (corner - camera.global_position).normalized()
	player.global_basis = Basis(Vector3.UP, atan2(-direction.x, -direction.z)).orthonormalized()
	(player.get_node("CameraPivot") as Node3D).rotation.x = asin(direction.y)
	await physics_frame
	grab.release()
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = ball.display_radius() * 0.98
	query.shape = sphere
	query.transform = ball.global_transform
	query.exclude = [ball.get_rid(), player.get_rid()]
	var overlaps := ball.get_world_3d().direct_space_state.intersect_shape(query, 4)
	_check(overlaps.is_empty(), "corner release left the ball overlapping the room")
	_check(ball.display_radius() <= GripBall.RADIUS_MAX + 0.001,
		"corner release committed past the size bound")
	var top_speed := 0.0
	for _frame in 30:
		await physics_frame
		top_speed = maxf(top_speed, ball.linear_velocity.length())
	_check(top_speed < 6.0, "corner release kicked the ball (%.2f m/s)" % top_speed)
	demo._grip.reset()
