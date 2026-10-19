class_name ExhibitHolonomyLoop extends RefCounted
## Exhibit — the holonomy loop: five sealed vaults chained in a cycle, and the
## loop that closes them does not close straight — its composed mapping is a
## turn about the vertical ([method HolonomyState.loop_mapping]).
##
## The vaults stand on a ring: rooms, and corridors whose long walls take doors
## too. Each has an entrance and an exit on two different walls, set anywhere
## along them, all drawn at random every time the exhibit is entered or reset,
## and the links form one directed cycle ([member order]) — crossing the exit
## of a vault drops the player in front of the next one's entrance, so the only
## way around is the loop itself. A vault walks the loop straight on, left or
## right, so views run down corridors and stair-step along diagonals. A draw is
## kept only when the loop turns ([method HolonomyState.layout_turn]) and no
## straight line crosses more doors than the render pool follows ([method
## sight_outruns_views]). Every mapping stays rigid and the space stays
## euclidean room by room: the curvature is in the connectivity, never in a
## transform.
##
## The loop rearranges behind the player's back: whenever a vault drops out of
## every line of sight, the vaults nobody can see swap places in the cycle and
## the one just lost is rebuilt in a new shape ([method track]). Each keeps its
## turn, so the loop still comes back turned the same way — only the start vault
## stays put. A vault in view never changes.
##
## The start vault spells out the turns and what the loop leaves. The current
## vault's two doors hold live views ([member active_portals]) and so do the
## doors seen through them, down the loop ([member nested_portals]) as deep as
## the render pool follows; a door past that waits behind a dim stand-in of a
## vault that no line of sight reaches.
##
## The host drives it: [method track] every frame while active, before the
## render pool runs, so a crossing or a rearrangement re-binds the views ahead
## of the next image; [method reset] draws a new loop.

const VAULT_COUNT := 5
## Room shape; the start vault is always one, its walls carry the walk.
const VAULT := Vector3(6.0, 4.0, 8.0)
const CORRIDOR := Vector3(3.6, 4.0, 14.0)
## Share of the other vaults drawn as corridors.
const CORRIDOR_CHANCE := 0.4
const APERTURE := Vector2(2.6, 3.4)
## Clear wall kept between a door and the corner beside it.
const CORNER_MARGIN := 0.6
const RING := 30.0
## Slack on the sight test that decides what the player may see: wider doors
## and eye, a wider field of view (≈12°), and no change at all while the eye
## stands this close to one of its vault's doors.
const SEEN_MARGIN := 0.15
const FOV_MARGIN := 0.21
const DOOR_GUARD := 2.0
const NUMERALS := ["I", "II", "III", "IV", "V"]
const ACCENTS := [
	Color(0.3, 0.68, 1.0),
	Color(1.0, 0.5, 0.2),
	Color(0.35, 1.0, 0.6),
	Color(0.6, 0.9, 1.0),
	Color(1.0, 0.38, 0.78),
]

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Exit and entrance portal of each vault, indexed by vault.
var exits: Array[Portal3D] = []
var entrances: Array[Portal3D] = []
## Vault at each place of the cycle: crossing the exit of [code]order[k][/code]
## lands at the entrance of [code]order[k + 1][/code]. The start vault keeps
## place 0.
var order: Array[int] = []
## Shape of each vault: [constant VAULT] or [constant CORRIDOR].
var vault_sizes: Array[Vector3] = []
## Wall of each vault's entrance and exit, and each door's offset along its
## wall: +X on north and south walls, +Z on east and west ones.
var entrance_walls: Array[String] = []
var exit_walls: Array[String] = []
var entrance_offsets: Array[float] = []
var exit_offsets: Array[float] = []
## Turn one full walk of the current draw leaves behind, radians, positive left.
var turn_angle := 0.0
## The current vault's two doors: the ones the render pool views directly.
var active_portals: Array[Portal3D] = []
## Every door mapped to the far door of the vault it opens on: the chain the
## render pool follows from each active door.
var nested_portals: Dictionary = {}
## Boundary crossings counted so far — one per portal traversed.
var crossing_count := 0
## Times the loop rearranged out of sight since the last draw.
var rearrangements := 0

