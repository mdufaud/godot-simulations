extends Node3D
## Spawner de formes physiques avec matériaux réfléchissants pour la démo SSR

@onready var spawn_timer: Timer = $SpawnTimer
@onready var info_label: Label = get_node("../UI/Control/VBoxContainer/InfoLabel")
@onready var fps_label: Label = get_node("../UI/Control/VBoxContainer/FPSLabel")
@onready var ssr_toggle: CheckButton = get_node("../UI/Control/VBoxContainer/SSRToggle")
@onready var clear_button: Button = get_node("../UI/Control/VBoxContainer/ClearButton")
@onready var environment: WorldEnvironment = get_node("../WorldEnvironment")

const MAX_OBJECTS := 200
const SPAWN_HEIGHT := 12.0
const SPAWN_RADIUS := 8.0

var spawned_objects: Array[RigidBody3D] = []

# Couleurs métalliques pour les réflexions SSR
var metallic_colors := [
	Color(1.0, 0.84, 0.0),    # Or
	Color(0.75, 0.75, 0.8),   # Argent
	Color(0.72, 0.45, 0.2),   # Bronze
	Color(0.85, 0.1, 0.1),    # Rouge métallique
	Color(0.1, 0.5, 0.85),    # Bleu métallique
	Color(0.1, 0.8, 0.4),     # Vert métallique
	Color(0.6, 0.2, 0.8),     # Violet métallique
	Color(0.9, 0.9, 0.95),    # Chrome
]


func _ready() -> void:
	spawn_timer.timeout.connect(_on_spawn_timer_timeout)
	ssr_toggle.toggled.connect(_on_ssr_toggled)
	clear_button.pressed.connect(_on_clear_pressed)


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	info_label.text = "Objets: %d / %d" % [spawned_objects.size(), MAX_OBJECTS]


func _on_spawn_timer_timeout() -> void:
	if spawned_objects.size() >= MAX_OBJECTS:
		spawn_timer.stop()
		return
	
	spawn_random_shape()


func spawn_random_shape() -> void:
	var rigid_body := RigidBody3D.new()
	
	# Position aléatoire
	var spawn_pos := Vector3(
		randf_range(-SPAWN_RADIUS, SPAWN_RADIUS),
		SPAWN_HEIGHT + randf_range(0, 3),
		randf_range(-SPAWN_RADIUS, SPAWN_RADIUS)
	)
	rigid_body.position = spawn_pos
	
	# Rotation aléatoire initiale
	rigid_body.rotation = Vector3(
		randf() * TAU,
		randf() * TAU,
		randf() * TAU
	)
	
	# Vélocité angulaire aléatoire
	rigid_body.angular_velocity = Vector3(
		randf_range(-3, 3),
		randf_range(-3, 3),
		randf_range(-3, 3)
	)
	
	# Créer mesh et collision selon la forme
	var mesh_instance := MeshInstance3D.new()
	var collision_shape := CollisionShape3D.new()
	
	var shape_type := randi() % 3
	match shape_type:
		0: # Sphère
			var sphere_mesh := SphereMesh.new()
			sphere_mesh.radius = randf_range(0.3, 0.7)
			sphere_mesh.height = sphere_mesh.radius * 2
			mesh_instance.mesh = sphere_mesh
			
			var sphere_shape := SphereShape3D.new()
			sphere_shape.radius = sphere_mesh.radius
			collision_shape.shape = sphere_shape
			
		1: # Cube
			var box_mesh := BoxMesh.new()
			var size := randf_range(0.5, 1.0)
			box_mesh.size = Vector3(size, size, size)
			mesh_instance.mesh = box_mesh
			
			var box_shape := BoxShape3D.new()
			box_shape.size = box_mesh.size
			collision_shape.shape = box_shape
			
		2: # Cylindre
			var cylinder_mesh := CylinderMesh.new()
			cylinder_mesh.top_radius = randf_range(0.2, 0.5)
			cylinder_mesh.bottom_radius = cylinder_mesh.top_radius
			cylinder_mesh.height = randf_range(0.5, 1.5)
			mesh_instance.mesh = cylinder_mesh
			
			var cylinder_shape := CylinderShape3D.new()
			cylinder_shape.radius = cylinder_mesh.top_radius
			cylinder_shape.height = cylinder_mesh.height
			collision_shape.shape = cylinder_shape
	
	# Matériau réfléchissant pour SSR
	var material := StandardMaterial3D.new()
	material.albedo_color = metallic_colors[randi() % metallic_colors.size()]
	material.metallic = randf_range(0.7, 1.0)
	material.roughness = randf_range(0.0, 0.3)
	mesh_instance.material_override = material
	
	# Assembler et ajouter à la scène
	rigid_body.add_child(mesh_instance)
	rigid_body.add_child(collision_shape)
	
	# Configuration physique Jolt
	rigid_body.mass = randf_range(0.5, 2.0)
	rigid_body.physics_material_override = _create_physics_material()
	
	add_child(rigid_body)
	spawned_objects.append(rigid_body)


func _create_physics_material() -> PhysicsMaterial:
	var mat := PhysicsMaterial.new()
	mat.bounce = randf_range(0.3, 0.8)
	mat.friction = randf_range(0.2, 0.6)
	return mat


func _on_ssr_toggled(enabled: bool) -> void:
	environment.environment.ssr_enabled = enabled


func _on_clear_pressed() -> void:
	for obj in spawned_objects:
		if is_instance_valid(obj):
			obj.queue_free()
	spawned_objects.clear()
	spawn_timer.start()
