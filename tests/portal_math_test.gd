extends "res://tests/test_case.gd"
## Unit tests for portal_math.gd. No scene, no GPU, no autoload: runs under
## --headless in a couple of seconds.

const PortalMathScript := preload("res://scripts/non_euclidean/portal_math.gd")


func _initialize() -> void:
	_test_round_trip()
	_test_crossing_math()
	_finish("portal_math")


func _test_round_trip() -> void:
	var source := Transform3D(
		Basis.from_euler(Vector3(0.17, -0.63, 0.09)).orthonormalized(),
		Vector3(12.5, -3.25, 8.75)
	)
	var destination := Transform3D(
		Basis.from_euler(Vector3(-0.31, 1.17, 0.42)).orthonormalized(),
		Vector3(-44.0, 16.5, 91.0)
	)
	var forward: Transform3D = PortalMathScript.mapping(source, destination)
	var backward: Transform3D = PortalMathScript.mapping(destination, source)
	var pose := Transform3D(
		Basis.from_euler(Vector3(0.2, 0.8, -0.4)).orthonormalized(),
		Vector3(9.0, 2.0, -5.0)
	)
	var velocity := Vector3(2.5, -7.0, 11.0)
	var gravity := Vector3(0.0, -12.0, 0.0)
	var initial_pose := pose
	var initial_velocity := velocity
	var initial_gravity := gravity
	var once_pose: Transform3D = PortalMathScript.map_transform(backward,
		PortalMathScript.map_transform(forward, pose))
	var once_velocity: Vector3 = PortalMathScript.map_vector(backward,
		PortalMathScript.map_vector(forward, velocity))
	var once_gravity: Vector3 = PortalMathScript.map_vector(backward,
		PortalMathScript.map_vector(forward, gravity))
	_check(once_pose.origin.distance_to(initial_pose.origin) <= 0.00001, "single round-trip position")
	_check(_basis_error(once_pose.basis, initial_pose.basis) <= 0.00001, "single round-trip basis")
	_check(once_velocity.distance_to(initial_velocity) <= 0.00001, "single round-trip velocity")
	_check(once_gravity.distance_to(initial_gravity) <= 0.00001, "single round-trip gravity")
	source = Transform3D(Basis.IDENTITY, Vector3(12.0, -4.0, 8.0))
	destination = Transform3D(Basis(
		Vector3(0.0, 0.0, -1.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(1.0, 0.0, 0.0)
	), Vector3(-44.0, 16.0, 92.0))
	forward = PortalMathScript.mapping(source, destination)
	backward = PortalMathScript.mapping(destination, source)
	pose = initial_pose
	velocity = initial_velocity
	gravity = initial_gravity
	for _index in 100:
		pose = PortalMathScript.map_transform(forward, pose)
		velocity = PortalMathScript.map_vector(forward, velocity)
		gravity = PortalMathScript.map_vector(forward, gravity)
		pose = PortalMathScript.map_transform(backward, pose)
		velocity = PortalMathScript.map_vector(backward, velocity)
		gravity = PortalMathScript.map_vector(backward, gravity)
	_check(pose.origin.distance_to(initial_pose.origin) <= 0.00001, "round-trip position drift")
	_check(_basis_error(pose.basis, initial_pose.basis) <= 0.00001, "round-trip basis drift")
	_check(velocity.distance_to(initial_velocity) <= 0.00001, "round-trip velocity drift")
	_check(gravity.distance_to(initial_gravity) <= 0.00001, "round-trip gravity drift")


func _test_crossing_math() -> void:
	var opening := Vector2(2.6, 3.4)
	var previous := Vector3(0.7, -0.4, 2.0)
	var current := Vector3(0.7, -0.4, -3.0)
	var hit: Vector3 = PortalMathScript.crossing_point(previous, current)
	_check(absf(hit.z) <= 0.000001, "crossing does not land on plane")
	_check(PortalMathScript.inside_aperture(hit, opening), "valid crossing rejected")
	_check(not PortalMathScript.inside_aperture(Vector3(2.0, 0.0, 0.0), opening),
		"outside crossing accepted")
