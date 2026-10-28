extends RiverField

const DOMAIN_M := Vector2(40.0, 48.0)
const GRID_CELL_M := 0.125
const DEPTH_M := 0.5
# Above its reach's level: a free-running river backs up behind a narrow passage in flood, and the banks hold it.
const BANK_HEIGHT_M := 1.6
const BANK_WIDTH_M := 1.4
const VALLEY_GRADE := 0.4
# A pool scoured under each fall, deeper and longer the higher it falls: shares of the drop, then bounds.
const PLUNGE_DEPTH_SHARE := 0.3
const PLUNGE_DEPTH_M := Vector2(0.12, 0.7)
const PLUNGE_LENGTH_SHARE := 1.2
const PLUNGE_LENGTH_M := Vector2(1.2, 3.2)
const SPUR_CORNER_M := 0.12
const ISLAND_HEIGHT_M := 0.85
const ISLAND_SIDE_GRADE := 1.2
const POOL_CENTER_M := Vector2(-1.0, -12.0)
const POOL_RADIUS_M := 7.0
const POOL_DEPTH_M := 1.1
const POOL_FLOW := 0.6
const LIP_FOAM_M := 1.5
const CHANNELS := 5
const LINE_BLEND_M := 2.0
const LIP_EASE := 1.5


# A river descending in terraces: its centre line from upstream, the level of each reach, the lips between them
# (distance along the line), the dry rock spurs splitting each lip (offsets across it) and its islands.
# Every steep face is a sheer step: a slope past the spill slope is a grid staircase whose treads hold water.
class River:
	var line: PackedVector2Array
	var half_width_m: float
	var levels_m: PackedFloat32Array
	var lips_m: PackedFloat32Array
	# Per lip: horseshoe bow upstream at its middle, tilt (along per metre across), setback of each stretch between spurs.
	var lip_shapes: PackedVector3Array
	var spurs_m: Array[PackedFloat32Array] = []
	# Per spur: half length along the river, half width across, height above the lip's level (above any flood on its reach), turn in radians.
	var spur_shapes: Array[PackedVector4Array] = []
	# Along, across, radius.
	var islands: PackedVector3Array
	# Along, half length, narrowest half width: where the banks close in on the river.
	var narrows: PackedVector3Array

	func _init(centre: PackedVector2Array, half_width: float, levels: PackedFloat32Array, lips: PackedFloat32Array,
			shapes: PackedVector3Array, spurs: Array, spur_list: Array, island_list: PackedVector3Array,
			narrow_list: PackedVector3Array) -> void:
		line = centre
		half_width_m = half_width
		levels_m = levels
		lips_m = lips
		lip_shapes = shapes
		spurs_m.assign(spurs)
		spur_shapes.assign(spur_list)
		islands = island_list
		narrows = narrow_list

	# Distance along the centre line, offset to its right facing downstream, and the unit tangent there. Segments
	# hand over across each joint's bisector within LINE_BLEND_M: a plain nearest segment jumps on the inside of a
	# bend and leaves a gap on the outside.
	func locate(point: Vector2) -> Vector4:
		var total := 0.0
		var sums := Vector4.ZERO
		var start := 0.0
		var fade_in := 1.0
		var last := line.size() - 2
		for i in line.size() - 1:
			var segment := line[i + 1] - line[i]
			var length := segment.length()
			var tangent := segment / length
			var fade_out := 0.0
			if i < last:
				var bisector := (tangent + (line[i + 2] - line[i + 1]).normalized()).normalized()
				fade_out = smoothstep(-LINE_BLEND_M, LINE_BLEND_M, (point - line[i + 1]).dot(bisector))
			var weight := fade_in * (1.0 - fade_out)
			if weight > 0.0:
				var along := (point - line[i]).dot(tangent)
				var across := tangent.cross(point - line[i])
				if i == last and along > length:
					across = signf(across) * point.distance_to(line[i + 1])
				sums += Vector4(start + along, across, tangent.x, tangent.y) * weight
				total += weight
			fade_in = fade_out
			start += length
		var tangent := Vector2(sums.z, sums.w).normalized()
		return Vector4(sums.x / total, sums.y / total, tangent.x, tangent.y)

	func width_m(along_m: float) -> float:
		var half := half_width_m
		for narrow in narrows:
			half = minf(half, lerpf(half_width_m, narrow.z, 1.0 - smoothstep(0.0, narrow.y, absf(along_m - narrow.x))))
		return half

	func edge_m(along_m: float, across_m: float) -> float:
		return absf(across_m) - width_m(along_m) - 0.3 * sin(along_m * 0.45 + signf(across_m) * 1.1)

	# The lip's line, smooth across the river: a horseshoe bowing upstream and a tilt.
	func lip_line_m(index: int, across_m: float) -> float:
		var share := clampf(across_m / half_width_m, -1.2, 1.2)
		return lips_m[index] - lip_shapes[index].x * (1.0 - share * share) + lip_shapes[index].y * across_m

	# Each stretch between two spurs is set back on its own; the step between stretches hides inside the spur.
	func lip_m(index: int, across_m: float) -> float:
		var stretch := 0
		for spur_across in spurs_m[index]:
			stretch += int(across_m > spur_across)
		return lip_line_m(index, across_m) + lip_shapes[index].z * sin(2.3 * stretch + 1.7 * index)

	func drop_m(index: int) -> float:
		return levels_m[index] - levels_m[index + 1]

	func reach(along_m: float, across_m: float) -> int:
		var index := 0
		for k in lips_m.size():
			if along_m > lip_m(k, across_m):
				index = k + 1
		return index

	func carve(along_m: float, across_m: float) -> float:
		var reach_index := reach(along_m, across_m)
		var edge := edge_m(along_m, across_m)
		# Past the banks each lip eases into a slope below it, so terraces do not cut walls across the hills and the
		# ground beside a reach stays as high as its bank right up to the lip.
		var ease := maxf(edge - BANK_WIDTH_M, 0.0) * LIP_EASE
		var level := levels_m[0]
		for k in lips_m.size():
			var lip := lip_m(k, across_m)
			level -= (levels_m[k] - levels_m[k + 1]) * (float(along_m > lip) if ease <= 0.0 else smoothstep(lip, lip + 2.0 * ease, along_m))
		var bed := level - DEPTH_M + (DEPTH_M + BANK_HEIGHT_M) * smoothstep(-BANK_WIDTH_M, BANK_WIDTH_M, edge) \
			+ maxf(edge - BANK_WIDTH_M, 0.0) * VALLEY_GRADE \
			+ (0.05 * sin(along_m * 1.7 + across_m * 2.3) + 0.04 * sin(along_m * 3.1 - across_m * 1.1)) * (1.0 - smoothstep(-0.5, 0.5, edge))
		if reach_index > 0:
			var below := along_m - lip_m(reach_index - 1, across_m)
			var drop := drop_m(reach_index - 1)
			var length := clampf(PLUNGE_LENGTH_SHARE * drop + 0.6, PLUNGE_LENGTH_M.x, PLUNGE_LENGTH_M.y)
			if below < length:
				var depth := clampf(PLUNGE_DEPTH_SHARE * drop, PLUNGE_DEPTH_M.x, PLUNGE_DEPTH_M.y)
				# The pool's sides ease off before the bank rises, so the two slopes never add up past the spill slope.
				bed -= depth * sin(PI * below / length) * (1.0 - smoothstep(-2.4, -1.2, edge))
		return bed

	func spur_centre_m(index: int, spur: int) -> Vector2:
		var across := spurs_m[index][spur]
		return Vector2(lip_line_m(index, across) - 0.15, across)

	# Dry rock standing out of the water: spurs across the lips and islands on the reaches.
	func rock(along_m: float, across_m: float) -> float:
		var height := -INF
		for k in lips_m.size():
			for s in spurs_m[k].size():
				var shape := spur_shapes[k][s]
				var local := (Vector2(along_m, across_m) - spur_centre_m(k, s)).rotated(-shape.w)
				var corner := minf(SPUR_CORNER_M, minf(shape.x, shape.y))
				var box := local.abs() - Vector2(shape.x, shape.y) + Vector2.ONE * corner
				if Vector2(maxf(box.x, 0.0), maxf(box.y, 0.0)).length() + minf(maxf(box.x, box.y), 0.0) <= corner:
					height = maxf(height, levels_m[k] + shape.z + 0.08 * sin(across_m * 7.0 + along_m * 3.0))
		for island in islands:
			var distance := Vector2(along_m - island.x, across_m - island.y).length() - island.z
			var level := levels_m[reach(island.x, island.y)]
			height = maxf(height, level + ISLAND_HEIGHT_M - 0.35 * smoothstep(-island.z, 0.0, distance) - maxf(distance, 0.0) * ISLAND_SIDE_GRADE)
		return height

	# Unit flow direction, turned away from the rock it would run into.
	func flow(point: Vector2, located: Vector4) -> Vector2:
		var direction := Vector2(located.z, located.w)
		for k in lips_m.size():
			for s in spurs_m[k].size():
				var centre := spur_centre_m(k, s)
				var shape := spur_shapes[k][s]
				direction = _deflect(direction, point - line_point(centre.x, centre.y), maxf(shape.x, shape.y) + 0.5)
		for island in islands:
			direction = _deflect(direction, point - line_point(island.x, island.y), island.z + 0.8)
		return direction.normalized() if direction.length() > 0.01 else Vector2(located.z, located.w)

	func line_point(along_m: float, across_m: float) -> Vector2:
		var start := 0.0
		for i in line.size() - 1:
			var segment := line[i + 1] - line[i]
			var length := segment.length()
			if along_m <= start + length or i == line.size() - 2:
				var tangent := segment / length
				return line[i] + tangent * (along_m - start) + Vector2(-tangent.y, tangent.x) * across_m
			start += length
		return line[0]

	static func _deflect(direction: Vector2, offset: Vector2, reach_m: float) -> Vector2:
		var distance := offset.length()
		if distance >= reach_m or distance < 0.001:
			return direction
		var normal := offset / distance
		return direction - normal * minf(direction.dot(normal), 0.0) * (1.0 - smoothstep(reach_m * 0.5, reach_m, distance))


