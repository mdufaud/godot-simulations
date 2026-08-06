class_name GeometryKit extends RefCounted
## Procedural building blocks for portal spaces: boxes with collision, room
## shells, labels, lights and props, all on [constant Portal3D.WORLD_LAYER] so a
## portal camera renders them.
##
## Every function is static and takes its parent and its material, so the kit owns
## no scene state and no palette. Nothing here knows what an exhibit is.
##
##     var wall := GeometryKit.make_material(Color(0.24, 0.27, 0.3), 0.0, 0.82)
##     GeometryKit.room_shell_with_front_opening(room, Vector3(22, 7, 30),
##         Vector2(2.6, 3.4), wall, wall)
##     GeometryKit.link(GeometryKit.add_portal(room, "In", Transform3D()),
##         GeometryKit.add_portal(other, "Out", Transform3D()))


## Boxes


## Returns a [StaticBody3D] when [param collision], a bare [MeshInstance3D]
## otherwise — decoration skips both the physics server and shadow casting.
static func add_box(parent: Node3D, local_position: Vector3, size: Vector3,
		material: Material, collision := true, rotation := Vector3.ZERO) -> Node3D:
	if collision:
		var body := StaticBody3D.new()
		body.position = local_position
		body.rotation = rotation
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh_instance.mesh = mesh
		mesh_instance.layers = Portal3D.WORLD_LAYER
		mesh_instance.material_override = material
		body.add_child(mesh_instance)
		var collision_shape := CollisionShape3D.new()
		collision_shape.name = "CollisionShape3D"
		var shape := BoxShape3D.new()
		shape.size = size
		collision_shape.shape = shape
		body.add_child(collision_shape)
		parent.add_child(body)
		return body
	var visual := MeshInstance3D.new()
	var visual_mesh := BoxMesh.new()
	visual_mesh.size = size
	visual.mesh = visual_mesh
	visual.position = local_position
	visual.rotation = rotation
	visual.layers = Portal3D.WORLD_LAYER
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(visual)
	return visual


