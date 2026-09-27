extends "res://tests/test_case.gd"

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const CONFIG := preload("res://scripts/ambient_fluid/ambient_fluid_config.gd")
const BODY := preload("res://scripts/ambient_fluid/ambient_fluid_body_3d.gd")
const PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")
const PLATE_PROFILE := preload("res://resources/ambient_fluid/plate_bem.tres")
const BODY_PROFILE := preload("res://resources/ambient_fluid/body_bem.tres")


func _initialize() -> void:
	_test_config()
	_test_surface_zero()
	_test_pressure_separation()
	_test_pressure_incidence_side()
	_test_pressure_symmetry()
	_test_magnus_symmetry()
	_test_drag_dissipation()
	_test_convergence_and_terminal_speed()
	_test_semidirect_coupling_contract()
	call_deferred("_test_runtime_quality")


func _test_config() -> void:
	var config := CONFIG.new()
	_check(config.validate() == "", "phase 3 default config is invalid")
	config.dynamic_viscosity_pa_s = -1.0
	_check(config.validate() != "", "negative dynamic viscosity was accepted")
	config.dynamic_viscosity_pa_s = 0.001
	config.separation_angle_rad = PI * 0.25
	_check(config.validate() != "", "separation angle below PI/2 was accepted")


func _test_surface_zero() -> void:
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var result := _surface(velocity, PI * 0.5, 0.001002)
	_check(_wrench_norm(result.pressure) <= 1.0e-12, "zero velocity produced pressure")
	_check(int(result.attached_faces) == 0, "zero velocity attached faces")
	var vacuum := _surface(velocity, PI * 0.5, 0.001002, 0.0)
	_check(_wrench_norm(vacuum.pressure) <= 1.0e-12, "vacuum produced pressure")


func _test_pressure_separation() -> void:
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var half := _surface(velocity, PI * 0.5, 0.0)
	var wide := _surface(velocity, PI * 0.75, 0.0)
	var attached := _surface(velocity, PI, 0.0)
	_check(int(half.attached_faces) == 8, "PI/2 did not select upstream hemisphere")
	_check(int(half.attached_faces) <= int(wide.attached_faces),
		"attached faces decreased with separation angle")
	_check(int(wide.attached_faces) <= int(attached.attached_faces),
		"attached faces did not grow monotonically")
	_check(int(attached.attached_faces) == PROFILE.face_centers_m.size(),
		"PI did not retain all faces")
	var full_power := MATH.vector_dot(attached.pressure, velocity)
	_check(_wrench_norm(half.pressure) > 0.0,
		"separation angle did not change the partial pressure integral")
	_check(absf(full_power) < 1.0e-6,
		"full attached pressure did not cancel on closed sphere")


func _test_pressure_incidence_side() -> void:
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var slip_matrix := PackedFloat64Array()
	slip_matrix.resize(18)
	var upstream := MATH.potential_pressure_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([Vector3.LEFT]), PackedFloat64Array([1.0]), slip_matrix,
		velocity, 1000.0, PI * 0.5)
	var downstream := MATH.potential_pressure_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([Vector3.RIGHT]), PackedFloat64Array([1.0]), slip_matrix,
		velocity, 1000.0, PI * 0.5)
	var half_wet := MATH.potential_pressure_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([Vector3.LEFT]), PackedFloat64Array([1.0]), slip_matrix,
		velocity, 1000.0, PI * 0.5, PackedFloat64Array([0.5]))
	var dry := MATH.potential_pressure_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([Vector3.LEFT]), PackedFloat64Array([1.0]), slip_matrix,
		velocity, 1000.0, PI * 0.5, PackedFloat64Array([0.0]))
	_check(int(upstream.attached_faces) == 1 and upstream.pressure[3] > 0.0,
		"body-relative flow did not load the upstream face")
	_check(int(downstream.attached_faces) == 0,
		"separation model attached the downstream face as the upstream side")
	_check(absf(half_wet.pressure[3] - upstream.pressure[3] * 0.5) < 1.0e-6
		and int(dry.attached_faces) == 0 and _wrench_norm(dry.pressure) == 0.0,
		"BEM pressure did not follow each face's clipped wet area")


