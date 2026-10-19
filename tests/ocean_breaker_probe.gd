extends RefCounted

const Solver := preload("res://scripts/fluid/sph_fluid_solver.gd")
const FluidConfig := preload("res://scripts/fluid/fluid_config.gd")
const G := 9.81
const X_MIN := -18.0
const X_MAX := 20.0
const Y_MIN := -2.5
const Y_MAX := 4.0
const Z_MIN := -1.8
const Z_MAX := 1.8
const DEPTH := 2.0
const LEVEL := 0.0
const BED_SLOPE := 1.0 / 8.0
const DURATION_S := 8.0
const ROCK_CENTER := Vector3(17.5, 0.15, 0.0)
const ROCK_SIZE := Vector3(1.4, 1.8, 1.5)


static func run(tree: SceneTree, check: Callable, candidate: String = "sph", p2g_transfer: int = 0) -> void:
	print("BREAKER setup scenario=solitary_slope_rock seed=0 candidate=%s domain=(%.1f..%.1f, %.1f..%.1f, %.1f..%.1f) level=%.1f offshore_depth=%.1f slope=1:8 slope_parameter_S0=%.6f expected_regime=surging rock_center=%s rock_size=%s eta=0.9*sech^2(sqrt(3*0.9/(4*2^3))*(x+8)) incident_velocity_profile=quadratic_depth_conservative u_mean=c*eta/(2+eta) v=continuity_integral c=sqrt(g*(2+0.9)) dt=1/60 duration=%.1f" % [
		candidate, X_MIN, X_MAX, Y_MIN, Y_MAX, Z_MIN, Z_MAX, LEVEL, DEPTH,
		1.521 * BED_SLOPE / sqrt(0.9 / DEPTH), str(ROCK_CENTER), str(ROCK_SIZE), DURATION_S])
	for spacing in [0.24, 0.18, 0.12]:
		if candidate == "apic":
			await _run_apic_rest(tree, check, spacing, p2g_transfer)
		await _run_resolution(tree, check, spacing, candidate, p2g_transfer)


static func build_solver(particle_spacing: float,
		pressure_stiffness_m2_s2: float = Solver.DEFAULT_PRESSURE_MULT,
		still_water: bool = false, include_rock: bool = true, bed_slope: float = BED_SLOPE) -> SphFluidSolver:
	if not is_finite(bed_slope) or bed_slope <= 0.0:
		push_error("Breaker bed slope must be finite and positive.")
		return null
	var x_max := DEPTH / bed_slope + 4.0
	var seed := _seed(particle_spacing, still_water, include_rock, bed_slope)
	@warning_ignore("integer_division")
	var count := seed.size() / 4
	var cell := particle_spacing * 2.0
	var config := FluidConfig.new()
	config.default_particle_count = count
	config.particle_counts = [count]
	config.texture_width = ceili(sqrt(float(count)))
	config.grid_origin = Vector3(X_MIN, Y_MIN, Z_MIN)
	config.domain_origin = config.grid_origin
	config.domain_size_m = Vector3(x_max - X_MIN, Y_MAX - Y_MIN, Z_MAX - Z_MIN)
	config.cell_size_m = cell
	config.grid_dims = Vector3i(
		ceili(config.domain_size_m.x / cell),
		ceili(config.domain_size_m.y / cell),
		ceili(config.domain_size_m.z / cell))
	var solver: SphFluidSolver = Solver.new()
	solver.config = config
	solver.particle_count = count
	solver.active_count = count
	solver.spacing = particle_spacing
	solver.material_density_kg_m3 = 1000.0
	solver.gravity = Vector3.DOWN * G
	solver.pressure_mult = pressure_stiffness_m2_s2
	solver.viscosity_strength = 0.0
	solver.collision_inflation = particle_spacing * 0.5
	solver.substeps = ceili((sqrt(solver.pressure_mult) + 10.0) / (60.0 * 0.4 * cell))
	solver.profiling = true
	solver.set_seed_positions(seed)
	solver.set_scene_obstacles(_obstacles(include_rock, bed_slope))
	return solver


static func run_boot(tree: SceneTree, check: Callable) -> void:
	for spacing in [0.24, 0.18, 0.12]:
		for candidate in ["sph", "apic"]:
			var solver = build_apic_solver(spacing) if candidate == "apic" else build_solver(spacing)
			RenderingServer.call_on_render_thread(solver.init_render)
			await RenderingServer.frame_post_draw
			if not solver.initialized:
				check.call(false, "breaker boot: solver did not initialize")
				continue
			var sample := {}
			RenderingServer.call_on_render_thread(_read_boot.bind(solver, sample))
			await RenderingServer.frame_post_draw
			print("BREAKER BOOT candidate=%s spacing_m=%.3f physical_time=%.6f particles=%d render_position_error_m=%.6f" % [
				candidate, spacing, solver._sim_time, solver.live_count(), float(sample.error)])
			check.call(bool(sample.finite) and float(sample.error) <= 0.000001 \
				and solver._sim_time == 0.0, "breaker boot: render positions do not match initial physical state")
			print("BREAKER BOOT candidate=%s obstacle_retention_error=%.6f" % [candidate, float(sample.retention_error)])
			check.call(float(sample.retention_error) <= 0.000001,
				"breaker boot: obstacle velocity retention was not transferred to GPU")
			var overlap := _seed_overlap(solver)
			print("BREAKER BOOT candidate=%s collision_inflation_m=%.6f initial_solid_overlap_m=%.6f" % [
				candidate, solver.collision_inflation, overlap])
			check.call(overlap <= 0.000001, "breaker boot: initial particles overlap collision geometry")
			RenderingServer.call_on_render_thread(solver.free_render)
			await RenderingServer.frame_post_draw


static func _read_boot(solver, result: Dictionary) -> void:
	var data: PackedFloat32Array = solver._rd.texture_get_data(solver.get_position_tex_rid(), 0).to_float32_array()
	var seed: PackedFloat32Array = solver._seed_data
	var error := 0.0
	var finite := data.size() >= seed.size()
	if finite:
		for particle in solver.live_count():
			for axis in 3:
				var index: int = particle * 4 + axis
				finite = finite and is_finite(data[index])
				error = maxf(error, absf(data[index] - seed[index]))
	var retention_error := 0.0
	if solver is ApicFluidSolver:
		var scene_data: PackedByteArray = solver._rd.buffer_get_data(solver._scene_ubo)
		for obstacle in solver.scene_obstacles.size():
			var expected := float(solver.scene_obstacles[obstacle].get("retention", 0.985))
			retention_error = maxf(retention_error, absf(scene_data.decode_float(908 + obstacle * 16) - expected))
	result.merge({"error": error if finite else INF, "finite": finite,
		"retention_error": retention_error})


static func _seed_overlap(solver) -> float:
	var overlap := 0.0
	var seed: PackedFloat32Array = solver._seed_data
	for obstacle: Dictionary in solver.scene_obstacles:
		var inverse: Transform3D = obstacle.transform.affine_inverse()
		var half_size: Vector3 = obstacle.size * 0.5 + Vector3.ONE * solver.collision_inflation
		for particle in solver.live_count():
			var index: int = particle * 4
			var local: Vector3 = inverse * Vector3(seed[index], seed[index + 1], seed[index + 2])
			var inside := half_size - local.abs()
			overlap = maxf(overlap, minf(inside.x, minf(inside.y, inside.z)))
	return overlap


static func build_apic_solver(particle_spacing: float, p2g_transfer: int = 0,
		grid_cell_size_m: float = 0.0, free_surface_cut_cells: bool = false,
		still_water: bool = false, requested_substeps: int = 0,
		conservative_amount_tracking: bool = false, conservative_surface_reconstruction: bool = false,
		amount_transport_order: int = 1, interface_distance_max_iterations: int = 64,
		geometric_surface: bool = false, flip_velocity_fraction: float = 0.0, pressure_iteration_budget: int = 256,
		include_rock: bool = true, bed_slope: float = BED_SLOPE):
	var template := build_solver(particle_spacing, Solver.DEFAULT_PRESSURE_MULT, still_water, include_rock, bed_slope)
	if template == null:
		return null
	var solver = load("res://scripts/fluid/apic_fluid_solver.gd").new()
	solver.config = template.config
	solver.particle_count = template.particle_count
	solver.active_count = template.active_count
	solver.spacing = template.spacing
	solver.grid_cell_size_m = grid_cell_size_m
	solver.free_surface_cut_cells = free_surface_cut_cells
	solver.conservative_amount_tracking = conservative_amount_tracking
	solver.conservative_surface_reconstruction = conservative_surface_reconstruction
	solver.amount_transport_order = amount_transport_order
	solver.interface_distance_max_iterations = interface_distance_max_iterations
	solver.amount_geometric_full_cell_flux = geometric_surface
	solver.pressure_surface_from_volume_planes = geometric_surface
	solver.flip_velocity_fraction = flip_velocity_fraction
	solver.pressure_iterations = pressure_iteration_budget
	solver.gravity = template.gravity
	solver.material_density_kg_m3 = template.material_density_kg_m3
	solver.collision_inflation = template.collision_inflation
	solver.substeps = template.substeps if requested_substeps == 0 else requested_substeps
	solver.p2g_transfer = p2g_transfer
	solver.profiling = template.profiling
	solver.set_seed_positions(template._seed_data)
	if free_surface_cut_cells:
		solver.set_seed_levelset(_seed_levelset(template.config, particle_spacing, grid_cell_size_m, still_water))
	solver.set_scene_obstacles(template.scene_obstacles)
	return solver


static func _seed_levelset(config: FluidConfig, particle_spacing: float,
		grid_cell_size_m: float, still_water: bool) -> PackedFloat32Array:
	var dx := particle_spacing * 2.0 if grid_cell_size_m == 0.0 else grid_cell_size_m
	if not is_finite(dx) or dx <= 0.0:
		return PackedFloat32Array()
	var dims := Vector3i(ceili(config.domain_size_m.x / dx),
		ceili(config.domain_size_m.y / dx), ceili(config.domain_size_m.z / dx))
	var values := PackedFloat32Array()
	values.resize(dims.x * dims.y * dims.z)
	var water_surface := PackedFloat32Array()
	water_surface.resize(dims.x)
	for x in dims.x:
		var world_x := config.domain_origin.x + (float(x) + 0.5) * dx
		water_surface[x] = LEVEL + (0.0 if still_water else _wave_eta(world_x))
	for z in dims.z:
		for y in dims.y:
			var world_y := config.domain_origin.y + (float(y) + 0.5) * dx
			for x in dims.x:
				values[(z * dims.y + y) * dims.x + x] = world_y - water_surface[x]
	return values


static func _run_apic_rest(tree: SceneTree, check: Callable, particle_spacing: float,
		p2g_transfer: int = 0) -> void:
	var solver = load("res://scripts/fluid/apic_fluid_solver.gd").new()
	var seed := PackedFloat32Array()
	for z in 20:
		for y in 8:
			for x in 32:
				seed.append_array([(float(x) + 0.5) * particle_spacing,
					(float(y) + 0.5) * particle_spacing,
					(float(z) + 0.5) * particle_spacing, 0.0])
	var config := FluidConfig.new()
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3(32, 16, 20) * particle_spacing
	config.default_particle_count = 5120
	config.particle_counts = [5120]
	config.texture_width = ceili(sqrt(5120.0))
	solver.config = config
	solver.particle_count = 5120
	solver.active_count = 5120
	solver.spacing = particle_spacing
	solver.gravity = Vector3.DOWN * G
	solver.p2g_transfer = p2g_transfer
	solver.set_seed_positions(seed)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC rest: initialization failed")
		return
	for _frame in 60:
		RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
		await RenderingServer.frame_post_draw
	var sample := {}
	RenderingServer.call_on_render_thread(_read_apic_rest.bind(solver, seed, sample))
	await RenderingServer.frame_post_draw
	print("BREAKER REST candidate=apic spacing=%.2f time=%.6f max_speed_m_s=%.6f max_displacement_m=%.6f projection=%s" % [
		particle_spacing, solver._sim_time, float(sample.max_speed), float(sample.max_displacement),
		str(sample.projection)])
	check.call(bool(sample.finite) and float(sample.max_speed) <= 0.01 \
		and float(sample.max_displacement) <= 0.01,
		"APIC rest: spontaneous motion exceeds 1 cm/s or 1 cm")
	var projection: Dictionary = sample.projection
	check.call(bool(projection.get("finite", false)) \
		and float(projection.get("divergence_max_s_inv", INF)) <= float(projection.pressure_tolerance_s_inv),
		"APIC rest: projected velocity did not reach the declared pressure tolerance")
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _read_apic_rest(solver, seed: PackedFloat32Array, result: Dictionary) -> void:
	var suffix := "a" if solver.current_parity() == 0 else "b"
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers["positions_" + suffix]).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers["velocities_" + suffix]).to_float32_array()
	var max_speed := 0.0
	var max_displacement := 0.0
	var finite := true
	var fastest := {}
	for index in solver.live_count():
		var offset: int = index * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		var seed_offset: int = roundi(velocities[offset + 3]) * 4 if solver is SphFluidSolver else offset
		var start := Vector3(seed[seed_offset], seed[seed_offset + 1], seed[seed_offset + 2])
		finite = finite and p.is_finite() and v.is_finite()
		if v.length() > max_speed:
			max_speed = v.length()
			fastest = {"position_m": p, "velocity_m_s": v, "seed_m": start}
		max_displacement = maxf(max_displacement, p.distance_to(start))
	result.merge({"finite": finite, "max_speed": max_speed,
		"max_displacement": max_displacement,
		"projection": solver.get_diagnostics() if solver is ApicFluidSolver else "unavailable"})
	result["fastest"] = fastest
	if solver is ApicFluidSolver and solver.conservative_surface_reconstruction:
		var cells: int = solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z
		var cl: int = solver._rd.compute_list_begin()
		solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 8),
			ceili(float(cells) / 256.0), 1, 1)
		solver._rd.compute_list_end()
		var phi: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
		var geometry: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_geometry).to_float32_array()
		var amounts: PackedByteArray = solver._rd.buffer_get_data(solver._buffers.surface_amount)
		var gx: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi_next).to_float32_array()
		var gy: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi_corrected).to_float32_array()
		var gz: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.residual).to_float32_array()
		var geometric_volume := 0.0
		var max_phi_shift := 0.0
		var worst := {}
		for cell in cells:
			var fraction := amounts.decode_float(ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES + 4)
			geometric_volume += fraction * pow(solver.grid_dx, 3.0)
			var shift := absf(phi[cell] - solver._seed_levelset[cell])
			if geometry[cell * 4 + 3] > 0.0 and absf(solver._seed_levelset[cell]) < solver.grid_dx * 2.0 and shift > max_phi_shift:
				max_phi_shift = shift
				var coordinate := Vector3i(cell % solver.grid_dims.x,
					(cell / solver.grid_dims.x) % solver.grid_dims.y, cell / (solver.grid_dims.x * solver.grid_dims.y))
				worst = {"cell": coordinate,
					"world_center_m": solver.grid_origin + (Vector3(coordinate) + Vector3.ONE * 0.5) * solver.grid_dx,
					"phi_m": phi[cell], "seed_phi_m": solver._seed_levelset[cell],
					"gradient": Vector3(gx[cell], gy[cell], gz[cell]), "fraction": fraction,
					"amount": amounts.decode_float(ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES), "capacity": geometry[cell * 4 + 3]}
		result["surface"] = {"amount": solver.get_liquid_amount_diagnostics_render(),
			"geometric_volume_m3": geometric_volume, "max_phi_shift_m": max_phi_shift, "worst_cell": worst}


static func run_apic_shore_rest(tree: SceneTree, check: Callable,
		candidate: String = "apic", pressure_stiffness_m2_s2: float = Solver.DEFAULT_PRESSURE_MULT,
		free_surface_cut_cells: bool = false, conservative_surface_reconstruction: bool = false,
		amount_transport_order: int = 1) -> void:
	for particle_spacing in [0.24, 0.12]:
		var solver = build_apic_solver(particle_spacing, 0, 0.0, free_surface_cut_cells, true, 0, conservative_surface_reconstruction, conservative_surface_reconstruction, amount_transport_order) if candidate == "apic" else build_solver(particle_spacing, pressure_stiffness_m2_s2, true)
		var seed: PackedFloat32Array = solver._seed_data
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "%s shore rest: solver failed to initialize" % candidate)
			continue
		for frame in 60:
			RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
			await RenderingServer.frame_post_draw
			if frame in [0, 4, 9, 29, 59]:
				var sample := {}
				RenderingServer.call_on_render_thread(_read_apic_rest.bind(solver, seed, sample))
				await RenderingServer.frame_post_draw
				var memory_report := str(solver.get_gpu_memory_bytes()) if candidate == "apic" else "unavailable"
				var pressure_report := "stiffness_m2_s2=%.3f near_stiffness_m2_s2=%.3f" % [solver.pressure_mult, solver.near_pressure_mult] if candidate == "sph" else "pressure_tolerance_s_inv=%.6f conservative_amount_tracking=%s surface_controls_pressure=%s" % [solver.pressure_tolerance_s_inv, str(solver.conservative_amount_tracking), str(solver.conservative_surface_reconstruction)]
				print("BREAKER SHORE REST scenario=still_slope_rock candidate=%s seed=0 seed_layout=world_vertical amplitude_m=0.0 water_level_m=%.3f depth_m=%.3f bed_slope=%.6f requested_spacing_m=%.3f applied_spacing_m=%.3f kernel_or_grid_cell_size_m=%.3f requested_time_s=%.6f physical_time_s=%.6f substeps=%d particles=%d memory_bytes=%s %s gpu_ms=%s render=unavailable max_speed_m_s=%.9f max_displacement_m=%.9f projection=%s" % [
					candidate, LEVEL, DEPTH, BED_SLOPE, particle_spacing, solver.spacing, solver.h,
					float(frame + 1) / 60.0, solver._sim_time, solver.last_substeps, solver.live_count(), memory_report,
					pressure_report, str(solver.get_timings()), float(sample.max_speed), float(sample.max_displacement),
					str(sample.projection)])
				if candidate == "apic" and solver.conservative_surface_reconstruction:
					print("BREAKER SHORE REST INTERFACE physical_time_s=%.6f fastest=%s surface=%s" % [
						solver._sim_time, str(sample.fastest), str(sample.surface)])
				check.call(bool(sample.finite) and float(sample.max_speed) <= 0.01
					and float(sample.max_displacement) <= 0.01,
					"%s shore rest: spontaneous motion exceeds 1 cm/s or 1 cm" % candidate)
				if candidate == "apic":
					var projection: Dictionary = sample.projection
					check.call(bool(projection.finite)
						and float(projection.divergence_max_s_inv) <= solver.pressure_tolerance_s_inv,
						"APIC shore rest: pressure projection exceeds the declared tolerance")
		check.call(absf(solver._sim_time - 1.0) <= 1.0e-6,
			"%s shore rest: simulation did not reach one physical second" % candidate)
		solver.profiling = false
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func _run_resolution(tree: SceneTree, check: Callable, particle_spacing: float,
		candidate: String, p2g_transfer: int = 0, grid_cell_size_m: float = 0.0,
		pressure_stiffness_m2_s2: float = Solver.DEFAULT_PRESSURE_MULT,
		free_surface_cut_cells: bool = false, duration_s: float = DURATION_S,
		requested_apic_substeps: int = 0, ticks_per_render_frame: int = 1,
		conservative_amount_tracking: bool = false, conservative_surface_reconstruction: bool = false,
		amount_transport_order: int = 1, interface_distance_max_iterations: int = 64,
		geometric_surface: bool = false, flip_velocity_fraction: float = 0.0, pressure_iteration_budget: int = 256,
		include_rock: bool = true, bed_slope: float = BED_SLOPE,
		projection_energy_diagnostics: bool = false) -> void:
	var solver = build_apic_solver(particle_spacing, p2g_transfer, grid_cell_size_m, free_surface_cut_cells, false, requested_apic_substeps, conservative_amount_tracking, conservative_surface_reconstruction, amount_transport_order, interface_distance_max_iterations, geometric_surface, flip_velocity_fraction, pressure_iteration_budget, include_rock, bed_slope) if candidate == "apic" else build_solver(particle_spacing, pressure_stiffness_m2_s2, false, include_rock, bed_slope)
	if solver == null:
		check.call(false, "breaker: invalid physical configuration")
		return
	if candidate == "apic":
		solver.projection_energy_diagnostics = projection_energy_diagnostics
	var seed: PackedFloat32Array = solver._seed_data
	var count: int = solver.particle_count
	RenderingServer.call_on_render_thread(solver.init_render)
	for _frame in 120:
		await RenderingServer.frame_post_draw
		if solver.initialized:
			break
	if not solver.initialized:
		check.call(false, "breaker: %s solver did not initialize at spacing %.2f" % [candidate, particle_spacing])
		solver.profiling = false
		return
	RenderingServer.call_on_render_thread(_set_seed_velocities.bind(solver, seed, false, bed_slope))
	await RenderingServer.frame_post_draw
	var initial_energy := {}
	if candidate == "apic":
		RenderingServer.call_on_render_thread(_read_apic_energy_render.bind(solver, initial_energy))
		await RenderingServer.frame_post_draw
		print("BREAKER ENERGY initial_state=%s boundary=closed external_work_j=0.000 gain_limit_over_initial_kinetic=0.050000 affine_measurement=full_quadratic_stencil_proxy" % str(initial_energy))
	var initial_volume_state := {}
	if candidate == "apic" and free_surface_cut_cells:
		RenderingServer.call_on_render_thread(_read_apic_initial_volume_render.bind(solver, initial_volume_state))
		await RenderingServer.frame_post_draw
		print("BREAKER VOLUME initial_state=%s boundary=closed volume_measurement=planar_cell_cube_cdf legacy_measurement=unit_distance_proxy geometric_accuracy=unavailable flux_m3_s=0.000 requested_duration_s=%.3f" % [
			str(initial_volume_state), duration_s])
	var represented_volume := float(count) * pow(particle_spacing, 3.0)
	var mass_kg: float = represented_volume * solver.material_density_kg_m3
	var pressure_report := "EOS requested_stiffness_m2_s2=%.3f applied_stiffness_m2_s2=%.3f near_stiffness_m2_s2=%.3f viscosity_coefficient=%.3f" % [
		pressure_stiffness_m2_s2, solver.pressure_mult, solver.near_pressure_mult, solver.viscosity_strength] if candidate == "sph" \
		else "MAC requested_grid_cell_size_m=%.6f applied_grid_cell_size_m=%.6f pressure_tolerance_s_inv=%.6f pressure_relaxation=%.3f viscosity_coefficient=0.000 p2g_transfer=%d free_surface_cut_cells=%s solid_cut_cells=%s conservative_amount_tracking=%s surface_controls_pressure=%s" % [grid_cell_size_m, solver.grid_dx, solver.pressure_tolerance_s_inv, solver.pressure_relaxation, solver.p2g_transfer, str(solver.free_surface_cut_cells), str(solver.free_surface_cut_cells and solver.solid_cut_cells), str(solver.conservative_amount_tracking), str(solver.conservative_surface_reconstruction)]
	print("BREAKER applied scenario=%s seed=0 seed_layout=world_vertical amplitude_m=0.9 offshore_depth_m=2.0 bed_slope=%.9f domain=%s expected_regime=%s incident_velocity_profile=quadratic_depth_conservative candidate=%s requested_spacing_m=%.3f applied_spacing_m=%.3f kernel_or_grid_m=%.3f requested_dt_s=0.016667 applied_dt_s=0.016667 applied_substeps=%d collision_inflation_m=%.3f %s" % [
		"solitary_slope_rock" if include_rock else "solitary_unobstructed_slope", bed_slope, str(AABB(solver.config.domain_origin, solver.config.domain_size_m)), "plunging" if is_equal_approx(bed_slope, 1.0 / 15.0) else "surging" if is_equal_approx(bed_slope, BED_SLOPE) else "unavailable", candidate, particle_spacing, solver.spacing, solver.h, solver.substeps,
		solver.collision_inflation, pressure_report])
	if candidate == "apic":
		print("BREAKER APIC PRESSURE BUDGET requested=%d applied=%d tolerance_s_inv=%.9f" % [pressure_iteration_budget, mini(maxi(solver.pressure_iterations, 0), ApicFluidSolver.PRESSURE_MAX_ITERATIONS), solver.pressure_tolerance_s_inv])
		print("BREAKER APIC COUPLING geometric_surface_requested=%s geometric_flux_applied=%s volume_plane_pressure_applied=%s geometric_split_applied=%s flip_velocity_fraction_requested=%.6f flip_velocity_fraction_applied=%.6f" % [
			str(geometric_surface), str(solver.amount_geometric_full_cell_flux), str(solver.pressure_surface_from_volume_planes), str(solver.amount_geometric_split_transport), flip_velocity_fraction, solver.flip_velocity_fraction])
	var last_sample := 0
	var gpu_samples := PackedFloat64Array()
	var max_overhang_volume := 0.0
	var max_rock_contact_count := 0
	var final_backwash_volume := 0.0
	var total_frames := roundi(duration_s * 60.0)
	print("BREAKER SCHEDULE physics_tick_s=0.016666667 ticks_per_render_frame=%d gpu_timing_scope=per_render_frame physical_time_scaling=1.000000" % ticks_per_render_frame)
	for frame in total_frames:
		RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
		var second := frame + 1
		var full_sample := second in [1, 180, 300, 480, 900] or second == total_frames \
			or (not include_rock and second in [30, 60]) \
			or (is_equal_approx(bed_slope, 1.0 / 15.0) and second in [330, 360, 390, 420])
		if second % ticks_per_render_frame == 0 or full_sample or second % 30 == 0:
			await RenderingServer.frame_post_draw
			var gpu_ms := float(solver.get_timings().get("total", -1.0))
			if frame >= 60 and gpu_ms >= 0.0:
				gpu_samples.append(gpu_ms)
		if full_sample or second % 30 == 0:
			var sample := {}
			RenderingServer.call_on_render_thread(_read_metrics.bind(solver, sample, candidate, full_sample, include_rock, bed_slope))
			await RenderingServer.frame_post_draw
			var label := float(second) / 60.0
			if candidate == "apic":
				var energy: Dictionary = sample.energy
				print("BREAKER ENERGY time_s=%.9f state=%s change_from_initial_j=%.9f change_over_initial_kinetic=%.9f" % [
					label, str(energy), float(energy.total_with_affine_proxy_j) - float(initial_energy.total_with_affine_proxy_j),
					(float(energy.total_with_affine_proxy_j) - float(initial_energy.total_with_affine_proxy_j)) / maxf(float(initial_energy.kinetic_j), 1.0e-9)])
				check.call(bool(energy.finite) and float(energy.total_with_affine_proxy_j)
					<= float(initial_energy.total_with_affine_proxy_j) + 0.05 * float(initial_energy.kinetic_j),
					"APIC closed energy: unforced gain exceeds 5% of initial kinetic energy")
				if projection_energy_diagnostics:
					print("BREAKER PROJECTION ENERGY time_s=%.9f state=%s" % [label, str(sample.projection_energy)])
				print("BREAKER PRESSURE HISTORY time_s=%.9f state=%s" % [label, str(sample.projection.projection_history)])
			max_overhang_volume = maxf(max_overhang_volume, float(sample.overhang_volume))
			max_rock_contact_count = maxi(max_rock_contact_count, int(sample.rock_contact_count))
			if second == total_frames:
				last_sample = second
				final_backwash_volume = float(sample.backwash_volume)
			if full_sample:
				var density_report := "%.3f" % float(sample.density_p95) if candidate == "sph" else "unavailable"
				var density_state_report := "time_s=%.6f revision=%d mask=height_column_clearance mask_cell_m=%.6f kernel_clearance_m=%.6f" % [float(sample.density_state_time_s), int(sample.density_state_revision), particle_spacing, solver.h] if candidate == "sph" else "unavailable"
				print("BREAKER candidate=%s spacing=%.2f t=%.3f particles=%d volume=%.3f mass=%.1f density_error_p95=%s density_state={%s} interior=%d finite=%d outside=%d solid_penetration=%.5f runup_x=%.3f crest=(%.3f,%.3f) max_speed=%.3f main_component_fraction=%.4f geometric_overhang_proxy_m3=%.6f rock_contact_count=%d backwash_m3=%.6f projection=%s volume_state=%s" % [
					candidate, particle_spacing, label, count, represented_volume, mass_kg,
					density_report, density_state_report, int(sample.interior), int(sample.finite),
					int(sample.outside), float(sample.penetration), float(sample.runup_x),
					float(sample.crest_x), float(sample.crest_y), float(sample.max_speed),
					float(sample.main_component_fraction), float(sample.overhang_volume),
					int(sample.rock_contact_count), float(sample.backwash_volume),
					str(sample.get("projection", "unavailable")), str(sample.get("volume_state", "unavailable"))])
				check.call(int(sample.finite) == count,
					"breaker: non-finite particle state at spacing %.2f t=%.3f" % [particle_spacing, label])
				check.call(int(sample.outside) == 0,
					"breaker: particles left configured domain at spacing %.2f t=%.3f" % [particle_spacing, label])
				check.call(float(sample.penetration) <= 0.02,
					"breaker: particles penetrated solid geometry at spacing %.2f t=%.3f" % [particle_spacing, label])
				if candidate == "sph":
					check.call(int(sample.interior) > 50 and float(sample.density_p95) <= 0.05,
						"breaker: interior density error exceeds 5%% or measurement is unavailable at spacing %.2f t=%.3f" % [particle_spacing, label])
				else:
					var projection: Dictionary = sample.projection
					check.call(bool(projection.get("finite", false)) \
						and float(projection.get("divergence_max_s_inv", INF)) <= float(projection.pressure_tolerance_s_inv)
						and int(projection.projection_history.failed_substeps) == 0
						and int(projection.projection_history.checked_substeps) == second * solver.last_substeps,
						"APIC breaker: projected velocity did not reach the declared pressure tolerance")
					if solver.free_surface_cut_cells:
						if solver.conservative_amount_tracking:
							var amount_state: Dictionary = sample.amount_state
							print("BREAKER AMOUNT time_s=%.9f state=%s geometric_volume_conservation_verified=false" % [label, str(amount_state)])
							check.call(bool(amount_state.finite) and bool(amount_state.transport_valid)
								and int(amount_state.failed_steps) == 0
								and absf(float(amount_state.transport_time_s) - label) <= 1.0e-5
								and float(amount_state.relative_amount_drift) <= 0.01,
								"APIC amount transport: closed-wave amount drift or transport time exceeds the declared limit")
							if solver.conservative_surface_reconstruction:
								check.call(float(amount_state.overfilled_amount_volume_m3) <= 0.01 * float(amount_state.initial_amount_volume_m3),
									"APIC conservative surface: overfilled cells exceed 1% of the liquid amount")
								check.call(bool(amount_state.interface_distance_converged),
									"APIC conservative surface: interface distance reconstruction did not converge")
								print("BREAKER INTERFACE GEOMETRY time_s=%.9f state=%s" % [label, str(sample.interface_geometry)])
						var volume_state: Dictionary = sample.volume_state
						check.call(bool(volume_state.finite)
							and absf(float(volume_state.physical_time_s) - label) <= 0.000001,
							"APIC breaker: volume field is invalid or not at the same physical time as particles")
						var initial_volume := float(initial_volume_state.planar_cell_volume_estimate_m3)
						var volume_drift := absf(float(volume_state.planar_cell_volume_estimate_m3) - initial_volume) / initial_volume
						var legacy_volume := float(initial_volume_state.linear_cell_volume_estimate_m3)
						var legacy_drift := absf(float(volume_state.linear_cell_volume_estimate_m3) - legacy_volume) / legacy_volume
						print("BREAKER VOLUME time_s=%.6f initial_planar_volume_estimate_m3=%.9f current_planar_volume_estimate_m3=%.9f relative_drift=%.9f legacy_unit_distance_proxy_drift=%.9f boundary_flux_m3_s=0.000 geometric_accuracy=unavailable" % [
							label, initial_volume, float(volume_state.planar_cell_volume_estimate_m3), volume_drift, legacy_drift])
						if duration_s >= 30.0 or solver.conservative_surface_reconstruction:
							check.call(volume_drift <= 0.01, "APIC closed volume: measured interface volume drift exceeds 1%")
			else:
				print("BREAKER SHAPE spacing=%.2f t=%.3f main_component_fraction=%.4f geometric_overhang_proxy_m3=%.6f rock_contact_count=%d backwash_m3=%.6f max_speed_m_s=%.9f" % [
					particle_spacing, label, float(sample.main_component_fraction),
					float(sample.overhang_volume), int(sample.rock_contact_count),
					float(sample.backwash_volume), float(sample.max_speed)])
	var timings: Dictionary = solver.get_timings()
	gpu_samples.sort()
	var gpu_p95 := str(gpu_samples[ceili(float(gpu_samples.size()) * 0.95) - 1]) if not gpu_samples.is_empty() else "unavailable"
	var memory_report := str(solver.get_gpu_memory_bytes()) if candidate == "apic" else "unavailable"
	print("BREAKER resolution candidate=%s spacing=%.2f particles=%d volume=%.3f mass=%.1f density=%.1f h=%.3f dt=0.016667 substeps=%d physical_time=%.9f requested_time=%.9f gpu_ms=%s gpu_p95_ms=%s samples=%d gpu_memory_bytes=%s overturning_verified=false max_geometric_overhang_proxy_m3=%.6f max_rock_contact_count=%d final_backwash_m3=%.6f render_ms=unavailable" % [
		candidate, particle_spacing, count, represented_volume, mass_kg, solver.material_density_kg_m3,
		solver.h, solver.last_substeps, solver._sim_time, duration_s, str(timings), gpu_p95,
		gpu_samples.size(), memory_report, max_overhang_volume, max_rock_contact_count, final_backwash_volume])
	check.call(absf(solver._sim_time - float(last_sample) / 60.0) < 0.00001,
		"breaker: simulation did not advance the requested physical duration")
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _read_apic_initial_volume_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	result.merge(_apic_volume_diagnostics(solver))


static func _read_apic_energy_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	var positions := solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
	var velocities := solver._rd.buffer_get_data(solver._buffers.velocities_a).to_float32_array()
	var affine := solver._rd.buffer_get_data(solver._buffers.affine_rows).to_float32_array()
	var motion_flags := solver._rd.buffer_get_data(solver._buffers.particle_motion_flags).to_float32_array()
	result.merge(_apic_particle_energy(solver, positions, velocities, affine, motion_flags))


static func _apic_particle_energy(solver: ApicFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array, affine: PackedFloat32Array,
		motion_flags: PackedFloat32Array) -> Dictionary:
	var mass := solver.material_density_kg_m3 * pow(solver.spacing, 3.0)
	var kinetic := 0.0
	var potential := 0.0
	var affine_energy := 0.0
	var finite := true
	var classes := {}
	var max_affine_norm := -1.0
	var max_speed := -1.0
	var strongest_affine := {}
	var fastest := {}
	for particle in solver.live_count():
		var offset := particle * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		finite = finite and p.is_finite() and v.is_finite()
		var particle_kinetic := 0.5 * mass * v.length_squared()
		kinetic += particle_kinetic
		potential -= mass * solver.gravity.y * (p.y - LEVEL)
		var affine_norm_squared := 0.0
		var rows: Array[Vector3] = []
		for row in 3:
			var base := particle * 12 + row * 4
			var c := Vector3(affine[base], affine[base + 1], affine[base + 2])
			finite = finite and c.is_finite()
			affine_norm_squared += c.length_squared()
			rows.append(c)
		var particle_affine_energy := mass * solver.grid_dx * solver.grid_dx * affine_norm_squared / 8.0
		affine_energy += particle_affine_energy
		var motion := "ballistic" if motion_flags[particle] == 1.0 else "grid" if motion_flags[particle] == 0.0 else "unknown_phase"
		var state: Dictionary = classes.get(motion, {"count": 0, "kinetic_j": 0.0, "affine_proxy_j": 0.0})
		state.count += 1
		state.kinetic_j += particle_kinetic
		state.affine_proxy_j += particle_affine_energy
		classes[motion] = state
		var affine_norm := sqrt(affine_norm_squared)
		if affine_norm > max_affine_norm:
			max_affine_norm = affine_norm
			strongest_affine = {"particle": particle, "motion": motion, "position_m": p,
				"velocity_m_s": v, "affine_rows_s_inv": rows, "norm_s_inv": affine_norm}
		var speed := v.length()
		if speed > max_speed:
			max_speed = speed
			fastest = {"particle": particle, "motion": motion, "position_m": p,
				"velocity_m_s": v, "affine_rows_s_inv": rows, "speed_m_s": speed}
	return {"physical_time_s": solver._sim_time, "state_revision": solver._frame,
		"finite": finite, "kinetic_j": kinetic, "potential_relative_level_j": potential,
		"affine_full_stencil_energy_proxy_j": affine_energy,
		"total_with_affine_proxy_j": kinetic + potential + affine_energy,
		"motion_classes": classes, "strongest_affine": strongest_affine, "fastest": fastest,
		"energy_conservation_verified": false}


