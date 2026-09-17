extends "res://tests/test_case.gd"

const SCENE := preload("res://scenes/ambient_fluid_demo.tscn")
const PREPROCESSOR := preload("res://scripts/ambient_fluid/ambient_fluid_preprocessor.gd")
const BODY := preload("res://scripts/ambient_fluid/ambient_fluid_body_3d.gd")
const CONFIG := preload("res://scripts/ambient_fluid/ambient_fluid_config.gd")
const PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_pool_is_labeled_approximation()
	await _test_geometry_correspondence()
	await _test_deterministic_reset()
	for scenario_index in range(1, 5):
		await _test_scientific_scenario(scenario_index)
	await _test_csv_export()
	await _test_scaling_benchmark()
	_finish("ambient_fluid_validation")


func _test_pool_is_labeled_approximation() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	var entries: Dictionary = demo.menu._entries
	_check(entries.has("Experiment/Scenario"), "scenario selector is missing")
	_check(entries.has("Experiment/Fluid Model"), "fluid model selector is missing")
	_check(entries.has("Experiment/Vacuum Baseline"), "vacuum baseline toggle is missing")
	_check(entries.has("Experiment/Fluid Density"), "fluid density control is missing")
	_check(entries.has("Experiment/Dynamic Viscosity"), "viscosity control is missing")
	_check(entries.has("Experiment/Separation Angle"), "separation control is missing")
	var partial: float = demo._sample_medium_density(Vector3(0.0, 0.4, 0.0), 0.5)
	_check(partial > 0.0 and partial < demo.MEDIUM_DENSITIES[0],
		"pool approximation no longer exposes partial immersion")
	demo.queue_free()
	await process_frame


func _test_geometry_correspondence() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	var mesh: ArrayMesh = demo._mesh_for(0)
	var rebuilt: AmbientFluidProfile3D = PREPROCESSOR.build_profile(mesh, 998.0)
	_check(rebuilt != null, "canonical sphere mesh failed BEM preprocessing")
	if rebuilt != null:
		_check(rebuilt.source_mesh_hash == demo.SPHERE_PROFILE.source_mesh_hash,
			"sphere render mesh and BEM profile hashes differ")
		_check(absf(rebuilt.volume_m3 - demo.SPHERE_PROFILE.volume_m3) < 1.0e-6,
			"sphere render mesh and BEM profile volumes differ")
	var collision: Shape3D = demo._collision_for(0)
	_check(collision is ConvexPolygonShape3D and collision.points.size() == 12,
		"sphere collision does not use canonical icosahedron")
	demo.queue_free()
	await process_frame


func _test_deterministic_reset() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._object_index = 3
	demo._reset_experiment()
	demo._throw_object()
	var first: AmbientFluidBody3D = demo.bodies.back()
	var first_position := first.position
	var first_velocity := first.config.initial_velocity_m_s
	var first_profile := first.profile.resource_path
	demo._reset_experiment()
	demo._throw_object()
	var second: AmbientFluidBody3D = demo.bodies.back()
	_check(second.position == first_position, "reset did not reproduce throw position")
	_check(second.config.initial_velocity_m_s == first_velocity,
		"reset did not reproduce throw velocity")
	_check(second.profile.resource_path == first_profile, "reset did not reproduce random object")
	demo.queue_free()
	await process_frame


