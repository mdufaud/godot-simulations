extends "res://tests/test_case.gd"
## Integration tests for the non-euclidean demo: portal traversal, the infinite
## staircase, spherical curvature and the shared input contract. Needs a real GPU
## (SubViewport portal targets), so it does not run under --headless.
##
## Assertions here must describe player-visible behaviour. Node names, child counts,
## exact scene coordinates and renderer configuration are deliberately not asserted:
## they break on every legitimate refactor without catching a single real bug. Portal
## image correctness is covered by tools/capture_non_euclidean.gd.

const PortalMathScript := preload("res://scripts/non_euclidean/portal_math.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# The suite drives the player through real input actions, so stray keystrokes in
	# the focused window would cancel them. Never take focus.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	await _test_scene_integration()
	_finish("non_euclidean")


func _test_scene_integration() -> void:
	var initial_root_size := root.size
	root.size = _root_size(Vector2i(1920, 1080))
	var packed_scene := load("res://scenes/non_euclidean_demo.tscn") as PackedScene
	_check(packed_scene != null, "demo scene cannot be loaded")
	if packed_scene == null:
		return
	var initial_scaling_mode := root.scaling_3d_mode
	var initial_scaling_scale := root.scaling_3d_scale
	var demo := packed_scene.instantiate()
	root.add_child(demo)
	await process_frame
	await physics_frame

	var cells := demo.get_node("Cells") as Node3D
	var player := demo.get_node("Player") as NonEuclideanPlayer
	var manager := demo.get_node("PortalRenderManager") as PortalRenderManager
	var source := cells.get_node("ReserveCourtyard/ReserveExpansion") as Portal3D
	var destination := cells.get_node("ImpossibleReserve/ReserveReturn") as Portal3D

	player.set_pose(Transform3D(Basis.IDENTITY,
		destination.to_global(Vector3(0.0, -0.8, 0.25))))
	for _frame in 30:
		await physics_frame
	_check(player.global_position.y >= 0.87,
		"player falls through the reserve doorway threshold")

	player.set_pose(_aimed_pose(source, Vector3(0.0, -0.8, 10.0)))
	manager._process(0.0)
	var source_camera := manager._slots[0]["camera"] as Camera3D
	_check(source_camera.near > 9.9, "distant portal camera does not clip at doorway plane")
	_check(manager.active_view_count == 1, "visible reserve portal is not active")
	player.set_pose(_aimed_pose(source, Vector3(0.0, -0.8, 0.004)))
	manager._process(0.0)
	_check(is_equal_approx(source_camera.near, PortalRenderManager.MIN_NEAR),
		"near portal view clips before traversal")
	player.set_pose(Transform3D(Basis(Vector3.UP, PI),
		source.to_global(Vector3(0.0, -0.8, 10.0))))
	manager._process(0.0)
	_check(manager.active_view_count == 0, "portal renders while fully behind player")
	_check(source._surface_material.get_shader_parameter("portal_texture") != null,
		"offscreen culling clears live texture and creates a black first frame")

	await _test_portal_traversal(player, source, destination)
	await _test_rigid_body_traversal(demo, source, destination)
	await _test_staircase(demo, player, cells)
	await _test_spherical_curvature(demo, player, cells)
	await _test_growing_corridor(demo, player, cells)
	await _test_grip_room(demo, player, cells)
	await _test_wrap_world(demo, player, cells)
	await _test_holonomy_loop(demo, player, cells)
	_test_existing_input_contract()
	await _test_player_input(player)

	demo.queue_free()
	await process_frame
	_check(root.scaling_3d_mode == initial_scaling_mode,
		"demo did not restore viewport scaling mode")
	_check(is_equal_approx(root.scaling_3d_scale, initial_scaling_scale),
		"demo did not restore viewport scaling scale")
	root.size = initial_root_size


func _test_portal_traversal(player: NonEuclideanPlayer, source: Portal3D,
		destination: Portal3D) -> void:
	player.set_pose(Transform3D(Basis.IDENTITY, source.to_global(Vector3(0.0, -0.8, -0.05))))
	player._portal_previous_position = source.to_global(Vector3(0.0, -0.8, 0.05))
	var expected := PortalMathScript.map_transform(source.get_mapping(), player.global_transform)
	expected.origin += destination.get_normal() * NonEuclideanPlayer.PORTAL_EXIT_EPSILON
	source._physics_process(0.0)
	_check(player.global_position.distance_to(expected.origin) <= 0.00001,
		"player traversal did not map position")
	_check(player._portal_lock == destination, "arrival portal was not locked")
	var after_first_crossing := player.global_transform
	destination._physics_process(0.0)
	_check(player.global_position.distance_to(after_first_crossing.origin) <= 0.000001,
		"player ping-ponged through arrival portal")
	await physics_frame
	_check(player._portal_lock == null, "arrival portal remains locked after safe arrival")
	player._portal_previous_position = destination.to_global(Vector3(0.0, -0.8, 0.05))
	player.global_position = destination.to_global(Vector3(0.0, -0.8, -0.05))
	var expected_return := PortalMathScript.map_transform(destination.get_mapping(),
		player.global_transform)
	expected_return.origin += source.get_normal() * NonEuclideanPlayer.PORTAL_EXIT_EPSILON
	destination._physics_process(0.0)
	_check(player.global_position.distance_to(expected_return.origin) <= 0.00001,
		"player cannot reverse through arrival portal")


func _test_rigid_body_traversal(demo: Node3D, source: Portal3D,
		destination: Portal3D) -> void:
	demo._reserve.reset()
	var crate := demo._reserve.props[0] as PortalRigidBody3D
	var launch_velocity := -source.get_normal() * 20.0
	crate.global_transform = Transform3D(Basis.IDENTITY,
		source.to_global(Vector3(0.0, -1.2, -0.1)))
	crate.linear_velocity = launch_velocity
	crate.angular_velocity = Vector3(1.5, -2.0, 3.5)
	crate.gravity_vector = Vector3.ZERO
	crate.sleeping = false
	crate._portal_previous_position = source.to_global(Vector3(0.0, -1.2, 0.1))
	source._physics_process(0.0)
	_check(crate._has_pending_teleport, "crate crossing did not queue physics transfer")
	await physics_frame
	_check(crate._portal_lock == destination, "crate did not cross reserve portal")
	_check(crate.global_position.distance_to(destination.global_position) < 10.0,
		"crate did not arrive in impossible interior")
	_check(crate.linear_velocity.normalized().dot(source.map_vector(launch_velocity).normalized()) >= 0.999,
		"crate velocity was not mapped")
	demo._reserve.reset()


func _test_staircase(demo: Node3D, player: NonEuclideanPlayer, cells: Node3D) -> void:
	demo._go_to_case(1)
	var stair := cells.get_node("InfiniteStaircase") as Node3D
	var loop_seal := stair.get_node("LoopSeal") as Node3D
	var ground_level := stair.get_node("GroundLevel") as Node3D
	var fill_light := player.get_node("StairFillLight") as OmniLight3D
	_check(fill_light.visible, "player-relative stair light is disabled inside staircase")
	_check(fill_light.get_parent() == player, "stair lighting does not follow recycled player pose")
	# Every drawn tread sits within half a riser of the ramp the player walks, and
	# every flight but the based first turn is opaque from below.
	var space := stair.get_world_3d().direct_space_state
	for child in stair.get_children():
		if not child.has_meta("infinite_stair_ramp"):
			continue
		var steps := child.get_node("Steps") as MeshInstance3D
		var faces := steps.mesh.generate_triangle_mesh()
		var module := floori((steps.get_aabb().position.y + 0.5) / ExhibitStaircase.PERIOD)
		var base_y := float(module) * ExhibitStaircase.PERIOD
		for sample in 40:
			var turn := (float(sample) + 0.37) * TAU / 40.0
			var angle := ExhibitStaircase.START_ANGLE + turn
			for radius in [2.2, ExhibitStaircase.CENTER_RADIUS, 4.3]:
				var at := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
				var walk_line := base_y + ExhibitStaircase.PERIOD * turn / TAU
				var above := at + Vector3.UP * (walk_line + 1.0)
				var tread := faces.intersect_ray(above, Vector3.DOWN)
				var ramp := space.intersect_ray(PhysicsRayQueryParameters3D.create(
					stair.to_global(above), stair.to_global(above + Vector3.DOWN * 2.0)))
				_check(not tread.is_empty() and _front_normal(faces, tread).y > 0.9 \
					and not ramp.is_empty() \
					and absf(tread["position"].y - stair.to_local(ramp["position"]).y) \
						<= ExhibitStaircase.RISE * 0.5 + 0.02,
					"stair tread at %.0f° of flight %d strays from the walked ramp" % [
						rad_to_deg(turn), module])
				if module == 0 and turn < float(ExhibitStaircase.BASE_STEPS) * TAU \
						/ float(ExhibitStaircase.STEPS):
					continue
				var under := faces.intersect_ray(at + Vector3.UP * (walk_line - 1.0), Vector3.UP)
				_check(not under.is_empty() and _front_normal(faces, under).y < -0.5,
					"stair flight %d is transparent from below at %.0f°" % [module,
						rad_to_deg(turn)])
	_check(not loop_seal.visible, "ground-floor corridor does not start open")
	player.capture_mouse()
	for _frame in 45:
		Input.action_press("move_forward")
		await physics_frame
	Input.action_release("move_forward")
	var corridor_position := stair.to_local(player.global_position)
	_check(corridor_position.z < 7.0 and corridor_position.y >= 0.87,
		"ground-floor corridor does not lead safely into the staircase")
	player.set_pose(Transform3D(Basis.IDENTITY,
		stair.to_global(Vector3(0.0, 0.95, ExhibitStaircase.CENTER_RADIUS))))
	var walk_start := stair.to_local(player.global_position)
	for _frame in 180:
		Input.action_press("move_forward")
		var local_position := stair.to_local(player.global_position)
		var radial := Vector3(local_position.x, 0.0, local_position.z).normalized()
		var tangent := Vector3(-radial.z, 0.0, radial.x)
		player.global_basis = _basis_from_forward(tangent)
		await physics_frame
	Input.action_release("move_forward")
	var walk_end := stair.to_local(player.global_position)
	var walk_radius := Vector2(walk_end.x, walk_end.z).length()
	_check(walk_end.y > walk_start.y + 2.0, "player cannot walk up helical staircase")
	_check(walk_radius > 2.0 and walk_radius < 4.6,
		"player escaped the enclosed helical staircase")
	var phase := Vector3(0.0, ExhibitStaircase.WRAP_HEIGHT + 0.13, ExhibitStaircase.CENTER_RADIUS)
	player.global_position = stair.to_global(phase)
	player.velocity = stair.global_basis.y
	demo._physics_process(0.0)
	var wrapped := stair.to_local(player.global_position)
	_check(absf(wrapped.y - (phase.y - ExhibitStaircase.PERIOD)) <= 0.00001,
		"stair ascent did not recycle one exact period")
	_check(Vector2(wrapped.x, wrapped.z).distance_to(Vector2(phase.x, phase.z)) <= 0.00001,
		"stair recycling changed horizontal position")
	_check(loop_seal.visible, "ground-floor corridor repeats on upper loops")
	_check(absf(ground_level.position.y + ExhibitStaircase.PERIOD) <= 0.00001,
		"ground floor moved relative to player during recycling")
	for _index in 100:
		player.global_position = stair.to_global(phase)
		player.velocity = stair.global_basis.y
		demo._physics_process(0.0)
		wrapped = stair.to_local(player.global_position)
		_check(absf(wrapped.y - (phase.y - ExhibitStaircase.PERIOD)) <= 0.00001,
			"stair period accumulated drift")
	_check(absf(ground_level.position.y + 101.0 * ExhibitStaircase.PERIOD) <= 0.00001,
		"ground floor does not preserve perceived ascent distance")
	player.global_position = stair.to_global(Vector3(phase.x, 4.0, phase.z))
	player.velocity = Vector3.ZERO
	demo._physics_process(0.0)
	_check(not loop_seal.visible, "ground-floor corridor does not return while descending")
	_check(is_zero_approx(ground_level.position.y), "ground floor does not return while descending")


## Normal of the hit triangle's drawn side: Godot fronts are clockwise, while
## TriangleMesh reports the normal facing the ray.
func _front_normal(faces: TriangleMesh, hit: Dictionary) -> Vector3:
	var corners := faces.get_faces()
	var first: int = hit["face_index"] * 3
	return (corners[first + 2] - corners[first]).cross(
		corners[first + 1] - corners[first]).normalized()


func _test_spherical_curvature(demo: Node3D, player: NonEuclideanPlayer,
		cells: Node3D) -> void:
	demo._go_to_case(2)
	await physics_frame
	await physics_frame
	_check(not (player.get_node("StairFillLight") as OmniLight3D).visible,
		"stair light leaks into another exhibit")
	var radial_field := cells.get_node("SphericalGarden/RadialGravity") as GravityField3D
	var radial := player.global_position - radial_field.global_position
	_check(player.gravity_field == radial_field, "player did not receive radial gravity")
	_check(player.gravity_vector.normalized().dot(radial.normalized()) >= 0.999,
		"spherical gravity does not point outward")
	_check(player.up_direction.dot(-radial.normalized()) >= 0.999,
		"spherical up direction does not point inward")
	_check(radial.length() > 28.0 and radial.length() < 30.1,
		"player left spherical shell")
	var initial_direction := radial.normalized()
	var initial_basis := player.global_basis
	var radius := radial.length()
	for step in 360:
		var direction := Basis(Vector3.RIGHT, TAU * float(step + 1) / 360.0) * initial_direction
		player.global_position = radial_field.global_position + direction * radius
		player.gravity_vector = direction * player.gravity_strength
		player._align_to_gravity()
		_check(absf((-player.global_basis.z).dot(direction)) <= 0.0001,
			"spherical forward vector stopped being tangent")
	_check(absf(player.global_position.distance_to(radial_field.global_position) - radius) <= 0.00001,
		"spherical transport changed shell radius")
	_check(_basis_error(player.global_basis, initial_basis) <= 0.0002,
		"full great-circle transport did not restore view frame")
	# The balls rest on the shell under the same radial pull, and one lifted
	# toward the centre falls back outward.
	var garden: ExhibitGarden = demo._garden
	var resting := ExhibitGarden.RADIUS - ExhibitGarden.BALL_RADIUS
	for ball in garden.balls:
		_check(ball.gravity_field == radial_field, "a garden ball escaped the radial gravity")
		_check(absf(ball.global_position.distance_to(radial_field.global_position) - resting)
			<= 0.1, "a garden ball does not rest on the shell")
	var lifted := garden.balls[0]
	var lift_direction := (lifted.global_position - radial_field.global_position).normalized()
	lifted.global_position = radial_field.global_position + lift_direction * (resting - 2.0)
	lifted.linear_velocity = Vector3.ZERO
	for _frame in 120:
		await physics_frame
	_check(absf(lifted.global_position.distance_to(radial_field.global_position) - resting)
		<= 0.15, "a ball lifted off the shell did not fall back outward")


func _test_growing_corridor(demo: Node3D, player: NonEuclideanPlayer,
		cells: Node3D) -> void:
	demo._go_to_case(3)
	var corridor := cells.get_node("GrowingCorridor") as Node3D
	var exhibit: ExhibitGrowingCorridor = demo._corridor
	await physics_frame
	_check(absf(player.global_position.y - 0.9) <= 0.05,
		"corridor spawn does not rest on the floor")
	var far_at_start := exhibit.far_distance
	var depth_at_start := -corridor.to_local(player.global_position).z
	player.capture_mouse()
	var lowest := INF
	for _frame in 480:
		Input.action_press("move_forward")
		Input.action_press("move_down")
		await physics_frame
		lowest = minf(lowest, player.global_position.y)
	Input.action_release("move_forward")
	Input.action_release("move_down")
	var walked := -corridor.to_local(player.global_position).z - depth_at_start
	_check(lowest >= 0.85, "floor vanished under the player while walking the corridor")
	_check(walked > 25.0, "sprinting eight seconds did not carry the player down the corridor")
	_check(exhibit.far_distance > far_at_start + walked * 0.4,
		"the far door did not recede while walking toward it")
	_check(absf(corridor.to_local(player.global_position).x) < ExhibitGrowingCorridor.SIZE.x * 0.5,
		"player left the corridor walls")
	var camera_environment := player.get_camera().environment
	_check(camera_environment != null \
		and is_equal_approx(camera_environment.fog_density, ExhibitGrowingCorridor.CORRIDOR_FOG),
		"corridor fog is not on the player camera")
	_check(not is_equal_approx(player.get_world_3d().environment.fog_density,
		ExhibitGrowingCorridor.CORRIDOR_FOG), "corridor fog leaked into the shared environment")
	# Turnaround: walking back retraces the folds and the start door still holds.
	var far_before_back := exhibit.far_distance
	for _frame in 1200:
		Input.action_press("move_back")
		Input.action_press("move_down")
		await physics_frame
	Input.action_release("move_back")
	Input.action_release("move_down")
	_check(player.global_position.y >= 0.85, "floor vanished under the player while walking back")
	_check(exhibit.far_distance < far_before_back,
		"walking back did not fold the corridor up again")
	_check(-corridor.to_local(player.global_position).z > 0.0,
		"player walked through the start door")
	# Reset: the readout returns to the start and the player to the spawn.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(player.global_position.distance_to(exhibit.spawn_pose.origin) <= 0.05,
		"corridor reset did not re-pose the player at the spawn")
	_check(is_equal_approx(exhibit.far_distance, far_at_start),
		"corridor reset did not fold the corridor back to its start")