static func _read_apic_projection_energy_render(solver: ApicFluidSolver) -> Dictionary:
	var archived := solver._rd.texture_get_data(solver._pre_force_velocity_tex, 0).to_float32_array()
	var dims := solver.grid_dims + Vector3i.ONE
	var count := dims.x * dims.y * dims.z
	var before := 0.0
	var after := 0.0
	var max_gain := 0.0
	var strongest := {}
	var finite := true
	for component in 3:
		var masses := solver._rd.buffer_get_data(solver._buffers[["face_mass_u", "face_mass_v", "face_mass_w"][component]]).to_float32_array()
		for face in count:
			var a := archived[(face + count) * 4 + component]
			var b := archived[(face + count * 2) * 4 + component]
			var mass := masses[face]
			finite = finite and is_finite(a) and is_finite(b) and is_finite(mass)
			var initial := 0.5 * mass * a * a
			var final := 0.5 * mass * b * b
			before += initial
			after += final
			if final - initial > max_gain:
				max_gain = final - initial
				var cell := Vector3i(face % dims.x, (face / dims.x) % dims.y, face / (dims.x * dims.y))
				var offset := Vector3.ONE * 0.5
				offset[component] = 0.0
				strongest = {"component": component, "face": cell,
					"position_m": solver.grid_origin + (Vector3(cell) + offset) * solver.grid_dx,
					"mass_kg": mass, "before_m_s": a, "after_m_s": b, "gain_j": max_gain}
	return {"physical_time_s": solver._sim_time, "state_revision": solver._frame,
		"scope": "last_substep_pressure_only", "metric": "particle_weighted_face_mass",
		"finite": finite, "before_j": before, "after_j": after, "change_j": after - before,
		"strongest_gain": strongest, "physical_energy_conservation_verified": false}


static func _seed(particle_spacing: float, still_water: bool = false, include_rock: bool = true,
		bed_slope: float = BED_SLOPE) -> PackedFloat32Array:
	var positions := PackedFloat32Array()
	var obstacles := _obstacles(include_rock, bed_slope)
	var x_max := DEPTH / bed_slope + 4.0
	var transforms: Array[Transform3D] = []
	var half_sizes: Array[Vector3] = []
	for obstacle: Dictionary in obstacles:
		transforms.append(obstacle.transform.affine_inverse())
		half_sizes.append(obstacle.size * 0.5 + Vector3.ONE * particle_spacing * 0.5)
	var x := X_MIN + particle_spacing * 0.5
	while x < x_max:
		var bed := _bed_height(x, bed_slope)
		var surface := LEVEL + (0.0 if still_water else _wave_eta(x))
		var normal_offset := particle_spacing * 0.5 * (sqrt(1.0 + bed_slope * bed_slope) if x > 0.0 else 1.0)
		var vertical_origin := -DEPTH + particle_spacing * 0.5
		var y := vertical_origin + ceili((bed + normal_offset - vertical_origin - 1.0e-6) / particle_spacing) * particle_spacing
		while y < surface:
			var z := Z_MIN + particle_spacing * 0.5
			while z < Z_MAX:
				var point := Vector3(x, y, z)
				var inside := false
				for obstacle in obstacles.size():
					var local := transforms[obstacle] * point
					var clearance := half_sizes[obstacle] - local.abs()
					if minf(clearance.x, minf(clearance.y, clearance.z)) > 0.000001:
						inside = true
						break
				if not inside:
					positions.append_array([point.x, point.y, point.z, 0.0])
				z += particle_spacing
			y += particle_spacing
		x += particle_spacing
	return positions


static func run_seed_geometry(check: Callable) -> void:
	const SPACING := 0.12
	var k := sqrt(3.0 * 0.9 / (4.0 * pow(DEPTH, 3.0)))
	var eta_integral := 0.9 / k * (tanh(k * (X_MAX + 8.0)) - tanh(k * (X_MIN + 8.0)))
	var reference_volume := (Z_MAX - Z_MIN) * (-X_MIN * DEPTH
		+ 0.5 * DEPTH * DEPTH / BED_SLOPE + eta_integral)
	var seed := _seed(SPACING)
	var seeded_volume := float(seed.size() / 4) * pow(SPACING, 3.0)
	var relative_error := absf(seeded_volume - reference_volume) / reference_volume
	print("BREAKER SEED scenario=solitary_slope_rock seed=0 spacing_m=%.3f requested_level_m=%.3f requested_depth_m=%.3f requested_amplitude_m=0.900 particles=%d particle_cell_volume_m3=%.9f continuum_volume_m3=%.9f relative_volume_error=%.9f volume_measurement=midpoint_particle_cells geometry_tolerance_m=%.3f" % [
		SPACING, LEVEL, DEPTH, seed.size() / 4, seeded_volume, reference_volume, relative_error, SPACING * 0.5])
	check.call(relative_error <= 0.01, "Breaker seed: fine particle cells do not represent prescribed water volume within 1%")
	var no_rock_seed := _seed(SPACING, false, false)
	print("BREAKER SEED COMPARISON original=solitary_slope_rock candidate=solitary_unobstructed_slope particles=%d identical_positions=%s amplitude_m=0.900 depth_m=2.000 bed_slope=0.125" % [seed.size() / 4, str(seed == no_rock_seed)])
	check.call(seed == no_rock_seed, "Breaker seed: removing the initially dry rock changes the prescribed water")
	var plunging_slope := 1.0 / 15.0
	var plunging_seed := _seed(SPACING, false, true, plunging_slope)
	var plunging_x_max := DEPTH / plunging_slope + 4.0
	var plunging_reference := (Z_MAX - Z_MIN) * (-X_MIN * DEPTH
		+ 0.5 * DEPTH * DEPTH / plunging_slope
		+ 0.9 / k * (tanh(k * (plunging_x_max + 8.0)) - tanh(k * (X_MIN + 8.0))))
	var plunging_error := absf(float(plunging_seed.size() / 4) * pow(SPACING, 3.0) - plunging_reference) / plunging_reference
	var offshore_identical := true
	for index in range(0, seed.size(), 4):
		if seed[index] >= 0.0:
			break
		for axis in 4:
			offshore_identical = offshore_identical and seed[index + axis] == plunging_seed[index + axis]
	print("BREAKER SEED PLUNGING bed_slope=%.9f particles=%d continuum_volume_m3=%.9f relative_volume_error=%.9f offshore_positions_identical=%s amplitude_m=0.900 depth_m=2.000 initial_profile=approximate_sech_squared" % [
		plunging_slope, plunging_seed.size() / 4, plunging_reference, plunging_error, str(offshore_identical)])
	check.call(plunging_error <= 0.01 and offshore_identical,
		"Breaker seed: plunging case changes the offshore wave or misses prescribed volume by over 1%")


static func _wave_eta(x: float) -> float:
	var k := sqrt(3.0 * 0.9 / (4.0 * pow(DEPTH, 3.0)))
	var c := cosh(k * (x + 8.0))
	return 0.9 / (c * c)


static func _wave_velocity(x: float, y: float, slope: float = BED_SLOPE) -> Vector2:
	var eta := _wave_eta(x)
	var k := sqrt(3.0 * 0.9 / (4.0 * pow(DEPTH, 3.0)))
	var c := sqrt(G * (DEPTH + 0.9))
	var eta_x := -2.0 * k * eta * tanh(k * (x + 8.0))
	var eta_xx := 4.0 * k * k * eta - 6.0 * k * k * eta * eta / 0.9
	var eta_xxx := (4.0 * k * k - 12.0 * k * k * eta / 0.9) * eta_x
	var offshore_depth := DEPTH + eta
	var mean_u := c * eta / offshore_depth
	var mean_u_x := c * DEPTH * eta_x / pow(offshore_depth, 2.0)
	var mean_u_xx := c * DEPTH * (eta_xx / pow(offshore_depth, 2.0)
		- 2.0 * eta_x * eta_x / pow(offshore_depth, 3.0))
	var mean_u_xxx := c * DEPTH * (eta_xxx / pow(offshore_depth, 2.0)
		- 6.0 * eta_x * eta_xx / pow(offshore_depth, 3.0)
		+ 6.0 * pow(eta_x, 3.0) / pow(offshore_depth, 4.0))
	var bed_slope := 0.0 if x <= 0.0 else slope
	var depth := LEVEL + eta - _bed_height(x, slope)
	var height := y - _bed_height(x, slope)
	var depth_x := eta_x - bed_slope
	var u := mean_u + (depth * depth / 6.0 - height * height / 2.0) * mean_u_xx
	var v := (u * bed_slope - height * mean_u_x
		- height * depth * depth_x * mean_u_xx / 3.0
		- (height * depth * depth / 6.0 - pow(height, 3.0) / 6.0) * mean_u_xxx)
	return Vector2(u, v)


static func _bed_height(x: float, bed_slope: float = BED_SLOPE) -> float:
	return -DEPTH + maxf(x, 0.0) * bed_slope


static func _inside_rock(point: Vector3, center: Vector3 = ROCK_CENTER) -> bool:
	return (point - center).abs().x < ROCK_SIZE.x * 0.5 \
		and (point - center).abs().y < ROCK_SIZE.y * 0.5 \
		and (point - center).abs().z < ROCK_SIZE.z * 0.5


static func _obstacles(include_rock: bool = true, bed_slope: float = BED_SLOPE) -> Array[Dictionary]:
	var x_max := DEPTH / bed_slope + 4.0
	var slope_angle := atan(bed_slope)
	var slope_basis := Basis(Vector3.BACK, slope_angle)
	var slope_normal := slope_basis.y
	var slope_thickness := x_max * bed_slope - DEPTH - Y_MIN
	var slope_size := Vector3(x_max * sqrt(1.0 + bed_slope * bed_slope), slope_thickness, Z_MAX - Z_MIN)
	var slope_midpoint := Vector3(x_max * 0.5, -DEPTH + x_max * 0.5 * bed_slope, 0.0)
	var obstacles: Array[Dictionary] = [
		{transform = Transform3D(Basis.IDENTITY, Vector3((X_MIN + x_max) * 0.5, (-DEPTH + Y_MIN) * 0.5, 0.0)),
			size = Vector3(x_max - X_MIN, -DEPTH - Y_MIN, Z_MAX - Z_MIN), retention = 0.985},
		{transform = Transform3D(slope_basis, slope_midpoint - slope_normal * slope_thickness * 0.5),
			size = slope_size, retention = 0.985},
	]
	if include_rock:
		obstacles.append({transform = Transform3D(Basis.IDENTITY, Vector3(x_max - 2.5, ROCK_CENTER.y, ROCK_CENTER.z)), size = ROCK_SIZE, retention = 0.985})
	return obstacles


static func _set_seed_velocities(solver, seed: PackedFloat32Array, still_water: bool = false,
		bed_slope: float = BED_SLOPE) -> void:
	var velocities := PackedFloat32Array()
	velocities.resize(seed.size())
	@warning_ignore("integer_division")
	var count := seed.size() / 4
	for i in count:
		var velocity := Vector2.ZERO if still_water else _wave_velocity(seed[i * 4], seed[i * 4 + 1], bed_slope)
		velocities[i * 4] = velocity.x
		velocities[i * 4 + 1] = velocity.y
		velocities[i * 4 + 3] = float(i)
	var bytes := velocities.to_byte_array()
	for key in ["velocities_a", "velocities_b"]:
		if solver._buffers.has(key):
			solver._rd.buffer_update(solver._buffers[key], 0, bytes.size(), bytes)


static func _read_metrics(solver, result: Dictionary, candidate: String = "sph",
		report_grid_diagnostics: bool = false, include_rock: bool = true, bed_slope: float = BED_SLOPE) -> void:
	var positions: PackedFloat32Array
	var velocities: PackedFloat32Array
	var densities := PackedFloat32Array()
	var motion_flags := PackedFloat32Array()
	if candidate == "sph":
		var state: Dictionary = solver.read_current_particle_state_render()
		positions = state.positions_m
		velocities = state.velocities_m_s
		densities = state.kernel_density_m_inv3
		result["density_state_time_s"] = state.physical_time_s
		result["density_state_revision"] = state.state_revision
	else:
		var key := "positions_a" if solver.current_parity() == 0 else "positions_b"
		var velocity_key := "velocities_a" if solver.current_parity() == 0 else "velocities_b"
		positions = solver._rd.buffer_get_data(solver._buffers[key]).to_float32_array()
		velocities = solver._rd.buffer_get_data(solver._buffers[velocity_key]).to_float32_array()
		motion_flags = solver._rd.buffer_get_data(solver._buffers.particle_motion_flags).to_float32_array()
		var affine: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.affine_rows).to_float32_array()
		result["energy"] = _apic_particle_energy(solver, positions, velocities, affine, motion_flags)
		if solver.projection_energy_diagnostics:
			result["projection_energy"] = _read_apic_projection_energy_render(solver)
		result["projection"] = solver.get_diagnostics()
	var ratios := PackedFloat32Array()
	var x_max: float = solver.config.domain_origin.x + solver.config.domain_size_m.x
	var rock_center := Vector3(x_max - 2.5, ROCK_CENTER.y, ROCK_CENTER.z)
	var surface_cell_m: float = solver.spacing if candidate == "sph" else solver.h
	var nx := ceili((x_max - X_MIN) / surface_cell_m)
	var nz := ceili((Z_MAX - Z_MIN) / surface_cell_m)
	var surface := PackedFloat32Array()
	surface.resize(nx * nz)
	surface.fill(-INF)
	var finite := 0
	var outside := 0
	var interior := 0
	var rock_contact_count := 0
	var max_speed := 0.0
	var penetration := 0.0
	var voxel_counts: Dictionary = {}
	var voxel_backwash: Dictionary = {}
	var runup_x := X_MIN
	var crest_x := X_MIN
	var crest_y := -INF
	var low := config_domain_min()
	var high := Vector3(x_max, Y_MAX, Z_MAX)
	for i in solver.live_count():
		var offset: int = i * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		if not p.is_finite():
			continue
		var ix := clampi(int((p.x - X_MIN) / surface_cell_m), 0, nx - 1)
		var iz := clampi(int((p.z - Z_MIN) / surface_cell_m), 0, nz - 1)
		var column := ix * nz + iz
		surface[column] = maxf(surface[column], p.y)
	for i in solver.live_count():
		var offset: int = i * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		var density_ratio: float = densities[i] / solver._target_density if candidate == "sph" else -1.0
		var valid := p.is_finite() and v.is_finite() and (candidate != "sph" or is_finite(density_ratio))
		if valid:
			finite += 1
			if candidate != "apic" or motion_flags[i] == 0.0:
				var voxel := Vector3i(floori(p.x / solver.spacing), floori(p.y / solver.spacing),
					floori(p.z / solver.spacing))
				voxel_counts[voxel] = int(voxel_counts.get(voxel, 0)) + 1
				if p.x > 0.0 and v.x < -0.1:
					voxel_backwash[voxel] = int(voxel_backwash.get(voxel, 0)) + 1
			if p.x < low.x or p.y < low.y or p.z < low.z or p.x > high.x or p.y > high.y or p.z > high.z:
				outside += 1
			var clearance := p.y - _bed_height(p.x, bed_slope)
			if p.x >= X_MIN and p.x <= x_max:
				penetration = maxf(penetration, -clearance)
			var rock_delta := (p - rock_center).abs()
			var rock_inside := ROCK_SIZE * 0.5 - rock_delta
			if include_rock and rock_inside.x > 0.0 and rock_inside.y > 0.0 and rock_inside.z > 0.0:
				penetration = maxf(penetration, minf(rock_inside.x, minf(rock_inside.y, rock_inside.z)))
			var ix := clampi(int((p.x - X_MIN) / surface_cell_m), 0, nx - 1)
			var iz := clampi(int((p.z - Z_MIN) / surface_cell_m), 0, nz - 1)
			var top := surface[ix * nz + iz]
			var rock_gap := Vector3(maxf(rock_delta.x - ROCK_SIZE.x * 0.5, 0.0),
				maxf(rock_delta.y - ROCK_SIZE.y * 0.5, 0.0),
				maxf(rock_delta.z - ROCK_SIZE.z * 0.5, 0.0)).length()
			if not include_rock:
				rock_gap = INF
			if rock_gap <= solver.collision_inflation + solver.spacing * 0.5:
				rock_contact_count += 1
			if clearance >= solver.h and top - p.y >= solver.h and rock_gap >= solver.h \
					and p.x - X_MIN >= solver.h and x_max - p.x >= solver.h \
					and p.z - Z_MIN >= solver.h and Z_MAX - p.z >= solver.h:
				interior += 1
				if candidate == "sph":
					ratios.append(absf(density_ratio - 1.0))
			if clearance > 0.12:
				runup_x = maxf(runup_x, p.x)
			if p.y > crest_y:
				crest_x = p.x
				crest_y = p.y
			max_speed = maxf(max_speed, v.length())
	ratios.sort()
	var p95 := ratios[clampi(ceili(float(ratios.size()) * 0.95) - 1, 0, maxi(ratios.size() - 1, 0))] if not ratios.is_empty() else 0.0
	var main_component := _largest_component(voxel_counts)
	var main_cells: Dictionary = main_component.cells
	var main_particle_count: int = main_component.particle_count
	var backwash_particles := 0
	for voxel in voxel_backwash:
		if main_cells.has(voxel):
			backwash_particles += int(voxel_backwash[voxel])
	result.merge({"finite": finite, "outside": outside, "interior": interior,
		"density_p95": p95, "penetration": maxf(penetration, 0.0),
		"runup_x": runup_x, "crest_x": crest_x, "crest_y": crest_y,
		"max_speed": max_speed,
		"main_component_fraction": float(main_particle_count) / float(maxi(finite, 1)),
		"overhang_volume": _overhang_volume(main_cells, voxel_counts, solver.spacing, include_rock, bed_slope, rock_center),
		"rock_contact_count": rock_contact_count,
		"backwash_volume": float(backwash_particles) * pow(solver.spacing, 3.0)}, true)
	if candidate == "apic" and report_grid_diagnostics:
		if solver.free_surface_cut_cells:
			result["volume_state"] = _apic_volume_diagnostics(solver)
			if solver.conservative_amount_tracking:
				result["amount_state"] = solver.get_liquid_amount_diagnostics_render()
				if solver.conservative_surface_reconstruction:
					result["interface_geometry"] = solver.get_interface_geometry_diagnostics_render()
		var grid_metrics := _apic_grid_diagnostics(solver, positions)
		result.merge(grid_metrics, true)
		var support_time: float = solver._sim_time - solver.last_step_dt_s / float(maxi(solver.last_substeps, 1))
		var iou_label := "%.6f" % float(grid_metrics.phase_occupancy_iou) if solver.free_surface_cut_cells else "unavailable"
		print("BREAKER GRID DIAG t_s=%.6f support_time_s=%.6f cellmask_time_s=%.6f spacing_m=%.6f grid_dx_m=%.6f occupied_fluid_cell_volume_m3=%.9f trapped_air_cells=%d largest_trapped_air_component_cells=%d particles_in_solid_cells=%d mass_supported_fluid_faces=%s massless_fluid_faces=%s occupancy_proxy=%s phi_fluid_cells=%d particle_occupied_cells=%d phase_intersection_cells=%d phase_union_cells=%d phase_occupancy_iou=%s" % [
			solver._sim_time, support_time, solver._sim_time if solver.free_surface_cut_cells else support_time,
			solver.spacing, solver.grid_dx,
			float(grid_metrics.occupied_fluid_cell_volume_m3),
			int(grid_metrics.trapped_air_cells),
			int(grid_metrics.largest_trapped_air_component_cells),
			int(grid_metrics.particles_in_solid_cells), str(grid_metrics.mass_supported_fluid_faces),
			str(grid_metrics.massless_fluid_faces), str(solver.free_surface_cut_cells),
			int(grid_metrics.phi_fluid_cells), int(grid_metrics.particle_occupied_cells),
			int(grid_metrics.phase_intersection_cells), int(grid_metrics.phase_union_cells), iou_label])
		print("BREAKER CUT FACE DIAG support_time_s=%.9f dry_pressure_faces=%d net_velocity_area_proxy_m3_s=%.9f absolute_velocity_area_proxy_m3_s=%.9f physical_flux=unavailable" % [
			support_time, int(grid_metrics.dry_pressure_faces), float(grid_metrics.dry_face_net_velocity_area_proxy_m3_s),
			float(grid_metrics.dry_face_absolute_velocity_area_proxy_m3_s)])


static func _apic_volume_diagnostics(solver: ApicFluidSolver) -> Dictionary:
	var state := solver.read_volume_state_render()
	var phi: PackedFloat32Array = state.level_set_m
	var solid_mask: PackedByteArray = state.solid_cell_mask
	var dims: Vector3i = state.grid_dims
	var dx: float = state.cell_size_m
	var geometry: PackedFloat32Array = state.get("cell_geometry", PackedFloat32Array())
	var cut_solids := geometry.size() == phi.size() * 4
	var solid_planes: Array[Array] = ApicFluidSolver.CutGeometry.obstacle_planes(solver.scene_obstacles) if cut_solids else []
	var domain := AABB(solver.config.domain_origin, solver.config.domain_size_m)
	var finite := true
	var volume := 0.0
	var planar_volume := 0.0
	var max_geometric_overfill := 0.0
	var overfill_cell := Vector3i.ZERO
	var overfill_span := Vector3.ZERO
	var overfill_phi := 0.0
	var wet_cells: Dictionary = {}
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var index := (z * dims.y + y) * dims.x + x
				finite = finite and is_finite(phi[index])
				if solid_mask[index] != 0:
					continue
				var span := _apic_cell_phi_span(phi, solid_mask, dims, Vector3i(x, y, z))
				var fraction := _linear_cell_liquid_fraction(phi[index], span)
				var geometric_fraction := geometry[index * 4 + 3] if cut_solids else 1.0
				volume += clampf(0.5 - phi[index] / dx, 0.0, 1.0) * geometric_fraction * pow(dx, 3.0)
				if geometric_fraction < 1.0:
					var center: Vector3 = state.grid_origin_m + (Vector3(x, y, z) + Vector3.ONE * 0.5) * dx
					if span.length_squared() > 1.0e-20:
						var gradient := span / dx
						var air_normal := -gradient.normalized()
						var air: Array[Plane] = [Plane(air_normal, air_normal.dot(center) + phi[index] / gradient.length())]
						var excluded: Array[Array] = solid_planes.duplicate()
						excluded.append(air)
						fraction = ApicFluidSolver.CutGeometry.open_cube(center, dx, domain, excluded).open_fraction
					else:
						fraction *= geometric_fraction
					if fraction - geometric_fraction > max_geometric_overfill:
						max_geometric_overfill = fraction - geometric_fraction
						overfill_cell = Vector3i(x, y, z)
						overfill_span = span
						overfill_phi = phi[index]
				planar_volume += fraction * pow(dx, 3.0)
				if phi[index] < 0.0 and fraction > 0.0:
					wet_cells[Vector3i(x, y, z)] = 1
	var main_component := _largest_component(wet_cells)
	var main_cells: Dictionary = main_component.cells
	var upper_cells := 0
	var scalar_crest := Vector3(0.0, -INF, 0.0)
	var scalar_surface_crossings := 0
	for z in dims.z:
		for x in dims.x:
			var found_water := false
			var air_gap := false
			for y in dims.y:
				var index := (z * dims.y + y) * dims.x + x
				if solid_mask[index] != 0:
					found_water = false
					air_gap = false
				elif main_cells.has(Vector3i(x, y, z)):
					if y + 1 < dims.y and solid_mask[index + dims.x] == 0 and phi[index + dims.x] >= 0.0:
						var point: Vector3 = state.grid_origin_m + (Vector3(x, y, z) + Vector3.ONE * 0.5) * dx
						point.y += dx * (-phi[index]) / (phi[index + dims.x] - phi[index])
						var inside_solid := false
						for obstacle: Array in solid_planes:
							var inside := true
							for plane: Plane in obstacle:
								inside = inside and plane.distance_to(point) <= 0.0
							inside_solid = inside_solid or inside
						if not inside_solid and domain.has_point(point):
							scalar_surface_crossings += 1
							if point.y > scalar_crest.y:
								scalar_crest = point
					if air_gap:
						upper_cells += 1
					found_water = true
				elif found_water:
					air_gap = true
	return {"physical_time_s": state.physical_time_s, "state_revision": state.state_revision,
		"finite": finite, "cell_size_m": dx, "grid_dims": dims,
		"linear_cell_volume_estimate_m3": volume,
		"planar_cell_volume_estimate_m3": planar_volume,
		"main_component_cell_fraction": float(main_cells.size()) / float(maxi(wet_cells.size(), 1)),
		"main_component_reentrant_cell_volume_proxy_m3": float(upper_cells) * pow(dx, 3.0),
		"scalar_main_surface_crest_m": scalar_crest if scalar_surface_crossings > 0 else "unavailable",
		"scalar_main_surface_crossings": scalar_surface_crossings,
		"solid_geometry": "clipped_obb_union" if cut_solids else "cell_center_mask",
		"max_geometric_fraction_overfill": max_geometric_overfill,
		"geometric_overfill_cell": overfill_cell,
		"geometric_overfill_phi_m": overfill_phi,
		"geometric_overfill_span_m": overfill_span,
		"volume_conservation_verified": false}


static func _apic_cell_phi_span(phi: PackedFloat32Array, solid_mask: PackedByteArray,
		dims: Vector3i, cell: Vector3i) -> Vector3:
	var index := (cell.z * dims.y + cell.y) * dims.x + cell.x
	var strides := Vector3i(1, dims.x, dims.x * dims.y)
	var span := Vector3.ZERO
	for axis in 3:
		var stride := strides[axis]
		var has_left: bool = cell[axis] > 0 and solid_mask[index - stride] == 0
		var has_right: bool = cell[axis] + 1 < dims[axis] and solid_mask[index + stride] == 0
		if has_left and has_right:
			span[axis] = (phi[index + stride] - phi[index - stride]) * 0.5
		elif has_right:
			span[axis] = phi[index + stride] - phi[index]
		elif has_left:
			span[axis] = phi[index] - phi[index - stride]
	return span


static func _largest_component(voxel_counts: Dictionary) -> Dictionary:
	var visited: Dictionary = {}
	var largest: Dictionary = {}
	var largest_count := 0
	for start_cell: Vector3i in voxel_counts:
		if visited.has(start_cell):
			continue
		var component: Dictionary = {}
		var queue: Array[Vector3i] = [start_cell]
		visited[start_cell] = true
		var component_count := 0
		var read_index := 0
		while read_index < queue.size():
			var cell := queue[read_index]
			read_index += 1
			component[cell] = true
			component_count += int(voxel_counts[cell])
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						if dx == 0 and dy == 0 and dz == 0:
							continue
						var neighbor := cell + Vector3i(dx, dy, dz)
						if voxel_counts.has(neighbor) and not visited.has(neighbor):
							visited[neighbor] = true
							queue.append(neighbor)
		if component_count > largest_count:
			largest_count = component_count
			largest = component
	return {"cells": largest, "particle_count": largest_count}


static func _overhang_volume(main_cells: Dictionary, voxel_counts: Dictionary,
		cell_size: float, include_rock: bool = true, bed_slope: float = BED_SLOPE,
		rock_center: Vector3 = ROCK_CENTER) -> float:
	var columns: Dictionary = {}
	for cell: Vector3i in main_cells:
		var column := Vector2i(cell.x, cell.z)
		if not columns.has(column):
			columns[column] = []
		(columns[column] as Array).append(cell.y)
	var particles := 0
	for column: Vector2i in columns:
		var heights: Array = columns[column]
		heights.sort()
		var runs: Array[Vector2i] = []
		var run_start: int = heights[0]
		var run_end: int = heights[0]
		for index in range(1, heights.size()):
			var height: int = heights[index]
			if height == run_end:
				continue
			if height == run_end + 1:
				run_end = height
				continue
			runs.append(Vector2i(run_start, run_end))
			run_start = height
			run_end = height
		runs.append(Vector2i(run_start, run_end))
		for upper_index in range(1, runs.size()):
			var upper := runs[upper_index]
			if upper.y - upper.x + 1 < 2:
				continue
			var qualifies := false
			for lower_index in upper_index:
				var lower := runs[lower_index]
				if lower.y - lower.x + 1 < 2 or upper.x - lower.y - 1 < 2 \
						or float(lower.y + 1) * cell_size < LEVEL - cell_size:
					continue
				var x := (float(column.x) + 0.5) * cell_size
				var z := (float(column.y) + 0.5) * cell_size
				var solid_in_gap := false
				for y_cell in range(lower.y + 1, upper.x):
					var y := (float(y_cell) + 0.5) * cell_size
					if y <= _bed_height(x, bed_slope) or (include_rock and _inside_rock(Vector3(x, y, z), rock_center)):
						solid_in_gap = true
						break
				if not solid_in_gap:
					qualifies = true
					break
			if qualifies:
				for y_cell in range(upper.x, upper.y + 1):
					particles += int(voxel_counts.get(Vector3i(column.x, y_cell, column.y), 0))
	return float(particles) * pow(cell_size, 3.0)


static func config_domain_min() -> Vector3:
	return Vector3(X_MIN, Y_MIN, Z_MIN)


static func run_apic_transfer(tree: SceneTree, check: Callable) -> void:
	for scenario in ["translation", "affine", "solid_affine", "cluster_affine", "translation_custom_grid"]:
		var mode_results: Array[Dictionary] = []
		for mode in [0, 1]:
			var setup := _apic_transfer_setup(scenario, mode)
			var solver = setup.solver
			RenderingServer.call_on_render_thread(solver.init_render)
			await RenderingServer.frame_post_draw
			if not solver.initialized:
				check.call(false, "APIC transfer: solver initialization failed")
				continue
			RenderingServer.call_on_render_thread(_dispatch_apic_transfer.bind(solver, setup))
			await RenderingServer.frame_post_draw
			var sample := {}
			RenderingServer.call_on_render_thread(_read_apic_transfer.bind(solver, setup, sample))
			await RenderingServer.frame_post_draw
			var metrics: Dictionary = sample.metrics
			print("BREAKER P2G scenario=%s mode=%s seed=731 spacing_m=%.3f grid_cell_size_m=%.3f particles=%d memory_bytes=%d physical_time_s=%.3f gpu_timing=unavailable rel_mass=%.9f rel_momentum=%.9f rel_velocity=%.9f partition_mass_rel=%.9f partition_momentum_rel=%.9f masked_faces=%d" % [
				scenario, "gather" if mode == 0 else "scatter_cas", solver.spacing,
				solver.grid_dx, solver.live_count(), solver.get_gpu_memory_bytes(), solver._sim_time,
				float(metrics.rel_mass), float(metrics.rel_momentum), float(metrics.rel_velocity),
				float(metrics.partition_mass_rel), float(metrics.partition_momentum_rel),
				int(metrics.masked_faces)])
			check.call(float(metrics.rel_mass) <= 1.0e-5
				and float(metrics.rel_momentum) <= 1.0e-5
				and float(metrics.rel_velocity) <= 1.0e-5,
				"APIC transfer: %s CPU-reference error exceeded 1e-5" % scenario)
			if scenario != "solid_affine":
				check.call(float(metrics.partition_mass_rel) <= 1.0e-5
					and float(metrics.partition_momentum_rel) <= 1.0e-5,
					"APIC transfer: %s mass/momentum partition failed" % scenario)
			mode_results.append(sample)
			RenderingServer.call_on_render_thread(solver.free_render)
			await RenderingServer.frame_post_draw
		if mode_results.size() == 2:
			var mode_delta := _apic_transfer_mode_delta(mode_results[0], mode_results[1])
			print("BREAKER P2G MODES scenario=%s rel_mass=%.9f rel_momentum=%.9f rel_velocity=%.9f" % [
				scenario, float(mode_delta.rel_mass), float(mode_delta.rel_momentum),
				float(mode_delta.rel_velocity)])
			check.call(float(mode_delta.rel_mass) <= 1.0e-5
				and float(mode_delta.rel_momentum) <= 1.0e-5
				and float(mode_delta.rel_velocity) <= 1.0e-5
				and int(mode_delta.mask_mismatch) == 0,
				"APIC transfer: gather and scatter modes differ by more than 1e-5")


static func _apic_transfer_setup(scenario: String, mode: int) -> Dictionary:
	var particle_spacing := 0.12
	var dx := particle_spacing if scenario == "translation_custom_grid" else particle_spacing * 2.0
	var origin := Vector3(-0.373, -0.227, 0.119)
	var domain_size := Vector3.ONE * (12.0 * dx)
	var seed := PackedFloat32Array()
	var velocity_data := PackedFloat32Array()
	var affine_data := PackedFloat32Array()
	var affine_rows := [Vector3(0.12, 0.31, -0.17), Vector3(0.11, -0.05, 0.23), Vector3(-0.04, 0.19, -0.07)]
	var center := origin + Vector3.ONE * (6.0 * dx)
	var base_velocity := Vector3(0.37, -0.21, 0.13)
	for z in range(2, 10):
		for y in range(2, 10):
			for x in range(2, 10):
				var p := origin + (Vector3(x, y, z) + Vector3.ONE * 0.317) * dx
				if scenario == "cluster_affine":
					p = origin + (Vector3.ONE * 5.2 + Vector3(x - 2, y - 2, z - 2) * 0.09) * dx
				var v := base_velocity
				var rows: Array = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
				if scenario not in ["translation", "translation_custom_grid"]:
					rows = affine_rows
					v += Vector3(rows[0].dot(p - center), rows[1].dot(p - center), rows[2].dot(p - center))
				seed.append_array([p.x, p.y, p.z, 0.0])
				velocity_data.append_array([v.x, v.y, v.z, 0.0])
				for row: Vector3 in rows:
					affine_data.append_array([row.x, row.y, row.z, 0.0])
	var count := 512
	var config := FluidConfig.new()
	config.domain_origin = origin
	config.domain_size_m = domain_size
	config.grid_origin = origin
	config.cell_size_m = dx
	config.grid_dims = Vector3i(12, 12, 12)
	config.default_particle_count = count
	config.particle_counts = [count]
	config.texture_width = ceili(sqrt(float(count)))
	var solver = load("res://scripts/fluid/apic_fluid_solver.gd").new()
	solver.config = config
	solver.particle_count = count
	solver.active_count = count
	solver.spacing = particle_spacing
	solver.grid_cell_size_m = dx
	solver.gravity = Vector3.ZERO
	solver.profiling = false
	solver.p2g_transfer = mode
	solver.set_seed_positions(seed)
	if scenario == "solid_affine":
		var slab_size := Vector3(domain_size.x, 0.2, domain_size.z)
		var slab_center := Vector3(origin.x + domain_size.x * 0.5,
			origin.y + 2.0 * dx - slab_size.y * 0.5, origin.z + domain_size.z * 0.5)
		var obstacles: Array[Dictionary] = [{"transform": Transform3D(Basis.IDENTITY, slab_center),
			"size": slab_size, "retention": 0.985}]
		solver.set_scene_obstacles(obstacles)
	return {"solver": solver, "seed": seed, "velocity_data": velocity_data,
		"affine_data": affine_data, "affine_rows": affine_rows if scenario not in ["translation", "translation_custom_grid"] else [
			Vector3.ZERO, Vector3.ZERO, Vector3.ZERO], "origin": origin,
		"scenario": scenario}


static func _dispatch_apic_transfer(solver, setup: Dictionary) -> void:
	solver._rd.buffer_update(solver._buffers.velocities_a, 0,
		setup.velocity_data.size() * 4, setup.velocity_data.to_byte_array())
	solver._rd.buffer_update(solver._buffers.affine_rows, 0,
		setup.affine_data.size() * 4, setup.affine_data.to_byte_array())
	var cells: int = solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z
	var faces: int = (solver.grid_dims.x + 1) * (solver.grid_dims.y + 1) * (solver.grid_dims.z + 1)
	var cell_groups := ceili(float(cells) / 256.0)
	var particle_groups := ceili(float(solver.live_count()) / 256.0)
	var face_groups := ceili(float(faces * 3) / 256.0)
	var pc: PackedByteArray = solver._pack_push_constant(0.0, -1)
	var cl: int = solver._rd.compute_list_begin()
	solver._dispatch(cl, "grid_clear", pc, cell_groups, 1, 1)
	solver._dispatch(cl, "grid_count", pc, particle_groups, 1, 1)
	solver._dispatch(cl, "grid_scan", pc, cell_groups, 1, 1)
	solver._dispatch(cl, "grid_scan_blocks", pc, 1, 1, 1)
	solver._dispatch(cl, "grid_add_back", pc, cell_groups, 1, 1)
	solver._dispatch(cl, "grid_scatter", pc, particle_groups, 1, 1)
	solver._dispatch(cl, "classify", pc, cell_groups, 1, 1)
	solver._dispatch(cl, "solid_faces", pc, face_groups, 1, 1)
	solver._dispatch_p2g_render(cl, pc)
	solver._rd.compute_list_end()


