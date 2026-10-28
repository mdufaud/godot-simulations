extends "res://tests/test_case.gd"

const SIDE := 10
const COUNT := SIDE * SIDE * SIDE
const DT := 1.0 / 60.0

var _rd: RenderingDevice


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "Light Paste test needs a RenderingDevice")
	if _rd == null:
		_finish("light_paste")
		return
	# Bingham yield stress in Pa, solved implicitly (sph_viscosity.comp); the
	# slider stops at 400 Pa, where the default sweep count still converges.
	var heights := {}
	var settled: SphFluidSolver
	var default_yield := FluidMaterial.for_kind(FluidSystem.FluidKind.LIGHT_PASTE).yield_stress
	for threshold in [0.0, 100.0, default_yield, 400.0]:
		var solver := await _make_solver(threshold, 0.06, true)
		await _step(solver, 180)
		var state := await _read_state(solver)
		_check(_finite_state(state), "Paste left the domain or went non-finite")
		heights[threshold] = _height(state.positions)
		if threshold == default_yield:
			_check(_mean_speed(state.velocities) < 0.01, "Paste pile never came to rest")
			settled = solver
		else:
			await _free_solver(solver)
	_check(heights[0.0] < 0.15, "Paste without yield did not flow flat: %.3f" % heights[0.0])
	_check(heights[default_yield] > 0.35, "Paste pile lost its relief: %.3f" % heights[default_yield])
	_check(heights[400.0] > heights[100.0] + 0.12, "Yield stress does not set the pile height: %s"
		% [heights])

	# A soft shove is resisted by the unyielded paste and its grip on the floor;
	# a hard one shears it past the yield and it flows.
	var rest := await _read_state(settled)
	await _write_state(settled, rest.positions, _uniform_velocities(Vector3(0.2, 0.0, 0.0)))
	await _step(settled, 6)
	var soft := _mean_velocity((await _read_state(settled)).velocities).x
	_check(absf(soft) < 0.02, "A push below the yield did not stop: %.3f" % soft)
	await _write_state(settled, rest.positions, _uniform_velocities(Vector3(4.0, 0.0, 0.0)))
	await _step(settled, 1)
	var hard := _mean_velocity((await _read_state(settled)).velocities).x
	_check(hard > 2.0, "A push above the yield did not flow: %.3f" % hard)
	await _free_solver(settled)

	var lump := await _make_solver(default_yield, 1.5, true)
	await _step(lump, 20)
	var fall := _mean_velocity((await _read_state(lump)).velocities).y
	_check(fall < -2.5, "Unsupported paste lump hovered: %.3f" % fall)
	await _free_solver(lump)

	var drifting := await _make_solver(default_yield, 1.4, false)
	var still := await _read_state(drifting)
	await _write_state(drifting, still.positions, _uniform_velocities(Vector3(0.5, 0.0, 0.0)))
	await _step(drifting, 12)
	var drift := _mean_velocity((await _read_state(drifting)).velocities).x
	_check(absf(drift - 0.5) < 0.001, "Paste froze uniform bulk translation: %.4f" % drift)
	await _free_solver(drifting)

	print("LIGHT PASTE heights=%s soft=%.4f hard=%.4f fall=%.4f drift=%.4f" % [
		heights, soft, hard, fall, drift])
	_finish("light_paste")