var _cell: Node3D
var _materials: Dictionary
var _reported := 0
var _place := 0
var _seen_last: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func build(cells: Node3D, materials: Dictionary) -> void:
	_materials = materials
	_cell = Node3D.new()
	_cell.name = "HolonomyLoop"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(-250.0, 0.0, -1200.0))
	cells.add_child(_cell)
	_rng.randomize()
	_build_loop()


## Reports whether a crossing or a rearrangement happened since the last call,
## so the host can re-bind the views and refresh its readout. Vaults that just
## left the player's sight trigger a rearrangement of everything unseen.
func track(player: NonEuclideanPlayer) -> bool:
	var changed := crossing_count != _reported
	_reported = crossing_count
	var seen := seen_vaults(player.get_camera())
	var lost: Array[int] = []
	for vault: int in _seen_last:
		if not seen.has(vault):
			lost.append(vault)
	_seen_last = seen
	if not lost.is_empty() and _rearrange(seen, lost):
		changed = true
	return changed


## Draws and builds a new loop and zeroes the counters. The host re-poses the
## player onto [member spawn_pose] right after.
func reset() -> void:
	crossing_count = 0
	_reported = 0
	_build_loop()


## The turn as the HUD and the start vault print it.
func turn_text() -> String:
	var degrees := roundi(rad_to_deg(turn_angle))
	if absi(degrees) == 180:
		return "180° AROUND"
	return "%d° %s" % [absi(degrees), "LEFT" if degrees > 0 else "RIGHT"]


## Whether a straight line crosses more doors of the current loop than the
## render pool follows — a live door, its nested views, then the stand-in one
## further. Sight lines run both ways, so the forward views cover the backward
## ones.
func sight_outruns_views() -> bool:
	for place in VAULT_COUNT:
		if HolonomyState.sight_line(_view_chain(place, true,
				PortalRenderManager.NESTED_DEPTH + 2), APERTURE.x * 0.5):
			return true
	return false


## Vaults [param camera] may see, as a set: the current one and, down each of
## its doors, every vault a straight line from the eye inside the field of view
## reaches. Everything counts as seen while the eye is in or near a doorway or
## looks too steeply up or down for the floor-plane test.
func seen_vaults(camera: Camera3D) -> Dictionary:
	var everything := {}
	for vault in VAULT_COUNT:
		everything[vault] = true
	if camera == null:
		return everything
	var here := _vault_at(_place)
	var node := _vault_node(here)
	var eye := node.to_local(camera.global_position)
	var size := vault_sizes[here]
	if absf(eye.x) > size.x * 0.5 or absf(eye.z) > size.z * 0.5:
		return everything
	for door in [_door_pose(here, true), _door_pose(here, false)]:
		if Vector2(eye.x - door.origin.x, eye.z - door.origin.z).length() < DOOR_GUARD:
			return everything
	var to_vault := node.global_basis.inverse()
	var forward := to_vault * -camera.global_basis.z
	var heading := Vector2(forward.x, forward.z)
	if heading.length() < 0.05:
		return everything
	var rect := camera.get_viewport().get_visible_rect()
	var spread := 0.0
	for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
			Vector2(rect.position.x, rect.end.y)]:
		var ray := to_vault * camera.project_ray_normal(corner)
		var flat := Vector2(ray.x, ray.z)
		if flat.length() < 0.01:
			return everything
		spread = maxf(spread, absf(heading.angle_to(flat)))
	spread += FOV_MARGIN
	if spread >= atan(HolonomyState.GRAZING_SLOPE):
		return everything
	var eye_pose := Transform3D(Basis(Vector3.UP, atan2(heading.x, heading.y)),
		Vector3(eye.x, 0.0, eye.z))
	var seen := {here: true}
	for walk in [1, -1]:
		var doors := _view_chain(_place, walk > 0, PortalRenderManager.NESTED_DEPTH + 2)
		for depth in doors.size():
			var sight: Array[Transform3D] = [eye_pose]
			sight.append_array(doors.slice(0, depth + 1))
			if not HolonomyState.sight_line(sight, APERTURE.x * 0.5 + SEEN_MARGIN,
					tan(spread)):
				break
			seen[_vault_at(_place + walk * (depth + 1))] = true
	return seen


