extends "res://tests/test_case.gd"
## Unit tests for holonomy_state.gd — the loop mapping of the four-vault square.
## Pure transforms only: no scene, no GPU, no player. Runs under --headless.

const PortalMathScript := preload("res://scripts/non_euclidean/portal_math.gd")
const State := preload("res://scripts/non_euclidean/holonomy_state.gd")

## Mirrors ExhibitHolonomyLoop's placement: vaults on a ring, entrances on the
## south wall of vaults I–III and the east wall of vault IV, every exit on a
## west wall — the wall choices whose composition turns a quarter.
const VAULT_ANGLES := [0.0, PI * 0.5, PI, -PI * 0.5]
const RING := 24.0
const OPENING_HALF_HEIGHT := 1.7
const DOOR_DEPTH := 4.25
## Door centres of one exhibit vault (6 × 8 m) in its own frame, and the half
## width of its apertures.
const ROOM_DOORS := {"south": Vector3(0.0, 0.0, 4.25), "north": Vector3(0.0, 0.0, -4.25),
	"west": Vector3(-3.25, 0.0, 0.0), "east": Vector3(3.25, 0.0, 0.0)}
const APERTURE_HALF_WIDTH := 1.3


func _initialize() -> void:
	_test_pair_mappings_are_rigid()
	_test_loop_is_quarter_turn()
	_test_walk_arrivals()
	_test_reverse_door()
	_test_room_turns()
	_test_layout_turn_matches_mappings()
	_test_sight_line_cases()
	_test_sight_line_misses_no_sampled_line()
	_finish("holonomy_state")


func _vault_pose(index: int) -> Transform3D:
	var angle: float = VAULT_ANGLES[index]
	var outward := Vector3(sin(angle), 0.0, cos(angle))
	return Transform3D(Basis(Vector3.UP, angle), outward * RING)


## Portal pose for a door: flush at the wall's mid-thickness, front facing
## into the vault. Walls: "south", "north", "west", "east".
func _door_pose(index: int, wall: String) -> Transform3D:
	var origin := Vector3.ZERO
	var yaw := 0.0
	match wall:
		"south":
			origin = Vector3(0.0, OPENING_HALF_HEIGHT, DOOR_DEPTH)
			yaw = PI
		"north":
			origin = Vector3(0.0, OPENING_HALF_HEIGHT, -DOOR_DEPTH)
			yaw = 0.0
		"west":
			origin = Vector3(-DOOR_DEPTH, OPENING_HALF_HEIGHT, 0.0)
			yaw = PI * 0.5
		"east":
			origin = Vector3(DOOR_DEPTH, OPENING_HALF_HEIGHT, 0.0)
			yaw = -PI * 0.5
	return _vault_pose(index) * Transform3D(Basis(Vector3.UP, yaw), origin)


func _entrance_poses() -> Array[Transform3D]:
	return [_door_pose(0, "south"), _door_pose(1, "south"), _door_pose(2, "south"),
		_door_pose(3, "east")]


func _exit_poses() -> Array[Transform3D]:
	return [_door_pose(0, "west"), _door_pose(1, "west"), _door_pose(2, "west"),
		_door_pose(3, "west")]


## The four walk mappings: crossing exit i lands at entrance (i + 1) % 4.
func _walk_mappings() -> Array[Transform3D]:
	var entrances := _entrance_poses()
	var exits := _exit_poses()
	var mappings: Array[Transform3D] = []
	for index in 4:
		mappings.append(PortalMathScript.mapping(exits[index], entrances[(index + 1) % 4]))
	return mappings


func _forward_basis(forward: Vector3) -> Basis:
	var normalized := forward.normalized()
	var right := normalized.cross(Vector3.UP).normalized()
	return Basis(right, Vector3.UP, -normalized).orthonormalized()