static func add_transformed_box(parent: Node3D, box_transform: Transform3D, size: Vector3,
		material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = box_transform
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body


## Invisible blocker: collision without a mesh.
static func add_collision_box(parent: Node3D, local_position: Vector3,
		size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = local_position
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	return body


## Rooms


## Closed box room whose +Z face carries an [param opening] hole. The floor is
## tagged [code]portal_threshold[/code] so a portal placed in the opening can find
## the surface the player steps across.
static func room_shell_with_front_opening(parent: Node3D, size: Vector3, opening: Vector2,
		wall_material: Material, floor_material: Material) -> void:
	var wall := 0.5
	var floor := add_box(parent, Vector3(0.0, -wall * 0.5, wall * 0.5),
		Vector3(size.x, wall, size.z + wall), floor_material)
	floor.name = "PortalThreshold"
	floor.set_meta("portal_threshold", true)
	add_box(parent, Vector3(0.0, size.y + wall * 0.5, 0.0), Vector3(size.x, wall, size.z), wall_material)
	add_box(parent, Vector3(-size.x * 0.5 - wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), wall_material)
	add_box(parent, Vector3(size.x * 0.5 + wall * 0.5, size.y * 0.5, 0.0),
		Vector3(wall, size.y, size.z), wall_material)
	add_box(parent, Vector3(0.0, size.y * 0.5, -size.z * 0.5 - wall * 0.5),
		Vector3(size.x, size.y, wall), wall_material)
	add_opening_wall(parent, size, opening, size.z * 0.5 + wall * 0.5, wall_material)
	var probe := ReflectionProbe.new()
	probe.position = Vector3(0.0, size.y * 0.5, 0.0)
	probe.size = size - Vector3.ONE
	probe.box_projection = true
	probe.enable_shadows = false
	probe.cull_mask = Portal3D.WORLD_LAYER
	parent.add_child(probe)


## Wall at [param wall_z] made of two jambs and a lintel around [param opening].
static func add_opening_wall(parent: Node3D, size: Vector3, opening: Vector2, wall_z: float,
		wall_material: Material) -> void:
	var wall := 0.5
	var side_width := (size.x - opening.x) * 0.5
	var side_offset := opening.x * 0.5 + side_width * 0.5
	add_box(parent, Vector3(-side_offset, size.y * 0.5, wall_z),
		Vector3(side_width, size.y, wall), wall_material)
	add_box(parent, Vector3(side_offset, size.y * 0.5, wall_z),
		Vector3(side_width, size.y, wall), wall_material)
	var top_height := size.y - opening.y
	add_box(parent, Vector3(0.0, opening.y + top_height * 0.5, wall_z),
		Vector3(opening.x, top_height, wall), wall_material)


## Lights


static func add_ceiling_grid(parent: Node3D, area: Vector2, height: float, color: Color,
		columns: int, rows: int) -> void:
	for x_index in columns:
		for z_index in rows:
			var x := 0.0 if columns == 1 else lerpf(-area.x * 0.42, area.x * 0.42,
				float(x_index) / float(columns - 1))
			var z := 0.0 if rows == 1 else lerpf(-area.y * 0.42, area.y * 0.42,
				float(z_index) / float(rows - 1))
			var emissive := make_material(Color(0.12, 0.14, 0.16), 0.2, 0.25, color, 3.5)
			add_box(parent, Vector3(x, height, z), Vector3(1.8, 0.08, 0.24), emissive, false)
			if (x_index + z_index) % 3 == 0:
				add_omni_light(parent, Vector3(x, height - 0.25, z), color, 1.7, 10.0, false)


## Emissive strip with no light attached — cheap fill for a lit corridor.
static func add_ceiling_light(parent: Node3D, local_position: Vector3, color: Color) -> void:
	var emissive := make_material(Color(0.12, 0.14, 0.16), 0.2, 0.25, color, 3.5)
	add_box(parent, local_position, Vector3(2.4, 0.08, 0.3), emissive, false)


static func add_omni_light(parent: Node3D, local_position: Vector3, color: Color, energy: float,
		range_value: float, shadows: bool) -> OmniLight3D:
	var light := OmniLight3D.new()
	light.position = local_position
	light.light_color = color
	light.light_energy = energy
	light.omni_range = range_value
	light.shadow_enabled = shadows
	parent.add_child(light)
	return light


## Portals and labels


static func add_portal(parent: Node3D, portal_name: String,
		portal_transform: Transform3D) -> Portal3D:
	var portal := Portal3D.new()
	portal.name = portal_name
	portal.transform = portal_transform
	parent.add_child(portal)
	return portal


static func link(a: Portal3D, b: Portal3D) -> void:
	a.linked_portal = b
	b.linked_portal = a


static func add_label(parent: Node3D, text: String, local_position: Vector3, yaw: float,
		color: Color, font_size: int) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = local_position
	label.rotation.y = yaw
	label.font_size = font_size
	label.pixel_size = 0.006
	label.modulate = color
	label.outline_size = 8
	parent.add_child(label)
	return label


## Props


static func add_box_prop(parent: Node3D, local_position: Vector3, size: Vector3,
		color: Color, mass_value: float) -> PortalRigidBody3D:
	var body := PortalRigidBody3D.new()
	body.position = local_position
	body.mass = mass_value
	body.albedo = color
	body.material_roughness = 0.52
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	mesh_instance.layers = Portal3D.WORLD_LAYER
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.72
	physics_material.bounce = 0.08
	body.physics_material_override = physics_material
	parent.add_child(body)
	return body


static func add_sphere_prop(parent: Node3D, local_position: Vector3, radius: float,
		color: Color, mass_value: float) -> PortalRigidBody3D:
	var body := PortalRigidBody3D.new()
	body.position = local_position
	body.mass = mass_value
	body.albedo = color
	body.material_roughness = 0.22
	body.material_metallic = 0.35
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
	physics_material.friction = 0.48
	physics_material.bounce = 0.32
	body.physics_material_override = physics_material
	parent.add_child(body)
	return body


## Materials


static func make_material(color: Color, metallic: float, roughness: float,
		emission := Color(0.0, 0.0, 0.0), emission_energy := 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material


## Loads the Poly Haven set under [code]resources/materials/<asset>/[/code], each
## map optional: a missing download leaves [param fallback] as flat albedo.
static func make_downloaded_material(asset: String, fallback: Color, metallic: float,
		roughness: float, uv_scale: float) -> StandardMaterial3D:
	var material := make_material(fallback, metallic, roughness)
	var directory := "res://resources/materials/%s/" % asset
	var diffuse_path := "%s%s_diff_2k.jpg" % [directory, asset]
	var normal_path := "%s%s_nor_gl_2k.jpg" % [directory, asset]
	var roughness_path := "%s%s_rough_2k.jpg" % [directory, asset]
	if ResourceLoader.exists(diffuse_path):
		material.albedo_color = Color.WHITE
		material.albedo_texture = load(diffuse_path) as Texture2D
	if ResourceLoader.exists(normal_path):
		material.normal_enabled = true
		material.normal_texture = load(normal_path) as Texture2D
	if ResourceLoader.exists(roughness_path):
		material.roughness_texture = load(roughness_path) as Texture2D
	material.uv1_scale = Vector3.ONE * uv_scale
	return material
