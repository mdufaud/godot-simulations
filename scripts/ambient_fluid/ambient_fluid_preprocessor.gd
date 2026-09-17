class_name AmbientFluidPreprocessor
extends RefCounted

const PROFILE := preload("res://scripts/ambient_fluid/ambient_fluid_profile_3d.gd")
const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const GREEN_FUNCTION_SCALE := 1.0 / (4.0 * PI)
const CONDITION_EPSILON := 1.0e-10

static var _last_error := ""
static var _last_bem_residual := 0.0


static func get_last_error() -> String:
	return _last_error


static func build_profile(mesh: ArrayMesh,
		reference_density_kg_m3: float) -> AmbientFluidProfile3D:
	_last_error = ""
	_last_bem_residual = 0.0
	if mesh == null:
		return _fail("mesh is required")
	if not is_finite(reference_density_kg_m3) or reference_density_kg_m3 <= 0.0:
		return _fail("reference_density_kg_m3 must be finite and positive")
	var geometry: Dictionary = _extract_geometry(mesh)
	if geometry.is_empty():
		return null
	var vertices: PackedVector3Array = geometry.vertices
	var triangles: Array = geometry.triangles
	var volume_data: Dictionary = _orient_and_measure(vertices, triangles)
	if volume_data.is_empty():
		return null
	var signed_volume: float = volume_data.volume
	var center_of_volume: Vector3 = volume_data.center
	var face_centers := PackedVector3Array()
	var face_normals := PackedVector3Array()
	var face_areas := PackedFloat64Array()
	var vertex_normals := PackedVector3Array()
	vertex_normals.resize(vertices.size())
	for vertex_index in vertices.size():
		vertex_normals[vertex_index] = Vector3.ZERO
	var edge_lengths := {}
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		var a: Vector3 = vertices[ids[0]]
		var b: Vector3 = vertices[ids[1]]
		var c: Vector3 = vertices[ids[2]]
		var cross := (b - a).cross(c - a)
		var area := cross.length() * 0.5
		var normal := cross / (area * 2.0)
		face_centers.append((a + b + c) / 3.0)
		face_normals.append(normal)
		face_areas.append(area)
		vertex_normals[ids[0]] += cross
		vertex_normals[ids[1]] += cross
		vertex_normals[ids[2]] += cross
		_register_edge_length(edge_lengths, ids[0], ids[1], a.distance_to(b))
		_register_edge_length(edge_lengths, ids[1], ids[2], b.distance_to(c))
		_register_edge_length(edge_lengths, ids[2], ids[0], c.distance_to(a))
	for vertex_index in vertices.size():
		if vertex_normals[vertex_index].length_squared() <= 1.0e-20:
			return _fail("vertex normal is undefined")
		vertex_normals[vertex_index] = vertex_normals[vertex_index].normalized()
	var mean_edge := 0.0
	for length in edge_lengths.values():
		mean_edge += float(length)
	if edge_lengths.is_empty() or not is_finite(mean_edge) or mean_edge <= 0.0:
		return _fail("mean edge length is invalid")
	mean_edge /= edge_lengths.size()
	var source_data: Dictionary = _choose_sources(vertices, triangles, face_normals,
		vertex_normals, mean_edge)
	if source_data.is_empty():
		return null
	var source_points: PackedVector3Array = source_data.sources
	var source_offset_m: float = source_data.offset
	var factorization: Dictionary = source_data.factorization
	var potential_matrix := _solve_potentials(vertices, vertex_normals, source_points,
		factorization)
	if potential_matrix.is_empty():
		return null
	var added_mass := _build_added_mass(vertices, triangles, face_normals, face_areas,
		potential_matrix, reference_density_kg_m3)
	if added_mass.is_empty():
		return null
	var translation_trace := added_mass[21] + added_mass[28] + added_mass[35]
	if not is_finite(translation_trace) or absf(translation_trace) <= 1.0e-12:
		return _fail("BEM translation added mass is zero")
	if translation_trace < 0.0:
		return _fail("BEM translation added mass has the wrong sign")
	added_mass = _symmetrize(added_mass)
	var projected_added_mass := MATH.project_positive_semidefinite(added_mass)
	if projected_added_mass.is_empty():
		return _fail("BEM added_mass_tensor is not positive semidefinite")
	var bem_psd_clamped := false
	for value_index in added_mass.size():
		if absf(projected_added_mass[value_index] - added_mass[value_index]) > 1.0e-8:
			bem_psd_clamped = true
			break
	added_mass = projected_added_mass
	var slip_matrix := _build_slip_matrix(vertices, triangles, face_normals)
	if slip_matrix.size() != face_centers.size() * 18:
		return _fail("BEM slip matrix construction failed")
	var total_area := 0.0
	for area in face_areas:
		total_area += area
	var profile: AmbientFluidProfile3D = PROFILE.new()
	profile.format_version = AmbientFluidProfile3D.FORMAT_BEM
	profile.source_mesh_hash = _mesh_hash(vertices, triangles)
	profile.reference_density_kg_m3 = reference_density_kg_m3
	profile.volume_m3 = absf(signed_volume)
	profile.center_of_volume_m = center_of_volume
	profile.total_area_m2 = total_area
	profile.characteristic_length_m = sqrt(total_area)
	profile.face_centers_m = face_centers
	profile.face_normals = face_normals
	profile.face_areas_m2 = face_areas
	profile.added_mass_tensor = added_mass
	profile.slip_matrix = slip_matrix
	profile.source_offset_m = source_offset_m
	profile.bem_psd_clamped = bem_psd_clamped
	profile.bem_max_residual = _last_bem_residual
	var profile_error := profile.validate()
	if profile_error != "":
		return _fail("generated profile: %s" % profile_error)
	return profile