static func _read_apic_transfer(solver, setup: Dictionary, result: Dictionary) -> void:
	var faces: int = (solver.grid_dims.x + 1) * (solver.grid_dims.y + 1) * (solver.grid_dims.z + 1)
	var reference_mass := PackedFloat64Array()
	var reference_momentum := PackedFloat64Array()
	reference_mass.resize(faces * 3)
	reference_momentum.resize(faces * 3)
	var mask: PackedInt32Array = solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	var seed: PackedFloat32Array = setup.seed
	var velocity_data: PackedFloat32Array = setup.velocity_data
	var rows: Array = setup.affine_rows
	var dx: float = solver.grid_dx
	var particle_mass: float = solver.material_density_kg_m3 * pow(solver.spacing, 3.0)
	var fd: Vector3i = solver.grid_dims + Vector3i.ONE
	var offsets: Array[Vector3] = [Vector3(0.0, 0.5, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, 0.5, 0.0)]
	for particle in solver.live_count():
		var p := Vector3(seed[particle * 4], seed[particle * 4 + 1], seed[particle * 4 + 2])
		var velocity := Vector3(velocity_data[particle * 4], velocity_data[particle * 4 + 1], velocity_data[particle * 4 + 2])
		var local: Vector3 = (p - solver.grid_origin) / dx
		for component in 3:
			var base := Vector3i(floori(local.x - offsets[component].x - 0.5),
				floori(local.y - offsets[component].y - 0.5),
				floori(local.z - offsets[component].z - 0.5))
			var row: Vector3 = rows[component]
			for z in 3:
				for y in 3:
					for x in 3:
						var face := base + Vector3i(x, y, z)
						if face.x < 0 or face.y < 0 or face.z < 0 or face.x >= fd.x or face.y >= fd.y or face.z >= fd.z:
							continue
						var face_index: int = (face.z * fd.y + face.y) * fd.x + face.x
						var index: int = component * faces + face_index
						if (mask[index] & 1) != 0:
							continue
						var fp: Vector3 = solver.grid_origin + (Vector3(face) + offsets[component]) * dx
						var delta: Vector3 = (fp - p) / dx
						var weight := _apic_transfer_weight(delta.x) * _apic_transfer_weight(delta.y) * _apic_transfer_weight(delta.z)
						if weight <= 0.0:
							continue
						var momentum := velocity[component] + row.dot(fp - p)
						reference_mass[index] += weight * particle_mass
						reference_momentum[index] += weight * particle_mass * momentum
	var mass_buffers := ["face_mass_u", "face_mass_v", "face_mass_w"]
	var velocity_buffers := ["face_u", "face_v", "face_w"]
	var actual_mass := PackedFloat32Array()
	var actual_velocity := PackedFloat32Array()
	var actual_momentum := PackedFloat32Array()
	actual_mass.resize(faces * 3)
	actual_velocity.resize(faces * 3)
	actual_momentum.resize(faces * 3)
	var sums_mass := PackedFloat64Array([0.0, 0.0, 0.0])
	var sums_momentum := PackedFloat64Array([0.0, 0.0, 0.0])
	var max_ref_mass := PackedFloat64Array([0.0, 0.0, 0.0])
	var max_ref_momentum := PackedFloat64Array([0.0, 0.0, 0.0])
	var max_ref_velocity := PackedFloat64Array([0.0, 0.0, 0.0])
	var masked_faces := 0
	for component in 3:
		var masses: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers[mass_buffers[component]]).to_float32_array()
		var velocities: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers[velocity_buffers[component]]).to_float32_array()
		for face_index in faces:
			var index: int = component * faces + face_index
			actual_mass[index] = masses[face_index]
			actual_velocity[index] = velocities[face_index]
			if (mask[index] & 1) != 0:
				masked_faces += 1
				continue
			sums_mass[component] += masses[face_index]
			sums_momentum[component] += masses[face_index] * velocities[face_index]
			var expected_mass: float = reference_mass[index]
			var expected_mom: float = reference_momentum[index]
			var expected_vel := expected_mom / expected_mass if expected_mass > 0.0 else 0.0
			max_ref_mass[component] = maxf(max_ref_mass[component], absf(expected_mass))
			max_ref_momentum[component] = maxf(max_ref_momentum[component], absf(expected_mom))
			max_ref_velocity[component] = maxf(max_ref_velocity[component], absf(expected_vel))
	var rel_mass := 0.0
	var rel_momentum := 0.0
	var rel_velocity := 0.0
	for component in 3:
		for face_index in faces:
			var index: int = component * faces + face_index
			var expected_mass: float = reference_mass[index]
			var expected_mom: float = reference_momentum[index]
			var expected_vel := expected_mom / expected_mass if expected_mass > 0.0 else 0.0
			rel_mass = maxf(rel_mass, absf(actual_mass[index] - expected_mass) / maxf(max_ref_mass[component], 1.0e-12))
			rel_momentum = maxf(rel_momentum, absf(actual_mass[index] * actual_velocity[index] - expected_mom) / maxf(max_ref_momentum[component], 1.0e-12))
			rel_velocity = maxf(rel_velocity, absf(actual_velocity[index] - expected_vel) / maxf(max_ref_velocity[component], 1.0e-12))
	var partition_mass_rel := 0.0
	var partition_momentum_rel := 0.0
	if setup.scenario != "solid_affine":
		var particle_velocity_sum := Vector3.ZERO
		for particle in solver.live_count():
			particle_velocity_sum += Vector3(velocity_data[particle * 4], velocity_data[particle * 4 + 1], velocity_data[particle * 4 + 2])
		var expected_total_mass := float(solver.live_count()) * particle_mass
		for component in 3:
			partition_mass_rel = maxf(partition_mass_rel,
				absf(sums_mass[component] - expected_total_mass) / expected_total_mass)
			var expected_total_momentum := expected_total_mass * particle_velocity_sum[component] / float(solver.live_count())
			partition_momentum_rel = maxf(partition_momentum_rel,
				absf(sums_momentum[component] - expected_total_momentum) / maxf(absf(expected_total_momentum), expected_total_mass * 0.01))
	for index in actual_mass.size():
		actual_momentum[index] = actual_mass[index] * actual_velocity[index]
	result.merge({"metrics": {"rel_mass": rel_mass, "rel_momentum": rel_momentum,
		"rel_velocity": rel_velocity, "partition_mass_rel": partition_mass_rel,
		"partition_momentum_rel": partition_momentum_rel, "masked_faces": masked_faces},
		"mass": actual_mass, "momentum": actual_momentum,
		"velocity": actual_velocity, "mask": mask}, true)


static func _apic_transfer_mode_delta(a: Dictionary, b: Dictionary) -> Dictionary:
	var max_mass := 0.0
	var max_momentum := 0.0
	var max_velocity := 0.0
	var mask_mismatch := 0
	for index in a.mass.size():
		if a.mask[index] != b.mask[index]:
			mask_mismatch += 1
		if a.mask[index] != 0 or b.mask[index] != 0:
			continue
		max_mass = maxf(max_mass, absf(a.mass[index] - b.mass[index]))
		max_momentum = maxf(max_momentum, absf(a.momentum[index] - b.momentum[index]))
		max_velocity = maxf(max_velocity, absf(a.velocity[index] - b.velocity[index]))
	return {"rel_mass": max_mass / maxf(_array_max_abs(a.mass), 1.0e-12),
		"rel_momentum": max_momentum / maxf(_array_max_abs(a.momentum), 1.0e-12),
		"rel_velocity": max_velocity / maxf(_array_max_abs(a.velocity), 1.0e-12),
		"mask_mismatch": mask_mismatch}


static func _array_max_abs(values: PackedFloat32Array) -> float:
	var result := 0.0
	for value in values:
		result = maxf(result, absf(value))
	return result


static func _apic_transfer_weight(distance: float) -> float:
	var d := absf(distance)
	if d < 0.5:
		return 0.75 - d * d
	if d < 1.5:
		var q := 1.5 - d
		return 0.5 * q * q
	return 0.0


static func run_apic_timestep(tree: SceneTree, check: Callable,
		free_surface_cut_cells: bool = false) -> void:
	var runs: Array[Dictionary] = []
	for requested_substeps in ([1, 3, 5] if free_surface_cut_cells else [1, 2, 5]):
		var solver: ApicFluidSolver = build_apic_solver(0.12, 0, 0.24,
			free_surface_cut_cells, false, requested_substeps)
		solver.profiling = true
		var seed: PackedFloat32Array = solver._seed_data
		RenderingServer.call_on_render_thread(solver.init_render)
		for _wait in 120:
			await RenderingServer.frame_post_draw
			if solver.initialized:
				break
		if not solver.initialized:
			check.call(false, "APIC timestep: solver initialization failed")
			continue
		RenderingServer.call_on_render_thread(_set_seed_velocities.bind(solver, seed))
		await RenderingServer.frame_post_draw
		var initial_volume_state := {}
		if free_surface_cut_cells:
			RenderingServer.call_on_render_thread(_read_apic_initial_volume_render.bind(solver, initial_volume_state))
			await RenderingServer.frame_post_draw
		var initial_plateau_x := _apic_timestep_initial_plateau(seed, solver.spacing)
		var samples: Dictionary = {}
		var gpu_samples := PackedFloat64Array()
		for frame in 480:
			RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
			await RenderingServer.frame_post_draw
			var gpu_ms := float(solver.get_timings().get("total", -1.0))
			if frame >= 60 and gpu_ms >= 0.0:
				gpu_samples.append(gpu_ms)
			var sample_second := frame + 1
			if sample_second == 60 or sample_second == 480:
				var sample := {}
				RenderingServer.call_on_render_thread(_read_apic_timestep_metrics.bind(solver, sample))
				await RenderingServer.frame_post_draw
				samples[int(sample_second / 60)] = sample
				var diagnostics: Dictionary = sample.diagnostics
				if free_surface_cut_cells:
					var volume_state: Dictionary = sample.volume_state
					var initial_volume := float(initial_volume_state.planar_cell_volume_estimate_m3)
					var volume_drift := absf(float(volume_state.planar_cell_volume_estimate_m3) - initial_volume) / initial_volume
					print("BREAKER TIMESTEP VOLUME scenario=solitary_slope_rock seed=0 substeps=%d dx_m=%.6f spacing_m=%.6f time_s=%.6f surface_advection=bounded_maccormack_rk2 relative_volume_estimate_drift=%.9f geometric_accuracy=unavailable" % [
						requested_substeps, solver.grid_dx, solver.spacing, solver._sim_time, volume_drift])
					check.call(bool(volume_state.finite) and volume_drift <= 0.01,
						"APIC timestep: measured interface volume drift exceeds 1%")
				var timing_ms := float(solver.get_timings().get("total", -1.0))
				var timing_report := "%.9f" % timing_ms if timing_ms >= 0.0 else "unavailable"
				print("BREAKER TIMESTEP substeps_requested=%d substeps_applied=%d sample_t_s=%.9f physical_time_s=%.9f particles=%d memory_bytes=%d gpu_ms=%s render=unavailable finite=%d outside=%d terrain_rock_penetration_m=%.9f crest_x_m=%.9f crest_y_m=%.9f plateau_x_m=%.9f kinetic_energy_j=%.9f excess_volume_m3=%.9f backwash_momentum_x_kg_m_s=%.9f runup_x_m=%.9f divergence_max_s_inv=%.9f pressure_residual_s_inv=%.9f pressure_iterations=%d pressure_tolerance_s_inv=%.9f" % [
					requested_substeps, solver.last_substeps, float(sample_second) / 60.0,
					solver._sim_time, solver.live_count(), solver.get_gpu_memory_bytes(), timing_report,
					int(sample.finite), int(sample.outside), float(sample.penetration),
					float(sample.crest_x), float(sample.crest_y), float(sample.plateau_x), float(sample.kinetic_energy),
					float(sample.excess_volume), float(sample.backwash_momentum), float(sample.runup_x),
					float(diagnostics.get("divergence_max_s_inv", INF)),
					float(diagnostics.get("pressure_residual_max_s_inv", INF)),
					int(diagnostics.get("pressure_iterations", -1)),
					float(diagnostics.get("pressure_tolerance_s_inv", INF))])
				check.call(int(sample.finite) == solver.live_count() and int(sample.outside) == 0
					and float(sample.penetration) <= 0.02,
					"APIC timestep: invalid or penetrating particle state at t=%.3f substeps=%d" % [
					float(sample_second) / 60.0, requested_substeps])
				check.call(bool(diagnostics.get("finite", false))
					and float(diagnostics.get("divergence_max_s_inv", INF))
					<= float(diagnostics.get("pressure_tolerance_s_inv", 0.001)),
					"APIC timestep: pressure tolerance failed at t=%.3f substeps=%d" % [
					float(sample_second) / 60.0, requested_substeps])
		check.call(absf(solver._sim_time - 8.0) <= 1.0e-6,
			"APIC timestep: physical time did not reach 8 seconds")
		gpu_samples.sort()
		print("BREAKER TIMESTEP COST substeps=%d physical_time_s=%.6f gpu_p95_ms=%s samples=%d render=unavailable" % [
			requested_substeps, solver._sim_time,
			str(gpu_samples[ceili(float(gpu_samples.size()) * 0.95) - 1]) if not gpu_samples.is_empty() else "unavailable", gpu_samples.size()])
		runs.append({"substeps": requested_substeps, "initial_plateau_x": initial_plateau_x,
			"particle_count": solver.live_count(), "samples": samples})
		solver.profiling = false
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
	if runs.size() != 3:
		check.call(false, "APIC timestep: expected all three substep runs")
		return
	var reference: Dictionary = runs[2].samples
	var ref_one: Dictionary = reference[1]
	var ref_amplitude := float(ref_one.crest_y) - LEVEL
	var ref_displacement := float(ref_one.plateau_x) - float(runs[2].initial_plateau_x)
	var prebreaking_ok := true
	for run_index in 2:
		var run: Dictionary = runs[run_index]
		var sample_one: Dictionary = run.samples[1]
		var amplitude_error := absf((float(sample_one.crest_y) - LEVEL) - ref_amplitude) \
			/ maxf(absf(ref_amplitude), 0.001)
		var phase_error := absf(float(sample_one.plateau_x) - float(ref_one.plateau_x)) \
			/ maxf(absf(ref_displacement), 0.001)
		var amplitude_phase_pass := amplitude_error <= 0.05 and phase_error <= 0.05
		var diagnostics: Dictionary = sample_one.diagnostics
		var pressure_pass := bool(diagnostics.get("finite", false)) \
			and float(diagnostics.get("divergence_max_s_inv", INF)) \
			<= float(diagnostics.get("pressure_tolerance_s_inv", 0.001))
		var physical_control := int(sample_one.finite) == int(run.particle_count) \
			and int(sample_one.outside) == 0 and float(sample_one.penetration) <= 0.02 \
			and pressure_pass
		prebreaking_ok = prebreaking_ok and amplitude_phase_pass and physical_control
		check.call(amplitude_phase_pass,
			"APIC timestep: prebreaking amplitude or phase error exceeds 5 percent for substeps=%d" % int(run.substeps))
		print("BREAKER TIMESTEP COMPARE substeps=%d reference_substeps=5 t_s=1.000000000 amplitude_error_pct=%.9f phase_error_pct=%.9f physical_control=%s prebreaking_5pct=%s" % [
			int(run.substeps), amplitude_error * 100.0, phase_error * 100.0,
			str(physical_control), str(amplitude_phase_pass)])
		var sample_eight: Dictionary = run.samples[8]
		var ref_eight: Dictionary = reference[8]
		print("BREAKER TIMESTEP LONG substeps=%d reference_substeps=5 t_s=8.000000000 kinetic_energy_j=%.9f reference_kinetic_energy_j=%.9f d_kinetic_energy_pct=%.9f excess_volume_m3=%.9f reference_excess_volume_m3=%.9f d_excess_volume_pct=%.9f backwash_momentum_x_kg_m_s=%.9f reference_backwash_momentum_x_kg_m_s=%.9f d_backwash_momentum_pct=%.9f runup_x_m=%.9f reference_runup_x_m=%.9f d_runup_x_m=%.9f" % [
			int(run.substeps), float(sample_eight.kinetic_energy), float(ref_eight.kinetic_energy),
			_apic_timestep_percent(float(sample_eight.kinetic_energy),
				float(ref_eight.kinetic_energy)), float(sample_eight.excess_volume), float(ref_eight.excess_volume),
			_apic_timestep_percent(float(sample_eight.excess_volume), float(ref_eight.excess_volume)),
			float(sample_eight.backwash_momentum), float(ref_eight.backwash_momentum),
			_apic_timestep_percent(float(sample_eight.backwash_momentum), float(ref_eight.backwash_momentum)),
			float(sample_eight.runup_x), float(ref_eight.runup_x),
			float(sample_eight.runup_x) - float(ref_eight.runup_x)])
	var mass_control := int(runs[0].particle_count) == int(runs[1].particle_count) \
		and int(runs[0].particle_count) == int(runs[2].particle_count)
	print("BREAKER TIMESTEP DECISION sub1_sub2_prebreaking=%s particle_volume_control=%s branch_selected=false recommendation=unselected rendering=unavailable" % [
		str(prebreaking_ok), str(mass_control)])


static func _read_apic_timestep_metrics(solver: ApicFluidSolver, result: Dictionary) -> void:
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.velocities_a).to_float32_array()
	var count := solver.live_count()
	var finite := 0
	var outside := 0
	var penetration := 0.0
	var max_y := -INF
	var crest_x := X_MIN
	var runup_x := X_MIN
	var kinetic_energy := 0.0
	var excess_particles := 0
	var backwash_momentum := 0.0
	var plateau_x_sum := 0.0
	var plateau_count := 0
	var particle_mass := solver.material_density_kg_m3 * pow(solver.spacing, 3.0)
	for particle in count:
		var offset := particle * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		if not p.is_finite() or not v.is_finite():
			continue
		finite += 1
		if p.x < X_MIN or p.x > X_MAX or p.y < Y_MIN or p.y > Y_MAX or p.z < Z_MIN or p.z > Z_MAX:
			outside += 1
		var clearance := p.y - _bed_height(p.x)
		penetration = maxf(penetration, -clearance)
		var rock_delta := (p - ROCK_CENTER).abs()
		var rock_inside := ROCK_SIZE * 0.5 - rock_delta
		if rock_inside.x > 0.0 and rock_inside.y > 0.0 and rock_inside.z > 0.0:
			penetration = maxf(penetration, minf(rock_inside.x, minf(rock_inside.y, rock_inside.z)))
		if p.y > max_y:
			max_y = p.y
			crest_x = p.x
		if p.y > LEVEL + solver.spacing:
			runup_x = maxf(runup_x, p.x)
		if p.y > LEVEL:
			excess_particles += 1
		if p.x > 0.0 and v.x < 0.0:
			backwash_momentum += particle_mass * v.x
		kinetic_energy += 0.5 * particle_mass * v.length_squared()
	for particle in count:
		var offset := particle * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		if p.is_finite() and p.y >= max_y - solver.spacing:
			plateau_x_sum += p.x
			plateau_count += 1
	result.merge({"finite": finite, "outside": outside, "penetration": maxf(penetration, 0.0),
		"crest_y": max_y, "crest_x": crest_x,
		"plateau_x": plateau_x_sum / float(maxi(plateau_count, 1)),
		"kinetic_energy": kinetic_energy,
		"excess_volume": float(excess_particles) * pow(solver.spacing, 3.0),
		"backwash_momentum": backwash_momentum, "runup_x": runup_x,
		"diagnostics": solver.get_diagnostics()}, true)
	if solver.free_surface_cut_cells:
		result["volume_state"] = _apic_volume_diagnostics(solver)


static func _apic_timestep_initial_plateau(seed: PackedFloat32Array, spacing_m: float) -> float:
	var max_y := -INF
	for particle in seed.size() / 4:
		max_y = maxf(max_y, seed[particle * 4 + 1])
	var x_sum := 0.0
	var count := 0
	for particle in seed.size() / 4:
		if seed[particle * 4 + 1] >= max_y - spacing_m:
			x_sum += seed[particle * 4]
			count += 1
	return x_sum / float(maxi(count, 1))


static func _apic_timestep_percent(value: float, reference: float) -> float:
	return 100.0 * (value - reference) / maxf(absf(reference), 1.0e-12)


static func run_apic_wall_slip(tree: SceneTree, check: Callable) -> void:
	await _run_apic_contact_offset(tree, check)
	var solver: ApicFluidSolver = _build_apic_wall_slip_solver()
	print("BREAKER WALL SLIP setup scenario=flat_floor_uniform_current seed=0 spacing_m=%.3f domain=%s floor_size_m=%s current_m_s=(1,0,0) gravity_m_s2=(0,0,0)" % [
		solver.spacing, str(solver.config.domain_size_m), str(solver.scene_obstacles[0].size)])
	var velocity_data := PackedFloat32Array()
	velocity_data.resize(solver.particle_count * 4)
	for particle in solver.particle_count:
		velocity_data[particle * 4] = 1.0
		velocity_data[particle * 4 + 3] = float(particle)
	RenderingServer.call_on_render_thread(solver.init_render)
	for _wait in 120:
		await RenderingServer.frame_post_draw
		if solver.initialized:
			break
	if not solver.initialized:
		check.call(false, "APIC wall slip: solver initialization failed")
		return
	RenderingServer.call_on_render_thread(_set_apic_wall_slip_velocity.bind(solver, velocity_data))
	await RenderingServer.frame_post_draw
	for frame in 60:
		RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
		await RenderingServer.frame_post_draw
		if frame == 0 or frame == 59:
			var sample := {}
			var elapsed_s := float(frame + 1) / 60.0
			RenderingServer.call_on_render_thread(_read_apic_wall_slip_metrics.bind(solver, elapsed_s, sample))
			await RenderingServer.frame_post_draw
			var memory_bytes := solver.get_gpu_memory_bytes()
			print("BREAKER WALL SLIP sample_t_s=%.9f physical_time_s=%.9f substeps_requested=%d substeps_applied=%d particles=%d memory_bytes=%d collision_inflation_m=%.9f gpu_timing=unavailable render=unavailable finite=%d outside=%d penetration_m=%.9f core_count=%d core_vx_mean_m_s=%.9f core_vx_max_error_m_s=%.9f core_cross_velocity_max_m_s=%.9f projection_diagnostics=%s surface_pressure=unavailable density=unavailable" % [
				elapsed_s, solver._sim_time, solver.substeps, solver.last_substeps, solver.live_count(), memory_bytes,
				solver.collision_inflation,
				int(sample.finite), int(sample.outside), float(sample.penetration), int(sample.core_count),
				float(sample.core_vx_mean), float(sample.core_vx_max_error),
				float(sample.core_cross_velocity_max), str(sample.projection)])
			check.call(int(sample.finite) == solver.live_count() and int(sample.outside) == 0
				and float(sample.penetration) <= 0.02,
				"APIC wall slip: invalid particle state at t=%.9f" % elapsed_s)
			check.call(int(sample.core_count) > 50 and float(sample.core_vx_max_error) <= 1.0e-4
				and float(sample.core_cross_velocity_max) <= 1.0e-4,
				"APIC wall slip: near-wall core velocity changed at t=%.9f" % elapsed_s)
	check.call(absf(solver._sim_time - 1.0) <= 1.0e-6,
		"APIC wall slip: physical time did not reach one second")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_contact_offset(tree: SceneTree, check: Callable) -> void:
	const DX := 0.24
	const DT := 1.0 / 60.0
	const CONTACT_Y := 0.06
	var config := FluidConfig.new()
	config.domain_origin = -Vector3.ONE
	config.domain_size_m = Vector3.ONE * 2.0
	config.default_particle_count = 2
	config.particle_counts = [2]
	config.texture_width = 2
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = 2
	solver.active_count = 2
	solver.spacing = DX * 0.5
	solver.grid_cell_size_m = DX
	solver.collision_inflation = CONTACT_Y
	solver.free_surface_cut_cells = true
	solver.gravity = Vector3.ZERO
	solver.substeps = 1
	solver.set_seed_positions(PackedFloat32Array([0.0, 0.1, 0.0, 0.0, 0.0, 0.055, 0.2, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(9 * 9 * 9)
	phi.fill(1.0)
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([{"transform": Transform3D(Basis.IDENTITY, Vector3(0.0, -0.05, 0.0)),
		"size": Vector3(2.0, 0.1, 2.0), "retention": 1.0}])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC contact offset: initialization failed")
		return
	RenderingServer.call_on_render_thread(_set_apic_wall_slip_velocity.bind(solver,
		PackedFloat32Array([0.8, -3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])))
	await RenderingServer.frame_post_draw
	for tick in 2:
		RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
		await RenderingServer.frame_post_draw
		var result := {}
		RenderingServer.call_on_render_thread(_read_apic_contact_offset.bind(solver, result))
		await RenderingServer.frame_post_draw
		print("BREAKER APIC CONTACT OFFSET scenario=swept_contact_and_initial_overlap seed=0 dx_m=%.6f dt_s=%.9f physical_time_s=%.9f contact_y_m=%.6f numerical_clearance_limit_m=%.9f positions=%s velocities=%s memory_bytes=%d gpu_timing=unavailable" % [
			DX, DT, solver._sim_time, CONTACT_Y, DX * 1.0e-4 + 2.0e-6,
			str(result.positions), str(result.velocities), solver.get_gpu_memory_bytes()])
		for particle in 2:
			var p: Vector3 = result.positions[particle]
			var v: Vector3 = result.velocities[particle]
			check.call(p.is_finite() and v.is_finite() and p.y >= CONTACT_Y - 2.0e-6
				and p.y - CONTACT_Y <= DX * 1.0e-4 + 2.0e-6 and absf(v.y) <= 1.0e-6,
				"APIC contact offset: collision injects a position lift beyond numerical clearance")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _read_apic_contact_offset(solver: ApicFluidSolver, result: Dictionary) -> void:
	var p := solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
	var v := solver._rd.buffer_get_data(solver._buffers.velocities_a).to_float32_array()
	result["positions"] = [Vector3(p[0], p[1], p[2]), Vector3(p[4], p[5], p[6])]
	result["velocities"] = [Vector3(v[0], v[1], v[2]), Vector3(v[4], v[5], v[6])]


static func _build_apic_wall_slip_solver() -> ApicFluidSolver:
	var particle_spacing := 0.12
	var count := 32 * 8 * 20
	var origin := Vector3(-2.0, -0.48, -0.8)
	var domain_size := Vector3(7.84, 1.68, 4.0)
	var seed := PackedFloat32Array()
	for y in 8:
		for z in 20:
			for x in 32:
				var p := Vector3((float(x) + 0.5) * particle_spacing,
					(float(y) + 0.5) * particle_spacing,
					(float(z) + 0.5) * particle_spacing)
				seed.append_array([p.x, p.y, p.z, 0.0])
	var config := FluidConfig.new()
	config.default_particle_count = count
	config.particle_counts = [count]
	config.texture_width = ceili(sqrt(float(count)))
	config.domain_origin = origin
	config.domain_size_m = domain_size
	config.grid_origin = origin
	config.cell_size_m = particle_spacing * 2.0
	config.grid_dims = Vector3i(33, 7, 17)
	var solver: ApicFluidSolver = ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = count
	solver.active_count = count
	solver.spacing = particle_spacing
	solver.collision_inflation = particle_spacing * 0.5
	solver.gravity = Vector3.ZERO
	solver.substeps = 1
	solver.profiling = false
	var obstacles: Array[Dictionary] = [{"transform": Transform3D(Basis.IDENTITY,
		Vector3(1.92, -0.15, 1.2)), "size": Vector3(domain_size.x + 0.48, 0.3, domain_size.z + 0.48), "retention": 1.0}]
	solver.set_seed_positions(seed)
	solver.set_scene_obstacles(obstacles)
	return solver


static func _set_apic_wall_slip_velocity(solver: ApicFluidSolver,
		velocity_data: PackedFloat32Array) -> void:
	var bytes := velocity_data.to_byte_array()
	solver._rd.buffer_update(solver._buffers.velocities_a, 0, bytes.size(), bytes)


static func _read_apic_wall_slip_metrics(solver: ApicFluidSolver, elapsed_s: float,
		result: Dictionary) -> void:
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.velocities_a).to_float32_array()
	var finite := 0
	var outside := 0
	var penetration := 0.0
	var core_count := 0
	var core_vx_sum := 0.0
	var core_vx_error := 0.0
	var core_cross_velocity := 0.0
	var liquid_x_min := elapsed_s
	var liquid_x_max := elapsed_s + 32.0 * solver.spacing
	var liquid_z_min := 0.0
	var liquid_z_max := 20.0 * solver.spacing
	var core_margin := 2.0 * solver.h
	var inverse: Transform3D = solver.scene_obstacles[0].transform.affine_inverse()
	var half_size: Vector3 = solver.scene_obstacles[0].size * 0.5
	for particle in solver.live_count():
		var offset := particle * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		if not p.is_finite() or not v.is_finite():
			continue
		finite += 1
		if p.x < solver.config.domain_origin.x or p.y < solver.config.domain_origin.y \
				or p.z < solver.config.domain_origin.z \
				or p.x > solver.config.domain_origin.x + solver.config.domain_size_m.x \
				or p.y > solver.config.domain_origin.y + solver.config.domain_size_m.y \
				or p.z > solver.config.domain_origin.z + solver.config.domain_size_m.z:
			outside += 1
		var local: Vector3 = inverse * p
		var inside := half_size - local.abs()
		if inside.x > 0.0 and inside.y > 0.0 and inside.z > 0.0:
			penetration = maxf(penetration, minf(inside.x, minf(inside.y, inside.z)))
		if p.y >= 0.0 and p.y < solver.spacing \
				and p.x >= liquid_x_min + core_margin and p.x <= liquid_x_max - core_margin \
				and p.z >= liquid_z_min + core_margin and p.z <= liquid_z_max - core_margin:
			core_count += 1
			core_vx_sum += v.x
			core_vx_error = maxf(core_vx_error, absf(v.x - 1.0))
			core_cross_velocity = maxf(core_cross_velocity, maxf(absf(v.y), absf(v.z)))
	result.merge({"finite": finite, "outside": outside, "penetration": maxf(penetration, 0.0),
		"core_count": core_count, "core_vx_mean": core_vx_sum / float(maxi(core_count, 1)),
		"core_vx_max_error": core_vx_error, "core_cross_velocity_max": core_cross_velocity,
		"projection": solver.get_diagnostics()}, true)


static func run_incident_cpu(check: Callable) -> void:
	var sample_x: Array[float] = [-12.0, -8.0, -4.0, 0.5, 6.0, 12.0]
	var fractions: Array[float] = [0.25, 0.75]
	var epsilon := 0.001
	var max_flux_error := 0.0
	var max_divergence := 0.0
	var max_bed_slip := 0.0
	var max_kinematic_residual := 0.0
	var finite := true
	for x in sample_x:
		var eta := _wave_eta(x)
		var bed := _bed_height(x)
		var surface := LEVEL + eta
		var depth := surface - bed
		var c := sqrt(G * (DEPTH + 0.9))
		var flux := 0.0
		for midpoint in 128:
			var y := bed + (float(midpoint) + 0.5) * depth / 128.0
			var velocity := _wave_velocity(x, y)
			finite = finite and is_finite(velocity.x) and is_finite(velocity.y)
			flux += velocity.x * depth / 128.0
		var target_flux := depth * c * eta / (DEPTH + eta)
		var flux_error := absf(flux - target_flux) / maxf(absf(target_flux), 1.0e-12)
		max_flux_error = maxf(max_flux_error, flux_error)
		var bed_velocity := _wave_velocity(x, bed)
		var bed_slope := 0.0 if x <= 0.0 else BED_SLOPE
		var bed_slip := absf(bed_velocity.y - bed_velocity.x * bed_slope)
		finite = finite and is_finite(flux) and is_finite(target_flux) and is_finite(bed_slip)
		max_bed_slip = maxf(max_bed_slip, bed_slip)
		for fraction in fractions:
			var y := bed + fraction * depth
			var ux_plus := _wave_velocity(x + epsilon, y).x
			var ux_minus := _wave_velocity(x - epsilon, y).x
			var vy_plus := _wave_velocity(x, y + epsilon).y
			var vy_minus := _wave_velocity(x, y - epsilon).y
			var divergence := absf((ux_plus - ux_minus) / (2.0 * epsilon)
				+ (vy_plus - vy_minus) / (2.0 * epsilon))
			finite = finite and is_finite(divergence)
			max_divergence = maxf(max_divergence, divergence)
			if x < 0.0 and fraction == 0.75:
				var surface_velocity := _wave_velocity(x, surface)
				var eta_x := (_wave_eta(x + epsilon) - _wave_eta(x - epsilon)) / (2.0 * epsilon)
				var kinematic := absf((surface_velocity.x - c) * eta_x - surface_velocity.y)
				finite = finite and is_finite(eta_x) and is_finite(kinematic)
				max_kinematic_residual = maxf(max_kinematic_residual, kinematic)
	var crest_x := -8.0
	var crest_eta := 0.9
	var c_crest := sqrt(G * (DEPTH + crest_eta))
	var surface_crest := _wave_velocity(crest_x, LEVEL + crest_eta)
	var bernoulli := absf(pow(surface_crest.x - c_crest, 2.0)
		+ pow(surface_crest.y, 2.0) + 2.0 * G * crest_eta - c_crest * c_crest) \
		/ (c_crest * c_crest)
	finite = finite and is_finite(bernoulli)
	print("BREAKER INCIDENT CPU scenario=solitary_slope seed=0 depth_m=%.9f amplitude_m=%.9f flux_max_relative_error=%.9f divergence_max_s_inv=%.9f bed_slip_max_m_s=%.9f free_surface_kinematic_max_m_s=%.9f crest_bernoulli_relative_residual=%.9f finite=%s memory=unavailable gpu=unavailable render=unavailable pressure=unvalidated volume_3d=unvalidated" % [
		DEPTH, crest_eta, max_flux_error, max_divergence, max_bed_slip,
		max_kinematic_residual, bernoulli, str(finite)])
	check.call(finite, "incident CPU: non-finite wave metric")
	check.call(max_flux_error <= 1.0e-4,
		"incident CPU: vertical flux differs from declared discharge")
	check.call(max_divergence <= 0.001,
		"incident CPU: finite-difference divergence exceeds 0.001 s^-1")
	check.call(max_bed_slip <= 1.0e-5,
		"incident CPU: bottom impermeability condition failed")
	check.call(max_kinematic_residual <= 1.0e-5,
		"incident CPU: free-surface kinematic condition failed")
	check.call(bernoulli <= 0.05,
		"incident CPU: crest Bernoulli residual exceeds 5 percent")
	_test_apic_air_flood_topology(check)


static func _apic_grid_diagnostics(solver: ApicFluidSolver,
		positions: PackedFloat32Array) -> Dictionary:
	var dims: Vector3i = solver.grid_dims
	var cells: int = dims.x * dims.y * dims.z
	var types: PackedInt32Array = solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	var topology_types := types
	if solver.free_surface_cut_cells:
		var phi: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
		topology_types = PackedInt32Array()
		topology_types.resize(cells)
		for i in cells:
			topology_types[i] = 2 if types[i] == 2 else (1 if phi[i] < 0.0 else 0)
	var fluid_count := 0
	var visited := PackedByteArray()
	visited.resize(cells)
	var queue := PackedInt32Array()
	for i in cells:
		if topology_types[i] == 1:
			fluid_count += 1
		var x := i % dims.x
		var y := (i / dims.x) % dims.y
		var z := i / (dims.x * dims.y)
		if topology_types[i] == 0 and (x == 0 or y == 0 or z == 0
				or x == dims.x - 1 or y == dims.y - 1 or z == dims.z - 1):
			visited[i] = 1
			queue.append(i)
	_flood_apic_air(queue, visited, topology_types, dims)
	var trapped := 0
	var largest := 0
	for i in cells:
		if topology_types[i] != 0 or visited[i] != 0:
			continue
		queue.clear()
		queue.append(i)
		visited[i] = 1
		var size := 0
		_flood_apic_air(queue, visited, topology_types, dims)
		size = queue.size()
		trapped += size
		largest = maxi(largest, size)
	var solid_particles := 0
	var particle_cells := PackedByteArray()
	particle_cells.resize(cells)
	for particle in solver.live_count():
		var p := Vector3(positions[particle * 4], positions[particle * 4 + 1], positions[particle * 4 + 2])
		if not p.is_finite():
			continue
		var c := Vector3i(floori((p.x - solver.grid_origin.x) / solver.grid_dx),
			floori((p.y - solver.grid_origin.y) / solver.grid_dx),
			floori((p.z - solver.grid_origin.z) / solver.grid_dx))
		if c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < dims.x and c.y < dims.y and c.z < dims.z:
			var index: int = (c.z * dims.y + c.y) * dims.x + c.x
			particle_cells[index] = 1
			if types[index] == 2:
				solid_particles += 1
	var particle_occupied := 0
	var intersection := 0
	for i in cells:
		if particle_cells[i] != 0:
			particle_occupied += 1
			if topology_types[i] == 1:
				intersection += 1
	var union := fluid_count + particle_occupied - intersection
	var supported: Array[int] = [0, 0, 0]
	var massless: Array[int] = [0, 0, 0]
	var face_dims := dims + Vector3i.ONE
	var face_count: int = face_dims.x * face_dims.y * face_dims.z
	var blocked: PackedInt32Array = solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	var mass_keys: Array[String] = ["face_mass_u", "face_mass_v", "face_mass_w"]
	var velocity_keys: Array[String] = ["face_u", "face_v", "face_w"]
	var face_areas: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.face_area).to_float32_array()
	var dry_faces := 0
	var dry_net_proxy := 0.0
	var dry_absolute_proxy := 0.0
	for component in 3:
		var masses: PackedFloat32Array = solver._rd.buffer_get_data(
			solver._buffers[mass_keys[component]]).to_float32_array()
		var velocities: PackedFloat32Array = solver._rd.buffer_get_data(
			solver._buffers[velocity_keys[component]]).to_float32_array()
		for face in face_count:
			var offset := component * face_count + face
			if (blocked[offset] & 2) != 0:
				dry_faces += 1
				var right := Vector3i(face % face_dims.x, (face / face_dims.x) % face_dims.y,
					face / (face_dims.x * face_dims.y))
				var left := right
				left[component] -= 1
				var sign := 1.0 if _apic_surface_cell_is_fluid(left, dims, types) else -1.0
				var proxy := velocities[face] * face_areas[offset] * solver.grid_dx * solver.grid_dx
				dry_net_proxy += sign * proxy
				dry_absolute_proxy += absf(proxy)
			if blocked[offset] != 0:
				continue
			var x := face % face_dims.x
			var y := (face / face_dims.x) % face_dims.y
			var z := face / (face_dims.x * face_dims.y)
			var right := Vector3i(x, y, z)
			var left := right
			left[component] -= 1
			if not _apic_surface_cell_is_fluid(left, dims, types) \
					and not _apic_surface_cell_is_fluid(right, dims, types):
				continue
			if masses[face] > 0.0:
				supported[component] += 1
			else:
				massless[component] += 1
	return {"occupied_fluid_cell_volume_m3": float(fluid_count) * pow(solver.grid_dx, 3.0),
		"dry_pressure_faces": dry_faces,
		"dry_face_net_velocity_area_proxy_m3_s": dry_net_proxy,
		"dry_face_absolute_velocity_area_proxy_m3_s": dry_absolute_proxy,
		"trapped_air_cells": trapped, "largest_trapped_air_component_cells": largest,
		"particles_in_solid_cells": solid_particles,
		"mass_supported_fluid_faces": supported, "massless_fluid_faces": massless,
		"phi_fluid_cells": fluid_count if solver.free_surface_cut_cells else -1,
		"particle_occupied_cells": particle_occupied if solver.free_surface_cut_cells else -1,
		"phase_intersection_cells": intersection if solver.free_surface_cut_cells else -1,
		"phase_union_cells": union if solver.free_surface_cut_cells else -1,
		"phase_occupancy_iou": float(intersection) / float(union)
			if solver.free_surface_cut_cells and union > 0 else -1.0}


static func _flood_apic_air(queue: PackedInt32Array, visited: PackedByteArray,
		types: PackedInt32Array, dims: Vector3i) -> void:
	var offsets: Array[Vector3i] = [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP,
		Vector3i.DOWN, Vector3i(0, 0, -1), Vector3i(0, 0, 1)]
	var read_index := 0
	while read_index < queue.size():
		var index: int = queue[read_index]
		read_index += 1
		var x := index % dims.x
		var y := (index / dims.x) % dims.y
		var z := index / (dims.x * dims.y)
		for offset in offsets:
			var n := Vector3i(x, y, z) + offset
			if n.x < 0 or n.y < 0 or n.z < 0 or n.x >= dims.x or n.y >= dims.y or n.z >= dims.z:
				continue
			var neighbor: int = (n.z * dims.y + n.y) * dims.x + n.x
			if types[neighbor] == 0 and visited[neighbor] == 0:
				visited[neighbor] = 1
				queue.append(neighbor)


static func _test_apic_air_flood_topology(check: Callable) -> void:
	var dims := Vector3i(3, 3, 3)
	var types := PackedInt32Array()
	types.resize(27)
	types.fill(0)
	var center := 13
	var axial_neighbors: Array[int] = [12, 14, 10, 16, 4, 22]
	for index in axial_neighbors:
		types[index] = 1
	var visited := PackedByteArray()
	visited.resize(27)
	var queue := PackedInt32Array()
	for i in 27:
		var x := i % dims.x
		var y := (i / dims.x) % dims.y
		var z := i / (dims.x * dims.y)
		if types[i] == 0 and (x == 0 or y == 0 or z == 0
				or x == dims.x - 1 or y == dims.y - 1 or z == dims.z - 1):
			visited[i] = 1
			queue.append(i)
	_flood_apic_air(queue, visited, types, dims)
	var boundary_count := 0
	for value in visited:
		boundary_count += int(value)
	var center_sealed := visited[center] == 0
	var center_queue := PackedInt32Array([center])
	visited[center] = 1
	_flood_apic_air(center_queue, visited, types, dims)
	var sealed_size := center_queue.size()
	types[axial_neighbors[0]] = 0
	visited.fill(0)
	queue.clear()
	for i in 27:
		var x := i % dims.x
		var y := (i / dims.x) % dims.y
		var z := i / (dims.x * dims.y)
		if types[i] == 0 and (x == 0 or y == 0 or z == 0
				or x == dims.x - 1 or y == dims.y - 1 or z == dims.z - 1):
			visited[i] = 1
			queue.append(i)
	_flood_apic_air(queue, visited, types, dims)
	var opened_count := 0
	for value in visited:
		opened_count += int(value)
	print("BREAKER GRID TOPOLOGY CPU boundary_air_reached=%d sealed_center=%s sealed_component_cells=%d opened_air_reached=%d expected_opened_air=22 gpu_claim=none" % [
		boundary_count, str(center_sealed), sealed_size, opened_count])
	check.call(boundary_count == 20 and center_sealed and sealed_size == 1,
		"grid topology CPU: enclosed air center was not isolated")
	check.call(opened_count == 22,
		"grid topology CPU: opening an axial air path did not reach all air cells")


static func run_sph_prediction(tree: SceneTree, check: Callable) -> void:
	const COUNT := 512
	const SPACING := 0.12
	var seed := PackedFloat32Array()
	for z in 8:
		for y in 8:
			for x in 8:
				seed.append_array([0.30 + float(x) * SPACING,
					0.30 + float(y) * SPACING, 0.30 + float(z) * SPACING, 0.0])
	var config := FluidConfig.new()
	config.default_particle_count = COUNT
	config.particle_counts = [COUNT]
	config.texture_width = 23
	config.grid_origin = Vector3.ZERO
	config.domain_origin = Vector3.ZERO
	config.cell_size_m = 0.24
	config.grid_dims = Vector3i.ONE * 6
	config.domain_size_m = Vector3(config.grid_dims) * config.cell_size_m
	var solver: SphFluidSolver = Solver.new()
	solver.config = config
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.spacing = SPACING
	solver.gravity = Vector3.ZERO
	solver.viscosity_strength = 0.0
	solver.collision_inflation = 0.0
	solver.foam_tex_width = 32
	solver.set_seed_positions(seed)
	var obstacles: Array[Dictionary] = []
	solver.set_scene_obstacles(obstacles)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "SPH prediction: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_sph_prediction_render.bind(solver, result))
	await RenderingServer.frame_post_draw
	var mass_kg := float(COUNT) * pow(SPACING, 3.0) * solver.material_density_kg_m3
	for sample: Dictionary in result.get("samples", []):
		var error_m := float(sample.error_m)
		print("BREAKER SPH PREDICTION scenario=uniform_translation seed=0 particles=512 physical_time_s=0 velocity_m_s=(1,0.2,-0.3) dt_requested_s=%.9f dt_applied_s=%.9f spacing_m=%.3f cell_size_m=%.3f mass_kg=%.6f max_prediction_error_m=%.9f memory_bytes=unavailable gpu_timing=unavailable" % [
			float(sample.dt), float(sample.dt), SPACING, solver.cell_size, mass_kg, error_m])
		check.call(bool(sample.finite) and error_m <= 1.0e-6,
			"SPH prediction: predicted position differs from position + velocity * dt_sub")
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_sph_prediction_render(solver: SphFluidSolver, result: Dictionary) -> void:
	const COUNT := 512
	var velocity_data := PackedFloat32Array()
	velocity_data.resize(COUNT * 4)
	for i in COUNT:
		velocity_data[i * 4] = 1.0
		velocity_data[i * 4 + 1] = 0.2
		velocity_data[i * 4 + 2] = -0.3
		velocity_data[i * 4 + 3] = float(i)
	var bytes := velocity_data.to_byte_array()
	for key in ["velocities_a", "velocities_b"]:
		solver._rd.buffer_update(solver._buffers[key], 0, bytes.size(), bytes)
	var samples: Array[Dictionary] = []
	var dts: Array[float] = [1.0 / 60.0, 1.0 / 180.0, 1.0 / 300.0, 1.0 / 600.0]
	for dt in dts:
		var pc := solver._pack_push_constant(dt, 1)
		var cl := solver._rd.compute_list_begin()
		var groups := ceili(float(solver._grid_cell_count()) / 256.0)
		solver._dispatch(cl, "grid_clear", pc, groups)
		solver._dispatch(cl, "sph_external", pc, ceili(float(COUNT) / 256.0))
		solver._rd.compute_list_end()
		var positions: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
		var predicted: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.predicted_a).to_float32_array()
		var max_error := 0.0
		for i in COUNT:
			var offset: int = i * 4
			var expected := Vector3(positions[offset], positions[offset + 1], positions[offset + 2]) \
				+ Vector3(1.0, 0.2, -0.3) * dt
			var actual := Vector3(predicted[offset], predicted[offset + 1], predicted[offset + 2])
			max_error = maxf(max_error, actual.distance_to(expected))
		samples.append({"dt": dt, "error_m": max_error, "finite": is_finite(max_error)})
	result["samples"] = samples


