extends "res://tests/test_case.gd"
## GPU gates on the SPH solver's numerics, independent of any one material's look:
## the result of a physical setup must not depend on how many sub-steps the frame
## is cut into.

const SIDE := 10
const COUNT := SIDE * SIDE * SIDE
const SPACING := 0.12
const DT := 1.0 / 60.0

var _rd: RenderingDevice


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rd = RenderingServer.get_rendering_device()
	_check(_rd != null, "SPH consistency test needs a RenderingDevice")
	if _rd == null:
		_finish("sph_consistency")
		return
	await _test_viscous_column_is_substep_independent()
	await _test_viscosity_slider_is_stable()
	_finish("sph_consistency")


# A column of each viscous material settles in a box that fits it exactly, so
# only its pressure response sets the height. Viscosity damps relative motion;
# it must not eat the pressure push, whose share would then depend on the
# sub-step length (the old blend kept ~26% of it at 3 sub-steps, ~50% at 6).
func _test_viscous_column_is_substep_independent() -> void:
	for kind in [FluidSystem.FluidKind.HONEY, FluidSystem.FluidKind.ASTRAL,
			FluidSystem.FluidKind.SPECTRAL_GEL]:
		var heights: Array[float] = []
		for substeps in [2, 6]:
			var solver := await _make_column(kind, substeps)
			await _step(solver, 240)
			var state := await _read_state(solver)
			_check(_finite(state), "material %d went non-finite at %d sub-steps" % [kind, substeps])
			heights.append(_mean_height(state.positions))
			await _free_solver(solver)
		var spread := absf(heights[0] - heights[1]) / maxf(heights[1], 1e-6)
		print("SPH COLUMN material=%d mean_height(2 sub-steps)=%.4f mean_height(6)=%.4f spread=%.3f"
			% [kind, heights[0], heights[1], spread])
		_check(spread < 0.05, "material %d: settled column height depends on sub-steps (%s)"
			% [kind, str(heights)])


# Viscosity relaxes neighbours toward their mean velocity. Integrated explicitly it
# overshot once viscosity * sum(W) * dt passed 1 -- the Viscosity slider's top
# value (3.0) at the default 3 sub-steps gives ~8 -- and the column blew up to NaN.
# Stirred liquid at the slider maximum must settle like any other viscous fluid.
func _test_viscosity_slider_is_stable() -> void:
	for kind in [FluidSystem.FluidKind.WATER, FluidSystem.FluidKind.WATER_OIL,
			FluidSystem.FluidKind.MERCURY, FluidSystem.FluidKind.LIQUID_NITROGEN]:
		var solver := await _make_column(kind, 3, 3.0)
		var state := await _read_state(solver)
		var stirred: PackedFloat32Array = state.velocities.duplicate()
		var rng := RandomNumberGenerator.new()
		rng.seed = 99
		for i in COUNT:
			for c in 3:
				stirred[i * 4 + c] = rng.randf_range(-1.0, 1.0)
		await _write_velocities(solver, stirred)
		await _step(solver, 120)
		state = await _read_state(solver)
		var speed := _mean_speed(state.velocities)
		print("SPH VISCOSITY material=%d slider=3.0 substeps=3 mean_speed=%.4f" % [kind, speed])
		_check(_finite(state) and speed < 0.2,
			"material %d: viscosity at the slider maximum is unstable (%s m/s)"
				% [kind, str(speed)])
		await _free_solver(solver)


func _make_column(kind: int, substeps: int, viscosity := -1.0) -> SphFluidSolver:
	var spec := FluidMaterial.for_kind(kind)
	var solver := SphFluidSolver.new()
	solver.particle_count = COUNT
	solver.active_count = COUNT
	solver.material = kind
	solver.substeps = substeps
	solver.gravity = Vector3(0.0, -9.8, 0.0)
	solver.foam_enabled = false
	solver.viscosity_strength = spec.viscosity if viscosity < 0.0 else viscosity
	solver.cohesion_strength = spec.cohesion
	solver.collision_damping = spec.collision_damping
	solver.extension_strength = spec.extension_strength
	solver.yield_stress = 0.0
	solver.config = FluidConfig.new()
	solver.config.default_particle_count = COUNT
	solver.config.particle_counts = [COUNT]
	solver.config.texture_width = 32
	solver.config.grid_dims = Vector3i(8, 16, 8)
	solver.config.grid_origin = Vector3(-1.0, 0.0, -1.0)
	# The box fits the column: the block cannot spread, only compress.
	var half := 0.5 * SIDE * SPACING + 0.02
	solver.config.domain_origin = Vector3(-half, 0.0, -half)
	solver.config.domain_size_m = Vector3(2.0 * half, 4.0, 2.0 * half)
	solver.config.cell_size_m = 0.25
	var positions := PackedFloat32Array()
	positions.resize(COUNT * 4)
	for i in COUNT:
		positions[i * 4] = -0.54 + float(i % SIDE) * SPACING
		@warning_ignore("integer_division")
		positions[i * 4 + 1] = 0.06 + float((i / SIDE) % SIDE) * SPACING
		@warning_ignore("integer_division")
		positions[i * 4 + 2] = -0.54 + float(i / (SIDE * SIDE)) * SPACING
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


func _write_velocities(solver: SphFluidSolver, velocities: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(func():
		var bytes := velocities.to_byte_array()
		for parity in 2:
			_rd.buffer_update(solver.parity_velocities_rid(parity), 0, bytes.size(), bytes))
	await RenderingServer.frame_post_draw


func _mean_speed(velocities: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in COUNT:
		sum += Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2]).length()
	return sum / float(COUNT)


func _mean_height(positions: PackedFloat32Array) -> float:
	var sum := 0.0
	for i in COUNT:
		sum += positions[i * 4 + 1]
	return sum / float(COUNT)


func _finite(state: Dictionary) -> bool:
	for value in state.positions:
		if not is_finite(value):
			return false
	for value in state.velocities:
		if not is_finite(value):
			return false
	return true


func _free_solver(solver: SphFluidSolver) -> void:
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
