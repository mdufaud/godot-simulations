extends "res://tests/astral_fluid_test.gd"


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "Prismatic Slime test needs a RenderingDevice")
	if _rd == null:
		_finish("prismatic_slime")
		return
	var driven := await _make_solver(0.0, 0)
	await _step(driven, 3)
	var state := await _read_state(driven)
	_check(_max_stress(state.positions) < 0.01, "Resting slime became fluid without strain")
	for _i in 15:
		await _write_state(driven, state.positions, _velocities(state.positions, 1))
		await _step(driven, 1)
		state = await _read_state(driven)
	var peak := _max_stress(state.positions)
	_check(peak > 0.7, "Slime did not thin under sustained strain: %f" % peak)
	await _write_state(driven, state.positions, _velocities(state.positions, 0))
	await _step(driven, 180)
	var relaxed := await _read_state(driven)
	var recovered := _max_stress(relaxed.positions)
	_check(recovered < peak * 0.15, "Slime did not recover after strain stopped")
	_check(_finite_state(relaxed), "Slime became non-finite or left the domain")
	await _free_solver(driven)

	var thick := await _make_solver(0.0, 2)
	var thin := await _make_solver(1.0, 2)
	await _step(thick, 12)
	await _step(thin, 12)
	var thick_state := await _read_state(thick)
	var thin_state := await _read_state(thin)
	var ratio := _velocity_variance(thin_state.velocities) / maxf(_velocity_variance(thick_state.velocities), 1e-8)
	_check(ratio > 1.5, "Thinned slime did not flow more freely: %f" % ratio)
	_check(_finite_state(thick_state) and _finite_state(thin_state), "Slime damping became unstable")
	await _free_solver(thick)
	await _free_solver(thin)

	var moving := await _make_solver(0.0, 3)
	await _step(moving, 12)
	var translation := await _read_state(moving)
	_check(_max_stress(translation.positions) < 0.01, "Uniform translation incorrectly thinned slime")
	var speed := 0.0
	for i in COUNT:
		speed += translation.velocities[i * 4] / float(COUNT)
	_check(speed > 0.45, "Thick slime froze uniform bulk motion")
	await _free_solver(moving)
	print("PRISMATIC SLIME strain=%.4f recovered=%.4f flow_variance_ratio=%.4f translation=%.4f" % [
		peak, recovered, ratio, speed])
	_finish("prismatic_slime")


func _make_solver(stress: float, velocity_kind: int) -> SphFluidSolver:
	var solver := await super._make_solver(stress, velocity_kind)
	solver.material = FluidSystem.FluidKind.PRISMATIC_SLIME
	solver.viscosity_strength = FluidMaterial.for_kind(solver.material).viscosity
	return solver


func _velocities(positions: PackedFloat32Array, kind: int) -> PackedFloat32Array:
	if kind != 0:
		return super._velocities(positions, kind)
	var still := PackedFloat32Array()
	still.resize(COUNT * 4)
	for i in COUNT:
		still[i * 4 + 3] = float(i)
	return still