func _build_loop() -> void:
	# Freed now, not queued: the new vaults reuse the names and the render pool
	# re-binds before the next frame.
	for child in _cell.get_children():
		child.free()
	for array: Array in [exits, entrances, vault_sizes, entrance_walls, exit_walls,
			entrance_offsets, exit_offsets]:
		array.clear()
		array.resize(VAULT_COUNT)
	order.assign(range(VAULT_COUNT))
	_place = 0
	_seen_last = {}
	rearrangements = 0
	_draw_vaults()
	for index in VAULT_COUNT:
		_build_vault(index, _materials)
	_link()
	# Spawn facing the exit door: the loop starts with the turn the walk keeps
	# handing back.
	var door := _wall_point(VAULT, exit_walls[0], exit_offsets[0], 0.0)
	spawn_pose = _vault_node(0).global_transform * Transform3D(
		Basis(Vector3.UP, atan2(-door.x, -door.z)), Vector3(0.0, 0.9, 0.0))


## Shapes, walls and door offsets at random, redrawn while the loop closes
## straight or a sight line outruns the live views onto a stand-in.
func _draw_vaults() -> void:
	var drawn := false
	while not drawn:
		for index in VAULT_COUNT:
			_draw_vault(index, 1 + _rng.randi() % 3)
		turn_angle = HolonomyState.layout_turn(entrance_walls, exit_walls)
		drawn = not is_zero_approx(turn_angle) and not sight_outruns_views()


## One vault's shape, walls and offsets, its exit [param side] quarter turns
## round from its entrance: 2 walks straight on, 1 and 3 turn.
func _draw_vault(index: int, side: int) -> void:
	var size := CORRIDOR if index > 0 and _rng.randf() < CORRIDOR_CHANCE else VAULT
	var entrance := _rng.randi() % 4
	vault_sizes[index] = size
	entrance_walls[index] = HolonomyState.WALLS[entrance]
	exit_walls[index] = HolonomyState.WALLS[(entrance + side) % 4]
	entrance_offsets[index] = _draw_offset(size, entrance_walls[index])
	exit_offsets[index] = _draw_offset(size, exit_walls[index])


func _draw_offset(size: Vector3, wall: String) -> float:
	var reach := maxf(0.0, _wall_length(size, wall) * 0.5 - APERTURE.x * 0.5 - CORNER_MARGIN)
	return _rng.randf_range(-reach, reach)


func _side(index: int) -> int:
	return posmod(HolonomyState.WALLS.find(exit_walls[index])
		- HolonomyState.WALLS.find(entrance_walls[index]), 4)


## Shuffles the unseen vaults among their places in the cycle — a vault just
## [param lost] from sight never keeps its place when another can take it — and
## rebuilds the lost ones in a new shape with the same turn, so the loop's
## holonomy holds. A try that would line a view up past the live doors is
## undone; after a few, the loop stays as it was.
func _rearrange(seen: Dictionary, lost: Array[int]) -> bool:
	var places: Array[int] = []
	for place in range(1, VAULT_COUNT):
		if not seen.has(order[place]):
			places.append(place)
	var redraw := lost.filter(func(vault: int) -> bool: return vault != 0 and not seen.has(vault))
	if places.size() < 2 and redraw.is_empty():
		return false
	var saved := [order.duplicate(), vault_sizes.duplicate(), entrance_walls.duplicate(),
		exit_walls.duplicate(), entrance_offsets.duplicate(), exit_offsets.duplicate()]
	for attempt in 24:
		var vaults: Array[int] = []
		for place in places:
			vaults.append(order[place])
		for index in range(vaults.size() - 1, 0, -1):
			var other := _rng.randi_range(0, index)
			var held := vaults[index]
			vaults[index] = vaults[other]
			vaults[other] = held
		var stayed := false
		for index in places.size():
			stayed = stayed or (vaults[index] == order[places[index]] and redraw.has(vaults[index]))
			order[places[index]] = vaults[index]
		for vault: int in redraw:
			_draw_vault(vault, _side(vault))
		if not (stayed and places.size() > 1 and attempt < 16) and not sight_outruns_views():
			for vault: int in redraw:
				_vault_node(vault).free()
				_build_vault(vault, _materials)
			_link()
			rearrangements += 1
			return true
		order.assign(saved[0])
		vault_sizes.assign(saved[1])
		entrance_walls.assign(saved[2])
		exit_walls.assign(saved[3])
		entrance_offsets.assign(saved[4])
		exit_offsets.assign(saved[5])
	return false


