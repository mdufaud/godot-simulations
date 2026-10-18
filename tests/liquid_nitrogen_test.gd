extends "res://tests/light_paste_test.gd"


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "Liquid nitrogen test needs a RenderingDevice")
	if _rd == null:
		_finish("liquid_nitrogen")
		return
	var solver := await _make_nitrogen()
	# The block lands at ~0.35 s; by 1.7 s its boil-off has had time to rise.
	await _step(solver, 100)
	var splash := await _read_state(solver)
	var splash_vapour := await _read_vapour(solver)
	_check(_finite_state(splash), "Nitrogen went non-finite")
	_check(splash_vapour.count > 200, "Impact did not boil: %d vapour" % splash_vapour.count)
	var lift: float = splash_vapour.top - _height(splash.positions)
	_check(lift > 0.3, "Vapour did not rise off the liquid: %.3f" % lift)
	# Past the longest vapour life, so only what the resting liquid sheds is left.
	await _step(solver, 320)
	var rest_vapour := await _read_vapour(solver)
	_check(rest_vapour.count * 3 < splash_vapour.count,
		"Resting nitrogen boils as hard as an impact: %d vs %d" % [rest_vapour.count, splash_vapour.count])
	await _free_solver(solver)
	print("LIQUID NITROGEN splash_vapour=%d rest_vapour=%d lift=%.3f" % [
		splash_vapour.count, rest_vapour.count, lift])
	_finish("liquid_nitrogen")


func _make_nitrogen() -> SphFluidSolver:
	var spec := FluidMaterial.for_kind(FluidSystem.FluidKind.LIQUID_NITROGEN)
	var solver := SphFluidSolver.new()
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.material = FluidSystem.FluidKind.LIQUID_NITROGEN
	solver.viscosity_strength = spec.viscosity
	solver.cohesion_strength = spec.cohesion
	solver.collision_damping = spec.collision_damping
	solver.foam_enabled = true
	solver.foam_tex_width = 64
	solver.foam_spawn_rate = 3.0
	solver.foam_spawn_fade_time = 0.0
	solver.foam_life_min = 2.0
	solver.foam_life_max = 5.0
	solver.foam_dissolve_time = 1.5
	solver.config = FluidConfig.new()
	solver.config.default_particle_count = COUNT
	solver.config.particle_counts = [COUNT]
	solver.config.texture_width = 32
	# A narrow tank keeps the liquid deep, so at rest only its top layer steams.
	solver.config.grid_dims = Vector3i(6, 16, 6)
	solver.config.grid_origin = Vector3(-0.75, 0.0, -0.75)
	solver.config.domain_origin = solver.config.grid_origin
	solver.config.domain_size_m = Vector3(1.5, 4.0, 1.5)
	solver.config.cell_size_m = 0.25
	var positions := PackedFloat32Array()
	positions.resize(COUNT * 4)
	for i in COUNT:
		positions[i * 4] = -0.54 + float(i % SIDE) * 0.12
		@warning_ignore("integer_division")
		positions[i * 4 + 1] = 0.6 + float((i / SIDE) % SIDE) * 0.12
		@warning_ignore("integer_division")
		positions[i * 4 + 2] = -0.54 + float(i / (SIDE * SIDE)) * 0.12
	solver.set_seed_positions(positions)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	return solver


func _read_vapour(solver: SphFluidSolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(func():
		var live := mini(_rd.buffer_get_data(solver._buffers["foam_count"]).to_int32_array()[0], solver.foam_cap())
		var data := _rd.buffer_get_data(solver._buffers["foam_pos"]).to_float32_array()
		var heights: Array[float] = []
		for i in live:
			heights.append(data[i * 4 + 1])
		heights.sort()
		result.count = live
		result.top = heights[int(live * 0.9)] if live > 0 else 0.0
		result.done = true)
	while not result.get("done", false):
		await process_frame
	return result