func _test_pressure_symmetry() -> void:
	var positive := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var negative := PackedFloat64Array([0.0, 0.0, 0.0, -1.0, 0.0, 0.0])
	var positive_result := _surface(positive, PI * 0.5, 0.0)
	var negative_result := _surface(negative, PI * 0.5, 0.0)
	_check(absf(positive_result.pressure[3] + negative_result.pressure[3]) < 1.0e-4,
		"pressure inversion symmetry failed")
	_check(absf(MATH.vector_dot(positive_result.pressure, positive)) > 0.0,
		"positive direction pressure was empty")


func _test_drag_dissipation() -> void:
	for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP,
		Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		for candidate: AmbientFluidProfile3D in [PROFILE, PLATE_PROFILE, BODY_PROFILE]:
			var velocity := PackedFloat64Array([0.0, 0.0, 0.0,
				direction.x, direction.y, direction.z])
			var drag := MATH.particle_drag_wrench(velocity, 0.001002, 998.0,
				candidate.volume_m3, 1.0, candidate.total_area_m2)
			_check(MATH.vector_dot(drag, velocity) < 0.0,
				"particle drag power is not dissipative for %s" % candidate.resource_path)
	var inviscid_velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var inviscid_drag := MATH.particle_drag_wrench(inviscid_velocity, 0.0, 998.0,
		PROFILE.volume_m3, 1.0, PROFILE.total_area_m2)
	_check(is_finite(inviscid_drag[3]) and inviscid_drag[3] < 0.0,
		"zero-viscosity particle drag did not reach the finite high-Re limit")


func _test_magnus_symmetry() -> void:
	var positive_spin := PackedFloat64Array([0.0, 1.0, 0.0, 5.0, 0.0, 0.0])
	var negative_spin := PackedFloat64Array([0.0, -1.0, 0.0, 5.0, 0.0, 0.0])
	var positive := _surface(positive_spin, PI * 0.5, 0.0, 1.204)
	var negative := _surface(negative_spin, PI * 0.5, 0.0, 1.204)
	_check(absf(positive.pressure[5] + negative.pressure[5]) < 1.0e-5,
		"opposite spin did not reverse Magnus force")
	_check(absf(positive.pressure[5]) > 1.0e-5,
		"Magnus force was empty")


func _test_shape_dissipation() -> void:
	for candidate: AmbientFluidProfile3D in [PROFILE, PLATE_PROFILE, BODY_PROFILE]:
		for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP,
			Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
			var velocity := PackedFloat64Array([0.0, 0.0, 0.0,
				direction.x, direction.y, direction.z])
			var result := _surface_with_profile(candidate, velocity, PI * 0.5, 0.0, 998.0)
			_check(MATH.vector_dot(result.pressure, velocity) <= 1.0e-10,
				"pressure power is not dissipative for %s" % candidate.resource_path)


func _test_runtime_quality() -> void:
	await _test_scene_body()
	await _test_galilean_invariance()
	await _test_demo_scenarios()
	await _test_rotational_convergence()
	await _test_torque_free_angular_momentum()
	await _test_coupled_gyroscopic_stability()
	_finish("ambient_fluid_phase3")


