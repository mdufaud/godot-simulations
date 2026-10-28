extends "res://tests/test_case.gd"
## GPU gates of ClothSolver: a sheet hanging from two corners at the Medium tier
## stretches under 8 % with inextensible edges and less than without them,
## pinned vertices stay exactly where they were seeded, and the sheet neither
## sinks into the ground nor into the boulder.

const SPACING := 0.06
const STEPS := 120


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		_check(false, "no RenderingDevice")
		_finish("cloth_gpu")
		return
	await _hanging_case()
	await _ground_case()
	await _sphere_case()
	_finish("cloth_gpu")


func _sheet(w: int, h: int, origin: Vector3, pinned: Array[Vector2i]) -> ClothSolver:
	var solver := ClothSolver.new()
	var values := ClothQualityProfile.values(SimQualityProfile.Tier.MEDIUM)
	solver.iterations = values.iterations
	solver.substeps = values.substeps
	solver.grid_w = w
	solver.grid_h = h
	solver.rest_spacing = SPACING
	solver.wind_enabled = false
	var seed := PackedFloat32Array()
	for y in h:
		for x in w:
			var p := origin + Vector3(x * SPACING, 0.0, y * SPACING)
			seed.append_array([p.x, p.y, p.z, 1.0 if Vector2i(x, y) in pinned else 0.0])
	solver.set_seed(seed)
	return solver


func _simulate(solver: ClothSolver) -> PackedFloat32Array:
	RenderingServer.call_on_render_thread(solver.init_render)
	for i in STEPS:
		RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
		await process_frame
	var out: Array[PackedFloat32Array] = [PackedFloat32Array()]
	var done := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		out[0] = solver._rd.buffer_get_data(solver._buffers["positions"]).to_float32_array()
		solver.free_render()
		done.post())
	done.wait()
	var finite := true
	for value in out[0]:
		finite = finite and is_finite(value)
	_check(finite, "cloth positions not finite")
	return out[0]


func _point(positions: PackedFloat32Array, i: int) -> Vector3:
	return Vector3(positions[i * 4], positions[i * 4 + 1], positions[i * 4 + 2])


func _max_strain(solver: ClothSolver, positions: PackedFloat32Array) -> float:
	var strain := 0.0
	for y in solver.grid_h:
		for x in solver.grid_w:
			var a := _point(positions, y * solver.grid_w + x)
			if x + 1 < solver.grid_w:
				strain = maxf(strain, a.distance_to(_point(positions, y * solver.grid_w + x + 1))
					/ SPACING - 1.0)
			if y + 1 < solver.grid_h:
				strain = maxf(strain, a.distance_to(_point(positions, (y + 1) * solver.grid_w + x))
					/ SPACING - 1.0)
	return strain


func _hanging_case() -> void:
	var origin := Vector3(-0.9, 2.5, 0.0)
	var pins: Array[Vector2i] = [Vector2i(0, 0), Vector2i(31, 0)]
	var strains := {}
	for inextensible in [false, true]:
		var solver := _sheet(32, 24, origin, pins)
		solver.inextensible = inextensible
		var positions := await _simulate(solver)
		strains[inextensible] = _max_strain(solver, positions)
		if inextensible:
			for pin in pins:
				var seeded := origin + Vector3(pin.x * SPACING, 0.0, pin.y * SPACING)
				var p := _point(positions, pin.y * solver.grid_w + pin.x)
				_check(p.is_equal_approx(seeded), "pin moved: %s -> %s" % [seeded, p])
	print("CLOTH GPU hanging strain springs=%.4f inextensible=%.4f" % [strains[false],
		strains[true]])
	_check(strains[true] < strains[false], "inextensible edges stretch more than springs")
	_check(strains[true] < 0.08, "inextensible sheet stretched %.4f" % strains[true])


func _ground_case() -> void:
	var solver := _sheet(24, 24, Vector3(-0.7, 0.3, -0.7), [])
	var positions := await _simulate(solver)
	var lowest := INF
	for i in solver.vertex_count():
		lowest = minf(lowest, _point(positions, i).y)
	print("CLOTH GPU ground lowest=%.4f" % lowest)
	_check(lowest > -0.002, "cloth sank into the ground: %.4f" % lowest)


func _sphere_case() -> void:
	var solver := _sheet(24, 24, Vector3(-0.7, 1.2, -0.7), [])
	solver.sphere_center = Vector3(0.0, 0.5, 0.0)
	solver.sphere_radius = 0.4
	var positions := await _simulate(solver)
	var nearest := INF
	for i in solver.vertex_count():
		nearest = minf(nearest, _point(positions, i).distance_to(solver.sphere_center))
	print("CLOTH GPU sphere nearest=%.4f" % nearest)
	_check(nearest > solver.sphere_radius - 0.01,
		"cloth sank into the sphere: %.4f" % nearest)
