extends "res://tests/test_case.gd"
## GPU gates of SoftBodySolver: a block resting on the floor settles and stays
## put, a dropped nearly incompressible block keeps its volume and does not sink
## into the floor, stiffer material sags less, a grabbed vertex follows the
## mouse spring, and the colliders push back on the body and report the force.

const SETTLE_STEPS := 240


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		_check(false, "no RenderingDevice")
		_finish("softbody_gpu")
		return
	await _rest_case()
	await _drop_case()
	await _stiffness_case()
	await _grab_case()
	await _collider_case()
	await _static_box_case()
	await _stack_case()
	_finish("softbody_gpu")


func _box(youngs_modulus_pa: float, height_m: float) -> SoftBodyShape:
	var shape := SoftBodyShape.new()
	shape.size_m = Vector3(0.4, 0.4, 0.4)
	shape.position_m = Vector3(0.0, height_m, 0.0)
	shape.youngs_modulus_pa = youngs_modulus_pa
	return shape


func _solver(shapes: Array[SoftBodyShape]) -> SoftBodySolver:
	var solver := SoftBodySolver.new()
	solver.config.lattice_cell_m = 0.08
	for shape in shapes:
		solver.add_body(shape, true)
	return solver


func _start(solver: SoftBodySolver) -> bool:
	var error := solver.start()
	_check(error == "", "solver did not start: %s" % error)
	var deadline := Time.get_ticks_msec() + 10000
	while not solver.is_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(solver.is_ready(), "solver never became ready")
	return solver.is_ready()


func _steps(solver: SoftBodySolver, count: int) -> void:
	for i in count:
		solver.advance(1)
		await process_frame


func _stats(solver: SoftBodySolver, body: int) -> Dictionary:
	var positions := solver.read_positions()
	var lattice := solver.body_lattice(body)
	var offset := solver.body_offset(body)
	var low := INF
	var high := -INF
	var center := Vector3.ZERO
	var axis_top := -INF
	var finite := true
	for v in lattice.vertex_count():
		var i := (offset + v) * 4
		var p := Vector3(positions[i], positions[i + 1], positions[i + 2])
		finite = finite and p.is_finite()
		low = minf(low, p.y)
		high = maxf(high, p.y)
		if Vector2(p.x, p.z).length() < 0.06:
			axis_top = maxf(axis_top, p.y)
		center += p
	var volume := 0.0
	for tet in lattice.tet_count():
		var x := []
		for corner in 4:
			var i := (offset + lattice.tets[tet * 4 + corner]) * 4
			x.append(Vector3(positions[i], positions[i + 1], positions[i + 2]))
		volume += (x[1] - x[0]).dot((x[2] - x[0]).cross(x[3] - x[0])) / 6.0
	return {low = low, high = high, axis_top = axis_top, center = center / lattice.vertex_count(),
		volume_ratio = volume / lattice.volume(), finite = finite}


func _rest_case() -> void:
	var solver := _solver([_box(50000.0, 0.2)])
	if not await _start(solver):
		return
	await _steps(solver, SETTLE_STEPS)
	var settled := _stats(solver, 0)
	await _steps(solver, 60)
	var later := _stats(solver, 0)
	var drift: float = settled.center.distance_to(later.center)
	print("SOFTBODY GPU rest drift=%.5f m low=%.4f top=%.4f" % [drift, later.low, later.high])
	_check(later.finite, "rest: NaN in positions")
	_check(drift < 0.001, "rest: block still drifting %.4f m per second" % drift)
	_check(later.low > -0.01, "rest: block sank %.4f m into the floor" % -later.low)
	solver.stop()


func _drop_case() -> void:
	var solver := _solver([_box(50000.0, 1.0)])
	solver.config.poisson_ratio = 0.45
	if not await _start(solver):
		return
	var low := INF
	var worst := 0.0
	var settled := 0.0
	for i in SETTLE_STEPS / 10:
		await _steps(solver, 10)
		var stats := _stats(solver, 0)
		low = minf(low, stats.low)
		worst = maxf(worst, absf(stats.volume_ratio - 1.0))
		settled = absf(stats.volume_ratio - 1.0)
	print("SOFTBODY GPU drop lowest=%.4f worst volume error=%.3f settled=%.3f" % [low, worst,
		settled])
	# The impact frame compresses an under-converged nu = 0.45 solve; at rest it holds.
	_check(worst < 0.1, "drop: volume changed by %.1f%% on impact" % (worst * 100.0))
	_check(settled < 0.03, "drop: settled volume off by %.1f%%" % (settled * 100.0))
	_check(low > -0.01, "drop: block went %.4f m into the floor" % -low)
	solver.stop()