func _test_grip_room(demo: Node3D, player: NonEuclideanPlayer, cells: Node3D) -> void:
	_check(InputMap.has_action("grab"), "shared grab action is missing")
	demo._go_to_case(4)
	await physics_frame
	var room := cells.get_node("GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	var grab: GrabController3D = demo._grab
	var camera := player.get_camera()
	var exclude: Array[RID] = [player.get_rid()]
	var ball_position := room.to_global(Vector3(-2.6, 0.35, 3.0))
	_place_aiming(player, ball_position + Vector3(0.0, 1.3, 0.75),
		ball_position + Vector3(0.0, 0.1, 0.0))
	await physics_frame
	_check(grab.try_grab(camera, 1, exclude), "ball not grabbed at one metre")
	_place_aiming(player, player.global_position + Vector3.UP * 0.75,
		player.global_position + Vector3.UP * 0.75 - player.global_basis.z)
	await physics_frame
	_check(grab.held_body == ball, "grab controller held the wrong body")
	_check(ball.freeze, "held ball did not freeze")
	_check(ball.display_radius() > 0.1, "held ball lost a readable in-hand size")
	await physics_frame
	_check(grab.held_body == ball, "held ball resolved without meeting a surface")
	# Put it down on the floor at the feet: the size stays small.
	_place_aiming(player, player.global_position + Vector3.UP * 0.75,
		player.global_position - player.global_basis.z * 0.55 - Vector3.UP * 0.75)
	await physics_frame
	grab.release()
	_check(grab.held_body == null, "release did not let go")
	_check(not ball.freeze, "ball stayed frozen after release")
	_check(ball.linear_velocity.length_squared() <= 0.000001,
		"ball kept velocity through release")
	var small_radius := ball.display_radius()
	_check(is_equal_approx(small_radius, _collision_radius(ball)),
		"mesh and collision radius diverged after the small put-down")
	_check(small_radius < GripBall.RADIUS_MAX * 0.5,
		"floor put-down did not keep the ball small")
	# Grab again and aim from the back of the room down a clear lane at the far
	# wall: the projection clamps to the giant bound before reaching it.
	_place_aiming(player, ball.global_position + Vector3(0.0, 1.3, 0.75),
		ball.global_position)
	await physics_frame
	_check(grab.try_grab(camera, 1, exclude), "ball not grabbed again for the wall test")
	_place_aiming(player, room.to_global(Vector3(-2.0, 1.65, 7.0)),
		room.to_global(Vector3(-2.4, 3.2, -8.0)))
	await physics_frame
	_check(grab.held_body == ball, "held ball resolved before the wall put-down")
	grab.release()
	var giant_radius := ball.display_radius()
	_check(giant_radius >= GripBall.RADIUS_MAX - 0.01,
		"wall put-down did not resolve a giant size")
	_check(is_equal_approx(giant_radius, _collision_radius(ball)),
		"mesh and collision radius diverged after the giant put-down")
	_check(not ball.freeze, "ball stayed frozen after the giant put-down")
	for _frame in 40:
		await physics_frame
	_check(is_finite(ball.global_position.length_squared()),
		"giant ball position left the finite range while settling")
	_check(is_equal_approx(_collision_radius(ball), GripBall.RADIUS_MAX),
		"giant ball radius drifted while settling")
	# Reset returns every ball to its built pose and size.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(is_equal_approx(ball.display_radius(), ball.base_radius()),
		"reset did not restore the built ball size")
	_check(is_equal_approx(_collision_radius(ball), ball.base_radius()),
		"reset did not restore the collision sphere")
	_check(ball.global_position.distance_to(demo._grip.props[0].global_position) <= 0.001,
		"reset moved the first ball")


