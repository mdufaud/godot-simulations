extends "res://tests/test_case.gd"

const SCENE := preload("res://scenes/ambient_fluid_demo.tscn")
const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const CONTROLLER := preload("res://scripts/demos/ambient_fluid_controller.gd")
const SPHERE_PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")
const BOX_PROFILE := preload("res://resources/ambient_fluid/body_bem.tres")
const PLATE_PROFILE := preload("res://resources/ambient_fluid/plate_bem.tres")
const WATER_DENSITY := 998.0
const CUBE_SIZE := Vector3(1.8, 1.4, 1.0)
const WATER_LEVEL := 0.4


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_exact_cube_submersion()
	_test_wet_surface_force_centroid()
	_test_rotated_half_volume()
	_test_surface_continuity()
	_test_restoring_torque()
	_test_pool_viscous_drag()
	_test_rotational_drag_correlation()
	await _test_runtime_honey_drag()
	await _test_runtime_honey_entry_drag()
	await _test_runtime_pool_and_scientific_paths()
	await _test_runtime_air_to_water_transition()
	await _test_runtime_honey_1100_body()
	await _test_light_pool_throw_stability()
	await _test_pool_momentum_passivity()
	await _test_repeated_drop_mix()
	_finish("ambient_fluid_float")


func _test_exact_cube_submersion() -> void:
	var faces := _cube_faces()
	var submerged := MATH.clip_convex_mesh_below_plane(
		faces, Vector3.ZERO, Vector3.UP, 0.21)
	var expected_volume := CUBE_SIZE.x * CUBE_SIZE.z * 0.91
	_check(absf(float(submerged.volume_m3) - expected_volume) < 1.0e-6,
		"horizontal cube immersion volume is not exact")
	_check(absf(submerged.centroid_m.distance_to(Vector3(0.0, -0.245, 0.0))) < 1.0e-6,
		"horizontal cube center of buoyancy is wrong")
	var partial_faces := 0
	var moved_partial_centers := 0
	for fraction in submerged.wet_area_fractions:
		if fraction > 0.0 and fraction < 1.0:
			partial_faces += 1
	for face_index in submerged.wet_area_fractions.size():
		if submerged.wet_area_fractions[face_index] > 0.0 \
				and submerged.wet_area_fractions[face_index] < 1.0 \
				and submerged.wet_area_centers_m[face_index].distance_to(
					(faces[face_index * 3] + faces[face_index * 3 + 1]
						+ faces[face_index * 3 + 2]) / 3.0) > 1.0e-6:
			moved_partial_centers += 1
	_check(partial_faces > 0, "waterline did not clip any cube face")
	_check(moved_partial_centers > 0,
		"partial face immersion kept the full-face force centroid")
	var total_area := 0.0
	var wetted_area := 0.0
	for face_index in submerged.wet_area_fractions.size():
		var base: int = face_index * 3
		var face_area := (faces[base + 1] - faces[base]).cross(
			faces[base + 2] - faces[base]).length() * 0.5
		total_area += face_area
		wetted_area += face_area * submerged.wet_area_fractions[face_index]
	_check(absf(float(submerged.wetted_area_fraction) - wetted_area / total_area) < 1.0e-6,
		"partial immersion did not report its wetted surface area fraction")


