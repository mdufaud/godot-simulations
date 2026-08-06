class_name RigidBodySpawner extends RefCounted

enum MatCategory { MIRROR, BRUSHED, DIELECTRIC, EMISSIVE }

var roughness_override := -1.0
var metallic_override := -1.0
var color_palette: Array[Color] = [
	Color(1.0, 0.84, 0.0), Color(0.75, 0.75, 0.8), Color(0.72, 0.45, 0.2),
	Color(0.85, 0.1, 0.1), Color(0.1, 0.5, 0.85), Color(0.1, 0.8, 0.4),
	Color(0.6, 0.2, 0.8), Color(0.9, 0.9, 0.95), Color(0.0, 0.8, 0.75),
	Color(1.0, 0.55, 0.7), Color(1.0, 0.75, 0.3), Color(0.95, 0.95, 1.0),
]

var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


func spawn(parent: Node3D, position: Vector3, rotation: Vector3,
		angular_velocity: Vector3, shape_type := -1) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.position = position
	body.rotation = rotation
	body.angular_velocity = angular_velocity
	var mesh_instance := MeshInstance3D.new()
	var collision_shape := CollisionShape3D.new()
	_configure_shape(mesh_instance, collision_shape, shape_type)
	mesh_instance.material_override = _create_surface_material()
	body.add_child(mesh_instance)
	body.add_child(collision_shape)
	body.mass = _rng.randf_range(0.5, 2.5)
	body.physics_material_override = _create_physics_material()
	parent.add_child(body)
	return body


func _configure_shape(mesh_instance: MeshInstance3D, collision: CollisionShape3D,
		requested_type: int) -> void:
	var shape_type := _rng.randi_range(0, 4) if requested_type < 0 else requested_type
	match shape_type:
		0:
			var mesh := SphereMesh.new()
			mesh.radius = _rng.randf_range(0.3, 0.7)
			mesh.height = mesh.radius * 2.0
			mesh_instance.mesh = mesh
			var shape := SphereShape3D.new()
			shape.radius = mesh.radius
			collision.shape = shape
		1:
			var mesh := BoxMesh.new()
			var size := _rng.randf_range(0.4, 1.0)
			mesh.size = Vector3.ONE * size
			mesh_instance.mesh = mesh
			var shape := BoxShape3D.new()
			shape.size = mesh.size
			collision.shape = shape
		2:
			var mesh := CylinderMesh.new()
			mesh.top_radius = _rng.randf_range(0.2, 0.5)
			mesh.bottom_radius = mesh.top_radius
			mesh.height = _rng.randf_range(0.5, 1.5)
			mesh_instance.mesh = mesh
			var shape := CylinderShape3D.new()
			shape.radius = mesh.top_radius
			shape.height = mesh.height
			collision.shape = shape
		3:
			var mesh := CapsuleMesh.new()
			mesh.radius = _rng.randf_range(0.2, 0.45)
			mesh.height = mesh.radius * 2.0 + _rng.randf_range(0.3, 1.0)
			mesh_instance.mesh = mesh
			var shape := CapsuleShape3D.new()
			shape.radius = mesh.radius
			shape.height = mesh.height
			collision.shape = shape
		_:
			var mesh := TorusMesh.new()
			mesh.inner_radius = _rng.randf_range(0.15, 0.3)
			mesh.outer_radius = mesh.inner_radius + _rng.randf_range(0.15, 0.35)
			mesh_instance.mesh = mesh
			var shape := SphereShape3D.new()
			shape.radius = mesh.outer_radius
			collision.shape = shape


func _create_surface_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	var base_color := color_palette[_rng.randi_range(0, color_palette.size() - 1)]
	var roll := _rng.randf()
	var category := MatCategory.MIRROR
	if roll >= 0.35 and roll < 0.6:
		category = MatCategory.BRUSHED
	elif roll >= 0.6 and roll < 0.85:
		category = MatCategory.DIELECTRIC
	elif roll >= 0.85:
		category = MatCategory.EMISSIVE
	match category:
		MatCategory.MIRROR:
			material.metallic = 1.0
			material.roughness = _rng.randf_range(0.0, 0.08)
			material.metallic_specular = 0.7
		MatCategory.BRUSHED:
			material.metallic = _rng.randf_range(0.7, 0.9)
			material.roughness = _rng.randf_range(0.18, 0.35)
			material.metallic_specular = 0.5
		MatCategory.DIELECTRIC:
			material.metallic = _rng.randf_range(0.0, 0.2)
			material.roughness = _rng.randf_range(0.05, 0.15)
			material.metallic_specular = 0.5
		MatCategory.EMISSIVE:
			material.metallic = _rng.randf_range(0.5, 1.0)
			material.roughness = _rng.randf_range(0.0, 0.1)
			material.emission_enabled = true
			material.emission = base_color
			material.emission_energy_multiplier = _rng.randf_range(1.2, 2.5)
	if roughness_override >= 0.0:
		material.roughness = roughness_override
	if metallic_override >= 0.0:
		material.metallic = metallic_override
	material.albedo_color = base_color
	return material


func _create_physics_material() -> PhysicsMaterial:
	var material := PhysicsMaterial.new()
	material.bounce = _rng.randf_range(0.3, 0.85)
	material.friction = _rng.randf_range(0.15, 0.55)
	return material
