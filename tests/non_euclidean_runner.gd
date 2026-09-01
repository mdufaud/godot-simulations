extends "res://tests/test_case.gd"
## Integration tests for the non-euclidean demo: portal traversal, the infinite
## staircase, spherical curvature and the shared input contract. Needs a real GPU
## (SubViewport portal targets), so it does not run under --headless.
##
## Assertions here must describe player-visible behaviour. Node names, child counts,
## exact scene coordinates and renderer configuration are deliberately not asserted:
## they break on every legitimate refactor without catching a single real bug. Portal
## image correctness is covered by tests/capture_non_euclidean.gd.

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
	root.size = Vector2i(1920, 1080)
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
	for child in stair.get_children():
		if not child.has_meta("infinite_stair_ramp"):
			continue
		var previous_top := -INF
		for flight_child in child.get_children():
			if flight_child is not MeshInstance3D:
				continue
			var mesh_instance := flight_child as MeshInstance3D
			var box := mesh_instance.mesh as BoxMesh
			_check(box.size.y >= 0.29, "helical slab is visibly transparent from below")
			var bottom := mesh_instance.position.y - box.size.y * 0.5
			if previous_top != -INF:
				_check(bottom <= previous_top + 0.00001,
					"helical slab has visible gaps between steps")
			previous_top = mesh_instance.position.y + box.size.y * 0.5
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


func _test_growing_corridor(demo: Node3D, player: NonEuclideanPlayer,
		cells: Node3D) -> void:
	demo._go_to_case(3)
	var corridor := cells.get_node("GrowingCorridor") as Node3D
	var exhibit: ExhibitGrowingCorridor = demo._corridor
	await physics_frame
	_check(absf(player.global_position.y - 0.9) <= 0.05,
		"corridor spawn does not rest on the first segment floor")
	_check(corridor.get_node_or_null("Segment00") != null,
		"corridor does not start with its scale-1 segment")
	player.capture_mouse()
	var ceiling_heights: Array[float] = []
	var previous_crossings := 0
	var frame := 0
	while frame < 1500 and exhibit.crossing_count < 3:
		frame += 1
		Input.action_press("move_forward")
		Input.action_press("move_down")
		await physics_frame
		if frame % 10 == 0:
			_check(player.global_position.y >= 0.85,
				"floor vanished under the player during a segment swap")
		if exhibit.crossing_count > previous_crossings:
			previous_crossings = exhibit.crossing_count
			var height := _ceiling_height_above(player)
			ceiling_heights.append(height)
			if ceiling_heights.size() > 1:
				_check(height > ceiling_heights[ceiling_heights.size() - 2] + 0.5,
					"corridor ceiling did not grow across threshold %d" % previous_crossings)
	Input.action_release("move_forward")
	Input.action_release("move_down")
	_check(ceiling_heights.size() >= 3,
		"walking the corridor did not cross three thresholds")
	_check(exhibit.virtual_distance > 0.0,
		"virtual distance stayed at zero while walking forward")
	_check(exhibit.current_index >= 3,
		"player did not reach the fourth segment after three crossings")
	# Turnaround: the corridor behind is a capped dead end, never a hole.
	var local_before_back := corridor.to_local(player.global_position)
	for _frame in 240:
		Input.action_press("move_back")
		Input.action_press("move_down")
		await physics_frame
	Input.action_release("move_back")
	Input.action_release("move_down")
	_check(player.global_position.y >= 0.85,
		"floor vanished under the player while walking back")
	var local_after_back := corridor.to_local(player.global_position)
	_check(local_after_back.z > local_before_back.z,
		"walking back did not move the player toward the start")
	_check(exhibit.current_index >= 1,
		"player escaped the corridor window while walking back")
	# Reset: counters to zero and geometry rebuilt at scale 1.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(exhibit.crossing_count == 0 and is_zero_approx(exhibit.virtual_distance),
		"corridor reset did not zero its counters")
	_check(exhibit.current_index == 0, "corridor reset did not return to the first segment")
	_check(player.global_position.distance_to(exhibit.spawn_pose.origin) <= 0.05,
		"corridor reset did not re-pose the player at the spawn")
	_check(_ceiling_height_above(player) < 2.5,
		"corridor reset did not rebuild scale-1 geometry")