static func run_sph_density_snapshot(tree: SceneTree, check: Callable) -> void:
	const COUNT := 64
	const SPACING := 0.12
	var seed := PackedFloat32Array()
	var particle_index := 0
	for z in 4:
		for y in 4:
			for x in 4:
				var p := Vector3(0.30 + float(x) * SPACING,
					0.30 + float(y) * SPACING, 0.30 + float(z) * SPACING)
				if particle_index % 11 == 0:
					p += Vector3(0.017, -0.009, 0.013)
				seed.append_array([p.x, p.y, p.z, float(particle_index)])
				particle_index += 1
	var config := FluidConfig.new()
	config.default_particle_count = COUNT
	config.particle_counts = [COUNT]
	config.texture_width = 8
	config.grid_origin = Vector3.ZERO
	config.domain_origin = Vector3.ZERO
	config.cell_size_m = 0.24
	config.grid_dims = Vector3i.ONE * 6
	config.domain_size_m = Vector3(config.grid_dims) * config.cell_size_m
	var solver: SphFluidSolver = Solver.new()
	solver.config = config
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.spacing = SPACING
	solver.gravity = Vector3.ZERO
	solver.viscosity_strength = 0.0
	solver.pressure_mult = 0.0
	solver.near_pressure_mult = 0.0
	solver.collision_inflation = 0.0
	solver.substeps = 1
	solver.foam_tex_width = 16
	solver.set_seed_positions(seed)
	var obstacles: Array[Dictionary] = []
	solver.set_scene_obstacles(obstacles)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "SPH density snapshot: solver failed to initialize")
		return
	var first := {}
	RenderingServer.call_on_render_thread(_sph_density_snapshot_render.bind(solver, first, true, true))
	await RenderingServer.frame_post_draw
	RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 600.0))
	await RenderingServer.frame_post_draw
	var second := {}
	RenderingServer.call_on_render_thread(_sph_density_snapshot_render.bind(solver, second, false, false))
	await RenderingServer.frame_post_draw
	var mass_kg := float(COUNT) * pow(SPACING, 3.0) * solver.material_density_kg_m3
	for sample: Dictionary in [first, second]:
		print("BREAKER SPH DENSITY SNAPSHOT scenario=irregular_lattice seed=0 cell_size_m=%.3f spacing_m=%.3f physical_time_s=%.9f particles=%d mass_kg=%.6f max_relative_density_error=%.9f state_preserved=%s memory_bytes=unavailable gpu_timing=unavailable" % [
			solver.cell_size, SPACING, float(sample.time_s), COUNT, mass_kg,
			float(sample.error), str(sample.state_ok)])
		check.call(bool(sample.state_ok) and float(sample.error) <= 1.0e-5,
			"SPH density snapshot: state changed or GPU density differs from all-pairs CPU reference")
	check.call(bool(first.empty_ok), "SPH density snapshot: empty snapshot was not empty")
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _sph_density_snapshot_render(solver: SphFluidSolver, result: Dictionary,
		seed_velocities: bool, check_empty: bool) -> void:
	const COUNT := 64
	if seed_velocities:
		var velocity_data := PackedFloat32Array()
		velocity_data.resize(COUNT * 4)
		for i in COUNT:
			velocity_data[i * 4] = 0.3
			velocity_data[i * 4 + 1] = 0.1
			velocity_data[i * 4 + 2] = -0.2
			velocity_data[i * 4 + 3] = float(i)
		var velocity_bytes := velocity_data.to_byte_array()
		for key in ["velocities_a", "velocities_b"]:
			solver._rd.buffer_update(solver._buffers[key], 0, velocity_bytes.size(), velocity_bytes)
	var parity := solver.current_parity()
	var suffix := "a" if parity == 0 else "b"
	var active_positions: PackedByteArray = solver._rd.buffer_get_data(solver._buffers["positions_" + suffix])
	var active_velocities: PackedByteArray = solver._rd.buffer_get_data(solver._buffers["velocities_" + suffix])
	var texture_before: PackedByteArray = solver._rd.texture_get_data(solver.get_position_tex_rid(), 0)
	var frame := solver._frame
	var time := solver._sim_time
	var snapshot := solver.read_current_particle_state_render()
	var positions_after: PackedByteArray = solver._rd.buffer_get_data(solver._buffers["positions_" + suffix])
	var velocities_after: PackedByteArray = solver._rd.buffer_get_data(solver._buffers["velocities_" + suffix])
	var texture_after: PackedByteArray = solver._rd.texture_get_data(solver.get_position_tex_rid(), 0)
	var cpu_density := PackedFloat32Array()
	cpu_density.resize(COUNT)
	var positions: PackedFloat32Array = snapshot.positions_m
	var gpu_density: PackedFloat32Array = snapshot.kernel_density_m_inv3
	var h := solver.h
	var kernel := 15.0 / (2.0 * PI * pow(h, 5.0))
	var max_relative_error := 0.0
	for i in COUNT:
		var a := Vector3(positions[i * 4], positions[i * 4 + 1], positions[i * 4 + 2])
		for j in COUNT:
			var b := Vector3(positions[j * 4], positions[j * 4 + 1], positions[j * 4 + 2])
			var distance_squared := a.distance_squared_to(b)
			if distance_squared < h * h:
				cpu_density[i] += pow(h - sqrt(distance_squared), 2.0) * kernel
		max_relative_error = maxf(max_relative_error,
			absf(gpu_density[i] - cpu_density[i]) / maxf(absf(cpu_density[i]), 1.0e-12))
	var active_position_values := active_positions.to_float32_array()
	var active_velocity_values := active_velocities.to_float32_array()
	var seen_ids := PackedByteArray()
	seen_ids.resize(COUNT)
	var tuples_ok: bool = positions.size() == COUNT * 4 and snapshot.velocities_m_s.size() == COUNT * 4
	var active_slot_by_id := PackedInt32Array()
	active_slot_by_id.resize(COUNT)
	active_slot_by_id.fill(-1)
	for slot in COUNT:
		var active_id := roundi(active_position_values[slot * 4 + 3])
		if active_id < 0 or active_id >= COUNT or active_slot_by_id[active_id] != -1:
			tuples_ok = false
		else:
			active_slot_by_id[active_id] = slot
	for i in COUNT:
		var id := roundi(positions[i * 4 + 3])
		if id < 0 or id >= COUNT or seen_ids[id] != 0 or active_slot_by_id[id] < 0:
			tuples_ok = false
			continue
		seen_ids[id] = 1
		var active_offset := active_slot_by_id[id] * 4
		for component in 4:
			tuples_ok = tuples_ok and is_equal_approx(positions[i * 4 + component], active_position_values[active_offset + component]) \
				and is_equal_approx(snapshot.velocities_m_s[i * 4 + component], active_velocity_values[active_offset + component])
	var state_ok: bool = parity == solver.current_parity() and frame == solver._frame \
		and is_equal_approx(time, solver._sim_time) and active_positions == positions_after \
		and active_velocities == velocities_after and texture_before == texture_after \
		and int(snapshot.state_revision) == frame and is_equal_approx(float(snapshot.physical_time_s), time) \
		and int(snapshot.particle_count) == COUNT and tuples_ok
	var empty_ok := true
	if check_empty:
		solver.active_count = 0
		var empty := solver.read_current_particle_state_render()
		empty_ok = int(empty.particle_count) == 0 and empty.positions_m.is_empty() \
			and empty.velocities_m_s.is_empty() and empty.kernel_density_m_inv3.is_empty()
		solver.active_count = COUNT
	result.merge({"error": max_relative_error, "state_ok": state_ok,
		"empty_ok": empty_ok, "time_s": time}, true)


static func run_sph_pressure_conservation(tree: SceneTree, check: Callable) -> void:
	const COUNT := 3
	const SPACING := 0.12
	const DT := 1.0 / 600.0
	var seed := PackedFloat32Array([
		0.72, 0.72, 0.72, 0.0,
		0.82, 0.75, 0.72, 0.0,
		0.90, 0.83, 0.75, 0.0])
	var config := FluidConfig.new()
	config.default_particle_count = COUNT
	config.particle_counts = [COUNT]
	config.texture_width = 2
	config.grid_origin = Vector3.ZERO
	config.domain_origin = Vector3.ZERO
	config.cell_size_m = SPACING * 2.0
	config.grid_dims = Vector3i.ONE * 8
	config.domain_size_m = Vector3(config.grid_dims) * config.cell_size_m
	var cases: Array[Vector2] = [Vector2(400.0, 0.0), Vector2(0.0, 12.0)]
	var particle_mass_kg := 1000.0 * pow(SPACING, 3.0)
	for coefficients in cases:
		var solver: SphFluidSolver = Solver.new()
		solver.config = config.duplicate(true)
		solver.particle_count = COUNT
		solver.active_count = COUNT
		solver.spacing = SPACING
		solver.gravity = Vector3.ZERO
		solver.pressure_mult = coefficients.x
		solver.near_pressure_mult = coefficients.y
		solver.viscosity_strength = 0.0
		solver.cohesion_strength = 0.0
		solver.collision_inflation = 0.0
		solver.substeps = 1
		solver.foam_enabled = false
		solver.foam_tex_width = 2
		solver.set_seed_positions(seed)
		var obstacles: Array[Dictionary] = []
		solver.set_scene_obstacles(obstacles)
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "SPH pressure conservation: solver failed to initialize")
			continue
		RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
		await RenderingServer.frame_post_draw
		var result := {}
		RenderingServer.call_on_render_thread(_read_sph_pressure_conservation_render.bind(solver, result))
		await RenderingServer.frame_post_draw
		var error := float(result.get("momentum_error", INF))
		var time_s := float(result.get("physical_time_s", -1.0))
		print("BREAKER SPH PRESSURE CONSERVATION scenario=irregular_three_particle seed=0 positions_m=%s coefficients_main=%.1f coefficients_near=%.1f dt_requested_s=%.9f dt_sub_s=%.9f substeps=%d physical_time_s=%.9f particles=%d spacing_m=%.3f cell_size_m=%.3f grid=%s particle_mass_kg=%.6f total_mass_kg=%.6f volume_m3=%.9f sum_delta_v_m_s=%s sum_delta_speed_m_s=%.9f normalized_momentum_error=%.9f finite=%s memory_bytes=unavailable gpu_timing=unavailable" % [
			str([Vector3(0.72, 0.72, 0.72), Vector3(0.82, 0.75, 0.72), Vector3(0.90, 0.83, 0.75)]),
			coefficients.x, coefficients.y, DT, float(result.get("dt_sub_s", -1.0)),
			int(result.get("substeps", 0)), time_s, COUNT, SPACING,
			solver.cell_size, str(solver.grid_dims), particle_mass_kg,
			particle_mass_kg * COUNT, particle_mass_kg * COUNT / 1000.0,
			str(result.get("sum_delta_v_m_s", Vector3.INF)),
			float(result.get("sum_delta_speed_m_s", INF)), error,
			str(bool(result.get("finite", false)))])
		check.call(bool(result.get("finite", false)) and absf(time_s - DT) <= 1.0e-9
			and int(result.get("substeps", 0)) == 1
			and absf(float(result.get("dt_sub_s", -1.0)) - DT) <= 1.0e-9
			and float(result.get("sum_delta_speed_m_s", 0.0)) > 0.0001
			and error <= 1.0e-6,
			"SPH pressure conservation: isolated pressure pass changed total momentum")
		solver.profiling = false
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func _read_sph_pressure_conservation_render(solver: SphFluidSolver, result: Dictionary) -> void:
	const COUNT := 3
	var suffix := "a" if solver.current_parity() == 0 else "b"
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers["positions_" + suffix]).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers["velocities_" + suffix]).to_float32_array()
	var seen := PackedByteArray()
	seen.resize(COUNT)
	var sum_delta_v := Vector3.ZERO
	var sum_delta_speed := 0.0
	var finite := positions.size() >= COUNT * 4 and velocities.size() >= COUNT * 4
	for slot in COUNT:
		var offset := slot * 4
		var id := roundi(velocities[offset + 3])
		var position := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var velocity := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		if id < 0 or id >= COUNT or seen[id] != 0:
			finite = false
		else:
			seen[id] = 1
		finite = finite and position.is_finite() and velocity.is_finite()
		sum_delta_v += velocity
		sum_delta_speed += velocity.length()
	result.merge({"momentum_error": sum_delta_v.length() / maxf(sum_delta_speed, 1.0e-6),
		"sum_delta_v_m_s": sum_delta_v, "sum_delta_speed_m_s": sum_delta_speed,
		"finite": finite, "physical_time_s": solver._sim_time,
		"substeps": solver.last_substeps,
		"dt_sub_s": solver._sim_time / float(maxi(solver.last_substeps, 1))})


static func run_apic_surface_projection(tree: SceneTree, check: Callable) -> void:
	const DT := 1.0 / 60.0
	const DX := 0.25
	const SPACING := 0.125
	const HEIGHT := 1.04
	const DENSITY := 1000.0
	const GRAVITY := 9.81
	var config := FluidConfig.new()
	config.default_particle_count = 1
	config.particle_counts = [1]
	config.texture_width = 1
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3.ONE * 2.0
	var apic_script: Script = load("res://scripts/fluid/apic_fluid_solver.gd")
	var solver: ApicFluidSolver = apic_script.new()
	solver.config = config
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = SPACING
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.gravity = Vector3(0.0, -GRAVITY, 0.0)
	solver.material_density_kg_m3 = DENSITY
	solver.collision_inflation = 0.0
	solver.set_seed_positions(PackedFloat32Array([1.0, 1.0, 1.0, 0.0]))
	var initial_phi := PackedFloat32Array()
	initial_phi.resize(8 * 8 * 8)
	for z in 8:
		for y in 8:
			for x in 8:
				initial_phi[(z * 8 + y) * 8 + x] = (float(y) + 0.5) * DX - HEIGHT
	solver.set_seed_levelset(initial_phi)
	var obstacles: Array[Dictionary] = []
	solver.set_scene_obstacles(obstacles)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC surface projection: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_projection_render.bind(
		solver, result, DT, HEIGHT, DENSITY, GRAVITY))
	await RenderingServer.frame_post_draw
	var particle_mass_kg := DENSITY * pow(SPACING, 3.0)
	print("BREAKER APIC SURFACE PROJECTION scenario=manufactured_hydrostatic_plane surface=analytic_signed_distance free_surface_cut_cells=true domain_m=2.000 grid=%s dx_m=%.3f spacing_m=%.3f fluid_top_center_y_m=0.875 air_bottom_center_y_m=1.125 interface_height_m=%.3f theta_true=0.660 density_kg_m3=%.1f particle_mass_kg=%.6f gravity_y_m_s2=%.3f dt_s=%.9f particles=1 physical_time_s=0.000000 initial_div_max_s_inv=%.9f pressure_residual_max_s_inv=%.9f post_div_max_s_inv=%.9f post_fluid_face_speed_m_s=%.9f finite=%s memory=unavailable gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, SPACING, HEIGHT, DENSITY, particle_mass_kg, -GRAVITY, DT,
		float(result.get("initial_divergence", INF)), float(result.get("pressure_residual", INF)),
		float(result.get("post_divergence", INF)), float(result.get("post_face_speed", INF)),
		str(bool(result.get("finite", false)))])
	check.call(bool(result.get("finite", false))
		and float(result.get("pressure_residual", INF)) <= 1.0e-4
		and float(result.get("post_divergence", INF)) <= 1.0e-4
		and float(result.get("post_face_speed", INF)) <= 1.0e-5,
		"APIC surface projection: hydrostatic plane did not project to rest")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_surface_projection_render(solver: ApicFluidSolver, result: Dictionary,
		dt: float, surface_height: float, density: float, gravity: float) -> void:
	var dims: Vector3i = solver.grid_dims
	var face_dims := dims + Vector3i.ONE
	var cell_count := dims.x * dims.y * dims.z
	var face_count := face_dims.x * face_dims.y * face_dims.z
	var cell_types := PackedInt32Array()
	cell_types.resize(cell_count)
	cell_types.fill(0)
	var pressure := PackedFloat32Array()
	pressure.resize(cell_count)
	var phi := PackedFloat32Array()
	phi.resize(cell_count)
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var cell := (z * dims.y + y) * dims.x + x
				var center_y := (float(y) + 0.5) * solver.grid_dx
				phi[cell] = center_y - surface_height
				if center_y < surface_height:
					cell_types[cell] = 1
					pressure[cell] = density * gravity * (surface_height - center_y)
	solver._rd.buffer_update(solver._buffers.cell_types, 0, cell_types.to_byte_array().size(),
		cell_types.to_byte_array())
	solver._rd.buffer_update(solver._buffers.pressure, 0, pressure.to_byte_array().size(),
		pressure.to_byte_array())
	var phi_bytes := phi.to_byte_array()
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, phi_bytes.size(), phi_bytes)
	var pc := solver._pack_push_constant(dt, -1)
	var face_groups := ceili(float(face_count * 3) / 256.0)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "solid_faces", pc, face_groups, 1, 1)
	solver._rd.compute_list_end()
	var blocked: PackedByteArray = solver._rd.buffer_get_data(solver._buffers.solid_faces)
	var face_masses: Array[PackedFloat32Array] = []
	var face_velocities: Array[PackedFloat32Array] = []
	for component in 3:
		var masses := PackedFloat32Array()
		masses.resize(face_count)
		var velocities := PackedFloat32Array()
		velocities.resize(face_count)
		for index in face_count:
			var is_blocked := blocked.decode_u32((component * face_count + index) * 4) != 0
			if not is_blocked:
				masses[index] = 1.0
				var x := index % face_dims.x
				var y := (index / face_dims.x) % face_dims.y
				var z := index / (face_dims.x * face_dims.y)
				var right_cell := Vector3i(x, y, z)
				var left_cell := right_cell
				left_cell[component] -= 1
				var touches_fluid := _apic_surface_cell_is_fluid(left_cell, dims, cell_types) \
					or _apic_surface_cell_is_fluid(right_cell, dims, cell_types)
				if component == 1 and touches_fluid:
					velocities[index] = -gravity * dt
		face_masses.append(masses)
		face_velocities.append(velocities)
	for component in 3:
		var mass_bytes := face_masses[component].to_byte_array()
		var velocity_bytes := face_velocities[component].to_byte_array()
		var mass_key: String = ["face_mass_u", "face_mass_v", "face_mass_w"][component]
		var velocity_key: String = ["face_u", "face_v", "face_w"][component]
		solver._rd.buffer_update(solver._buffers[mass_key], 0, mass_bytes.size(), mass_bytes)
		solver._rd.buffer_update(solver._buffers[velocity_key], 0, velocity_bytes.size(), velocity_bytes)
	var cell_groups := ceili(float(cell_count) / 256.0)
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "divergence", pc, cell_groups, 1, 1)
	solver._rd.compute_list_end()
	var initial_divergence: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.divergence).to_float32_array()
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "residual", pc, cell_groups, 1, 1)
	solver._rd.compute_list_end()
	var residuals: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.residual).to_float32_array()
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "project", pc, face_groups, 1, 1)
	solver._dispatch(cl, "divergence", pc, cell_groups, 1, 1)
	solver._rd.compute_list_end()
	var post_divergence: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.divergence).to_float32_array()
	var max_initial_divergence := 0.0
	var max_pressure_residual := 0.0
	var max_post_divergence := 0.0
	var max_face_speed := 0.0
	var finite := true
	for index in cell_count:
		if cell_types[index] != 1:
			continue
		finite = finite and is_finite(initial_divergence[index]) \
			and is_finite(residuals[index]) and is_finite(post_divergence[index])
		max_initial_divergence = maxf(max_initial_divergence, absf(initial_divergence[index]))
		max_pressure_residual = maxf(max_pressure_residual, residuals[index])
		max_post_divergence = maxf(max_post_divergence, absf(post_divergence[index]))
	for component in 3:
		var key: String = ["face_u", "face_v", "face_w"][component]
		var values: PackedFloat32Array = solver._rd.buffer_get_data(
			solver._buffers[key]).to_float32_array()
		for index in face_count:
			var is_blocked := blocked.decode_u32((component * face_count + index) * 4) != 0
			if face_masses[component][index] <= 0.0 or is_blocked:
				continue
			var x := index % face_dims.x
			var y := (index / face_dims.x) % face_dims.y
			var z := index / (face_dims.x * face_dims.y)
			var right_cell := Vector3i(x, y, z)
			var left_cell := right_cell
			left_cell[component] -= 1
			var touches_fluid := _apic_surface_cell_is_fluid(left_cell, dims, cell_types) \
				or _apic_surface_cell_is_fluid(right_cell, dims, cell_types)
			if touches_fluid:
				finite = finite and is_finite(values[index])
				max_face_speed = maxf(max_face_speed, absf(values[index]))
	result.merge({"initial_divergence": max_initial_divergence,
		"pressure_residual": max_pressure_residual,
		"post_divergence": max_post_divergence,
		"post_face_speed": max_face_speed, "finite": finite})


static func _apic_surface_cell_is_fluid(cell: Vector3i, dims: Vector3i,
		cell_types: PackedInt32Array) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.z < 0 \
			or cell.x >= dims.x or cell.y >= dims.y or cell.z >= dims.z:
		return false
	return cell_types[(cell.z * dims.y + cell.y) * dims.x + cell.x] == 1


static func run_apic_surface_transport(tree: SceneTree, check: Callable) -> void:
	const DT := 1.0 / 60.0
	const DX := 0.25
	const SPACING := 0.125
	const VELOCITY := Vector3(0.8, 0.2, -0.4)
	var config := FluidConfig.new()
	config.default_particle_count = 1
	config.particle_counts = [1]
	config.texture_width = 1
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3.ONE * 2.0
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = SPACING
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(PackedFloat32Array([1.0, 1.0, 1.0, 0.0]))
	var dims := Vector3i.ONE * 8
	var initial_phi := PackedFloat32Array()
	initial_phi.resize(dims.x * dims.y * dims.z)
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var p := Vector3((float(x) + 0.5) * DX,
					(float(y) + 0.5) * DX, (float(z) + 0.5) * DX)
				initial_phi[(z * dims.y + y) * dims.x + x] = p.y + 0.3 * p.x - 0.2 * p.z - 0.8
	solver.set_seed_levelset(initial_phi)
	var obstacles: Array[Dictionary] = []
	solver.set_scene_obstacles(obstacles)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC surface transport: solver failed to initialize")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_transport_render.bind(
		solver, result, initial_phi, DT, VELOCITY))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE TRANSPORT scenario=affine_levelset uniform_velocity_m_s=(0.8,0.2,-0.4) domain_m=2.000 grid=%s dx_m=%.3f spacing_m=%.3f dt_s=%.9f physical_time_s=0.000000 state_revision_before=%d state_revision_after=%d initial_phi_max_error_m=%.9f translated_phi_max_error_m=%.9f finite=%s gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, SPACING, DT,
		int(result.get("revision_before", -1)), int(result.get("revision_after", -2)),
		float(result.get("initial_error", INF)), float(result.get("transport_error", INF)),
		str(bool(result.get("finite", false)))])
	check.call(bool(result.get("finite", false)) and float(result.get("initial_error", INF)) <= 1.0e-6
		and float(result.get("transport_error", INF)) <= 1.0e-5
		and int(result.get("revision_before", -1)) == 0
		and int(result.get("revision_after", -2)) == 0
		and is_equal_approx(float(result.get("physical_time_before_s", -1.0)), 0.0)
		and is_equal_approx(float(result.get("physical_time_s", -1.0)), 0.0),
		"APIC surface transport: RK2 level set did not translate the affine field without advancing state")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
	await _run_apic_surface_solid_independence(tree, check)
	await _run_apic_surface_sphere(tree, check)


static func _run_apic_surface_transport_render(solver: ApicFluidSolver, result: Dictionary,
		initial_phi: PackedFloat32Array, dt: float, velocity: Vector3) -> void:
	var dims: Vector3i = solver.grid_dims
	var face_dims := dims + Vector3i.ONE
	var face_count := face_dims.x * face_dims.y * face_dims.z
	var extension := PackedFloat32Array()
	extension.resize(face_count * 6)
	for component in 3:
		for face in face_count:
			var offset := component * face_count * 2 + face * 2
			extension[offset] = velocity[component]
	var extension_bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0,
		extension_bytes.size(), extension_bytes)
	var field_before: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var revision_before := solver._frame
	var time_before := solver._sim_time
	var cell_groups := ceili(float(dims.x * dims.y * dims.z) / 256.0)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, cell_groups)
	solver._rd.compute_list_end()
	var field_after: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var initial_error := 0.0
	for i in initial_phi.size():
		initial_error = maxf(initial_error, absf(field_before[i] - initial_phi[i]))
	var gradient := Vector3(0.3, 1.0, -0.2)
	var expected_shift := gradient.dot(velocity) * dt
	var max_error := 0.0
	var finite := field_after.size() == initial_phi.size()
	for value in field_after:
		finite = finite and is_finite(value)
	for z in range(1, dims.z - 1):
		for y in range(1, dims.y - 1):
			for x in range(1, dims.x - 1):
				var index := (z * dims.y + y) * dims.x + x
				var expected := initial_phi[index] - expected_shift
				finite = finite and is_finite(field_after[index])
				max_error = maxf(max_error, absf(field_after[index] - expected))
	result.merge({"initial_error": initial_error, "transport_error": max_error,
		"finite": finite, "revision_before": revision_before,
		"revision_after": solver._frame, "physical_time_before_s": time_before,
		"physical_time_s": solver._sim_time})


