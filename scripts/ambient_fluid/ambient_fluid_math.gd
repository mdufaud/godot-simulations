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


static func surface_wrench(face_centers_m: PackedVector3Array,
		face_normals: PackedVector3Array, face_areas_m2: PackedFloat64Array,
		slip_matrix: PackedFloat64Array, generalized_velocity: PackedFloat64Array,
		fluid_density_kg_m3: float, dynamic_viscosity_pa_s: float,
		separation_angle_rad: float, characteristic_length_m: float) -> Dictionary:
	var pressure := PackedFloat64Array()
	pressure.resize(MATRIX_SIZE)
	var friction := PackedFloat64Array()
	friction.resize(MATRIX_SIZE)
	if face_centers_m.size() == 0 or face_centers_m.size() != face_normals.size() \
		or face_centers_m.size() != face_areas_m2.size() \
		or slip_matrix.size() != face_centers_m.size() * 18 \
		or generalized_velocity.size() != MATRIX_SIZE:
		return {pressure = pressure, friction = friction, attached_faces = 0}
	if not is_finite(fluid_density_kg_m3) or fluid_density_kg_m3 <= 0.0:
		return {pressure = pressure, friction = friction, attached_faces = 0}
	var cos_separation := cos(clampf(separation_angle_rad, PI * 0.5, PI))
	var attached_faces := 0
	for face_index in face_centers_m.size():
		var center := face_centers_m[face_index]
		var normal := face_normals[face_index]
		var area := face_areas_m2[face_index]
		var relative_surface_velocity := Vector3(
			generalized_velocity[3], generalized_velocity[4], generalized_velocity[5]) \
			+ Vector3(generalized_velocity[0], generalized_velocity[1], generalized_velocity[2]).cross(center)
		var relative_speed := relative_surface_velocity.length()
		if relative_speed <= 1.0e-8:
			continue
		if normal.dot(relative_surface_velocity / relative_speed) <= cos_separation:
			continue
		attached_faces += 1
		var slip := Vector3.ZERO
		var base := face_index * 18
		for row in 3:
			var value := 0.0
			for col in MATRIX_SIZE:
				value += slip_matrix[base + row * MATRIX_SIZE + col] * generalized_velocity[col]
			slip[row] = value
		var slip_speed := slip.length()
		if slip_speed <= 1.0e-8:
			continue
		var pressure_force := -0.5 * fluid_density_kg_m3 * slip_speed * slip_speed * area * normal
		_accumulate_wrench(pressure, center.cross(pressure_force), pressure_force)
		if dynamic_viscosity_pa_s <= 0.0 or characteristic_length_m <= 0.0:
			continue
		var reynolds := fluid_density_kg_m3 * slip_speed * characteristic_length_m \
			/ dynamic_viscosity_pa_s
		if not is_finite(reynolds) or reynolds < 1.0e-8:
			continue
		var skin_friction_coefficient := 0.0576 * pow(reynolds, -0.2)
		var friction_force := 0.5 * skin_friction_coefficient * fluid_density_kg_m3 \
			* slip_speed * area * slip
		_accumulate_wrench(friction, center.cross(friction_force), friction_force)
	return {pressure = pressure, friction = friction, attached_faces = attached_faces}


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