func _test_wrap_world(demo: Node3D, player: NonEuclideanPlayer, cells: Node3D) -> void:
	demo._go_to_case(5)
	var world := cells.get_node("WrapWorld") as Node3D
	var exhibit: ExhibitWrapWorld = demo._wrap
	await physics_frame
	_check(absf(player.global_position.y - 0.9) <= 0.06,
		"wrap world spawn does not rest on the block top")
	# Straight walk across the seam: the floor must hold every frame and the
	# cell must stay bounded — the wrap must never read as a hole or a jump.
	player.capture_mouse()
	player.set_pose(Transform3D(Basis.IDENTITY, world.to_global(Vector3(8.0, 0.9, 17.0))))
	await physics_frame
	var loops_before := exhibit.wrap_count
	var min_height := INF
	var frame := 0
	while frame < 600 and exhibit.wrap_count == loops_before:
		frame += 1
		Input.action_press("move_forward")
		Input.action_press("move_down")
		await physics_frame
		min_height = minf(min_height, player.global_position.y)
	Input.action_release("move_forward")
	Input.action_release("move_down")
	_check(exhibit.wrap_count == loops_before + 1,
		"straight walk did not wrap exactly once within 600 frames")
	_check(min_height >= 0.7, "floor vanished under the player at the wrap seam")
	var walked_local := world.to_local(player.global_position)
	_check(absf(walked_local.x) <= ExhibitWrapWorld.PERIODS.x * 0.5 \
		and absf(walked_local.z) <= ExhibitWrapWorld.PERIODS.z * 0.5,
		"player ended outside the bounded cell after wrapping")
	_check(walked_local.z > ExhibitWrapWorld.PERIODS.z * 0.5 - 4.0,
		"wrap did not carry the player one full period over")
	_check(player.get_camera().environment != null \
		and player.get_camera().environment.fog_mode == Environment.FOG_MODE_DEPTH,
		"wrap world does not fog out the lattice edge")
	for slot in demo.render_manager._slots:
		_check(slot["portal"] == null, "a portal of a previous exhibit kept its render slot")
	# A fall out of the cell bottom re-enters from the top without crossing a seam.
	var seam_before := exhibit.last_seam
	var loops_after_walk := exhibit.wrap_count
	await physics_frame
	player.set_pose(Transform3D(Basis.IDENTITY, world.to_global(
		Vector3(0.0, -ExhibitWrapWorld.PERIODS.y * 0.5 - 0.5, 0.0))))
	exhibit.track(player, 0.0)
	_check(world.to_local(player.global_position).y > 0.0,
		"a fall out of the cell bottom did not re-enter from the top")
	_check(exhibit.last_seam == seam_before and exhibit.wrap_count == loops_after_walk,
		"a fall through the shaft was reported as a seam crossing")
	player.set_pose(exhibit.spawn_pose)
	await physics_frame
	# The prop loops through the central shaft: re-entering from above, staying
	# in the shaft, and never accelerating past the terminal fall cap.
	var sphere := exhibit.props[0]
	sphere.global_transform = Transform3D(Basis.IDENTITY,
		world.to_global(Vector3(0.0, 2.5, 0.0)))
	sphere.linear_velocity = Vector3.ZERO
	sphere.angular_velocity = Vector3.ZERO
	sphere.sleeping = false
	var prop_wraps_before := exhibit.prop_wraps
	frame = 0
	var max_speed := 0.0
	var max_radius := 0.0
	while frame < 900 and exhibit.prop_wraps < prop_wraps_before + 3:
		frame += 1
		await physics_frame
		max_speed = maxf(max_speed, sphere.linear_velocity.length())
		var sphere_local := world.to_local(sphere.global_position)
		max_radius = maxf(max_radius, Vector2(sphere_local.x, sphere_local.z).length())
	_check(exhibit.prop_wraps >= prop_wraps_before + 3,
		"sphere did not loop three times through the shaft")
	_check(max_speed <= ExhibitWrapWorld.TERMINAL_FALL + 1.0,
		"fall speed accumulated past the terminal cap while looping")
	_check(max_radius <= 1.25, "sphere drifted out of the shaft while looping")
	_check(is_finite(sphere.global_position.length_squared()),
		"sphere position left the finite range while looping")
	# Reset zeroes the counters and rebuilds the built poses.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(exhibit.wrap_count == 0 and exhibit.prop_wraps == 0,
		"wrap reset did not zero the loop counters")
	_check(player.global_position.distance_to(exhibit.spawn_pose.origin) <= 0.05,
		"wrap reset did not re-pose the player at the spawn")
	var sphere_home := world.to_local(exhibit.props[0].global_position)
	_check(sphere_home.distance_to(Vector3(-4.0, 0.4, 4.0)) <= 0.2,
		"wrap reset did not return the sphere to its built spot")


