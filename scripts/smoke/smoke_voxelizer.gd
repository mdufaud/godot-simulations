class_name SmokeVoxelizer
extends RefCounted
## Solid fraction of closed triangle meshes on the smoke grid, by parity: rays
## along +x through each (y, z) column, sorted hits paired inside/outside, covered
## length accumulated per cell. Odd hit counts drop their last hit, so an open mesh
## never floods the rest of its row. The C++ SmokeKernels.voxelize is a
## bit-identical port; this body is the reference.

static var _native := Native.kernel(&"SmokeKernels")


## [param faces]: world-space triangle soup (Mesh.get_faces() transformed).
## Returns one value per cell, x fastest, in [0, 1].
static func voxelize(faces: PackedVector3Array, origin_m: Vector3, cell_m: float,
		dims: Vector3i, rays_per_axis: int) -> PackedFloat32Array:
	if Native.enabled and _native != null:
		return _native.voxelize(faces, origin_m, cell_m, dims, rays_per_axis)
	var nx := dims.x
	var ny := dims.y
	var nz := dims.z
	var out := PackedFloat32Array()
	out.resize(nx * ny * nz)
	var triangle_count := faces.size() / 3
	if triangle_count == 0 or rays_per_axis < 1 or cell_m <= 0.0 or nx < 1 or ny < 1 or nz < 1:
		return out
	var ox := float(origin_m.x)
	var oy := float(origin_m.y)
	var oz := float(origin_m.z)

	# Triangles binned per (y, z) column, compressed rows: column k * ny + j.
	var spans := PackedInt32Array()
	spans.resize(triangle_count * 4)
	var starts := PackedInt32Array()
	starts.resize(ny * nz + 1)
	for t in triangle_count:
		var a := faces[t * 3]
		var b := faces[t * 3 + 1]
		var c := faces[t * 3 + 2]
		var j0 := clampi(floori((minf(minf(a.y, b.y), c.y) - oy) / cell_m), 0, ny - 1)
		var j1 := clampi(floori((maxf(maxf(a.y, b.y), c.y) - oy) / cell_m), 0, ny - 1)
		var k0 := clampi(floori((minf(minf(a.z, b.z), c.z) - oz) / cell_m), 0, nz - 1)
		var k1 := clampi(floori((maxf(maxf(a.z, b.z), c.z) - oz) / cell_m), 0, nz - 1)
		spans[t * 4] = j0
		spans[t * 4 + 1] = j1
		spans[t * 4 + 2] = k0
		spans[t * 4 + 3] = k1
		for k in range(k0, k1 + 1):
			for j in range(j0, j1 + 1):
				starts[k * ny + j + 1] += 1
	for column in ny * nz:
		starts[column + 1] += starts[column]
	var cursor := starts.duplicate()
	var items := PackedInt32Array()
	items.resize(starts[ny * nz])
	for t in triangle_count:
		for k in range(spans[t * 4 + 2], spans[t * 4 + 3] + 1):
			for j in range(spans[t * 4], spans[t * 4 + 1] + 1):
				items[cursor[k * ny + j]] = t
				cursor[k * ny + j] += 1

	var rays := float(rays_per_axis)
	var weight := 1.0 / (rays * rays)
	var hits := PackedFloat64Array()
	for k in nz:
		for j in ny:
			var column := k * ny + j
			if starts[column] == starts[column + 1]:
				continue
			for sk in rays_per_axis:
				for sj in rays_per_axis:
					# Off-centre by an irrational fraction so rays miss shared edges.
					var ry := oy + (float(j) + (float(sj) + 0.5123) / rays) * cell_m
					var rz := oz + (float(k) + (float(sk) + 0.5071) / rays) * cell_m
					hits.clear()
					for item in range(starts[column], starts[column + 1]):
						var t := items[item]
						var x := _ray_x_hit(faces[t * 3], faces[t * 3 + 1], faces[t * 3 + 2], ry, rz)
						if x < INF:
							hits.append(x)
					hits.sort()
					var base := column * nx
					for h in range(0, hits.size() - 1, 2):
						var lo := clampf((hits[h] - ox) / cell_m, 0.0, float(nx))
						var hi := clampf((hits[h + 1] - ox) / cell_m, 0.0, float(nx))
						var i := floori(lo)
						while i < nx and float(i) < hi:
							out[base + i] += (minf(hi, float(i) + 1.0) - maxf(lo, float(i))) * weight
							i += 1
	return out


## x where the ray (y = ry, z = rz) along +x crosses triangle abc, or INF.
static func _ray_x_hit(a: Vector3, b: Vector3, c: Vector3, ry: float, rz: float) -> float:
	var ay := float(a.y)
	var az := float(a.z)
	var by := float(b.y) - ay
	var bz := float(b.z) - az
	var cy := float(c.y) - ay
	var cz := float(c.z) - az
	var det := by * cz - bz * cy
	if absf(det) < 1e-18:
		return INF
	var py := ry - ay
	var pz := rz - az
	var wb := (py * cz - pz * cy) / det
	var wc := (by * pz - bz * py) / det
	if wb < 0.0 or wc < 0.0 or wb + wc > 1.0:
		return INF
	return float(a.x) + wb * (float(b.x) - float(a.x)) + wc * (float(c.x) - float(a.x))
