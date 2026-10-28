extends "res://tests/test_case.gd"
## Value gates of the soft body core, headless: the lattice of every shape fills
## its analytic volume, its tetrahedra are positively oriented and coloured so no
## two vertices of one share a colour, lumped masses add up, the surface embedding
## has weights that sum to one and reproduce the rest surface, the solver's CSR
## adjacency and colour lists cover every vertex, and the configs validate.


func _initialize() -> void:
	for shape in _shapes():
		_lattice_case(shape)
		_embedding_case(shape)
	_solver_arrays_case()
	_validation_case()
	_finish("softbody")


func _shapes() -> Array[SoftBodyShape]:
	var box := SoftBodyShape.new()
	box.size_m = Vector3(0.6, 0.4, 0.5)
	var sphere := SoftBodyShape.new()
	sphere.kind = SoftBodyShape.Kind.SPHERE
	sphere.size_m = Vector3(0.35, 0.0, 0.0)
	var capsule := SoftBodyShape.new()
	capsule.kind = SoftBodyShape.Kind.CAPSULE
	capsule.size_m = Vector3(0.2, 0.9, 0.0)
	var torus := SoftBodyShape.new()
	torus.kind = SoftBodyShape.Kind.TORUS
	torus.size_m = Vector3(0.35, 0.15, 0.0)
	return [box, sphere, capsule, torus]


func _lattice_case(shape: SoftBodyShape) -> void:
	var name: String = SoftBodyShape.Kind.keys()[shape.kind]
	var lattice := TetLattice.build(shape, 0.05)
	var analytic := shape.analytic_volume_m3()
	var ratio := lattice.volume() / analytic
	print("SOFTBODY lattice %s vertices=%d tets=%d volume ratio=%.3f" % [name,
		lattice.vertex_count(), lattice.tet_count(), ratio])
	_check(absf(ratio - 1.0) <= 0.05, "%s lattice volume off by %.1f%%" % [name,
		(ratio - 1.0) * 100.0])
	var tet_volume := 0.0
	for tet in lattice.tet_count():
		var det := lattice.rest_edges(tet).determinant()
		_check(det > 0.0, "%s tetrahedron %d is inverted" % [name, tet])
		tet_volume += det / 6.0
		var seen := {}
		for corner in 4:
			var colour := lattice.colors[lattice.tets[tet * 4 + corner]]
			_check(not seen.has(colour), "%s tetrahedron %d repeats colour %d" % [name, tet, colour])
			seen[colour] = true
	_check(absf(tet_volume - lattice.volume()) < 1e-6 * maxf(tet_volume, 1.0),
		"%s lumped volume differs from the tetrahedra's" % name)
	var surface := 0
	for v in lattice.vertex_count():
		_check(lattice.colors[v] >= 0 and lattice.colors[v] < TetLattice.COLORS,
			"%s colour out of range" % name)
		surface += lattice.surface[v]
	_check(surface > 0 and surface < lattice.vertex_count(),
		"%s surface flags %d of %d" % [name, surface, lattice.vertex_count()])


func _embedding_case(shape: SoftBodyShape) -> void:
	var name: String = SoftBodyShape.Kind.keys()[shape.kind]
	var lattice := TetLattice.build(shape, 0.08)
	var arrays := shape.make_mesh().get_mesh_arrays()
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom := lattice.embed(points, arrays[Mesh.ARRAY_NORMAL])
	_check(custom[0].size() == points.size() * 4 and custom[1].size() == points.size() * 4,
		"%s embedding size" % name)
	var worst := INF
	var max_error := 0.0
	for i in points.size():
		var w := Vector3(custom[1][i * 4], custom[1][i * 4 + 1], custom[1][i * 4 + 2])
		worst = minf(worst, minf(1.0 - w.x - w.y - w.z, minf(w.x, minf(w.y, w.z))))
		var v := Vector4i(int(custom[0][i * 4]), int(custom[0][i * 4 + 1]),
			int(custom[0][i * 4 + 2]), int(custom[0][i * 4 + 3]))
		var x0 := lattice.rest[v.x]
		var ds := Basis(lattice.rest[v.y] - x0, lattice.rest[v.z] - x0, lattice.rest[v.w] - x0)
		max_error = maxf(max_error, (x0 + ds * w).distance_to(points[i]))
	print("SOFTBODY embed %s points=%d worst weight=%.3f" % [name, points.size(), worst])
	_check(max_error < 1e-4, "%s embedding misplaces a point by %.6f m" % [name, max_error])
	_check(worst > -1.0, "%s embedding extrapolates too far (%.3f)" % [name, worst])


func _solver_arrays_case() -> void:
	var solver := SoftBodySolver.new()
	solver.config.lattice_cell_m = 0.1
	var shapes := _shapes()
	for shape in shapes:
		solver.add_body(shape, true)
	solver.add_body(shapes[0], false)
	_check(solver.body_lattice(0) == solver.body_lattice(4), "same shape must share its lattice")
	var arrays := solver._build_arrays()
	var n := solver.vertex_count()
	var offsets: PackedInt32Array = arrays.adjacency_offsets.to_int32_array()
	var entries: PackedInt32Array = arrays.adjacency_entries.to_int32_array()
	var tets: PackedInt32Array = arrays.tets.to_int32_array()
	_check(offsets.size() == n + 1 and offsets[n] == tets.size(), "CSR offsets")
	var csr_ok := true
	for v in n:
		for a in range(offsets[v], offsets[v + 1]):
			csr_ok = csr_ok and tets[entries[a]] == v
	_check(csr_ok, "a CSR entry points at another vertex's corner")
	var colors: PackedInt32Array = arrays.color_vertices.to_int32_array()
	_check(colors.size() == n, "colour lists hold %d of %d vertices" % [colors.size(), n])
	var seen := PackedByteArray()
	seen.resize(n)
	for v in colors:
		seen[v] += 1
	_check(seen.count(1) == n, "a vertex is missing or repeated in the colour lists")
	var pc := solver.make_push_constants()
	_check(pc.size() == SoftBodySolver.PUSH_CONSTANT_BYTES, "push constant size")
	_check(pc.decode_s32(40) == n, "push constant vertex count")
	var velocities: PackedFloat32Array = arrays.velocities.to_float32_array()
	_check(int(velocities[solver.body_offset(4) * 4 + 3]) == 4, "velocity w carries the body")


func _validation_case() -> void:
	var config := SoftBodyConfig.new()
	_check(config.validate() == "", "default config must validate: %s" % config.validate())
	config.poisson_ratio = 0.5
	_check(config.validate() != "", "poisson 0.5 must be rejected")
	config = SoftBodyConfig.new()
	var lame := config.lame(1.0e5)
	_check(absf(lame.x - 1.0e5 / 2.8) < 1.0, "mu of E=1e5, nu=0.4")
	var capsule := SoftBodyShape.new()
	capsule.kind = SoftBodyShape.Kind.CAPSULE
	capsule.size_m = Vector3(0.3, 0.4, 0.0)
	_check(capsule.validate() != "", "capsule shorter than two radii must be rejected")
	for tier in 4:
		var values := SoftBodyQualityProfile.values(tier)
		var tiered := SoftBodyConfig.new()
		tiered.lattice_cell_m = values.lattice_cell_m
		tiered.substeps = values.substeps
		tiered.iterations = values.iterations
		tiered.max_bodies = values.max_bodies
		_check(tiered.validate() == "", "tier %d config invalid" % tier)