func _test_holonomy_loop(demo: Node3D, player: NonEuclideanPlayer,
		cells: Node3D) -> void:
	demo._go_to_case(6)
	var cell := cells.get_node("HolonomyLoop") as Node3D
	var exhibit: ExhibitHolonomyLoop = demo._holonomy
	var vault1 := cell.get_node("Vault1") as Node3D
	await physics_frame
	_check(player.get_camera().environment == null, "wrap world fog leaked into the next exhibit")
	var count := ExhibitHolonomyLoop.VAULT_COUNT
	_check(exhibit.exits.size() == count and exhibit.entrances.size() == count,
		"holonomy loop does not chain one exit into one entrance per vault")
	# Every lit door frame hugs its own aperture, on the room side of the wall,
	# and the wall leaves that aperture open wherever along it the door sits.
	var space := demo.get_world_3d().direct_space_state
	for index in count:
		var vault := cell.get_node("Vault%d" % (index + 1)) as Node3D
		_check(exhibit.entrance_walls[index] != exhibit.exit_walls[index],
			"vault %d has both doors on one wall" % (index + 1))
		for door in [[exhibit.entrance_walls[index], exhibit.entrances[index]],
				[exhibit.exit_walls[index], exhibit.exits[index]]]:
			var frame := vault.get_node("DoorFrame%s" % String(door[0]).capitalize()) as Node3D
			var portal: Portal3D = door[1]
			var trim := frame.get_child(0) as Node3D
			var offset := trim.global_position - portal.global_position
			var depth := offset.dot(portal.global_basis.z)
			_check(depth > 0.0 and depth <= 0.35,
				"vault %d %s door frame floats off its wall (%.2f m)" % [index + 1, door[0], depth])
			_check(absf(absf(offset.dot(portal.global_basis.x))
				- ExhibitHolonomyLoop.APERTURE.x * 0.5 - 0.06) <= 0.01,
				"vault %d %s door frame slid off its aperture" % [index + 1, door[0]])
			var normal := portal.global_basis.z * 0.6
			var through := PhysicsRayQueryParameters3D.create(portal.global_position + normal,
				portal.global_position - normal)
			_check(space.intersect_ray(through).is_empty(),
				"vault %d %s aperture is walled up" % [index + 1, door[0]])
	var spawn_local := vault1.to_local(player.global_position)
	_check(absf(spawn_local.x) <= ExhibitHolonomyLoop.VAULT.x * 0.5 \
		and absf(spawn_local.z) <= ExhibitHolonomyLoop.VAULT.z * 0.5,
		"holonomy spawn is not inside the first vault")
	_check(absf(player.global_position.y - 0.9) <= 0.06,
		"holonomy spawn does not rest on the vault floor")
	# The built loop composes to the turn its door walls predict, never to none.
	var walk: Array[Transform3D] = []
	for step in count:
		walk.append(exhibit.exits[exhibit.order[step]].get_mapping())
	var loop := HolonomyState.loop_mapping(walk)
	_check(not is_zero_approx(exhibit.turn_angle), "the drawn loop closes straight")
	_check(not exhibit.sight_outruns_views(),
		"the drawn loop lines a view up past the live doors onto a stand-in")
	# The draw check itself: four straight rooms line their doors up past the
	# live views; five left turns fold every view back.
	var probe := ExhibitHolonomyLoop.new()
	probe.order.assign(range(count))
	for _index in count:
		probe.vault_sizes.append(ExhibitHolonomyLoop.VAULT)
		probe.entrance_walls.append("south")
		probe.entrance_offsets.append(0.0)
		probe.exit_offsets.append(0.0)
	probe.exit_walls.assign(["north", "north", "north", "north", "west"])
	_check(probe.sight_outruns_views(), "four straight rooms in a row pass the draw check")
	probe.exit_walls.assign(["west", "west", "west", "west", "west"])
	_check(not probe.sight_outruns_views(), "five left turns fail the draw check")
	_check(absf(angle_difference(HolonomyState.turn_angle(loop), exhibit.turn_angle)) <= 0.001,
		"the built loop does not turn as its door walls predict")
	_check(loop.basis.y.distance_to(Vector3.UP) <= 0.001,
		"the built loop turns about a tilted axis")
	# Walk the whole cycle with scripted crossings: every crossing must land in
	# front of the next vault's entrance, and every one must be counted. The
	# order is read afresh each step: the loop may rearrange out of sight.
	for step in count:
		var entry: Portal3D = exhibit.exits[exhibit.order[step]]
		var arrival: Portal3D = exhibit.entrances[exhibit.order[(step + 1) % count]]
		player.set_pose(Transform3D(Basis.IDENTITY,
			entry.to_global(Vector3(0.0, -0.8, -0.05))))
		player._portal_previous_position = entry.to_global(Vector3(0.0, -0.8, 0.05))
		entry._physics_process(0.0)
		_check(player.global_position.distance_to(arrival.global_position) <= 3.0,
			"crossing exit %d did not land in front of the next entrance" % (step + 1))
		_check(exhibit.active_portals.has(arrival),
			"live views did not follow the player through exit %d" % (step + 1))
		# process_frame fires before _process: two frames see the views re-bound.
		await process_frame
		await process_frame
		var far_vault := exhibit.order[(step + 2) % count]
		var far_door: Portal3D = exhibit.exits[far_vault]
		_check(far_door._surface_material.get_shader_parameter("portal_texture") is ViewportTexture,
			"vault %d's exit, seen through the next door, renders as a hole" % (far_vault + 1))
		await physics_frame
	_check(exhibit.crossing_count == count, "the loop's crossings were not all counted")
	# The loop returns the player inside the first vault, through its entrance:
	# they settle in the doorway itself, so the bounds are the shell envelope.
	var returned_local := vault1.to_local(player.global_position)
	_check(absf(returned_local.x) <= ExhibitHolonomyLoop.VAULT.x * 0.5 + 0.5 \
		and absf(returned_local.z) <= ExhibitHolonomyLoop.VAULT.z * 0.5 + 0.5,
		"the full loop did not return the player to the first vault")
	await physics_frame
	await physics_frame
	_check(player._portal_lock == null, "arrival portal stays locked after the loop")
	var settled := player.global_position
	await physics_frame
	_check(player.global_position.distance_to(settled) <= 0.001,
		"the player ping-ponged through the return portal")
	_test_holonomy_rearrangement(player, exhibit, vault1)
	# Reset zeroes the counter and re-poses the player at the spawn.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(exhibit.crossing_count == 0, "holonomy reset did not zero the crossings")
	_check(player.global_position.distance_to(exhibit.spawn_pose.origin) <= 0.05,
		"holonomy reset did not re-pose the player at the spawn")
	_check(_basis_error(player.global_basis, exhibit.spawn_pose.basis) <= 0.001,
		"holonomy reset did not restore the spawn orientation")


