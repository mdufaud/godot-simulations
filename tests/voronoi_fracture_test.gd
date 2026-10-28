extends "res://tests/test_case.gd"

const VoronoiFractureScript := preload("res://scripts/destruction/voronoi_fracture.gd")


func _initialize() -> void:
	_test_seed_points_are_deterministic()
	_test_fracture_cells_match_seeds()
	_test_fracture_cells_are_exact()
	_finish("voronoi_fracture")


func _test_seed_points_are_deterministic() -> void:
	var size := Vector3(6.0, 4.0, 2.0)
	var rng_a := RandomNumberGenerator.new()
	var rng_b := RandomNumberGenerator.new()
	rng_a.seed = 987654
	rng_b.seed = 987654
	var points_a: PackedVector3Array = VoronoiFractureScript.seed_points(
		size, 12, Vector3(1.0, 0.5, 0.0), 0.7, rng_a)
	var points_b: PackedVector3Array = VoronoiFractureScript.seed_points(
		size, 12, Vector3(1.0, 0.5, 0.0), 0.7, rng_b)
	_check(points_a.size() == 12, "seed count")
	for i in points_a.size():
		_check(points_a[i].is_equal_approx(points_b[i]), "seed generation is deterministic")
		_check(absf(points_a[i].x) <= size.x * 0.5 + 1e-5, "seed outside x bounds")
		_check(absf(points_a[i].y) <= size.y * 0.5 + 1e-5, "seed outside y bounds")
		_check(absf(points_a[i].z) <= size.z * 0.5 + 1e-5, "seed outside z bounds")


func _test_fracture_cells_match_seeds() -> void:
	var size := Vector3(4.0, 2.0, 3.0)
	var seeds := PackedVector3Array([
		Vector3(-1.0, -0.4, -0.7),
		Vector3(1.0, -0.25, 0.6),
		Vector3(-0.8, 0.55, 0.8),
		Vector3(0.75, 0.5, -0.65),
	])
	var cells: Array = VoronoiFractureScript.fracture_box(size, seeds)
	_check(cells.size() == seeds.size(), "every seed produced a fracture cell")
	var seen := {}
	for cell_variant in cells:
		var cell: Dictionary = cell_variant
		var seed_index: int = cell.seed
		seen[seed_index] = true
		var center: Vector3 = cell.center
		var points: PackedVector3Array = cell.points
		_check(points.size() >= 4, "cell has a convex hull")
		_check((center - seeds[seed_index]).length() < 1.0,
			"cell center remains near its seed")
		for point in points:
			var world_point := point + center
			_check(absf(world_point.x) <= size.x * 0.5 + 1e-4, "cell point outside x bounds")
			_check(absf(world_point.y) <= size.y * 0.5 + 1e-4, "cell point outside y bounds")
			_check(absf(world_point.z) <= size.z * 0.5 + 1e-4, "cell point outside z bounds")
		var mesh: ArrayMesh = cell.mesh
		_check(mesh != null and mesh.get_surface_count() > 0, "cell has a surface mesh")
		for neighbour in cell.neighbours:
			_check(neighbour != seed_index and neighbour >= 0 and neighbour < seeds.size(),
				"cell neighbour index is valid")
	_check(seen.size() == seeds.size(), "all fracture seed indices are present")


# Every cell must be the true Voronoi cell: each of its vertices is at least as
# close to its own seed as to any other. Run at wall-like counts, where cells have
# more neighbours than the nearest-16 shortcut alone can clip.
func _test_fracture_cells_are_exact() -> void:
	var cases := [[Vector3(5.6, 4.0, 0.7), 110], [Vector3(5.0, 3.6, 0.18), 180],
		[Vector3(3.0, 3.0, 3.0), 120]]
	for case in cases:
		var size: Vector3 = case[0]
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x5EED_F00D
		var seeds: PackedVector3Array = VoronoiFractureScript.seed_points(
			size, case[1], Vector3.ZERO, 0.6, rng)
		var start := Time.get_ticks_usec()
		var cells: Array = VoronoiFractureScript.fracture_box(size, seeds)
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		var bad_vertices := 0
		for cell_variant in cells:
			var cell: Dictionary = cell_variant
			var own: Vector3 = seeds[cell.seed]
			for point in cell.points:
				var world: Vector3 = point + cell.center
				var own_d := world.distance_to(own)
				for other in seeds:
					if world.distance_to(other) + 1e-3 < own_d:
						bad_vertices += 1
						break
		_check(cells.size() == seeds.size(), "%s: every seed produced a cell" % size)
		_check(bad_vertices == 0,
			"%s with %d seeds: %d cell vertices lie inside another seed's cell" % [
				size, seeds.size(), bad_vertices])
		print("voronoi %s x%d: %.1f ms" % [size, seeds.size(), elapsed_ms])
