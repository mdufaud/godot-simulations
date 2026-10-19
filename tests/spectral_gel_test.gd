extends "res://tests/test_case.gd"

const COUNT := 256
const DT := 1.0 / 60.0

var _rd: RenderingDevice


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "Spectral Gel test has no RenderingDevice")
	if _rd == null:
		_finish("spectral_gel")
		return
	var gel := await _make_solver(3600.0, 256)
	await _step(gel, 1)
	var resting := await _read_state(gel)
	_check(_rms_error(resting, 0) < 0.001, "Spectral Gel drifted at rest")
	for transform in [1, 2]:
		var rigid := _pose(resting, transform)
		await _write_state(gel, rigid, resting.velocities)
		await _step(gel, 1)
		var moved := await _read_state(gel)
		_check(_rms_to_pose(moved, transform) < 0.002,
			"Spectral Gel produced force under a rigid translation or rotation")
		await _write_state(gel, _pose(moved, 0), moved.velocities)
		await _step(gel, 1)
		resting = await _read_state(gel)
	var elastic := await _make_solver(3600.0, COUNT)
	var control := await _make_solver(0.0, COUNT)
	var stretched := _pose(resting, 3)
	await _write_state(elastic, stretched, resting.velocities)
	await _write_state(control, stretched, resting.velocities)
	await _step(elastic, 90)
	await _step(control, 90)
	var elastic_state := await _read_state(elastic)
	var control_state := await _read_state(control)
	var start_error := _rms_error({"positions": stretched,
		"velocities": resting.velocities, "references": resting.references}, 0)
	var elastic_error := _rms_error(elastic_state, 0)
	var control_error := _rms_error(control_state, 0)
	_check(elastic_error < start_error * 0.8,
		"Spectral Gel stretch did not recoil: %.4f -> %.4f" % [start_error, elastic_error])
	_check(control_error > start_error * 0.95,
		"Zero-stiffness control changed its stretched shape")
	_check(_finite(elastic_state) and _finite(control_state),
		"Spectral Gel stretch produced invalid or out-of-domain particles")
	await _check_respawn(elastic)
	await _free_solver(gel)
	await _free_solver(elastic)
	await _free_solver(control)
	var falling := await _make_solver(3600.0, 1)
	falling.gravity = Vector3(0.0, -9.8, 0.0)
	falling.collision_damping = 0.28
	var fall_state := await _read_state(falling)
	var fell := false
	var bounced := false
	for _i in 60:
		await _step(falling, 1)
		fall_state = await _read_state(falling)
		fell = fell or fall_state.positions[1] < 0.4
		if fall_state.positions[1] <= 0.12 and fall_state.velocities[1] > 0.05:
			bounced = true
	_check(fell and bounced and fall_state.positions[1] >= 0.019,
		"Spectral Gel did not fall, rebound from the floor, and remain in bounds")
	print("SPECTRAL GEL stretch start=%.4f elastic=%.4f control=%.4f bounce=%s" % [
		start_error, elastic_error, control_error, str(bounced)])
	await _free_solver(falling)
	_finish("spectral_gel")


func _make_solver(stiffness: float, count: int) -> SphFluidSolver:
	var solver := SphFluidSolver.new()
	solver.particle_count = count
	solver.active_count = count
	solver.material = FluidSystem.FluidKind.SPECTRAL_GEL
	solver.gravity = Vector3.ZERO
	solver.pressure_mult = 0.0
	solver.near_pressure_mult = 0.0
	solver.cohesion_strength = 0.0
	solver.viscosity_strength = 1.0
	solver.extension_strength = stiffness
	solver.substeps = 3
	solver.foam_enabled = false
	solver.config = FluidConfig.new()
	solver.config.default_particle_count = count
	solver.config.particle_counts = [count]
	solver.config.texture_width = 16 if count > 1 else 1
	solver.config.grid_dims = Vector3i(8, 8, 8)
	solver.config.grid_origin = Vector3(-1.0, 0.0, -1.0)
	solver.config.domain_origin = solver.config.grid_origin
	solver.config.domain_size_m = Vector3(2.0, 2.0, 2.0)
	solver.config.cell_size_m = 0.25
	var seed := PackedFloat32Array()
	seed.resize(count * 4)
	for i in count:
		seed[i * 4] = -0.42 + float(i % 8) * 0.12
		seed[i * 4 + 1] = 0.55 + float((i / 8) % 4) * 0.12
		seed[i * 4 + 2] = -0.42 + float(i / 32) * 0.12
	solver.set_seed_positions(seed)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	return solver


func _step(solver: SphFluidSolver, frames: int) -> void:
	for _i in frames:
		RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
		await RenderingServer.frame_post_draw


func _read_state(solver: SphFluidSolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_state_render.bind(solver, result))
	while not result.get("done", false):
		await process_frame
	return result


