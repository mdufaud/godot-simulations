class_name ExhibitHolonomyLoop extends RefCounted
## Exhibit — the holonomy square: four sealed vaults chained in a cycle, and the
## loop that closes them does not close straight — its composed mapping is a
## pure quarter turn ([method HolonomyState.loop_mapping], +90° about Y).
##
## The four vaults stand at the cardinal points of a ring. Each has two doors:
## an entrance and an exit, and the links form one directed cycle — crossing the
## exit of vault i drops the player in front of vault i+1's entrance, so the
## only way around is the loop itself. Vaults I–III are entered from their south
## door and leave through their west one (turn left); vault IV is entered from
## its east door and leaves through its west one (walk straight). Those wall
## choices are the whole trick: each walk mapping turns the traveller's frame
## by −90°, three of them plus the straight vault compose to a +90° yaw — walk
## the square, come back turned. Every mapping stays rigid and the space stays
## euclidean room by room: the curvature is in the connectivity, never in a
## transform.
##
## The paradox is dead-reckoned, not thrown at you: every arrival faces into
## its room, yet the vault you return to has no door on the wall you just
## walked in from — four left turns and a straight should not close a square.
## The HUD counts crossings; [method HolonomyState.turn_angle] states the
## quarter turn for the tests. The portals render an opaque accent gradient
## (MVP): the doors read as glowing membranes, and crossing one swaps the room
## without spending a live view slot.
##
## The host drives it: [method track] every physics frame while active, [method
## reset] on reset.

const VAULT := Vector3(6.0, 4.0, 8.0)
const APERTURE := Vector2(2.6, 3.4)
const RING := 24.0
## Yaw of each vault node along the walk I → II → III → IV; the ring's outward
## direction is the vault's local +Z.
const VAULT_ANGLES := [0.0, PI * 0.5, PI, -PI * 0.5]
## Wall of each vault's entrance along the walk. Vaults I–III take their
## entrance on the south (outer) wall; vault IV is entered from the east —
## the straight-through vault that makes the loop turn instead of closing.
const ENTRANCE_WALLS := ["south", "south", "south", "east"]
## Every exit sits on a west wall: three left turns, then vault IV's straight.
const EXIT_WALLS := ["west", "west", "west", "west"]

const VAULT_NAMES := ["VAULT I · START", "VAULT II", "VAULT III", "VAULT IV"]
const ACCENTS := [
	Color(0.3, 0.68, 1.0),
	Color(1.0, 0.5, 0.2),
	Color(0.35, 1.0, 0.6),
	Color(0.6, 0.9, 1.0),
]

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## The four exit portals, walk order I → II → III → IV.
var exits: Array[Portal3D] = []
## The four entrance portals; [code]entrances[i][/code] receives the walk from
## [code]exits[(i + 3) % 4][/code].
var entrances: Array[Portal3D] = []
## Every portal of the cycle, walk order (exits then entrances interleaved).
var portals: Array[Portal3D] = []
## Boundary crossings counted so far — one per portal traversed, four per loop.
var crossing_count := 0

var _cell: Node3D
var _reported := 0


func build(cells: Node3D, materials: Dictionary) -> void:
	_cell = Node3D.new()
	_cell.name = "HolonomyLoop"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(-250.0, 0.0, -1200.0))
	cells.add_child(_cell)
	for index in VAULT_ANGLES.size():
		_build_vault(index, materials)
	# One directed cycle: crossing the exit of vault i always lands at vault
	# i+1's entrance, and walking back out of an entrance undoes one vault.
	# Each portal gets exactly one assignment — GeometryKit.link pairs would
	# overwrite each other on a cycle this shape.
	for index in exits.size():
		exits[index].linked_portal = entrances[(index + 1) % exits.size()]
		entrances[index].linked_portal = exits[(index + exits.size() - 1) % exits.size()]
	# Spawn facing the exit door: the loop starts with the turn the walk keeps
	# handing back.
	spawn_pose = _vault_node(0).global_transform * Transform3D(
		Basis(Vector3.UP, PI * 0.5), Vector3(0.0, 0.9, 0.0))


## Reports whether a crossing happened since the last call, so the host can
## refresh its readout.
func track(_player: NonEuclideanPlayer) -> bool:
	var changed := crossing_count != _reported
	_reported = crossing_count
	return changed


## Zeroes the crossing counter. The host re-poses the player onto [member
## spawn_pose] right after.
func reset() -> void:
	crossing_count = 0
	_reported = 0


