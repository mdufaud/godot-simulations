extends SceneTree

const WATER_DENSITY_KG_M3 := 998.0


func _initialize() -> void:
	var profiles := [
		{
			"path": "res://resources/ambient_fluid/sphere_bem.tres",
			"mesh": _icosahedron_mesh(),
		},
		{
			"path": "res://resources/ambient_fluid/body_bem.tres",
			"mesh": _box_mesh(Vector3(1.8, 1.4, 1.0)),
		},
		{
			"path": "res://resources/ambient_fluid/plate_bem.tres",
			"mesh": _box_mesh(Vector3(2.4, 0.18, 1.2)),
		},
	]
	for item in profiles:
		var profile: AmbientFluidProfile3D = AmbientFluidPreprocessor.build_profile(
			item.mesh, WATER_DENSITY_KG_M3)
		if profile == null:
			push_error("BEM build failed for %s: %s" % [
				item.path, AmbientFluidPreprocessor.get_last_error()])
			quit(1)
			return
		var tensor := profile.added_mass_tensor
		print("%s: translation diagonals x=%.3f y=%.3f z=%.3f; source offset %.4f m" % [
			item.path, tensor[21], tensor[28], tensor[35], profile.source_offset_m])
		if item.path.ends_with("plate_bem.tres") \
				and (tensor[28] <= tensor[21] or tensor[28] <= tensor[35]):
			push_error("plate broadside (y) added mass is not dominant")
			quit(1)
			return
		var save_error := AmbientFluidPreprocessor.save_profile(profile, item.path)
		if save_error != "":
			push_error("save failed for %s: %s" % [item.path, save_error])
			quit(1)
			return
	print("TEST PASS regenerate_ambient_profile")
	quit(0)


func _box_mesh(size: Vector3) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box.get_mesh_arrays())
	return mesh


func _icosahedron_mesh() -> ArrayMesh:
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
	var indices := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
