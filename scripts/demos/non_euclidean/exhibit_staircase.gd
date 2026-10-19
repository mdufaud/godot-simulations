class_name ExhibitStaircase extends RefCounted
## Exhibit 2 — a helical stairwell that never ends.
##
## Four identical modules are stacked; crossing the top of the stack teleports the
## player down one module, so climbing is unbounded while the geometry stays
## finite. Walking back down cancels the illusion: the ground floor returns to its
## real height and the loop seal reopens.
##
## The doorway opens on a ground-level landing; the flight starts at its left
## jamb and its first turn rests on a solid base that ends at the right jamb.
## Every turn after that hangs on a smooth helical soffit. The steps are drawn,
## but the player walks a smooth ramp through the middle of every tread, so no
## riser can catch the capsule and feet stay within half a riser of the stone.
##
## The host drives it: [method track] every physics frame, [method set_active]
## when the exhibit is selected.

const PERIOD := 4.0
const WRAP_HEIGHT := 8.37
const SEGMENTS := 48
const STEPS := 24
const RISE := PERIOD / STEPS
## Arc cuts per step: the soffit and the rail curve through them.
const STEP_CUTS := 3
const CENTER_RADIUS := 3.225
const WIDTH := 2.65
const OUTER_RADIUS := 4.55
## Visual step edges, buried in the core and in the outer wall so no seam shows.
const INNER_EDGE := 1.85
const OUTER_EDGE := 4.6
const SOFFIT_DEPTH := 0.24
const NOSING := 0.035
## The doorway takes the outer-wall segments within this angle of +Z.
const DOOR_HALF_ANGLE := PI / 8.0
const DOOR_HEIGHT := 3.0
## Left jamb of the doorway, seen from inside: the flight climbs from there.
const START_ANGLE := PI * 0.5 + DOOR_HALF_ANGLE
## Steps of the first turn that rest on the solid base: all but those over the
## landing, whose underside must clear the doorway.
const BASE_STEPS := 21
const RAIL_HEIGHT := 0.95
const RAIL_RADIUS := 4.47

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## How many times the player has crossed the wrap plane without going back down.
var ascent_count := 0

var _cell: Node3D
var _ground_level: Node3D
var _loop_seal: Node3D
var _fill_light: OmniLight3D
var _palette: Dictionary
var _previous_local_y := 0.0


## [param player] carries the fill light, which follows the climb instead of
## lighting a stairwell that repeats every four metres.
func build(cells: Node3D, materials: Dictionary, player: NonEuclideanPlayer) -> void:
	_cell = Node3D.new()
	_cell.name = "InfiniteStaircase"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(250.0, 0.0, -200.0))
	cells.add_child(_cell)
	_ground_level = Node3D.new()
	_ground_level.name = "GroundLevel"
	_cell.add_child(_ground_level)
	_build_corridor(_ground_level, materials)
	_palette = {
		"tread": GeometryKit.make_material(Color(0.47, 0.46, 0.43), 0.0, 0.72),
		"riser": GeometryKit.make_material(Color(0.13, 0.14, 0.15), 0.0, 0.8),
		"under": materials["stair_plain"],
		"glow": GeometryKit.make_material(Color(0.04, 0.09, 0.07), 0.0, 0.5,
			Color(0.35, 0.95, 0.62), 2.4),
	}
	_build_core(_cell, materials)
	for module_index in range(0, 4):
		_build_module(_cell, float(module_index) * PERIOD, module_index == 0, materials)
	_build_loop_seal(_cell)
	_fill_light = OmniLight3D.new()
	_fill_light.name = "StairFillLight"
	_fill_light.position = Vector3(0.0, 0.75, 0.0)
	_fill_light.light_color = Color(1.0, 0.9, 0.78)
	_fill_light.light_energy = 2.4
	_fill_light.omni_range = 14.0
	_fill_light.shadow_enabled = false
	_fill_light.visible = false
	player.add_child(_fill_light)
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(-0.6, 0.9, 8.5))