func _test_scene_body() -> void:
	var config := CONFIG.new()
	config.fluid_density_kg_m3 = 998.0
	config.dynamic_viscosity_pa_s = 0.001002
	config.body_density_kg_m3 = 998.0
	config.initial_velocity_m_s = Vector3.RIGHT
	var body := BODY.new()
	body.profile = PROFILE
	body.config = config
	body.fluid_enabled = true
	body.position = Vector3(0.0, 5.0, 0.0)
	root.add_child(body)
	await process_frame
	await physics_frame
	_check(body.finite_state(), "phase 3 body state became non-finite")
	_check(body.linear_velocity.x > 0.9, "initial velocity was lost on the first physics tick")
	_check(body.surface_faces() > 0, "phase 3 body did not evaluate surface faces")
	_check(is_finite(body.pressure_power_w()), "phase 3 body pressure power is not finite")
	_check(body.friction_power_w() < 0.0, "phase 3 body friction power is not dissipative")
	var pressure_force := body.global_transform.basis * Vector3(body.pressure_wrench()[3],
		body.pressure_wrench()[4], body.pressure_wrench()[5])
	_check(absf(pressure_force.dot(body.linear_velocity)) \
		< pressure_force.length() * body.linear_velocity.length() * 1.0e-2 + 1.0e-6,
		"BEM pressure duplicated the empirical longitudinal particle drag")
	_check(body.surface_cpu_time_us() >= 0, "phase 3 surface CPU time was not recorded")
	body.reset_state(body.global_transform, Vector3.RIGHT, Vector3.ZERO)
	await physics_frame
	_check(body.surface_faces() > 0, "high-Reynolds body did not evaluate pressure before threshold crossing")
	body.reset_state(body.global_transform, Vector3.RIGHT * 1.0e-6, Vector3.ZERO)
	await physics_frame
	_check(body.surface_faces() == 0 and _wrench_norm(body.pressure_wrench()) <= 1.0e-12,
		"sub-threshold substep retained a stale pressure wrench")
	body.set_fluid_enabled(false)
	await physics_frame
	_check(body.pressure_wrench().size() == MATH.MATRIX_SIZE,
		"vacuum body pressure wrench has wrong size")
	_check(_wrench_norm(body.pressure_wrench()) <= 1.0e-12,
		"disabled fluid retained pressure wrench")
	body.queue_free()
	await process_frame


func _test_galilean_invariance() -> void:
	var config := CONFIG.new()
	config.fluid_density_kg_m3 = 998.0
	config.dynamic_viscosity_pa_s = 0.001002
	config.body_density_kg_m3 = 998.0
	config.initial_velocity_m_s = Vector3(4.0, 0.0, 0.0)
	var body := BODY.new()
	body.profile = PROFILE
	body.config = config
	body.medium_velocity_sampler = func(_position: Vector3) -> Vector3:
		return Vector3(4.0, 0.0, 0.0)
	root.add_child(body)
	while body._pending_reset:
		await physics_frame
	_check(body.linear_velocity.distance_to(Vector3(4.0, 0.0, 0.0)) < 1.0e-3,
		"matched body/fluid velocity is not Galilean invariant: %s" % body.linear_velocity)
	_check(_wrench_norm(body.pressure_wrench()) < 1.0e-8,
		"matched body/fluid velocity produced pressure")
	_check(_wrench_norm(body.friction_wrench()) < 1.0e-8,
		"matched body/fluid velocity produced friction")
	body.queue_free()
	await process_frame