static func save_profile(profile: AmbientFluidProfile3D, path: String) -> String:
	if profile == null:
		return "profile is required"
	if not path.begins_with("res://resources/ambient_fluid/") or not path.ends_with(".tres"):
		return "profile path must be under res://resources/ambient_fluid/ and end with .tres"
	var profile_error := profile.validate()
	if profile_error != "":
		return "profile is invalid: %s" % profile_error
	var save_error: Error = ResourceSaver.save(profile, path)
	if save_error != OK:
		return "ResourceSaver failed with error %s" % save_error
	return ""


static func _extract_geometry(mesh: ArrayMesh):
	var surfaces: Array = []
	var all_positions := PackedVector3Array()
	for surface_index in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
			return _fail_dict("surface %d is not a triangle list" % surface_index)
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX or not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			return _fail_dict("surface %d has no vertex array" % surface_index)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if positions.is_empty():
			return _fail_dict("surface %d has no vertices" % surface_index)
		var indices := PackedInt32Array()
		if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
			indices = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty() and positions.size() % 3 != 0:
			return _fail_dict("surface %d has incomplete unindexed triangles" % surface_index)
		if not indices.is_empty() and indices.size() % 3 != 0:
			return _fail_dict("surface %d has incomplete indexed triangles" % surface_index)
		for position in positions:
			if not _finite_vector(position):
				return _fail_dict("mesh contains a non-finite coordinate")
			all_positions.append(position)
		surfaces.append({vertices = positions, indices = indices})
	if surfaces.is_empty():
		return _fail_dict("mesh has no surfaces")
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for position in all_positions:
		minimum = minimum.min(position)
		maximum = maximum.max(position)
	var extent := (maximum - minimum).length()
	if not is_finite(extent) or extent <= 1.0e-12:
		return _fail_dict("mesh extent is zero")
	var weld_epsilon := extent * 1.0e-7
	var vertices := PackedVector3Array()
	var vertex_lookup := {}
	var triangles: Array = []
	for surface in surfaces:
		var positions: PackedVector3Array = surface.vertices
		var indices: PackedInt32Array = surface.indices
		var remapped := PackedInt32Array()
		remapped.resize(positions.size())
		for position_index in positions.size():
			var position: Vector3 = positions[position_index]
			var key := _vertex_key(position, weld_epsilon)
			if not vertex_lookup.has(key):
				vertex_lookup[key] = vertices.size()
				vertices.append(position)
			remapped[position_index] = vertex_lookup[key]
		if indices.is_empty():
			for index in range(0, remapped.size(), 3):
				triangles.append(PackedInt32Array([
					remapped[index], remapped[index + 1], remapped[index + 2]]))
		else:
			for index in range(0, indices.size(), 3):
				var i0 := int(indices[index])
				var i1 := int(indices[index + 1])
				var i2 := int(indices[index + 2])
				if i0 < 0 or i0 >= remapped.size() or i1 < 0 or i1 >= remapped.size() \
					or i2 < 0 or i2 >= remapped.size():
					return _fail_dict("mesh index is out of range")
				triangles.append(PackedInt32Array([
					remapped[i0], remapped[i1], remapped[i2]]))
	if vertices.size() < 4 or triangles.is_empty():
		return _fail_dict("mesh needs at least four vertices and one triangle")
	var edge_data := {}
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		if ids[0] == ids[1] or ids[1] == ids[2] or ids[2] == ids[0]:
			return _fail_dict("mesh contains a repeated-index triangle")
		for edge in [[ids[0], ids[1]], [ids[1], ids[2]], [ids[2], ids[0]]]:
			var first: int = edge[0]
			var second: int = edge[1]
			var edge_key := _edge_key(first, second)
			var entry: Dictionary = edge_data.get(edge_key, {count = 0, direction = 0})
			entry.count += 1
			entry.direction += 1 if first < second else -1
			edge_data[edge_key] = entry
	for entry in edge_data.values():
		if entry.count != 2 or entry.direction != 0:
			return _fail_dict("mesh must be closed with oppositely oriented manifold edges")
	return {vertices = vertices, triangles = triangles}