var rivers: Array[River] = []
var _grid := PackedFloat32Array()
var _grid_size := Vector2i.ZERO


func _init() -> void:
	domain_m = DOMAIN_M
	spills = true
	rivers = [
		# A horseshoe, an oblique step round a boulder, a gorge slot over the tallest fall, a lip split by spurs into the pool.
		River.new(PackedVector2Array([Vector2(-4.5, 25.0), Vector2(-4.5, 11.5), Vector2(-3.0, 7.5), Vector2(-3.0, -9.0), Vector2(-1.0, -25.0)]),
			3.3, PackedFloat32Array([6.0, 4.8, 4.3, 1.5, 0.0]), PackedFloat32Array([9.0, 11.3, 21.0, 27.7]),
			PackedVector3Array([Vector3(0.7, 0.0, 0.0), Vector3(0.0, 0.2, 0.0), Vector3.ZERO, Vector3(0.0, 0.0, 0.25)]),
			[PackedFloat32Array(), PackedFloat32Array([1.4]), PackedFloat32Array([-3.2, 3.0]), PackedFloat32Array([-2.4, -0.8, 1.0, 2.5])],
			[PackedVector4Array(), PackedVector4Array([Vector4(0.45, 0.45, 1.2, 0.4)]),
				PackedVector4Array([Vector4(1.6, 1.8, 2.2, 0.0), Vector4(1.6, 1.6, 2.4, 0.0)]),
				PackedVector4Array([Vector4(0.75, 0.32, 1.5, 0.0), Vector4(0.6, 0.45, 1.4, 0.3), Vector4(0.9, 0.28, 1.8, -0.2),
					Vector4(0.7, 0.4, 1.6, 0.12)])],
			PackedVector3Array([Vector3(4.0, 1.2, 1.3), Vector3(14.0, -1.5, 1.0)]), PackedVector3Array()),
		# Two small steps, a narrow chute, then an oblique fall split by two spurs.
		River.new(PackedVector2Array([Vector2(21.0, 7.5), Vector2(11.0, 7.5), Vector2(5.2, 0.0), Vector2(5.2, -6.5), Vector2(-1.0, -12.0)]),
			2.0, PackedFloat32Array([3.5, 3.0, 2.5, 0.0]), PackedFloat32Array([6.0, 7.9, 23.5]),
			PackedVector3Array([Vector3(-0.35, 0.0, 0.0), Vector3(0.0, -0.15, 0.0), Vector3(0.0, 0.1, 0.2)]),
			[PackedFloat32Array(), PackedFloat32Array([-0.5]), PackedFloat32Array([-0.9, 0.7])],
			[PackedVector4Array(), PackedVector4Array([Vector4(0.4, 0.3, 1.4, 0.5)]),
				PackedVector4Array([Vector4(0.8, 0.4, 1.8, 0.2), Vector4(0.6, 0.3, 1.6, -0.3)])],
			PackedVector3Array(), PackedVector3Array([Vector3(15.0, 2.5, 1.4)])),
	]
	_grid_size = Vector2i(DOMAIN_M / GRID_CELL_M)
	var rows := []
	rows.resize(_grid_size.y)
	var task := WorkerThreadPool.add_group_task(func(y: int) -> void:
		var row := PackedFloat32Array()
		row.resize(_grid_size.x * CHANNELS)
		for x in _grid_size.x:
			var values := _evaluate(domain_rect().position + (Vector2(x, y) + Vector2.ONE * 0.5) * GRID_CELL_M)
			for c in CHANNELS:
				row[x * CHANNELS + c] = values[c]
		rows[y] = row, _grid_size.y)
	LoadingPump.wait_for_group(task)
	for row: PackedFloat32Array in rows:
		_grid.append_array(row)


