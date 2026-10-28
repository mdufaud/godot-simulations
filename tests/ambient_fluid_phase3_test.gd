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
	_test_sphere_drag_coefficient()
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
	var leading := 0
	for normal in PROFILE.face_normals:
		if normal.x > 1.0e-6:
			leading += 1
	_check(int(half.attached_faces) == leading,
		"PI/2 attached %d faces, the leading hemisphere has %d" % [half.attached_faces, leading])
	for face_index in PROFILE.face_centers_m.size():
		if PROFILE.face_normals[face_index].x < -1.0e-6:
			var lone := MATH.surface_wrench(
				PackedVector3Array([PROFILE.face_centers_m[face_index]]),
				PackedVector3Array([PROFILE.face_normals[face_index]]),
				PackedFloat64Array([PROFILE.face_areas_m2[face_index]]),
				velocity, 998.0, 0.0, PI * 0.5, PROFILE.surface_length_m())
			_check(int(lone.attached_faces) == 0, "a trailing face kept attached flow at PI/2")
	_check(int(half.attached_faces) <= int(wide.attached_faces),
		"attached faces decreased with separation angle")
	_check(int(wide.attached_faces) <= int(attached.attached_faces),
		"attached faces did not grow monotonically")
	_check(int(attached.attached_faces) == PROFILE.face_centers_m.size(),
		"PI did not retain all faces")
	_check(half.pressure[3] < 0.0, "separated flow did not produce drag")
	_check(absf(MATH.vector_dot(attached.pressure, velocity)) < 1.0e-6,
		"fully attached pressure did not cancel on a closed symmetric body (d'Alembert)")


func _test_pressure_incidence_side() -> void:
	# One face moving obliquely: the leading side (normal along the motion) keeps
	# attached flow and feels the slip suction -1/2 rho |u_s|^2 A n; the
	# trailing side separates at PI/2.
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 1.0, 0.0])
	var leading := _single_face(Vector3.RIGHT, velocity, PackedFloat64Array())
	var trailing := _single_face(Vector3.LEFT, velocity, PackedFloat64Array())
	var half_wet := _single_face(Vector3.RIGHT, velocity, PackedFloat64Array([0.5]))
	var dry := _single_face(Vector3.RIGHT, velocity, PackedFloat64Array([0.0]))
	_check(int(leading.attached_faces) == 1 and absf(leading.pressure[3] + 500.0) < 1.0e-6,
		"leading face did not carry -1/2 rho |u_s|^2 A n: %s" % leading.pressure)
	_check(int(trailing.attached_faces) == 0 and _wrench_norm(trailing.pressure) == 0.0,
		"trailing face kept attached flow at PI/2")
	_check(absf(half_wet.pressure[3] - leading.pressure[3] * 0.5) < 1.0e-6
		and int(dry.attached_faces) == 0 and _wrench_norm(dry.pressure) == 0.0,
		"surface pressure did not follow each face's clipped wet area")
	var head_on := _single_face(Vector3.RIGHT,
		PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0]), PackedFloat64Array())
	_check(int(head_on.attached_faces) == 1 and _wrench_norm(head_on.pressure) == 0.0,
		"a stagnation face (no slip) carried dynamic pressure")


func _test_pressure_symmetry() -> void:
	var positive := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var negative := PackedFloat64Array([0.0, 0.0, 0.0, -1.0, 0.0, 0.0])
	var positive_result := _surface(positive, PI * 0.5, 0.0)
	var negative_result := _surface(negative, PI * 0.5, 0.0)
	_check(absf(positive_result.pressure[3] + negative_result.pressure[3]) < 1.0e-4,
		"pressure inversion symmetry failed")
	_check(MATH.vector_dot(positive_result.pressure, positive) < 0.0,
		"positive direction pressure did not oppose the motion")