static func run_apic_velocity_support(tree: SceneTree, check: Callable) -> void:
	const DX := 0.25
	const DT := 1.0 / 60.0
	var config := FluidConfig.new()
	config.default_particle_count = 1
	config.particle_counts = [1]
	config.texture_width = 1
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3.ONE * 2.0
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = DX * 0.5
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.gravity = Vector3.ZERO
	solver.set_seed_positions(PackedFloat32Array([1.0, 0.5, 1.0, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(8 * 8 * 8)
	for z in 8:
		for y in 8:
			for x in 8:
				phi[(z * 8 + y) * 8 + x] = (float(y) + 0.5) * DX - 1.0
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC velocity support: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_velocity_support_render.bind(solver, result, DT))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC VELOCITY SUPPORT scenario=uniform_current_missing_p2g_support scope=before_forces_and_projection seed=0 grid=%s dx_m=%.6f dt_s=%.9f restored_hole_faces=%d expected_hole_faces=%d max_unsupported_error_m_s=%.9f supported_faces=%d max_supported_change_m_s=%.9f solid_faces=%d max_solid_speed_m_s=%.9f finite=%s physical_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, DT, int(result.get("restored_hole_faces", 0)),
		int(result.get("expected_hole_faces", 0)), float(result.get("unsupported_error", INF)),
		int(result.get("supported_faces", 0)), float(result.get("supported_change", INF)),
		int(result.get("solid_faces", 0)), float(result.get("solid_speed", INF)),
		str(bool(result.get("finite", false))), float(result.get("physical_time_s", -1.0)),
		int(result.get("state_revision", -1)), solver.get_gpu_memory_bytes()])
	check.call(bool(result.get("finite", false))
		and int(result.get("restored_hole_faces", 0)) == int(result.get("expected_hole_faces", -1))
		and float(result.get("unsupported_error", INF)) <= 1.0e-5
		and int(result.get("supported_faces", 0)) > 0
		and float(result.get("supported_change", INF)) <= 1.0e-5
		and int(result.get("solid_faces", 0)) > 0
		and float(result.get("solid_speed", INF)) <= 1.0e-7
		and is_equal_approx(float(result.get("physical_time_s", -1.0)), 0.0)
		and int(result.get("state_revision", -1)) == 0,
		"APIC velocity support: extension failed to fill missing P2G support without changing supported or solid faces")
	print("BREAKER APIC VELOCITY SUPPORT scheduling missing_faces=%d directly_repaired_faces=%d deep_missing_faces=%d repair_dispatch_groups=%d fully_supported_missing_faces=%d fully_supported_dispatch_groups=%d fully_supported_velocity_error_m_s=%.9f" % [
		int(result.get("missing_faces", -1)), int(result.get("directly_repaired_faces", -1)),
		int(result.get("deep_missing_faces", -1)), int(result.get("repair_dispatch_groups", -1)),
		int(result.get("fully_supported_missing_faces", -1)), int(result.get("fully_supported_dispatch_groups", -1)),
		float(result.get("fully_supported_velocity_error", INF))])
	check.call(int(result.get("missing_faces", -1)) == int(result.get("expected_hole_faces", -2))
		and int(result.get("directly_repaired_faces", -1)) == int(result.get("expected_hole_faces", -2))
		and int(result.get("deep_missing_faces", -1)) == 0
		and int(result.get("repair_dispatch_groups", -1)) == 0
		and int(result.get("fully_supported_missing_faces", -1)) == 0
		and int(result.get("fully_supported_dispatch_groups", -1)) == 0
		and float(result.get("fully_supported_velocity_error", INF)) <= 1.0e-5,
		"APIC velocity support: indirect extension did not skip fully supported faces or preserve their velocity")
	print("BREAKER APIC VELOCITY SUPPORT equivalence direct_max_error_m_s=%.9f deep_missing_faces=%d deep_dispatch_groups=%d deep_extension_passes=%d deep_max_error_m_s=%.9f" % [
		float(result.get("direct_reference_error", INF)), int(result.get("deep_fixture_missing_faces", -1)),
		int(result.get("deep_fixture_dispatch_groups", -1)), int(result.get("deep_fixture_extension_passes", -1)),
		float(result.get("deep_reference_error", INF))])
	check.call(float(result.get("direct_reference_error", INF)) <= 1.0e-7
		and int(result.get("deep_fixture_missing_faces", -1)) > 0
		and int(result.get("deep_fixture_dispatch_groups", 0)) > 0
		and int(result.get("deep_fixture_extension_passes", -1)) == 2
		and float(result.get("deep_reference_error", INF)) <= 1.0e-7,
		"APIC velocity support: local repair or deep-hole fallback changed fluid faces from six-pass extension")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_velocity_support_render(solver: ApicFluidSolver, result: Dictionary,
		dt: float) -> void:
	var dims: Vector3i = solver.grid_dims
	var face_dims := dims + Vector3i.ONE
	var face_count := face_dims.x * face_dims.y * face_dims.z
	var groups := ceili(float(face_count * 3) / 256.0)
	var pc := solver._pack_push_constant(dt, -1)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "solid_faces", pc, groups, 1, 1)
	solver._rd.compute_list_end()
	var blocked: PackedByteArray = solver._rd.buffer_get_data(solver._buffers.solid_faces)
	var velocities: Array[PackedFloat32Array] = []
	var masses: Array[PackedFloat32Array] = []
	for component in 3:
		var component_velocity := PackedFloat32Array()
		component_velocity.resize(face_count)
		var component_mass := PackedFloat32Array()
		component_mass.resize(face_count)
		for index in face_count:
			var offset := (component * face_count + index) * 4
			if blocked.decode_u32(offset) == 0:
				component_velocity[index] = 0.8 if component == 0 else 0.0
				component_mass[index] = 1.0
				var x := index % face_dims.x
				var y := (index / face_dims.x) % face_dims.y
				var z := index / (face_dims.x * face_dims.y)
				if component == 0 and x == 4 and y >= 1 and y <= 2 and z >= 1 and z <= 6:
					component_velocity[index] = 0.0
					component_mass[index] = 0.0
		velocities.append(component_velocity)
		masses.append(component_mass)
	for component in 3:
		var velocity_key: String = ["face_u", "face_v", "face_w"][component]
		var mass_key: String = ["face_mass_u", "face_mass_v", "face_mass_w"][component]
		solver._rd.buffer_update(solver._buffers[velocity_key], 0,
			face_count * 4, velocities[component].to_byte_array())
		solver._rd.buffer_update(solver._buffers[mass_key], 0,
			face_count * 4, masses[component].to_byte_array())
	var time_before := solver._sim_time
	var revision_before := solver._frame
	cl = solver._rd.compute_list_begin()
	solver._dispatch_velocity_extension_render(cl, dt, groups, true)
	solver._rd.compute_list_end()
	var restored := 0
	var expected := 0
	var unsupported_error := 0.0
	var supported := 0
	var supported_change := 0.0
	var solid_count := 0
	var solid_speed := 0.0
	var finite := true
	for component in 3:
		var velocity_key: String = ["face_u", "face_v", "face_w"][component]
		var after: PackedFloat32Array = solver._rd.buffer_get_data(
			solver._buffers[velocity_key]).to_float32_array()
		for index in face_count:
			var blocked_face := blocked.decode_u32((component * face_count + index) * 4) != 0
			var value := after[index]
			finite = finite and is_finite(value)
			if blocked_face:
				solid_count += 1
				solid_speed = maxf(solid_speed, absf(value))
			elif component == 0:
				var x := index % face_dims.x
				var y := (index / face_dims.x) % face_dims.y
				var z := index / (face_dims.x * face_dims.y)
				if x == 4 and y >= 1 and y <= 2 and z >= 1 and z <= 6:
					expected += 1
					if absf(value - 0.8) <= 1.0e-5:
						restored += 1
					unsupported_error = maxf(unsupported_error, absf(value - 0.8))
				elif x >= 2 and x <= 6 and y >= 1 and y <= 2 and z >= 1 and z <= 6:
					supported += 1
					supported_change = maxf(supported_change, absf(value - 0.8))
	result.merge({"restored_hole_faces": restored, "expected_hole_faces": expected,
		"unsupported_error": unsupported_error, "supported_faces": supported,
		"supported_change": supported_change, "solid_faces": solid_count,
		"solid_speed": solid_speed, "finite": finite,
		"physical_time_s": solver._sim_time, "state_revision": solver._frame,
		"physical_time_before_s": time_before, "state_revision_before": revision_before})
	var repair_control := solver._rd.buffer_get_data(solver._buffers.extension_control, 0, 32)
	for component in 3:
		var velocity_key: String = ["face_u", "face_v", "face_w"][component]
		var mass_key: String = ["face_mass_u", "face_mass_v", "face_mass_w"][component]
		for index in face_count:
			if blocked.decode_u32((component * face_count + index) * 4) == 0:
				velocities[component][index] = 0.8 if component == 0 else 0.0
				masses[component][index] = 1.0
		solver._rd.buffer_update(solver._buffers[velocity_key], 0, face_count * 4, velocities[component].to_byte_array())
		solver._rd.buffer_update(solver._buffers[mass_key], 0, face_count * 4, masses[component].to_byte_array())
	cl = solver._rd.compute_list_begin()
	solver._dispatch_velocity_extension_render(cl, dt, groups, true)
	solver._rd.compute_list_end()
	var supported_control := solver._rd.buffer_get_data(solver._buffers.extension_control, 0, 32)
	var fully_supported_error := 0.0
	for component in 3:
		var velocity_key: String = ["face_u", "face_v", "face_w"][component]
		var after := solver._rd.buffer_get_data(solver._buffers[velocity_key]).to_float32_array()
		for index in face_count:
			fully_supported_error = maxf(fully_supported_error, absf(after[index] - velocities[component][index]))
	result.merge({"missing_faces": repair_control.decode_u32(12),
		"repair_dispatch_groups": repair_control.decode_u32(0),
		"directly_repaired_faces": repair_control.decode_u32(20),
		"deep_missing_faces": repair_control.decode_u32(16),
		"fully_supported_missing_faces": supported_control.decode_u32(12),
		"fully_supported_dispatch_groups": supported_control.decode_u32(0),
		"fully_supported_velocity_error": fully_supported_error})
	for deep_holes in [false, true]:
		for component in 3:
			for index in face_count:
				var x := index % face_dims.x
				var y := (index / face_dims.x) % face_dims.y
				var z := index / (face_dims.x * face_dims.y)
				var blocked_face := blocked.decode_u32((component * face_count + index) * 4) != 0
				var hole := component == 0 and x >= (3 if deep_holes else 4) and x <= (5 if deep_holes else 4) \
					and y >= 1 and y <= 3 and z >= 3 and z <= 5
				velocities[component][index] = 0.0 if blocked_face or hole else 0.1 * float(component + 1) \
					+ 0.03 * float(x * x) - 0.07 * float(y) + 0.013 * float(z * z)
				masses[component][index] = 0.0 if blocked_face or hole else 1.0
			var velocity_key: String = ["face_u", "face_v", "face_w"][component]
			var mass_key: String = ["face_mass_u", "face_mass_v", "face_mass_w"][component]
			solver._rd.buffer_update(solver._buffers[velocity_key], 0, face_count * 4, velocities[component].to_byte_array())
			solver._rd.buffer_update(solver._buffers[mass_key], 0, face_count * 4, masses[component].to_byte_array())
		cl = solver._rd.compute_list_begin()
		solver._dispatch_velocity_extension_render(cl, dt, groups, true)
		solver._rd.compute_list_end()
		var fixture_control := solver._rd.buffer_get_data(solver._buffers.extension_control, 0, 48)
		var actual: Array[PackedFloat32Array] = []
		for component in 3:
			var velocity_key: String = ["face_u", "face_v", "face_w"][component]
			actual.append(solver._rd.buffer_get_data(solver._buffers[velocity_key]).to_float32_array())
			solver._rd.buffer_update(solver._buffers[velocity_key], 0, face_count * 4, velocities[component].to_byte_array())
		cl = solver._rd.compute_list_begin()
		solver._dispatch(cl, "extension_prepare", solver._pack_push_constant(dt, -1, 4), groups, 1, 1)
		for extension in 6:
			solver._dispatch(cl, "extension_expand", solver._pack_push_constant(dt, extension % 2), groups, 1, 1)
		solver._dispatch(cl, "extension_publish", pc, groups, 1, 1)
		solver._rd.compute_list_end()
		var reference_error := 0.0
		for component in 3:
			var velocity_key: String = ["face_u", "face_v", "face_w"][component]
			var reference := solver._rd.buffer_get_data(solver._buffers[velocity_key]).to_float32_array()
			for index in face_count:
				var y := (index / face_dims.x) % face_dims.y
				if blocked.decode_u32((component * face_count + index) * 4) == 0 and y < (5 if component == 1 else 4):
					reference_error = maxf(reference_error, absf(actual[component][index] - reference[index]))
		result["deep_reference_error" if deep_holes else "direct_reference_error"] = reference_error
		if deep_holes:
			result["deep_fixture_missing_faces"] = fixture_control.decode_u32(16)
			result["deep_fixture_dispatch_groups"] = fixture_control.decode_u32(0)
			result["deep_fixture_extension_passes"] = fixture_control.decode_u32(44)


static func _run_apic_surface_sphere(tree: SceneTree, check: Callable) -> void:
	const DX := 0.0625
	const DT := 1.0 / 60.0
	const RADIUS := 0.35
	const CENTER := Vector3(0.7, 1.0, 1.0)
	const VELOCITY := Vector3(0.6, 0.0, 0.0)
	var solver := ApicFluidSolver.new()
	solver.config.domain_origin = Vector3.ZERO
	solver.config.domain_size_m = Vector3.ONE * 2.0
	solver.config.texture_width = 1
	solver.config.default_particle_count = 1
	solver.config.particle_counts = [1]
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = DX * 0.5
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(PackedFloat32Array([CENTER.x, CENTER.y, CENTER.z, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(32 * 32 * 32)
	for z in 32:
		for y in 32:
			for x in 32:
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * DX
				phi[(z * 32 + y) * 32 + x] = p.distance_to(CENTER) - RADIUS
	solver.set_seed_levelset(phi)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC sphere transport: initialization failed")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_sphere_render.bind(
		solver, result, DT, CENTER, RADIUS, VELOCITY))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE TRANSPORT scenario=translated_sphere scope=levelset_only seed=0 dx_m=%.6f radius_m=%.3f uniform_velocity_m_s=%s requested_transport_time_s=0.500 applied_transport_time_s=0.500 physical_solver_time_s=%.6f initial_linear_volume_estimate_m3=%.9f final_linear_volume_estimate_m3=%.9f relative_volume_error=%.9f interface_phi_rms_error_m=%.9f finite=%s memory_bytes=%d gpu_timing=unavailable" % [
		DX, RADIUS, str(VELOCITY), solver._sim_time,
		float(result.get("initial_volume", INF)), float(result.get("final_volume", INF)),
		float(result.get("volume_error", INF)), float(result.get("interface_rms_error", INF)),
		str(bool(result.get("finite", false))), solver.get_gpu_memory_bytes()])
	check.call(bool(result.get("finite", false))
		and float(result.get("volume_error", INF)) <= 0.01,
		"APIC sphere transport: curved interface volume error exceeds 1%")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_surface_solid_independence(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	const DT := 1.0 / 60.0
	var solver := ApicFluidSolver.new()
	solver.config.domain_origin = Vector3.ZERO
	solver.config.domain_size_m = Vector3.ONE * 2.0
	solver.config.texture_width = 1
	solver.config.default_particle_count = 1
	solver.config.particle_counts = [1]
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = DX * 0.5
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(PackedFloat32Array([0.25, 0.75, 0.25, 0.0]))
	var obstacle_basis := Basis(Vector3.BACK, PI * 0.25)
	var obstacles: Array[Dictionary] = [{
		transform = Transform3D(obstacle_basis, Vector3.ONE),
		size = Vector3(3.0, 2.0 * DX, 2.0), retention = 1.0,
	}]
	solver.set_scene_obstacles(obstacles)
	var dims := Vector3i.ONE * 16
	var phi_a := PackedFloat32Array()
	phi_a.resize(dims.x * dims.y * dims.z)
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				phi_a[(z * dims.y + y) * dims.x + x] = (float(y) + 0.5) * DX - 1.0
	solver.set_seed_levelset(phi_a)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC surface solid independence: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_solid_independence_render.bind(
		solver, result, phi_a, DT, obstacle_basis.x * 0.8))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE TRANSPORT scenario=solid_phi_independence seed=0 grid=%s dx_m=%.6f wall_thickness_cells=2.000 dt_s=%.9f tangent_velocity_m_s=%s solid_cells=%d compared_outside_cells=%d max_outside_delta_m=%.9f finite=%s physical_time_s=%.6f gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, DT, str(obstacle_basis.x * 0.8),
		int(result.get("solid_cells", 0)), int(result.get("outside_cells", 0)),
		float(result.get("max_outside_delta", INF)), str(bool(result.get("finite", false))),
		solver._sim_time])
	check.call(bool(result.get("finite", false)) and int(result.get("solid_cells", 0)) > 0
		and int(result.get("outside_cells", 0)) > 0
		and float(result.get("max_outside_delta", INF)) <= 1.0e-6,
		"APIC surface transport: outside phi depends on arbitrary values inside a static solid")
	print("BREAKER APIC SURFACE TRANSPORT scenario=affine_phi_beside_oblique_solid scope=levelset_only dx_m=%.6f wall_thickness_cells=2.000 dt_s=%.9f tangent_velocity_m_s=%s compared_core_cells=%d max_affine_phi_error_m=%.9f reference=translated_horizontal_plane physical_solver_time_s=%.9f" % [
		DX, DT, str(obstacle_basis.x * 0.8), int(result.affine_cells), float(result.max_affine_error), solver._sim_time])
	check.call(int(result.affine_cells) > 0 and float(result.max_affine_error) <= 1.0e-6,
		"APIC surface transport: masked donors do not reproduce an affine interface beside a solid")
	var shear := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_shear_render.bind(solver, shear, phi_a, DT))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE TRANSPORT scenario=affine_shear_beside_oblique_solid scope=levelset_only seed=0 velocity_m_s=(y-x,y-x,0) velocity_gradient_squared=0 divergence_s_inv=0 wall_tangent=true manufactured_extension=true dx_m=%.6f dt_s=%.9f compared_core_cells=%d max_phi_error_m=%.9f reference=phi_initial-dt*(y-x) physical_solver_time_s=%.9f finite=%s" % [
		DX, DT, int(shear.cells), float(shear.error), solver._sim_time, str(shear.finite)])
	check.call(bool(shear.finite) and int(shear.cells) > 0 and float(shear.error) <= 1.0e-6,
		"APIC surface transport: cut-cell characteristic does not reproduce affine shear")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_surface_solid_independence_render(solver: ApicFluidSolver,
		result: Dictionary, phi_a: PackedFloat32Array, dt: float, velocity: Vector3) -> void:
	var types: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_types).to_int32_array()
	var phi_b := phi_a.duplicate()
	var solid_cells := 0
	for i in types.size():
		if types[i] == 2:
			phi_b[i] = -10.0 if phi_b[i] >= 0.0 else 10.0
			solid_cells += 1
	var extension := PackedFloat32Array()
	var face_count := (solver.grid_dims.x + 1) * (solver.grid_dims.y + 1) * (solver.grid_dims.z + 1)
	extension.resize(face_count * 6)
	for component in 3:
		for face in face_count:
			extension[(component * face_count + face) * 2] = velocity[component]
	var extension_bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0,
		extension_bytes.size(), extension_bytes)
	var groups := ceili(float(types.size()) / 256.0)
	var bytes_a := phi_a.to_byte_array()
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, bytes_a.size(), bytes_a)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var result_a: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var bytes_b := phi_b.to_byte_array()
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, bytes_b.size(), bytes_b)
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var result_b: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var max_delta := 0.0
	var outside_cells := 0
	var max_affine_error := 0.0
	var affine_cells := 0
	var finite := result_a.size() == types.size() and result_b.size() == types.size()
	for i in types.size():
		finite = finite and is_finite(result_a[i]) and is_finite(result_b[i])
		if types[i] != 2:
			outside_cells += 1
			max_delta = maxf(max_delta, absf(result_a[i] - result_b[i]))
			var x := i % solver.grid_dims.x
			var y := (i / solver.grid_dims.x) % solver.grid_dims.y
			var z := i / (solver.grid_dims.x * solver.grid_dims.y)
			if x >= 2 and y >= 2 and z >= 2 and x < solver.grid_dims.x - 2 and y < solver.grid_dims.y - 2 and z < solver.grid_dims.z - 2:
				affine_cells += 1
				max_affine_error = maxf(max_affine_error, absf(result_a[i] - (phi_a[i] - velocity.y * dt)))
	result.merge({"solid_cells": solid_cells, "outside_cells": outside_cells,
		"max_outside_delta": max_delta, "finite": finite,
		"affine_cells": affine_cells, "max_affine_error": max_affine_error})


static func _run_apic_surface_shear_render(solver: ApicFluidSolver, result: Dictionary,
		initial_phi: PackedFloat32Array, dt: float) -> void:
	var dims := solver.grid_dims
	var face_dims := dims + Vector3i.ONE
	var faces := face_dims.x * face_dims.y * face_dims.z
	var extension := PackedFloat32Array()
	extension.resize(faces * 6)
	for component in 3:
		var offset := Vector3.ONE * 0.5
		offset[component] = 0.0
		for face in faces:
			var coord := Vector3i(face % face_dims.x, (face / face_dims.x) % face_dims.y,
				face / (face_dims.x * face_dims.y))
			var p := solver.grid_origin + (Vector3(coord) + offset) * solver.grid_dx
			extension[(component * faces + face) * 2] = p.y - p.x if component < 2 else 0.0
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0,
		extension.size() * 4, extension.to_byte_array())
	solver._rd.buffer_update(solver._buffers.cell_phi, 0,
		initial_phi.size() * 4, initial_phi.to_byte_array())
	var cl := solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, ceili(float(initial_phi.size()) / 256.0))
	solver._rd.compute_list_end()
	var phi := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var types := solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	var error := 0.0
	var compared := 0
	var finite := true
	for z in range(2, dims.z - 2):
		for y in range(2, dims.y - 2):
			for x in range(2, dims.x - 2):
				var index := (z * dims.y + y) * dims.x + x
				if types[index] == 2:
					continue
				var p := solver.grid_origin + (Vector3(x, y, z) + Vector3.ONE * 0.5) * solver.grid_dx
				var expected := initial_phi[index] - dt * (p.y - p.x)
				finite = finite and is_finite(phi[index])
				error = maxf(error, absf(phi[index] - expected))
				compared += 1
	result.merge({"cells": compared, "error": error, "finite": finite})


static func _run_apic_surface_sphere_render(solver: ApicFluidSolver,
		result: Dictionary, dt: float, center: Vector3, radius: float, velocity: Vector3) -> void:
	var dims := solver.grid_dims
	var face_count := (dims.x + 1) * (dims.y + 1) * (dims.z + 1)
	var extension := PackedFloat32Array()
	extension.resize(face_count * 6)
	for component in 3:
		for face in face_count:
			extension[(component * face_count + face) * 2] = velocity[component]
	var bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0, bytes.size(), bytes)
	var initial: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var initial_volume := 0.0
	for value in initial:
		initial_volume += clampf(0.5 - value / solver.grid_dx, 0.0, 1.0) * pow(solver.grid_dx, 3.0)
	var cl := solver._rd.compute_list_begin()
	for step in 30:
		solver._dispatch_surface_transport_render(cl, dt, ceili(float(initial.size()) / 256.0))
	solver._rd.compute_list_end()
	var field: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var volume := 0.0
	var squared_error := 0.0
	var interface_cells := 0
	var finite := true
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var index := (z * dims.y + y) * dims.x + x
				var value := field[index]
				finite = finite and is_finite(value)
				volume += clampf(0.5 - value / solver.grid_dx, 0.0, 1.0) * pow(solver.grid_dx, 3.0)
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * solver.grid_dx
				var expected := p.distance_to(center + velocity * dt * 30.0) - radius
				if absf(expected) < solver.grid_dx:
					squared_error += pow(value - expected, 2.0)
					interface_cells += 1
	result.merge({"initial_volume": initial_volume, "final_volume": volume,
		"volume_error": absf(volume - initial_volume) / initial_volume,
		"interface_rms_error": sqrt(squared_error / maxi(interface_cells, 1)), "finite": finite})


static func run_apic_surface_strain(tree: SceneTree, check: Callable) -> void:
	const DT := 1.0 / 60.0
	const RADIUS := 0.35
	const CENTER := Vector3.ONE
	for dx_value in [0.0625, 0.03125]:
		var dx: float = dx_value
		var dims := Vector3i(roundi(2.0 / dx), roundi(2.0 / dx), roundi(2.0 / dx))
		var config := FluidConfig.new()
		config.default_particle_count = 1
		config.particle_counts = [1]
		config.texture_width = 1
		config.domain_origin = Vector3.ZERO
		config.domain_size_m = Vector3.ONE * 2.0
		var solver := ApicFluidSolver.new()
		solver.config = config
		solver.particle_count = 1
		solver.active_count = 1
		solver.spacing = dx * 0.5
		solver.grid_cell_size_m = dx
		solver.free_surface_cut_cells = true
		solver.gravity = Vector3.ZERO
		solver.set_seed_positions(PackedFloat32Array([CENTER.x, CENTER.y, CENTER.z, 0.0]))
		var phi := PackedFloat32Array()
		phi.resize(dims.x * dims.y * dims.z)
		for z in dims.z:
			for y in dims.y:
				for x in dims.x:
					var p: Vector3 = (Vector3(x, y, z) + Vector3.ONE * 0.5) * dx
					phi[(z * dims.y + y) * dims.x + x] = p.distance_to(CENTER) - RADIUS
		solver.set_seed_levelset(phi)
		solver.set_scene_obstacles([])
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "APIC strain transport: solver failed to initialize at dx=%.5f" % dx)
			continue
		var result := {}
		RenderingServer.call_on_render_thread(_run_apic_surface_strain_render.bind(
			solver, result, DT, CENTER, RADIUS))
		await RenderingServer.frame_post_draw
		print("BREAKER APIC SURFACE STRAIN scenario=sheared_sphere scope=levelset_only seed=0 grid=%s dx_m=%.6f spacing_m=%.6f shear_rate_s_inv=0.700000 dt_s=%.9f steps=60 requested_transport_time_s=1.000000 applied_transport_time_s=1.000000 initial_planar_volume_m3=%.9f exact_final_planar_volume_m3=%.9f transported_planar_volume_m3=%.9f planar_volume_error_vs_exact=%.9f exact_estimator_bias_vs_initial=%.9f interface_phi_rms_error_m=%.9f finite=%s boundary_flux_m3_s=0.000 physical_solver_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable volume_conservation_verified=false" % [
			str(dims), dx, dx * 0.5, DT,
			float(result.get("initial_volume", INF)), float(result.get("exact_final_volume", INF)),
			float(result.get("transported_volume", INF)), float(result.get("volume_error_vs_exact", INF)),
			float(result.get("estimator_bias_vs_initial", INF)),
			float(result.get("interface_rms_error", INF)), str(bool(result.get("finite", false))),
			float(result.get("physical_time_s", -1.0)), int(result.get("state_revision", -1)),
			solver.get_gpu_memory_bytes()])
		check.call(bool(result.get("finite", false))
			and float(result.get("volume_error_vs_exact", INF)) <= 0.01
			and float(result.get("interface_rms_error", INF)) <= 0.1 * dx
			and is_equal_approx(float(result.get("physical_time_s", -1.0)), 0.0)
			and int(result.get("state_revision", -1)) == 0,
			"APIC strain transport: advection differs from the exact divergence-free affine flow at dx=%.5f" % dx)
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func run_apic_geometric_flux_cache(tree: SceneTree, check: Callable) -> void:
	var solver: ApicFluidSolver = build_apic_solver(0.12, 0, 0.0, true, false, 1, true, true, 1, 64, true)
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC geometric flux cache: initialization failed")
		return
	RenderingServer.call_on_render_thread(_set_seed_velocities.bind(solver, solver._seed_data))
	await RenderingServer.frame_post_draw
	RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
	await RenderingServer.frame_post_draw
	var result := {}
	RenderingServer.call_on_render_thread(_compare_apic_geometric_flux_cache_render.bind(solver, result))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC GEOMETRIC CACHE scenario=solitary_slope_rock_projected_flux seed=0 scope=amount_transport_only imposed_transport_dt_s=0.250 source_physical_time_s=%.9f state_revision=%d dx_m=%.6f spacing_m=%.6f particles=%d max_cell_amount_difference=%.12f tolerance=0.0000001 transport_substeps=%d cached_valid=%s reference_valid=%s transport_time_difference_s=%.12f source_memory_bytes=%d gpu_timing=unavailable" % [
		solver._sim_time, solver._frame, solver.grid_dx, solver.spacing, solver.live_count(), float(result.max_error), int(result.substeps), str(bool(result.cached_valid)), str(bool(result.reference_valid)), float(result.clock_error), solver.get_gpu_memory_bytes()])
	check.call(bool(result.cached_valid) and bool(result.reference_valid)
		and int(result.substeps) > 1 and float(result.max_error) <= 1.0e-7
		and float(result.clock_error) <= 1.0e-7,
		"APIC geometric flux cache: subcycled amount differs from the uncached reference")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _compare_apic_geometric_flux_cache_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	var source := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var cells := solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z
	var groups := ceili(float(cells) / 256.0)
	solver.amount_geometric_flux_cache = false
	var cl := solver._rd.compute_list_begin()
	solver._dispatch_surface_amount_render(cl, 0.25, groups)
	solver._rd.compute_list_end()
	var reference := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	solver._rd.buffer_update(solver._buffers.surface_amount, 0, source.size(), source)
	solver.amount_geometric_flux_cache = true
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_amount_render(cl, 0.25, groups)
	solver._rd.compute_list_end()
	var cached := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var max_error := 0.0
	for cell in cells:
		var offset := ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES
		max_error = maxf(max_error, absf(reference.decode_float(offset) - cached.decode_float(offset)))
	result.merge({"max_error": max_error, "substeps": cached.decode_u32(20),
		"cached_valid": cached.decode_u32(28) != 0, "reference_valid": reference.decode_u32(28) != 0,
		"clock_error": absf(cached.decode_float(32) - reference.decode_float(32))})


static func run_apic_linear_wave(tree: SceneTree, check: Callable, conservative_surface: bool = true,
		geometric_full_cells: bool = false, pressure_volume_planes: bool = false, requested_substeps: int = 3,
		flip_velocity_fraction: float = 0.0, geometric_split: bool = false) -> void:
	const LENGTH := 8.0
	const WATER_DEPTH := 2.0
	const AMPLITUDE := 0.03
	const DX := 0.25
	const SPACING := 0.125
	const DIMS := Vector3i(32, 14, 3)
	var k := PI / LENGTH
	var omega := sqrt(G * k * tanh(k * WATER_DEPTH))
	var period := TAU / omega
	var config := FluidConfig.new()
	config.domain_origin = Vector3(0.0, -WATER_DEPTH, -0.375)
	config.domain_size_m = Vector3(LENGTH, 3.5, 0.75)
	var seed := PackedFloat32Array()
	for z in 6:
		for y in 16:
			for x in 64:
				var p := config.domain_origin + (Vector3(x, y, z) + Vector3.ONE * 0.5) * SPACING
				seed.append_array([p.x, p.y, p.z, 0.0])
	var count := seed.size() / 4
	config.default_particle_count = count
	config.particle_counts = [count]
	config.texture_width = ceili(sqrt(float(count)))
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = count
	solver.active_count = count
	solver.spacing = SPACING
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.conservative_amount_tracking = true
	solver.conservative_surface_reconstruction = conservative_surface
	solver.amount_transport_order = 1 if geometric_full_cells else 2
	solver.amount_geometric_full_cell_flux = geometric_full_cells
	solver.amount_geometric_split_transport = geometric_split
	solver.pressure_surface_from_volume_planes = pressure_volume_planes
	solver.flip_velocity_fraction = flip_velocity_fraction
	solver.substeps = requested_substeps
	solver.profiling = true
	solver.set_seed_positions(seed)
	var phi := PackedFloat32Array()
	phi.resize(DIMS.x * DIMS.y * DIMS.z)
	for z in DIMS.z:
		for y in DIMS.y:
			for x in DIMS.x:
				var p := config.domain_origin + (Vector3(x, y, z) + Vector3.ONE * 0.5) * DX
				phi[(z * DIMS.y + y) * DIMS.x + x] = p.y - AMPLITUDE * cos(k * p.x)
	solver.set_seed_levelset(phi)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC linear wave: solver failed to initialize")
		return
	var samples: Array[Dictionary] = []
	var initial := {}
	RenderingServer.call_on_render_thread(_read_apic_linear_wave_render.bind(solver, initial, k, WATER_DEPTH))
	await RenderingServer.frame_post_draw
	samples.append(initial)
	var ticks := ceili(2.25 * period * 60.0)
	var gpu_samples := PackedFloat64Array()
	for tick in ticks:
		RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
		await RenderingServer.frame_post_draw
		var gpu_ms := float(solver.get_timings().get("total", -1.0))
		if tick >= 60 and gpu_ms >= 0.0:
			gpu_samples.append(gpu_ms)
		if (tick + 1) % 6 == 0 or tick + 1 == ticks:
			var sample := {}
			RenderingServer.call_on_render_thread(_read_apic_linear_wave_render.bind(solver, sample, k, WATER_DEPTH))
			await RenderingServer.frame_post_draw
			samples.append(sample)
			if tick == 5:
				print("BREAKER APIC LINEAR WAVE INTERFACE columns=%s geometric_split=%s" % [str(sample.interface_columns), str(geometric_split)])
			print("BREAKER APIC LINEAR WAVE SAMPLE time_s=%.9f expected_amplitude_m=%.9f phi_amplitude_m=%.9f amount_amplitude_m=%.9f relative_amount_drift=%.12f max_divergence_s_inv=%.9f finite=%s pressure_finite=%s transport_valid=%s transport_failed_steps=%d transport_time_s=%.9f concentration_min=%.12f concentration_max=%.12f distance_converged=%s" % [
				solver._sim_time, AMPLITUDE * cos(omega * solver._sim_time), float(sample.phi_amplitude_m),
				float(sample.amount_amplitude_m), float(sample.amount.relative_amount_drift),
				float(sample.projection.divergence_max_s_inv), str(bool(sample.finite)), str(bool(sample.projection.finite)),
				str(bool(sample.amount.transport_valid)), int(sample.amount.failed_steps), float(sample.amount.transport_time_s),
				float(sample.amount.concentration_min), float(sample.amount.concentration_max), str(bool(sample.amount.interface_distance_converged))])
			check.call(bool(sample.finite) and bool(sample.amount.transport_valid)
				and bool(sample.projection.finite)
				and (not conservative_surface or bool(sample.amount.interface_distance_converged))
				and float(sample.amount.relative_amount_drift) <= 0.01
				and absf(float(sample.amount.transport_time_s) - solver._sim_time) <= 1.0e-5
				and float(sample.projection.divergence_max_s_inv) <= solver.pressure_tolerance_s_inv,
				"APIC linear wave: finite state, volume, pressure, distance or physical time failed")
	for field: String in ["phi_amplitude_m", "amount_amplitude_m"]:
		print("BREAKER APIC LINEAR WAVE TRANSFER field=%s flip_velocity_fraction_requested=%.6f flip_velocity_fraction_applied=%.6f supported_particle_advection=projected_grid_velocity pre_force_texture_size=%d image_channels=rgba32f storage_buffer_count=32 push_constant_bytes=%d" % [
			field, flip_velocity_fraction, solver.flip_velocity_fraction, solver._pre_force_velocity_tex_size, solver._pack_push_constant(0.0, -1).size()])
		var zero_crossings := PackedFloat64Array()
		var peak_error := 0.0
		var peaks := 0
		for index in range(1, samples.size()):
			var previous := float(samples[index - 1][field])
			var current := float(samples[index][field])
			if (previous > 0.0 and current <= 0.0) or (previous < 0.0 and current >= 0.0):
				var t0 := float(samples[index - 1].time_s)
				var t1 := float(samples[index].time_s)
				zero_crossings.append(lerpf(t0, t1, previous / (previous - current)))
			if (index + 1 < samples.size() and absf(current) >= absf(previous)
					and absf(current) > absf(float(samples[index + 1][field])) and absf(current) > 0.25 * AMPLITUDE):
				peaks += 1
				peak_error = maxf(peak_error, absf(absf(current) / AMPLITUDE - 1.0))
		var measured_period := 2.0 * (zero_crossings[-1] - zero_crossings[0]) / float(zero_crossings.size() - 1) if zero_crossings.size() >= 3 else INF
		var phase_error := absf(period / measured_period - 1.0)
		var initial_error := absf(float(initial[field]) / AMPLITUDE - 1.0)
		print("BREAKER APIC LINEAR WAVE scenario=closed_standing_airy_wave seed=0 field=%s surface_controls_pressure=%s amount_transport_order=%d geometric_full_cell_flux=%s pressure_volume_planes=%s pressure_connection_fraction=%.9f pressure_connection_tolerance_m=%.9f pressure_plane_fallback_evaluations=unavailable amplitude_requested_m=0.030 amplitude_initial_m=%.9f depth_m=2.000 length_m=8.000 wavelength_m=16.000 kh=%.9f omega_reference_s_inv=%.9f period_reference_s=%.9f period_measured_s=%s initial_amplitude_error=%.9f peak_amplitude_error=%.9f phase_speed_error=%.9f peaks=%d zero_crossings=%d dx_requested_m=0.250 dx_applied_m=%.3f spacing_requested_m=0.125 spacing_applied_m=%.3f substeps=%d dt_s=0.016666667 physical_time_s=%.9f requested_time_s=%.9f boundary=closed initial_velocity_m_s=(0,0,0) reference=linear_inviscid_finite_depth dispersion=omega_squared_g_k_tanh_kh memory_bytes=%d render=unavailable" % [
			field, str(conservative_surface), solver.amount_transport_order, str(geometric_full_cells), str(pressure_volume_planes), solver.pressure_plane_connection_fraction, solver.grid_dx * solver.pressure_plane_connection_fraction,
			float(initial[field]), k * WATER_DEPTH, omega, period,
			str(measured_period) if is_finite(measured_period) else "unavailable", initial_error,
			peak_error, phase_error, peaks, zero_crossings.size(), solver.grid_dx, solver.spacing,
			solver.substeps, solver._sim_time, float(ticks) / 60.0, solver.get_gpu_memory_bytes()])
		check.call(initial_error <= 0.01 and peaks >= 4 and zero_crossings.size() >= 4
			and peak_error <= 0.05 and phase_error <= 0.05,
			"APIC linear wave: amplitude or phase differs from the finite-depth reference by more than 5%")
	gpu_samples.sort()
	print("BREAKER APIC LINEAR WAVE COST particles=%d grid=%s physical_time_s=%.9f gpu_p95_ms=%s samples=%d" % [
		count, str(solver.grid_dims), solver._sim_time, str(gpu_samples[ceili(float(gpu_samples.size()) * 0.95) - 1]) if not gpu_samples.is_empty() else "unavailable", gpu_samples.size()])
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _read_apic_linear_wave_render(solver: ApicFluidSolver, result: Dictionary,
		k: float, water_depth: float) -> void:
	var state := solver.read_liquid_amount_state_render()
	var amount: PackedFloat32Array = state.liquid_amount_per_full_cell
	var phi := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var dims := solver.grid_dims
	var phi_amplitude := 0.0
	var amount_amplitude := 0.0
	var crossings := 0
	var interface_columns: Array[Dictionary] = []
	for z in dims.z:
		for x in dims.x:
			var weight := cos(k * (solver.grid_origin.x + (float(x) + 0.5) * solver.grid_dx))
			var height := -water_depth
			for y in dims.y:
				var cell := (z * dims.y + y) * dims.x + x
				if z == dims.z / 2 and x in [0, dims.x - 1] and y in range(6, 10):
					interface_columns.append({"cell": Vector3i(x, y, z), "amount": amount[cell], "phi_m": phi[cell]})
				height += amount[cell] * solver.grid_dx
				if y + 1 < dims.y and phi[cell] < 0.0 and phi[cell + dims.x] >= 0.0:
					var surface := solver.grid_origin.y + (float(y) + 0.5) * solver.grid_dx
					surface += solver.grid_dx * (-phi[cell]) / (phi[cell + dims.x] - phi[cell])
					phi_amplitude += surface * weight
					crossings += 1
			amount_amplitude += height * weight
	var factor := 2.0 / float(dims.x * dims.z)
	result.merge({"time_s": solver._sim_time, "phi_amplitude_m": phi_amplitude * factor,
		"amount_amplitude_m": amount_amplitude * factor,
		"interface_columns": interface_columns,
		"finite": crossings == dims.x * dims.z and is_finite(phi_amplitude) and is_finite(amount_amplitude),
		"amount": solver.get_liquid_amount_diagnostics_render(), "projection": solver.get_diagnostics()})


