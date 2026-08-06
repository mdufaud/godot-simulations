class_name ExhibitStaircase extends RefCounted
## Exhibit 2 — a helical stairwell that never ends.
##
## Four identical modules are stacked; crossing the top of the stack teleports the
## player down one module, so climbing is unbounded while the geometry stays
## finite. Walking back down cancels the illusion: the ground floor returns to its
## real height and the loop seal reopens.
##
## The host drives it: [method track] every physics frame, [method set_active]
## when the exhibit is selected.

const PERIOD := 4.0
const RAISE := 0.45
const WRAP_HEIGHT := 8.37
const SEGMENTS := 48
const CENTER_RADIUS := 3.225
const WIDTH := 2.65
const OUTER_RADIUS := 4.55

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## How many times the player has crossed the wrap plane without going back down.
var ascent_count := 0

var _cell: Node3D
var _ground_level: Node3D
var _loop_seal: Node3D
var _fill_light: OmniLight3D
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
	_build_core(_cell, materials)
	for module_index in range(0, 4):
		_build_module(_cell, float(module_index) * PERIOD, module_index == 0, materials)
	_build_loop_seal(_cell)
	_fill_light = OmniLight3D.new()
	_fill_light.name = "StairFillLight"
	_fill_light.position = Vector3(0.0, 0.75, 0.0)
	_fill_light.light_color = Color(0.42, 0.82, 0.62)
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
	GeometryKit.add_box(parent, Vector3(0.0, 4.0, 7.45), Vector3(3.2, 0.25, 6.3),
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
	_add_helical_flight(parent, base_y, materials)
	_add_outer_wall(parent, base_y, entrance_open, materials)
	for light_index in 4:
		var angle := PI * 0.5 + float(light_index) * PI * 0.5
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		GeometryKit.add_ceiling_light(parent,
			radial * 4.35 + Vector3.UP * (base_y + float(light_index) + 3.55),
			Color(0.35, 0.88, 0.62))


## One full turn of steps. The visual slabs stay level while the collision slabs
## are tilted along the helix, so the player walks a ramp and sees stairs.
func _add_helical_flight(parent: Node3D, base_y: float, materials: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.name = "HelicalFlight"
	body.set_meta("infinite_stair_ramp", true)
	var segment_angle := TAU / float(SEGMENTS)
	var rise := PERIOD / float(SEGMENTS)
	var length := TAU * OUTER_RADIUS / float(SEGMENTS) * 1.08
	var slope := atan(PERIOD / (TAU * CENTER_RADIUS))
	var slab_thickness := 0.3
	for index in SEGMENTS:
		var angle := PI * 0.5 + (float(index) + 0.5) * segment_angle
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var flat_basis := Basis(radial, Vector3.UP, tangent)
		var ramp_basis := flat_basis * Basis(Vector3.RIGHT, -slope)
		var entry_raise := RAISE
		if is_zero_approx(base_y):
			entry_raise *= minf(float(index + 1) / 6.0, 1.0)
		var visual_position := radial * CENTER_RADIUS
		visual_position.y = base_y + float(index + 1) * rise + entry_raise \
			- slab_thickness * 0.5
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(WIDTH, slab_thickness, length)
		mesh_instance.mesh = mesh
		mesh_instance.transform = Transform3D(flat_basis, visual_position)
		mesh_instance.layers = Portal3D.WORLD_LAYER
		mesh_instance.material_override = materials["tile"]
		body.add_child(mesh_instance)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(WIDTH, 0.16, length)
		collision.shape = shape
		var collision_position := radial * CENTER_RADIUS
		collision_position.y = base_y + (float(index) + 0.5) * rise + entry_raise - 0.08
		collision.transform = Transform3D(ramp_basis, collision_position)
		body.add_child(collision)
	parent.add_child(body)


func _add_outer_wall(parent: Node3D, base_y: float, entrance_open: bool,
		materials: Dictionary) -> void:
	var radius := 4.75
	var wall_depth := 0.4
	var segment_angle := TAU / float(SEGMENTS)
	var segment_length := TAU * radius / float(SEGMENTS) * 1.08
	for index in SEGMENTS:
		var angle := PI * 0.5 + (float(index) + 0.5) * segment_angle
		var at_entrance := absf(wrapf(angle - PI * 0.5, -PI, PI)) < segment_angle * 2.7
		if entrance_open and at_entrance:
			continue
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var basis := Basis(tangent, Vector3.UP, -radial)
		GeometryKit.add_transformed_box(parent, Transform3D(basis,
			radial * radius + Vector3.UP * (base_y + PERIOD * 0.5)),
			Vector3(segment_length, PERIOD, wall_depth), materials["stair_plain"])


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