## Links every door along [member order] and points the live views at the
## current vault. One directed cycle: an exit lands at the next vault's
## entrance, and walking back out of an entrance undoes one vault. Each portal
## gets exactly one assignment — GeometryKit.link pairs would overwrite each
## other on a cycle this shape. Through an exit lies the next vault, whose far
## door is its exit; through an entrance lies the previous one, whose far door
## is its entrance. Idle doors get their stand-in back, so none samples another
## vault's view; the exit comes first, so a one-view pool keeps the door the
## walk heads for.
func _link() -> void:
	nested_portals = {}
	for place in VAULT_COUNT:
		var vault := order[place]
		var next := _vault_at(place + 1)
		var previous := _vault_at(place - 1)
		exits[vault].linked_portal = entrances[next]
		entrances[vault].linked_portal = exits[previous]
		nested_portals[exits[vault]] = exits[next]
		nested_portals[entrances[vault]] = entrances[previous]
		_set_gradient(entrances[vault], ACCENTS[vault])
		_set_gradient(exits[vault], ACCENTS[vault])
	var here := _vault_at(_place)
	active_portals.assign([exits[here], entrances[here]])


func _vault_at(place: int) -> int:
	return order[posmod(place, VAULT_COUNT)]


## Doors a view from inside the vault at [param place] crosses heading out
## through its exit (or its entrance), unfolded into that vault's frame
## through the portal mappings; each pose's +Z points along the view.
func _view_chain(place: int, forward: bool, count: int) -> Array[Transform3D]:
	var half_turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var frame := Transform3D.IDENTITY
	var doors: Array[Transform3D] = []
	var here := place
	for _step in count:
		var there := here + (1 if forward else -1)
		var leaving := _door_pose(_vault_at(here), not forward)
		doors.append(frame * leaving * half_turn)
		frame = frame * PortalMath.mapping(_door_pose(_vault_at(there), forward), leaving)
		here = there
	return doors


func _build_vault(index: int, materials: Dictionary) -> void:
	var accent: Color = ACCENTS[index]
	var size := vault_sizes[index]
	var angle := TAU * float(index) / float(VAULT_COUNT)
	var vault := Node3D.new()
	vault.name = "Vault%d" % (index + 1)
	vault.rotation.y = angle
	vault.position = Vector3(sin(angle), 0.0, cos(angle)) * RING
	_cell.add_child(vault)
	_build_shell(vault, index, materials)
	GeometryKit.add_ceiling_grid(vault, Vector2(size.x - 2.0, size.z - 3.0),
		size.y - 0.35, accent, 2 if size.x > 4.0 else 1, roundi(size.z / 3.0))
	GeometryKit.add_omni_light(vault, Vector3(0.0, size.y - 0.7, 0.0),
		Color(0.75, 0.8, 0.9), 1.6, 16.0, false)
	var blind := _blind_wall(index)
	var name_text := "VAULT %s" % NUMERALS[index]
	if index == 0:
		name_text += " · START"
	_add_wall_label(vault, size, blind, name_text, 2.7, accent, 72)
	if index == 0:
		_add_wall_label(vault, size, blind, _walk_text(), 1.5, Color(0.8, 0.86, 0.92), 30)
	for is_entrance in [true, false]:
		var wall := entrance_walls[index] if is_entrance else exit_walls[index]
		var portal := GeometryKit.add_portal(vault, "Portal%d%s" % [index + 1,
			"In" if is_entrance else "Out"], _door_pose(index, is_entrance))
		portal.teleported.connect(_on_portal_crossed)
		if is_entrance:
			entrances[index] = portal
		else:
			exits[index] = portal
		_build_door_frame(vault, size, wall,
			entrance_offsets[index] if is_entrance else exit_offsets[index], accent)


## Wall for the vault's name: the one facing the arrival when it has no door,
## else the first wall without one.
func _blind_wall(index: int) -> String:
	var facing: String = HolonomyState.WALLS[
		(HolonomyState.WALLS.find(entrance_walls[index]) + 2) % 4]
	if facing != exit_walls[index]:
		return facing
	for wall in HolonomyState.WALLS:
		if wall != entrance_walls[index] and wall != exit_walls[index]:
			return wall
	return facing


