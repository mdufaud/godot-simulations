extends RefCounted

const LOD_DENSITY := [0.9, 0.9, 0.9, 0.8, 0.8]


static func make_tuft_mesh(high_detail: bool) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	surface.set_custom_format(1, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var blade_count := 6
	var blade_segments := 4 if high_detail else 2
	for blade in blade_count:
		var angle := TAU * float(blade) / float(blade_count) + 0.18 * float(blade % 2)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var height := 0.76 + 0.24 * float((blade * 3 + 1) % 7) / 6.0
		var lean := 0.35 + 0.3 * float((blade * 5 + 2) % 7) / 6.0
		var root := direction * (0.045 + 0.025 * float(blade % 3))
		_append_ribbon(surface, root, direction, height, lean,
			0.043 if high_detail else 0.052,
			blade_segments, 0)
	var stalk_direction := Vector3(0.71, 0.0, 0.71)
	_append_ribbon(surface, Vector3.ZERO, stalk_direction, 1.1, 0.38, 0.008,
			2, 2)
	var head_root := stalk_direction * 0.38 + Vector3.UP * 1.1
	var head_cards := 3
	for card in head_cards:
		var angle := TAU * float(card) / float(head_cards) + 0.16 * float(card - 1)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		_append_ribbon(surface, head_root, direction, 0.36 + 0.1 * float((card * 5 + 1) % 4) / 3.0,
			0.14 + 0.08 * float((card * 3 + 2) % 4) / 3.0,
			0.16 if high_detail else 0.2,
			4 if high_detail else 2, 1)
	# De-duplicates the shared quad edges of the ribbons (~33% fewer vertices)
	# without changing any triangle; the mesh stays visually identical.
	surface.index()
	return surface.commit()


static func _append_ribbon(surface: SurfaceTool, root: Vector3,
		direction: Vector3, height: float, lean: float, width: float,
		segments: int, kind: int) -> void:
	var sideways := Vector3(-direction.z, 0.0, direction.x)
	var curve_direction := Vector3(0.71, 0.0, 0.71) if kind == 1 else direction
	surface.set_custom(0, Color(root.x, root.y, root.z, height))
	surface.set_custom(1, Color(lean, float(segments), curve_direction.x, curve_direction.z))
	for segment in segments:
		var t0 := float(segment) / float(segments)
		var t1 := float(segment + 1) / float(segments)
		var center0 := root + curve_direction * lean * t0 * t0 + Vector3.UP * height * t0
		var center1 := root + curve_direction * lean * t1 * t1 + Vector3.UP * height * t1
		var width0 := width if kind == 1 else width * (1.0 - t0)
		var width1 := width if kind == 1 else width * (1.0 - t1)
		if kind == 0:
			center0.y -= height * 0.25 * t0 * t0 * t0
			center1.y -= height * 0.25 * t1 * t1 * t1
			width0 *= 0.6 + 0.4 * sin(PI * t0)
			width1 *= 0.6 + 0.4 * sin(PI * t1)
		elif kind == 2:
			width0 = width * (1.0 - 0.5 * t0)
			width1 = width * (1.0 - 0.5 * t1)
		var left0 := center0 - sideways * width0
		var right0 := center0 + sideways * width0
		var left1 := center1 - sideways * width1
		var right1 := center1 + sideways * width1
		var uv0 := t0 if kind == 0 else (0.75 + 0.25 * t0 if kind == 1 else 0.75 * t0)
		var uv1 := t1 if kind == 0 else (0.75 + 0.25 * t1 if kind == 1 else 0.75 * t1)
		var tangent0 := curve_direction * (2.0 * lean * t0) + Vector3.UP * height
		var tangent1 := curve_direction * (2.0 * lean * t1) + Vector3.UP * height
		if kind == 0:
			tangent0.y -= height * 0.75 * t0 * t0
			tangent1.y -= height * 0.75 * t1 * t1
		var normal0 := tangent0.cross(sideways).normalized()
		var normal1 := tangent1.cross(sideways).normalized()
		_append_vertex(surface, left0, normal0, Vector2(float(kind * 2), uv0))
		_append_vertex(surface, right0, normal0, Vector2(float(kind * 2 + 1), uv0))
		_append_vertex(surface, left1, normal1, Vector2(float(kind * 2), uv1))
		_append_vertex(surface, left1, normal1, Vector2(float(kind * 2), uv1))
		_append_vertex(surface, right0, normal0, Vector2(float(kind * 2 + 1), uv0))
		_append_vertex(surface, right1, normal1, Vector2(float(kind * 2 + 1), uv1))


static func _append_vertex(surface: SurfaceTool, position: Vector3,
		normal: Vector3, uv: Vector2) -> void:
	surface.set_normal(normal)
	surface.set_uv(uv)
	surface.add_vertex(position)


static func build_lods(density: float, tile_size: float, high_mesh: Mesh,
		low_mesh: Mesh, seed: int) -> Array[MultiMesh]:
	var lods: Array[MultiMesh] = []
	var max_row_size := int(ceil(tile_size * 3.6 * density * LOD_DENSITY[0]))
	var candidate_count := max_row_size * max_row_size
	var positions := PackedVector3Array()
	var variation := PackedColorArray()
	var order := PackedInt32Array()
	positions.resize(candidate_count)
	variation.resize(candidate_count)
	order.resize(candidate_count)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	if max_row_size > 0:
		var cell_size := tile_size / float(max_row_size)
		var jitter := cell_size * 0.45
		for z in max_row_size:
			for x in max_row_size:
				var index := x + z * max_row_size
				positions[index] = Vector3(
					(x + 0.5) / float(max_row_size) - 0.5,
					0.0,
					(z + 0.5) / float(max_row_size) - 0.5
				) * tile_size + Vector3(rng.randf_range(-jitter, jitter), 0.0,
					rng.randf_range(-jitter, jitter))
				variation[index] = Color(rng.randf(), rng.randf(), rng.randf(), rng.randf())
				order[index] = index

	for i in range(candidate_count - 1, 0, -1):
		var swap_index := rng.randi_range(0, i)
		var previous := order[i]
		order[i] = order[swap_index]
		order[swap_index] = previous

	var previous_multimesh: MultiMesh
	var previous_row_size := -1
	var previous_mesh: Mesh
	for lod_index in LOD_DENSITY.size():
		var row_size := int(ceil(tile_size * 3.6 * density * LOD_DENSITY[lod_index]))
		var instance_count := mini(row_size * row_size, candidate_count)
		var lod_mesh := high_mesh if lod_index == 0 else low_mesh
		if row_size == previous_row_size and lod_mesh == previous_mesh:
			lods.append(previous_multimesh)
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.mesh = lod_mesh
		multimesh.instance_count = instance_count
		for instance_id in instance_count:
			var candidate_id := order[instance_id]
			multimesh.set_instance_transform(instance_id,
				Transform3D(Basis(), positions[candidate_id]))
			multimesh.set_instance_custom_data(instance_id, variation[candidate_id])
		lods.append(multimesh)
		previous_multimesh = multimesh
		previous_row_size = row_size
		previous_mesh = lod_mesh
	return lods