static func _orient_and_measure(vertices: PackedVector3Array, triangles: Array):
	var signed_volume := 0.0
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		signed_volume += vertices[ids[0]].dot(vertices[ids[1]].cross(vertices[ids[2]])) / 6.0
	if not is_finite(signed_volume) or absf(signed_volume) <= 1.0e-12:
		return _fail_dict("mesh has zero signed volume")
	if signed_volume < 0.0:
		for triangle_index in triangles.size():
			var ids: PackedInt32Array = triangles[triangle_index]
			triangles[triangle_index] = PackedInt32Array([ids[0], ids[2], ids[1]])
		signed_volume = 0.0
		for triangle in triangles:
			var flipped: PackedInt32Array = triangle
			signed_volume += vertices[flipped[0]].dot(vertices[flipped[1]].cross(vertices[flipped[2]])) / 6.0
	var first_moment := Vector3.ZERO
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		var scalar := vertices[ids[0]].dot(vertices[ids[1]].cross(vertices[ids[2]]))
		first_moment += (vertices[ids[0]] + vertices[ids[1]] + vertices[ids[2]]) * scalar / 24.0
	return {volume = signed_volume, center = first_moment / signed_volume}


static func _choose_sources(vertices: PackedVector3Array, triangles: Array,
		face_normals: PackedVector3Array, vertex_normals: PackedVector3Array,
		mean_edge: float):
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for vertex in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	var shape_extent := (maximum - minimum).length()
	# Sources ride vertex normals inward. On a thin shape a deep offset pushes
	# them past the opposite face, which corrupts the potentials (the demo
	# plate once got an inverted broadside/edgewise added mass), so cap the
	# offset at half the smallest face-centroid-to-opposite-plane distance.
	var min_face_gap := INF
	for triangle_index in triangles.size():
		var ids: PackedInt32Array = triangles[triangle_index]
		var center := (vertices[ids[0]] + vertices[ids[1]] + vertices[ids[2]]) / 3.0
		var normal: Vector3 = face_normals[triangle_index]
		for other_index in triangles.size():
			if other_index == triangle_index:
				continue
			var other_ids: PackedInt32Array = triangles[other_index]
			# Facing pairs measure the shape's thinness; a triangle centroid
			# hugging an edge would understate the gap to a perpendicular face.
			if face_normals[other_index].dot(normal) >= -0.5:
				continue
			var gap := face_normals[other_index].dot(vertices[other_ids[0]] - center)
			if gap > 1.0e-9:
				min_face_gap = minf(min_face_gap, gap)
	if not is_finite(min_face_gap):
		# No facing pair (nonconvex mesh): keep the conservative all-pairs bound.
		for triangle_index in triangles.size():
			var ids: PackedInt32Array = triangles[triangle_index]
			var center := (vertices[ids[0]] + vertices[ids[1]] + vertices[ids[2]]) / 3.0
			for other_index in triangles.size():
				if other_index == triangle_index:
					continue
				var other_ids: PackedInt32Array = triangles[other_index]
				var gap := face_normals[other_index].dot(vertices[other_ids[0]] - center)
				if gap > 1.0e-9:
					min_face_gap = minf(min_face_gap, gap)
	if not is_finite(min_face_gap):
		return _fail_dict("mesh interior is too thin to place BEM sources")
	var max_offset := 0.5 * min_face_gap
	var factors := [0.2, 0.15, 0.1, 0.075, 0.05, 0.025]
	var previous_offset := -1.0
	for factor in factors:
		var offset := minf(shape_extent * float(factor), max_offset)
		if is_equal_approx(offset, previous_offset):
			continue
		previous_offset = offset
		var sources := PackedVector3Array()
		var all_inside := true
		for vertex_index in vertices.size():
			var source := vertices[vertex_index] - vertex_normals[vertex_index] * offset
			sources.append(source)
			if not _point_inside(source, vertices, triangles, face_normals, mean_edge * 1.0e-6):
				all_inside = false
				break
		if not all_inside:
			continue
		var matrix := _assemble_source_matrix(vertices, vertex_normals, sources)
		var factorization := _factorize(matrix, vertices.size())
		if not factorization.is_empty() and factorization.condition >= CONDITION_EPSILON:
			return {sources = sources, offset = offset, factorization = factorization}
	return _fail_dict("no interior source offset produced a sufficiently conditioned BEM matrix")