static func run_apic_cube_fraction(tree: SceneTree, check: Callable) -> void:
	const CELLS := 4096
	var config := FluidConfig.new()
	config.default_particle_count = 1
	config.particle_counts = [1]
	config.texture_width = 1
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3(2.0, 2.0, 2.0)
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = 0.0625
	solver.grid_cell_size_m = 0.125
	solver.free_surface_cut_cells = true
	solver.conservative_amount_tracking = true
	solver.gravity = Vector3.ZERO
	solver.set_seed_positions(PackedFloat32Array([1.0, 1.0, 1.0, 0.0]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 314159
	var gradients: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	var phi := PackedFloat32Array()
	phi.resize(CELLS)
	for axis in 3:
		gradients[axis].resize(CELLS)
	for cell in CELLS:
		var gradient := Vector3.ZERO
		for axis in 3:
			gradient[axis] = pow(10.0, rng.randf_range(-8.0, 4.0)) * (-1.0 if rng.randf() < 0.5 else 1.0)
		if cell % 16 == 0:
			gradient = Vector3.UP
		elif cell % 16 == 1:
			gradient.z = 0.0
		elif cell % 16 == 2:
			gradient = Vector3.ZERO
		for axis in 3:
			gradients[axis][cell] = gradient[axis]
		var spans := [absf(gradient.x) * 0.125, absf(gradient.y) * 0.125, absf(gradient.z) * 0.125]
		spans.sort()
		var half_span: float = 0.5 * (spans[0] + spans[1] + spans[2])
		phi[cell] = rng.randf_range(-1.1, 1.1) * half_span
		if cell % 16 in [3, 4, 5]:
			phi[cell] = half_span - float(spans[cell % 16 - 3])
		elif cell % 16 in [6, 7]:
			phi[cell] = (1.0e-7 if cell % 16 == 6 else -1.0e-7) * half_span
		elif cell % 16 in [8, 9]:
			phi[cell] = (1.0 - 1.0e-7 if cell % 16 == 8 else -1.0 + 1.0e-7) * half_span
		elif cell % 16 == 2:
			phi[cell] = 0.01 if cell % 32 == 2 else -0.01
	solver.set_seed_levelset(phi)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC cube fraction: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_cube_fraction_render.bind(solver, gradients, phi, result))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC CUBE FRACTION scenario=signed_planes_axes_log_spans_breakpoints seed=314159 cells=%d dx_m=0.125 gradient_component_range=(1e-8,1e4) reference=six_tetrahedra candidate=normalized_rectangle_cdf max_fraction_error=%.12f tolerance=0.000001 finite=%s worst_cell=%s physical_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable" % [
		CELLS, float(result.max_error), str(bool(result.finite)), str(result.worst), solver._sim_time, solver._frame, solver.get_gpu_memory_bytes()])
	check.call(bool(result.finite) and float(result.max_error) <= 1.0e-6,
		"APIC cube fraction: analytic candidate differs from the tetrahedral reference")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_cube_fraction_render(solver: ApicFluidSolver,
		gradients: Array[PackedFloat32Array], phi: PackedFloat32Array, result: Dictionary) -> void:
	var names := ["cell_phi_next", "cell_phi_corrected", "residual"]
	for axis in 3:
		var bytes := gradients[axis].to_byte_array()
		solver._rd.buffer_update(solver._buffers[names[axis]], 0, bytes.size(), bytes)
	var groups := ceili(float(phi.size()) / 256.0)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 28), groups, 1, 1)
	solver._rd.compute_list_end()
	var reference := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 29), groups, 1, 1)
	solver._rd.compute_list_end()
	var candidate := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var max_error := 0.0
	var finite := true
	var worst := {}
	for cell in phi.size():
		var offset := ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES + 4
		var expected := reference.decode_float(offset)
		var actual := candidate.decode_float(offset)
		finite = finite and is_finite(expected) and is_finite(actual) and actual >= 0.0 and actual <= 1.0
		var error := absf(expected - actual)
		if error > max_error:
			max_error = error
			worst = {"index": cell, "phi": phi[cell], "gradient": Vector3(gradients[0][cell], gradients[1][cell], gradients[2][cell]),
				"reference": expected, "candidate": actual}
	result.merge({"max_error": max_error, "finite": finite, "worst": worst})


static func run_apic_amount_transport(tree: SceneTree, check: Callable, amount_transport_order: int = 1) -> void:
	const DX := 0.125
	const DIMS := Vector3i(16, 12, 16)
	const FLOOR := 0.45
	for scenario: String in ["uniform_cut_cell_current", "closed_vortex_tracer",
			"accepted_cfl_subcycling", "cfl_budget_rejection", "dry_face_free_surface"]:
		var config := FluidConfig.new()
		config.default_particle_count = 1
		config.particle_counts = [1]
		config.texture_width = 1
		config.domain_origin = Vector3.ZERO
		config.domain_size_m = Vector3(2.0, 1.5, 2.0)
		var solver := ApicFluidSolver.new()
		solver.config = config
		solver.particle_count = 1
		solver.active_count = 1
		solver.spacing = DX * 0.5
		solver.grid_cell_size_m = DX
		solver.free_surface_cut_cells = true
		solver.conservative_amount_tracking = true
		solver.amount_transport_order = amount_transport_order
		solver.conservative_surface_reconstruction = scenario == "dry_face_free_surface"
		solver.gravity = Vector3.ZERO
		solver.set_seed_positions(PackedFloat32Array([1.0, 1.0, 1.0, 0.0]))
		solver.set_scene_obstacles([{
			"transform": Transform3D(Basis.IDENTITY, Vector3(1.0, FLOOR - 1.0, 1.0)),
			"size": Vector3(4.0, 2.0, 4.0),
		}])
		var phi := PackedFloat32Array()
		var amount := PackedFloat32Array()
		phi.resize(DIMS.x * DIMS.y * DIMS.z)
		amount.resize(phi.size())
		for z in DIMS.z:
			for y in DIMS.y:
				for x in DIMS.x:
					var cell := Vector3(x, y, z)
					var center := (cell + Vector3.ONE * 0.5) * DX
					var index := (z * DIMS.y + y) * DIMS.x + x
					phi[index] = center.y - (0.48 if scenario == "dry_face_free_surface" else 1.0)
					var open_height := maxf(0.0, (float(y) + 1.0) * DX - maxf(float(y) * DX, FLOOR))
					var fraction := open_height / DX
					if scenario == "uniform_cut_cell_current":
						amount[index] = fraction * 0.3
					elif scenario == "dry_face_free_surface":
						amount[index] = maxf(0.0, minf((float(y) + 1.0) * DX, 0.48) - maxf(float(y) * DX, FLOOR)) / DX
					else:
						var width := maxf(0.0, minf((float(x) + 1.0) * DX, 1.0) - maxf(float(x) * DX, 0.5))
						var depth := maxf(0.0, minf((float(z) + 1.0) * DX, 1.25) - maxf(float(z) * DX, 0.75))
						amount[index] = fraction * width * depth / (DX * DX)
		solver.set_seed_levelset(phi)
		solver.set_seed_liquid_amount(amount)
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "APIC amount transport: initialization failed")
			continue
		var result := {}
		RenderingServer.call_on_render_thread(_run_apic_amount_transport_render.bind(
			solver, result, scenario, amount))
		await RenderingServer.frame_post_draw
		print("BREAKER APIC AMOUNT scenario=%s scope=isolated_amount_transport seed=0 domain_m=(2,1.5,2) dx_m=0.125 spacing_m=0.0625 floor_top_y_m=0.450 imposed_speed_m_s=%.9f dt_s=%.9f steps=%d transport_time_s=%.9f expected_transport_time_s=%.9f initial_amount_volume_m3=%.9f final_amount_volume_m3=%.9f relative_amount_error=%.12f concentration_min=%.9f concentration_max=%.9f uniform_error=%.12f distribution_change_l1_m3=%.9f solid_amount_m3=%.12f max_outflow_rate_s_inv=%.9f requested_substeps=%d completed_substeps=%d failed_steps=%d finite=%s transport_valid=%s physical_solver_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable geometric_volume_conservation=unavailable interface_controls_pressure=%s pressure_only_dry_faces_transport=true amount_transport_order=%d" % [
			scenario, float(result.speed), float(result.dt), int(result.steps),
			float(result.transport_time_s), float(result.expected_time),
			float(result.initial_volume), float(result.final_volume), float(result.relative_error),
			float(result.minimum), float(result.maximum), float(result.uniform_error),
			float(result.distribution_change), float(result.solid_volume), float(result.max_outflow_rate_s_inv),
			int(result.requested_substeps), int(result.completed_substeps), int(result.failed_steps),
			str(bool(result.finite)), str(bool(result.transport_valid)),
			solver._sim_time, solver._frame, solver.get_gpu_memory_bytes(), str(solver.conservative_surface_reconstruction), solver.amount_transport_order])
		check.call(bool(result.finite) and float(result.relative_error) <= 0.01
			and absf(float(result.solid_volume)) <= 1.0e-9
			and float(result.minimum) >= -1.0e-6 and float(result.maximum) <= 1.000001,
			"APIC amount transport: amount conservation, positivity, or solid exclusion failed")
		if scenario == "uniform_cut_cell_current":
			check.call(float(result.uniform_error) <= 1.0e-6,
				"APIC amount transport: constant concentration changed in cut cells")
		if scenario == "cfl_budget_rejection":
			check.call(int(result.failed_steps) == 1 and int(result.completed_substeps) == 0
				and float(result.transport_time_s) == 0.0 and float(result.distribution_change) == 0.0,
				"APIC amount transport: over-budget tick was silently changed or advanced")
		else:
			check.call(bool(result.transport_valid) and int(result.failed_steps) == 0
				and absf(float(result.transport_time_s) - float(result.expected_time)) <= 1.0e-5,
				"APIC amount transport: physical advection time differs from the requested time")
		if scenario == "accepted_cfl_subcycling":
			check.call(int(result.requested_substeps) > 1
				and int(result.completed_substeps) == int(result.requested_substeps),
				"APIC amount transport: CFL subcycling did not execute all requested internal steps")
		if scenario == "closed_vortex_tracer":
			check.call(float(result.distribution_change) > 0.01,
				"APIC amount transport: dry pressure flags blocked the transported tracer")
		if scenario == "dry_face_free_surface":
			print("BREAKER APIC AMOUNT DRY FACE water_level_m=0.480 face_y_m=0.500 imposed_vertical_speed_m_s=%.9f swept_depth_m=%.12f dry_amount_volume_m3=%.12f" % [
				float(result.speed), float(result.speed) * float(result.dt), float(result.dry_volume)])
			check.call(float(result.dry_volume) <= 1.0e-12,
				"APIC amount transport: liquid crossed a geometrically dry swept face")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func _run_apic_amount_transport_render(solver: ApicFluidSolver, result: Dictionary,
		scenario: String, initial: PackedFloat32Array) -> void:
	var dims := solver.grid_dims
	var cells := initial.size()
	var groups := ceili(float(cells) / 256.0)
	var face_dims := dims + Vector3i.ONE
	var faces := face_dims.x * face_dims.y * face_dims.z
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "solid_faces", solver._pack_push_constant(0.0, -1),
		ceili(float(faces * 3) / 256.0), 1, 1)
	solver._rd.compute_list_end()
	var flags: PackedInt32Array = solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	for i in flags.size():
		flags[i] |= 2
	var flag_bytes := flags.to_byte_array()
	solver._rd.buffer_update(solver._buffers.solid_faces, 0, flag_bytes.size(), flag_bytes)
	var speed := 100.0 if scenario == "cfl_budget_rejection" else (10.0 if scenario == "accepted_cfl_subcycling" else 0.8)
	if scenario == "dry_face_free_surface":
		speed = 0.0001
	var dt := 0.5 if scenario == "cfl_budget_rejection" else (1.0 / 30.0 if scenario == "accepted_cfl_subcycling" else 1.0 / 60.0)
	var steps := 1 if scenario == "cfl_budget_rejection" else (30 if scenario == "accepted_cfl_subcycling" else 60)
	if scenario == "dry_face_free_surface":
		steps = 1
	var offsets: Array[Vector3] = [Vector3(0.0, 0.5, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, 0.5, 0.0)]
	var extension := PackedFloat32Array()
	extension.resize(faces * 6)
	for axis in 3:
		for face in faces:
			var cell := Vector3(face % face_dims.x, (face / face_dims.x) % face_dims.y,
				face / (face_dims.x * face_dims.y))
			var p := (cell + offsets[axis]) * solver.grid_dx
			var velocity := 0.0
			if axis == 0:
				velocity = speed * sin(PI * p.x / 2.0) * cos(PI * p.z / 2.0)
			elif axis == 2:
				velocity = -speed * cos(PI * p.x / 2.0) * sin(PI * p.z / 2.0)
			if scenario == "dry_face_free_surface":
				velocity = speed if axis == 1 else 0.0
			extension[(axis * faces + face) * 2] = velocity
	var extension_bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0, extension_bytes.size(), extension_bytes)
	cl = solver._rd.compute_list_begin()
	for step in steps:
		solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var state := solver.read_liquid_amount_state_render()
	var amounts: PackedFloat32Array = state.liquid_amount_per_full_cell
	var geometry: PackedFloat32Array = solver._rd.buffer_get_data(solver._buffers.cell_geometry).to_float32_array()
	var initial_volume := 0.0
	var final_volume := 0.0
	var solid_volume := 0.0
	var minimum := INF
	var maximum := -INF
	var uniform_error := 0.0
	var distribution_change := 0.0
	var finite := true
	var dry_volume := 0.0
	for i in cells:
		initial_volume += initial[i] * pow(solver.grid_dx, 3.0)
		final_volume += amounts[i] * pow(solver.grid_dx, 3.0)
		distribution_change += absf(amounts[i] - initial[i]) * pow(solver.grid_dx, 3.0)
		if scenario == "dry_face_free_surface" and float((i / dims.x) % dims.y) * solver.grid_dx >= 0.48:
			dry_volume += amounts[i] * pow(solver.grid_dx, 3.0)
		var capacity := geometry[i * 4 + 3]
		finite = finite and is_finite(amounts[i])
		if capacity <= 0.0:
			solid_volume += amounts[i] * pow(solver.grid_dx, 3.0)
		else:
			var concentration := amounts[i] / capacity
			minimum = minf(minimum, concentration)
			maximum = maxf(maximum, concentration)
			uniform_error = maxf(uniform_error, absf(concentration - 0.3))
	result.merge(state)
	result.merge({"speed": speed, "dt": dt, "steps": steps,
		"expected_time": 0.0 if scenario == "cfl_budget_rejection" else dt * steps,
		"initial_volume": initial_volume, "final_volume": final_volume, "solid_volume": solid_volume,
		"relative_error": absf(final_volume - initial_volume) / initial_volume,
		"minimum": minimum, "maximum": maximum, "uniform_error": uniform_error,
		"distribution_change": distribution_change, "dry_volume": dry_volume, "finite": finite})


static func run_apic_amount_reconstruction(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	for scenario: String in ["inclined_plane", "inclined_plane_lowered",
			"scaled_inclined_plane", "scaled_inclined_plane_lowered",
			"thin_cut_cell_film", "very_thin_cut_cell_film",
			"curved_surface", "curved_surface_lowered", "curved_small_boundary_wave",
			"odd_grid_inclined_plane"]:
		var dims := Vector3i(17, 11, 15) if scenario == "odd_grid_inclined_plane" else Vector3i(16, 12, 16)
		var config := FluidConfig.new()
		config.default_particle_count = 1
		config.particle_counts = [1]
		config.texture_width = 1
		config.domain_origin = Vector3.ZERO
		config.domain_size_m = Vector3(dims) * DX
		var solver := ApicFluidSolver.new()
		solver.config = config
		solver.particle_count = 1
		solver.active_count = 1
		solver.spacing = DX * 0.5
		solver.grid_cell_size_m = DX
		solver.free_surface_cut_cells = true
		solver.conservative_amount_tracking = true
		solver.conservative_surface_reconstruction = true
		solver.gravity = Vector3.ZERO
		solver.set_seed_positions(PackedFloat32Array([1.0, 0.46, 1.0, 0.0]))
		var obstacles: Array[Dictionary] = []
		var is_film := scenario.ends_with("cut_cell_film")
		var is_curved := scenario.begins_with("curved_")
		if is_film:
			obstacles.append({
				"transform": Transform3D(Basis.IDENTITY, Vector3(1.0, -0.55, 1.0)),
				"size": Vector3(4.0, 2.0, 4.0),
			})
		solver.set_scene_obstacles(obstacles)
		var gradient := Vector3.UP if is_film else Vector3(0.2, 1.0, 0.1).normalized()
		if scenario.begins_with("scaled_"):
			gradient *= 4.0
		var water_level := 0.46 if scenario == "very_thin_cut_cell_film" else 0.48
		var reference_point := Vector3(0.0, water_level, 0.0) if is_film else Vector3(1.0, 0.75, 1.0)
		var phi_shift := -0.05 if scenario.ends_with("lowered") else 0.05
		var phi := PackedFloat32Array()
		phi.resize(dims.x * dims.y * dims.z)
		for z in dims.z:
			for y in dims.y:
				for x in dims.x:
					var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * DX
					phi[(z * dims.y + y) * dims.x + x] = gradient.dot(p - reference_point)
					if is_curved:
						phi[(z * dims.y + y) * dims.x + x] = p.y - 0.75 - 0.2 * cos(TAU * p.x) - 0.05 * cos(TAU * p.z)
					if scenario == "curved_small_boundary_wave":
						phi[(z * dims.y + y) * dims.x + x] = p.y - 0.75 - 0.015 * cos(PI * p.x)
		solver.set_seed_levelset(phi)
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "APIC amount reconstruction: initialization failed")
			continue
		var result := {}
		RenderingServer.call_on_render_thread(_run_apic_amount_reconstruction_render.bind(solver, result, phi, phi_shift, gradient.length()))
		await RenderingServer.frame_post_draw
		var field_description := "y-0.75-0.2*cos(2*pi*x)-0.05*cos(2*pi*z)" if is_curved else "affine_plane"
		if scenario == "curved_small_boundary_wave":
			field_description = "y-0.75-0.015*cos(pi*x)"
		print("BREAKER APIC AMOUNT RECONSTRUCTION scenario=%s scope=local_plane_inverse seed=0 domain_m=(2,1.5,2) dx_m=0.125 spacing_m=0.0625 gradient=%s initial_field=%s imposed_phi_shift_m=%.3f partial_liquid_cells=%d max_interface_phi_error_m=%s reference_scalar_difference_m=%.12f partial_solid_cells=%d tetrahedral_volume_error=%.12f initial_amount_volume_m3=%.9f final_amount_volume_m3=%.9f finite=%s normal_fallback_cells=%d transport_time_s=%.6f physical_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable full_coupled_volume_conservation=unavailable" % [
			scenario, "variable_from_initial_field" if is_curved else str(gradient), field_description,
			phi_shift, int(result.partial_cells), "unavailable" if is_curved else "%.12f" % float(result.max_error), float(result.max_error),
			int(result.cut_cells), float(result.tetra_error), float(result.initial_volume),
			float(result.final_volume), str(bool(result.finite)), int(result.normal_fallback_cells),
			float(result.transport_time_s), solver._sim_time, solver._frame, solver.get_gpu_memory_bytes()])
		check.call(bool(result.finite) and int(result.partial_cells) > 0
			and (is_curved or float(result.max_error) <= 1.0e-6)
			and float(result.tetra_error) <= 1.0e-6
			and absf(float(result.initial_volume) - float(result.final_volume)) <= 1.0e-9
			and float(result.transport_time_s) == 0.0,
			"APIC amount reconstruction: local interface, tetrahedral volume, or fixed amount failed")
		print("BREAKER APIC AMOUNT COMMITTED GEOMETRY scenario=%s geometric_volume_m3=%.9f amount_volume_m3=%.9f relative_volume_error=%.9f max_fraction_error=%.12f worst_cell=%s" % [
			scenario, float(result.geometric_volume), float(result.final_volume),
			float(result.geometric_error), float(result.fraction_error), str(result.fraction_error_cell)])
		check.call(float(result.geometric_error) <= 0.01,
			"APIC amount reconstruction: committed interface geometry differs from amount by more than 1%")
		check.call(is_curved or float(result.fraction_error) <= 1.0e-6,
			"APIC amount reconstruction: an affine interface has inconsistent local committed volume")
		if scenario == "curved_small_boundary_wave":
			print("BREAKER APIC SMALL WAVE RECONSTRUCTION amplitude_m=0.015 max_surface_height_error_m=%.12f tolerance_m=0.00075" % float(result.surface_height_error))
			check.call(float(result.surface_height_error) <= 0.00075,
				"APIC amount reconstruction: small-wave surface differs from fixed amount by more than 5% of amplitude")
			print("BREAKER APIC TRANSVERSE NORMAL field_independent_of=z max_abs_normal_z=%.12f tolerance=0.000001" % float(result.max_partial_plane_z_normal))
			check.call(float(result.max_partial_plane_z_normal) <= 1.0e-6,
				"APIC amount reconstruction: boundary stencil creates a transverse interface normal")
		print("BREAKER APIC INTERFACE DISTANCE scenario=%s seed_cells=%d iterations=%d max_iterations=%d max_change_m=%.12f tolerance_m=%.12f converged=%s faces_initialized=%s" % [
			scenario, int(result.interface_distance_seed_cells), int(result.interface_distance_iterations),
			int(result.interface_distance_max_iterations), float(result.interface_distance_max_change_m),
			float(result.interface_distance_tolerance_m), str(bool(result.interface_distance_converged)), str(bool(result.faces_initialized))])
		check.call(bool(result.interface_distance_converged) and bool(result.faces_initialized)
			and float(result.interface_distance_max_change_m) <= float(result.interface_distance_tolerance_m),
			"APIC amount reconstruction: distance convergence or runtime face initialization failed")
		print("BREAKER APIC DISTANCE ORDER scenario=%s current=red_black_gauss_seidel reference=jacobi max_phi_difference_m=%.12f tolerance_m=%.12f relative_geometric_volume_difference=%.12f tolerance_relative=0.0001 current_iterations=%d reference_iterations=%d" % [
			scenario, float(result.distance_order_phi_difference_m), 2.0 * solver.interface_distance_tolerance_m,
			float(result.distance_order_volume_difference), int(result.interface_distance_iterations), int(result.distance_order_reference_iterations)])
		check.call(float(result.distance_order_phi_difference_m) <= 2.0 * solver.interface_distance_tolerance_m
			and float(result.distance_order_volume_difference) <= 0.0001
			and bool(result.distance_order_reference_converged),
			"APIC distance ordering: converged interface differs from the Jacobi reference")
		print("BREAKER APIC AMOUNT INVERSE IDENTITY scenario=%s max_phi_difference_m=%.12f reference=unconditional_inverse tolerance_m=0.0000001" % [scenario, float(result.identity_error)])
		check.call(float(result.identity_error) <= 1.0e-7,
			"APIC amount reconstruction: identity culling changes the unconditional inverse")
		if is_film:
			check.call(int(result.cut_cells) > 0 and absf(float(result.initial_volume) - 4.0 * (water_level - 0.45)) <= 1.0e-6,
				"APIC amount reconstruction: thin film geometric volume differs from the analytic reference")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func run_apic_amount_consistency(tree: SceneTree, check: Callable,
		still_water: bool = false, ticks: int = 1, advection_only: bool = false,
		first_substep: bool = false) -> void:
	var solver: ApicFluidSolver = build_apic_solver(0.12, 0, 0.0, true, still_water, 1 if first_substep else 3, true, true)
	solver.profiling = false
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC amount consistency: initialization failed")
		return
	solver.conservative_surface_reconstruction = false
	if not still_water:
		RenderingServer.call_on_render_thread(_set_seed_velocities.bind(solver, solver._seed_data))
		await RenderingServer.frame_post_draw
	for tick in ticks:
		if advection_only:
			RenderingServer.call_on_render_thread(_run_apic_zero_surface_transport_render.bind(solver))
		else:
			RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 180.0 if first_substep else 1.0 / 60.0))
		await RenderingServer.frame_post_draw
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_amount_consistency_render.bind(solver, result))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC AMOUNT CONSISTENCY scenario=%s seed=0 scope=%d_ticks_then_local_reconstruction dx_m=%.6f spacing_m=%.6f particles=%d physical_time_s=%.9f state_revision=%d before_volume_m3=%.9f frozen_gradient_volume_m3=%.9f committed_gradient_volume_m3=%.9f amount_volume_m3=%.9f deep_changed_cells=%d deep_amount_deficit_m3=%.12f max_deep_phi_shift_m=%.9f local_frozen_fraction_max_error=%.12f local_committed_fraction_max_error=%.12f changed_cells=%d max_phi_shift_m=%.9f max_shift_cell=%s finite=%s memory_bytes=%d gpu_timing=unavailable" % [
		"still_slope_rock" if still_water else "solitary_slope_rock", ticks,
		solver.grid_dx, solver.spacing, solver.live_count(), solver._sim_time, solver._frame,
		float(result.before_volume), float(result.frozen_volume), float(result.committed_volume),
		float(result.amount_volume), int(result.deep_changed), float(result.deep_deficit),
		float(result.max_deep_shift), float(result.frozen_error), float(result.committed_error),
		int(result.changed), float(result.max_shift), str(result.max_shift_cell),
		str(bool(result.finite)), solver.get_gpu_memory_bytes()])
	print("BREAKER APIC PRE RECONSTRUCTION max_seed_phi_error_m=%.12f worst_cell=%s" % [
		float(result.seed_error), str(result.seed_error_cell)])
	if advection_only:
		print("BREAKER APIC ZERO SURFACE TRANSPORT scenario=still_slope_rock transport_steps=%d dt_s=%.9f imposed_velocity_m_s=(0,0,0) max_seed_phi_error_m=%.12f pressure=unavailable gpu_timing=unavailable" % [
			ticks, 1.0 / 60.0, float(result.seed_error)])
		check.call(float(result.seed_error) <= 1.0e-7,
			"APIC surface transport: zero velocity changes the initialized flat interface")
	check.call(bool(result.finite)
		and absf(float(result.committed_volume) - float(result.amount_volume)) <= 0.01 * float(result.amount_volume),
		"APIC amount consistency: committed interface geometry differs from transported amount by more than 1%")
	if still_water and ticks == 0:
		check.call(float(result.max_shift) <= 1.0e-6,
			"APIC amount consistency: reconstruction changes the initialized flat interface")
	if still_water and first_substep:
		check.call(float(result.seed_error) <= 1.0e-6,
			"APIC surface transport: the first still-water substep moves the interface")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_zero_surface_transport_render(solver: ApicFluidSolver) -> void:
	var faces := (solver.grid_dims.x + 1) * (solver.grid_dims.y + 1) * (solver.grid_dims.z + 1)
	var zero_velocity := PackedByteArray()
	zero_velocity.resize(faces * 24)
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0, zero_velocity.size(), zero_velocity)
	var groups := ceili(float(solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z) / 256.0)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface", solver._pack_push_constant(1.0 / 60.0, -1), groups, 1, 1)
	solver._dispatch(cl, "surface", solver._pack_push_constant(1.0 / 60.0, -3), groups, 1, 1)
	solver._dispatch(cl, "surface", solver._pack_push_constant(1.0 / 60.0, -2), groups, 1, 1)
	solver._rd.compute_list_end()


static func _run_apic_amount_consistency_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	var cells := solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z
	var groups := ceili(float(cells) / 256.0)
	var phi_before := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var geometry := solver._rd.buffer_get_data(solver._buffers.cell_geometry).to_float32_array()
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 8), groups, 1, 1)
	solver._rd.compute_list_end()
	var before := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var gx := solver._rd.buffer_get_data(solver._buffers.cell_phi_next).to_float32_array()
	var gy := solver._rd.buffer_get_data(solver._buffers.cell_phi_corrected).to_float32_array()
	var gz := solver._rd.buffer_get_data(solver._buffers.residual).to_float32_array()
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_amount_reconstruction_render(cl, 1.0 / 180.0, groups)
	solver._rd.compute_list_end()
	var saved_gradients: Array[PackedFloat32Array] = [gx, gy, gz]
	var gradient_buffers: Array[String] = ["cell_phi_next", "cell_phi_corrected", "residual"]
	for component in 3:
		var bytes := saved_gradients[component].to_byte_array()
		solver._rd.buffer_update(solver._buffers[gradient_buffers[component]], 0, bytes.size(), bytes)
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 9), groups, 1, 1)
	solver._rd.compute_list_end()
	var phi_after := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var frozen := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 8), groups, 1, 1)
	solver._rd.compute_list_end()
	var committed := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var before_volume := 0.0
	var frozen_volume := 0.0
	var committed_volume := 0.0
	var amount_volume := 0.0
	var deep_changed := 0
	var deep_deficit := 0.0
	var max_deep_shift := 0.0
	var changed := 0
	var max_shift := 0.0
	var max_shift_cell := {}
	var frozen_error := 0.0
	var committed_error := 0.0
	var finite := true
	var seed_error := 0.0
	var seed_error_cell := {}
	for cell in cells:
		var offset := ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES
		var amount := before.decode_float(offset)
		var capacity := geometry[cell * 4 + 3]
		if capacity > 0.0:
			var delta := absf(phi_before[cell] - solver._seed_levelset[cell])
			if delta > seed_error:
				seed_error = delta
				seed_error_cell = {"cell": Vector3i(cell % solver.grid_dims.x,
					(cell / solver.grid_dims.x) % solver.grid_dims.y, cell / (solver.grid_dims.x * solver.grid_dims.y)),
					"phi_before": phi_before[cell], "seed_phi": solver._seed_levelset[cell]}
		var target := clampf(amount, 0.0, capacity)
		var pre := before.decode_float(offset + 4)
		var fixed := frozen.decode_float(offset + 4)
		var post := committed.decode_float(offset + 4)
		finite = finite and is_finite(pre) and is_finite(fixed) and is_finite(post)
		before_volume += pre * pow(solver.grid_dx, 3.0)
		frozen_volume += fixed * pow(solver.grid_dx, 3.0)
		committed_volume += post * pow(solver.grid_dx, 3.0)
		amount_volume += amount * pow(solver.grid_dx, 3.0)
		frozen_error = maxf(frozen_error, absf(fixed - target))
		committed_error = maxf(committed_error, absf(post - target))
		var radius := 0.5 * solver.grid_dx * (absf(gx[cell]) + absf(gy[cell]) + absf(gz[cell]))
		var shift := absf(phi_after[cell] - phi_before[cell])
		if shift > 1.0e-6:
			changed += 1
		if shift > max_shift:
			max_shift = shift
			var coordinate := Vector3i(cell % solver.grid_dims.x,
				(cell / solver.grid_dims.x) % solver.grid_dims.y, cell / (solver.grid_dims.x * solver.grid_dims.y))
			max_shift_cell = {"cell": coordinate,
				"world_center_m": solver.grid_origin + (Vector3(coordinate) + Vector3.ONE * 0.5) * solver.grid_dx,
				"phi_before_m": phi_before[cell], "phi_after_m": phi_after[cell],
				"gradient_before": Vector3(gx[cell], gy[cell], gz[cell]),
				"capacity": capacity, "amount": amount, "fraction_before": pre,
				"fraction_frozen": fixed, "fraction_committed": post}
		if capacity > 0.0 and phi_before[cell] < -radius and shift > 1.0e-6:
			deep_changed += 1
			deep_deficit += absf(amount - capacity) * pow(solver.grid_dx, 3.0)
			max_deep_shift = maxf(max_deep_shift, shift)
	result.merge({"before_volume": before_volume, "frozen_volume": frozen_volume,
		"committed_volume": committed_volume, "amount_volume": amount_volume,
		"deep_changed": deep_changed, "deep_deficit": deep_deficit, "max_deep_shift": max_deep_shift,
		"frozen_error": frozen_error, "committed_error": committed_error,
		"changed": changed, "max_shift": max_shift, "max_shift_cell": max_shift_cell,
		"seed_error": seed_error, "seed_error_cell": seed_error_cell, "finite": finite})


