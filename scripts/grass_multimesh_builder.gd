extends RefCounted


static func build(density: float, tile_size: float, mesh: Mesh) -> MultiMesh:
	var row_size := int(ceil(tile_size * lerpf(0.0, 10.0, density)))
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = row_size * row_size

	var jitter := tile_size / float(row_size) * 0.5 * 0.9 if row_size > 0 else 0.0
	for i in row_size:
		for j in row_size:
			var position := Vector3(i / float(row_size) - 0.5, 0, j / float(row_size) - 0.5) * tile_size
			var offset := Vector3(randf_range(-jitter, jitter), 0, randf_range(-jitter, jitter))
			multimesh.set_instance_transform(i + j * row_size, Transform3D(Basis(), position + offset))
	return multimesh
