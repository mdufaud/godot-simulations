extends "res://tests/test_case.gd"

const PREPROCESSOR := preload("res://scripts/ambient_fluid/ambient_fluid_preprocessor.gd")
const PROFILE := preload("res://scripts/ambient_fluid/ambient_fluid_profile_3d.gd")


func _initialize() -> void:
	_test_tetrahedron()
	_test_cube()
	_test_icosphere()
	_test_invalid_meshes()
	_test_profile_validation()
	_test_serialization()
	_finish("ambient_fluid_preprocessor")


func _test_tetrahedron() -> void:
	var vertices := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0),
	])
	var indices := PackedInt32Array([
		0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3,
	])
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, indices), 998.0)
	_check(profile != null, "tetrahedron preprocessing failed: %s" % PREPROCESSOR.get_last_error())
	if profile == null:
		return
	_check(profile.validate() == "", "tetrahedron profile is invalid")
	_check(absf(profile.volume_m3 - 1.0 / 6.0) < 1.0e-6,
		"tetrahedron volume is wrong")
	_check(profile.center_of_volume_m.distance_to(Vector3.ONE * 0.25) < 1.0e-6,
		"tetrahedron center of volume is wrong")
	_check(profile.face_centers_m.size() == 4, "tetrahedron face count is wrong")
	_check(_profile_invariants(profile), "tetrahedron BEM invariants failed")


func _test_cube() -> void:
	var vertices := _cube_vertices()
	var indices := _cube_indices()
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, indices), 998.0)
	_check(profile != null, "cube preprocessing failed: %s" % PREPROCESSOR.get_last_error())
	if profile == null:
		return
	_check(absf(profile.volume_m3 - 8.0) < 1.0e-6, "cube volume is wrong")
	_check(profile.center_of_volume_m.length() < 1.0e-6,
		"cube center of volume is wrong")
	_check(profile.face_centers_m.size() == 12, "cube face count is wrong")
	_check(_profile_invariants(profile), "cube BEM invariants failed")
	var reversed_indices := PackedInt32Array()
	for index in range(0, indices.size(), 3):
		reversed_indices.append(indices[index])
		reversed_indices.append(indices[index + 2])
		reversed_indices.append(indices[index + 1])
	var reversed_profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, reversed_indices), 998.0)
	_check(reversed_profile != null, "reversed cube was not corrected")
	if reversed_profile != null:
		_check(absf(reversed_profile.volume_m3 - profile.volume_m3) < 1.0e-6,
			"reversed cube volume changed")


func _test_icosphere() -> void:
	var golden_ratio := (1.0 + sqrt(5.0)) * 0.5
	var scale := 1.0 / sqrt(1.0 + golden_ratio * golden_ratio)
	var vertices := PackedVector3Array([
		Vector3(-1.0, golden_ratio, 0.0), Vector3(1.0, golden_ratio, 0.0),
		Vector3(-1.0, -golden_ratio, 0.0), Vector3(1.0, -golden_ratio, 0.0),
		Vector3(0.0, -1.0, golden_ratio), Vector3(0.0, 1.0, golden_ratio),
		Vector3(0.0, -1.0, -golden_ratio), Vector3(0.0, 1.0, -golden_ratio),
		Vector3(golden_ratio, 0.0, -1.0), Vector3(golden_ratio, 0.0, 1.0),
		Vector3(-golden_ratio, 0.0, -1.0), Vector3(-golden_ratio, 0.0, 1.0),
	])
	for index in vertices.size():
		vertices[index] *= scale
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
	var indices := PackedInt32Array()
	for face in faces:
		indices.append_array(face)
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, indices), 998.0)
	_check(profile != null, "icosphere preprocessing failed: %s" % PREPROCESSOR.get_last_error())
	if profile == null:
		return
	_check(profile.face_centers_m.size() == 20, "icosphere face count is wrong")
	_check(profile.center_of_volume_m.length() < 1.0e-6,
		"icosphere center of volume is wrong")
	_check(_profile_invariants(profile), "icosphere BEM invariants failed")
	var expected_translation := 998.0 * profile.volume_m3 * 0.5
	var relative_error := absf(profile.added_mass_tensor[21] - expected_translation) / expected_translation
	_check(relative_error < 0.35, "icosphere translation added mass is not spherical")
	_check(absf(profile.added_mass_tensor[21] - profile.added_mass_tensor[28]) \
		/ expected_translation < 0.08, "icosphere added mass is anisotropic on x/y")
	_check(absf(profile.added_mass_tensor[28] - profile.added_mass_tensor[35]) \
		/ expected_translation < 0.08, "icosphere added mass is anisotropic on y/z")
	var refined_profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_build_icosphere(1), 998.0)
	_check(refined_profile != null,
		"refined icosphere preprocessing failed: %s" % PREPROCESSOR.get_last_error())
	if refined_profile != null:
		var refined_expected := 998.0 * refined_profile.volume_m3 * 0.5
		var refined_error := absf(refined_profile.added_mass_tensor[21] - refined_expected) \
			/ refined_expected
		_check(refined_error < 0.25, "refined icosphere added mass is not bounded")
		_check(refined_error <= relative_error,
			"icosphere added mass did not converge under refinement")