func _test_drag_dissipation() -> void:
	# At PI/2 every attached face moves into the fluid (n.zdot > 0), so its
	# -1/2 rho |u_s|^2 A n does negative work; friction (Blasius and the Stokes
	# extension) dissipates at every separation angle. Checked on every shipped
	# shape for random spins and velocities, not only symmetric translations.
	var rng := RandomNumberGenerator.new()
	rng.seed = 2601
	for candidate: AmbientFluidProfile3D in [PROFILE, PLATE_PROFILE, BODY_PROFILE]:
		for case_index in 48:
			var velocity := PackedFloat64Array()
			for axis in 6:
				velocity.append(rng.randf_range(-4.0, 4.0))
			if case_index < 6:
				velocity = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
				velocity[3 + (case_index >> 1)] = 1.0 if case_index % 2 == 0 else -1.0
			var viscosity: float = [0.001002, 1.81e-5, 185.13][case_index % 3]
			var half := _surface_with_profile(candidate, velocity, PI * 0.5, viscosity, 998.0)
			var wide := _surface_with_profile(candidate, velocity, PI * 0.8, viscosity, 998.0)
			_check(MATH.vector_dot(half.pressure, velocity) <= 1.0e-9,
				"PI/2 pressure power is not dissipative for %s" % candidate.resource_path)
			_check(MATH.vector_dot(half.friction, velocity) < 0.0
				and MATH.vector_dot(wide.friction, velocity) < 0.0,
				"friction power is not dissipative for %s" % candidate.resource_path)
			if case_index < 6:
				var direction := Vector3(velocity[3], velocity[4], velocity[5])
				var force := Vector3(half.pressure[3], half.pressure[4], half.pressure[5]) \
					+ Vector3(half.friction[3], half.friction[4], half.friction[5])
				_check(force.dot(direction) < 0.0,
					"drag does not oppose %s motion for %s" % [direction, candidate.resource_path])
	var inviscid := _surface(PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0]), PI * 0.5, 0.0)
	_check(_wrench_norm(inviscid.friction) == 0.0 and inviscid.pressure[3] < 0.0,
		"zero viscosity kept friction or lost the inviscid pressure drag")


func _test_sphere_drag_coefficient() -> void:
	# Eq. 20 at PI/2 on a sphere: -1/2 rho v^2 integral of sin^2 cos over the
	# leading hemisphere = 1/2 rho v^2 (pi R^2 / 2), so C_D = 1/2. A finely
	# tessellated sphere converges to it.
	var sphere := _sphere_surface(1.0, 96, 48)
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 3.0, 0.0, 0.0])
	var result := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		velocity, 998.0, 0.0, PI * 0.5, sqrt(sphere.total_area))
	var drag_coefficient := -float(result.pressure[3]) / (0.5 * 998.0 * 9.0 * PI)
	print("AMBIENT SPHERE C_D=%.4f" % drag_coefficient)
	_check(absf(drag_coefficient - 0.5) < 0.01,
		"sphere pressure drag coefficient %.4f, expected 1/2" % drag_coefficient)
	# Stokes extension: exact Stokes drag and torque on the same sphere.
	var slow := PackedFloat64Array([0.0, 0.0, 0.0, 1.0e-4, 0.0, 0.0])
	var creeping := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		slow, 1420.0, 185.13, PI * 0.5, sqrt(sphere.total_area))
	var radius := sqrt(sphere.total_area / (4.0 * PI))
	var stokes_drag := 6.0 * PI * 185.13 * radius * 1.0e-4
	_check(absf(-float(creeping.friction[3]) - stokes_drag) < stokes_drag * 1.0e-3,
		"creeping sphere drag %.6f, Stokes %.6f" % [-float(creeping.friction[3]), stokes_drag])
	var spin := PackedFloat64Array([0.0, 2.0e-4, 0.0, 0.0, 0.0, 0.0])
	var turning := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		spin, 1420.0, 185.13, PI * 0.5, sqrt(sphere.total_area))
	var stokes_torque := 8.0 * PI * 185.13 * pow(radius, 3.0) * 2.0e-4
	_check(absf(-float(turning.friction[1]) - stokes_torque) < stokes_torque * 2.0e-3,
		"creeping sphere torque %.6f, Stokes %.6f" % [-float(turning.friction[1]), stokes_torque])
	# Blasius friction (Eq. 22) on a spinning sphere scales as w^1.8.
	var fast := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		PackedFloat64Array([0.0, 100.0, 0.0, 0.0, 0.0, 0.0]), 998.0, 0.001002, PI,
		sqrt(sphere.total_area))
	var faster := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		PackedFloat64Array([0.0, 200.0, 0.0, 0.0, 0.0, 0.0]), 998.0, 0.001002, PI,
		sqrt(sphere.total_area))
	var ratio := float(faster.friction[1]) / float(fast.friction[1])
	_check(float(fast.friction[1]) < 0.0 and absf(ratio - pow(2.0, 1.8)) < 0.02,
		"Blasius spin friction ratio %.4f, expected 2^1.8" % ratio)