func _test_rotated_half_volume() -> void:
	var controller: Node = CONTROLLER.new()
	var shapes := [
		{faces = _cube_faces(), volume = BOX_PROFILE.volume_m3, name = "cube"},
		{faces = _plate_faces(), volume = PLATE_PROFILE.volume_m3, name = "plate"},
		{faces = controller._pool_faces_for(0), volume = SPHERE_PROFILE.volume_m3, name = "icosahedron"},
	]
	for shape: Dictionary in shapes:
		for angle_degrees in [12.0, 37.0, 71.0]:
			var basis := Basis(Vector3.FORWARD, deg_to_rad(angle_degrees))
			var local_up := basis.transposed() * Vector3.UP
			var submerged := MATH.clip_convex_mesh_below_plane(shape.faces, Vector3.ZERO,
				local_up, 0.0)
			_check(absf(float(submerged.volume_m3) - float(shape.volume) * 0.5) < 1.0e-6,
				"rotated centrally symmetric %s did not displace half its volume" % shape.name)
			_check(local_up.dot(submerged.centroid_m) < 0.0,
				"rotated %s centroid did not remain below the water plane" % shape.name)
			if shape.name == "cube":
				var projected_x := absf(local_up.x) * CUBE_SIZE.x * 0.5
				var projected_y := absf(local_up.y) * CUBE_SIZE.y * 0.5
				var larger := maxf(projected_x, projected_y)
				var smaller := minf(projected_x, projected_y)
				var expected_centroid_projection := -(larger * 0.5 \
					+ smaller * smaller / (6.0 * larger))
				_check(absf(local_up.dot(submerged.centroid_m) \
					- expected_centroid_projection) < 1.0e-6,
					"rotated cube centroid projection is inaccurate at %.0f degrees" % angle_degrees)
	controller.free()


func _test_wet_surface_force_centroid() -> void:
	var center := Vector3(0.0, 0.0, 1.0)
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 1.0, 0.0])
	var slip_matrix := PackedFloat64Array()
	slip_matrix.resize(18)
	slip_matrix[3] = -1.0
	var result := MATH.potential_pressure_wrench(PackedVector3Array([Vector3.ZERO]),
		PackedVector3Array([Vector3.UP]), PackedFloat64Array([1.0]), slip_matrix,
		velocity, 1000.0, PI, PackedFloat64Array([1.0]),
		PackedVector3Array([center]))
	_check(absf(result.pressure[0] - 500.0) < 1.0e-6,
		"partial-face pressure torque used the whole-face center instead of wet centroid")


func _test_surface_continuity() -> void:
	var faces := _cube_faces()
	var dry := MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO, Vector3.UP, -0.7)
	var shallow := MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO,
		Vector3.UP, -0.699)
	var full := MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO, Vector3.UP, 0.7)
	var nearly_full := MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO,
		Vector3.UP, 0.699)
	_check(float(dry.volume_m3) == 0.0, "body touching the surface from above gained volume")
	_check(float(shallow.volume_m3) > 0.0 and float(shallow.volume_m3) < 0.01,
		"small waterline crossing did not produce a continuous shallow volume")
	_check(absf(float(full.volume_m3) - CUBE_SIZE.x * CUBE_SIZE.y * CUBE_SIZE.z) < 1.0e-6,
		"body touching the surface from below lost volume")
	_check(float(nearly_full.volume_m3) < float(full.volume_m3)
		and float(nearly_full.volume_m3) > float(full.volume_m3) - 0.01,
		"small waterline retreat did not produce a continuous volume")


func _test_restoring_torque() -> void:
	var faces := _cube_faces()
	var angle := deg_to_rad(8.0)
	var basis := Basis(Vector3.BACK, angle)
	var local_up := basis.transposed() * Vector3.UP
	var submerged := MATH.clip_convex_mesh_below_plane(faces, Vector3.ZERO,
		local_up, WATER_LEVEL - 0.19)
	var displaced_mass := WATER_DENSITY * float(submerged.volume_m3)
	var wrench := MATH.gravity_buoyancy_wrench(
		650.0 * CUBE_SIZE.x * CUBE_SIZE.y * CUBE_SIZE.z,
		displaced_mass, basis.transposed() * Vector3.DOWN * 9.8, submerged.centroid_m)
	var world_torque_z := (basis * Vector3(wrench[0], wrench[1], wrench[2])).z
	_check(world_torque_z * angle < 0.0, "buoyancy torque did not oppose the cube tilt")