## Wraps the player when they pass the top of the stack, and undoes the climb the
## moment they head back down. Returns [code]true[/code] when [member
## ascent_count] changed, so the host can refresh its readout.
func track(player: NonEuclideanPlayer) -> bool:
	var local_position := _cell.to_local(player.global_position)
	if local_position.y >= WRAP_HEIGHT:
		player.global_position += _cell.global_basis * Vector3(0.0, -PERIOD, 0.0)
		player._portal_previous_position = player.global_position
		player.reset_physics_interpolation()
		ascent_count += 1
		_ground_level.position.y = -float(ascent_count) * PERIOD
		_set_loop_sealed(true)
		_previous_local_y = local_position.y - PERIOD
		return true
	var moved_down := local_position.y < _previous_local_y - 0.002
	var falling_down := player.velocity.dot(_cell.global_basis.y) < -0.2
	_previous_local_y = local_position.y
	if ascent_count > 0 and (moved_down or falling_down):
		reset()
		return true
	return false


func set_active(active: bool, player: NonEuclideanPlayer) -> void:
	_fill_light.visible = active
	if active:
		_previous_local_y = _cell.to_local(player.global_position).y


func reset() -> void:
	ascent_count = 0
	_ground_level.position.y = 0.0
	_set_loop_sealed(false)


func _build_corridor(parent: Node3D, materials: Dictionary) -> void:
	var ground_floor := GeometryKit.add_box(parent, Vector3(0.0, -0.12, 0.0),
		Vector3(10.2, 0.24, 10.2), materials["tile"])
	ground_floor.name = "StairGroundFloor"
	GeometryKit.add_box(parent, Vector3(0.0, -0.1, 7.45), Vector3(3.2, 0.2, 6.3),
		materials["tile"])
	GeometryKit.add_box(parent, Vector3(-1.85, 2.0, 7.45), Vector3(0.5, 4.0, 6.3),
		materials["concrete"])
	GeometryKit.add_box(parent, Vector3(1.85, 2.0, 7.45), Vector3(0.5, 4.0, 6.3),
		materials["concrete"])
	# Starts inside the stairwell wall: the flight passes just above it there.
	GeometryKit.add_box(parent, Vector3(0.0, 4.0, 7.6), Vector3(3.2, 0.25, 6.0),
		materials["concrete"])
	GeometryKit.add_box(parent, Vector3(0.0, 2.0, 10.6), Vector3(4.2, 4.0, 0.5),
		materials["concrete"])
	var label := GeometryKit.add_label(parent, "STAIRWELL ∞\nFLOOR 00",
		Vector3(0.0, 2.65, 10.32), PI, Color(0.2, 1.0, 0.55), 42)
	label.pixel_size = 0.004
	GeometryKit.add_ceiling_light(parent, Vector3(0.0, 3.72, 8.2), Color(0.45, 1.0, 0.72))


## Solid column the flights wrap around: it hides the wrap seam from every angle
## the player can look inwards from.
func _build_core(parent: Node3D, materials: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.name = "SolidCore"
	body.position.y = 8.0
	var mesh_instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.9
	mesh.bottom_radius = 1.9
	mesh.height = 20.0
	mesh.radial_segments = SEGMENTS
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	mesh_instance.material_override = materials["stair_plain"]
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 1.9
	shape.height = 20.0
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)


func _build_module(parent: Node3D, base_y: float, entrance_open: bool,
		materials: Dictionary) -> void:
	_add_helical_flight(parent, base_y, entrance_open)
	_add_outer_wall(parent, base_y, entrance_open, materials)


