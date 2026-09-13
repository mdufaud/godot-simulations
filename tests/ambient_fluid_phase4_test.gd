extends "res://tests/test_case.gd"

const BODY := preload("res://scripts/ambient_fluid/ambient_fluid_body_3d.gd")
const CONFIG := preload("res://scripts/ambient_fluid/ambient_fluid_config.gd")
const PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")

var _root: Node3D


func _initialize() -> void:
	_root = Node3D.new()
	get_root().add_child(_root)
	call_deferred("_run")


func _run() -> void:
	_add_ground()
	var fluid_body := _add_body("Fluid", Vector3(-2.0, 4.0, 0.0), true)
	var vacuum_body := _add_body("Vacuum", Vector3(2.0, 4.0, 0.0), false)
	await process_frame
	_test_contact_configuration(fluid_body)
	await _test_impacts([fluid_body, vacuum_body])
	for index in 8:
		var impact_body := _add_body("Impact%d" % index, Vector3(0.0, 4.0, 0.0), false)
		await process_frame
		await _test_impacts([impact_body])
		impact_body.queue_free()
		await process_frame
	await _test_reset_and_impulses(vacuum_body)
	_test_contact_toggle(vacuum_body)
	_test_fluid_toggle(fluid_body)
	_test_parameter_wake(fluid_body)
	fluid_body.queue_free()
	vacuum_body.queue_free()
	_root.queue_free()
	await process_frame
	_finish("ambient_fluid_phase4")


func _test_contact_configuration(body: AmbientFluidBody3D) -> void:
	_check(body.contacts_enabled, "phase 4 body contacts are disabled")
	_check(body.contact_monitor, "phase 4 contact monitor is disabled")
	_check(body.collision_layer == 1 and body.collision_mask == 1,
		"phase 4 body collision layer or mask is wrong")
	_check(body.continuous_cd, "phase 4 body CCD is disabled")
	_check(body.can_sleep, "phase 4 body sleep is disabled")
	_check(body.max_contacts_reported == 4, "phase 4 contact report budget is wrong")
	_check(body.contact_warning().contains("body inertia"),
		"phase 4 Jolt inertia warning is missing")


func _test_impacts(bodies: Array[AmbientFluidBody3D]) -> void:
	var contact_seen := PackedByteArray()
	contact_seen.resize(bodies.size())
	var minimum_heights := PackedFloat64Array()
	minimum_heights.resize(bodies.size())
	minimum_heights.fill(INF)
	var maximum_energy := 0.0
	for _frame in 90:
		await physics_frame
		for index in bodies.size():
			var body := bodies[index]
			if body.contact_count() > 0:
				contact_seen[index] = 1
			minimum_heights[index] = minf(minimum_heights[index], body.global_position.y)
			maximum_energy = maxf(maximum_energy, body.kinetic_energy_j())
			_check(body.finite_state(), "phase 4 impact produced a non-finite body state")
	_check(contact_seen.count(1) == bodies.size(), "phase 4 bodies did not contact the ground")
	for body in bodies:
		_check(body.global_position.y > 0.0, "phase 4 body tunneled below the ground")
	for minimum_height in minimum_heights:
		_check(minimum_height > -0.5, "phase 4 body tunneled deeply through the ground")
	_check(maximum_energy < 2.0e6, "phase 4 impact energy became unbounded")


func _test_reset_and_impulses(body: AmbientFluidBody3D) -> void:
	body.set_contacts_enabled(false)
	body.reset_state(Transform3D(Basis.IDENTITY, Vector3(0.0, 4.0, 0.0)),
		Vector3(3.0, 0.0, 0.0), Vector3(0.0, 10.0, 0.0))
	await physics_frame
	_check(body.linear_velocity.x > 2.9, "reset lost initial linear velocity")
	_check(body.angular_velocity.y > 9.0, "reset lost initial angular velocity")
	_check(body.integration_substeps() >= 2, "fast spin did not activate adaptive substeps")
	body.reset_state(Transform3D(Basis.IDENTITY, Vector3(0.0, 4.0, 0.0)),
		Vector3.ZERO, Vector3.ZERO)
	body.queue_impulses(Vector3(0.0, body.mass * 2.0, 0.0), Vector3(0.0, 100.0, 0.0))
	await physics_frame
	_check(body.linear_velocity.y > 1.5, "queued central impulse was lost after reset")
	_check(body.angular_velocity.y > 0.0, "queued torque impulse was lost after reset")


func _test_contact_toggle(body: AmbientFluidBody3D) -> void:
	body.sleeping = true
	body.set_contacts_enabled(false)
	_check(not body.sleeping, "contact disable did not wake the body")
	_check(not body.contact_monitor and body.collision_layer == 0 and body.collision_mask == 0,
		"contact disable did not clear collision configuration")
	_check(body.contact_count() == 0, "contact disable did not clear tracked contacts")
	_check(not body.body_entered.is_connected(body._on_contact_entered),
		"contact disable retained body_entered signal")
	body.set_contacts_enabled(true)
	_check(body.contact_monitor and body.collision_layer == 1 and body.collision_mask == 1,
		"contact re-enable did not restore collision configuration")


func _test_fluid_toggle(body: AmbientFluidBody3D) -> void:
	body.sleeping = true
	body.set_fluid_enabled(false)
	_check(not body.sleeping, "disabling fluid did not wake the body")
	_check(_wrench_norm(body.pressure_wrench()) <= 1.0e-12,
		"disabling fluid retained stale pressure wrench")
	_check(_wrench_norm(body.friction_wrench()) <= 1.0e-12,
		"disabling fluid retained stale friction wrench")


func _test_parameter_wake(body: AmbientFluidBody3D) -> void:
	body.set_contacts_enabled(true)
	body.sleeping = true
	body.set_fluid_density_kg_m3(850.0)
	_check(not body.sleeping, "fluid density change did not wake the body")
	body.sleeping = true
	body.set_dynamic_viscosity_pa_s(0.065)
	_check(not body.sleeping, "viscosity change did not wake the body")
	body.sleeping = true
	body.set_separation_angle_rad(PI * 0.75)
	_check(not body.sleeping, "separation change did not wake the body")
	body.sleeping = true
	body.set_body_inertia_diagonal_kg_m2(body.inertia * 1.01)
	_check(not body.sleeping, "inertia change did not wake the body")
	body.sleeping = true
	body.set_medium_velocity_sampler(func(_position: Vector3) -> Vector3: return Vector3.RIGHT)
	_check(not body.sleeping, "velocity sampler change did not wake the body")


func _add_ground() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.2, 20.0)
	shape.shape = box
	ground.add_child(shape)
	_root.add_child(ground)


func _add_body(body_name: String, position: Vector3, fluid_enabled: bool) -> AmbientFluidBody3D:
	var config := CONFIG.new()
	config.fluid_density_kg_m3 = 998.0
	config.dynamic_viscosity_pa_s = 0.001002
	config.body_density_kg_m3 = 1200.0
	config.initial_velocity_m_s = Vector3(0.0, -12.0, 0.0)
	var body := BODY.new()
	body.name = body_name
	body.profile = PROFILE
	body.config = config
	body.fluid_enabled = fluid_enabled
	body.contacts_enabled = true
	body.position = position
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	shape.shape = sphere
	body.add_child(shape)
	_root.add_child(body)
	return body