func _test_demo_scenarios() -> void:
	var demo: Node = load("res://scenes/ambient_fluid_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	await process_frame
	var entries: Dictionary = demo.menu._entries
	_check(entries.has("Experiment/Fluid"), "fluid control is missing")
	_check(entries.has("Experiment/Object"), "object control is missing")
	_check(entries.has("Experiment/Object Density"), "density control is missing")
	_check(demo.bodies.size() == 4, "starter buoyancy set was not spawned")
	_check(demo.water_surface.visible and demo.liquid_sides.visible,
		"water visuals are hidden in water mode")
	_check(absf(demo._sample_medium_density(Vector3(0.0, -2.0, 0.0), 0.5) - 998.0) < 1.0e-6,
		"pool medium sampler does not return full water density")
	_check(absf(demo._sample_medium_density(Vector3(0.0, 2.0, 0.0), 0.5) - 998.0) < 1.0e-6,
		"pool medium density depends on object height")
	var pool_body: AmbientFluidBody3D = demo.bodies[0]
	pool_body.reset_state(Transform3D(pool_body.global_transform.basis,
		Vector3(-4.4, demo.WATER_LEVEL - 0.2, -1.0)), Vector3.RIGHT * 4.0, Vector3.ZERO)
	await physics_frame
	_check(pool_body.surface_faces() > 0,
		"partially submerged pool body did not evaluate its wet BEM faces")
	var initial_count: int = demo.bodies.size()
	demo._throw_object()
	_check(demo.bodies.size() == initial_count + 1, "throw did not add one object")
	var thrown: AmbientFluidBody3D = demo.bodies.back()
	_check(thrown.global_position.y > demo.WATER_LEVEL,
		"throw did not spawn above the pool")
	_check(absf(thrown.global_position.x) <= 5.4 and absf(thrown.global_position.z) <= 3.4,
		"throw did not spawn inside pool bounds")
	_check(thrown.config.initial_velocity_m_s.length() >= 2.25
		and thrown.config.initial_velocity_m_s.length() <= 5.0,
		"throw speed was not randomized inside configured range")
	demo._set_medium(3)
	_check(not demo.water_surface.visible and not demo.liquid_sides.visible,
		"water visuals stayed visible in air mode")
	_check(absf(demo._sample_medium_density(Vector3.ZERO, 0.5) - 1.204) < 1.0e-6,
		"air mode density is wrong")
	demo._clear_objects()
	demo._drop_buoyancy_set()
	_check(is_equal_approx(demo.bodies[0].config.body_density_kg_m3, 0.35),
		"air showcase does not include a sub-air-density object")
	demo._set_medium(4)
	_check(demo._sample_medium_density(Vector3.ZERO, 0.5) == 0.0,
		"vacuum mode has non-zero density")
	demo._clear_objects()
	demo._drop_buoyancy_set()
	_check(is_equal_approx(demo.bodies[0].config.body_density_kg_m3, 0.35),
		"vacuum showcase does not reuse the light comparison object")
	demo._clear_objects()
	_check(demo.bodies.is_empty(), "clear did not remove all objects")
	demo._reset_experiment()
	_check(demo.bodies.size() == 4, "reset did not restore starter set")
	demo.queue_free()
	await process_frame


func _test_rotational_convergence() -> void:
	var original_ticks := Engine.physics_ticks_per_second
	var results: Array[PackedFloat64Array] = []
	for frequency in [30, 60, 120, 240]:
		Engine.physics_ticks_per_second = frequency
		var config := CONFIG.new()
		config.fluid_density_kg_m3 = 1.204
		config.dynamic_viscosity_pa_s = 1.81e-5
		config.body_density_kg_m3 = 500.0
		config.initial_velocity_m_s = Vector3(5.0, 1.0, -2.0)
		config.initial_spin_rad_s = Vector3(4.0, 10.0, 2.0)
		var body := BODY.new()
		body.profile = BODY_PROFILE
		body.config = config
		body.fluid_enabled = true
		body.contacts_enabled = false
		body.body_inertia_diagonal_kg_m2 = Vector3(700.0, 950.0, 1200.0)
		body.transform = Transform3D(Basis(Vector3(1.0, 1.0, 0.0).normalized(), 0.6),
			Vector3(0.0, 20.0, 0.0))
		root.add_child(body)
		await process_frame
		for _frame in frequency:
			await physics_frame
		_check(body.finite_state(), "rotational convergence body became non-finite at %d Hz" % frequency)
		results.append(PackedFloat64Array([
			body.angular_velocity.x, body.angular_velocity.y, body.angular_velocity.z,
			body.linear_velocity.x, body.linear_velocity.y, body.linear_velocity.z,
		]))
		body.queue_free()
		await process_frame
	Engine.physics_ticks_per_second = original_ticks
	_check(_relative_vector_error(results[1], results[3]) < 0.08,
		"60/240 Hz rotational trajectories do not converge")
	_check(_relative_vector_error(results[2], results[3]) < 0.04,
		"120/240 Hz rotational trajectories do not converge")


func _test_torque_free_angular_momentum() -> void:
	var config := CONFIG.new()
	config.body_density_kg_m3 = 500.0
	config.initial_velocity_m_s = Vector3(2.0, 0.0, 0.0)
	config.initial_spin_rad_s = Vector3(3.0, 5.0, 2.0)
	var body := BODY.new()
	body.profile = PROFILE
	body.config = config
	body.fluid_enabled = false
	body.contacts_enabled = false
	body.body_inertia_diagonal_kg_m2 = Vector3(2.0, 3.0, 4.0)
	root.add_child(body)
	await process_frame
	while body._pending_reset:
		await physics_frame
	var reference := _world_angular_momentum(body)
	var reference_norm := reference.length()
	var worst_norm_drift := 0.0
	var worst_direction := 1.0
	for _frame in 120:
		await physics_frame
		_check(body.finite_state(), "torque-free gyro body became non-finite")
		var angular := _world_angular_momentum(body)
		worst_norm_drift = maxf(worst_norm_drift,
			absf(angular.length() - reference_norm) / reference_norm)
		worst_direction = minf(worst_direction,
			angular.normalized().dot(reference.normalized()))
	body.queue_free()
	await process_frame
	# No external torque acts on the vacuum anisotropic top, so the real loop's
	# R^T momentum propagation must conserve world-frame angular momentum up to
	# first-order integration error (measured: 0.8% norm drift, 0.9996
	# direction). Dropping or misapplying the rotation wobbles the direction by
	# radians as the body tumbles.
	_check(worst_norm_drift < 0.03,
		"torque-free angular momentum norm drifted %.4f on the real loop" % worst_norm_drift)
	_check(worst_direction > 0.99,
		"torque-free angular momentum direction drifted on the real loop (%.5f)" % worst_direction)


func _test_coupled_gyroscopic_stability() -> void:
	# Exercise the real loop with an analytic profile whose added mass couples
	# linear and angular motion. Passive drag may remove energy but must not pump it.
	var profile := AmbientFluidProfile3D.new()
	profile.format_version = AmbientFluidProfile3D.FORMAT_ANALYTIC
	profile.volume_m3 = 1.0
	profile.reference_density_kg_m3 = 998.0
	profile.added_mass_tensor = _coupled_added_mass_tensor()
	var config := CONFIG.new()
	config.fluid_density_kg_m3 = 998.0
	config.dynamic_viscosity_pa_s = 0.001002
	config.body_density_kg_m3 = 998.0
	config.initial_velocity_m_s = Vector3(1.5, 0.0, -0.4)
	config.initial_spin_rad_s = Vector3(1.0, 1.6, 0.7)
	var body := BODY.new()
	body.profile = profile
	body.config = config
	body.contacts_enabled = false
	body.body_inertia_diagonal_kg_m2 = Vector3(2.0, 3.0, 4.0)
	root.add_child(body)
	await process_frame
	while body._pending_reset:
		await physics_frame
	var first_energy := body.kinetic_energy_j()
	var maximum_energy := first_energy
	var maximum_spin := body.angular_speed_rad_s()
	for _frame in 120:
		await physics_frame
		_check(body.finite_state(), "coupled gyro body became non-finite")
		maximum_energy = maxf(maximum_energy, body.kinetic_energy_j())
		maximum_spin = maxf(maximum_spin, body.angular_speed_rad_s())
	var final_spin: Vector3 = body.global_transform.basis.transposed() * body.angular_velocity
	body.queue_free()
	await process_frame
	var energy_growth := (maximum_energy - first_energy) / maxf(absf(first_energy), 1.0e-12)
	print("AMBIENT GYRO energy_growth=%.5f max_spin=%.4f final_spin=%s" % [
		energy_growth, maximum_spin, final_spin])
	_check(energy_growth < 0.015,
		"coupled gyroscopic step pumped %.4f of the energy on the real loop" % energy_growth)
	_check(maximum_spin < config.initial_spin_rad_s.length() * 2.0,
		"coupled gyroscopic loop exceeded its spin stability bound")


func _world_angular_momentum(body: AmbientFluidBody3D) -> Vector3:
	var momentum := body.current_generalized_momentum()
	return body.global_transform.basis * Vector3(momentum[0], momentum[1], momentum[2])


func _coupled_added_mass_tensor() -> PackedFloat64Array:
	var tensor := MATH.zero_matrix()
	tensor[21] = 500.0
	tensor[28] = 550.0
	tensor[35] = 450.0
	tensor[0] = 80.0
	tensor[7] = 100.0
	tensor[14] = 70.0
	tensor[4] = 0.3
	tensor[24] = 0.3
	tensor[11] = -0.25
	tensor[31] = -0.25
	tensor[15] = 0.2
	tensor[20] = 0.2
	return tensor


func _test_semidirect_coupling_contract() -> void:
	# The runtime gyroscopic term is semidirect_coupling_wrench: torque equals
	# the linear momentum crossed with the linear velocity, force stays zero.
	var momentum := PackedFloat64Array([0.0, 0.0, 0.0, 3.0, -1.0, 2.0])
	var velocity := PackedFloat64Array([0.5, -0.25, 1.0, 0.3, 0.0, -0.6])
	var wrench := MATH.semidirect_coupling_wrench(momentum, velocity)
	var expected_torque := Vector3(3.0, -1.0, 2.0).cross(Vector3(0.3, 0.0, -0.6))
	_check(absf(wrench[0] - expected_torque.x) < 1.0e-12
		and absf(wrench[1] - expected_torque.y) < 1.0e-12
		and absf(wrench[2] - expected_torque.z) < 1.0e-12,
		"semidirect coupling torque is not p_linear x v_linear")
	_check(absf(wrench[3]) + absf(wrench[4]) + absf(wrench[5]) < 1.0e-12,
		"semidirect coupling produced a force")


func _test_convergence_and_terminal_speed() -> void:
	var velocity_30 := _simulate_underwater(1.0 / 30.0, 3.0)
	var velocity_60 := _simulate_underwater(1.0 / 60.0, 3.0)
	var velocity_120 := _simulate_underwater(1.0 / 120.0, 3.0)
	var velocity_240 := _simulate_underwater(1.0 / 240.0, 3.0)
	_check(is_finite(velocity_30), "30 Hz underwater integration is unbounded")
	_check(absf(velocity_60 - velocity_240) / maxf(absf(velocity_240), 1.0) < 0.01,
		"60/240 Hz underwater trajectories do not converge")
	_check(absf(velocity_120 - velocity_240) / maxf(absf(velocity_240), 1.0) < 0.005,
		"120/240 Hz underwater trajectories do not converge")
	var terminal_29 := _simulate_underwater(1.0 / 120.0, 29.0)
	var terminal_30 := _simulate_underwater(1.0 / 120.0, 30.0)
	_check(absf(terminal_30 - terminal_29) < maxf(absf(terminal_30) * 0.01, 0.02),
		"underwater body did not approach a terminal speed: v29=%.6f v30=%.6f" % [
			terminal_29, terminal_30])


func _simulate_underwater(delta: float, duration: float) -> float:
	var density := 998.0
	var body_density := 1200.0
	var body_mass: float = body_density * PROFILE.volume_m3
	var inertia := Vector3.ONE * (0.4 * body_mass)
	var combined := MATH.matrix_add(MATH.diagonal_matrix(inertia, body_mass),
		MATH.matrix_scale(PROFILE.added_mass_tensor,
			density / PROFILE.reference_density_kg_m3))
	var inverse := MATH.matrix_inverse(combined)
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for _step in int(round(duration / delta)):
		var momentum := MATH.matrix_vector_multiply(combined, velocity)
		var wrench := MATH.gravity_buoyancy_wrench(body_mass,
			density * PROFILE.volume_m3, Vector3(0.0, -9.8, 0.0),
			PROFILE.center_of_volume_m)
		wrench = MATH.vector_add(wrench,
			MATH.semidirect_coupling_wrench(momentum, velocity))
		var surface := _surface_with_profile(PROFILE, velocity, PI * 0.5,
			0.001002, density)
		wrench = MATH.vector_add(wrench,
			surface.pressure)
		wrench = MATH.vector_add(wrench, MATH.particle_drag_wrench(velocity,
			0.001002, density, PROFILE.volume_m3, 1.0, PROFILE.total_area_m2))
		velocity = MATH.matrix_vector_multiply(inverse,
			MATH.semi_implicit_momentum_step(momentum, wrench, delta))
	return velocity[4]


func _surface(velocity: PackedFloat64Array, angle: float, viscosity: float,
		density := 998.0) -> Dictionary:
	return _surface_with_profile(PROFILE, velocity, angle, viscosity, density)


func _surface_with_profile(profile: AmbientFluidProfile3D, velocity: PackedFloat64Array,
		angle: float, _viscosity: float, density: float) -> Dictionary:
	return MATH.potential_pressure_wrench(profile.face_centers_m, profile.face_normals,
		profile.face_areas_m2, profile.slip_matrix, velocity, density, angle)


func _relative_vector_error(first: PackedFloat64Array, second: PackedFloat64Array) -> float:
	var difference := 0.0
	var scale := 0.0
	for index in first.size():
		difference += pow(first[index] - second[index], 2.0)
		scale += second[index] * second[index]
	return sqrt(difference) / maxf(sqrt(scale), 1.0)