func _test_magnus_symmetry() -> void:
	var positive_spin := PackedFloat64Array([0.0, 1.0, 0.0, 5.0, 0.0, 0.0])
	var negative_spin := PackedFloat64Array([0.0, -1.0, 0.0, 5.0, 0.0, 0.0])
	var positive := _surface(positive_spin, PI * 0.5, 0.0, 1.204)
	var negative := _surface(negative_spin, PI * 0.5, 0.0, 1.204)
	_check(absf(positive.pressure[5] + negative.pressure[5]) < 1.0e-5,
		"opposite spin did not reverse Magnus force")
	# w x v = (0, 1, 0) x (5, 0, 0) = (0, 0, -5): the faster-slipping side pulls.
	_check(positive.pressure[5] < -1.0e-5,
		"Magnus force %.6f does not point along w x v" % positive.pressure[5])
	var sphere := _sphere_surface(0.11, 96, 48)
	var ball := MATH.surface_wrench(sphere.centers, sphere.normals, sphere.areas,
		PackedFloat64Array([0.0, 60.0, 0.0, 25.0, 0.0, 0.0]), 1.204, 1.81e-5, PI * 0.5,
		sqrt(sphere.total_area))
	_check(ball.pressure[5] < 0.0 and absf(ball.pressure[4]) < absf(ball.pressure[5]) * 1.0e-3,
		"spinning ball lift is not along w x v: %s" % ball.pressure)


func _test_runtime_quality() -> void:
	await _test_scene_body()
	await _test_galilean_invariance()
	await _test_demo_scenarios()
	await _test_rotational_convergence()
	await _test_torque_free_angular_momentum()
	await _test_slow_turn_reaches_jolt()
	await _test_magnus_curve()
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
	_check(pressure_force.dot(body.linear_velocity) < 0.0,
		"surface pressure did not oppose the body's motion")
	_check(body.surface_cpu_time_us() >= 0, "phase 3 surface CPU time was not recorded")
	body.reset_state(body.global_transform, Vector3.RIGHT * 1.0e-6, Vector3.ZERO)
	await physics_frame
	_check(_wrench_norm(body.pressure_wrench()) <= 1.0e-6,
		"a creeping body retained the previous tick's pressure wrench")
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
		var spin := body.current_angular_velocity()
		var velocity := body.current_linear_velocity()
		results.append(PackedFloat64Array([spin.x, spin.y, spin.z,
			velocity.x, velocity.y, velocity.z]))
		body.queue_free()
		await process_frame
	Engine.physics_ticks_per_second = original_ticks
	_check(_relative_vector_error(results[1], results[3]) < 0.08,
		"60/240 Hz rotational trajectories do not converge")
	_check(_relative_vector_error(results[2], results[3]) < 0.04,
		"120/240 Hz rotational trajectories do not converge")


func _test_torque_free_angular_momentum() -> void:
	# Ten seconds of a vacuum anisotropic top, slow (one symplectic Euler step
	# per tick) and fast (RK4 substeps). No torque acts about the centre of
	# mass, so world angular momentum and rotational energy must hold.
	for spin: Vector3 in [Vector3(3.0, 5.0, 2.0) * 0.3, Vector3(3.0, 5.0, 2.0),
			Vector3(20.0, 30.0, 10.0)]:
		var config := CONFIG.new()
		config.body_density_kg_m3 = 500.0
		config.initial_velocity_m_s = Vector3(2.0, 0.0, 0.0)
		config.initial_spin_rad_s = spin
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
		var reference_energy := _rotational_energy(body)
		var worst_norm_drift := 0.0
		var worst_direction := 1.0
		var worst_energy_drift := 0.0
		for _frame in 600:
			await physics_frame
			_check(body.finite_state(), "torque-free gyro body became non-finite")
			var angular := _world_angular_momentum(body)
			worst_norm_drift = maxf(worst_norm_drift,
				absf(angular.length() - reference.length()) / reference.length())
			worst_direction = minf(worst_direction,
				angular.normalized().dot(reference.normalized()))
			worst_energy_drift = maxf(worst_energy_drift,
				absf(_rotational_energy(body) - reference_energy) / reference_energy)
		var substeps := body.integration_substeps()
		body.queue_free()
		await process_frame
		print("AMBIENT TOP spin=%s substeps=%d norm=%.6f direction=%.8f energy=%.6f" % [
			spin, substeps, worst_norm_drift, worst_direction, worst_energy_drift])
		_check(worst_norm_drift < 0.005,
			"torque-free angular momentum norm drifted %.5f (spin %s)" % [worst_norm_drift, spin])
		_check(worst_direction > 0.99999,
			"torque-free angular momentum direction drifted (%.7f, spin %s)" % [worst_direction, spin])
		_check(worst_energy_drift < 0.005,
			"torque-free rotational energy drifted %.5f (spin %s)" % [worst_energy_drift, spin])