func _test_pool_viscous_drag() -> void:
	var velocity := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, -1.0, 0.0])
	var full := MATH.particle_drag_wrench(velocity, 185.13, 1420.0,
		SPHERE_PROFILE.volume_m3, 1.0, SPHERE_PROFILE.total_area_m2)
	var half := MATH.particle_drag_wrench(velocity, 185.13, 1420.0,
		SPHERE_PROFILE.volume_m3, 0.5, SPHERE_PROFILE.total_area_m2)
	_check(full[4] > 0.0 and absf(half[4] - full[4] * 0.5) < 1.0e-6,
		"honey drag did not oppose sinking or follow immersion")
	var slow := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, -0.0001, 0.0])
	var cold := MATH.particle_drag_wrench(slow, 185.13, 1420.0,
		SPHERE_PROFILE.volume_m3, 1.0, SPHERE_PROFILE.total_area_m2)
	var warm := MATH.particle_drag_wrench(slow, 18.513, 1420.0,
		SPHERE_PROFILE.volume_m3, 1.0, SPHERE_PROFILE.total_area_m2)
	var equivalent_radius := pow(3.0 * SPHERE_PROFILE.volume_m3 / (4.0 * PI), 1.0 / 3.0)
	var stokes_force := 6.0 * PI * 185.13 * equivalent_radius * 0.0001
	_check(cold[4] > warm[4] * 8.0,
		"low-speed viscous drag did not respond to viscosity")
	_check(absf(cold[4]) >= stokes_force
		and absf(cold[4]) < stokes_force * 1.01,
		"low-Re sphere drag did not approach Stokes' law")
	var plate_radius := pow(3.0 * PLATE_PROFILE.volume_m3 / (4.0 * PI), 1.0 / 3.0)
	var plate_velocity := PackedFloat64Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	var plate_drag := MATH.particle_drag_wrench(plate_velocity, 185.13, 1420.0,
		PLATE_PROFILE.volume_m3, 1.0, PLATE_PROFILE.total_area_m2)
	var equivalent_sphere_drag := MATH.particle_drag_wrench(plate_velocity, 185.13, 1420.0,
		PLATE_PROFILE.volume_m3, 1.0, 4.0 * PI * plate_radius * plate_radius)
	_check(plate_drag[3] < equivalent_sphere_drag[3] * 0.75,
		"honey treated the flat plate as a sphere with the same volume")


func _test_rotational_drag_correlation() -> void:
	var radius := pow(3.0 * SPHERE_PROFILE.volume_m3 / (4.0 * PI), 1.0 / 3.0)
	var fluid_density := 998.0
	var viscosity := 0.001002
	for rotational_reynolds: float in [0.001, 10.0, 1000.0, 30000.0]:
		var angular_speed: float = rotational_reynolds * viscosity \
			/ (fluid_density * radius * radius)
		var velocity := PackedFloat64Array([0.0, angular_speed, 0.0, 0.0, 0.0, 0.0])
		var wrench := MATH.particle_drag_wrench(velocity, viscosity, fluid_density,
			SPHERE_PROFILE.volume_m3, 1.0, SPHERE_PROFILE.total_area_m2)
		var expected_torque := 0.0
		if rotational_reynolds < 6.03:
			expected_torque = 8.0 * PI * viscosity * pow(radius, 3.0) * angular_speed
		else:
			var torque_coefficient: float
			if rotational_reynolds < 20.37:
				torque_coefficient = 5.32 / sqrt(rotational_reynolds) \
					+ 37.2 / rotational_reynolds
			else:
				torque_coefficient = 6.45 / sqrt(rotational_reynolds) \
					+ 32.1 / rotational_reynolds
			expected_torque = 0.5 * fluid_density * pow(radius, 5.0) \
				* torque_coefficient * angular_speed * angular_speed
		_check(absf(absf(wrench[1]) - expected_torque) \
			<= maxf(expected_torque * 1.0e-6, 1.0e-20),
			"rotational drag disagreed with the sphere correlation at Reω=%.3f" \
			% rotational_reynolds)
		_check(MATH.vector_dot(wrench, velocity) <= 0.0,
			"rotational drag added energy at Reω=%.3f" % rotational_reynolds)
		if rotational_reynolds == 1000.0:
			var half_wet := MATH.particle_drag_wrench(velocity, viscosity, fluid_density,
				SPHERE_PROFILE.volume_m3, 0.5, SPHERE_PROFILE.total_area_m2)
			_check(absf(half_wet[1] - wrench[1] * 0.5) < 1.0e-12,
				"partial immersion did not scale rotational drag with wetted area")


