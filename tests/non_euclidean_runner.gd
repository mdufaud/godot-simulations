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
	demo._reset_reserve_props()
	var crate := demo._reserve_props[0] as PortalRigidBody3D
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
	demo._reset_reserve_props()


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
		stair.to_global(Vector3(0.0, 0.95, demo.STAIR_CENTER_RADIUS))))
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
	var phase := Vector3(0.0, demo.STAIR_WRAP_HEIGHT + 0.13, demo.STAIR_CENTER_RADIUS)
	player.global_position = stair.to_global(phase)
	player.velocity = stair.global_basis.y
	demo._physics_process(0.0)
	var wrapped := stair.to_local(player.global_position)
	_check(absf(wrapped.y - (phase.y - demo.STAIR_PERIOD)) <= 0.00001,
		"stair ascent did not recycle one exact period")
	_check(Vector2(wrapped.x, wrapped.z).distance_to(Vector2(phase.x, phase.z)) <= 0.00001,
		"stair recycling changed horizontal position")
	_check(loop_seal.visible, "ground-floor corridor repeats on upper loops")
	_check(absf(ground_level.position.y + demo.STAIR_PERIOD) <= 0.00001,
		"ground floor moved relative to player during recycling")
	for _index in 100:
		player.global_position = stair.to_global(phase)
		player.velocity = stair.global_basis.y
		demo._physics_process(0.0)
		wrapped = stair.to_local(player.global_position)
		_check(absf(wrapped.y - (phase.y - demo.STAIR_PERIOD)) <= 0.00001,
			"stair period accumulated drift")
	_check(absf(ground_level.position.y + 101.0 * demo.STAIR_PERIOD) <= 0.00001,
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
