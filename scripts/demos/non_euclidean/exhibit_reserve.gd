class_name ExhibitReserve extends RefCounted
## Exhibit 1 — a 6 x 8 m shed whose doorway opens onto a 22 x 30 m warehouse.
##
## Builds two cells far apart in world space and links them with a portal pair, so
## the interior is genuinely bigger than the exterior rather than a trick of the
## camera. Both rooms carry printed dimensions, and a crate outside plus a ball
## inside can be pushed through the opening.

const OUTER_SIZE := Vector3(6.0, 4.5, 8.0)
const INNER_SIZE := Vector3(22.0, 7.0, 30.0)

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## The linked pair, for [code]PortalRenderManager.configure_portals[/code].
var portals: Array[Portal3D] = []

## The crate outside and the ball inside, in that order.
var props: Array[PortalRigidBody3D] = []

var _prop_poses: Array[Transform3D] = []


func build(cells: Node3D, materials: Dictionary) -> void:
	var courtyard := _new_cell(cells, "ReserveCourtyard",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -200.0)))
	_build_courtyard(courtyard, materials)
	var source := GeometryKit.add_portal(courtyard, "ReserveExpansion",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.7, 2.5)))

	var interior := _new_cell(cells, "ImpossibleReserve",
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -450.0)))
	GeometryKit.room_shell_with_front_opening(interior, INNER_SIZE, Vector2(2.6, 3.4),
		materials["concrete"], materials["tile"])
	GeometryKit.add_ceiling_grid(interior, Vector2(19.0, 26.0), 6.65,
		Color(0.45, 0.72, 1.0), 3, 4)
	_add_floor_grid(interior, Vector2(22.0, 30.0), materials)
	var destination := GeometryKit.add_portal(interior, "ReserveReturn",
		Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 1.7, 15.5)))
	GeometryKit.link(source, destination)
	portals.assign([source, destination])

	var area_ratio := INNER_SIZE.x * INNER_SIZE.z / (OUTER_SIZE.x * OUTER_SIZE.z)
	GeometryKit.add_label(interior,
		"INTERIOR 22 × 30 m · 660 m² · ×%.2f FOOTPRINT" % area_ratio,
		Vector3(0.0, 5.4, -14.96), 0.0, Color(0.5, 0.78, 1.0), 76)
	GeometryKit.add_label(interior, "22 m", Vector3(0.0, 0.08, -14.65), 0.0,
		Color(0.35, 0.78, 1.0), 54)
	GeometryKit.add_label(interior, "30 m", Vector3(-10.65, 0.08, 0.0), -PI * 0.5,
		Color(0.35, 0.78, 1.0), 54)
	for x in [-7.5, 7.5]:
		for z in [-9.0, 0.0, 9.0]:
			_add_storage_rack(interior, Vector3(x, 0.0, z), materials)
	GeometryKit.add_box(interior, Vector3(0.0, 0.45, -7.0), Vector3(7.0, 0.9, 3.2),
		materials["white"])
	var courtyard_crate := GeometryKit.add_box_prop(courtyard, Vector3(0.0, 0.5, 4.25),
		Vector3(0.9, 0.9, 0.9), Color(0.24, 0.55, 0.78), 2.0)
	var inside_ball := GeometryKit.add_sphere_prop(interior, Vector3(0.0, 0.58, 12.4), 0.52,
		Color(0.92, 0.42, 0.1), 1.5)
	props.assign([courtyard_crate, inside_ball])
	_prop_poses.assign([courtyard_crate.global_transform, inside_ball.global_transform])
	spawn_pose = courtyard.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.9, 8.2))


## Returns the crate and the ball to where they were built, awake so they settle.
func reset() -> void:
	for index in props.size():
		var body := props[index]
		body.global_transform = _prop_poses[index]
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false


func _new_cell(cells: Node3D, cell_name: String, cell_transform: Transform3D) -> Node3D:
	var cell := Node3D.new()
	cell.name = cell_name
	cell.transform = cell_transform
	cells.add_child(cell)
	return cell


