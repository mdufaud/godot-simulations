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


func _initialize() -> void:
	_test_pair_mappings_are_rigid()
	_test_loop_is_quarter_turn()
	_test_walk_arrivals()
	_test_reverse_door()
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
	var loop: Transform3D = State.loop_mapping(mappings[0], mappings[1], mappings[2],
		mappings[3])
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