## Rearranging never touches what the player may see: from poses all over the
## start vault, the vaults in sight keep their place and their build, the start
## vault keeps place 0, and the loop keeps its turn and its sight-line bound.
func _test_holonomy_rearrangement(player: NonEuclideanPlayer, exhibit: ExhibitHolonomyLoop,
		vault1: Node3D) -> void:
	var count := ExhibitHolonomyLoop.VAULT_COUNT
	var camera := player.get_camera()
	(player.get_node("CameraPivot") as Node3D).rotation.x = 0.0
	var turn := exhibit.turn_angle
	var rearranged := 0
	var partly_seen := 0
	for pose_index in 32:
		var yaw := TAU * float(pose_index) / 32.0
		var spot := Vector3(sin(yaw * 3.0) * 1.4, 0.0, cos(yaw * 2.0) * 1.8)
		player.set_pose(vault1.global_transform * Transform3D(Basis(Vector3.UP, yaw), spot))
		var seen := exhibit.seen_vaults(camera)
		if seen.size() < count:
			partly_seen += 1
		var before := {}
		for vault: int in seen:
			before[vault] = [exhibit.order.find(vault), exhibit._vault_node(vault).get_instance_id()]
		var lost: Array[int] = []
		for vault in count:
			if not seen.has(vault):
				lost.append(vault)
		if not exhibit._rearrange(seen, lost):
			continue
		rearranged += 1
		for vault: int in seen:
			_check(before[vault] == [exhibit.order.find(vault),
				exhibit._vault_node(vault).get_instance_id()],
				"pose %d: vault %d changed while in sight" % [pose_index, vault + 1])
		_check(exhibit.order[0] == 0, "pose %d: the start vault left place 0" % pose_index)
		_check(absf(angle_difference(HolonomyState.layout_turn(exhibit.entrance_walls,
			exhibit.exit_walls), turn)) <= 0.0001,
			"pose %d: rearranging changed the loop's turn" % pose_index)
		_check(not exhibit.sight_outruns_views(),
			"pose %d: rearranging lined a view up onto a stand-in" % pose_index)
		for place in count:
			var vault := exhibit.order[place]
			_check(exhibit.exits[vault].linked_portal \
				== exhibit.entrances[exhibit.order[(place + 1) % count]],
				"pose %d: the cycle broke at place %d" % [pose_index, place])
	_check(partly_seen >= 8, "too few poses leave part of the loop unseen (%d)" % partly_seen)
	_check(rearranged >= 8, "too few poses let the loop rearrange (%d)" % rearranged)