func _test_invalid_meshes() -> void:
	var vertices := _cube_vertices()
	var open_indices := _cube_indices()
	open_indices.resize(open_indices.size() - 3)
	var open_profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, open_indices), 998.0)
	_check(open_profile == null, "open mesh was accepted")
	var degenerate := PackedInt32Array([0, 1, 1])
	var degenerate_profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(vertices, degenerate), 998.0)
	_check(degenerate_profile == null, "degenerate mesh was accepted")


func _test_profile_validation() -> void:
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(_cube_vertices(), _cube_indices()), 998.0)
	if profile == null:
		_check(false, "profile validation fixture preprocessing failed")
		return
	var invalid_slip: AmbientFluidProfile3D = profile.duplicate(true)
	invalid_slip.slip_matrix[0] = NAN
	_check(invalid_slip.validate() != "", "non-finite slip matrix was accepted")
	var invalid_area: AmbientFluidProfile3D = profile.duplicate(true)
	invalid_area.total_area_m2 *= 1.1
	_check(invalid_area.validate() != "", "inconsistent total area was accepted")
	var invalid_length: AmbientFluidProfile3D = profile.duplicate(true)
	invalid_length.characteristic_length_m *= 1.1
	_check(invalid_length.validate() != "", "inconsistent characteristic length was accepted")
	var invalid_hash: AmbientFluidProfile3D = profile.duplicate(true)
	invalid_hash.source_mesh_hash = ""
	_check(invalid_hash.validate() != "", "empty BEM source hash was accepted")


func _test_serialization() -> void:
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		_mesh(_cube_vertices(), _cube_indices()), 998.0)
	if profile == null:
		_check(false, "serialization fixture preprocessing failed")
		return
	var path := "res://resources/ambient_fluid/.ambient_fluid_phase2_test.tres"
	var save_error := PREPROCESSOR.save_profile(profile, path)
	_check(save_error == "", "profile save failed: %s" % save_error)
	var reloaded: AmbientFluidProfile3D = load(path)
	_check(reloaded != null and reloaded.validate() == "", "saved profile did not reload")
	if reloaded != null:
		_check(_array_near(reloaded.added_mass_tensor, profile.added_mass_tensor, 1.0e-6),
			"reloaded added mass changed")
		_check(_array_near(reloaded.slip_matrix, profile.slip_matrix, 1.0e-6),
			"reloaded slip matrix changed")
	_check(PREPROCESSOR.save_profile(profile, "user://invalid.tres") != "",
		"profile save accepted a non-resources path")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _profile_invariants(profile: AmbientFluidProfile3D) -> bool:
	if profile.format_version != PROFILE.FORMAT_BEM:
		return false
	if not _matrix_near_transpose(profile.added_mass_tensor, 1.0e-6):
		return false
	if not _positive_diagonal(profile.added_mass_tensor):
		return false
	_check(profile.bem_max_residual <= 1.0e-7, "BEM residual exceeds tolerance")
	for face_index in profile.face_centers_m.size():
		var normal := profile.face_normals[face_index]
		var center := profile.face_centers_m[face_index]
		var base := face_index * 18
		for sample in [PackedFloat64Array([1.0, 2.0, -0.5, 3.0, -1.0, 0.25]),
			PackedFloat64Array([-0.2, 0.4, 1.5, -2.0, 0.5, 4.0])]:
			var projected := Vector3.ZERO
			for row in 3:
				var value := 0.0
				for col in 6:
					value += profile.slip_matrix[base + row * 6 + col] * sample[col]
				projected[row] = value
			_check(absf(normal.dot(projected)) < 1.0e-6,
				"slip matrix has a normal component")
			var angular := Vector3(sample[0], sample[1], sample[2])
			var linear := Vector3(sample[3], sample[4], sample[5])
			var surface_velocity := linear + angular.cross(center)
			var expected := -(surface_velocity - normal * normal.dot(surface_velocity))
			_check(projected.distance_to(expected) < 1.0e-6,
				"slip matrix does not implement -PnR")
	return true