func _make_solver(threshold: float, base: float, falling: bool,
		kind := FluidSystem.FluidKind.LIGHT_PASTE) -> SphFluidSolver:
	var spec := FluidMaterial.for_kind(kind)
	var solver := SphFluidSolver.new()
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.material = kind
	solver.gravity = Vector3(0.0, -9.8, 0.0) if falling else Vector3.ZERO
	solver.foam_enabled = false
	solver.viscosity_strength = spec.viscosity
	solver.cohesion_strength = spec.cohesion
	solver.collision_damping = spec.collision_damping
	solver.extension_strength = spec.extension_strength
	solver.yield_stress = threshold
	solver.config = FluidConfig.new()
	solver.config.default_particle_count = COUNT
	solver.config.particle_counts = [COUNT]
	solver.config.texture_width = 32
	solver.config.grid_dims = Vector3i(24, 16, 24)
	solver.config.grid_origin = Vector3(-3.0, 0.0, -3.0)
	solver.config.domain_origin = solver.config.grid_origin
	solver.config.domain_size_m = Vector3(6.0, 4.0, 6.0)
	solver.config.cell_size_m = 0.25
	var positions := PackedFloat32Array()
	positions.resize(COUNT * 4)
	for i in COUNT:
		positions[i * 4] = -0.54 + float(i % SIDE) * 0.12
		@warning_ignore("integer_division")
		positions[i * 4 + 1] = base + float((i / SIDE) % SIDE) * 0.12
		@warning_ignore("integer_division")
		positions[i * 4 + 2] = -0.54 + float(i / (SIDE * SIDE)) * 0.12
	solver.set_seed_positions(positions)
	RenderingServer.call_on_render_thread(solver.init_render)
	await RenderingServer.frame_post_draw
	return solver


func _step(solver: SphFluidSolver, frames: int) -> void:
	for _i in frames:
		RenderingServer.call_on_render_thread(solver.step_render.bind(DT))
		await RenderingServer.frame_post_draw


func _read_state(solver: SphFluidSolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(func():
		var parity := solver.current_parity()
		result.positions = _rd.buffer_get_data(solver.parity_positions_rid(parity)).to_float32_array()
		result.velocities = _rd.buffer_get_data(solver.parity_velocities_rid(parity)).to_float32_array()
		result.done = true)
	while not result.get("done", false):
		await process_frame
	return result


func _write_state(solver: SphFluidSolver, positions: PackedFloat32Array,
		velocities: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(func():
		var position_bytes := positions.to_byte_array()
		var velocity_bytes := velocities.to_byte_array()
		for suffix in ["a", "b"]:
			_rd.buffer_update(solver._buffers["positions_" + suffix], 0, position_bytes.size(), position_bytes)
			_rd.buffer_update(solver._buffers["predicted_" + suffix], 0, position_bytes.size(), position_bytes)
			_rd.buffer_update(solver._buffers["velocities_" + suffix], 0, velocity_bytes.size(), velocity_bytes))
	await RenderingServer.frame_post_draw


func _uniform_velocities(velocity: Vector3) -> PackedFloat32Array:
	var velocities := PackedFloat32Array()
	velocities.resize(COUNT * 4)
	for i in COUNT:
		velocities[i * 4] = velocity.x
		velocities[i * 4 + 1] = velocity.y
		velocities[i * 4 + 2] = velocity.z
		velocities[i * 4 + 3] = float(i)
	return velocities


func _height(positions: PackedFloat32Array) -> float:
	var heights: Array[float] = []
	for i in COUNT:
		heights.append(positions[i * 4 + 1])
	heights.sort()
	return heights[int(COUNT * 0.95)]


func _mean_velocity(velocities: PackedFloat32Array) -> Vector3:
	var sum := Vector3.ZERO
	for i in COUNT:
		sum += Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2])
	return sum / float(COUNT)


func _mean_speed(velocities: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in COUNT:
		sum += Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2]).length()
	return sum / float(COUNT)


func _finite_state(state: Dictionary) -> bool:
	for value in state.positions:
		if not is_finite(value):
			return false
	for value in state.velocities:
		if not is_finite(value):
			return false
	for i in COUNT:
		var p := Vector3(state.positions[i * 4], state.positions[i * 4 + 1], state.positions[i * 4 + 2])
		if not AABB(Vector3(-3.0, 0.0, -3.0), Vector3(6.0, 4.0, 6.0)).grow(0.01).has_point(p):
			return false
	return true


func _free_solver(solver: SphFluidSolver) -> void:
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