func _test_runtime_honey_drag() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._clear_objects()
	var water_body: AmbientFluidBody3D = demo._spawn_body(0, 2600.0,
		Vector3(0.0, -1.0, 0.0), Vector3(0.0, -2.0, 0.0), Vector3.ZERO)
	for _frame in 30:
		await physics_frame
	var water_drop := -1.0 - water_body.global_position.y
	var water_speed := water_body.linear_velocity.length()
	demo._clear_objects()
	demo._set_medium(2)
	var honey_body: AmbientFluidBody3D = demo._spawn_body(0, 2600.0,
		Vector3(0.0, -1.0, 0.0), Vector3(0.0, -2.0, 0.0), Vector3.ZERO)
	for _frame in 30:
		await physics_frame
	var honey_drop := -1.0 - honey_body.global_position.y
	var honey_speed := honey_body.linear_velocity.length()
	var honey_pressure := _wrench_norm(honey_body.pressure_wrench())
	print("AMBIENT HONEY MOTION water_drop=%.3f honey_drop=%.3f water_speed=%.3f honey_speed=%.3f" % [
		water_drop, honey_drop, water_speed, honey_speed])
	_check(honey_drop < water_drop and honey_speed < water_speed,
		"runtime honey drag did not slow a sinking body compared with water")
	_check(honey_pressure <= 1.0e-12 and honey_body.surface_faces() == 0,
		"honey combined equivalent-sphere drag with the separate face-pressure model")
	_check(honey_body.friction_power_w() < 0.0,
		"runtime honey drag added energy to the falling body")
	demo.queue_free()
	await process_frame


func _test_runtime_honey_entry_drag() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._clear_objects()
	demo._set_medium(2)
	var body: AmbientFluidBody3D = demo._spawn_body(0, 2600.0,
		Vector3(0.0, 1.2, 0.0), Vector3(0.0, -1.0, 0.0), Vector3.ZERO)
	await physics_frame
	await physics_frame
	var volume_drag := MATH.particle_drag_wrench(body._last_wrench_generalized_velocity,
		185.13, 1420.0, body.profile.volume_m3, body.submerged_fraction,
		body.profile.total_area_m2)
	var area_drag := MATH.particle_drag_wrench(body._last_wrench_generalized_velocity,
		185.13, 1420.0, body.profile.volume_m3, body.wetted_area_fraction,
		body.profile.total_area_m2)
	_check(body.wetted_area_fraction > body.submerged_fraction,
		"honey entry used its tiny cap volume as the wetted drag area")
	_check(absf(body.friction_wrench()[4] - area_drag[4]) < 1.0e-6
		and area_drag[4] > volume_drag[4],
		"honey entry drag did not follow the clipped wetted surface")
	print("AMBIENT HONEY ENTRY volume_fraction=%.5f area_fraction=%.5f drag_y=%.2f" % [
		body.submerged_fraction, body.wetted_area_fraction, body.friction_wrench()[4]])
	demo.queue_free()
	await process_frame