# Bed, water level, flow x and z, foam source. A point inside a channel, banks included, belongs to it, so a lower
# reach never cuts the bank of a higher one; where two rivers' banks meet, the nearer channel owns the point, so the
# ridge between them holds each one's water; elsewhere the lowest carved ground wins. The pool counts as a channel.
func _evaluate(point: Vector2) -> PackedFloat32Array:
	var pool_edge := point.distance_to(POOL_CENTER_M) - POOL_RADIUS_M
	var bed := -DEPTH_M - POOL_DEPTH_M * (1.0 - smoothstep(-POOL_RADIUS_M * 0.7, 0.0, pool_edge)) \
		+ (DEPTH_M + BANK_HEIGHT_M) * smoothstep(-BANK_WIDTH_M, BANK_WIDTH_M, pool_edge) + maxf(pool_edge - BANK_WIDTH_M, 0.0) * VALLEY_GRADE
	var inside := pool_edge < BANK_WIDTH_M
	var owner: River = null
	var owner_edge := INF
	var located := Vector4.ZERO
	for river in rivers:
		var at := river.locate(point)
		var carved := river.carve(at.x, at.y)
		var edge := river.edge_m(at.x, at.y)
		var member := edge < BANK_WIDTH_M
		var nearer := member and inside and is_instance_valid(owner) and edge < owner_edge
		if (member and not inside) or nearer or (member == inside and carved < bed and not (member and is_instance_valid(owner))):
			bed = carved
			owner = river
			owner_edge = edge
			located = at
			inside = member
	# Runs on worker threads: an operator on a non-builtin operand (owner == null) inits a shared bytecode cache racily.
	if not is_instance_valid(owner):
		var outflow := rivers[0].locate(point)
		return PackedFloat32Array([bed, 0.0, outflow.z * POOL_FLOW, outflow.w * POOL_FLOW, 0.0])
	bed = maxf(bed, owner.rock(located.x, located.y))
	var reach := owner.reach(located.x, located.y)
	var foam := 0.0
	if reach > 0:
		foam = 0.6 * (1.0 - smoothstep(LIP_FOAM_M * 0.3, LIP_FOAM_M, located.x - owner.lip_m(reach - 1, located.y)))
	var direction := owner.flow(point, located)
	return PackedFloat32Array([bed, owner.levels_m[reach], direction.x, direction.y, foam])