static func _run_apic_amount_reconstruction_render(solver: ApicFluidSolver,
		result: Dictionary, expected: PackedFloat32Array, phi_shift: float = 0.05,
		gradient_scale: float = 1.0) -> void:
	var geometry := solver._rd.buffer_get_data(solver._buffers.cell_geometry).to_float32_array()
	var ranges := solver._rd.buffer_get_data(solver._buffers.cell_vertex_ranges).to_int32_array()
	var vertices := solver._rd.buffer_get_data(solver._buffers.cut_vertices).to_float32_array()
	var initial := solver.read_liquid_amount_state_render()
	var amounts: PackedFloat32Array = initial.liquid_amount_per_full_cell
	var groups := ceili(float(expected.size()) / 256.0)
	var normal_cl := solver._rd.compute_list_begin()
	solver._dispatch(normal_cl, "surface_amount", solver._pack_push_constant(0.0, 31), groups, 1, 1)
	solver._rd.compute_list_end()
	var planes := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var reference_amount_state := planes.duplicate()
	var max_partial_plane_z_normal := 0.0
	for cell in amounts.size():
		if amounts[cell] <= 0.0 or amounts[cell] >= geometry[cell * 4 + 3]:
			continue
		var offset := ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + cell * ApicFluidSolver.AMOUNT_CELL_BYTES
		var oct := Vector2(planes.decode_float(offset + 8), planes.decode_float(offset + 12))
		var normal := Vector3(oct.x, oct.y, 1.0 - absf(oct.x) - absf(oct.y))
		if normal.z < 0.0:
			normal.x = (1.0 - absf(oct.y)) * (1.0 if oct.x >= 0.0 else -1.0)
			normal.y = (1.0 - absf(oct.x)) * (1.0 if oct.y >= 0.0 else -1.0)
		max_partial_plane_z_normal = maxf(max_partial_plane_z_normal, absf(normal.normalized().z))
	result["max_partial_plane_z_normal"] = max_partial_plane_z_normal
	var shifted := expected.duplicate()
	for i in shifted.size():
		shifted[i] += phi_shift
	var bytes := shifted.to_byte_array()
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, bytes.size(), bytes)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch_surface_amount_reconstruction_render(cl, 0.0, ceili(float(expected.size()) / 256.0))
	solver._rd.compute_list_end()
	var after := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var surface_height_error := 0.0
	var dims := solver.grid_dims
	for z in dims.z:
		for x in dims.x:
			var expected_height := INF
			var actual_height := INF
			for y in range(dims.y - 1):
				var cell := (z * dims.y + y) * dims.x + x
				var center := solver.grid_origin.y + (float(y) + 0.5) * solver.grid_dx
				if expected[cell] < 0.0 and expected[cell + dims.x] >= 0.0:
					expected_height = center - solver.grid_dx * expected[cell] / (expected[cell + dims.x] - expected[cell])
				if after[cell] < 0.0 and after[cell + dims.x] >= 0.0:
					actual_height = center - solver.grid_dx * after[cell] / (after[cell + dims.x] - after[cell])
			if is_finite(expected_height):
				surface_height_error = maxf(surface_height_error, absf(actual_height - expected_height))
	result["surface_height_error"] = surface_height_error
	var final := solver.read_liquid_amount_state_render()
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 30),
		ceili(float(expected.size()) / 256.0), 1, 1)
	solver._rd.compute_list_end()
	var reference_inverse := solver._rd.buffer_get_data(solver._buffers.divergence).to_float32_array()
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 26),
		ceili(float(expected.size()) / 256.0), 1, 1)
	solver._rd.compute_list_end()
	var culled_inverse := solver._rd.buffer_get_data(solver._buffers.divergence).to_float32_array()
	var identity_error := 0.0
	for cell in expected.size():
		identity_error = maxf(identity_error, absf(reference_inverse[cell] - culled_inverse[cell]))
	cl = solver._rd.compute_list_begin()
	solver._dispatch(cl, "surface_amount", solver._pack_push_constant(0.0, 8),
		ceili(float(expected.size()) / 256.0), 1, 1)
	solver._rd.compute_list_end()
	var committed := solver._rd.buffer_get_data(solver._buffers.surface_amount)
	var gx := solver._rd.buffer_get_data(solver._buffers.cell_phi_next).to_float32_array()
	var gy := solver._rd.buffer_get_data(solver._buffers.cell_phi_corrected).to_float32_array()
	var gz := solver._rd.buffer_get_data(solver._buffers.residual).to_float32_array()
	var face_flags := solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	var partial_cells := 0
	var cut_cells := 0
	var max_error := 0.0
	var tetra_error := 0.0
	var finite := true
	var initial_volume := 0.0
	var final_volume := 0.0
	var geometric_volume := 0.0
	var fraction_error := 0.0
	var fraction_error_cell := {}
	var faces_initialized := true
	for flags in face_flags:
		faces_initialized = faces_initialized and flags >= 0 and flags <= 3
	var final_amounts: PackedFloat32Array = final.liquid_amount_per_full_cell
	for i in amounts.size():
		finite = finite and is_finite(after[i]) and is_finite(final_amounts[i])
		initial_volume += amounts[i] * pow(solver.grid_dx, 3.0)
		final_volume += final_amounts[i] * pow(solver.grid_dx, 3.0)
		var fraction := committed.decode_float(ApicFluidSolver.AMOUNT_STATE_HEADER_BYTES + i * ApicFluidSolver.AMOUNT_CELL_BYTES + 4)
		geometric_volume += fraction * pow(solver.grid_dx, 3.0)
		var error := absf(fraction - final_amounts[i])
		if error > fraction_error:
			fraction_error = error
			var coordinate := Vector3i(i % solver.grid_dims.x,
				(i / solver.grid_dims.x) % solver.grid_dims.y, i / (solver.grid_dims.x * solver.grid_dims.y))
			fraction_error_cell = {"cell": coordinate, "phi": after[i], "expected": expected[i] / gradient_scale,
				"gradient": Vector3(gx[i], gy[i], gz[i]), "amount": final_amounts[i], "fraction": fraction}
		var capacity := geometry[i * 4 + 3]
		if amounts[i] > 1.0e-6 and amounts[i] < capacity - 1.0e-6:
			partial_cells += 1
			max_error = maxf(max_error, absf(after[i] - expected[i] / gradient_scale))
		if ranges[i * 4 + 3] > 0:
			cut_cells += 1
			var tetra_volume := 0.0
			for tetra in ranges[i * 4 + 3]:
				tetra_volume += vertices[(ranges[i * 4 + 2] + tetra * 4) * 4 + 3]
			tetra_error = maxf(tetra_error, absf(tetra_volume - capacity))
	result.merge(final)
	result.merge({"partial_cells": partial_cells, "max_error": max_error,
		"cut_cells": cut_cells, "tetra_error": tetra_error,
		"initial_volume": initial_volume, "final_volume": final_volume,
		"geometric_volume": geometric_volume, "geometric_error": absf(geometric_volume - final_volume) / final_volume,
		"fraction_error": fraction_error, "fraction_error_cell": fraction_error_cell,
		"faces_initialized": faces_initialized, "identity_error": identity_error, "finite": finite}, true)
	solver.interface_distance_red_black = false
	solver._rd.buffer_update(solver._buffers.surface_amount, 0, reference_amount_state.size(), reference_amount_state)
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, bytes.size(), bytes)
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_amount_reconstruction_render(cl, 0.0, groups)
	solver._rd.compute_list_end()
	var reference := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var reference_state := solver.read_liquid_amount_state_render()
	solver.interface_distance_red_black = true
	var order_difference := 0.0
	for i in after.size():
		order_difference = maxf(order_difference, absf(after[i] - reference[i])) if is_finite(reference[i]) else INF
	var reference_geometry: Dictionary = solver.get_interface_geometry_diagnostics_render()
	result["distance_order_phi_difference_m"] = order_difference
	result["distance_order_reference_iterations"] = reference_state.interface_distance_iterations
	result["distance_order_reference_converged"] = reference_state.interface_distance_converged
	result["distance_order_volume_difference"] = absf(geometric_volume - float(reference_geometry.geometric_volume_m3)) / maxf(geometric_volume, 1.0e-20)


static func _run_apic_surface_strain_render(solver: ApicFluidSolver, result: Dictionary,
		dt: float, center: Vector3, radius: float) -> void:
	var dims: Vector3i = solver.grid_dims
	var cells: int = dims.x * dims.y * dims.z
	var face_dims := dims + Vector3i.ONE
	var face_count: int = face_dims.x * face_dims.y * face_dims.z
	var offsets: Array[Vector3] = [Vector3(0.0, 0.5, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, 0.5, 0.0)]
	var extension := PackedFloat32Array()
	extension.resize(face_count * 6)
	for component in 3:
		for face in face_count:
			var x := face % face_dims.x
			var y := (face / face_dims.x) % face_dims.y
			var z := face / (face_dims.x * face_dims.y)
			var p := (Vector3(x, y, z) + offsets[component]) * solver.grid_dx
			var value := 0.7 * (p.y - center.y) if component == 0 else 0.0
			extension[(component * face_count + face) * 2] = value
	var extension_bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0,
		extension_bytes.size(), extension_bytes)
	var initial: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var exact := PackedFloat32Array()
	exact.resize(cells)
	var exact_time := dt * 60.0
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var p: Vector3 = (Vector3(x, y, z) + Vector3.ONE * 0.5) * solver.grid_dx
				var q := Vector3(p.x - center.x - 0.7 * exact_time * (p.y - center.y),
					p.y - center.y, p.z - center.z)
				exact[(z * dims.y + y) * dims.x + x] = q.length() - radius
	var time_before := solver._sim_time
	var revision_before := solver._frame
	var groups := ceili(float(cells) / 256.0)
	var cl := solver._rd.compute_list_begin()
	for step in 60:
		solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var transported: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var solid_types: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_types).to_int32_array()
	var solid_mask := PackedByteArray()
	solid_mask.resize(cells)
	for i in cells:
		solid_mask[i] = 1 if solid_types[i] == 2 else 0
	var initial_volume := 0.0
	var exact_volume := 0.0
	var transported_volume := 0.0
	var squared_error := 0.0
	var interface_cells := 0
	var finite := true
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var index := (z * dims.y + y) * dims.x + x
				finite = finite and is_finite(initial[index]) and is_finite(exact[index]) \
					and is_finite(transported[index])
				if solid_mask[index] != 0:
					continue
				var cell := Vector3i(x, y, z)
				initial_volume += _linear_cell_liquid_fraction(initial[index],
					_apic_cell_phi_span(initial, solid_mask, dims, cell)) * pow(solver.grid_dx, 3.0)
				exact_volume += _linear_cell_liquid_fraction(exact[index],
					_apic_cell_phi_span(exact, solid_mask, dims, cell)) * pow(solver.grid_dx, 3.0)
				transported_volume += _linear_cell_liquid_fraction(transported[index],
					_apic_cell_phi_span(transported, solid_mask, dims, cell)) * pow(solver.grid_dx, 3.0)
				if absf(exact[index]) <= solver.grid_dx:
					squared_error += pow(transported[index] - exact[index], 2.0)
					interface_cells += 1
	result.merge({"initial_volume": initial_volume, "exact_final_volume": exact_volume,
		"transported_volume": transported_volume,
		"volume_error_vs_exact": absf(transported_volume - exact_volume) / exact_volume,
		"estimator_bias_vs_initial": absf(exact_volume - initial_volume) / initial_volume,
		"interface_rms_error": sqrt(squared_error / float(maxi(interface_cells, 1))),
		"finite": finite, "physical_time_s": solver._sim_time,
		"state_revision": solver._frame, "physical_time_before_s": time_before,
		"state_revision_before": revision_before})


static func run_apic_surface_wall_barrier(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	const DT := 1.0 / 60.0
	const WALL_SIZE := Vector3(3.0, 0.0625, 2.0)
	var config := FluidConfig.new()
	config.default_particle_count = 1
	config.particle_counts = [1]
	config.texture_width = 1
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3.ONE * 2.0
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = DX * 0.5
	solver.grid_cell_size_m = DX
	solver.free_surface_cut_cells = true
	solver.gravity = Vector3.ZERO
	var wall_transform := Transform3D(Basis(Vector3.BACK, deg_to_rad(30.0)), Vector3.ONE)
	solver.set_seed_positions(PackedFloat32Array([1.0, 1.0, 1.0, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(16 * 16 * 16)
	for z in 16:
		for y in 16:
			for x in 16:
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * DX
				var local := wall_transform.affine_inverse() * p
				var index := (z * 16 + y) * 16 + x
				phi[index] = 0.125 if _apic_inside_box(local, WALL_SIZE) else -0.25
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([{
		transform = wall_transform, size = WALL_SIZE, retention = 1.0,
	}])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC wall barrier: solver failed to initialize")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_surface_wall_barrier_render.bind(
		solver, result, DT, wall_transform, WALL_SIZE))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE WALL BARRIER scenario=opposite_fluid_donor_independence seed=0 grid=%s dx_m=%.6f wall_angle_deg=30.000 wall_thickness_m=%.6f tangent_speed_m_s=0.800000 dt_s=%.9f transport_steps=1 blocked_interior_faces=%d target_cells_cpu=%d target_cells_gpu=%d target_masks_equal=%s cross_wall_stencils_cpu=%d cross_wall_stencils_gpu=%d compared_target_cells=%d changed_target_cells=%d max_target_difference_m=%.9f solid_phi_identical=true finite=%s physical_solver_time_s=%.6f state_revision=%d memory_bytes=%d gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, WALL_SIZE.y, DT, int(result.get("blocked_interior_faces", 0)),
		int(result.get("target_cells_cpu", 0)),
		int(result.get("target_cells_gpu", 0)),
		str(bool(result.get("target_masks_equal", false))),
		int(result.get("cross_wall_stencils_cpu", 0)), int(result.get("cross_wall_stencils_gpu", 0)),
		int(result.get("compared_target_cells", 0)), int(result.get("changed_target_cells", 0)),
		float(result.get("max_target_difference", INF)), str(bool(result.get("finite", false))),
		float(result.get("physical_time_s", -1.0)), int(result.get("state_revision", -1)),
		solver.get_gpu_memory_bytes()])
	check.call(bool(result.get("finite", false))
		and int(result.get("blocked_interior_faces", 0)) > 0
		and int(result.get("target_cells_cpu", 0)) == int(result.get("target_cells_gpu", -1))
		and bool(result.get("target_masks_equal", false))
		and int(result.get("cross_wall_stencils_cpu", 0)) > 0
		and int(result.get("cross_wall_stencils_gpu", 0)) > 0
		and int(result.get("target_cells_gpu", 0)) > 0
		and int(result.get("compared_target_cells", 0)) > 0
		and float(result.get("max_target_difference", INF)) <= 1.0e-6
		and is_equal_approx(float(result.get("physical_time_s", -1.0)), 0.0)
		and int(result.get("state_revision", -1)) == 0,
		"APIC wall barrier: target-side level set depends on opposite-side fluid values")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_surface_wall_barrier_render(solver: ApicFluidSolver,
		result: Dictionary, dt: float, wall_transform: Transform3D, wall_size: Vector3) -> void:
	var dims: Vector3i = solver.grid_dims
	var cells: int = dims.x * dims.y * dims.z
	var face_dims := dims + Vector3i.ONE
	var face_count: int = face_dims.x * face_dims.y * face_dims.z
	var face_groups := ceili(float(face_count * 3) / 256.0)
	var types: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_types).to_int32_array()
	var pc := solver._pack_push_constant(dt, -1)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "solid_faces", pc, face_groups, 1, 1)
	solver._rd.compute_list_end()
	var solid_faces: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.solid_faces).to_int32_array()
	var blocked_interior := 0
	for component in 3:
		for face in face_count:
			var x := face % face_dims.x
			var y := (face / face_dims.x) % face_dims.y
			var z := face / (face_dims.x * face_dims.y)
			var right := Vector3i(x, y, z)
			var left := right
			left[component] -= 1
			if left.x < 0 or left.y < 0 or left.z < 0 \
					or left.x >= dims.x or left.y >= dims.y or left.z >= dims.z \
					or right.x < 0 or right.y < 0 or right.z < 0 \
					or right.x >= dims.x or right.y >= dims.y or right.z >= dims.z:
				continue
			if solid_faces[component * face_count + face] != 0:
				blocked_interior += 1
	var phi_a: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var phi_b := phi_a.duplicate()
	var inverse := wall_transform.affine_inverse()
	var half := wall_size * 0.5
	var tangent_velocity: Vector3 = -wall_transform.basis.x * 0.8
	var extension := PackedFloat32Array()
	extension.resize(face_count * 6)
	var offsets: Array[Vector3] = [Vector3(0.0, 0.5, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, 0.5, 0.0)]
	for component in 3:
		for face in face_count:
			var x := face % face_dims.x
			var y := (face / face_dims.x) % face_dims.y
			var z := face / (face_dims.x * face_dims.y)
			var p: Vector3 = (Vector3(x, y, z) + offsets[component]) * solver.grid_dx
			extension[(component * face_count + face) * 2] = tangent_velocity[component]
	var extension_bytes := extension.to_byte_array()
	solver._rd.buffer_update(solver._buffers.face_extension_a, 0,
		extension_bytes.size(), extension_bytes)
	var target_cells_cpu := 0
	var target_cells_gpu := 0
	var cpu_cross := 0
	var gpu_cross := 0
	var cpu_target := PackedByteArray()
	cpu_target.resize(cells)
	var gpu_target := PackedByteArray()
	gpu_target.resize(cells)
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var index := (z * dims.y + y) * dims.x + x
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * solver.grid_dx
				var local := inverse * p
				if _apic_inside_box(local, wall_size) or local.y >= -half.y:
					continue
				cpu_target[index] = 1
				target_cells_cpu += 1
				if types[index] == 1:
					gpu_target[index] = 1
					target_cells_gpu += 1
	for z in dims.z:
		for y in dims.y:
			for x in dims.x:
				var index := (z * dims.y + y) * dims.x + x
				var p := (Vector3(x, y, z) + Vector3.ONE * 0.5) * solver.grid_dx
				var local := inverse * p
				if types[index] == 1 and not _apic_inside_box(local, wall_size) and local.y > half.y:
					phi_b[index] = -1.25
				if cpu_target[index] == 0:
					continue
				var departure := p - tangent_velocity * dt
				var q := departure / solver.grid_dx - Vector3.ONE * 0.5
				var base := Vector3i(floori(q.x), floori(q.y), floori(q.z))
				var fraction := q - Vector3(base)
				if base.x < 1 or base.y < 1 or base.z < 1 \
						or base.x + 1 >= dims.x - 1 or base.y + 1 >= dims.y - 1 \
						or base.z + 1 >= dims.z - 1:
					continue
				var negative_cpu := false
				var positive_cpu := false
				var negative_gpu := false
				var positive_gpu := false
				for dz in 2:
					for dy in 2:
						for dx in 2:
							var weight := (fraction.x if dx == 1 else 1.0 - fraction.x) \
								* (fraction.y if dy == 1 else 1.0 - fraction.y) \
								* (fraction.z if dz == 1 else 1.0 - fraction.z)
							if weight <= 0.0:
								continue
							var donor := base + Vector3i(dx, dy, dz)
							var donor_index := (donor.z * dims.y + donor.y) * dims.x + donor.x
							var donor_world := (Vector3(donor) + Vector3.ONE * 0.5) * solver.grid_dx
							var donor_local := inverse * donor_world
							if _apic_inside_box(donor_local, wall_size):
								continue
							if donor_local.y < -half.y:
								negative_cpu = true
								negative_gpu = negative_gpu or types[donor_index] == 1
							elif donor_local.y > half.y:
								positive_cpu = true
								positive_gpu = positive_gpu or types[donor_index] == 1
				if negative_cpu and positive_cpu:
					cpu_cross += 1
				if gpu_target[index] != 0 and negative_gpu and positive_gpu:
					gpu_cross += 1
	var time_before := solver._sim_time
	var revision_before := solver._frame
	var groups := ceili(float(cells) / 256.0)
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var after_a: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var phi_b_bytes := phi_b.to_byte_array()
	solver._rd.buffer_update(solver._buffers.cell_phi, 0, phi_b_bytes.size(), phi_b_bytes)
	cl = solver._rd.compute_list_begin()
	solver._dispatch_surface_transport_render(cl, dt, groups)
	solver._rd.compute_list_end()
	var after_b: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var max_difference := 0.0
	var changed := 0
	var target_count := 0
	var finite := true
	for i in cells:
		finite = finite and is_finite(after_a[i]) and is_finite(after_b[i])
		if gpu_target[i] == 0:
			continue
		target_count += 1
		if absf(after_a[i] - after_b[i]) > 1.0e-6:
			changed += 1
		max_difference = maxf(max_difference, absf(after_a[i] - after_b[i]))
	result.merge({"target_cells_cpu": target_cells_cpu, "target_cells_gpu": target_cells_gpu,
		"target_masks_equal": cpu_target == gpu_target,
		"blocked_interior_faces": blocked_interior,
		"compared_target_cells": target_count,
		"cross_wall_stencils_cpu": cpu_cross, "cross_wall_stencils_gpu": gpu_cross,
		"changed_target_cells": changed, "max_target_difference": max_difference,
		"finite": finite, "physical_time_s": solver._sim_time, "state_revision": solver._frame,
		"physical_time_before_s": time_before, "state_revision_before": revision_before})


static func _apic_inside_box(local: Vector3, box_size: Vector3) -> bool:
	return absf(local.x) <= box_size.x * 0.5 and absf(local.y) <= box_size.y * 0.5 \
		and absf(local.z) <= box_size.z * 0.5


static func run_apic_detached_gravity(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	const SPACING := 0.0625
	const DT := 1.0 / 60.0
	const GRAVITY := -9.81
	const BULK_COUNT := 48 * 8 * 48
	var seed := PackedFloat32Array()
	seed.resize((BULK_COUNT + 1) * 4)
	var particle := 0
	for z in 48:
		for y in 8:
			for x in 48:
				var offset := particle * 4
				seed[offset] = (float(x) + 0.5) * SPACING
				seed[offset + 1] = (float(y) + 0.5) * SPACING
				seed[offset + 2] = (float(z) + 0.5) * SPACING
				particle += 1
	var detached_index := BULK_COUNT
	seed[detached_index * 4] = 1.5
	seed[detached_index * 4 + 1] = 1.5
	seed[detached_index * 4 + 2] = 1.5
	var config := FluidConfig.new()
	config.default_particle_count = BULK_COUNT + 1
	config.particle_counts = [BULK_COUNT + 1]
	config.texture_width = ceili(sqrt(float(BULK_COUNT + 1)))
	config.domain_origin = Vector3.ZERO
	config.domain_size_m = Vector3.ONE * 3.0
	config.cell_size_m = DX
	config.grid_dims = Vector3i.ONE * 24
	var solver := ApicFluidSolver.new()
	solver.config = config
	solver.particle_count = BULK_COUNT + 1
	solver.active_count = BULK_COUNT + 1
	solver.spacing = SPACING
	solver.grid_cell_size_m = DX
	solver.gravity = Vector3(0.0, GRAVITY, 0.0)
	solver.substeps = 1
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(seed)
	var phi := PackedFloat32Array()
	phi.resize(24 * 24 * 24)
	for z in 24:
		for y in 24:
			for x in 24:
				phi[(z * 24 + y) * 24 + x] = (float(y) + 0.5) * DX - 0.5
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC detached gravity: solver failed to initialize")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
		return
	RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
	await RenderingServer.frame_post_draw
	var result := {}
	RenderingServer.call_on_render_thread(_read_apic_detached_gravity.bind(
		solver, result, detached_index))
	await RenderingServer.frame_post_draw
	var expected_velocity := GRAVITY * DT
	var expected_displacement := 0.5 * GRAVITY * DT * DT
	print("BREAKER APIC DETACHED GRAVITY scenario=phi_orphan_one_tick seed=0 grid=%s dx_m=%.6f particle_spacing_m=%.6f seed_layout=48x8x48_bulk+detached water_level_m=0.500 detached_position_m=(1.500,1.500,1.500) detached_volume_m3=%.9f bulk_volume_m3=%.9f gravity_y_m_s2=%.6f requested_dt_s=%.9f applied_dt_s=%.9f requested_ticks=1 applied_ticks=%d physical_time_s=%.9f substeps=%d detached_vy_m_s=%.9f expected_vy_m_s=%.9f detached_delta_y_m=%.9f expected_delta_y_m=%.9f bulk_first_speed_m_s=%.9f finite=%s outside=%d memory_bytes=%d gpu_timing=unavailable" % [
		str(solver.grid_dims), DX, SPACING, pow(SPACING, 3.0), BULK_COUNT * pow(SPACING, 3.0),
		GRAVITY, DT, float(result.get("applied_dt_s", -1.0)), int(result.get("applied_ticks", -1)),
		float(result.get("physical_time_s", -1.0)),
		int(result.get("substeps", -1)), float(result.get("detached_vy", INF)), expected_velocity,
		float(result.get("detached_delta_y", INF)), expected_displacement,
		float(result.get("bulk_first_speed", INF)), str(bool(result.get("finite", false))),
		int(result.get("outside", -1)), solver.get_gpu_memory_bytes()])
	check.call(bool(result.get("finite", false)) and int(result.get("outside", -1)) == 0
		and int(result.get("applied_ticks", -1)) == 1 and int(result.get("substeps", -1)) == 1
		and absf(float(result.get("physical_time_s", -1.0)) - DT) <= 1.0e-8
		and absf(float(result.get("detached_vy", INF)) - expected_velocity) <= 1.0e-5
		and absf(float(result.get("detached_delta_y", INF)) - expected_displacement) <= 1.0e-5
		and float(result.get("bulk_first_speed", INF)) <= 0.01,
		"APIC detached gravity: mass-supported air particle lost gravity velocity or bulk water left rest")
	var motion: Dictionary = result.particle_motion
	print("BREAKER APIC DETACHED GRAVITY particle_motion=%s" % str(motion))
	check.call(bool(motion.finite) and int(motion.ballistic_particle_count) == 1
		and int(motion.grid_transferred_particle_count) == BULK_COUNT
		and absf(float(motion.ballistic_particle_volume_m3) - pow(SPACING, 3.0)) <= 1.0e-12,
		"APIC detached gravity: motion classes lost represented particle volume")
	var initial_position: Vector3 = result.detached_position_m
	var incident_velocity := Vector3(0.8, 0.1, -0.2)
	RenderingServer.call_on_render_thread(_set_apic_detached_momentum_render.bind(
		solver, detached_index, incident_velocity))
	await RenderingServer.frame_post_draw
	RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
	await RenderingServer.frame_post_draw
	var momentum_result := {}
	RenderingServer.call_on_render_thread(_read_apic_detached_gravity.bind(
		solver, momentum_result, detached_index))
	await RenderingServer.frame_post_draw
	var expected_vector := incident_velocity + Vector3(0.0, GRAVITY * DT, 0.0)
	var velocity_error: float = (momentum_result.detached_velocity_m_s as Vector3).distance_to(expected_vector)
	var displacement_error: float = (momentum_result.detached_position_m as Vector3).distance_to(initial_position + DT * incident_velocity + Vector3(0.0, 0.5 * GRAVITY * DT * DT, 0.0))
	var expected_affine := PackedFloat32Array([0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])
	var affine_error := 0.0
	for i in expected_affine.size():
		affine_error = maxf(affine_error, absf(momentum_result.detached_affine[i] - expected_affine[i]))
	print("BREAKER APIC DETACHED MOMENTUM scenario=ballistic_affine_particle seed=0 physical_time_s=%.9f requested_velocity_m_s=%s expected_velocity_m_s=%s applied_velocity_m_s=%s velocity_error_m_s=%.9f displacement_error_m=%.9f affine_error_s_inv=%.9f particle_motion=%s" % [
		float(momentum_result.physical_time_s), str(incident_velocity), str(expected_vector),
		str(momentum_result.detached_velocity_m_s), velocity_error, displacement_error, affine_error,
		str(momentum_result.particle_motion)])
	check.call(bool(momentum_result.finite) and velocity_error <= 1.0e-5
		and displacement_error <= 1.0e-5 and affine_error <= 1.0e-6
		and int(momentum_result.applied_ticks) == 2,
		"APIC detached momentum: ballistic transfer lost incident velocity or affine momentum")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
	for rate_hz in [30, 60, 120]:
		var step_dt := 1.0 / float(rate_hz)
		var steps := roundi(float(rate_hz) / 10.0)
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "APIC detached timestep: solver failed to initialize")
			break
		for tick in steps:
			RenderingServer.call_on_render_thread(solver.step_render.bind(step_dt))
			await RenderingServer.frame_post_draw
		var rate_result := {}
		RenderingServer.call_on_render_thread(_read_apic_detached_gravity.bind(
			solver, rate_result, detached_index))
		await RenderingServer.frame_post_draw
		var requested_time_s := float(steps) * step_dt
		var exact_position := Vector3(1.5, 1.5 + 0.5 * GRAVITY * requested_time_s * requested_time_s, 1.5)
		var exact_velocity := Vector3(0.0, GRAVITY * requested_time_s, 0.0)
		var position_error_m: float = (rate_result.detached_position_m as Vector3).distance_to(exact_position)
		var rate_velocity_error: float = (rate_result.detached_velocity_m_s as Vector3).distance_to(exact_velocity)
		print("BREAKER APIC DETACHED TIMESTEP scenario=constant_gravity seed=0 rate_hz=%d requested_dt_s=%.9f applied_dt_s=%.9f requested_time_s=%.9f physical_time_s=%.9f dx_m=%.6f particle_spacing_m=%.6f particles=%d velocity_error_m_s=%.9f position_error_m=%.9f particle_motion=%s memory_bytes=%d gpu_timing=unavailable render=unavailable" % [
			rate_hz, step_dt, solver.last_step_dt_s, requested_time_s,
			float(rate_result.physical_time_s), DX, SPACING, solver.live_count(),
			rate_velocity_error, position_error_m, str(rate_result.particle_motion), solver.get_gpu_memory_bytes()])
		check.call(bool(rate_result.finite) and int(rate_result.outside) == 0
			and absf(float(rate_result.physical_time_s) - requested_time_s) <= 1.0e-8
			and rate_velocity_error <= 1.0e-5 and position_error_m <= 1.0e-5
			and int(rate_result.particle_motion.ballistic_particle_count) == 1,
			"APIC detached timestep: free fall differs from exact constant-gravity motion")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw


static func _read_apic_detached_gravity(solver: ApicFluidSolver, result: Dictionary,
		detached_index: int) -> void:
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.positions_a).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.velocities_a).to_float32_array()
	var offset := detached_index * 4
	var bulk_speed := Vector3(velocities[0], velocities[1], velocities[2]).length()
	var outside := 0
	var finite := true
	for i in solver.live_count():
		var base := i * 4
		var p := Vector3(positions[base], positions[base + 1], positions[base + 2])
		var v := Vector3(velocities[base], velocities[base + 1], velocities[base + 2])
		finite = finite and p.is_finite() and v.is_finite()
		if p.x < 0.0 or p.y < 0.0 or p.z < 0.0 or p.x > 3.0 or p.y > 3.0 or p.z > 3.0:
			outside += 1
	result.merge({"detached_vy": velocities[offset + 1],
		"detached_position_m": Vector3(positions[offset], positions[offset + 1], positions[offset + 2]),
		"detached_velocity_m_s": Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2]),
		"detached_affine": solver._rd.buffer_get_data(solver._buffers.affine_rows, detached_index * 48, 48).to_float32_array(),
		"particle_motion": solver.get_particle_motion_diagnostics_render(),
		"detached_delta_y": positions[offset + 1] - 1.5,
		"bulk_first_speed": bulk_speed, "finite": finite, "outside": outside,
		"applied_dt_s": solver.last_step_dt_s, "applied_ticks": solver._frame,
		"substeps": solver.last_substeps, "physical_time_s": solver._sim_time})


static func _set_apic_detached_momentum_render(solver: ApicFluidSolver,
		detached_index: int, velocity: Vector3) -> void:
	var values := PackedFloat32Array([velocity.x, velocity.y, velocity.z, float(detached_index)])
	var affine := PackedFloat32Array([0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])
	solver._rd.buffer_update(solver._buffers.velocities_a, detached_index * 16, 16, values.to_byte_array())
	solver._rd.buffer_update(solver._buffers.affine_rows, detached_index * 48, 48, affine.to_byte_array())


static func run_apic_thin_film(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	const SPACING := 0.0625
	const DT := 1.0 / 60.0
	const GRAVITY := -9.81
	const PARTICLE := Vector3(1.5, 0.475, 1.5)
	const FLOOR_SIZE := Vector3(3.0, 0.45, 3.0)
	var samples: Array[Dictionary] = []
	for poison_solid_phi in [false, true]:
		var config := FluidConfig.new()
		config.default_particle_count = 1
		config.particle_counts = [1]
		config.texture_width = 1
		config.domain_origin = Vector3.ZERO
		config.domain_size_m = Vector3.ONE * 3.0
		config.cell_size_m = DX
		config.grid_dims = Vector3i.ONE * 24
		var solver := ApicFluidSolver.new()
		solver.config = config
		solver.particle_count = 1
		solver.active_count = 1
		solver.spacing = SPACING
		solver.grid_cell_size_m = DX
		solver.collision_inflation = 0.0
		solver.gravity = Vector3(0.0, GRAVITY, 0.0)
		solver.substeps = 1
		solver.free_surface_cut_cells = true
		solver.set_seed_positions(PackedFloat32Array([PARTICLE.x, PARTICLE.y, PARTICLE.z, 0.0]))
		var phi := PackedFloat32Array()
		phi.resize(24 * 24 * 24)
		for z in 24:
			for y in 24:
				for x in 24:
					phi[(z * 24 + y) * 24 + x] = (float(y) + 0.5) * DX - 0.5
		solver.set_seed_levelset(phi)
		var floor_transform := Transform3D(Basis.IDENTITY, Vector3(1.5, FLOOR_SIZE.y * 0.5, 1.5))
		solver.set_scene_obstacles([{
			transform = floor_transform, size = FLOOR_SIZE, retention = 1.0,
		}])
		RenderingServer.call_on_render_thread(solver.init_render)
		await RenderingServer.frame_post_draw
		if not solver.initialized:
			check.call(false, "APIC thin film: solver failed to initialize")
			RenderingServer.call_on_render_thread(solver.free_render)
			await RenderingServer.frame_post_draw
			continue
		var result := {}
		RenderingServer.call_on_render_thread(_step_apic_thin_film.bind(
			solver, result, DT, poison_solid_phi))
		await RenderingServer.frame_post_draw
		samples.append(result)
		print("BREAKER APIC THIN FILM scenario=immersed_subgrid_film seed=0 solid_phi_variant=%s domain_m=3.000 dx_m=%.6f particle_spacing_m=%.6f floor_top_y_m=0.450000 water_level_m=0.500000 film_thickness_m=0.050000 particle_position_m=%s particle_volume_m3=%.9f gravity_y_m_s2=%.6f requested_dt_s=%.9f applied_dt_s=%.9f requested_ticks=1 applied_ticks=%d physical_time_s=%.9f substeps=%d fluid_cells=%d solid_cells=%d solid_phi_modified_cells=%d particle_vy_m_s=%.9f delta_y_m=%.9f finite=%s outside=%d memory_bytes=%d gpu_timing=unavailable" % [
			"alternating_pm1000" if poison_solid_phi else "seeded", DX, SPACING, str(PARTICLE),
			pow(SPACING, 3.0), GRAVITY, DT, float(result.get("applied_dt_s", -1.0)),
			int(result.get("applied_ticks", -1)), float(result.get("physical_time_s", -1.0)),
			int(result.get("substeps", -1)),
			int(result.get("fluid_cells", -1)), int(result.get("solid_cells", -1)),
			int(result.get("solid_phi_modified_cells", 0)), float(result.get("particle_vy", INF)),
			float(result.get("delta_y", INF)), str(bool(result.get("finite", false))),
			int(result.get("outside", -1)), solver.get_gpu_memory_bytes()])
		check.call(bool(result.get("finite", false)) and int(result.get("outside", -1)) == 0
			and int(result.get("fluid_cells", 0)) > 0
			and int(result.get("solid_cells", 0)) > 0
			and int(result.get("applied_ticks", -1)) == 1
			and int(result.get("substeps", -1)) == 1
			and absf(float(result.get("particle_vy", INF))) <= 1.0e-5
			and absf(float(result.get("delta_y", INF))) <= 1.0e-5,
			"APIC thin film: submerged particle acquired unsupported ballistic gravity")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
	if samples.size() == 2:
		var baseline: Dictionary = samples[0]
		var poisoned: Dictionary = samples[1]
		var motion_delta := maxf(absf(float(baseline.get("particle_vy", INF))
			- float(poisoned.get("particle_vy", INF))), absf(float(baseline.get("delta_y", INF))
			- float(poisoned.get("delta_y", INF))))
		print("BREAKER APIC THIN FILM SOLID INDEPENDENCE scenario=solid_phi_arbitrary_values seed=0 modified_cells=%d baseline_vy_m_s=%.9f poisoned_vy_m_s=%.9f baseline_delta_y_m=%.9f poisoned_delta_y_m=%.9f max_motion_difference=%.9f" % [
			int(poisoned.get("solid_phi_modified_cells", 0)),
			float(baseline.get("particle_vy", INF)), float(poisoned.get("particle_vy", INF)),
			float(baseline.get("delta_y", INF)), float(poisoned.get("delta_y", INF)), motion_delta])
		check.call(int(poisoned.get("solid_phi_modified_cells", 0)) > 0 and motion_delta <= 1.0e-6,
			"APIC thin film: particle motion depends on arbitrary phi values inside the solid floor")
	else:
		check.call(false, "APIC thin film: both solid-phi variants did not initialize")


static func _step_apic_thin_film(solver: ApicFluidSolver, result: Dictionary,
		dt: float, poison_solid_phi: bool) -> void:
	var cells: int = solver.grid_dims.x * solver.grid_dims.y * solver.grid_dims.z
	var types: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_types).to_int32_array()
	var modified := 0
	if poison_solid_phi:
		var phi: PackedFloat32Array = solver._rd.buffer_get_data(
			solver._buffers.cell_phi).to_float32_array()
		for i in cells:
			if types[i] == 2:
				phi[i] = 1000.0 if (i & 1) == 0 else -1000.0
				modified += 1
		var bytes := phi.to_byte_array()
		solver._rd.buffer_update(solver._buffers.cell_phi, 0, bytes.size(), bytes)
	solver.step_render(dt)
	var positions: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.positions_a).to_float32_array()
	var velocities: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.velocities_a).to_float32_array()
	var final_types: PackedInt32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_types).to_int32_array()
	var fluid_cells := 0
	var solid_cells := 0
	for cell_type in final_types:
		fluid_cells += 1 if cell_type == 1 else 0
		solid_cells += 1 if cell_type == 2 else 0
	var p := Vector3(positions[0], positions[1], positions[2])
	var v := Vector3(velocities[0], velocities[1], velocities[2])
	result.merge({"particle_vy": v.y, "delta_y": p.y - 0.475,
		"finite": p.is_finite() and v.is_finite(),
		"outside": 0 if p.x >= 0.0 and p.y >= 0.0 and p.z >= 0.0
			and p.x <= 3.0 and p.y <= 3.0 and p.z <= 3.0 else 1,
		"fluid_cells": fluid_cells, "solid_cells": solid_cells,
		"solid_phi_modified_cells": modified, "applied_dt_s": solver.last_step_dt_s,
		"applied_ticks": solver._frame, "substeps": solver.last_substeps,
		"physical_time_s": solver._sim_time})