func _test_runtime_pool_and_scientific_paths() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	_check(demo.bodies.size() == 4, "normal demo boot did not create the buoyancy mix")
	var icosahedron_inertia: Vector3 = demo._inertia_for(0, 2.0)
	_check(absf(icosahedron_inertia.x - 0.5788854382) < 1.0e-8
		and absf(icosahedron_inertia.x - icosahedron_inertia.y) < 1.0e-12
		and absf(icosahedron_inertia.y - icosahedron_inertia.z) < 1.0e-12,
		"sphere showcase inertia does not match its solid icosahedron mesh")
	for body: AmbientFluidBody3D in demo.bodies:
		_check(body.pool_buoyancy_enabled, "pool body boot omitted runtime buoyancy geometry")
	demo._process(0.0)
	_check(demo.demo_menu._status_label.text.contains("Total body mass:")
		and demo.demo_menu._status_label.text.contains("kg/m³ /"),
		"Live Result omitted body density and mass")
	demo._set_flow_speed(1.75)
	_check(demo._sample_medium_velocity(Vector3(0.0, WATER_LEVEL + 0.2, 0.0)) \
			== Vector3(1.75, 0.0, 0.0),
		"partially submerged body did not sample the pool current when its center was above water")
	demo._set_flow_speed(0.0)
	demo._clear_objects()
	await process_frame
	_check(demo.pool_effects.get_child_count() == 0,
		"Clear kept stale pool effects")
	var underfilled_cube: AmbientFluidBody3D = demo._spawn_body(1, 650.0,
		Vector3(-2.0, 0.3, 0.0), Vector3.ZERO, Vector3.ZERO)
	var overfilled_cube: AmbientFluidBody3D = demo._spawn_body(1, 650.0,
		Vector3(2.0, 0.076, 0.0), Vector3.ZERO, Vector3.ZERO)
	for _frame in 4:
		await physics_frame
	_check(underfilled_cube.linear_velocity.y < 0.0,
		"under-displaced cube did not accelerate toward its equilibrium height")
	_check(overfilled_cube.linear_velocity.y > 0.0,
		"over-displaced cube did not accelerate toward its equilibrium height")
	demo._clear_objects()
	await process_frame
	var cube: AmbientFluidBody3D = demo._spawn_body(1, 650.0,
		Vector3(0.0, 0.188, 0.0), Vector3.ZERO, Vector3.ZERO)
	for _frame in 240:
		await physics_frame
	var expected_fraction := cube.config.body_density_kg_m3 / WATER_DENSITY
	_check(absf(cube.submerged_fraction - expected_fraction) < 1.0e-4,
		"runtime cube immersed fraction %.4f, expected %.4f" % [
			cube.submerged_fraction, expected_fraction])
	_check(absf(cube.global_position.y - 0.188) < 0.03,
		"650 kg/m³ cube settled at y=%.3f instead of its float height" % cube.global_position.y)
	demo._clear_objects()
	var floating_sphere: AmbientFluidBody3D = demo._spawn_body(0, 400.0,
		Vector3(-3.0, 2.5, 0.0), Vector3.ZERO, Vector3.ZERO)
	var sinking_sphere: AmbientFluidBody3D = demo._spawn_body(0, 2600.0,
		Vector3(3.0, -0.5, 0.0), Vector3.ZERO, Vector3.ZERO)
	for _frame in 240:
		await physics_frame
	_check(floating_sphere.global_position.y > WATER_LEVEL - 0.3
		and floating_sphere.global_position.y < 1.5,
		"400 kg/m³ sphere did not remain afloat near the surface")
	_check(sinking_sphere.global_position.y < -0.7,
		"2600 kg/m³ sphere did not sink below its initial height")
	demo._set_medium(2)
	await physics_frame
	await process_frame
	_check(demo.pool_effects.get_child_count() == 0,
		"switching to honey kept water splash or foam effects")
	_check(demo.water_surface.material_override is StandardMaterial3D
		and demo.pool_floor.material_override is ShaderMaterial
		and demo.pool_floor.material_override.shader.resource_path.ends_with(
			"pool_lining.gdshader")
		and demo.get_node_or_null("Pool/LiquidSides/Front") == null,
		"honey retained the water surface shader, caustics, or a second front liquid layer")
	_check(absf(demo.demo_menu._viscosity_slider.value - 185.13) < 0.001,
		"honey slider did not show the selected viscosity")
	_check(demo.medium_label.text.contains("coriander, 5 °C"),
		"honey viscosity preset did not identify its measured sample and temperature")
	_check(absf(demo.bodies[0].config.dynamic_viscosity_pa_s - 185.13) < 0.001,
		"honey body did not receive the viscous drag preset")
	demo._set_custom_viscosity(25.0)
	demo._set_custom_fluid_density(1300.0)
	var custom_body: AmbientFluidBody3D = demo._spawn_body(0, 400.0,
		Vector3(0.0, -1.0, 0.0), Vector3.ZERO, Vector3.ZERO)
	_check(absf(custom_body.config.dynamic_viscosity_pa_s - 25.0) < 0.001
		and absf(custom_body.config.fluid_density_kg_m3 - 1300.0) < 0.001
		and absf(demo._sample_medium_density(Vector3.ZERO, 1.0) - 1300.0) < 0.001,
		"fluid sliders did not affect newly spawned bodies and sampled pool density")
	demo._set_medium(0)
	_check(demo.water_surface.material_override is ShaderMaterial,
		"returning to water did not restore the water surface shader")
	demo._set_medium(3)
	await physics_frame
	await process_frame
	_check(demo.pool_effects.get_child_count() == 0,
		"air medium kept pool foam or splash effects alive")
	_check(not demo.water_surface.visible and not demo.liquid_sides.visible,
		"air medium kept liquid surfaces visible")
	demo._set_scenario(1)
	await process_frame
	_check(demo.bodies.size() == 2 and demo.bodies[0].pool_buoyancy_faces_local.is_empty(),
		"scientific uniform scenario unexpectedly uses pool clipping")
	demo._set_medium(1)
	_check(not demo.bodies[0].pool_buoyancy_enabled,
		"changing fluid enabled pool clipping in a scientific scenario")
	demo.queue_free()
	await process_frame


