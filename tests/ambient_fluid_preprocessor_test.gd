extends "res://tests/test_case.gd"

const PREPROCESSOR := preload("res://scripts/ambient_fluid/ambient_fluid_preprocessor.gd")
const PROFILE := preload("res://scripts/ambient_fluid/ambient_fluid_profile_3d.gd")
const SHAPES := preload("res://scripts/ambient_fluid/ambient_fluid_shapes.gd")


func _initialize() -> void:
	_test_tetrahedron()
	_test_cube()
	_test_icosphere()
	_test_spheroids()
	_test_plate()
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
	# The demo sphere (320 faces) against 1/2 rho V.
	var demo_sphere: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		SHAPES.bem_mesh(SHAPES.Kind.SPHERE), 998.0)
	if demo_sphere != null:
		var coefficient := demo_sphere.added_mass_tensor[21] / (998.0 * demo_sphere.volume_m3)
		print("BEM sphere C_a=%.4f (exact 0.5)" % coefficient)
		_check(absf(coefficient - 0.5) < 0.015, "320-face sphere added mass is off by more than 3%")


## Ellipsoids against Lamb's closed forms (Hydrodynamics, Sec. 373): a 2:1
## prolate spheroid along and across its axis, and a 10:1 oblate one
## broadside, the thin-plate case the old point-source solver undershot.
func _test_spheroids() -> void:
	var prolate := _scaled_profile(Vector3(2.0, 1.0, 1.0))
	var oblate := _scaled_profile(Vector3(1.0, 0.1, 1.0))
	if prolate == null or oblate == null:
		_check(false, "spheroid preprocessing failed: %s" % PREPROCESSOR.get_last_error())
		return
	var e := sqrt(1.0 - 0.25)
	var log_term := log((1.0 + e) / (1.0 - e))
	var alpha := 2.0 * (1.0 - e * e) / (e * e * e) * (0.5 * log_term - e)
	var beta := 1.0 / (e * e) - (1.0 - e * e) / (2.0 * e * e * e) * log_term
	var axial := _coefficient(prolate, 21)
	var transverse := _coefficient(prolate, 28)
	var flat := sqrt(1.0 - 0.01)
	var gamma := 2.0 / (flat * flat) * (1.0 - sqrt(1.0 - flat * flat) * asin(flat) / flat)
	var broadside := _coefficient(oblate, 28)
	print("BEM spheroids axial=%.4f/%.4f transverse=%.4f/%.4f oblate broadside=%.4f/%.4f" % [
		axial, alpha / (2.0 - alpha), transverse, beta / (2.0 - beta),
		broadside, gamma / (2.0 - gamma)])
	_check(absf(axial / (alpha / (2.0 - alpha)) - 1.0) < 0.05,
		"prolate spheroid axial added mass is off Lamb's value")
	_check(absf(transverse / (beta / (2.0 - beta)) - 1.0) < 0.05,
		"prolate spheroid transverse added mass is off Lamb's value")
	_check(absf(broadside / (gamma / (2.0 - gamma)) - 1.0) < 0.08,
		"thin oblate spheroid broadside added mass is off Lamb's value")


func _scaled_profile(scale: Vector3) -> AmbientFluidProfile3D:
	var mesh := SHAPES.icosphere_mesh(1.0, 2)
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for index in vertices.size():
		vertices[index] *= scale
	return PREPROCESSOR.build_profile(_mesh(vertices, arrays[Mesh.ARRAY_INDEX]), 998.0)


func _coefficient(profile: AmbientFluidProfile3D, index: int) -> float:
	return profile.added_mass_tensor[index] / (998.0 * profile.volume_m3)


func _test_plate() -> void:
	# The demo plate (2.4 x 0.18 x 1.2 m): broadside, its added mass is several
	# times the displaced mass, close to an elliptic disk of the same outline
	# (~2150 kg); the old point-source solver gave 182 kg.
	var profile: AmbientFluidProfile3D = PREPROCESSOR.build_profile(
		SHAPES.bem_mesh(SHAPES.Kind.PLATE), 998.0)
	_check(profile != null, "plate preprocessing failed: %s" % PREPROCESSOR.get_last_error())
	if profile == null:
		return
	var tensor := profile.added_mass_tensor
	print("BEM plate added mass x=%.1f y=%.1f z=%.1f kg" % [tensor[21], tensor[28], tensor[35]])
	_check(tensor[28] > tensor[21] and tensor[28] > tensor[35],
		"plate broadside added mass is not dominant on y")
	_check(tensor[28] > 1800.0 and tensor[28] < 3000.0,
		"plate broadside added mass %.1f kg is far from the thin-disk estimate" % tensor[28])
	_check(_profile_invariants(profile), "plate BEM invariants failed")


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
	var invalid_vertices: AmbientFluidProfile3D = profile.duplicate(true)
	invalid_vertices.face_vertices_m[0] += Vector3(0.5, 0.0, 0.0)
	_check(invalid_vertices.validate() != "", "face vertices off their face were accepted")
	var missing_vertices: AmbientFluidProfile3D = profile.duplicate(true)
	missing_vertices.face_vertices_m.resize(3)
	_check(missing_vertices.validate() != "", "a profile without face vertices was accepted")
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
		_check(reloaded.face_vertices_m == profile.face_vertices_m,
			"reloaded face vertices changed")
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
	_check(profile.face_vertices_m.size() == profile.face_centers_m.size() * 3,
		"profile does not carry its face triangles")
	return true


func _positive_diagonal(matrix: PackedFloat64Array) -> bool:
	return matrix[21] > 0.0 and matrix[28] > 0.0 and matrix[35] > 0.0


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
