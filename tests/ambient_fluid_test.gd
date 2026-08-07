extends "res://tests/test_case.gd"

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const CONFIG := preload("res://scripts/ambient_fluid/ambient_fluid_config.gd")
const BODY := preload("res://scripts/ambient_fluid/ambient_fluid_body_3d.gd")
const GAME_MANAGER := preload("res://scripts/autoload/game_manager.gd")
const PROFILE_RESOURCE := preload("res://resources/ambient_fluid/sphere_analytic.tres")


func _initialize() -> void:
	_test_demo_isolation()
	_test_matrix_operations()
	_test_profile_and_tensor()
	_test_acceleration_closed_form()
	_test_gyroscopic_norm()
	call_deferred("_test_scene_body")


func _test_demo_isolation() -> void:
	_check(GAME_MANAGER.demo_scene("ambient_fluid_demo") == "res://scenes/ambient_fluid_demo.tscn",
		"ambient fluid demo is not registered in GameManager")
	var packed: PackedScene = load("res://scenes/ambient_fluid_demo.tscn")
	var instance := packed.instantiate()
	_check(instance.get_script() != null and instance.get_script().resource_path ==
		"res://scripts/demos/ambient_fluid_controller.gd",
		"ambient fluid scene is not using isolated controller")
	instance.free()


func _test_matrix_operations() -> void:
	var diagonal := MATH.diagonal_matrix(Vector3(2.0, 3.0, 4.0), 5.0)
	var inverse := MATH.matrix_inverse(diagonal)
	_check(inverse.size() == MATH.MATRIX_SCALARS, "6x6 diagonal inverse has wrong size")
	var product := MATH.matrix_multiply(diagonal, inverse)
	_check(_matrix_near(product, MATH.identity_matrix(), 1.0e-10), "6x6 inverse product is not identity")
	_check(MATH.is_symmetric(diagonal), "diagonal matrix is not symmetric")
	_check(MATH.cholesky(diagonal).size() == MATH.MATRIX_SCALARS,
		"positive diagonal matrix failed Cholesky")
	_check(MATH.is_positive_definite(diagonal), "positive diagonal matrix is not positive definite")
	_check(MATH.matrix_inverse(MATH.zero_matrix()).is_empty(),
		"singular 6x6 matrix was inverted")


func _test_profile_and_tensor() -> void:
	var profile: AmbientFluidProfile3D = PROFILE_RESOURCE
	var error := profile.validate()
	_check(error == "", "analytic sphere profile invalid: %s" % error)
	_check(profile.face_centers_m.size() == 20, "analytic sphere does not have icosahedron faces")
	_check(absf(profile.center_of_volume_m.length()) <= 1.0e-12,
		"sphere center of volume is not centered")
	for index in profile.face_centers_m.size():
		_check(profile.face_centers_m[index].dot(profile.face_normals[index]) > 0.0,
			"analytic sphere face normal is not outward")
	_check(MATH.is_symmetric(profile.added_mass_tensor), "sphere added mass is not symmetric")
	var expected_added_mass := profile.reference_density_kg_m3 * profile.volume_m3 * 0.5
	_check(absf(profile.added_mass_tensor[21] - expected_added_mass) < 1.0e-6,
		"sphere added mass x block is wrong")
	_check(absf(profile.added_mass_tensor[28] - expected_added_mass) < 1.0e-6,
		"sphere added mass y block is wrong")
	_check(absf(profile.added_mass_tensor[35] - expected_added_mass) < 1.0e-6,
		"sphere added mass z block is wrong")
	for index in [21, 28, 35]:
		_check(absf(profile.added_mass_tensor[index] - expected_added_mass) < 1.0e-6,
			"sphere translation added mass is anisotropic")
	_check(profile.slip_matrix.is_empty(), "analytic profile unexpectedly has slip matrix")