static func _assemble_source_matrix(collocation_points: PackedVector3Array,
		collocation_normals: PackedVector3Array, sources: PackedVector3Array) -> PackedFloat64Array:
	var matrix := PackedFloat64Array()
	matrix.resize(collocation_points.size() * sources.size())
	for row in collocation_points.size():
		for col in sources.size():
			var delta := collocation_points[row] - sources[col]
			var distance_squared := delta.length_squared()
			if distance_squared <= 1.0e-24:
				return PackedFloat64Array()
			var inverse_distance_cubed := 1.0 / (distance_squared * sqrt(distance_squared))
			var gradient := -delta * (GREEN_FUNCTION_SCALE * inverse_distance_cubed)
			matrix[row * sources.size() + col] = collocation_normals[row].dot(gradient)
	return matrix


static func _solve_potentials(vertices: PackedVector3Array,
		vertex_normals: PackedVector3Array, sources: PackedVector3Array,
		factorization: Dictionary) -> PackedFloat64Array:
	var potential_matrix := PackedFloat64Array()
	potential_matrix.resize(vertices.size() * 6)
	var source_matrix := _assemble_source_matrix(vertices, vertex_normals, sources)
	if source_matrix.is_empty():
		return _fail_array("BEM source matrix reconstruction failed")
	for mode in 6:
		var rhs := PackedFloat64Array()
		rhs.resize(vertices.size())
		for point_index in vertices.size():
			var angular := Vector3.ZERO
			var linear := Vector3.ZERO
			if mode < 3:
				angular[mode] = 1.0
			else:
				linear[mode - 3] = 1.0
			rhs[point_index] = vertex_normals[point_index].dot(
				angular.cross(vertices[point_index]) + linear)
		var source_strengths := _solve_factorized(factorization, rhs, sources.size())
		if source_strengths.is_empty():
			return _fail_array("BEM LU solve failed")
		var rhs_scale := 1.0
		var mode_residual := 0.0
		for row in vertices.size():
			var reconstructed := 0.0
			for col in sources.size():
				reconstructed += source_matrix[row * sources.size() + col] \
					* source_strengths[col]
			rhs_scale = maxf(rhs_scale, absf(rhs[row]))
			mode_residual = maxf(mode_residual, absf(reconstructed - rhs[row]))
		mode_residual /= rhs_scale
		_last_bem_residual = maxf(_last_bem_residual, mode_residual)
		if not is_finite(mode_residual) or mode_residual > 1.0e-7:
			return _fail_array("BEM solve residual exceeds tolerance")
		for vertex_index in vertices.size():
			var potential := 0.0
			for source_index in sources.size():
				var delta := vertices[vertex_index] - sources[source_index]
				var distance := delta.length()
				if distance <= 1.0e-12:
					return _fail_array("BEM potential evaluation reached a source")
				potential += GREEN_FUNCTION_SCALE * source_strengths[source_index] / distance
			potential_matrix[vertex_index * 6 + mode] = potential
	return potential_matrix


