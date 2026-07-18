class_name OceanClipmap
## Procedural concentric clipmap for the FFT ocean surface. Every level is a
## 64x64-cell grid whose cell doubles per level; ring levels carve out the
## 32x32-cell hole the previous level fills. 2:1 boundaries are closed by the
## surface shader's geomorph: each level's outer band morphs onto the coarser
## lattice, so both sides sample identical displacement and no crack opens. A
## flat skirt (on the last level's lattice, which therefore never morphs)
## extends to the horizon. Positions only — UVs come from world XZ in-shader.

const GRID := 64
const HOLE := 32


static func build(cell0: float, ring_levels: int, skirt_radius: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()

	for l in ring_levels + 1:
		var cell := cell0 * pow(2.0, l)
		var base := verts.size()
		var side := GRID + 1
		for gz in side:
			for gx in side:
				verts.append(Vector3((gx - GRID / 2.0) * cell, 0.0, (gz - GRID / 2.0) * cell))
		var hole_lo := (GRID - HOLE) / 2
		var hole_hi := hole_lo + HOLE
		for cz in GRID:
			for cx in GRID:
				if l > 0 and cx >= hole_lo and cx < hole_hi and cz >= hole_lo and cz < hole_hi:
					continue
				var v00 := base + cz * side + cx
				var v10 := v00 + 1
				var v01 := v00 + side
				var v11 := v01 + 1
				indices.append_array(PackedInt32Array([v00, v10, v11, v00, v11, v01]))

	_add_skirt(verts, indices, cell0 * pow(2.0, ring_levels) * (GRID / 2.0), skirt_radius)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _add_skirt(
	verts: PackedVector3Array, indices: PackedInt32Array, h: float, radius: float
) -> void:
	var s := radius / h
	var step := h * 2.0 / GRID
	var loop_pts := PackedVector3Array()
	for i in GRID:
		loop_pts.append(Vector3(-h + i * step, 0, -h))
	for i in GRID:
		loop_pts.append(Vector3(h, 0, -h + i * step))
	for i in GRID:
		loop_pts.append(Vector3(h - i * step, 0, h))
	for i in GRID:
		loop_pts.append(Vector3(-h, 0, h - i * step))
	for i in loop_pts.size():
		var a := loop_pts[i]
		var b := loop_pts[(i + 1) % loop_pts.size()]
		var base := verts.size()
		verts.append(a)
		verts.append(b)
		verts.append(b * s)
		verts.append(a * s)
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
