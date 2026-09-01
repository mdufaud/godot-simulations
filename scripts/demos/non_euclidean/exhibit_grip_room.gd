class_name ExhibitGripRoom extends RefCounted
## Exhibit — a grip lab where size is resolved by the take and the put-down.
##
## An asymmetric room with surfaces at every depth: floor at the player's feet,
## an intermediate shelf, and a far wall roughly fourteen metres in, pierced by
## an opening wide enough for the biggest committable ball. Three grip balls
## wait at those depths; grabbing one freezes it at a constant angular size,
## and where it meets a surface decides how big it becomes — pressed against the
## far wall it grows towards the bounds, dropped at the feet it stays tiny.
##
## The host drives the grab controller; this exhibit only owns the room, the
## balls and their reset.

const ROOM := Vector3(9.0, 6.0, 16.0)
## Twice the widest committable ball clears it, so a giant never blocks the door.
const FAR_OPENING := Vector2(4.4, 4.6)
const SHELF_TOP := 1.2

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## The three grip balls, near to far.
var props: Array[GripBall] = []

var _cell: Node3D
var _prop_poses: Array[Transform3D] = []


func build(cells: Node3D, materials: Dictionary) -> void:
	_cell = Node3D.new()
	_cell.name = "GripRoom"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(-250.0, 0.0, -700.0))
	cells.add_child(_cell)
	_build_shell(materials)
	_build_markers(materials)
	props.assign([
		_add_grip_ball(Vector3(-2.6, 0.35, 3.0), 0.35, Color(0.2, 0.55, 0.85), 1.2),
		_add_grip_ball(Vector3(0.0, SHELF_TOP + 0.5, -7.0), 0.5, Color(0.9, 0.42, 0.1), 2.0),
		_add_grip_ball(Vector3(0.0, 0.45, -11.5), 0.45, Color(0.2, 0.75, 0.4), 1.6),
	])
	for ball in props:
		_prop_poses.append(ball.global_transform)
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.9, 5.5))


## Returns every ball to its built pose and size, awake so they settle.
func reset() -> void:
	for index in props.size():
		var ball := props[index]
		ball.commit_scale(ball.base_radius())
		ball.global_transform = _prop_poses[index]
		ball.linear_velocity = Vector3.ZERO
		ball.angular_velocity = Vector3.ZERO
		ball.sleeping = false


func _build_shell(materials: Dictionary) -> void:
	var wall := 0.5
	GeometryKit.add_box(_cell, Vector3(0.0, -0.25, 0.0), Vector3(ROOM.x + wall, wall, ROOM.z + wall),
		materials["tile"])
	GeometryKit.add_box(_cell, Vector3(-ROOM.x * 0.5 - wall * 0.5, ROOM.y * 0.5, 0.0),
		Vector3(wall, ROOM.y, ROOM.z), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(ROOM.x * 0.5 + wall * 0.5, ROOM.y * 0.5, 0.0),
		Vector3(wall, ROOM.y, ROOM.z), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(0.0, ROOM.y * 0.5, ROOM.z * 0.5 + wall * 0.5),
		Vector3(ROOM.x, ROOM.y, wall), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(0.0, ROOM.y + wall * 0.5, 0.0),
		Vector3(ROOM.x + wall, wall, ROOM.z + wall), materials["concrete"])
	# Far wall with the oversized opening, and the alcove it leads into.
	GeometryKit.add_opening_wall(_cell, ROOM, FAR_OPENING, -ROOM.z * 0.5 - wall * 0.5,
		materials["concrete"])
	var alcove_z := -ROOM.z * 0.5 - 2.25
	GeometryKit.add_box(_cell, Vector3(0.0, -0.25, alcove_z), Vector3(FAR_OPENING.x + wall, wall, 5.0),
		materials["tile"])
	GeometryKit.add_box(_cell, Vector3(-FAR_OPENING.x * 0.5 - wall * 0.5, ROOM.y * 0.5, alcove_z),
		Vector3(wall, ROOM.y, 5.0), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(FAR_OPENING.x * 0.5 + wall * 0.5, ROOM.y * 0.5, alcove_z),
		Vector3(wall, ROOM.y, 5.0), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(0.0, ROOM.y + wall * 0.5, alcove_z),
		Vector3(FAR_OPENING.x + wall, wall, 5.0), materials["concrete"])
	GeometryKit.add_box(_cell, Vector3(0.0, ROOM.y * 0.5, -ROOM.z * 0.5 - 4.75),
		Vector3(FAR_OPENING.x + wall, ROOM.y, wall), materials["concrete"])
	# Intermediate shelf: a mid-depth surface to resolve sizes on.
	GeometryKit.add_box(_cell, Vector3(0.0, SHELF_TOP * 0.5, -7.0),
		Vector3(4.0, SHELF_TOP, 2.5), materials["white"])
	GeometryKit.add_ceiling_grid(_cell, Vector2(7.0, 13.0), ROOM.y - 0.05,
		Color(0.45, 0.72, 1.0), 2, 3)
	GeometryKit.add_omni_light(_cell, Vector3(0.0, ROOM.y - 0.8, 3.0),
		Color(0.58, 0.75, 0.92), 2.2, 16.0, false)
	GeometryKit.add_omni_light(_cell, Vector3(0.0, ROOM.y - 0.8, -10.0),
		Color(0.58, 0.75, 0.92), 2.2, 16.0, false)
	GeometryKit.add_label(_cell, "GRIP LAB",
		Vector3(0.0, 4.6, ROOM.z * 0.5 - 0.05), 0.0, Color(0.68, 0.82, 0.9), 96)
	GeometryKit.add_label(_cell,
		"GRAB CLOSE · PLACE FAR —\nSIZE IS RESOLVED BY THE SURFACE IT LANDS ON",
		Vector3(0.0, 3.4, ROOM.z * 0.5 - 0.05), 0.0, Color(0.22, 0.72, 1.0), 42)


func _build_markers(materials: Dictionary) -> void:
	# Distances from the spawn pose, in metres along the walk to the far wall.
	var spawn_z := 5.5
	var depths := {1.0: spawn_z - 1.0, 7.0: spawn_z - 7.0, 14.0: -ROOM.z * 0.5}
	for depth in depths:
		var z := float(depths[depth])
		GeometryKit.add_box(_cell, Vector3(0.0, 0.012, z), Vector3(6.0, 0.02, 0.08),
			materials["measure"], false)
		GeometryKit.add_label(_cell, "%.0f m" % float(depth),
			Vector3(0.0, 0.06, z + 0.55), 0.0, Color(0.35, 0.78, 1.0), 40)


func _add_grip_ball(local_position: Vector3, radius: float, color: Color,
		mass_value: float) -> GripBall:
	var body := GripBall.new()
	body.position = local_position
	body.mass = mass_value
	body.base_mass = mass_value
	body.albedo = color
	body.material_roughness = 0.3
	body.continuous_cd = true
	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	collision.shape = shape
	body.add_child(collision)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.6
	physics_material.bounce = 0.25
	body.physics_material_override = physics_material
	_cell.add_child(body)
	return body