static func _build_added_mass(vertices: PackedVector3Array, triangles: Array,
		face_normals: PackedVector3Array, face_areas: PackedFloat64Array,
		potential_matrix: PackedFloat64Array, density: float) -> PackedFloat64Array:
	var result := MATH.zero_matrix()
	for triangle_index in triangles.size():
		var ids: PackedInt32Array = triangles[triangle_index]
		var normal: Vector3 = face_normals[triangle_index]
		var area: float = face_areas[triangle_index]
		var positions := [vertices[ids[0]], vertices[ids[1]], vertices[ids[2]]]
		var boundary := PackedFloat64Array()
		boundary.resize(18)
		for local_index in 3:
			var position: Vector3 = positions[local_index]
			for mode in 6:
				var angular := Vector3.ZERO
				var linear := Vector3.ZERO
				if mode < 3:
					angular[mode] = 1.0
				else:
					linear[mode - 3] = 1.0
				boundary[local_index * 6 + mode] = normal.dot(
					angular.cross(position) + linear)
		for potential_mode in 6:
			for motion_mode in 6:
				var integral := 0.0
				for potential_vertex in 3:
					for motion_vertex in 3:
						var weight := area / 12.0
						if potential_vertex == motion_vertex:
							weight *= 2.0
						integral += weight * potential_matrix[ids[potential_vertex] * 6 + potential_mode] \
							* boundary[motion_vertex * 6 + motion_mode]
				result[potential_mode * 6 + motion_mode] -= density * integral
	return result


static func _build_slip_matrix(vertices: PackedVector3Array, triangles: Array,
		face_normals: PackedVector3Array) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	result.resize(triangles.size() * 18)
	for triangle_index in triangles.size():
		var ids: PackedInt32Array = triangles[triangle_index]
		var normal: Vector3 = face_normals[triangle_index]
		var positions := [vertices[ids[0]], vertices[ids[1]], vertices[ids[2]]]
		var center: Vector3 = (positions[0] + positions[1] + positions[2]) / 3.0
		for row in 3:
			for col in 6:
				var geometric := 0.0
				for projection_axis in 3:
					var projected := (1.0 if row == projection_axis else 0.0) \
						- normal[row] * normal[projection_axis]
					geometric += projected * _rigid_motion_matrix_value(center,
						projection_axis, col)
				result[triangle_index * 18 + row * 6 + col] = -geometric
	return result


static func _rigid_motion_matrix_value(center: Vector3, row: int, col: int) -> float:
	if col >= 3:
		return 1.0 if col - 3 == row else 0.0
	var cross_matrix := [
		[0.0, center.z, -center.y],
		[-center.z, 0.0, center.x],
		[center.y, -center.x, 0.0],
	]
	return cross_matrix[row][col]


static func _factorize(matrix: PackedFloat64Array, size: int) -> Dictionary:
	if matrix.size() != size * size or size <= 0:
		return {}
	var lu := matrix.duplicate()
	var permutation := PackedInt32Array()
	permutation.resize(size)
	for row in size:
		permutation[row] = row
	var matrix_scale := 0.0
	for value in lu:
		matrix_scale = maxf(matrix_scale, absf(value))
	if not is_finite(matrix_scale) or matrix_scale <= 0.0:
		return {}
	var minimum_pivot := INF
	var maximum_pivot := 0.0
	for pivot in size:
		var pivot_row := pivot
		var pivot_abs := absf(lu[pivot * size + pivot])
		for row in range(pivot + 1, size):
			var candidate := absf(lu[row * size + pivot])
			if candidate > pivot_abs:
				pivot_abs = candidate
				pivot_row = row
		if not is_finite(pivot_abs) or pivot_abs <= matrix_scale * 1.0e-14:
			return {}
		if pivot_row != pivot:
			for col in size:
				var swap := lu[pivot * size + col]
				lu[pivot * size + col] = lu[pivot_row * size + col]
				lu[pivot_row * size + col] = swap
			var permutation_swap := permutation[pivot]
			permutation[pivot] = permutation[pivot_row]
			permutation[pivot_row] = permutation_swap
		minimum_pivot = minf(minimum_pivot, pivot_abs)
		maximum_pivot = maxf(maximum_pivot, pivot_abs)
		var pivot_value: float = lu[pivot * size + pivot]
		for row in range(pivot + 1, size):
			lu[row * size + pivot] /= pivot_value
			var factor: float = lu[row * size + pivot]
			for col in range(pivot + 1, size):
				lu[row * size + col] -= factor * lu[pivot * size + col]
	var condition := minimum_pivot / maximum_pivot
	if not is_finite(condition):
		return {}
	return {lu = lu, permutation = permutation, condition = condition}