func _build_vault(index: int, materials: Dictionary) -> void:
	var accent: Color = ACCENTS[index]
	var vault := Node3D.new()
	vault.name = "Vault%d" % (index + 1)
	vault.rotation.y = VAULT_ANGLES[index]
	var outward := Vector3(sin(VAULT_ANGLES[index]), 0.0, cos(VAULT_ANGLES[index]))
	vault.position = outward * RING
	_cell.add_child(vault)
	_build_shell(vault, ENTRANCE_WALLS[index], EXIT_WALLS[index], materials)
	GeometryKit.add_ceiling_grid(vault, Vector2(VAULT.x - 2.0, VAULT.z - 3.0),
		VAULT.y - 0.35, accent, 2, 3)
	GeometryKit.add_omni_light(vault, Vector3(0.0, VAULT.y - 0.7, 0.0),
		Color(0.75, 0.8, 0.9), 1.6, 16.0, false)
	# Name wall: always the north wall — solid in every vault, so the label
	# never fights a door frame.
	GeometryKit.add_label(vault, VAULT_NAMES[index],
		Vector3(0.0, 2.7, -VAULT.z * 0.5 + 0.12), 0.0, accent, 72)
	if index == 0:
		GeometryKit.add_label(vault, "THREE LEFTS AND A STRAIGHT\nTHE SQUARE COMES BACK TURNED",
			Vector3(0.0, 1.7, -VAULT.z * 0.5 + 0.12), 0.0, Color(0.8, 0.86, 0.92), 34)
	for pair in [[true, ENTRANCE_WALLS[index]], [false, EXIT_WALLS[index]]]:
		var is_entrance: bool = pair[0]
		var wall: String = pair[1]
		var portal := GeometryKit.add_portal(vault, "Portal%d%s" % [index + 1,
			"In" if is_entrance else "Out"],
			_door_pose(wall, APERTURE))
		_set_gradient(portal, accent)
		portal.teleported.connect(_on_portal_crossed)
		portals.append(portal)
		if is_entrance:
			entrances.append(portal)
		else:
			exits.append(portal)
		_build_door_frame(vault, wall, accent)


## Sealed box shell with two apertures. The floor, ceiling and the two blind
## walls are solid boxes; each door wall is jambs and a lintel around the
## aperture, built in a rotated frame so one helper serves all four sides.
func _build_shell(vault: Node3D, entrance_wall: String, exit_wall: String,
		materials: Dictionary) -> void:
	var wall := 0.5
	var floor_body := GeometryKit.add_box(vault, Vector3(0.0, -wall * 0.5, 0.0),
		Vector3(VAULT.x + wall * 2.0, wall, VAULT.z + wall), materials["tile"])
	floor_body.name = "PortalThreshold"
	floor_body.set_meta("portal_threshold", true)
	GeometryKit.add_box(vault, Vector3(0.0, VAULT.y + wall * 0.5, 0.0),
		Vector3(VAULT.x + wall * 2.0, wall, VAULT.z + wall), materials["concrete"])
	for side in ["north", "south", "east", "west"]:
		if side == entrance_wall or side == exit_wall:
			_add_aperture_wall(vault, side, materials["concrete"])
		else:
			_add_solid_wall(vault, side, materials["concrete"])
	var probe := ReflectionProbe.new()
	probe.position = Vector3(0.0, VAULT.y * 0.5, 0.0)
	probe.size = VAULT - Vector3.ONE
	probe.box_projection = true
	probe.enable_shadows = false
	probe.cull_mask = Portal3D.WORLD_LAYER
	vault.add_child(probe)


func _add_solid_wall(vault: Node3D, side: String, material: Material) -> void:
	var wall := 0.5
	match side:
		"north":
			GeometryKit.add_box(vault, Vector3(0.0, VAULT.y * 0.5, -VAULT.z * 0.5 - wall * 0.5),
				Vector3(VAULT.x + wall * 2.0, VAULT.y, wall), material)
		"south":
			GeometryKit.add_box(vault, Vector3(0.0, VAULT.y * 0.5, VAULT.z * 0.5 + wall * 0.5),
				Vector3(VAULT.x + wall * 2.0, VAULT.y, wall), material)
		"west":
			GeometryKit.add_box(vault, Vector3(-VAULT.x * 0.5 - wall * 0.5, VAULT.y * 0.5, 0.0),
				Vector3(wall, VAULT.y, VAULT.z + wall), material)
		"east":
			GeometryKit.add_box(vault, Vector3(VAULT.x * 0.5 + wall * 0.5, VAULT.y * 0.5, 0.0),
				Vector3(wall, VAULT.y, VAULT.z + wall), material)