func _build_courtyard(parent: Node3D, materials: Dictionary) -> void:
	GeometryKit.add_box(parent, Vector3(0.0, -0.25, 0.0), Vector3(30.0, 0.5, 26.0),
		materials["tile"])
	GeometryKit.add_box(parent, Vector3(-15.25, 4.0, 0.0), Vector3(0.5, 8.0, 26.0),
		materials["concrete"])
	GeometryKit.add_box(parent, Vector3(15.25, 4.0, 0.0), Vector3(0.5, 8.0, 26.0),
		materials["concrete"])
	GeometryKit.add_box(parent, Vector3(0.0, 4.0, -13.25), Vector3(30.0, 8.0, 0.5),
		materials["concrete"])
	GeometryKit.add_box(parent, Vector3(0.0, 4.0, 13.25), Vector3(30.0, 8.0, 0.5),
		materials["concrete"])
	_build_outer_shell(parent, Vector3(0.0, 0.0, -1.5), OUTER_SIZE, Vector2(2.6, 3.4),
		materials)
	GeometryKit.add_label(parent, "STORAGE A-01", Vector3(0.0, 4.05, 2.53), 0.0,
		Color(0.68, 0.82, 0.9), 68)
	GeometryKit.add_box(parent, Vector3(7.0, 1.55, 2.45), Vector3(4.6, 2.7, 0.14),
		materials["metal"], false)
	GeometryKit.add_label(parent,
		"EXTERIOR 6 × 8 m · 48 m²\nENTER TO VERIFY INTERIOR\nWALK AROUND THE BUILDING",
		Vector3(7.0, 1.55, 2.53), 0.0, Color(0.22, 0.72, 1.0), 38)
	GeometryKit.add_label(parent, "6 m", Vector3(0.0, 0.08, 3.25), 0.0,
		Color(0.28, 0.75, 1.0), 48)
	GeometryKit.add_label(parent, "8 m", Vector3(-3.55, 0.08, -1.5), -PI * 0.5,
		Color(0.28, 0.75, 1.0), 48)
	GeometryKit.add_box(parent, Vector3(0.0, 0.025, 3.0), Vector3(6.0, 0.05, 0.08),
		materials["measure"], false)
	GeometryKit.add_box(parent, Vector3(-3.3, 0.025, -1.5), Vector3(0.08, 0.05, 8.0),
		materials["measure"], false)
	GeometryKit.add_box(parent, Vector3(0.0, 8.25, 0.0), Vector3(30.0, 0.5, 26.0),
		materials["concrete"])
	GeometryKit.add_ceiling_grid(parent, Vector2(26.0, 22.0), 7.95,
		Color(0.58, 0.75, 0.92), 4, 3)
	GeometryKit.add_omni_light(parent, Vector3(0.0, 6.8, 5.0), Color(0.58, 0.75, 0.92),
		2.4, 18.0, true)


## The shed itself: a room shell whose walls sit inside [param size], so the
## printed 6 x 8 m footprint is what a tape measure would read outside.
func _build_outer_shell(parent: Node3D, center: Vector3, size: Vector3, opening: Vector2,
		materials: Dictionary) -> void:
	var wall := 0.5
	var inner_width := size.x - wall * 2.0
	var side_width := (inner_width - opening.x) * 0.5
	var front_z := center.z + size.z * 0.5 - wall * 0.5
	GeometryKit.add_box(parent, center + Vector3(-size.x * 0.5 + wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), materials["concrete"])
	GeometryKit.add_box(parent, center + Vector3(size.x * 0.5 - wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), materials["concrete"])
	GeometryKit.add_box(parent, center + Vector3(0.0, size.y * 0.5, -size.z * 0.5 + wall * 0.5),
		Vector3(inner_width, size.y, wall), materials["concrete"])
	GeometryKit.add_box(parent, center + Vector3(0.0, size.y - wall * 0.5, 0.0),
		Vector3(inner_width, wall, size.z - wall * 2.0), materials["concrete"])
	var side_offset := opening.x * 0.5 + side_width * 0.5
	GeometryKit.add_box(parent, Vector3(-side_offset, size.y * 0.5, front_z),
		Vector3(side_width, size.y, wall), materials["concrete"])
	GeometryKit.add_box(parent, Vector3(side_offset, size.y * 0.5, front_z),
		Vector3(side_width, size.y, wall), materials["concrete"])
	var top_height := size.y - opening.y
	GeometryKit.add_box(parent, Vector3(0.0, opening.y + top_height * 0.5, front_z),
		Vector3(opening.x, top_height, wall), materials["concrete"])


func _add_floor_grid(parent: Node3D, size: Vector2, materials: Dictionary) -> void:
	for x in range(-10, 11, 2):
		GeometryKit.add_box(parent, Vector3(float(x), 0.012, 0.0),
			Vector3(0.025, 0.02, size.y), materials["measure"], false)
	for z in range(-14, 15, 2):
		GeometryKit.add_box(parent, Vector3(0.0, 0.014, float(z)),
			Vector3(size.x, 0.022, 0.025), materials["measure"], false)


func _add_storage_rack(parent: Node3D, center: Vector3, materials: Dictionary) -> void:
	for x_offset in [-0.56, 0.56]:
		for z_offset in [-2.18, 2.18]:
			GeometryKit.add_box(parent, center + Vector3(x_offset, 2.4, z_offset),
				Vector3(0.12, 4.8, 0.12), materials["metal"])
	for height in [0.42, 1.62, 2.82, 4.02, 4.72]:
		GeometryKit.add_box(parent, center + Vector3(0.0, height, 0.0),
			Vector3(1.25, 0.1, 4.5), materials["white"])
	GeometryKit.add_box(parent, center + Vector3(0.0, 0.92, -1.25), Vector3(0.82, 0.9, 0.82),
		materials["blue"], false)
	GeometryKit.add_box(parent, center + Vector3(0.0, 2.12, 1.15), Vector3(0.88, 0.9, 0.92),
		materials["orange"], false)