func _test_pair_mappings_are_rigid() -> void:
	var mappings := _walk_mappings()
	for index in mappings.size():
		var basis := (mappings[index] as Transform3D).basis
		_check(is_finite(mappings[index].origin.length_squared())
			and is_finite(basis.determinant()),
			"walk mapping %d left the finite range" % index)
		_check(absf(basis.determinant() - 1.0) <= 0.0001,
			"walk mapping %d is not orientation preserving" % index)
		_check(_basis_error(basis, basis.orthonormalized()) <= 0.0001,
			"walk mapping %d carries scale or shear" % index)


func _test_loop_is_quarter_turn() -> void:
	var mappings := _walk_mappings()
	var loop: Transform3D = State.loop_mapping(mappings)
	_check(absf(State.turn_angle(loop) - PI * 0.5) <= 0.0001,
		"the square's loop is not a +90° turn")
	_check(absf(loop.basis.determinant() - 1.0) <= 0.0001,
		"the loop is not orientation preserving")
	_check(loop.basis.y.distance_to(Vector3.UP) <= 0.0001,
		"the loop turns about a tilted axis")
	# The holonomy is exactly one quarter turn: four loops fold back to nothing.
	var pose := Transform3D(Basis.from_euler(Vector3(0.2, -0.7, 0.0)).orthonormalized(),
		Vector3(3.5, -1.25, 7.75))
	for _index in 4:
		pose = loop * pose
	_check(pose.origin.distance_to(Vector3(3.5, -1.25, 7.75)) <= 0.0005,
		"four loops did not restore the position")
	_check(_basis_error(pose.basis, Basis.from_euler(Vector3(0.2, -0.7, 0.0))
		.orthonormalized()) <= 0.0005, "four loops did not restore the orientation")


func _test_walk_arrivals() -> void:
	# Crossing each exit while walking into it must land upright, in front of
	# the next vault's entrance, facing into that vault. Positions are in the
	# arrival vault's frame; every door sits 5 cm off its wall plane.
	var exits := _exit_poses()
	var walks := [Vector3(-1, 0, 0), Vector3(-1, 0, 0), Vector3(-1, 0, 0), Vector3(-1, 0, 0)]
	var crossings := [Vector3(-DOOR_DEPTH - 0.05, 0.9, 0.0), Vector3(-DOOR_DEPTH - 0.05, 0.9, 0.0),
		Vector3(-DOOR_DEPTH - 0.05, 0.9, 0.0), Vector3(-DOOR_DEPTH - 0.05, 0.9, 0.0)]
	var expected_positions := [Vector3(0.0, 0.9, DOOR_DEPTH - 0.05),
		Vector3(0.0, 0.9, DOOR_DEPTH - 0.05), Vector3(DOOR_DEPTH - 0.05, 0.9, 0.0),
		Vector3(0.0, 0.9, DOOR_DEPTH - 0.05)]
	var expected_forwards := [Vector3(0, 0, -1), Vector3(0, 0, -1), Vector3(-1, 0, 0),
		Vector3(0, 0, -1)]
	var mappings := _walk_mappings()
	for step in 4:
		var arrival_vault := _vault_pose((step + 1) % 4)
		var crossing := _vault_pose(step) * Transform3D(
			_forward_basis(walks[step]), crossings[step])
		var arrival := arrival_vault.affine_inverse() * (mappings[step] * crossing)
		_check(arrival.origin.distance_to(expected_positions[step]) <= 0.01,
			"crossing exit %d did not land at the next entrance" % (step + 1))
		_check(arrival.basis.y.distance_to(Vector3.UP) <= 0.0001,
			"crossing exit %d tilted the traveller" % (step + 1))
		_check((-arrival.basis.z).normalized().dot(expected_forwards[step]) >= 0.999,
			"crossing exit %d did not face into the vault" % (step + 1))