func _test_grip_room(demo: Node3D, player: NonEuclideanPlayer, cells: Node3D) -> void:
	_check(InputMap.has_action("grab"), "shared grab action is missing")
	demo._go_to_case(4)
	await physics_frame
	var room := cells.get_node("GripRoom") as Node3D
	var ball: GripBall = demo._grip.props[0]
	var grab: GrabController3D = demo._grab
	var camera := player.get_camera()
	var exclude: Array[RID] = [player.get_rid()]
	var ball_position := room.to_global(Vector3(-2.6, 0.35, -1.5))
	# Grab the near ball from ~1 m and keep it held: re-aim level in the same
	# tick, before the controller's next probe, so the floor behind the ball
	# cannot count as a contact.
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
	# Grab again and put it down against the far wall through the opening:
	# the size resolves at the wall's distance and clamps to the giant bound.
	_place_aiming(player, ball.global_position + Vector3(0.0, 1.3, 0.75),
		ball.global_position)
	await physics_frame
	_check(grab.try_grab(camera, 1, exclude), "ball not grabbed again for the wall test")
	_place_aiming(player, room.to_global(Vector3(0.0, 1.65, -0.5)),
		room.to_global(Vector3(0.0, 1.65, -12.0)))
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
	_check(exhibit.exits.size() == 4 and exhibit.entrances.size() == 4,
		"holonomy loop does not chain four exits into four entrances")
	var spawn_local := vault1.to_local(player.global_position)
	_check(absf(spawn_local.x) <= ExhibitHolonomyLoop.VAULT.x * 0.5 \
		and absf(spawn_local.z) <= ExhibitHolonomyLoop.VAULT.z * 0.5,
		"holonomy spawn is not inside the first vault")
	_check(absf(player.global_position.y - 0.9) <= 0.06,
		"holonomy spawn does not rest on the vault floor")
	# The built square must compose to a pure quarter turn — the exhibit's claim.
	var walk: Array[Transform3D] = []
	for step in 4:
		walk.append(exhibit.exits[step].get_mapping())
	var loop := HolonomyState.loop_mapping(walk[0], walk[1], walk[2], walk[3])
	_check(absf(HolonomyState.turn_angle(loop) - PI * 0.5) <= 0.001,
		"the built square does not compose to a +90° turn")
	_check(loop.basis.y.distance_to(Vector3.UP) <= 0.001,
		"the built square's loop turns about a tilted axis")
	# Walk the cycle I→II→III→IV→I with scripted crossings: every crossing must
	# land in front of the next vault's entrance, and every one must be counted.
	for step in 4:
		var entry: Portal3D = exhibit.exits[step]
		var arrival: Portal3D = exhibit.entrances[(step + 1) % 4]
		player.set_pose(Transform3D(Basis.IDENTITY,
			entry.to_global(Vector3(0.0, -0.8, -0.05))))
		player._portal_previous_position = entry.to_global(Vector3(0.0, -0.8, 0.05))
		entry._physics_process(0.0)
		_check(player.global_position.distance_to(arrival.global_position) <= 3.0,
			"crossing exit %d did not land in front of the next entrance" % (step + 1))
		await physics_frame
	_check(exhibit.crossing_count == 4, "the four crossings were not all counted")
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
	# Reset zeroes the counter and re-poses the player at the spawn.
	demo._reset_current_case()
	await physics_frame
	await physics_frame
	_check(exhibit.crossing_count == 0, "holonomy reset did not zero the crossings")
	_check(player.global_position.distance_to(exhibit.spawn_pose.origin) <= 0.05,
		"holonomy reset did not re-pose the player at the spawn")
	_check(_basis_error(player.global_basis, exhibit.spawn_pose.basis) <= 0.001,
		"holonomy reset did not restore the spawn orientation")


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


func _ceiling_height_above(player: NonEuclideanPlayer) -> float:
	var query := PhysicsRayQueryParameters3D.create(player.global_position,
		player.global_position + Vector3.UP * 60.0, 1, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position.y - player.global_position.y if not hit.is_empty() else -1.0


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