func _positive_diagonal(matrix: PackedFloat64Array) -> bool:
	return matrix[21] > 0.0 and matrix[28] > 0.0 and matrix[35] > 0.0


func _matrix_near_transpose(matrix: PackedFloat64Array, tolerance: float) -> bool:
	for row in 6:
		for col in 6:
			if absf(matrix[row * 6 + col] - matrix[col * 6 + row]) > tolerance:
				return false
	return true


func _array_near(a: PackedFloat64Array, b: PackedFloat64Array, tolerance: float) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if absf(a[index] - b[index]) > tolerance:
			return false
	return true


func _mesh(vertices: PackedVector3Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _cube_vertices() -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-1.0, -1.0, -1.0), Vector3(1.0, -1.0, -1.0),
		Vector3(1.0, 1.0, -1.0), Vector3(-1.0, 1.0, -1.0),
		Vector3(-1.0, -1.0, 1.0), Vector3(1.0, -1.0, 1.0),
		Vector3(1.0, 1.0, 1.0), Vector3(-1.0, 1.0, 1.0),
	])


func _cube_indices() -> PackedInt32Array:
	return PackedInt32Array([
		0, 2, 1, 0, 3, 2,
		4, 5, 6, 4, 6, 7,
		0, 4, 7, 0, 7, 3,
		1, 2, 6, 1, 6, 5,
		0, 1, 5, 0, 5, 4,
		3, 7, 6, 3, 6, 2,
	])


func _build_icosphere(subdivisions: int) -> ArrayMesh:
	var golden_ratio := (1.0 + sqrt(5.0)) * 0.5
	var scale := 1.0 / sqrt(1.0 + golden_ratio * golden_ratio)
	var vertices := PackedVector3Array([
		Vector3(-1.0, golden_ratio, 0.0), Vector3(1.0, golden_ratio, 0.0),
		Vector3(-1.0, -golden_ratio, 0.0), Vector3(1.0, -golden_ratio, 0.0),
		Vector3(0.0, -1.0, golden_ratio), Vector3(0.0, 1.0, golden_ratio),
		Vector3(0.0, -1.0, -golden_ratio), Vector3(0.0, 1.0, -golden_ratio),
		Vector3(golden_ratio, 0.0, -1.0), Vector3(golden_ratio, 0.0, 1.0),
		Vector3(-golden_ratio, 0.0, -1.0), Vector3(-golden_ratio, 0.0, 1.0),
	])
	for index in vertices.size():
		vertices[index] *= scale
	var faces: Array = [
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
	for _step in subdivisions:
		var midpoint_cache := {}
		var refined: Array = []
		for face in faces:
			var a: int = face[0]
			var b: int = face[1]
			var c: int = face[2]
			var ab := _midpoint_index(vertices, midpoint_cache, a, b)
			var bc := _midpoint_index(vertices, midpoint_cache, b, c)
			var ca := _midpoint_index(vertices, midpoint_cache, c, a)
			refined.append(PackedInt32Array([a, ab, ca]))
			refined.append(PackedInt32Array([b, bc, ab]))
			refined.append(PackedInt32Array([c, ca, bc]))
			refined.append(PackedInt32Array([ab, bc, ca]))
		faces = refined
	var indices := PackedInt32Array()
	for face in faces:
		indices.append_array(face)
	return _mesh(vertices, indices)


func _midpoint_index(vertices: PackedVector3Array, cache: Dictionary,
		first: int, second: int) -> int:
	var key := "%d:%d" % [mini(first, second), maxi(first, second)]
	if cache.has(key):
		return cache[key]
	var midpoint := (vertices[first] + vertices[second]).normalized()
	vertices.append(midpoint)
	var index := vertices.size() - 1
	cache[key] = index
	return index