## One full turn: drawn steps over the walkable ramp. The ramp segments are
## tilted along the helix with their top on the pitch line; the first turn adds
## a lead-in from the landing floor and a collision face on the base end.
func _add_helical_flight(parent: Node3D, base_y: float, first: bool) -> void:
	var body := StaticBody3D.new()
	body.name = "HelicalFlight"
	body.set_meta("infinite_stair_ramp", true)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Steps"
	mesh_instance.mesh = _flight_mesh(base_y, first)
	mesh_instance.layers = Portal3D.WORLD_LAYER
	body.add_child(mesh_instance)
	var segment_angle := TAU / float(SEGMENTS)
	var length := TAU * OUTER_RADIUS / float(SEGMENTS) * 1.08
	var slope := atan(PERIOD / (TAU * CENTER_RADIUS))
	for index in range(-1 if first else 0, SEGMENTS):
		var turn := (float(index) + 0.5) * segment_angle
		var radial := _radial(turn)
		var ramp_basis := Basis(radial, Vector3.UP, _tangent(turn)) \
			* Basis(Vector3.RIGHT, -slope)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(WIDTH, 0.16, length)
		collision.shape = shape
		collision.transform = Transform3D(ramp_basis,
			radial * CENTER_RADIUS + Vector3.UP * (base_y + _pitch(turn) - 0.08))
		body.add_child(collision)
	if first:
		var end_turn := float(BASE_STEPS) * TAU / float(STEPS)
		var radial := _radial(end_turn)
		var tangent := _tangent(end_turn)
		var height := base_y + _soffit(end_turn)
		var face := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(WIDTH, height, 0.2)
		face.shape = shape
		face.transform = Transform3D(Basis(radial, Vector3.UP, tangent),
			radial * CENTER_RADIUS + Vector3(0.0, height * 0.5, 0.0) - tangent * 0.1)
		body.add_child(face)
	parent.add_child(body)


## Treads, risers lit along their nosing, the helical soffit with an LED strip
## (or, under the first turn, the solid base and its end face) and the glowing
## handrail on the outer wall.
func _flight_mesh(base_y: float, first: bool) -> ArrayMesh:
	var surfaces := {}
	for key in ["tread", "riser", "under", "glow"]:
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfaces[key] = tool
	var step_angle := TAU / float(STEPS)
	var cut := step_angle / float(STEP_CUTS)
	for step in STEPS:
		var top := base_y + float(step + 1) * RISE
		var start := float(step) * step_angle
		var back := -_tangent(start)
		_quad(surfaces["riser"], _point(start, INNER_EDGE, top - RISE),
			_point(start, OUTER_EDGE, top - RISE), _point(start, OUTER_EDGE, top - NOSING),
			_point(start, INNER_EDGE, top - NOSING), back)
		_quad(surfaces["glow"], _point(start, INNER_EDGE, top - NOSING) + back * 0.003,
			_point(start, OUTER_EDGE, top - NOSING) + back * 0.003,
			_point(start, OUTER_EDGE, top) + back * 0.003,
			_point(start, INNER_EDGE, top) + back * 0.003, back)
		var on_base := first and step < BASE_STEPS
		for index in STEP_CUTS:
			var from := start + float(index) * cut
			var to := from + cut
			_quad(surfaces["tread"], _point(from, INNER_EDGE, top), _point(to, INNER_EDGE, top),
				_point(to, OUTER_EDGE, top), _point(from, OUTER_EDGE, top), Vector3.UP)
			var rail_from := base_y + _pitch(from) + RAIL_HEIGHT
			var rail_to := base_y + _pitch(to) + RAIL_HEIGHT
			_quad(surfaces["glow"], _point(from, RAIL_RADIUS, rail_from),
				_point(to, RAIL_RADIUS, rail_to), _point(to, OUTER_RADIUS, rail_to),
				_point(from, OUTER_RADIUS, rail_from), Vector3.UP)
			_quad(surfaces["glow"], _point(from, RAIL_RADIUS, rail_from - 0.06),
				_point(to, RAIL_RADIUS, rail_to - 0.06), _point(to, RAIL_RADIUS, rail_to),
				_point(from, RAIL_RADIUS, rail_from), -_radial(from + cut * 0.5))
			if on_base:
				continue
			# Radial bands sharing their edges: the middle one is the LED strip,
			# flush with the soffit since a twisted quad would bury an offset one.
			var under_from := base_y + _soffit(from)
			var under_to := base_y + _soffit(to)
			var bands := [INNER_EDGE, CENTER_RADIUS - 0.04, CENTER_RADIUS + 0.04, OUTER_EDGE]
			for band in 3:
				var inner: float = bands[band]
				var outer: float = bands[band + 1]
				_quad(surfaces["glow" if band == 1 else "under"], _point(from, inner, under_from),
					_point(to, inner, under_to), _point(to, outer, under_to),
					_point(from, outer, under_from), Vector3.DOWN)
	if first:
		var end := float(BASE_STEPS) * step_angle
		var height := base_y + _soffit(end)
		_quad(surfaces["under"], _point(end, INNER_EDGE, base_y), _point(end, OUTER_EDGE, base_y),
			_point(end, OUTER_EDGE, height), _point(end, INNER_EDGE, height), _tangent(end))
	var mesh := ArrayMesh.new()
	for key in surfaces:
		(surfaces[key] as SurfaceTool).commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _palette[key])
	return mesh