func _test_slow_turn_reaches_jolt() -> void:
	# A slow spin turns less than 0.009 rad a tick; Jolt must still be handed
	# the turn (Quaternion.get_axis() once collapsed it ~200-fold).
	for rate in [0.05, 0.3, 2.0]:
		var config := CONFIG.new()
		config.body_density_kg_m3 = 500.0
		config.initial_spin_rad_s = Vector3(0.0, rate, 0.0)
		var body := BODY.new()
		body.profile = PROFILE
		body.config = config
		body.fluid_enabled = false
		body.contacts_enabled = false
		body.gravity_scale = 0.0
		root.add_child(body)
		await process_frame
		while body._pending_reset:
			await physics_frame
		for _frame in 60:
			await physics_frame
		await physics_frame
		var basis := PhysicsServer3D.body_get_direct_state(body.get_rid()).transform.basis
		var turned := atan2(basis.z.x, basis.z.z)
		body.queue_free()
		await process_frame
		print("AMBIENT SLOW TURN rate=%.2f turned=%.5f expected=%.5f" % [rate, turned, rate * 61.0 / 60.0])
		_check(absf(turned - rate * 61.0 / 60.0) < absf(rate) * 0.03 + 1.0e-4,
			"a %.2f rad/s spin turned the Jolt pose %.5f rad in 61 ticks" % [rate, turned])


func _test_magnus_curve() -> void:
	# Paper Sec. 6.2 on the real loop: a ball spun about +y while flying along
	# +x curves toward w x v = -z; without spin it flies straight.
	var drift := []
	for spin in [0.0, 30.0, -30.0]:
		var config := CONFIG.new()
		config.fluid_density_kg_m3 = 1.204
		config.dynamic_viscosity_pa_s = 1.81e-5
		config.body_density_kg_m3 = 60.0
		config.initial_velocity_m_s = Vector3(20.0, 0.0, 0.0)
		config.initial_spin_rad_s = Vector3(0.0, spin, 0.0)
		var body := BODY.new()
		body.profile = PROFILE
		body.config = config
		body.contacts_enabled = false
		body.position = Vector3(0.0, 500.0, 0.0)
		root.add_child(body)
		await process_frame
		while body._pending_reset:
			await physics_frame
		for _frame in 90:
			await physics_frame
		drift.append(body.global_position.z)
		body.queue_free()
		await process_frame
	print("AMBIENT MAGNUS z: no spin %.3f, +y spin %.3f, -y spin %.3f" % drift)
	_check(absf(drift[0]) < 0.01, "a ball without spin drifted sideways")
	_check(drift[1] < -0.5 and drift[2] > 0.5,
		"spinning balls did not curve along w x v: %s" % [drift])