func _stiffness_case() -> void:
	var tops := []
	for modulus in [8000.0, 30000.0, 120000.0]:
		var solver := _solver([_box(modulus, 0.2)])
		if not await _start(solver):
			return
		await _steps(solver, SETTLE_STEPS)
		tops.append(_stats(solver, 0).high)
		solver.stop()
	print("SOFTBODY GPU sag tops=%s" % [tops])
	_check(tops[0] < tops[1] and tops[1] < tops[2], "sag is not monotone in stiffness")
	_check(tops[0] < 0.39, "soft block barely sagged: top %.3f m" % tops[0])


func _grab_case() -> void:
	var solver := _solver([_box(50000.0, 0.2)])
	if not await _start(solver):
		return
	await _steps(solver, 60)
	var positions := solver.read_positions()
	var vertex := solver.nearest_vertex(positions, Vector3(0.0, 2.0, 0.0), Vector3.DOWN, 0.1)
	_check(vertex >= 0, "grab: no vertex under the ray")
	if vertex < 0:
		solver.stop()
		return
	var start := Vector3(positions[vertex * 4], positions[vertex * 4 + 1], positions[vertex * 4 + 2])
	var target := start + Vector3(0.0, 0.4, 0.0)
	solver.set_grab(vertex, target)
	await _steps(solver, 60)
	positions = solver.read_positions()
	var held := Vector3(positions[vertex * 4], positions[vertex * 4 + 1], positions[vertex * 4 + 2])
	print("SOFTBODY GPU grab start=%.3f held=%.3f target=%.3f" % [start.distance_to(target),
		held.distance_to(target), 0.0])
	_check(held.distance_to(target) < 0.5 * start.distance_to(target),
		"grab: vertex did not follow the spring")
	solver.stop()


func _collider_case() -> void:
	var solver := _solver([_box(50000.0, 0.2)])
	if not await _start(solver):
		return
	await _steps(solver, 60)
	var top: float = _stats(solver, 0).high
	# A fixed dynamic sphere pressed 5 cm into the top face.
	var center := Vector3(0.0, top + 0.15 - 0.05, 0.0)
	solver.set_colliders(SoftBodySolver.pack_collider(SoftBodySolver.COLLIDER_SPHERE,
		Transform3D(Basis.IDENTITY, center), Vector3(0.15, 0.0, 0.0), Vector3.ZERO,
		Vector3.ZERO, true))
	await _steps(solver, 120)
	var stats := _stats(solver, 0)
	var positions := solver.read_positions()
	var penetration := 0.0
	for v in solver.vertex_count():
		var p := Vector3(positions[v * 4], positions[v * 4 + 1], positions[v * 4 + 2])
		penetration = maxf(penetration, 0.15 - p.distance_to(center))
	var reaction := solver.reactions()
	var force := Vector3(reaction[0], reaction[1], reaction[2]) if reaction.size() >= 3 \
		else Vector3.ZERO
	print("SOFTBODY GPU collider axis top=%.3f penetration=%.4f force=%s" % [stats.axis_top,
		penetration, force])
	_check(stats.axis_top < top - 0.02, "collider: top did not give way")
	_check(penetration < 0.01, "collider: vertices %.4f m inside the sphere" % penetration)
	_check(force.y > 1.0 and absf(force.x) < 0.2 * force.y and absf(force.z) < 0.2 * force.y,
		"collider: reaction %s is not an upward push" % force)
	solver.stop()


func _static_box_case() -> void:
	var solver := _solver([_box(50000.0, 1.0)])
	if not await _start(solver):
		return
	# A 1 m step whose top sits at 0.5 m, under the block.
	solver.set_colliders(SoftBodySolver.pack_collider(SoftBodySolver.COLLIDER_BOX,
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.25, 0.0)), Vector3(0.5, 0.25, 0.5),
		Vector3.ZERO, Vector3.ZERO, false))
	await _steps(solver, SETTLE_STEPS)
	var stats := _stats(solver, 0)
	print("SOFTBODY GPU static box low=%.4f" % stats.low)
	_check(stats.low > 0.49, "static box: block went %.4f m into the step" % (0.5 - stats.low))
	solver.stop()


func _stack_case() -> void:
	var solver := _solver([_box(50000.0, 0.2), _box(50000.0, 0.7)])
	if not await _start(solver):
		return
	await _steps(solver, SETTLE_STEPS)
	var bottom := _stats(solver, 0)
	var top := _stats(solver, 1)
	var rise: float = top.center.y - bottom.center.y
	var slide: float = Vector2(top.center.x - bottom.center.x, top.center.z - bottom.center.z).length()
	print("SOFTBODY GPU stack rise=%.4f slide=%.4f" % [rise, slide])
	_check(rise > 0.36 and rise < 0.45, "stack: upper block sits %.3f m above the lower one" % rise)
	_check(slide < 0.05, "stack: upper block slid %.3f m off the lower one" % slide)
	solver.stop()
