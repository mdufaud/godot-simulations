class_name ExhibitGarden extends RefCounted
## Exhibit 3 — the inside of a 30 m sphere, walked as if it were a small planet
## turned outside in.
##
## Gravity points radially outwards, so the floor curves up in every direction and
## a straight walk closes on itself. Three great circles and a ring of columns give
## the eye something to measure the curvature against.

const SHADER := preload("res://shaders/non_euclidean/spherical_garden.gdshader")
const RADIUS := 30.0

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Radial field the host hands to the player so their up vector follows the shell.
var gravity_field: GravityField3D


func build(cells: Node3D, materials: Dictionary) -> void:
	var cell := Node3D.new()
	cell.name = "SphericalGarden"
	cell.transform = Transform3D(Basis.IDENTITY, Vector3(-300.0, 30.0, -350.0))
	cells.add_child(cell)

	var visual_sphere := SphereMesh.new()
	visual_sphere.radius = RADIUS
	visual_sphere.height = RADIUS * 2.0
	visual_sphere.radial_segments = 96
	visual_sphere.rings = 48
	visual_sphere.flip_faces = true
	var sphere_mesh := MeshInstance3D.new()
	sphere_mesh.mesh = visual_sphere
	sphere_mesh.layers = Portal3D.WORLD_LAYER
	var garden_material := ShaderMaterial.new()
	garden_material.shader = SHADER
	sphere_mesh.material_override = garden_material
	cell.add_child(sphere_mesh)

	var collision_sphere := SphereMesh.new()
	collision_sphere.radius = RADIUS
	collision_sphere.height = RADIUS * 2.0
	collision_sphere.radial_segments = 48
	collision_sphere.rings = 24
	collision_sphere.flip_faces = true
	var shell_shape := collision_sphere.create_trimesh_shape()
	if shell_shape is ConcavePolygonShape3D:
		(shell_shape as ConcavePolygonShape3D).backface_collision = true
	var shell := StaticBody3D.new()
	var shell_collision := CollisionShape3D.new()
	shell_collision.shape = shell_shape
	shell.add_child(shell_collision)
	cell.add_child(shell)

	gravity_field = GravityField3D.new()
	gravity_field.name = "RadialGravity"
	gravity_field.mode = GravityField3D.Mode.RADIAL_OUTWARD
	gravity_field.gravity_strength = 12.0
	var gravity_collision := CollisionShape3D.new()
	var gravity_shape := SphereShape3D.new()
	gravity_shape.radius = 29.85
	gravity_collision.shape = gravity_shape
	gravity_field.add_child(gravity_collision)
	cell.add_child(gravity_field)

	_add_great_circles(cell, 29.92, materials)
	_add_columns(cell, RADIUS, materials)
	var light := OmniLight3D.new()
	light.position = Vector3.ZERO
	light.light_color = Color(0.52, 0.75, 1.0)
	light.light_energy = 5.0
	light.omni_range = 45.0
	light.shadow_enabled = true
	cell.add_child(light)
	var sphere_probe := ReflectionProbe.new()
	sphere_probe.size = Vector3.ONE * 55.0
	sphere_probe.box_projection = true
	sphere_probe.enable_shadows = false
	sphere_probe.cull_mask = Portal3D.WORLD_LAYER
	cell.add_child(sphere_probe)

	var garden_position := Vector3(0.0, -23.28, 17.46)
	var garden_up := -garden_position.normalized()
	var garden_forward := Vector3.RIGHT
	var garden_right := garden_forward.cross(garden_up).normalized()
	var garden_basis := Basis(garden_right, garden_up, -garden_forward).orthonormalized()
	spawn_pose = cell.global_transform * Transform3D(garden_basis, garden_position)


## Three orthogonal great circles, one [MultiMesh] for the 288 segments.
func _add_great_circles(parent: Node3D, radius: float, materials: Dictionary) -> void:
	var segment_count := 96
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.035, TAU * radius / float(segment_count) * 1.08)
	mesh.material = materials["blue"]
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = segment_count * 3
	var index := 0
	for circle in 3:
		for segment in segment_count:
			var angle := TAU * float(segment) / float(segment_count)
			var direction := Vector3.ZERO
			var tangent := Vector3.ZERO
			if circle == 0:
				direction = Vector3(cos(angle), sin(angle), 0.0)
				tangent = Vector3(-sin(angle), cos(angle), 0.0)
			elif circle == 1:
				direction = Vector3(cos(angle), 0.0, sin(angle))
				tangent = Vector3(-sin(angle), 0.0, cos(angle))
			else:
				direction = Vector3(0.0, cos(angle), sin(angle))
				tangent = Vector3(0.0, -sin(angle), cos(angle))
			var local_up := -direction
			var local_right := local_up.cross(tangent).normalized()
			var basis := Basis(local_right, local_up, tangent).orthonormalized()
			multimesh.set_instance_transform(index, Transform3D(basis, direction * radius))
			index += 1
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.layers = Portal3D.WORLD_LAYER
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


func _add_columns(parent: Node3D, radius: float, materials: Dictionary) -> void:
	for index in 24:
		var angle := TAU * float(index) / 24.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var up := -direction
		var forward := Vector3.UP
		var right := up.cross(forward).normalized()
		var basis := Basis(right, up, forward).orthonormalized()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.16
		mesh.bottom_radius = 0.24
		mesh.height = 4.0
		mesh.material = materials["blue"]
		var column := MeshInstance3D.new()
		column.mesh = mesh
		column.transform = Transform3D(basis, direction * (radius - 2.0))
		column.layers = Portal3D.WORLD_LAYER
		parent.add_child(column)