## Walkable height above the module base, [param turn] radians past the start:
## through the middle of every tread.
func _pitch(turn: float) -> float:
	return PERIOD * turn / TAU + RISE * 0.5


## Underside of the flight: parallel to the pitch line, [constant SOFFIT_DEPTH]
## under the foot of every riser.
func _soffit(turn: float) -> float:
	return PERIOD * turn / TAU - SOFFIT_DEPTH


func _radial(turn: float) -> Vector3:
	return Vector3(cos(START_ANGLE + turn), 0.0, sin(START_ANGLE + turn))


## Direction of the climb.
func _tangent(turn: float) -> Vector3:
	return Vector3(-sin(START_ANGLE + turn), 0.0, cos(START_ANGLE + turn))


func _point(turn: float, radius: float, height: float) -> Vector3:
	return _radial(turn) * radius + Vector3.UP * height


## Quad a-b-c-d (in perimeter order) as two triangles whose front faces
## [param outward]: Godot draws clockwise triangles as front.
func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		outward: Vector3) -> void:
	var corners := [a, b, c, d]
	if (b - a).cross(c - a).dot(outward) > 0.0:
		corners = [a, d, c, b]
	tool.set_normal((corners[2] - corners[0]).cross(corners[1] - corners[0]).normalized())
	for index in [0, 1, 2, 0, 2, 3]:
		tool.add_vertex(corners[index])


func _add_outer_wall(parent: Node3D, base_y: float, entrance_open: bool,
		materials: Dictionary) -> void:
	var radius := 4.75
	var wall_depth := 0.4
	var segment_angle := TAU / float(SEGMENTS)
	var segment_length := TAU * radius / float(SEGMENTS) * 1.08
	for index in SEGMENTS:
		var angle := PI * 0.5 + (float(index) + 0.5) * segment_angle
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var basis := Basis(tangent, Vector3.UP, -radial)
		var bottom := 0.0
		if entrance_open and absf(wrapf(angle - PI * 0.5, -PI, PI)) < DOOR_HALF_ANGLE:
			bottom = DOOR_HEIGHT
		GeometryKit.add_transformed_box(parent, Transform3D(basis,
			radial * radius + Vector3.UP * (base_y + (bottom + PERIOD) * 0.5)),
			Vector3(segment_length, PERIOD - bottom, wall_depth), materials["stair_plain"])


## Closes the ground-floor doorway once the player is above the real ground, so
## they cannot step out of a stairwell they are supposedly high up in.
func _build_loop_seal(parent: Node3D) -> void:
	_loop_seal = Node3D.new()
	_loop_seal.name = "LoopSeal"
	parent.add_child(_loop_seal)
	var ground_guard := GeometryKit.add_collision_box(_loop_seal, Vector3(0.0, 2.0, 4.75),
		Vector3(3.2, 4.0, 0.4))
	ground_guard.name = "GroundOpeningGuard"
	_set_loop_sealed(false)


func _set_loop_sealed(sealed: bool) -> void:
	_loop_seal.visible = sealed
	for child in _loop_seal.get_children():
		var collision := child.get_node("CollisionShape3D") as CollisionShape3D
		collision.set_deferred("disabled", not sealed)