func _test_reverse_door() -> void:
	# Walking back out of an entrance undoes exactly one vault: it lands at the
	# previous vault's exit, facing into that vault. The walk-out pose follows
	# the entrance's wall: south doors exit heading +Z, east doors heading +X.
	var entrances := _entrance_poses()
	var exits := _exit_poses()
	var walls := ["south", "south", "south", "east"]
	for index in 4:
		var back := PortalMathScript.mapping(entrances[index], exits[(index + 3) % 4])
		var previous_vault := _vault_pose((index + 3) % 4)
		var outward := Vector3(0, 0, 1) if walls[index] == "south" else Vector3(1, 0, 0)
		var walk_out := Vector3(0.0, 0.9, DOOR_DEPTH + 0.05) if walls[index] == "south" \
			else Vector3(DOOR_DEPTH + 0.05, 0.9, 0.0)
		var crossing := _vault_pose(index) * Transform3D(_forward_basis(outward), walk_out)
		var arrival := previous_vault.affine_inverse() * (back * crossing)
		_check(arrival.origin.distance_to(Vector3(-DOOR_DEPTH + 0.05, 0.9, 0.0)) <= 0.01,
			"walking out of entrance %d did not land at the previous exit" % (index + 1))
		_check((-arrival.basis.z).normalized().dot(Vector3(1, 0, 0)) >= 0.999,
			"the reversed crossing did not face into the vault")


func _test_room_turns() -> void:
	_check(is_equal_approx(State.room_turn("south", "west"), PI * 0.5),
		"in through south, out through west is not a left turn")
	_check(is_equal_approx(State.room_turn("south", "east"), -PI * 0.5),
		"in through south, out through east is not a right turn")
	_check(is_zero_approx(State.room_turn("south", "north")),
		"in through south, out through north does not go straight")
	_check(is_zero_approx(State.room_turn("east", "west")),
		"in through east, out through west does not go straight")
	_check(is_equal_approx(State.layout_turn(["south", "south", "south", "east"],
		["west", "west", "west", "west"]), PI * 0.5),
		"three lefts and a straight do not leave a +90° turn")


## The wall arithmetic must agree with the composed portal mappings for any
## draw: the exhibit trusts it to reject loops that close straight.
func _test_layout_turn_matches_mappings() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for draw in 60:
		var entrance_walls: Array[String] = []
		var exit_walls: Array[String] = []
		for _index in 4:
			var entrance: String = State.WALLS[rng.randi() % 4]
			var others := State.WALLS.filter(func(wall: String) -> bool: return wall != entrance)
			entrance_walls.append(entrance)
			exit_walls.append(others[rng.randi() % others.size()])
		var mappings: Array[Transform3D] = []
		for index in 4:
			mappings.append(PortalMathScript.mapping(_door_pose(index, exit_walls[index]),
				_door_pose((index + 1) % 4, entrance_walls[(index + 1) % 4])))
		var built := State.turn_angle(State.loop_mapping(mappings))
		_check(absf(angle_difference(built, State.layout_turn(entrance_walls, exit_walls))) <= 0.0001,
			"draw %d: the wall arithmetic disagrees with the composed mappings" % draw)


func _test_sight_line_cases() -> void:
	var ahead := func(x: float, z: float) -> Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3(x, 0.0, z))
	_check(State.sight_line([ahead.call(0.0, 0.0), ahead.call(0.0, 8.0), ahead.call(0.0, 16.0)],
		APERTURE_HALF_WIDTH), "three doors in a row hide their corridor")
	_check(State.sight_line([ahead.call(0.0, 0.0), ahead.call(2.0, 8.0), ahead.call(0.0, 16.0)],
		APERTURE_HALF_WIDTH), "a middle door 2 m aside blocks a view that still fits through")
	_check(not State.sight_line([ahead.call(0.0, 0.0), ahead.call(3.0, 8.0),
		ahead.call(0.0, 16.0)], APERTURE_HALF_WIDTH), "a middle door 3 m aside lets a view through")
	_check(not State.sight_line([ahead.call(0.0, 0.0),
		Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.0, 8.0)), ahead.call(0.0, 16.0)],
		APERTURE_HALF_WIDTH), "a view crosses a door against its way through")
	_check(State.sight_line(_chain(["south", "south", "south"], ["east", "west", "east"]),
		APERTURE_HALF_WIDTH), "right, left, right rooms do not stair-step a diagonal")
	_check(not State.sight_line(_chain(["south", "south"], ["east", "east"]), APERTURE_HALF_WIDTH),
		"two right turns do not fold the view back")
	_check(State.sight_line(_chain(["south", "south", "south"], ["north", "north", "north"]),
		APERTURE_HALF_WIDTH), "three straight rooms hide their corridor")
	# A door 50° off an eye's heading: in view at any width, out of a 60° field.
	var aside: Array[Transform3D] = [ahead.call(0.0, 0.0), ahead.call(8.0, 6.0)]
	_check(State.sight_line(aside, APERTURE_HALF_WIDTH), "a door 50° aside hides from a wide eye")
	_check(not State.sight_line(aside, APERTURE_HALF_WIDTH, tan(deg_to_rad(30.0))),
		"a door 50° aside shows inside a 60° field of view")


