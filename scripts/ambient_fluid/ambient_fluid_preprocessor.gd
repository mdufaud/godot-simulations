class_name AmbientFluidPreprocessor
extends RefCounted

const PROFILE := preload("res://scripts/ambient_fluid/ambient_fluid_profile_3d.gd")
const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")
const GREEN_FUNCTION_SCALE := 1.0 / (4.0 * PI)
const CONDITION_EPSILON := 1.0e-12

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
	var face_vertices := PackedVector3Array()
	for triangle in triangles:
		var ids: PackedInt32Array = triangle
		var a: Vector3 = vertices[ids[0]]
		var b: Vector3 = vertices[ids[1]]
		var c: Vector3 = vertices[ids[2]]
		var cross := (b - a).cross(c - a)
		var area := cross.length() * 0.5
		if not is_finite(area) or area <= 1.0e-14:
			return _fail("mesh contains a degenerate triangle")
		face_centers.append((a + b + c) / 3.0)
		face_normals.append(cross / (area * 2.0))
		face_areas.append(area)
		face_vertices.append_array(PackedVector3Array([a, b, c]))
	var added_mass := _panel_added_mass(face_vertices, face_centers, face_normals, face_areas,
		reference_density_kg_m3)
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
	profile.face_vertices_m = face_vertices
	profile.added_mass_tensor = added_mass
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


## Fluid inertia K_f (Eq. 8-9) by a constant-strength source panel method
## (Hess & Smith): each face carries a uniform source density sigma_j, the
## exterior Neumann condition n . grad(phi) = n . (v + w x x) holds on average
## over each face, and K_f = -rho sum_i phi_i (n . u)_i A_i. Faces closer than
## two of their sizes are integrated on sub-triangles at both ends (Galerkin);
## the self potential averages the closed-form in-plane integral of 1/r. The
## paper solves the same Neumann problem with interior point sources
## (Sec. 5.1); sources under a finely cut box or a thin plate either smear its
## edges or turn ill-conditioned, and gave the demo plate a tenth of its
## broadside added mass. Converges like the panel size: a 320-face sphere is
## 2% above 1/2 rho V.
static func _panel_added_mass(face_vertices: PackedVector3Array,
		face_centers: PackedVector3Array, face_normals: PackedVector3Array,
		face_areas: PackedFloat64Array, density: float) -> PackedFloat64Array:
	var count := face_centers.size()
	var sizes := PackedFloat64Array()
	var receivers: Array[PackedVector3Array] = []
	var sources: Array[PackedVector3Array] = []
	for face in count:
		var a := face_vertices[face * 3]
		var b := face_vertices[face * 3 + 1]
		var c := face_vertices[face * 3 + 2]
		sizes.append(maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a))))
		receivers.append(_sub_centroids(a, b, c, 2))
		sources.append(_sub_centroids(a, b, c, 3))
	var influence := PackedFloat64Array()
	influence.resize(count * count)
	var potential := PackedFloat64Array()
	potential.resize(count * count)
	for row in count:
		var normal := face_normals[row]
		var own_receivers: PackedVector3Array = receivers[row]
		for col in count:
			var index := row * count + col
			if row == col:
				# A flat face's own source has no normal flux in its plane: the
				# exterior limit is the jump -sigma/2.
				influence[index] = -0.5
				var self_sum := 0.0
				for point in own_receivers:
					self_sum += _plane_inverse_distance(face_vertices[col * 3],
						face_vertices[col * 3 + 1], face_vertices[col * 3 + 2], point)
				potential[index] = GREEN_FUNCTION_SCALE * self_sum / own_receivers.size()
				continue
			var distance := face_centers[row].distance_to(face_centers[col])
			var points := PackedVector3Array([face_centers[row]])
			var quadrature := PackedVector3Array([face_centers[col]])
			if distance < 2.0 * sizes[col]:
				points = own_receivers
				quadrature = sources[col]
			elif distance < 4.0 * sizes[col]:
				quadrature = receivers[col]
			var weight := face_areas[col] / quadrature.size() / points.size()
			var flux := 0.0
			var value := 0.0
			for point in points:
				for source in quadrature:
					var delta := point - source
					var distance_squared := delta.length_squared()
					var inverse_distance := 1.0 / sqrt(distance_squared)
					flux -= normal.dot(delta) * inverse_distance / distance_squared
					value += inverse_distance
			influence[index] = GREEN_FUNCTION_SCALE * weight * flux
			potential[index] = GREEN_FUNCTION_SCALE * weight * value
	var factorization := _factorize(influence, count)
	if factorization.is_empty() or factorization.condition < CONDITION_EPSILON:
		return _fail_array("BEM panel system is singular")
	var potentials: Array[PackedFloat64Array] = []
	var boundaries: Array[PackedFloat64Array] = []
	for mode in 6:
		var angular := Vector3.ZERO
		var linear := Vector3.ZERO
		if mode < 3:
			angular[mode] = 1.0
		else:
			linear[mode - 3] = 1.0
		var rhs := PackedFloat64Array()
		rhs.resize(count)
		for face in count:
			rhs[face] = face_normals[face].dot(angular.cross(face_centers[face]) + linear)
		var strengths := _solve_factorized(factorization, rhs, count)
		if strengths.is_empty():
			return _fail_array("BEM LU solve failed")
		var rhs_scale := 1.0e-12
		var mode_residual := 0.0
		var phi := PackedFloat64Array()
		phi.resize(count)
		for row in count:
			var reconstructed := 0.0
			var face_potential := 0.0
			for col in count:
				reconstructed += influence[row * count + col] * strengths[col]
				face_potential += potential[row * count + col] * strengths[col]
			rhs_scale = maxf(rhs_scale, absf(rhs[row]))
			mode_residual = maxf(mode_residual, absf(reconstructed - rhs[row]))
			phi[row] = face_potential
		mode_residual /= rhs_scale
		_last_bem_residual = maxf(_last_bem_residual, mode_residual)
		if not is_finite(mode_residual) or mode_residual > 1.0e-7:
			return _fail_array("BEM solve residual exceeds tolerance")
		potentials.append(phi)
		boundaries.append(rhs)
	var result := MATH.zero_matrix()
	for potential_mode in 6:
		for motion_mode in 6:
			var integral := 0.0
			for face in count:
				integral += potentials[potential_mode][face] * boundaries[motion_mode][face] \
					* face_areas[face]
			result[potential_mode * 6 + motion_mode] = -density * integral
	return result