## The turns the vaults make, counted rather than listed since their order
## shifts, then what the loop leaves behind.
func _walk_text() -> String:
	var counts := {"LEFT": 0, "RIGHT": 0, "STRAIGHT": 0}
	for index in VAULT_COUNT:
		var turn := HolonomyState.room_turn(entrance_walls[index], exit_walls[index])
		counts["STRAIGHT" if is_zero_approx(turn) else ("LEFT" if turn > 0.0 else "RIGHT")] += 1
	var parts: Array[String] = []
	for word: String in counts:
		if counts[word] > 0:
			parts.append("%d %s" % [counts[word], word])
	return "%s\nTHE ROOMS REARRANGE WHEN YOU LOOK AWAY\nTHE LOOP STILL COMES BACK TURNED %s" % [
		" · ".join(parts), turn_text()]


func _add_wall_label(vault: Node3D, size: Vector3, wall: String, text: String,
		height: float, color: Color, font_size: int) -> void:
	var inward := Basis(Vector3.UP, HolonomyState.inward_yaw(wall))
	var half := (size.z if wall == "south" or wall == "north" else size.x) * 0.5
	GeometryKit.add_label(vault, text, inward.z * -(half - 0.12) + Vector3.UP * height,
		HolonomyState.inward_yaw(wall), color, font_size)


## Sealed box shell with two apertures. The floor, ceiling and the two blind
## walls are solid boxes; each door wall is jambs and a lintel around the
## aperture, built in a rotated frame so one helper serves all four sides.
func _build_shell(vault: Node3D, index: int, materials: Dictionary) -> void:
	var size := vault_sizes[index]
	var wall := 0.5
	var floor_body := GeometryKit.add_box(vault, Vector3(0.0, -wall * 0.5, 0.0),
		Vector3(size.x + wall * 2.0, wall, size.z + wall), materials["tile"])
	floor_body.name = "PortalThreshold"
	floor_body.set_meta("portal_threshold", true)
	GeometryKit.add_box(vault, Vector3(0.0, size.y + wall * 0.5, 0.0),
		Vector3(size.x + wall * 2.0, wall, size.z + wall), materials["concrete"])
	for side in HolonomyState.WALLS:
		if side == entrance_walls[index]:
			_add_aperture_wall(vault, size, side, entrance_offsets[index], materials["concrete"])
		elif side == exit_walls[index]:
			_add_aperture_wall(vault, size, side, exit_offsets[index], materials["concrete"])
		else:
			_add_solid_wall(vault, size, side, materials["concrete"])
	var probe := ReflectionProbe.new()
	probe.position = Vector3(0.0, size.y * 0.5, 0.0)
	probe.size = size - Vector3.ONE
	probe.box_projection = true
	probe.enable_shadows = false
	probe.cull_mask = Portal3D.WORLD_LAYER
	vault.add_child(probe)


func _add_solid_wall(vault: Node3D, size: Vector3, side: String, material: Material) -> void:
	var wall := 0.5
	match side:
		"north":
			GeometryKit.add_box(vault, Vector3(0.0, size.y * 0.5, -size.z * 0.5 - wall * 0.5),
				Vector3(size.x + wall * 2.0, size.y, wall), material)
		"south":
			GeometryKit.add_box(vault, Vector3(0.0, size.y * 0.5, size.z * 0.5 + wall * 0.5),
				Vector3(size.x + wall * 2.0, size.y, wall), material)
		"west":
			GeometryKit.add_box(vault, Vector3(-size.x * 0.5 - wall * 0.5, size.y * 0.5, 0.0),
				Vector3(wall, size.y, size.z + wall), material)
		"east":
			GeometryKit.add_box(vault, Vector3(size.x * 0.5 + wall * 0.5, size.y * 0.5, 0.0),
				Vector3(wall, size.y, size.z + wall), material)


## Jamb-and-lintel wall around the door's aperture, placed by rotating a frame
## so the wall builder always works in its own +Z.
func _add_aperture_wall(vault: Node3D, size: Vector3, side: String, offset: float,
		material: Material) -> void:
	var frame := Node3D.new()
	frame.name = "Aperture%s" % side.capitalize()
	frame.rotation.y = _outward_yaw(side)
	vault.add_child(frame)
	# North/south walls run the full outer width so they close against the
	# east/west walls, which span the depth.
	var deep := side == "south" or side == "north"
	var span := (size.x + 1.0 if deep else size.z + 0.5)
	var depth := (size.z if deep else size.x) * 0.5 + 0.25
	GeometryKit.add_opening_wall(frame, Vector3(span, size.y, 0.0), APERTURE, depth,
		material, _frame_x(side, offset))