func _rotational_energy(body: AmbientFluidBody3D) -> float:
	var velocity := body.current_generalized_velocity()
	var momentum := body.current_generalized_momentum()
	return 0.5 * (velocity[0] * momentum[0] + velocity[1] * momentum[1]
		+ velocity[2] * momentum[2])


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
	return body.world_angular_momentum()


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
	# Both helpers work in double precision.
	var momentum := PackedFloat64Array([0.5, 1.5, -2.0, 3.0, -1.0, 2.0])
	var velocity := PackedFloat64Array([0.5, -0.25, 1.0, 0.3, 0.0, -0.6])
	var wrench := MATH.semidirect_coupling_wrench(momentum, velocity)
	var expected_torque := [-1.0 * -0.6 - 2.0 * 0.0, 2.0 * 0.3 - 3.0 * -0.6,
		3.0 * 0.0 - -1.0 * 0.3]
	_check(absf(wrench[0] - expected_torque[0]) < 1.0e-12
		and absf(wrench[1] - expected_torque[1]) < 1.0e-12
		and absf(wrench[2] - expected_torque[2]) < 1.0e-12,
		"semidirect coupling torque is not p_linear x v_linear")
	_check(absf(wrench[3]) + absf(wrench[4]) + absf(wrench[5]) < 1.0e-12,
		"semidirect coupling produced a force")
	# Eq. 4: (l x w + p x v, p x w).
	var gyro := MATH.gyroscopic_wrench(momentum, velocity)
	var spin_torque := [1.5 * 1.0 - -2.0 * -0.25, -2.0 * 0.5 - 0.5 * 1.0,
		0.5 * -0.25 - 1.5 * 0.5]
	var force := [-1.0 * 1.0 - 2.0 * -0.25, 2.0 * 0.5 - 3.0 * 1.0, 3.0 * -0.25 - -1.0 * 0.5]
	for axis in 3:
		_check(absf(gyro[axis] - spin_torque[axis] - expected_torque[axis]) < 1.0e-12
			and absf(gyro[axis + 3] - force[axis]) < 1.0e-12,
			"gyroscopic wrench does not match Eq. 4 on axis %d" % axis)
	# Isotropic linear inertia: p parallel to v, so p x v vanishes exactly even
	# for a fast body (float32 products would leave |p||v| * 1e-7).
	var parallel := MATH.semidirect_coupling_wrench(
		PackedFloat64Array([0.0, 0.0, 0.0, 1259.7 * 31.3, 1259.7 * -97.1, 1259.7 * 4.7]),
		PackedFloat64Array([0.0, 0.0, 0.0, 31.3, -97.1, 4.7]))
	_check(absf(parallel[0]) + absf(parallel[1]) + absf(parallel[2]) < 1.0e-6,
		"parallel momentum and velocity left a spurious gyroscopic torque")


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
			MATH.vector_add(surface.pressure, surface.friction))
		velocity = MATH.matrix_vector_multiply(inverse,
			MATH.semi_implicit_momentum_step(momentum, wrench, delta))
	return velocity[4]


func _surface(velocity: PackedFloat64Array, angle: float, viscosity: float,
		density := 998.0) -> Dictionary:
	return _surface_with_profile(PROFILE, velocity, angle, viscosity, density)


func _surface_with_profile(profile: AmbientFluidProfile3D, velocity: PackedFloat64Array,
		angle: float, viscosity: float, density: float) -> Dictionary:
	return MATH.surface_wrench(profile.face_centers_m, profile.face_normals,
		profile.face_areas_m2, velocity, density, viscosity, angle, profile.surface_length_m())


func _single_face(normal: Vector3, velocity: PackedFloat64Array,
		wet: PackedFloat64Array) -> Dictionary:
	return MATH.surface_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([normal]), PackedFloat64Array([1.0]), velocity, 1000.0, 0.0,
		PI * 0.5, 1.0, wet)


## Face centers, normals and areas of a UV sphere, for checks against
## closed-form sphere results.
func _sphere_surface(radius: float, segments: int, rings: int) -> Dictionary:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = segments
	mesh.rings = rings
	var faces := mesh.get_faces()
	var centers := PackedVector3Array()
	var normals := PackedVector3Array()
	var areas := PackedFloat64Array()
	var total_area := 0.0
	for base in range(0, faces.size(), 3):
		var cross := (faces[base + 1] - faces[base]).cross(faces[base + 2] - faces[base])
		var area := cross.length() * 0.5
		if area <= 1.0e-12:
			continue
		var center := (faces[base] + faces[base + 1] + faces[base + 2]) / 3.0
		var normal := cross.normalized()
		if normal.dot(center) < 0.0:
			normal = -normal
		centers.append(center)
		normals.append(normal)
		areas.append(area)
		total_area += area
	return {centers = centers, normals = normals, areas = areas, total_area = total_area}


func _relative_vector_error(first: PackedFloat64Array, second: PackedFloat64Array) -> float:
	var difference := 0.0
	var scale := 0.0
	for index in first.size():
		difference += pow(first[index] - second[index], 2.0)
		scale += second[index] * second[index]
	return sqrt(difference) / maxf(sqrt(scale), 1.0)