static func _solve_factorized(factorization: Dictionary, rhs: PackedFloat64Array,
		size: int) -> PackedFloat64Array:
	if factorization.is_empty() or rhs.size() != size:
		return PackedFloat64Array()
	var lu: PackedFloat64Array = factorization.lu
	var permutation: PackedInt32Array = factorization.permutation
	var values := PackedFloat64Array()
	values.resize(size)
	for row in size:
		values[row] = rhs[permutation[row]]
		for col in range(row):
			values[row] -= lu[row * size + col] * values[col]
	for row in range(size - 1, -1, -1):
		for col in range(row + 1, size):
			values[row] -= lu[row * size + col] * values[col]
		var diagonal := lu[row * size + row]
		if absf(diagonal) <= 1.0e-18:
			return PackedFloat64Array()
		values[row] /= diagonal
	return values


static func _point_inside(point: Vector3, vertices: PackedVector3Array, triangles: Array,
		face_normals: PackedVector3Array, tolerance: float) -> bool:
	var convex := true
	for triangle_index in triangles.size():
		var ids: PackedInt32Array = triangles[triangle_index]
		if face_normals[triangle_index].dot(point - vertices[ids[0]]) > tolerance:
			convex = false
			break
	if convex:
		return true
	var ray_direction := Vector3(1.0, 0.3713907, 0.1938472).normalized()
	var intersections := 0
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		var distance := _ray_triangle_distance(point, ray_direction, vertices[ids[0]],
			vertices[ids[1]], vertices[ids[2]])
		if distance > tolerance:
			intersections += 1
	return intersections % 2 == 1


static func _ray_triangle_distance(origin: Vector3, direction: Vector3,
		a: Vector3, b: Vector3, c: Vector3) -> float:
	var edge_a := b - a
	var edge_b := c - a
	var cross_direction := direction.cross(edge_b)
	var determinant := edge_a.dot(cross_direction)
	if absf(determinant) <= 1.0e-12:
		return -1.0
	var inverse_determinant := 1.0 / determinant
	var origin_delta := origin - a
	var barycentric_u := origin_delta.dot(cross_direction) * inverse_determinant
	if barycentric_u < -1.0e-8 or barycentric_u > 1.0 + 1.0e-8:
		return -1.0
	var cross_origin := origin_delta.cross(edge_a)
	var barycentric_v := direction.dot(cross_origin) * inverse_determinant
	if barycentric_v < -1.0e-8 or barycentric_u + barycentric_v > 1.0 + 1.0e-8:
		return -1.0
	var distance := edge_b.dot(cross_origin) * inverse_determinant
	return distance


static func _symmetrize(matrix: PackedFloat64Array) -> PackedFloat64Array:
	var result := matrix.duplicate()
	for row in 6:
		for col in range(row + 1, 6):
			var value := 0.5 * (matrix[row * 6 + col] + matrix[col * 6 + row])
			result[row * 6 + col] = value
			result[col * 6 + row] = value
	return result


static func _register_edge_length(edge_lengths: Dictionary, first: int, second: int,
		length: float) -> void:
	var key := _edge_key(first, second)
	if not edge_lengths.has(key):
		edge_lengths[key] = length


static func _edge_key(first: int, second: int) -> String:
	return "%d:%d" % [mini(first, second), maxi(first, second)]


static func _vertex_key(value: Vector3, epsilon: float) -> String:
	return "%d:%d:%d" % [
		int(round(value.x / epsilon)), int(round(value.y / epsilon)), int(round(value.z / epsilon))]


static func _mesh_hash(vertices: PackedVector3Array, triangles: Array) -> String:
	var serialized := ""
	for vertex in vertices:
		serialized += str(vertex.x) + "," + str(vertex.y) + "," + str(vertex.z) + ";"
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		serialized += "%d,%d,%d;" % [ids[0], ids[1], ids[2]]
	return serialized.md5_text()


static func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _fail(message: String):
	_last_error = message
	return null


static func _fail_dict(message: String) -> Dictionary:
	_last_error = message
	return {}


static func _fail_array(message: String) -> PackedFloat64Array:
	_last_error = message
	return PackedFloat64Array()