func _read_state_render(solver: SphFluidSolver, result: Dictionary) -> void:
	var parity := solver.current_parity()
	result.positions = _rd.buffer_get_data(solver.parity_positions_rid(parity)).to_float32_array()
	result.velocities = _rd.buffer_get_data(solver.parity_velocities_rid(parity)).to_float32_array()
	result.references = _rd.buffer_get_data(solver._buffers["gel_reference"]).to_float32_array()
	result.done = true


func _write_state(solver: SphFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(_write_state_render.bind(solver, positions, velocities))
	await RenderingServer.frame_post_draw


func _write_state_render(solver: SphFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array) -> void:
	var bytes := positions.to_byte_array()
	var velocity_bytes := velocities.to_byte_array()
	for suffix in ["a", "b"]:
		_rd.buffer_update(solver._buffers["positions_" + suffix], 0, bytes.size(), bytes)
		_rd.buffer_update(solver._buffers["predicted_" + suffix], 0, bytes.size(), bytes)
		_rd.buffer_update(solver._buffers["velocities_" + suffix], 0, velocity_bytes.size(), velocity_bytes)


func _pose(state: Dictionary, kind: int) -> PackedFloat32Array:
	var result: PackedFloat32Array = state.positions.duplicate()
	var count: int = state.positions.size() / 4
	for i in count:
		var id := int(round(state.velocities[i * 4 + 3]))
		var base := id * 4
		var x: float = state.references[base]
		var y: float = state.references[base + 1]
		var z: float = state.references[base + 2]
		if kind == 0:
			result[i * 4] = x
			result[i * 4 + 1] = y
			result[i * 4 + 2] = z
		elif kind == 1:
			result[i * 4] = x + 0.1
		elif kind == 2:
			result[i * 4] = x * cos(0.5) + z * sin(0.5)
			result[i * 4 + 2] = -x * sin(0.5) + z * cos(0.5)
		elif kind == 3:
			result[i * 4] = x * 1.3
			result[i * 4 + 1] = y
			result[i * 4 + 2] = z
	return result


func _rms_error(state: Dictionary, _unused: int) -> float:
	var count: int = int(state.positions.size() / 4)
	var sum := 0.0
	for i in count:
		var id := int(round(state.velocities[i * 4 + 3]))
		var base := id * 4
		for axis in 3:
			sum += pow(state.positions[i * 4 + axis] - state.references[base + axis], 2.0)
	return sqrt(sum / float(count))


func _rms_to_pose(state: Dictionary, kind: int) -> float:
	var expected := _pose(state, kind)
	var sum := 0.0
	for i in int(state.positions.size() / 4):
		for axis in 3:
			sum += pow(state.positions[i * 4 + axis] - expected[i * 4 + axis], 2.0)
	return sqrt(sum / float(state.positions.size() / 4))


func _check_respawn(solver: SphFluidSolver) -> void:
	var before := await _read_state(solver)
	var ids := [int(round(before.velocities[3])), int(round(before.velocities[7]))]
	var batch := PackedFloat32Array([0.3, 0.8, 0.3, 0.0, 0.42, 0.8, 0.3, 0.0])
	var result := {}
	RenderingServer.call_on_render_thread(_respawn_render.bind(solver, batch, result))
	while not result.get("done", false):
		await process_frame
	var after := await _read_state(solver)
	var changed := 0
	for id in COUNT:
		var offset := id * 4
		if id in ids:
			changed += 1
			_check(after.references[offset + 3] > before.references[offset + 3],
				"Respawn did not assign a fresh gel cohort")
		else:
			for axis in 4:
				_check(is_equal_approx(after.references[offset + axis], before.references[offset + axis]),
					"Respawn changed an unrelated gel reference")
	_check(changed == 2 and is_equal_approx(after.references[ids[0] * 4], batch[0])
		and is_equal_approx(after.references[ids[1] * 4], batch[4]),
		"Respawn did not reset gel references for recycled IDs")
	var seen := {}
	for i in COUNT:
		var id := int(round(after.velocities[i * 4 + 3]))
		seen[id] = int(seen.get(id, 0)) + 1
	_check(seen.size() == COUNT and seen.values().all(func(n): return n == 1),
		"Respawn or sorting changed stable particle IDs")


func _respawn_render(solver: SphFluidSolver, batch: PackedFloat32Array,
		result: Dictionary) -> void:
	solver.respawn_range(0, batch)
	result.done = true


func _finite(state: Dictionary) -> bool:
	for i in int(state.positions.size() / 4):
		var offset := i * 4
		var id: float = state.velocities[offset + 3]
		for axis in 3:
			if not is_finite(state.positions[offset + axis]) or not is_finite(state.velocities[offset + axis]):
				return false
			if absf(state.velocities[offset + axis]) > 100.0:
				return false
		if not is_finite(state.positions[offset + 3]) or not is_finite(id) \
				or id < 0.0 or id >= float(COUNT) or not is_equal_approx(id, round(id)):
			return false
		if absf(state.positions[offset]) > 1.0 or state.positions[offset + 1] < 0.0 \
				or state.positions[offset + 1] > 2.0 or absf(state.positions[offset + 2]) > 1.0:
			return false
	return true


func _free_solver(solver: SphFluidSolver) -> void:
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
