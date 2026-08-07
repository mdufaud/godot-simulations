class_name AmbientFluidProfile3D
extends Resource

const FORMAT_ANALYTIC := 1
const FORMAT_BEM := 3

const MATH := preload("res://scripts/ambient_fluid/ambient_fluid_math.gd")

@export var format_version: int = FORMAT_ANALYTIC
@export var source_mesh_uid: int = 0
@export var source_mesh_hash: String = ""
@export var reference_density_kg_m3: float = 998.0
@export var volume_m3: float = 1.0
@export var center_of_volume_m: Vector3 = Vector3.ZERO
@export var total_area_m2: float = 0.0
@export var characteristic_length_m: float = 0.0
@export var face_centers_m: PackedVector3Array = PackedVector3Array()
@export var face_normals: PackedVector3Array = PackedVector3Array()
@export var face_areas_m2: PackedFloat64Array = PackedFloat64Array()
@export var added_mass_tensor: PackedFloat64Array = PackedFloat64Array()
@export var slip_matrix: PackedFloat64Array = PackedFloat64Array()
@export var source_offset_m: float = 0.0
@export var bem_psd_clamped: bool = false
@export var bem_max_residual: float = 0.0


func ensure_analytic_geometry() -> void:
	if face_centers_m.size() > 0 or face_normals.size() > 0 or face_areas_m2.size() > 0:
		return
	var radius := pow(volume_m3 * 3.0 / (4.0 * PI), 1.0 / 3.0)
	var golden_ratio := (1.0 + sqrt(5.0)) * 0.5
	var scale := radius / sqrt(1.0 + golden_ratio * golden_ratio)
	var vertices: Array[Vector3] = [
		Vector3(-1.0, golden_ratio, 0.0), Vector3(1.0, golden_ratio, 0.0),
		Vector3(-1.0, -golden_ratio, 0.0), Vector3(1.0, -golden_ratio, 0.0),
		Vector3(0.0, -1.0, golden_ratio), Vector3(0.0, 1.0, golden_ratio),
		Vector3(0.0, -1.0, -golden_ratio), Vector3(0.0, 1.0, -golden_ratio),
		Vector3(golden_ratio, 0.0, -1.0), Vector3(golden_ratio, 0.0, 1.0),
		Vector3(-golden_ratio, 0.0, -1.0), Vector3(-golden_ratio, 0.0, 1.0),
	]
	for i in vertices.size():
		vertices[i] *= scale
	var faces: Array[PackedInt32Array] = [
		PackedInt32Array([0, 11, 5]), PackedInt32Array([0, 5, 1]),
		PackedInt32Array([0, 1, 7]), PackedInt32Array([0, 7, 10]),
		PackedInt32Array([0, 10, 11]), PackedInt32Array([1, 5, 9]),
		PackedInt32Array([5, 11, 4]), PackedInt32Array([11, 10, 2]),
		PackedInt32Array([10, 7, 6]), PackedInt32Array([7, 1, 8]),
		PackedInt32Array([3, 9, 4]), PackedInt32Array([3, 4, 2]),
		PackedInt32Array([3, 2, 6]), PackedInt32Array([3, 6, 8]),
		PackedInt32Array([3, 8, 9]), PackedInt32Array([4, 9, 5]),
		PackedInt32Array([2, 4, 11]), PackedInt32Array([6, 2, 10]),
		PackedInt32Array([8, 6, 7]), PackedInt32Array([9, 8, 1]),
	]
	face_centers_m = PackedVector3Array()
	face_normals = PackedVector3Array()
	face_areas_m2 = PackedFloat64Array()
	for face in faces:
		var a: Vector3 = vertices[face[0]]
		var b: Vector3 = vertices[face[1]]
		var c: Vector3 = vertices[face[2]]
		var cross := (b - a).cross(c - a)
		face_centers_m.append((a + b + c) / 3.0)
		face_normals.append(cross.normalized())
		face_areas_m2.append(cross.length() * 0.5)


func validate() -> String:
	if format_version != FORMAT_ANALYTIC and format_version != FORMAT_BEM:
		return "unsupported ambient fluid profile format_version"
	if format_version == FORMAT_ANALYTIC:
		ensure_analytic_geometry()
	if added_mass_tensor.is_empty():
		var added_mass := reference_density_kg_m3 * volume_m3 * 0.5
		added_mass_tensor = MATH.zero_matrix()
		added_mass_tensor[21] = added_mass
		added_mass_tensor[28] = added_mass
		added_mass_tensor[35] = added_mass
	if not is_finite(reference_density_kg_m3) or reference_density_kg_m3 <= 0.0:
		return "reference_density_kg_m3 must be finite and positive"
	if not is_finite(volume_m3) or volume_m3 <= 0.0:
		return "volume_m3 must be finite and positive"
	if not _finite_vector(center_of_volume_m):
		return "center_of_volume_m must be finite"
	if face_centers_m.size() == 0 or face_centers_m.size() != face_normals.size() \
		or face_centers_m.size() != face_areas_m2.size():
		return "face geometry arrays must have equal non-zero length"
	if format_version == FORMAT_BEM:
		if source_mesh_hash.is_empty():
			return "BEM source_mesh_hash must not be empty"
		if not is_finite(total_area_m2) or total_area_m2 <= 0.0:
			return "total_area_m2 must be finite and positive"
		if not is_finite(characteristic_length_m) or characteristic_length_m <= 0.0:
			return "characteristic_length_m must be finite and positive"
		if not is_finite(source_offset_m) or source_offset_m <= 0.0:
			return "source_offset_m must be finite and positive"
		if not is_finite(bem_max_residual) or bem_max_residual < 0.0 \
			or bem_max_residual > 1.0e-7:
			return "BEM residual must be finite and at most 1e-7"
		if slip_matrix.size() != face_centers_m.size() * 18:
			return "BEM slip_matrix must contain 18 values per face"
		for value in slip_matrix:
			if not is_finite(value):
				return "BEM slip_matrix must contain only finite values"
	else:
		if slip_matrix.size() != 0:
			return "analytic profile slip_matrix must be empty"
	if added_mass_tensor.size() != MATH.MATRIX_SCALARS:
		return "added_mass_tensor must contain 36 values"
	for center in face_centers_m:
		if not _finite_vector(center):
			return "face center must be finite"
	for normal in face_normals:
		if not _finite_vector(normal) or absf(normal.length() - 1.0) > 1.0e-5:
			return "face normals must be finite and normalized"
	for area in face_areas_m2:
		if not is_finite(area) or area <= 0.0:
			return "face areas must be finite and positive"
	if format_version == FORMAT_BEM:
		var measured_area := 0.0
		for area in face_areas_m2:
			measured_area += area
		if absf(measured_area - total_area_m2) > maxf(1.0e-8, measured_area * 1.0e-6):
			return "total_area_m2 does not match face areas"
		if absf(characteristic_length_m - sqrt(total_area_m2)) \
			> maxf(1.0e-8, characteristic_length_m * 1.0e-6):
			return "characteristic_length_m must equal sqrt(total_area_m2)"
	if not MATH.is_finite_matrix(added_mass_tensor) or not MATH.is_symmetric(added_mass_tensor):
		return "added_mass_tensor must be finite and symmetric"
	if format_version == FORMAT_BEM and not MATH.is_positive_semidefinite(added_mass_tensor):
		return "BEM added_mass_tensor must be positive semidefinite"
	if not MATH.is_positive_definite(MATH.matrix_add(
		added_mass_tensor, MATH.diagonal_matrix(Vector3.ONE, 1.0))):
		return "added_mass_tensor failed positive-definiteness check"
	return ""


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