func _place_aiming(player: NonEuclideanPlayer, eye: Vector3, target: Vector3) -> void:
	var to_target := target - eye
	var horizontal := Vector3(to_target.x, 0.0, to_target.z).normalized()
	player.set_pose(Transform3D(_basis_from_forward(horizontal), eye - Vector3.UP * 0.75))
	(player.get_node("CameraPivot") as Node3D).rotation.x = atan2(to_target.y,
		Vector3(to_target.x, 0.0, to_target.z).length())


func _collision_radius(ball: GripBall) -> float:
	for child in ball.get_children():
		if child is CollisionShape3D:
			return ((child as CollisionShape3D).shape as SphereShape3D).radius
	return -1.0


func _test_existing_input_contract() -> void:
	_check(InputMap.has_action("move_forward"), "shared move_forward action is missing")
	_check(InputMap.has_action("move_up"), "shared move_up action is missing")
	_check(InputMap.has_action("move_down"), "shared move_down action is missing")
	var has_z := false
	var has_physical_w := false
	for event in InputMap.action_get_events("move_forward"):
		if event is InputEventKey:
			var key := event as InputEventKey
			has_z = has_z or key.keycode == KEY_Z
			has_physical_w = has_physical_w or key.physical_keycode == KEY_W
	_check(has_z, "move_forward no longer supports AZERTY Z")
	_check(has_physical_w, "move_forward no longer supports physical W")


func _test_player_input(player: NonEuclideanPlayer) -> void:
	player.set_pose(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 7.5)))
	player.capture_mouse()
	var movement_start := player.global_position
	var movement_forward := -player.global_basis.z
	for _frame in 12:
		Input.action_press("move_forward")
		await physics_frame
	Input.action_release("move_forward")
	var movement_delta := player.global_position - movement_start
	_check(movement_delta.dot(movement_forward) > 0.05,
		"move_forward did not move player forward")


func _aimed_pose(portal: Portal3D, local_position: Vector3) -> Transform3D:
	var body_position := portal.to_global(local_position)
	var camera_position := body_position + Vector3.UP * 0.75
	var direction := portal.global_position - camera_position
	direction.y = 0.0
	direction = direction.normalized()
	var yaw := atan2(-direction.x, -direction.z)
	return Transform3D(Basis(Vector3.UP, yaw), body_position)


func _basis_from_forward(forward: Vector3) -> Basis:
	var normalized_forward := forward.normalized()
	var right := normalized_forward.cross(Vector3.UP).normalized()
	return Basis(right, Vector3.UP, -normalized_forward).orthonormalized()