## Centroids of the 4^levels triangles a midpoint subdivision cuts a face into.
static func _sub_centroids(a: Vector3, b: Vector3, c: Vector3, levels: int) -> PackedVector3Array:
	var triangles := [[a, b, c]]
	for _level in levels:
		var refined := []
		for triangle in triangles:
			var ab: Vector3 = (triangle[0] + triangle[1]) * 0.5
			var bc: Vector3 = (triangle[1] + triangle[2]) * 0.5
			var ca: Vector3 = (triangle[2] + triangle[0]) * 0.5
			refined.append([triangle[0], ab, ca])
			refined.append([ab, triangle[1], bc])
			refined.append([ca, bc, triangle[2]])
			refined.append([ab, bc, ca])
		triangles = refined
	var centroids := PackedVector3Array()
	for triangle in triangles:
		centroids.append((triangle[0] + triangle[1] + triangle[2]) / 3.0)
	return centroids


## Integral of 1/|p - y| over the triangle (a, b, c) for p inside it, in its
## plane: the sum over edges of d ln((r2 + s2) / (r1 + s1)), with d the
## distance from p to the edge line, s the edge-wise coordinates of its ends
## from the foot of the perpendicular and r their distances to p.
static func _plane_inverse_distance(a: Vector3, b: Vector3, c: Vector3, point: Vector3) -> float:
	var total := 0.0
	var corners := [a, b, c]
	for edge in 3:
		var start: Vector3 = corners[edge]
		var finish: Vector3 = corners[(edge + 1) % 3]
		var tangent := (finish - start).normalized()
		var start_along := (start - point).dot(tangent)
		var finish_along := (finish - point).dot(tangent)
		var height := (start - tangent * start_along - point).length()
		total += height * log((finish.distance_to(point) + finish_along)
			/ (start.distance_to(point) + start_along))
	return total


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


static func _symmetrize(matrix: PackedFloat64Array) -> PackedFloat64Array:
	var result := matrix.duplicate()
	for row in 6:
		for col in range(row + 1, 6):
			var value := 0.5 * (matrix[row * 6 + col] + matrix[col * 6 + row])
			result[row * 6 + col] = value
			result[col * 6 + row] = value
	return result


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
