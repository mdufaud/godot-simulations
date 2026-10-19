class_name HolonomyState extends RefCounted
## Pure math of the holonomy loop: box rooms chained in a cycle by portal pairs,
## and the turn their composition leaves behind.
##
## Every pair mapping is rigid ([code]PortalMath.mapping[/code]), so the loop is
## rigid too — the curvature lives in the connectivity, never in a transform.
## Which walls carry each room's entrance and exit decides it all: the room
## yaws telescope away and the loop turns by minus the sum of the heading
## changes the walk makes inside the rooms ([method layout_turn]). Walk the
## loop, come back turned.
##
##     var loop := HolonomyState.loop_mapping(walk_mappings)
##     var predicted := HolonomyState.layout_turn(entrance_walls, exit_walls)

## The four walls of a box room; north is local -Z.
const WALLS := ["north", "east", "south", "west"]
## Steepest sight line [method sight_line] follows against the first door's
## way through, about 87°: past that a line only grazes the aperture.
const GRAZING_SLOPE := 20.0


## Composition of the walk mappings in walk order: crossing the first door,
## then the second… applies [code]m_n·…·m_2·m_1[/code] to the traveller — the
## last crossing maps first.
static func loop_mapping(mappings: Array[Transform3D]) -> Transform3D:
	var loop := Transform3D.IDENTITY
	for mapping in mappings:
		loop = mapping * loop
	return loop


## Angle in radians of a loop mapping that is a pure turn about Y — the
## holonomy readout. Positive follows [code]Basis(Vector3.UP, angle)[/code].
static func turn_angle(loop: Transform3D) -> float:
	return atan2(loop.basis.z.x, loop.basis.z.z)


## Yaw whose local +Z points into the room through [param wall]: the
## convention of portal fronts.
static func inward_yaw(wall: String) -> float:
	match wall:
		"south":
			return PI
		"west":
			return PI * 0.5
		"east":
			return -PI * 0.5
	return 0.0


## Heading change of a walk that enters through [param entrance] and leaves
## through [param exit], two different walls: +90° turns left, −90° right,
## 0 goes straight on.
static func room_turn(entrance: String, exit: String) -> float:
	return wrapf(inward_yaw(exit) + PI - inward_yaw(entrance), -PI, PI)


## Whether one straight line on the floor plane crosses every door in order:
## each pose's +Z is the way through, its local X spans the aperture. The rooms
## between doors are convex, so crossing each door the right way round keeps
## the crossings in order by itself. [param max_slope] bounds the line against
## the first door's way through: an eye's field of view.
static func sight_line(doors: Array[Transform3D], half_width: float,
		max_slope := GRAZING_SLOPE) -> bool:
	# Lines x = m·z + b in the first door's frame, z along its way through. Each
	# aperture end and each crossing direction is a half-plane of (m, b); the
	# line exists while their intersection keeps an area.
	var frame := doors[0].affine_inverse()
	var lines := PackedVector2Array([Vector2(-max_slope, -1000.0),
		Vector2(max_slope, -1000.0), Vector2(max_slope, 1000.0),
		Vector2(-max_slope, 1000.0)])
	for door in doors:
		var pose := frame * door
		var way := pose.basis.z
		var span := pose.basis.x * half_width
		var side := signf(way.z * span.x - way.x * span.z)
		var plus := pose.origin + span
		var minus := pose.origin - span
		lines = _clip(lines, Vector3(-side * plus.z, -side, side * plus.x))
		lines = _clip(lines, Vector3(side * minus.z, side, -side * minus.x))
		lines = _clip(lines, Vector3(way.x, 0.0, way.z))
	var area := 0.0
	for index in lines.size():
		area += lines[index].cross(lines[(index + 1) % lines.size()])
	return absf(area) > 1e-9


## Convex polygon of (m, b) kept on the side where
## [code]plane.x·m + plane.y·b + plane.z ≥ 0[/code].
static func _clip(polygon: PackedVector2Array, plane: Vector3) -> PackedVector2Array:
	var kept := PackedVector2Array()
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		var distance_a := plane.x * a.x + plane.y * a.y + plane.z
		var distance_b := plane.x * b.x + plane.y * b.y + plane.z
		if distance_a >= 0.0:
			kept.append(a)
		if (distance_a >= 0.0) != (distance_b >= 0.0):
			kept.append(a.lerp(b, distance_a / (distance_a - distance_b)))
	return kept


## Turn left behind by a loop of rooms whose doors sit on these walls, room by
## room in walk order — what [method turn_angle] reads off the built loop.
static func layout_turn(entrances: Array, exits: Array) -> float:
	var total := 0.0
	for index in entrances.size():
		total -= room_turn(entrances[index], exits[index])
	return wrapf(total, -PI, PI)