## Portal pose flush in the aperture: node at the wall's mid-thickness, front
## facing into the vault.
func _door_pose(index: int, entrance: bool) -> Transform3D:
	var wall := entrance_walls[index] if entrance else exit_walls[index]
	var offset := entrance_offsets[index] if entrance else exit_offsets[index]
	return Transform3D(Basis(Vector3.UP, HolonomyState.inward_yaw(wall)),
		_wall_point(vault_sizes[index], wall, offset, APERTURE.y * 0.5))


func _wall_point(size: Vector3, wall: String, offset: float, height: float) -> Vector3:
	var wall_thickness := 0.25
	match wall:
		"south":
			return Vector3(offset, height, size.z * 0.5 + wall_thickness)
		"north":
			return Vector3(offset, height, -size.z * 0.5 - wall_thickness)
		"west":
			return Vector3(-size.x * 0.5 - wall_thickness, height, offset)
		"east":
			return Vector3(size.x * 0.5 + wall_thickness, height, offset)
	return Vector3.ZERO


func _wall_length(size: Vector3, wall: String) -> float:
	return size.x if wall == "south" or wall == "north" else size.z


## Yaw whose local +Z points into the wall — the convention of the aperture
## wall builder, which always works at +Z.
func _outward_yaw(wall: String) -> float:
	return wrapf(HolonomyState.inward_yaw(wall) + PI, -PI, PI)


## A door's offset along its wall, as X in the wall's outward frame.
func _frame_x(wall: String, offset: float) -> float:
	var along := Vector3(offset, 0.0, 0.0) if wall == "south" or wall == "north" \
		else Vector3(0.0, 0.0, offset)
	return (Basis(Vector3.UP, _outward_yaw(wall)).inverse() * along).x


## Lit trim around one aperture, in the vault's accent, so every door reads as
## its vault's color.
func _build_door_frame(vault: Node3D, size: Vector3, wall: String, offset: float,
		accent: Color) -> void:
	var frame_material := GeometryKit.make_material(Color(0.1, 0.12, 0.14), 0.2, 0.25,
		accent, 3.2)
	var frame := Node3D.new()
	frame.name = "DoorFrame%s" % wall.capitalize()
	frame.rotation.y = _outward_yaw(wall)
	vault.add_child(frame)
	var x := _frame_x(wall, offset)
	var depth := (size.z if wall == "south" or wall == "north" else size.x) * 0.5 - 0.04
	GeometryKit.add_box(frame, Vector3(x - APERTURE.x * 0.5 - 0.06, APERTURE.y * 0.5, depth),
		Vector3(0.12, APERTURE.y + 0.12, 0.08), frame_material, false)
	GeometryKit.add_box(frame, Vector3(x + APERTURE.x * 0.5 + 0.06, APERTURE.y * 0.5, depth),
		Vector3(0.12, APERTURE.y + 0.12, 0.08), frame_material, false)
	GeometryKit.add_box(frame, Vector3(x, APERTURE.y + 0.06, depth),
		Vector3(APERTURE.x + 0.36, 0.12, 0.08), frame_material, false)


## Stand-in for a door past the render pool's reach: the bands of a vault seen
## head-on from afar — dark ceiling, accent-lit wall, darker floor — so a door
## deep down the loop reads as one more room, never as a missing view.
func _set_gradient(portal: Portal3D, accent: Color) -> void:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.2, 0.64, 0.68, 1.0])
	gradient.colors = PackedColorArray([accent.darkened(0.95), accent.darkened(0.85),
		accent.darkened(0.87), accent.darkened(0.93), accent.darkened(0.96)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0.0, 0.0)
	texture.fill_to = Vector2(0.0, 1.0)
	portal.set_placeholder(texture)


func _on_portal_crossed(_body: Node3D, destination: Portal3D) -> void:
	crossing_count += 1
	_place = order.find(maxi(entrances.find(destination), exits.find(destination)))
	_link()


func _vault_node(index: int) -> Node3D:
	return _cell.get_node("Vault%d" % (index + 1)) as Node3D