func _test_acceleration_closed_form() -> void:
	var profile: AmbientFluidProfile3D = PROFILE_RESOURCE
	var body_density := 500.0
	var body_mass := body_density * profile.volume_m3
	var radius := pow(profile.volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
	var inertia := Vector3.ONE * (0.4 * body_mass * radius * radius)
	var body_tensor := MATH.diagonal_matrix(inertia, body_mass)
	for fluid_density_value in [0.0, 1.204, 998.0]:
		var fluid_density: float = float(fluid_density_value)
		var fluid_mass := fluid_density * profile.volume_m3
		var combined := MATH.matrix_add(body_tensor, MATH.matrix_scale(
			profile.added_mass_tensor, fluid_density / profile.reference_density_kg_m3))
		var inverse := MATH.matrix_inverse(combined)
		var momentum := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		var wrench := MATH.gravity_buoyancy_wrench(body_mass, fluid_mass,
			Vector3(0.0, -9.8, 0.0), Vector3.ZERO)
		var next_momentum := MATH.semi_implicit_momentum_step(momentum, wrench, 1.0e-3)
		var velocity := MATH.matrix_vector_multiply(inverse, next_momentum)
		var expected: float = (body_mass - fluid_mass) * -9.8 \
			/ (body_mass + fluid_mass * 0.5)
		_check(absf(velocity[4] / 1.0e-3 - expected) < 1.0e-5,
			"closed-form acceleration mismatch at density %.3f" % fluid_density)


func _test_gyroscopic_norm() -> void:
	var tensor := MATH.diagonal_matrix(Vector3.ONE, 1.0)
	var inverse := MATH.matrix_inverse(tensor)
	var momentum := PackedFloat64Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
	var velocity := MATH.matrix_vector_multiply(inverse, momentum)
	var wrench := MATH.generalized_gyro_wrench(momentum, velocity)
	var next := MATH.semi_implicit_momentum_step(momentum, wrench, 1.0e-7)
	_check(absf(MATH.vector_dot(momentum, momentum) - MATH.vector_dot(next, next)) < 1.0e-10,
		"gyroscopic step did not conserve momentum norm")


func _test_scene_body() -> void:
	var profile: AmbientFluidProfile3D = PROFILE_RESOURCE
	var config := CONFIG.new()
	config.fluid_density_kg_m3 = 0.0
	config.body_density_kg_m3 = 500.0
	var body := BODY.new()
	body.profile = profile
	body.config = config
	body.fluid_enabled = false
	body.position = Vector3.ZERO
	root.add_child(body)
	await process_frame
	var start_y := body.global_position.y
	var vacuum_tensor := body.combined_tensor()[21]
	body.set_fluid_density_kg_m3(998.0)
	body.set_fluid_enabled(true)
	_check(body.combined_tensor()[21] > vacuum_tensor,
		"fluid density change did not rebuild combined tensor")
	body.set_fluid_enabled(false)
	var previous_inertia := body.inertia
	body.set_body_mass_kg(body.mass * 2.0)
	_check(body.combined_tensor()[21] > vacuum_tensor,
		"body mass change did not rebuild combined tensor")
	_check(body.inertia.x > previous_inertia.x,
		"derived Jolt inertia did not follow body mass")
	body.set_body_inertia_diagonal_kg_m2(Vector3(2.0, 3.0, 4.0))
	_check(body.inertia == Vector3(2.0, 3.0, 4.0),
		"explicit body inertia did not synchronize with Jolt")
	for _frame in 30:
		await physics_frame
	_check(body.finite_state(), "scene body state became non-finite")
	_check(body.collision_layer == 0 and body.collision_mask == 0,
		"ambient fluid body has collision enabled")
	_check(profile.format_version == AmbientFluidProfile3D.FORMAT_ANALYTIC
		and profile.slip_matrix.is_empty(), "ambient fluid body is not using analytic profile")
	_check(body.global_position.y < start_y, "scene body did not fall under gravity")
	_check(body.combined_tensor()[21] > 0.0, "scene body tensor was not built")
	body.queue_free()
	await process_frame
	_finish("ambient_fluid")


func _matrix_near(a: PackedFloat64Array, b: PackedFloat64Array, tolerance: float) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - b[i]) > tolerance:
			return false
	return true