func _test_light_pool_throw_stability() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._clear_objects()
	demo._object_density_kg_m3 = 35.0
	demo._throw_object()
	var body: AmbientFluidBody3D = demo.bodies.back()
	for _frame in 360:
		await physics_frame
		if body._invalid_state_reported or not body.finite_state():
			break
	_check(not body._invalid_state_reported and body.finite_state(),
		"light object throw produced a non-finite integration state")
	for medium in [1, 2, 0]:
		demo._set_medium(medium)
		for _frame in 120:
			await physics_frame
			if body._invalid_state_reported or not body.finite_state():
				break
		_check(not body._invalid_state_reported and body.finite_state(),
			"changing pool fluid produced a non-finite integration state")
	demo.queue_free()
	await process_frame


func _test_runtime_air_to_water_transition() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._clear_objects()
	demo._set_medium(3)
	var body: AmbientFluidBody3D = demo._spawn_body(0, 650.0,
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	for _frame in 10:
		await physics_frame
	var velocity_before := body.linear_velocity
	demo._set_medium(0)
	await physics_frame
	var velocity_after := body.linear_velocity
	print("AMBIENT AIR WATER before=%s after=%s immersion=%.4f mass=%.2f" % [
		velocity_before, velocity_after, body.submerged_fraction, body.mass])
	_check(body.finite_state() and body.submerged_fraction > 0.0,
		"Air-to-water switch invalidated the immersed body state")
	_check(velocity_after.y > velocity_before.y
		and velocity_after.distance_to(velocity_before) < 0.2,
		"Air-to-water switch did not apply buoyancy continuously")
	demo._clear_objects()
	await process_frame
	demo._set_medium(3)
	var dense_body: AmbientFluidBody3D = demo._spawn_body(0, 1100.0,
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	for _frame in 10:
		await physics_frame
	var dense_velocity_before := dense_body.linear_velocity
	demo._set_medium(0)
	await physics_frame
	var dense_velocity_after := dense_body.linear_velocity
	print("AMBIENT AIR WATER DENSE before=%s after=%s immersion=%.4f" % [
		dense_velocity_before, dense_velocity_after, dense_body.submerged_fraction])
	_check(dense_body.finite_state() and dense_body.submerged_fraction > 0.0
		and dense_velocity_after.y < dense_velocity_before.y
		and dense_velocity_after.distance_to(dense_velocity_before) < 0.2,
		"1100 kg/m³ Air-to-water switch had the wrong force or a velocity discontinuity")
	demo.queue_free()
	await process_frame


func _test_runtime_honey_1100_body() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	demo._clear_objects()
	demo._set_medium(2)
	var body: AmbientFluidBody3D = demo._spawn_body(0, 1100.0,
		Vector3(0.0, -2.8, 0.0), Vector3.ZERO, Vector3.ZERO)
	var initial_y := body.global_position.y
	var maximum_upward_speed := 0.0
	for _frame in 720:
		await physics_frame
		maximum_upward_speed = maxf(maximum_upward_speed, body.linear_velocity.y)
	print("AMBIENT HONEY 1100 start_y=%.3f end_y=%.3f max_up=%.3f final_up=%.3f immersion=%.4f friction_power=%.1f contacts=%d sleeping=%s" % [
		initial_y, body.global_position.y, maximum_upward_speed,
		body.linear_velocity.y, body.submerged_fraction, body.friction_power_w(),
		body.contact_count(), body.sleeping])
	_check(body.finite_state() and body.global_position.y > initial_y + 0.5,
		"1100 kg/m³ body did not rise in 1420 kg/m³ honey")
	_check(maximum_upward_speed < 2.0 and body.friction_power_w() <= 1.0e-6,
		"honey ascent exceeded the modeled terminal range or added energy")
	_check(absf(body.linear_velocity.y) < 0.1
		and absf(body.submerged_fraction - 1100.0 / 1420.0) < 0.03,
		"1100 kg/m³ body did not settle near neutral buoyancy in honey")
	demo.queue_free()
	await process_frame


func _test_repeated_drop_mix() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	for medium in 5:
		demo._clear_objects()
		demo._set_medium(medium)
		for press in 12:
			demo._drop_buoyancy_set()
			_check(demo.bodies.size() == (press + 1) * 4,
				"repeated Drop Mix replaced existing bodies")
			for old_index in range(demo.bodies.size() - 4):
				for new_index in range(demo.bodies.size() - 4, demo.bodies.size()):
					_check(demo.bodies[old_index].global_position.distance_to(
						demo.bodies[new_index].global_position) >= 2.4,
						"repeated Drop Mix spawned overlapping bodies")
			await physics_frame
			for body in demo.bodies:
				_check(not body._invalid_state_reported and body.finite_state(),
					"repeated Drop Mix produced a non-finite body state")
	demo.queue_free()
	await process_frame


func _test_pool_momentum_passivity() -> void:
	var demo: Node = SCENE.instantiate()
	root.add_child(demo)
	await process_frame
	var body: AmbientFluidBody3D = demo.bodies[0]
	var momentum := PackedFloat64Array([0.0, 0.0, 0.0, 10.0, 0.0, 0.0])
	var zero := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var sideways := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 10000.0, 0.0])
	var drag := PackedFloat64Array([0.0, 0.0, 0.0, -100000.0, 0.0, 0.0])
	var inverse := body.combined_inverse()
	var before := 0.5 * MATH.vector_dot(momentum,
		MATH.matrix_vector_multiply(inverse, momentum))
	var next := body._pool_momentum_step(momentum, zero, sideways, drag, 1.0 / 60.0)
	var after := 0.5 * MATH.vector_dot(next,
		MATH.matrix_vector_multiply(inverse, next))
	_check(after <= before + 1.0e-6 and after >= 0.0,
		"pool pressure and drag created kinetic energy")
	_check(next[3] >= -1.0e-6, "pool drag reversed momentum in one step")
	demo.queue_free()
	await process_frame


func _cube_faces() -> PackedVector3Array:
	var mesh := BoxMesh.new()
	mesh.size = CUBE_SIZE
	return mesh.get_faces()


func _plate_faces() -> PackedVector3Array:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.4, 0.18, 1.2)
	return mesh.get_faces()


func _wrench_norm(wrench: PackedFloat64Array) -> float:
	var squared_norm := 0.0
	for value in wrench:
		squared_norm += value * value
	return sqrt(squared_norm)
