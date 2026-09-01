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
	await _test_wall_press_resolves()
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
	grab.release()
	_check(grab.held_body == null, "release did not let go")
	_check(ball.display_radius() > base + 0.01,
		"ball placed on the farther floor did not grow")
	_check(absf(ball.global_position.distance_to(player.global_position)) > 3.0,
		"released ball did not land at the aimed surface")


## Walking the held ball into the solid side wall resolves it on contact
## instead of clipping. The far wall has a full-height opening, so the side
## wall is the honest press target.
func _test_wall_press_resolves() -> void:
	demo._grip.reset()
	await physics_frame
	var ball: GripBall = demo._grip.props[0]
	await _aim_at_ball(ball, Vector3(-1.0, 0.9, 4.2))
	var exclude: Array[RID] = [player.get_rid()]
	if not grab.try_grab(player.get_camera(), 1, exclude):
		_check(false, "near ball cannot be grabbed for the wall press test")
		return
	var committed := ball.display_radius()
	player.global_basis = Basis(Vector3.UP, -PI * 0.5).orthonormalized()
	(player.get_node("CameraPivot") as Node3D).rotation.x = 0.0
	for _frame in 240:
		player.global_position -= player.global_basis.z * 0.05
		await physics_frame
		if grab.held_body == null:
			break
	_check(grab.held_body == null, "ball pressed against the side wall never resolved")
	_check(absf(ball.display_radius() - committed) > 0.01,
		"wall press resolved without committing a size")
	demo._grip.reset()