func _test_scientific_scenario(scenario_index: int) -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._set_scenario(scenario_index)
	_check(demo.bodies.size() == 2, "scientific scenario did not create fluid/vacuum pair")
	if demo.bodies.size() != 2:
		demo.queue_free()
		await process_frame
		return
	var fluid: AmbientFluidBody3D = demo.bodies[0]
	var vacuum: AmbientFluidBody3D = demo.bodies[1]
	_check(fluid.fluid_enabled and not vacuum.fluid_enabled,
		"scientific scenario fluid/vacuum flags are wrong")
	_check(not fluid.medium_density_sampler.is_valid() and not fluid.medium_velocity_sampler.is_valid(),
		"scientific scenario uses spatial medium samplers")
	_check(fluid.config.fluid_density_kg_m3 == vacuum.config.fluid_density_kg_m3,
		"vacuum baseline changed initial fluid configuration")
	_check(fluid.config.body_density_kg_m3 == vacuum.config.body_density_kg_m3,
		"vacuum baseline changed body density")
	_check(fluid.config.initial_velocity_m_s == vacuum.config.initial_velocity_m_s,
		"vacuum baseline changed initial velocity")
	_check(fluid.config.initial_spin_rad_s == vacuum.config.initial_spin_rad_s,
		"vacuum baseline changed initial spin")
	var velocity_divergence := 0.0
	var fluid_vy_checkpoint := 0.0
	var vacuum_vy_checkpoint := 0.0
	for frame in 120:
		await physics_frame
		_check(fluid.finite_state() and vacuum.finite_state(),
			"scientific scenario produced non-finite state")
		if frame == 30:
			velocity_divergence = (fluid.linear_velocity - vacuum.linear_velocity).length()
			fluid_vy_checkpoint = fluid.linear_velocity.y
			vacuum_vy_checkpoint = vacuum.linear_velocity.y
	# The vacuum twin is the no-coupling baseline (same config, spawned 4 m
	# apart), so raw separation is trivially large. The coupling must instead
	# push the fluid body's velocity off the baseline's within the first
	# second, before both bodies settle on the pool floor in scenarios 1/4.
	# Measured divergence: 0.025 (falling plate), 0.054 (Magnus), 7.4
	# (balloon), 4.4 (underwater) m/s; the threshold sits under the weakest.
	_check(velocity_divergence > 0.01,
		"fluid coupling did not push the trajectory off the vacuum baseline "
		+ "(%.4f m/s divergence at the checkpoint)" % velocity_divergence)
	match scenario_index:
		3:
			_check(fluid_vy_checkpoint > 0.5 and vacuum_vy_checkpoint < -0.5,
				"balloon scenario: fluid body must rise while the vacuum baseline falls "
				+ "(fluid vy=%.2f, vacuum vy=%.2f)" % [fluid_vy_checkpoint, vacuum_vy_checkpoint])
		4:
			_check(fluid_vy_checkpoint > vacuum_vy_checkpoint + 1.0,
				"underwater scenario: fluid drag must slow the body relative to the "
				+ "vacuum baseline (fluid vy=%.2f, vacuum vy=%.2f)" % [
					fluid_vy_checkpoint, vacuum_vy_checkpoint])
	if scenario_index == 2:
		_check(fluid.integration_substeps() >= 1, "Magnus scenario integration did not run")
	demo.queue_free()
	await process_frame


func _test_csv_export() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	for _frame in 4:
		await physics_frame
	var path := "/tmp/ambient_fluid_trajectory_test.csv"
	demo._export_csv(path)
	_check(FileAccess.file_exists(path), "trajectory CSV was not exported")
	var text := FileAccess.get_file_as_string(path)
	_check(text.begins_with("physics_frame,body,x_m,y_m,z_m"), "trajectory CSV header is wrong")
	_check(demo._trajectory_rows.size() <= demo.TRAJECTORY_LIMIT, "trajectory CSV exceeded bound")
	DirAccess.remove_absolute(path)
	demo.queue_free()
	await process_frame


func _test_scaling_benchmark() -> void:
	for body_count in [1, 25, 50, 100, 200]:
		var group := Node3D.new()
		root.add_child(group)
		for index in body_count:
			var config := CONFIG.new()
			config.fluid_density_kg_m3 = 1.204
			config.dynamic_viscosity_pa_s = 1.81e-5
			config.body_density_kg_m3 = 500.0
			config.initial_velocity_m_s = Vector3(5.0, 0.0, 0.0)
			var body: AmbientFluidBody3D = BODY.new()
			body.profile = PROFILE
			body.config = config
			body.profiling = true
			body.contacts_enabled = true
			body.position = Vector3((index % 20) * 3.0, 30.0 + (index / 20) * 3.0, 0.0)
			var collision := CollisionShape3D.new()
			var shape := SphereShape3D.new()
			shape.radius = 1.0
			collision.shape = shape
			body.add_child(collision)
			group.add_child(body)
		await process_frame
		for _frame in 3:
			await physics_frame
		var integration_us := 0
		var surface_us := 0
		for body: AmbientFluidBody3D in group.get_children():
			integration_us += body.integration_cpu_time_us()
			surface_us += body.surface_cpu_time_us()
			_check(body.finite_state(), "benchmark body became non-finite")
		print("BENCHMARK ambient_fluid bodies=%d integration_us=%d surface_us=%d" % [
			body_count, integration_us, surface_us])
		_check(integration_us < 1000000, "ambient fluid benchmark exceeded one CPU second")
		group.queue_free()
		await process_frame
