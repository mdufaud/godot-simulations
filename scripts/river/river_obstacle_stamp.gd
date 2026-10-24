class_name RiverObstacleStamp
extends RefCounted
## Rasterises the upper surface of rock meshes into a cell-centred height grid, keeping
## the highest value per cell. Upright meshes go through a cached top map per mesh;
## tilted ones are rasterised triangle by triangle.

const MAP_SIZE := 96

var _maps: Dictionary = {}


# Returns the touched cell rectangle, empty when the mesh lies outside the grid.
func stamp(values: PackedFloat32Array, stride: int, size: Vector2i, origin: Vector2, cell_m: float,
		instance: MeshInstance3D) -> Rect2i:
	var transform := instance.global_transform
	var bounds := transform * instance.get_aabb()
	if not Rect2(origin, Vector2(size) * cell_m).intersects(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))):
		return Rect2i()
	var low := ((Vector2(bounds.position.x, bounds.position.z) - origin) / cell_m - Vector2.ONE * 0.5).ceil()
	var high := ((Vector2(bounds.end.x, bounds.end.z) - origin) / cell_m - Vector2.ONE * 0.5).floor()
	var first := Vector2i(maxi(int(low.x), 0), maxi(int(low.y), 0))
	var last := Vector2i(mini(int(high.x) + 1, size.x), mini(int(high.y) + 1, size.y))
	var basis := transform.basis
	var tolerance := 0.001 * basis.get_scale().length()
	if absf(basis.x.y) > tolerance or absf(basis.z.y) > tolerance or absf(basis.y.x) > tolerance or absf(basis.y.z) > tolerance:
		_stamp_faces(values, stride, size, origin, cell_m, instance)
		return Rect2i(first, (last - first).max(Vector2i.ZERO))
	var map := _top_map(instance.mesh)
	var local := instance.mesh.get_aabb()
	var texel := Vector2(local.size.x, local.size.z) / float(MAP_SIZE - 1)
	var inverse := transform.affine_inverse()
	for y in range(first.y, last.y):
		for x in range(first.x, last.x):
			var world := origin + Vector2(x + 0.5, y + 0.5) * cell_m
			var point := inverse * Vector3(world.x, 0.0, world.y)
			var cell := ((Vector2(point.x, point.z) - Vector2(local.position.x, local.position.z)) / texel).round()
			if cell.x < 0.0 or cell.y < 0.0 or cell.x >= MAP_SIZE or cell.y >= MAP_SIZE:
				continue
			var top := map[int(cell.y) * MAP_SIZE + int(cell.x)]
			if top == -INF:
				continue
			var offset := (y * size.x + x) * stride
			values[offset] = maxf(values[offset], (transform * Vector3(point.x, top, point.z)).y)
	return Rect2i(first, (last - first).max(Vector2i.ZERO))


func _top_map(mesh: Mesh) -> PackedFloat32Array:
	if _maps.has(mesh):
		return _maps[mesh]
	var bounds := mesh.get_aabb()
	var texel := Vector2(bounds.size.x, bounds.size.z) / float(MAP_SIZE - 1)
	var origin := Vector2(bounds.position.x, bounds.position.z)
	var map := PackedFloat32Array()
	map.resize(MAP_SIZE * MAP_SIZE)
	map.fill(-INF)
	var faces := mesh.get_faces()
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var area := ab.cross(ac)
		if absf(area) < 0.0000001:
			continue
		var low := ((Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))) - origin) / texel).ceil()
		var high := ((Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))) - origin) / texel).floor()
		for y in range(maxi(int(low.y), 0), mini(int(high.y) + 1, MAP_SIZE)):
			for x in range(maxi(int(low.x), 0), mini(int(high.x) + 1, MAP_SIZE)):
				var point := origin + Vector2(x, y) * texel - Vector2(a.x, a.z)
				var wb := point.cross(ac) / area
				var wc := ab.cross(point) / area
				if minf(1.0 - wb - wc, minf(wb, wc)) >= -0.0001:
					var cell := y * MAP_SIZE + x
					map[cell] = maxf(map[cell], a.y + wb * (b.y - a.y) + wc * (c.y - a.y))
	_maps[mesh] = map
	return map


func _stamp_faces(values: PackedFloat32Array, stride: int, size: Vector2i, origin: Vector2, cell_m: float,
		instance: MeshInstance3D) -> void:
	var faces := instance.mesh.get_faces()
	for index in range(0, faces.size(), 3):
		var a := instance.global_transform * faces[index]
		var b := instance.global_transform * faces[index + 1]
		var c := instance.global_transform * faces[index + 2]
		var corner := Vector2(a.x, a.z)
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var area := ab.cross(ac)
		if absf(area) < 0.000001:
			continue
		var low := (Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))) - origin) / cell_m - Vector2.ONE * 0.5
		var high := (Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))) - origin) / cell_m - Vector2.ONE * 0.5
		for y in range(maxi(ceili(low.y), 0), mini(floori(high.y) + 1, size.y)):
			for x in range(maxi(ceili(low.x), 0), mini(floori(high.x) + 1, size.x)):
				var point := origin + Vector2(x + 0.5, y + 0.5) * cell_m - corner
				var wb := point.cross(ac) / area
				var wc := ab.cross(point) / area
				if minf(1.0 - wb - wc, minf(wb, wc)) >= -0.0001:
					var offset := (y * size.x + x) * stride
					values[offset] = maxf(values[offset], a.y + wb * (b.y - a.y) + wc * (c.y - a.y))