## Jamb-and-lintel wall with the shared aperture, placed by rotating a frame so
## the wall builder always works in its own +Z.
func _add_aperture_wall(vault: Node3D, side: String, material: Material) -> void:
	var frame := Node3D.new()
	frame.name = "Aperture%s" % side.capitalize()
	match side:
		"south":
			frame.rotation.y = 0.0
		"west":
			frame.rotation.y = -PI * 0.5
		"east":
			frame.rotation.y = PI * 0.5
		"north":
			frame.rotation.y = PI
	vault.add_child(frame)
	# Offset and width follow the wall's own axis: the vault is 6 m wide but
	# 8 m deep, so reusing the depth offset for the east/west walls left them
	# a metre outside the room with a void band in between. North/south walls
	# run the full outer width so they close against the east/west walls.
	var deep := side == "south" or side == "north"
	var span := (VAULT.x + 1.0 if deep else VAULT.z + 0.5)
	var offset := (VAULT.z if deep else VAULT.x) * 0.5 + 0.25
	GeometryKit.add_opening_wall(frame, Vector3(span, VAULT.y, VAULT.z), APERTURE,
		offset, material)


## Portal pose flush in the aperture: node at the wall's mid-thickness, front
## facing into the vault.
func _door_pose(wall: String, size: Vector2) -> Transform3D:
	var yaw := 0.0
	match wall:
		"south":
			yaw = PI
		"west":
			yaw = PI * 0.5
		"east":
			yaw = -PI * 0.5
		"north":
			yaw = 0.0
	return Transform3D(Basis(Vector3.UP, yaw), _wall_point(wall,
		Vector3(0.0, size.y * 0.5, 0.0)))


func _wall_point(wall: String, offset: Vector3) -> Vector3:
	var wall_thickness := 0.25
	match wall:
		"south":
			return Vector3(offset.x, offset.y, VAULT.z * 0.5 + wall_thickness)
		"north":
			return Vector3(offset.x, offset.y, -VAULT.z * 0.5 - wall_thickness)
		"west":
			return Vector3(-VAULT.x * 0.5 - wall_thickness, offset.y, offset.z)
		"east":
			return Vector3(VAULT.x * 0.5 + wall_thickness, offset.y, offset.z)
	return offset


## Yaw whose local +Z points into the vault: the convention of portal fronts.
func _inward_yaw(wall: String) -> float:
	match wall:
		"south":
			return PI
		"north":
			return 0.0
		"west":
			return PI * 0.5
		"east":
			return -PI * 0.5
	return 0.0


## Yaw whose local +Z points into the wall — the convention of the aperture
## wall builder, which always works at +Z.
func _outward_yaw(wall: String) -> float:
	return wrapf(_inward_yaw(wall) + PI, -PI, PI)


## Lit trim around one aperture, in the vault's accent, so every door reads as
## its vault's color.
func _build_door_frame(vault: Node3D, wall: String, accent: Color) -> void:
	var frame_material := GeometryKit.make_material(Color(0.1, 0.12, 0.14), 0.2, 0.25,
		accent, 3.2)
	var frame := Node3D.new()
	frame.rotation.y = _outward_yaw(wall)
	vault.add_child(frame)
	var depth := VAULT.z * 0.5 - 0.04
	GeometryKit.add_box(frame, Vector3(-APERTURE.x * 0.5 - 0.06, APERTURE.y * 0.5, depth),
		Vector3(0.12, APERTURE.y + 0.12, 0.08), frame_material, false)
	GeometryKit.add_box(frame, Vector3(APERTURE.x * 0.5 + 0.06, APERTURE.y * 0.5, depth),
		Vector3(0.12, APERTURE.y + 0.12, 0.08), frame_material, false)
	GeometryKit.add_box(frame, Vector3(0.0, APERTURE.y + 0.06, depth),
		Vector3(APERTURE.x + 0.36, 0.12, 0.08), frame_material, false)


## Opaque MVP surface: a screen-space accent gradient instead of a live view.
func _set_gradient(portal: Portal3D, accent: Color) -> void:
	var gradient := Gradient.new()
	gradient.set_color(0, accent)
	gradient.set_color(1, accent.darkened(0.85))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	portal.set_render_texture(texture)


func _on_portal_crossed(_body: Node3D, _destination: Portal3D) -> void:
	crossing_count += 1


func _vault_node(index: int) -> Node3D:
	return _cell.get_node("Vault%d" % (index + 1)) as Node3D