static func run_apic_solid_geometry(check: Callable) -> void:
	var geometry = ApicFluidSolver.CutGeometry
	var domain := AABB(Vector3.ZERO, Vector3.ONE * 3.0)
	var no_solids: Array[Array] = []
	var center := Vector3(1.5, 0.4375, 1.5)
	var floor_planes: Array[Array] = geometry.obstacle_planes([{
		transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 0.225, 1.5)),
		size = Vector3(3.0, 0.45, 3.0),
	}])
	var film = geometry.open_cube(center, 0.125, domain, floor_planes, true)
	var empty = geometry.open_cube(Vector3.ONE, 0.125, domain, no_solids, true)
	var closed = geometry.open_cube(Vector3(1.5, 0.125, 1.5), 0.125, domain, floor_planes, true)
	var face_u: float = geometry.open_face(center, 0.125, 0, domain, floor_planes)
	var global_domain := AABB(Vector3.ONE * -10.0, Vector3.ONE * 20.0)
	var overlap: Array[Array] = geometry.obstacle_planes([
		{transform = Transform3D(Basis.IDENTITY, Vector3(-0.25, 0.0, 0.0)), size = Vector3(0.5, 4.0, 4.0)},
		{transform = Transform3D(Basis.IDENTITY, Vector3(-0.125, 0.0, 0.0)), size = Vector3(0.75, 4.0, 4.0)},
	])
	var union = geometry.open_cube(Vector3.ZERO, 1.0, global_domain, overlap, true)
	var thin: Array[Array] = geometry.obstacle_planes([
		{transform = Transform3D.IDENTITY, size = Vector3(0.08, 4.0, 4.0)},
	])
	var split = geometry.open_cube(Vector3.ZERO, 1.0, global_domain, thin, true)
	var rotation := Basis(Vector3.FORWARD, PI / 4.0)
	var inclined: Array[Array] = geometry.obstacle_planes([
		{transform = Transform3D(rotation, -rotation.y * 2.0), size = Vector3(6.0, 4.0, 6.0)},
	])
	var slope = geometry.open_cube(Vector3.ZERO, 1.0, global_domain, inclined, true)
	var limited := AABB(Vector3.ZERO, Vector3.ONE)
	var edge = geometry.open_cube(Vector3(1.0, 0.5, 0.5), 0.25, limited, no_solids, true)
	var edge_face: float = geometry.open_face(Vector3(0.9375, 0.5, 0.5), 0.25, 2, limited, no_solids)
	var max_error := maxf(absf(float(empty.open_fraction) - 1.0), absf(float(closed.open_fraction)))
	for pair in [[film.open_fraction, 0.4], [face_u, 0.4], [union.open_fraction, 0.25],
		[split.open_fraction, 0.92], [slope.open_fraction, 0.5], [edge.open_fraction, 0.5], [edge_face, 0.75]]:
		max_error = maxf(max_error, absf(float(pair[0]) - float(pair[1])))
	print("BREAKER APIC SOLID GEOMETRY scenario=analytic_obb_union_and_domain seed=0 cases=9 max_fraction_error=%.9f film_fraction=%.9f film_anchor_m=%s overlap_fraction=%.9f split_fraction=%.9f split_anchor_m=%s slope_fraction=%.9f domain_fraction=%.9f domain_face_fraction=%.9f vertices=%d gpu_timing=unavailable" % [
		max_error, float(film.open_fraction), str(film.anchor_m), float(union.open_fraction),
		float(split.open_fraction), str(split.anchor_m), float(slope.open_fraction),
		float(edge.open_fraction), edge_face, film.vertices_m.size()])
	check.call(is_finite(max_error) and max_error <= 1.0e-5
		and absf((film.anchor_m as Vector3).y - 0.475) <= 1.0e-5
		and absf((split.anchor_m as Vector3).x) > 0.04
		and absf((edge.anchor_m as Vector3).x - 0.9375) <= 1.0e-5,
		"APIC solid geometry: exact clipped volumes, areas or open anchors are incorrect")
	var max_tetra_error := 0.0
	var tetra_count := 0
	for entry in [[film, 0.125], [empty, 0.125], [closed, 0.125],
			[union, 1.0], [split, 1.0], [slope, 1.0], [edge, 0.25]]:
		var points: PackedVector3Array = entry[0].tetrahedra_m
		var dx: float = entry[1]
		var volume := 0.0
		check.call(points.size() % 4 == 0, "APIC solid geometry: incomplete tetrahedron")
		for index in range(0, points.size(), 4):
			volume += absf((points[index + 1] - points[index]).dot(
				(points[index + 2] - points[index]).cross(points[index + 3] - points[index]))) / 6.0
			tetra_count += 1
		max_tetra_error = maxf(max_tetra_error, absf(volume / pow(dx, 3.0) - float(entry[0].open_fraction)))
	print("BREAKER APIC SOLID GEOMETRY tetrahedral_decomposition cases=7 tetrahedra=%d max_fraction_error=%.12f" % [tetra_count, max_tetra_error])
	check.call(is_finite(max_tetra_error) and max_tetra_error <= 1.0e-6,
		"APIC solid geometry: tetrahedral decomposition changes open-cell volume")
	var near_plane_cases := 0
	var max_interval_error := 0.0
	var max_overfill := 0.0
	for slope_value in [-1.0e-5, -1.0e-6, -1.0e-7, 0.0, 1.0e-7, 1.0e-6, 1.0e-5]:
		for height_offset in [-1.0e-6, -1.0e-7, -1.0e-8, 0.0, 1.0e-8, 1.0e-7, 1.0e-6]:
			var normal := Vector3(slope_value, -1.0, slope_value).normalized()
			var surface_point := Vector3(1.5, 0.5 + height_offset, 1.5)
			var air: Array[Plane] = [Plane(normal, normal.dot(surface_point))]
			var excluded: Array[Array] = floor_planes.duplicate()
			excluded.append(air)
			var clipped = geometry.open_cube(center, 0.125, domain, excluded)
			var half_range: float = 0.125 * absf(slope_value)
			var lower: float = clampf((0.5 + height_offset - half_range - 0.45) / 0.125, 0.0, float(film.open_fraction))
			var upper: float = clampf((0.5 + height_offset + half_range - 0.45) / 0.125, 0.0, float(film.open_fraction))
			max_interval_error = maxf(max_interval_error, maxf(lower - float(clipped.open_fraction), float(clipped.open_fraction) - upper))
			max_overfill = maxf(max_overfill, float(clipped.open_fraction) - float(film.open_fraction))
			near_plane_cases += 1
	print("BREAKER APIC SOLID GEOMETRY near_coplanar_free_surface cases=%d max_fraction_interval_error=%.12f max_fraction_overfill=%.12f" % [near_plane_cases, max_interval_error, max_overfill])
	check.call(is_finite(max_interval_error) and max_interval_error <= 1.0e-5
		and is_finite(max_overfill) and max_overfill <= 1.0e-6,
		"APIC solid geometry: nearly coplanar free surface double-counted a boundary face")


static func run_apic_dry_cut_cell(tree: SceneTree, check: Callable) -> void:
	var solver := ApicFluidSolver.new()
	solver.config.domain_origin = Vector3.ZERO
	solver.config.domain_size_m = Vector3.ONE * 3.0
	solver.config.default_particle_count = 1
	solver.config.particle_counts = [1]
	solver.config.texture_width = 1
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = 0.05
	solver.grid_cell_size_m = 0.25
	solver.collision_inflation = 0.0
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(PackedFloat32Array([1.5, 1.5, 1.5, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(12 * 12 * 12)
	for z in 12:
		for y in 12:
			for x in 12:
				phi[(z * 12 + y) * 12 + x] = (float(y) + 0.5) * 0.25 - 0.4
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([{
		transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 0.225, 1.5)),
		size = Vector3(3.0, 0.45, 3.0), retention = 1.0,
	}])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC dry cut cell: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_read_apic_dry_cut_cell_render.bind(solver, result))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC DRY CUT CELL scenario=water_level_below_floor seed=0 domain_m=3.000 floor_top_y_m=0.450 water_level_m=0.400 dx_m=0.250 cell_center_y_m=0.375 cell_center_phi_m=-0.025 physical_time_s=%.9f state_revision=%d fluid_cells=%d physical_liquid_volume_m3=%.9f memory_bytes=%d gpu_timing=unavailable" % [
		solver._sim_time, solver._frame, int(result.get("fluid_cells", -1)),
		float(result.get("volume_m3", INF)), solver.get_gpu_memory_bytes()])
	check.call(int(result.get("fluid_cells", -1)) == 0
		and absf(float(result.get("volume_m3", INF))) <= 1.0e-7,
		"APIC dry cut cell: negative ghost phi created liquid above a dry floor")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _read_apic_dry_cut_cell_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	var types := solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	var volume_state := _apic_volume_diagnostics(solver)
	result.merge({"fluid_cells": types.count(1), "volume_m3": volume_state.planar_cell_volume_estimate_m3})


static func run_apic_dry_face_transport(tree: SceneTree, check: Callable) -> void:
	var solver := ApicFluidSolver.new()
	solver.config.domain_origin = Vector3.ZERO
	solver.config.domain_size_m = Vector3(5.0, 3.0, 3.0)
	solver.config.default_particle_count = 1
	solver.config.particle_counts = [1]
	solver.config.texture_width = 1
	solver.particle_count = 1
	solver.active_count = 1
	solver.spacing = 0.1
	solver.grid_cell_size_m = 1.0
	solver.collision_inflation = 0.0
	solver.gravity = Vector3.ZERO
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(PackedFloat32Array([1.5, 1.5, 1.5, 0.0]))
	var phi := PackedFloat32Array()
	phi.resize(45)
	var row := PackedFloat32Array([1.9, -0.2, -0.1, -2.2, 1.9])
	for z in 3:
		for y in 3:
			for x in 5:
				phi[(z * 3 + y) * 5 + x] = 1.9 if y == 2 or (y == 1 and x == 2) else row[x]
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([{
		transform = Transform3D(Basis.IDENTITY, Vector3(2.5, 0.45, 1.5)),
		size = Vector3(5.0, 0.9, 3.0), retention = 1.0,
	}])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC dry face transport: solver failed to initialize")
		return
	var result := {}
	RenderingServer.call_on_render_thread(_run_apic_dry_face_transport_render.bind(solver, result))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC DRY FACE TRANSPORT scenario=manufactured_conflicting_cut_cell_traces seed=0 scope=velocity_extension_surface_advection_reclassification domain_m=(5,3,3) dx_m=1.000 floor_top_y_m=0.900 geometry_face_fraction=%.9f ghost_air_phi_m=-0.100 imposed_velocity_x_m_s=1.000 operator_dt_s=0.500 physical_time_s=%.9f state_revision=%d before_left_type=%d before_right_type=%d before_face_flags=%d extrapolated_face_velocity_m_s=%.9f after_right_phi_m=%.9f after_right_type=%d after_face_flags=%d finite=%s memory_bytes=%d gpu_timing=unavailable volume_conservation=unavailable" % [
		float(result.face_fraction), solver._sim_time, solver._frame,
		int(result.left_before), int(result.right_before), int(result.flags_before),
		float(result.extended_velocity), float(result.right_phi_after), int(result.right_after),
		int(result.flags_after), str(result.finite), solver.get_gpu_memory_bytes()])
	check.call(int(result.left_before) == 1 and int(result.right_before) == 0
		and int(result.flags_before) == 2 and absf(float(result.face_fraction) - 0.1) <= 1.0e-6,
		"APIC dry face transport: dry liquid aperture was confused with closed solid geometry")
	check.call(bool(result.finite) and float(result.extended_velocity) > 0.5
		and int(result.right_after) == 1 and int(result.flags_after) == 0,
		"APIC dry face transport: dry pressure flag pinned the advancing interface")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _run_apic_dry_face_transport_render(solver: ApicFluidSolver, result: Dictionary) -> void:
	const DT := 0.5
	const LEFT := 16
	const RIGHT := 17
	const FACE := 26
	const FACE_COUNT := 96
	var pc := solver._pack_push_constant(DT, -1)
	var cl := solver._rd.compute_list_begin()
	solver._dispatch(cl, "classify", pc, 1, 1, 1)
	solver._dispatch(cl, "solid_faces", pc, 2, 1, 1)
	solver._rd.compute_list_end()
	var types := solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	var flags := solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	var areas := solver._rd.buffer_get_data(solver._buffers.face_area).to_float32_array()
	result.merge({"left_before": types[LEFT], "right_before": types[RIGHT],
		"flags_before": flags[FACE], "face_fraction": areas[FACE]})
	for component in 3:
		var velocity := PackedFloat32Array()
		velocity.resize(FACE_COUNT)
		velocity.fill(1.0 if component == 0 else 0.0)
		var key: String = ["face_u", "face_v", "face_w"][component]
		solver._rd.buffer_update(solver._buffers[key], 0, FACE_COUNT * 4, velocity.to_byte_array())
	cl = solver._rd.compute_list_begin()
	solver._dispatch_velocity_extension_render(cl, DT, 2, false)
	solver._dispatch_surface_transport_render(cl, DT, 1)
	solver._dispatch(cl, "classify", pc, 1, 1, 1)
	solver._dispatch(cl, "solid_faces", pc, 2, 1, 1)
	solver._rd.compute_list_end()
	types = solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	flags = solver._rd.buffer_get_data(solver._buffers.solid_faces).to_int32_array()
	var phi := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var velocity := solver._rd.buffer_get_data(solver._buffers.face_u).to_float32_array()
	var finite := true
	for value in phi:
		finite = finite and is_finite(value)
	result.merge({"right_after": types[RIGHT], "flags_after": flags[FACE],
		"right_phi_after": phi[RIGHT], "extended_velocity": velocity[FACE], "finite": finite})


static func run_apic_film_current(tree: SceneTree, check: Callable) -> void:
	const DX := 0.125
	const SPACING := 0.05
	const DT := 1.0 / 60.0
	const SPEED := 0.8
	var seed := PackedFloat32Array()
	for z in 60:
		for x in 60:
			seed.append_array([(float(x) + 0.5) * SPACING, 0.475,
				(float(z) + 0.5) * SPACING, 0.0])
	var solver := ApicFluidSolver.new()
	solver.config.domain_origin = Vector3.ZERO
	solver.config.domain_size_m = Vector3.ONE * 3.0
	solver.config.default_particle_count = 3600
	solver.config.particle_counts = [3600]
	solver.config.texture_width = 60
	solver.particle_count = 3600
	solver.active_count = 3600
	solver.spacing = SPACING
	solver.grid_cell_size_m = DX
	solver.collision_inflation = 0.0
	solver.gravity = Vector3(0.0, -9.81, 0.0)
	solver.substeps = 1
	solver.free_surface_cut_cells = true
	solver.set_seed_positions(seed)
	var phi := PackedFloat32Array()
	phi.resize(24 * 24 * 24)
	for z in 24:
		for y in 24:
			for x in 24:
				phi[(z * 24 + y) * 24 + x] = (float(y) + 0.5) * DX - 0.5
	solver.set_seed_levelset(phi)
	solver.set_scene_obstacles([{
		transform = Transform3D(Basis.IDENTITY, Vector3(1.5, 0.225, 1.5)),
		size = Vector3(3.0, 0.45, 3.0), retention = 1.0,
	}])
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	if not solver.initialized:
		check.call(false, "APIC film current: solver failed to initialize")
		RenderingServer.call_on_render_thread(solver.free_render)
		await RenderingServer.frame_post_draw
		return
	var result := {}
	RenderingServer.call_on_render_thread(_step_apic_film_current_render.bind(solver, result, DT, SPEED))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC FILM CURRENT scenario=flat_subgrid_film_divergence_free_vortex seed=0 domain_m=3.000 active_bounds_xz_m=(0.000,3.000) floor_top_y_m=0.450 water_level_m=0.500 film_thickness_m=0.050 dx_m=%.6f particle_spacing_m=%.6f particles=%d particle_volume_m3=%.9f requested_velocity_scale_m_s=%.6f velocity_profile=(S*sin(k*x)*cos(k*z),0,-S*cos(k*x)*sin(k*z)) k_m_inv=pi/3 local_xz_origin_m=0 closed_wall_normal_velocity_m_s=0 requested_dt_s=%.9f applied_dt_s=%.9f physical_time_s=%.9f state_revision=%d substeps=%d core_bounds_xz_m=(1.000,2.000) core_particles=%d expected_core_speed_mean_m_s=%.9f applied_core_speed_mean_m_s=%.9f core_velocity_max_error_m_s=%.9f core_vertical_speed_max_m_s=%.9f core_displacement_max_error_m=%.9f fluid_cells=%d finite=%s memory_bytes=%d gpu_timing=unavailable" % [
		DX, SPACING, solver.live_count(), float(solver.live_count()) * pow(SPACING, 3.0), SPEED,
		DT, solver.last_step_dt_s, solver._sim_time, solver._frame, solver.last_substeps,
		int(result.get("core_particles", 0)), float(result.get("expected_mean_speed", INF)),
		float(result.get("mean_speed", INF)),
		float(result.get("velocity_error", INF)), float(result.get("cross_speed", INF)),
		float(result.get("displacement_error", INF)), int(result.get("fluid_cells", -1)),
		str(bool(result.get("finite", false))), solver.get_gpu_memory_bytes()])
	check.call(bool(result.get("finite", false)) and int(result.get("core_particles", 0)) >= 100
		and absf(solver._sim_time - DT) <= 1.0e-7 and solver._frame == 1,
		"APIC film current: invalid state or physical clock")
	check.call(float(result.get("velocity_error", INF)) <= SPEED * 0.05
		and float(result.get("cross_speed", INF)) <= SPEED * 0.05
		and float(result.get("displacement_error", INF)) <= SPEED * DT * 0.05,
		"APIC film current: subgrid liquid lost its tangential current")
	print("BREAKER APIC FILM CURRENT volume expected_m3=0.450000000 initial_m3=%.9f final_m3=%.9f phi_max_change_m=%.9f max_particle_vertical_speed_m_s=%.9f volume_state=%s projection=%s" % [
		float(result.get("initial_volume_m3", INF)), float(result.get("final_volume_m3", INF)),
		float(result.get("phi_max_change", INF)), float(result.get("max_vertical_speed", INF)),
		str(result.get("volume_state", "unavailable")),
		str(result.get("projection", "unavailable"))])
	check.call(absf(float(result.get("initial_volume_m3", INF)) - 0.45) <= 1.0e-5
		and absf(float(result.get("final_volume_m3", INF)) - 0.45) <= 1.0e-5,
		"APIC film current: cut-cell field created or lost liquid volume")
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw


static func _step_apic_film_current_render(solver: ApicFluidSolver, result: Dictionary,
		dt: float, speed: float) -> void:
	var initial_velocity := PackedFloat32Array()
	initial_velocity.resize(solver.live_count() * 4)
	var affine := PackedFloat32Array()
	affine.resize(solver.live_count() * 12)
	var k := PI / 3.0
	for particle in solver.live_count():
		var x := k * solver._seed_data[particle * 4]
		var z := k * solver._seed_data[particle * 4 + 2]
		initial_velocity[particle * 4] = speed * sin(x) * cos(z)
		initial_velocity[particle * 4 + 2] = -speed * cos(x) * sin(z)
		initial_velocity[particle * 4 + 3] = float(particle)
		affine[particle * 12] = speed * k * cos(x) * cos(z)
		affine[particle * 12 + 2] = -speed * k * sin(x) * sin(z)
		affine[particle * 12 + 8] = speed * k * sin(x) * sin(z)
		affine[particle * 12 + 10] = -speed * k * cos(x) * cos(z)
	var bytes := initial_velocity.to_byte_array()
	solver._rd.buffer_update(solver._buffers.velocities_a, 0, bytes.size(), bytes)
	var affine_bytes := affine.to_byte_array()
	solver._rd.buffer_update(solver._buffers.affine_rows, 0, affine_bytes.size(), affine_bytes)
	var initial_volume := _apic_volume_diagnostics(solver)
	solver.step_render(dt)
	var final_volume := _apic_volume_diagnostics(solver)
	var positions := solver._rd.buffer_get_data(solver._buffers.positions_a).to_float32_array()
	var velocities := solver._rd.buffer_get_data(solver._buffers.velocities_a).to_float32_array()
	var types := solver._rd.buffer_get_data(solver._buffers.cell_types).to_int32_array()
	var core := 0
	var sum_speed := 0.0
	var sum_expected_speed := 0.0
	var velocity_error := 0.0
	var cross_speed := 0.0
	var displacement_error := 0.0
	var finite := true
	var max_vertical_speed := 0.0
	for particle in solver.live_count():
		var offset := particle * 4
		var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
		var v := Vector3(velocities[offset], velocities[offset + 1], velocities[offset + 2])
		finite = finite and p.is_finite() and v.is_finite()
		max_vertical_speed = maxf(max_vertical_speed, absf(v.y))
		var initial := Vector3(solver._seed_data[offset], solver._seed_data[offset + 1], solver._seed_data[offset + 2])
		if initial.x < 1.0 or initial.x > 2.0 or initial.z < 1.0 or initial.z > 2.0:
			continue
		core += 1
		var expected_velocity := Vector3(initial_velocity[offset], 0.0, initial_velocity[offset + 2])
		sum_speed += v.length()
		sum_expected_speed += expected_velocity.length()
		velocity_error = maxf(velocity_error, (v - expected_velocity).length())
		cross_speed = maxf(cross_speed, absf(v.y))
		displacement_error = maxf(displacement_error, (p - initial - expected_velocity * dt).length())
	var phi := solver._rd.buffer_get_data(solver._buffers.cell_phi).to_float32_array()
	var phi_max_change := 0.0
	for cell in phi.size():
		phi_max_change = maxf(phi_max_change, absf(phi[cell] - solver._seed_levelset[cell]))
	result.merge({"core_particles": core, "mean_speed": sum_speed / float(maxi(core, 1)),
		"expected_mean_speed": sum_expected_speed / float(maxi(core, 1)),
		"velocity_error": velocity_error, "cross_speed": cross_speed,
		"displacement_error": displacement_error, "finite": finite,
		"fluid_cells": types.count(1),
		"initial_volume_m3": initial_volume.planar_cell_volume_estimate_m3,
		"final_volume_m3": final_volume.planar_cell_volume_estimate_m3,
		"phi_max_change": phi_max_change, "max_vertical_speed": max_vertical_speed,
		"volume_state": final_volume,
		"projection": solver.get_diagnostics()})


static func run_apic_surface_boot(tree: SceneTree, check: Callable, conservative_surface: bool = false,
		geometric_surface: bool = false, fine_grid: bool = false, include_rock: bool = true,
		bed_slope: float = BED_SLOPE) -> void:
	if not is_equal_approx(bed_slope, BED_SLOPE) and not include_rock:
		check.call(false, "APIC surface boot: requested slope/grid/rock combination has no declared validation scene")
		return
	var scene_path := "res://scenes/ocean_breaker_apic_surface_sub3_validation.tscn" if conservative_surface else "res://scenes/ocean_breaker_apic_surface_validation.tscn"
	if geometric_surface:
		scene_path = "res://scenes/ocean_breaker_apic_surface_sub1_validation.tscn"
		if is_equal_approx(bed_slope, 1.0 / 15.0):
			scene_path = "res://scenes/ocean_breaker_apic_surface_plunging_grid_validation.tscn" if fine_grid else "res://scenes/ocean_breaker_apic_surface_plunging_validation.tscn"
		elif fine_grid:
			scene_path = "res://scenes/ocean_breaker_apic_surface_grid_validation.tscn"
		elif not include_rock:
			scene_path = "res://scenes/ocean_breaker_apic_surface_no_rock_validation.tscn"
	var packed_scene: PackedScene = load(scene_path)
	var demo = packed_scene.instantiate()
	demo.set_frozen(true)
	tree.root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await RenderingServer.frame_post_draw
		if demo.capture_ready() and demo.solver != null and demo.solver.initialized:
			break
	if not demo.capture_ready() or demo.solver == null or not demo.solver.initialized:
		check.call(false, "APIC surface boot: production validation scene did not reach ready state")
		demo.queue_free()
		await tree.process_frame
		await RenderingServer.frame_post_draw
		return
	var solver: ApicFluidSolver = demo.solver
	check.call(solver.conservative_amount_tracking == conservative_surface
		and solver.conservative_surface_reconstruction == conservative_surface
		and solver.amount_transport_order == demo.apic_amount_transport_order
		and solver.interface_distance_max_iterations == demo.apic_interface_distance_max_iterations
		and solver.amount_geometric_full_cell_flux == demo.apic_geometric_surface
		and solver.pressure_surface_from_volume_planes == demo.apic_geometric_surface
		and solver.flip_velocity_fraction == demo.apic_flip_velocity_fraction
		and solver.pressure_iterations == demo.apic_pressure_iterations
		and demo.include_rock == include_rock
		and is_equal_approx(demo.bed_slope, bed_slope)
		and solver.scene_obstacles.size() == (3 if include_rock else 2)
		and not solver.amount_geometric_split_transport
		and solver.substeps == (demo.apic_substeps if demo.apic_substeps > 0 else solver.substeps),
		"APIC surface boot: runtime amount, reconstruction or substep settings differ from the scene")
	print("BREAKER APIC SURFACE BOOT SETTINGS scene=%s conservative_amount_tracking=%s surface_controls_pressure=%s amount_transport_order=%d interface_distance_max_iterations=%d substeps=%d" % [
		scene_path, str(solver.conservative_amount_tracking), str(solver.conservative_surface_reconstruction), solver.amount_transport_order, solver.interface_distance_max_iterations, solver.substeps])
	print("BREAKER APIC SURFACE BOOT COUPLING geometric_flux=%s flux_plane_cache=%s volume_plane_pressure=%s geometric_split=%s flip_velocity_fraction=%.6f" % [
		str(solver.amount_geometric_full_cell_flux), str(solver.amount_geometric_full_cell_flux and solver.amount_geometric_flux_cache), str(solver.pressure_surface_from_volume_planes), str(solver.amount_geometric_split_transport), solver.flip_velocity_fraction])
	var expected := _seed_levelset(solver.config, solver.spacing,
		demo.apic_grid_cell_size_m, demo.still_water)
	var result := {}
	RenderingServer.call_on_render_thread(_read_apic_surface_boot_render.bind(
		solver, expected, result, demo.still_water, demo.bed_slope))
	await RenderingServer.frame_post_draw
	print("BREAKER APIC SURFACE BOOT scene=production_validation_without_capture_harness free_surface_cut_cells=%s solid_cut_cells=%s partial_solid_cells=%d grid=%s spacing_m=%.3f dx_m=%.3f samples=%s physical_time_s=%.6f state_revision=%d levelset_sample_max_error_m=%.9f initial_texture_max_error_m=%.9f field_valid=%s geometry_ok=%s finite=%s memory_bytes=%d gpu_timing=unavailable" % [
		str(solver.free_surface_cut_cells), str(solver.solid_cut_cells), solver._solid_geometry_partial_cells, str(solver.grid_dims), solver.spacing,
		solver.grid_dx, str(result.get("samples", [])), solver._sim_time, solver._frame,
		float(result.get("levelset_error", INF)), float(result.get("texture_error", INF)),
		str(bool(result.get("field_valid", false))), str(bool(result.get("geometry_ok", false))),
		str(bool(result.get("finite", false))),
		solver.get_gpu_memory_bytes()])
	print("BREAKER APIC SURFACE BOOT missed_bed_cells=%d partial_bed_cells=%d open_anchor_penetration_m=%.9f volume_state=%s" % [
		int(result.get("missed_bed_cells", -1)), int(result.get("partial_bed_cells", -1)),
		float(result.get("open_anchor_penetration_m", INF)), str(result.get("volume_state", {}))])
	check.call(solver.free_surface_cut_cells and solver.solid_cut_cells and solver._solid_geometry_partial_cells > 0 and bool(result.get("field_valid", false))
		and bool(result.get("geometry_ok", false)) and bool(result.get("finite", false)) and solver._frame == 0
		and is_equal_approx(solver._sim_time, 0.0)
		and float(result.get("levelset_error", INF)) <= 1.0e-6
		and float(result.get("texture_error", INF)) <= 1.0e-6,
		"APIC surface boot: production surface level set or initial particle texture differs from prescribed boot state")
	demo.queue_free()
	await tree.process_frame
	await RenderingServer.frame_post_draw


static func _read_apic_surface_boot_render(solver: ApicFluidSolver,
		expected: PackedFloat32Array, result: Dictionary, still_water: bool,
		bed_slope: float = BED_SLOPE) -> void:
	var field_valid: bool = solver._buffers.has("cell_phi") \
		and solver._buffers.cell_phi.is_valid() \
		and solver._rd.buffer_get_data(solver._buffers.cell_phi).size() == expected.size() * 4
	var field: PackedFloat32Array = solver._rd.buffer_get_data(
		solver._buffers.cell_phi).to_float32_array()
	var levelset_error := 0.0
	var finite := field.size() == expected.size()
	var samples: Array[Dictionary] = []
	var geometry_ok := true
	var dims: Vector3i = solver.grid_dims
	var dx := solver.grid_dx
	var state := solver.read_volume_state_render()
	var solid_mask: PackedByteArray = state.solid_cell_mask
	var geometry: PackedFloat32Array = state.cell_geometry
	var missed_bed_cells := 0
	var partial_bed_cells := 0
	var anchor_penetration := 0.0
	for iz in dims.z:
		for iy in dims.y:
			for ix in dims.x:
				var world := solver.grid_origin + (Vector3(ix, iy, iz) + Vector3.ONE * 0.5) * dx
				var index := (iz * dims.y + iy) * dims.x + ix
				if world.y + 0.5 * dx < _bed_height(world.x - 0.5 * dx, bed_slope) - 1.0e-6 and solid_mask[index] == 0:
					missed_bed_cells += 1
				if solid_mask[index] == 0 and world.y < _bed_height(world.x, bed_slope):
					partial_bed_cells += 1
					var anchor := world + Vector3(geometry[index * 4], geometry[index * 4 + 1], geometry[index * 4 + 2])
					anchor_penetration = maxf(anchor_penetration, _bed_height(anchor.x, bed_slope) - anchor.y)
	geometry_ok = geometry_ok and missed_bed_cells == 0 and partial_bed_cells > 0 and anchor_penetration <= 1.0e-5
	result["partial_bed_cells"] = partial_bed_cells
	result["open_anchor_penetration_m"] = anchor_penetration
	var z: int = floori(float(dims.z) * 0.5)
	for target_x in [-8.0, 16.0]:
		var x := clampi(roundi((target_x - solver.grid_origin.x) / dx - 0.5), 1, dims.x - 2)
		var world_x := solver.grid_origin.x + (float(x) + 0.5) * dx
		var surface_y := 0.0 if still_water else _wave_eta(world_x)
		var below_y := clampi(int(floor((surface_y - solver.grid_origin.y) / dx - 0.5)),
			1, dims.y - 3)
		var above_y := below_y + 1
		for sample_y in [below_y, above_y]:
			var index: int = (z * dims.y + sample_y) * dims.x + x
			levelset_error = maxf(levelset_error, absf(field[index] - expected[index]))
			finite = finite and is_finite(field[index])
			geometry_ok = geometry_ok and ((sample_y == below_y and field[index] < 0.0)
				or (sample_y == above_y and field[index] >= 0.0))
			samples.append({"cell": Vector3i(x, sample_y, z),
				"world_x_m": world_x, "phi_m": field[index], "expected_phi_m": expected[index],
				"inside": field[index] < 0.0})
	var texture: PackedFloat32Array = solver._rd.texture_get_data(
		solver.get_position_tex_rid(), 0).to_float32_array()
	var texture_error := 0.0
	finite = finite and texture.size() >= solver._seed_data.size()
	for index in solver._seed_data.size():
		finite = finite and is_finite(texture[index])
		texture_error = maxf(texture_error, absf(texture[index] - solver._seed_data[index]))
	result.merge({"field_valid": field_valid, "finite": finite,
		"levelset_error": levelset_error, "texture_error": texture_error,
		"geometry_ok": geometry_ok,
		"samples": samples, "missed_bed_cells": missed_bed_cells,
		"volume_state": _apic_volume_diagnostics(solver)})


static func _linear_cell_liquid_fraction(phi_center: float, phi_span: Vector3) -> float:
	return ApicFluidSolver.CutGeometry.linear_liquid_fraction(phi_center, phi_span)


static func run_apic_volume_fraction_values(check: Callable) -> void:
	var cases: Array[float] = [
		_linear_cell_liquid_fraction(0.2, Vector3(1.0, 0.0, 0.0)),
		_linear_cell_liquid_fraction(2.0, Vector3(10.0, 0.0, 0.0)),
		_linear_cell_liquid_fraction(0.0, Vector3(1.0, 2.0, 3.0)),
		_linear_cell_liquid_fraction(0.25, Vector3(1.0, 1.0, 0.0)),
		_linear_cell_liquid_fraction(0.25, Vector3.ONE),
		_linear_cell_liquid_fraction(-0.25, Vector3.ONE),
		_linear_cell_liquid_fraction(0.1, Vector3.ZERO),
		_linear_cell_liquid_fraction(-0.1, Vector3.ZERO),
		_linear_cell_liquid_fraction(0.2, Vector3(1.0, 1.0e-9, 0.0)),
		_linear_cell_liquid_fraction(0.8, Vector3(4.0, 0.0, 0.0)),
		_linear_cell_liquid_fraction(1.0, Vector3.ONE * 4.0),
	]
	var expected: Array[float] = [0.3, 0.3, 0.5, 0.28125,
		0.3177083333333333, 0.6822916666666667, 0.0, 1.0, 0.3,
		0.3, 0.3177083333333333]
	var max_error := 0.0
	var finite := true
	for i in cases.size():
		finite = finite and is_finite(cases[i])
		max_error = maxf(max_error, absf(cases[i] - expected[i]))
	max_error = maxf(max_error, absf(cases[4] + cases[5] - 1.0))
	print("BREAKER APIC VOLUME FRACTION scenario=linear_cell_cube_cdf cases=%d finite=%s max_error=%.12f expected_axis=0.300000000000 scaled_axis=0.300000000000 centered=0.500000000000 expected_2d=0.281250000000 expected_3d=0.317708333333 complement_sum=%.12f zero_span=(%.1f,%.1f) near_degenerate=%.12f" % [
		cases.size(), str(finite), max_error, cases[4] + cases[5], cases[6], cases[7], cases[8]])
	check.call(finite and max_error <= 1.0e-8,
		"APIC volume fraction: linear cube liquid fractions differ from analytic values")