func _lookup(point: Vector2, channel: int) -> float:
	var cell := (point - domain_rect().position) / GRID_CELL_M - Vector2.ONE * 0.5
	var low := Vector2i(cell.floor())
	var fraction := cell - Vector2(low)
	var last := _grid_size - Vector2i.ONE
	var a := low.clamp(Vector2i.ZERO, last)
	var b := (low + Vector2i(1, 1)).clamp(Vector2i.ZERO, last)
	var row_a := a.y * _grid_size.x
	var row_b := b.y * _grid_size.x
	return lerpf(lerpf(_grid[(row_a + a.x) * CHANNELS + channel], _grid[(row_a + b.x) * CHANNELS + channel], fraction.x),
		lerpf(_grid[(row_b + a.x) * CHANNELS + channel], _grid[(row_b + b.x) * CHANNELS + channel], fraction.x), fraction.y)


func sample_bed(point: Vector2) -> float:
	return _lookup(point, 0)


func sample_height(point: Vector2, level_m: float) -> float:
	return _lookup(point, 1) + level_m


func sample(point: Vector2, level_m: float) -> Color:
	var wet := smoothstep(0.0, 0.12, sample_height(point, level_m) - sample_bed(point))
	if wet <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	return Color(_lookup(point, 2) * wet, _lookup(point, 3) * wet, _lookup(point, 4) * wet, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	return Color(_lookup(point, 2), _lookup(point, 3), 0.0, 1.0)


# Distance outside the nearest wet channel; island tops count as banks.
func channel_edge_m(point: Vector2) -> float:
	var edge := point.distance_to(POOL_CENTER_M) - POOL_RADIUS_M
	for river in rivers:
		var at := river.locate(point)
		edge = minf(edge, absf(at.y) - river.width_m(at.x))
		for island in river.islands:
			if Vector2(at.x - island.x, at.y - island.y).length() < island.z * 0.8:
				return 1.0
	return edge
