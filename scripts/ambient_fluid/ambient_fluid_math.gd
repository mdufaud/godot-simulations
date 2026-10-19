class_name AmbientFluidMath
extends RefCounted

const MATRIX_SIZE := 6
const MATRIX_SCALARS := MATRIX_SIZE * MATRIX_SIZE
const PIVOT_EPSILON := 1.0e-12


static func zero_matrix() -> PackedFloat64Array:
	var matrix := PackedFloat64Array()
	matrix.resize(MATRIX_SCALARS)
	return matrix


static func identity_matrix() -> PackedFloat64Array:
	var matrix := zero_matrix()
	for i in MATRIX_SIZE:
		matrix[i * MATRIX_SIZE + i] = 1.0
	return matrix


static func diagonal_matrix(angular: Vector3, mass: float) -> PackedFloat64Array:
	var matrix := zero_matrix()
	matrix[0] = angular.x
	matrix[7] = angular.y
	matrix[14] = angular.z
	matrix[21] = mass
	matrix[28] = mass
	matrix[35] = mass
	return matrix


static func matrix_add(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != MATRIX_SCALARS or b.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var result := zero_matrix()
	for i in MATRIX_SCALARS:
		result[i] = a[i] + b[i]
	return result


static func matrix_scale(matrix: PackedFloat64Array, scale: float) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var result := zero_matrix()
	for i in MATRIX_SCALARS:
		result[i] = matrix[i] * scale
	return result


static func matrix_multiply(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != MATRIX_SCALARS or b.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var result := zero_matrix()
	for row in MATRIX_SIZE:
		for col in MATRIX_SIZE:
			var value := 0.0
			for k in MATRIX_SIZE:
				value += a[row * MATRIX_SIZE + k] * b[k * MATRIX_SIZE + col]
			result[row * MATRIX_SIZE + col] = value
	return result


static func matrix_vector_multiply(matrix: PackedFloat64Array,
		vector: PackedFloat64Array) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS or vector.size() != MATRIX_SIZE:
		return PackedFloat64Array()
	var result := PackedFloat64Array()
	result.resize(MATRIX_SIZE)
	for row in MATRIX_SIZE:
		var value := 0.0
		for col in MATRIX_SIZE:
			value += matrix[row * MATRIX_SIZE + col] * vector[col]
		result[row] = value
	return result


static func vector_add(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != MATRIX_SIZE or b.size() != MATRIX_SIZE:
		return PackedFloat64Array()
	var result := PackedFloat64Array()
	result.resize(MATRIX_SIZE)
	for i in MATRIX_SIZE:
		result[i] = a[i] + b[i]
	return result


static func vector_scale(vector: PackedFloat64Array, scale: float) -> PackedFloat64Array:
	if vector.size() != MATRIX_SIZE:
		return PackedFloat64Array()
	var result := PackedFloat64Array()
	result.resize(MATRIX_SIZE)
	for i in MATRIX_SIZE:
		result[i] = vector[i] * scale
	return result


static func matrix_transpose(matrix: PackedFloat64Array) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var result := zero_matrix()
	for row in MATRIX_SIZE:
		for col in MATRIX_SIZE:
			result[col * MATRIX_SIZE + row] = matrix[row * MATRIX_SIZE + col]
	return result


static func matrix_inverse(matrix: PackedFloat64Array) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var augmented := PackedFloat64Array()
	augmented.resize(MATRIX_SIZE * MATRIX_SIZE * 2)
	for row in MATRIX_SIZE:
		for col in MATRIX_SIZE:
			augmented[row * MATRIX_SIZE * 2 + col] = matrix[row * MATRIX_SIZE + col]
			augmented[row * MATRIX_SIZE * 2 + MATRIX_SIZE + col] = 1.0 if row == col else 0.0

	for pivot in MATRIX_SIZE:
		var pivot_row := pivot
		var pivot_abs := absf(augmented[pivot * MATRIX_SIZE * 2 + pivot])
		for row in range(pivot + 1, MATRIX_SIZE):
			var candidate := absf(augmented[row * MATRIX_SIZE * 2 + pivot])
			if candidate > pivot_abs:
				pivot_abs = candidate
				pivot_row = row
		if pivot_abs <= PIVOT_EPSILON:
			return PackedFloat64Array()
		if pivot_row != pivot:
			for col in MATRIX_SIZE * 2:
				var swap := augmented[pivot * MATRIX_SIZE * 2 + col]
				augmented[pivot * MATRIX_SIZE * 2 + col] = augmented[pivot_row * MATRIX_SIZE * 2 + col]
				augmented[pivot_row * MATRIX_SIZE * 2 + col] = swap

		var pivot_value := augmented[pivot * MATRIX_SIZE * 2 + pivot]
		for col in MATRIX_SIZE * 2:
			augmented[pivot * MATRIX_SIZE * 2 + col] /= pivot_value
		for row in MATRIX_SIZE:
			if row == pivot:
				continue
			var factor := augmented[row * MATRIX_SIZE * 2 + pivot]
			if is_zero_approx(factor):
				continue
			for col in MATRIX_SIZE * 2:
				augmented[row * MATRIX_SIZE * 2 + col] -= factor * augmented[pivot * MATRIX_SIZE * 2 + col]

	var result := zero_matrix()
	for row in MATRIX_SIZE:
		for col in MATRIX_SIZE:
			result[row * MATRIX_SIZE + col] = augmented[row * MATRIX_SIZE * 2 + MATRIX_SIZE + col]
	return result


static func cholesky(matrix: PackedFloat64Array) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS:
		return PackedFloat64Array()
	var lower := zero_matrix()
	for row in MATRIX_SIZE:
		for col in row + 1:
			var value := matrix[row * MATRIX_SIZE + col]
			for k in col:
				value -= lower[row * MATRIX_SIZE + k] * lower[col * MATRIX_SIZE + k]
			if row == col:
				if value <= PIVOT_EPSILON:
					return PackedFloat64Array()
				lower[row * MATRIX_SIZE + col] = sqrt(value)
			else:
				lower[row * MATRIX_SIZE + col] = value / lower[col * MATRIX_SIZE + col]
	return lower


static func is_symmetric(matrix: PackedFloat64Array, tolerance := 1.0e-9) -> bool:
	if matrix.size() != MATRIX_SCALARS:
		return false
	for row in MATRIX_SIZE:
		for col in range(row + 1, MATRIX_SIZE):
			if absf(matrix[row * MATRIX_SIZE + col] - matrix[col * MATRIX_SIZE + row]) > tolerance:
				return false
	return true


static func is_positive_definite(matrix: PackedFloat64Array) -> bool:
	return cholesky(matrix).size() == MATRIX_SCALARS


static func is_positive_semidefinite(matrix: PackedFloat64Array,
		tolerance := 1.0e-8) -> bool:
	if matrix.size() != MATRIX_SCALARS or not is_symmetric(matrix, tolerance * 10.0):
		return false
	var work := matrix
	for _iteration in 64:
		var pivot_row := 0
		var pivot_col := 1
		var pivot_abs := 0.0
		for row in MATRIX_SIZE:
			for col in range(row + 1, MATRIX_SIZE):
				var candidate := absf(work[row * MATRIX_SIZE + col])
				if candidate > pivot_abs:
					pivot_abs = candidate
					pivot_row = row
					pivot_col = col
		if pivot_abs <= tolerance:
			break
		var diagonal_row := work[pivot_row * MATRIX_SIZE + pivot_row]
		var diagonal_col := work[pivot_col * MATRIX_SIZE + pivot_col]
		var angle := 0.5 * atan2(2.0 * work[pivot_row * MATRIX_SIZE + pivot_col],
			diagonal_col - diagonal_row)
		var cosine := cos(angle)
		var sine := sin(angle)
		for index in MATRIX_SIZE:
			var row_value := work[pivot_row * MATRIX_SIZE + index]
			var col_value := work[pivot_col * MATRIX_SIZE + index]
			work[pivot_row * MATRIX_SIZE + index] = cosine * row_value - sine * col_value
			work[pivot_col * MATRIX_SIZE + index] = sine * row_value + cosine * col_value
		for index in MATRIX_SIZE:
			var row_value := work[index * MATRIX_SIZE + pivot_row]
			var col_value := work[index * MATRIX_SIZE + pivot_col]
			work[index * MATRIX_SIZE + pivot_row] = cosine * row_value - sine * col_value
			work[index * MATRIX_SIZE + pivot_col] = sine * row_value + cosine * col_value
	for index in MATRIX_SIZE:
		if work[index * MATRIX_SIZE + index] < -tolerance:
			return false
	return true


static func project_positive_semidefinite(matrix: PackedFloat64Array,
		max_negative_ratio := 0.1) -> PackedFloat64Array:
	if matrix.size() != MATRIX_SCALARS or not is_symmetric(matrix, 1.0e-7):
		return PackedFloat64Array()
	var work := matrix.duplicate()
	var eigenvectors := identity_matrix()
	for _iteration in 128:
		var pivot_row := 0
		var pivot_col := 1
		var pivot_abs := 0.0
		for row in MATRIX_SIZE:
			for col in range(row + 1, MATRIX_SIZE):
				var candidate := absf(work[row * MATRIX_SIZE + col])
				if candidate > pivot_abs:
					pivot_abs = candidate
					pivot_row = row
					pivot_col = col
		if pivot_abs <= 1.0e-10:
			break
		var angle := 0.5 * atan2(2.0 * work[pivot_row * MATRIX_SIZE + pivot_col],
			work[pivot_col * MATRIX_SIZE + pivot_col] - work[pivot_row * MATRIX_SIZE + pivot_row])
		var cosine := cos(angle)
		var sine := sin(angle)
		for index in MATRIX_SIZE:
			var row_value := work[pivot_row * MATRIX_SIZE + index]
			var col_value := work[pivot_col * MATRIX_SIZE + index]
			work[pivot_row * MATRIX_SIZE + index] = cosine * row_value - sine * col_value
			work[pivot_col * MATRIX_SIZE + index] = sine * row_value + cosine * col_value
		for index in MATRIX_SIZE:
			var row_value := work[index * MATRIX_SIZE + pivot_row]
			var col_value := work[index * MATRIX_SIZE + pivot_col]
			work[index * MATRIX_SIZE + pivot_row] = cosine * row_value - sine * col_value
			work[index * MATRIX_SIZE + pivot_col] = sine * row_value + cosine * col_value
		for index in MATRIX_SIZE:
			var row_value := eigenvectors[pivot_row * MATRIX_SIZE + index]
			var col_value := eigenvectors[pivot_col * MATRIX_SIZE + index]
			eigenvectors[pivot_row * MATRIX_SIZE + index] = cosine * row_value - sine * col_value
			eigenvectors[pivot_col * MATRIX_SIZE + index] = sine * row_value + cosine * col_value
	var maximum_diagonal := 0.0
	for index in MATRIX_SIZE:
		maximum_diagonal = maxf(maximum_diagonal, absf(work[index * MATRIX_SIZE + index]))
	if maximum_diagonal <= 1.0e-12:
		return PackedFloat64Array()
	for index in MATRIX_SIZE:
		if work[index * MATRIX_SIZE + index] < -maximum_diagonal * max_negative_ratio:
			return PackedFloat64Array()
	var result := zero_matrix()
	for row in MATRIX_SIZE:
		for col in MATRIX_SIZE:
			var value := 0.0
			for eigen_index in MATRIX_SIZE:
				var eigenvalue := maxf(work[eigen_index * MATRIX_SIZE + eigen_index], 0.0)
				value += eigenvectors[eigen_index * MATRIX_SIZE + row] * eigenvalue \
					* eigenvectors[eigen_index * MATRIX_SIZE + col]
			result[row * MATRIX_SIZE + col] = value
	return result


static func is_finite_matrix(matrix: PackedFloat64Array) -> bool:
	if matrix.size() != MATRIX_SCALARS:
		return false
	for value in matrix:
		if not is_finite(value):
			return false
	return true


static func vector_dot(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	if a.size() != MATRIX_SIZE or b.size() != MATRIX_SIZE:
		return NAN
	var result := 0.0
	for i in MATRIX_SIZE:
		result += a[i] * b[i]
	return result


static func semidirect_coupling_wrench(momentum: PackedFloat64Array,
		velocity: PackedFloat64Array) -> PackedFloat64Array:
	if momentum.size() != MATRIX_SIZE or velocity.size() != MATRIX_SIZE:
		return PackedFloat64Array()
	var linear_momentum := Vector3(momentum[3], momentum[4], momentum[5])
	var linear_velocity := Vector3(velocity[3], velocity[4], velocity[5])
	var torque := linear_momentum.cross(linear_velocity)
	return PackedFloat64Array([torque.x, torque.y, torque.z, 0.0, 0.0, 0.0])


static func gravity_buoyancy_wrench(body_mass_kg: float, displaced_mass_kg: float,
			gravity_local: Vector3, center_of_volume_m: Vector3) -> PackedFloat64Array:
	var wrench := PackedFloat64Array()
	wrench.resize(MATRIX_SIZE)
	var force := (body_mass_kg - displaced_mass_kg) * gravity_local
	var torque := -center_of_volume_m.cross(displaced_mass_kg * gravity_local)
	wrench[0] = torque.x
	wrench[1] = torque.y
	wrench[2] = torque.z
	wrench[3] = force.x
	wrench[4] = force.y
	wrench[5] = force.z
	return wrench


static func clip_convex_mesh_below_plane(triangle_vertices: PackedVector3Array,
			interior_point: Vector3, plane_normal: Vector3, plane_offset: float) -> Dictionary:
	if triangle_vertices.is_empty() or triangle_vertices.size() % 3 != 0 \
		or plane_normal.length_squared() <= 1.0e-12:
		return {}
	var normal := plane_normal.normalized()
	var minimum_distance := INF
	var maximum_distance := -INF
	for vertex in triangle_vertices:
		var distance := normal.dot(vertex) - plane_offset
		minimum_distance = minf(minimum_distance, distance)
		maximum_distance = maxf(maximum_distance, distance)
	var face_count := triangle_vertices.size() / 3
	var wet_fractions := PackedFloat64Array()
	wet_fractions.resize(face_count)
	var wet_centers := PackedVector3Array()
	wet_centers.resize(face_count)
	for face_index in face_count:
		var base := face_index * 3
		wet_centers[face_index] = (triangle_vertices[base]
			+ triangle_vertices[base + 1] + triangle_vertices[base + 2]) / 3.0
	if maximum_distance <= 1.0e-8:
		wet_fractions.fill(1.0)
		return {
			volume_m3 = _mesh_signed_volume(triangle_vertices, interior_point),
			centroid_m = interior_point,
			wet_area_fractions = wet_fractions,
			wet_area_centers_m = wet_centers,
			wetted_area_fraction = 1.0,
			waterline_points = PackedVector3Array(),
		}
	if minimum_distance >= -1.0e-8:
		return {
			volume_m3 = 0.0,
			centroid_m = interior_point,
			wet_area_fractions = wet_fractions,
			wet_area_centers_m = wet_centers,
			wetted_area_fraction = 0.0,
			waterline_points = PackedVector3Array(),
		}

	var clipped_surfaces: Array[PackedVector3Array] = []
	var waterline_points := PackedVector3Array()
	var total_surface_area := 0.0
	var wetted_surface_area := 0.0
	for face_index in face_count:
		var base := face_index * 3
		var a := triangle_vertices[base]
		var b := triangle_vertices[base + 1]
		var c := triangle_vertices[base + 2]
		if (b - a).cross(c - a).dot((a + b + c) / 3.0 - interior_point) < 0.0:
			var swap := b
			b = c
			c = swap
		var original_area := (b - a).cross(c - a).length() * 0.5
		total_surface_area += original_area
		var clipped := _clip_triangle_below_plane(a, b, c, normal, plane_offset)
		var polygon: PackedVector3Array = clipped.polygon
		if polygon.size() >= 3:
			clipped_surfaces.append(polygon)
			var clipped_area := _polygon_area(polygon)
			wet_fractions[face_index] = clampf(clipped_area / original_area, 0.0, 1.0)
			wet_centers[face_index] = _polygon_area_centroid(polygon)
			wetted_surface_area += clipped_area
		for point: Vector3 in clipped.intersections:
			_append_unique_point(waterline_points, point)

	var cap_surface_index := -1
	if waterline_points.size() >= 3:
		var cap_center := Vector3.ZERO
		for point in waterline_points:
			cap_center += point
		cap_center /= float(waterline_points.size())
		var reference_axis := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var tangent_x := normal.cross(reference_axis).normalized()
		var tangent_y := normal.cross(tangent_x).normalized()
		var sorted_points: Array[Vector3] = []
		for point in waterline_points:
			sorted_points.append(point)
		sorted_points.sort_custom(func(left: Vector3, right: Vector3) -> bool:
			var left_delta := left - cap_center
			var right_delta := right - cap_center
			return atan2(left_delta.dot(tangent_y), left_delta.dot(tangent_x)) \
				< atan2(right_delta.dot(tangent_y), right_delta.dot(tangent_x)))
		waterline_points.clear()
		for point in sorted_points:
			waterline_points.append(point)
		cap_surface_index = clipped_surfaces.size()
		clipped_surfaces.append(waterline_points)

	var signed_volume := 0.0
	var weighted_centroid := Vector3.ZERO
	for surface_index in clipped_surfaces.size():
		var polygon := clipped_surfaces[surface_index]
		for triangle_index in range(1, polygon.size() - 1):
			var a := polygon[0]
			var b := polygon[triangle_index]
			var c := polygon[triangle_index + 1]
			if surface_index == cap_surface_index and (b - a).cross(c - a).dot(normal) < 0.0:
				var swap := b
				b = c
				c = swap
			var tetra_volume := a.dot(b.cross(c)) / 6.0
			signed_volume += tetra_volume
			weighted_centroid += (a + b + c) * (tetra_volume * 0.25)
	var submerged_volume := absf(signed_volume)
	var centroid := interior_point
	if absf(signed_volume) > 1.0e-12:
		centroid = weighted_centroid / signed_volume
	return {
		volume_m3 = submerged_volume,
		centroid_m = centroid,
		wet_area_fractions = wet_fractions,
		wet_area_centers_m = wet_centers,
		wetted_area_fraction = wetted_surface_area / total_surface_area \
			if total_surface_area > 1.0e-12 else 0.0,
		waterline_points = waterline_points,
	}


static func _mesh_signed_volume(triangle_vertices: PackedVector3Array,
			interior_point: Vector3) -> float:
	var signed_volume := 0.0
	for base in range(0, triangle_vertices.size(), 3):
		var a := triangle_vertices[base]
		var b := triangle_vertices[base + 1]
		var c := triangle_vertices[base + 2]
		if (b - a).cross(c - a).dot((a + b + c) / 3.0 - interior_point) < 0.0:
			var swap := b
			b = c
			c = swap
		signed_volume += (a - interior_point).dot((b - interior_point).cross(c - interior_point)) / 6.0
	return absf(signed_volume)


static func _clip_triangle_below_plane(a: Vector3, b: Vector3, c: Vector3,
			normal: Vector3, plane_offset: float) -> Dictionary:
	var triangle := PackedVector3Array([a, b, c])
	var polygon := PackedVector3Array()
	var intersections := PackedVector3Array()
	for edge_index in 3:
		var current := triangle[edge_index]
		var next := triangle[(edge_index + 1) % 3]
		var current_distance := normal.dot(current) - plane_offset
		var next_distance := normal.dot(next) - plane_offset
		if current_distance <= 0.0:
			_append_unique_point(polygon, current)
		if absf(current_distance) <= 1.0e-8:
			_append_unique_point(intersections, current)
		if (current_distance < 0.0 and next_distance > 0.0) \
				or (current_distance > 0.0 and next_distance < 0.0):
			var fraction := current_distance / (current_distance - next_distance)
			var crossing := current.lerp(next, fraction)
			_append_unique_point(polygon, crossing)
			_append_unique_point(intersections, crossing)
	return {polygon = polygon, intersections = intersections}


static func _polygon_area(polygon: PackedVector3Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var area := 0.0
	for index in range(1, polygon.size() - 1):
		area += (polygon[index] - polygon[0]).cross(polygon[index + 1] - polygon[0]).length() * 0.5
	return area


static func _polygon_area_centroid(polygon: PackedVector3Array) -> Vector3:
	if polygon.size() < 3:
		return Vector3.ZERO
	var area := 0.0
	var weighted_centroid := Vector3.ZERO
	for index in range(1, polygon.size() - 1):
		var a := polygon[0]
		var b := polygon[index]
		var c := polygon[index + 1]
		var triangle_area := (b - a).cross(c - a).length() * 0.5
		area += triangle_area
		weighted_centroid += (a + b + c) * (triangle_area / 3.0)
	return weighted_centroid / area if area > 1.0e-12 else Vector3.ZERO


static func _append_unique_point(points: PackedVector3Array, point: Vector3) -> void:
	for existing in points:
		if existing.distance_squared_to(point) <= 1.0e-12:
			return
	points.append(point)


static func potential_pressure_wrench(face_centers_m: PackedVector3Array,
			face_normals: PackedVector3Array, face_areas_m2: PackedFloat64Array,
			slip_matrix: PackedFloat64Array, generalized_velocity: PackedFloat64Array,
			fluid_density_kg_m3: float, separation_angle_rad: float,
			wet_area_fractions := PackedFloat64Array(),
			wet_area_centers_m := PackedVector3Array()) -> Dictionary:
	var pressure := PackedFloat64Array()
	pressure.resize(MATRIX_SIZE)
	if face_centers_m.size() == 0 or face_centers_m.size() != face_normals.size() \
		or face_centers_m.size() != face_areas_m2.size() \
		or slip_matrix.size() != face_centers_m.size() * 18 \
		or (not wet_area_fractions.is_empty() \
			and wet_area_fractions.size() != face_centers_m.size()) \
		or (not wet_area_centers_m.is_empty() \
			and wet_area_centers_m.size() != face_centers_m.size()) \
		or generalized_velocity.size() != MATRIX_SIZE:
		return {pressure = pressure, attached_faces = 0}
	if not is_finite(fluid_density_kg_m3) or fluid_density_kg_m3 <= 0.0:
		return {pressure = pressure, attached_faces = 0}
	var cos_separation := cos(clampf(separation_angle_rad, PI * 0.5, PI))
	var body_relative_velocity := Vector3(generalized_velocity[3],
		generalized_velocity[4], generalized_velocity[5])
	var body_speed_squared := body_relative_velocity.length_squared()
	if body_speed_squared <= 1.0e-16:
		return {pressure = pressure, attached_faces = 0}
	var incoming_flow_direction := -body_relative_velocity.normalized()
	var attached_faces := 0
	for face_index in face_centers_m.size():
		var face_center := face_centers_m[face_index]
		var center := face_center if wet_area_centers_m.is_empty() \
			else wet_area_centers_m[face_index]
		var normal := face_normals[face_index]
		var wet_fraction := 1.0 if wet_area_fractions.is_empty() else \
			clampf(wet_area_fractions[face_index], 0.0, 1.0)
		var area := face_areas_m2[face_index] * wet_fraction
		if area <= 1.0e-12:
			continue
		var attached := normal.dot(incoming_flow_direction) >= cos_separation
		if attached:
			attached_faces += 1
		var slip := Vector3.ZERO
		var base := face_index * 18
		for row in 3:
			var value := 0.0
			for col in MATRIX_SIZE:
				value += slip_matrix[base + row * MATRIX_SIZE + col] * generalized_velocity[col]
			slip[row] = value
		var center_delta := center - face_center
		if center_delta.length_squared() > 1.0e-16:
			var angular_velocity := Vector3(generalized_velocity[0],
				generalized_velocity[1], generalized_velocity[2])
			var tangent_delta := angular_velocity.cross(center_delta)
			slip -= tangent_delta - normal * normal.dot(tangent_delta)
		var slip_speed := slip.length()
		if attached:
			var pressure_delta := 0.5 * fluid_density_kg_m3 \
				* (body_speed_squared - slip_speed * slip_speed)
			var pressure_force := -pressure_delta * area * normal
			_accumulate_wrench(pressure, center.cross(pressure_force), pressure_force)
	return {pressure = pressure, attached_faces = attached_faces}


static func particle_drag_wrench(generalized_velocity: PackedFloat64Array,
			dynamic_viscosity_pa_s: float, fluid_density_kg_m3: float, body_volume_m3: float,
			wetted_area_fraction: float, body_surface_area_m2 := 0.0) -> PackedFloat64Array:
	var wrench := PackedFloat64Array()
	wrench.resize(MATRIX_SIZE)
	if generalized_velocity.size() != MATRIX_SIZE or not is_finite(dynamic_viscosity_pa_s) \
			or dynamic_viscosity_pa_s < 0.0 or not is_finite(fluid_density_kg_m3) \
			or fluid_density_kg_m3 <= 0.0 \
			or body_volume_m3 <= 0.0 or wetted_area_fraction <= 0.0:
		return wrench
	var radius := pow(3.0 * body_volume_m3 / (4.0 * PI), 1.0 / 3.0)
	var wetted := clampf(wetted_area_fraction, 0.0, 1.0)
	var equivalent_sphere_area := 4.0 * PI * radius * radius
	var projected_sphere_area := PI * radius * radius
	var measured_surface_area := body_surface_area_m2 if is_finite(body_surface_area_m2) \
		and body_surface_area_m2 > 0.0 else equivalent_sphere_area
	var sphericity := clampf(equivalent_sphere_area / measured_surface_area, 0.026, 1.0)
	var speed := Vector3(generalized_velocity[3], generalized_velocity[4],
		generalized_velocity[5]).length()
	var reynolds := INF if dynamic_viscosity_pa_s == 0.0 else \
		2.0 * radius * fluid_density_kg_m3 * speed / dynamic_viscosity_pa_s
	var coefficient_a := exp(2.3288 - 6.4581 * sphericity + 2.4486 * sphericity * sphericity)
	var coefficient_b := 0.0964 + 0.5565 * sphericity
	var coefficient_c := exp(4.905 - 13.8944 * sphericity + 18.4222 * sphericity * sphericity \
		- 10.2599 * sphericity * sphericity * sphericity)
	var coefficient_d := exp(1.4681 + 12.2584 * sphericity - 20.7322 * sphericity * sphericity \
		+ 15.8855 * sphericity * sphericity * sphericity)
	var drag_magnitude := 0.0
	if speed > 1.0e-12:
		if dynamic_viscosity_pa_s == 0.0:
			drag_magnitude = 0.5 * fluid_density_kg_m3 * speed * speed \
				* projected_sphere_area * coefficient_c * wetted
		else:
			if reynolds < 1.0e-8:
				drag_magnitude = 6.0 * PI * dynamic_viscosity_pa_s * radius \
					* speed * wetted
			else:
				var drag_coefficient := 24.0 / reynolds \
					* (1.0 + coefficient_a * pow(reynolds, coefficient_b)) \
					+ coefficient_c / (1.0 + coefficient_d / reynolds)
				drag_magnitude = 0.5 * fluid_density_kg_m3 * speed * speed \
					* projected_sphere_area * drag_coefficient * wetted
	var linear_velocity := Vector3(generalized_velocity[3], generalized_velocity[4],
		generalized_velocity[5])
	var drag_force := -linear_velocity.normalized() * drag_magnitude \
		if speed > 1.0e-12 else Vector3.ZERO
	var angular_velocity := Vector3(generalized_velocity[0], generalized_velocity[1],
		generalized_velocity[2])
	var angular_speed := angular_velocity.length()
	var rotational_drag_torque := 0.0
	if angular_speed > 1.0e-12 and dynamic_viscosity_pa_s > 0.0:
		var rotational_reynolds := fluid_density_kg_m3 * radius * radius * angular_speed \
			/ dynamic_viscosity_pa_s
		if rotational_reynolds < 6.03:
			rotational_drag_torque = 8.0 * PI * dynamic_viscosity_pa_s \
				* pow(radius, 3.0) * angular_speed
		else:
			var torque_coefficient := 0.0
			if rotational_reynolds < 20.37:
				torque_coefficient = 5.32 / sqrt(rotational_reynolds) \
					+ 37.2 / rotational_reynolds
			else:
				torque_coefficient = 6.45 / sqrt(rotational_reynolds) \
					+ 32.1 / rotational_reynolds
			rotational_drag_torque = 0.5 * fluid_density_kg_m3 * pow(radius, 5.0) \
				* torque_coefficient * angular_speed * angular_speed
		rotational_drag_torque *= wetted
	for axis in 3:
		wrench[axis] = -rotational_drag_torque * angular_velocity[axis] / angular_speed \
			if angular_speed > 1.0e-12 else 0.0
		wrench[axis + 3] = drag_force[axis]
	return wrench


static func _accumulate_wrench(wrench: PackedFloat64Array, torque: Vector3, force: Vector3) -> void:
	wrench[0] += torque.x
	wrench[1] += torque.y
	wrench[2] += torque.z
	wrench[3] += force.x
	wrench[4] += force.y
	wrench[5] += force.z


static func semi_implicit_momentum_step(momentum: PackedFloat64Array,
		wrench: PackedFloat64Array, delta: float) -> PackedFloat64Array:
	return vector_add(momentum, vector_scale(wrench, delta))