## The exact test must find every sight line a brute-force search does, on
## chains of three rooms drawn at random — a line it misses would show a door
## past the render pool's reach.
func _test_sight_line_misses_no_sampled_line() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var found := 0
	for draw in 300:
		var entrance_walls: Array[String] = []
		var exit_walls: Array[String] = []
		for _index in 3:
			var entrance := rng.randi() % 4
			entrance_walls.append(State.WALLS[entrance])
			exit_walls.append(State.WALLS[(entrance + 1 + rng.randi() % 3) % 4])
		var doors := _chain(entrance_walls, exit_walls)
		if _sampled_sight(doors):
			found += 1
			_check(State.sight_line(doors, APERTURE_HALF_WIDTH),
				"draw %d: the exact test missed a sight line through four doors" % draw)
	_check(found >= 20, "random draws gave too few sight lines to compare (%d)" % found)


## Doors crossed walking through these 6 × 8 m rooms in a row, unfolded through
## their portal mappings, each pose's +Z along the walk.
func _chain(entrances: Array, exits: Array) -> Array[Transform3D]:
	var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var frame := Transform3D.IDENTITY
	var doors: Array[Transform3D] = [_room_door(entrances[0])]
	for room in entrances.size():
		if room > 0:
			frame = frame * PortalMathScript.mapping(_room_door(entrances[room]),
				_room_door(exits[room - 1]))
		doors.append(frame * _room_door(exits[room]) * half_turn)
	return doors


func _room_door(wall: String) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, State.inward_yaw(wall)), ROOM_DOORS[wall])


## Brute force: lines through a grid of points on the first two doors, kept
## when they cross every later door in order and the right way round.
func _sampled_sight(doors: Array[Transform3D]) -> bool:
	var ends: Array[PackedVector2Array] = []
	for door in doors:
		var plus := door * Vector3(APERTURE_HALF_WIDTH, 0.0, 0.0)
		var minus := door * Vector3(-APERTURE_HALF_WIDTH, 0.0, 0.0)
		ends.append(PackedVector2Array([Vector2(minus.x, minus.z), Vector2(plus.x, plus.z)]))
	for near in 41:
		for far in 41:
			var origin := ends[0][0].lerp(ends[0][1], lerpf(0.01, 0.99, near / 40.0))
			var direction := ends[1][0].lerp(ends[1][1], lerpf(0.01, 0.99, far / 40.0)) - origin
			var reach := 0.0
			var first_way := doors[0].basis.z
			var crosses := direction.dot(Vector2(first_way.x, first_way.z)) > 0.0
			for index in range(1, doors.size()):
				var way := doors[index].basis.z
				var hit := _ray_hit(origin, direction, ends[index])
				crosses = crosses and hit > reach and direction.dot(Vector2(way.x, way.z)) > 0.0
				reach = hit
			if crosses:
				return true
	return false


## Ray parameter where origin + direction · t crosses the door, −1 on a miss.
func _ray_hit(origin: Vector2, direction: Vector2, door: PackedVector2Array) -> float:
	var span := door[1] - door[0]
	var denominator := direction.cross(span)
	if is_zero_approx(denominator):
		return -1.0
	var offset := door[0] - origin
	var within := offset.cross(direction) / denominator
	return offset.cross(span) / denominator if within >= 0.0 and within <= 1.0 else -1.0

