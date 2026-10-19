extends "res://tests/test_case.gd"

const COUNT := 256
const DT := 1.0 / 60.0

var _rd: RenderingDevice


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "Astral GPU test has no RenderingDevice")
	if _rd == null:
		_finish("astral_fluid")
		return
	var resting := await _make_solver(0.0, 0)
	await _step(resting, 3)
	var initial := await _read_state(resting)
	_check(_max_stress(initial.positions) < 0.05,
		"Astral resting particles developed stress without strain")
	var shear := _velocities(initial.positions, 1)
	await _write_state(resting, initial.positions, shear)
	await _step(resting, 12)
	var stressed := await _read_state(resting)
	var peak := _max_stress(stressed.positions)
	_check(peak > 0.5, "Astral opposing flow did not build stress: %f" % peak)
	var still := _velocities(stressed.positions, 0)
	await _write_state(resting, stressed.positions, still)
	await _step(resting, 60)
	var relaxed := await _read_state(resting)
	_check(_max_stress(relaxed.positions) < peak * 0.5,
		"Astral stress did not relax after strain stopped")
	await _free_solver(resting)

	var low := await _make_solver(0.0, 2)
	var high := await _make_solver(1.0, 2)
	await _step(low, 30)
	await _step(high, 30)
	var low_state := await _read_state(low)
	var high_state := await _read_state(high)
	var low_variance := _velocity_variance(low_state.velocities)
	var high_variance := _velocity_variance(high_state.velocities)
	_check(high_variance < low_variance * 0.8,
		"Astral high stress did not damp velocity variance faster: %.6f vs %.6f" % [
			high_variance, low_variance])
	_check(_finite_state(low_state) and _finite_state(high_state),
		"Astral particle state became non-finite or left the simulation domain")
	await _free_solver(low)
	await _free_solver(high)
	var moving := await _make_solver(1.0, 3)
	await _step(moving, 12)
	var moving_state := await _read_state(moving)
	var translation := 0.0
	for i in COUNT:
		translation += moving_state.velocities[i * 4]
	translation /= COUNT
	_check(translation > 0.45, "Astral high stress froze uniform translation: %f" % translation)
	await _free_solver(moving)
	print("ASTRAL stress_peak=%.4f relaxed=%.4f damping_variance_ratio=%.4f translation=%.4f" % [
		peak, _max_stress(relaxed.positions), high_variance / maxf(low_variance, 1e-8), translation])
	_finish("astral_fluid")


func _make_solver(stress: float, velocity_kind: int) -> SphFluidSolver:
	var solver := SphFluidSolver.new()
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.material = FluidSystem.FluidKind.ASTRAL
	solver.gravity = Vector3.ZERO
	solver.pressure_mult = 0.0
	solver.near_pressure_mult = 0.0
	solver.cohesion_strength = 0.0
	solver.foam_enabled = false
	solver.viscosity_strength = 0.25
	solver.substeps = 3
	solver.config = FluidConfig.new()
	solver.config.default_particle_count = COUNT
	solver.config.particle_counts = [COUNT]
	solver.config.texture_width = 16
	solver.config.grid_dims = Vector3i(8, 8, 8)
	solver.config.grid_origin = Vector3(-1.0, 0.0, -1.0)
	solver.config.domain_origin = solver.config.grid_origin
	solver.config.domain_size_m = Vector3(2.0, 2.0, 2.0)
	solver.config.cell_size_m = 0.25
	var positions := PackedFloat32Array()
	positions.resize(COUNT * 4)
	for i in COUNT:
		var x := i % 8
		var y := (i / 8) % 4
		var z := i / 32
		positions[i * 4] = -0.42 + float(x) * 0.12
		positions[i * 4 + 1] = 0.55 + float(y) * 0.12
		positions[i * 4 + 2] = -0.42 + float(z) * 0.12
		positions[i * 4 + 3] = stress
	solver.set_seed_positions(positions)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	var state := await _read_state(solver)
	if velocity_kind != 0:
		await _write_state(solver, state.positions,
			_velocities(state.positions, velocity_kind))
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
	result.done = true


func _write_state(solver: SphFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(_write_state_render.bind(solver, positions, velocities))
	await RenderingServer.frame_post_draw


func _write_state_render(solver: SphFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array) -> void:
	var position_bytes := positions.to_byte_array()
	var velocity_bytes := velocities.to_byte_array()
	for suffix in ["a", "b"]:
		_rd.buffer_update(solver._buffers["positions_" + suffix], 0, position_bytes.size(), position_bytes)
		_rd.buffer_update(solver._buffers["predicted_" + suffix], 0, position_bytes.size(), position_bytes)
		_rd.buffer_update(solver._buffers["velocities_" + suffix], 0, velocity_bytes.size(), velocity_bytes)


func _velocities(positions: PackedFloat32Array, kind: int) -> PackedFloat32Array:
	var velocities := PackedFloat32Array()
	velocities.resize(COUNT * 4)
	for i in COUNT:
		var x := positions[i * 4]
		var y := positions[i * 4 + 1]
		if kind == 3:
			velocities[i * 4] = 0.5
		elif kind == 1:
			velocities[i * 4] = 4.0 if x < 0.0 else -4.0
		else:
			velocities[i * 4] = -(y - 0.8) * 2.0
			velocities[i * 4 + 1] = (x + 0.0) * 2.0
		velocities[i * 4 + 3] = float(i)
	return velocities


func _max_stress(positions: PackedFloat32Array) -> float:
	var maximum := 0.0
	for i in COUNT:
		maximum = maxf(maximum, positions[i * 4 + 3])
	return maximum


func _velocity_variance(velocities: PackedFloat32Array) -> float:
	var mean := Vector3.ZERO
	for i in COUNT:
		mean += Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2])
	mean /= float(COUNT)
	var variance := 0.0
	for i in COUNT:
		var velocity := Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2])
		variance += velocity.distance_squared_to(mean)
	return variance / float(COUNT)


func _finite_state(state: Dictionary) -> bool:
	for i in COUNT:
		var x: float = state.positions[i * 4]
		var y: float = state.positions[i * 4 + 1]
		var z: float = state.positions[i * 4 + 2]
		var stress: float = state.positions[i * 4 + 3]
		if not is_finite(x) or not is_finite(y) or not is_finite(z) or not is_finite(stress):
			return false
		if x < -1.0 or x > 1.0 or y < 0.0 or y > 2.0 or z < -1.0 or z > 1.0:
			return false
		if stress < 0.0 or stress > 1.0:
			return false
	for value in state.velocities:
		if not is_finite(value):
			return false
	return true


func _free_solver(solver: SphFluidSolver) -> void:
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
