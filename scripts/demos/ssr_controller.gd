extends Node3D
## SSR Physics Demo — Refined reflections, multi-light, material categories,
## full SimMenu control panel for SSR / SSAO / SSIL / Glow / Lighting / Materials.

# ── Scene references ─────────────────────────────────────────────────────────
@onready var spawn_timer: Timer = $SpawnTimer
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var dir_light: DirectionalLight3D = $DirectionalLight3D
@onready var omni_red: OmniLight3D = $OmniLightRed
@onready var omni_blue: OmniLight3D = $OmniLightBlue
@onready var omni_warm: OmniLight3D = $OmniLightWarm
@onready var spot_accent: SpotLight3D = $SpotLightAccent

var _info_label: Label

# ── Constants ────────────────────────────────────────────────────────────────
const SPAWN_HEIGHT := 12.0
const SPAWN_RADIUS := 10.0
const KILL_Y := -12.0
const KEY_LIGHT_ORBIT_RADIUS := 10.0
const KEY_LIGHT_ORBIT_HEIGHT := 10.0
const KEY_LIGHT_ORBIT_SPEED := 0.45

var max_objects: int = 200
var spawned_objects: Array[RigidBody3D] = []
var _camera_side_walls: Array[Dictionary] = []
var _key_light_angle := 0.0

# Material override values: -1 means "use per-object random"
var roughness_override: float = -1.0
var metallic_override: float = -1.0

# ── Material palette ─────────────────────────────────────────────────────────
# 3 categories: mirror (metallic=1, rough≈0), brushed (metallic≈0.8, rough≈0.25),
#               dielectric / glossy (metallic ≈0.15, rough≈0.1)
enum MatCategory { MIRROR, BRUSHED, DIELECTRIC, EMISSIVE }

var color_palette := [
	Color(1.0, 0.84, 0.0),    # Gold
	Color(0.75, 0.75, 0.8),   # Silver
	Color(0.72, 0.45, 0.2),   # Bronze
	Color(0.85, 0.1, 0.1),    # Red
	Color(0.1, 0.5, 0.85),    # Blue
	Color(0.1, 0.8, 0.4),     # Green
	Color(0.6, 0.2, 0.8),     # Purple
	Color(0.9, 0.9, 0.95),    # Chrome
	Color(0.0, 0.8, 0.75),    # Teal
	Color(1.0, 0.55, 0.7),    # Rose
	Color(1.0, 0.75, 0.3),    # Amber
	Color(0.95, 0.95, 1.0),   # Pearl
]

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	max_objects = GameManager.get_setting("ssr_demo_max_objects", 200)
	spawn_timer.wait_time = GameManager.get_setting("ssr_demo_spawn_rate", 0.25)

	# Configure orbit camera
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -25.0
	orbit_cam.yaw = 0.0
	orbit_cam.auto_rotate = true
	orbit_cam.auto_rotate_speed = 0.15
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 30.0
	_update_key_light()

	spawn_timer.timeout.connect(_on_spawn_timer_timeout)

	_build_menu()

	for info: Array in [
		["WallBack/MeshInstance3D", Vector3(0, 0, -1)],
		["WallLeft/MeshInstance3D", Vector3(-1, 0, 0)],
		["WallRight/MeshInstance3D", Vector3(1, 0, 0)],
		["WallFront/MeshInstance3D", Vector3(0, 0, 1)],
	]:
		var mesh: MeshInstance3D = get_node_or_null(info[0]) as MeshInstance3D
		if mesh == null:
			continue
		_camera_side_walls.append({"mesh": mesh, "normal": info[1]})


func _build_menu() -> void:
	var env := world_env.environment
	menu.title = "🔮 Space screen reflection"
	_info_label = menu.add_label("Objects: 0")

	menu.add_section("SSR")
	menu.add_toggle("SSR Enabled", true, func(on: bool) -> void: env.ssr_enabled = on)
	menu.add_slider("Max Steps", 16.0, 256.0, 96.0, func(v: float) -> void: env.ssr_max_steps = int(v))
	menu.add_slider("Fade In", 0.0, 1.0, 0.05, func(v: float) -> void: env.ssr_fade_in = v)
	menu.add_slider("Fade Out", 0.0, 5.0, 3.0, func(v: float) -> void: env.ssr_fade_out = v)
	menu.add_slider("Depth Tolerance", 0.01, 1.0, 0.25, func(v: float) -> void: env.ssr_depth_tolerance = v)

	menu.add_section("SSAO")
	menu.add_toggle("SSAO Enabled", true, func(on: bool) -> void: env.ssao_enabled = on)
	menu.add_slider("Intensity", 0.0, 4.0, 1.5, func(v: float) -> void: env.ssao_intensity = v)
	menu.add_slider("Radius", 0.1, 5.0, 1.2, func(v: float) -> void: env.ssao_radius = v)

	menu.add_section("SSIL")
	menu.add_toggle("SSIL Enabled", true, func(on: bool) -> void: env.ssil_enabled = on)
	menu.add_slider("Intensity", 0.0, 3.0, 1.2, func(v: float) -> void: env.ssil_intensity = v)

	menu.add_section("Glow")
	menu.add_toggle("Glow Enabled", true, func(on: bool) -> void: env.glow_enabled = on)
	menu.add_slider("Intensity", 0.0, 2.0, 0.5, func(v: float) -> void: env.glow_intensity = v)
	menu.add_slider("Bloom", 0.0, 1.0, 0.05, func(v: float) -> void: env.glow_bloom = v)

	menu.add_section("Lights")
	menu.add_slider("Directional", 0.0, 5.0, 1.3, func(v: float) -> void: dir_light.light_energy = v)
	menu.add_slider("Omni Lights", 0.0, 8.0, 3.0, func(v: float) -> void:
		omni_red.light_energy = v
		omni_blue.light_energy = v
		omni_warm.light_energy = v * 0.83)  # keep warm slightly dimmer
	menu.add_slider("Spot Light", 0.0, 10.0, 6.0, func(v: float) -> void: spot_accent.light_energy = v)
	menu.add_toggle("Volumetric Fog", false, func(on: bool) -> void: env.volumetric_fog_enabled = on)

	menu.add_section("Material")
	menu.add_slider("Roughness Override", -1.0, 1.0, -1.0, _on_roughness_override_changed)
	menu.add_slider("Metallic Override", -1.0, 1.0, -1.0, _on_metallic_override_changed)

	menu.add_action("🧹", "Clear", _on_clear_pressed)


func _process(delta: float) -> void:
	_info_label.text = "Objects: %d / %d" % [spawned_objects.size(), max_objects]
	_update_key_light(delta)
	_update_wall_visibility()
	_cleanup_fallen_objects()


func _update_key_light(delta: float = 0.0) -> void:
	_key_light_angle = fmod(_key_light_angle + delta * KEY_LIGHT_ORBIT_SPEED, TAU)
	spot_accent.position = Vector3(
		cos(_key_light_angle) * KEY_LIGHT_ORBIT_RADIUS,
		KEY_LIGHT_ORBIT_HEIGHT,
		sin(_key_light_angle) * KEY_LIGHT_ORBIT_RADIUS
	)
	spot_accent.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)


func _update_wall_visibility() -> void:
	var cam := orbit_cam.get_camera()
	if cam == null:
		return
	var cam_pos := cam.global_position
	for w in _camera_side_walls:
		var mesh: MeshInstance3D = w["mesh"]
		var outside: float = (cam_pos - mesh.global_position).dot(w["normal"])
		mesh.visible = outside <= 0.0


func _cleanup_fallen_objects() -> void:
	var removed := false
	for i in range(spawned_objects.size() - 1, -1, -1):
		var obj := spawned_objects[i]
		if not is_instance_valid(obj):
			spawned_objects.remove_at(i)
			removed = true
		elif obj.global_position.y < KILL_Y:
			obj.queue_free()
			spawned_objects.remove_at(i)
			removed = true
	if removed and spawn_timer.is_stopped() and spawned_objects.size() < max_objects:
		spawn_timer.start()

# ── Spawning ─────────────────────────────────────────────────────────────────

func _on_spawn_timer_timeout() -> void:
	if spawned_objects.size() >= max_objects:
		spawn_timer.stop()
		return
	spawn_random_shape()


func spawn_random_shape() -> void:
	var rigid_body := RigidBody3D.new()

	# Spawn position – spread across the arena
	rigid_body.position = Vector3(
		randf_range(-SPAWN_RADIUS, SPAWN_RADIUS),
		SPAWN_HEIGHT + randf_range(0.0, 4.0),
		randf_range(-SPAWN_RADIUS, SPAWN_RADIUS)
	)
	rigid_body.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	rigid_body.angular_velocity = Vector3(
		randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)
	)

	var mesh_instance := MeshInstance3D.new()
	var collision_shape := CollisionShape3D.new()

	# 5 shape types
	var shape_type := randi() % 5
	match shape_type:
		0: # Sphere
			var m := SphereMesh.new()
			m.radius = randf_range(0.3, 0.7)
			m.height = m.radius * 2.0
			mesh_instance.mesh = m
			var s := SphereShape3D.new()
			s.radius = m.radius
			collision_shape.shape = s

		1: # Box
			var m := BoxMesh.new()
			var sz := randf_range(0.4, 1.0)
			m.size = Vector3(sz, sz, sz)
			mesh_instance.mesh = m
			var s := BoxShape3D.new()
			s.size = m.size
			collision_shape.shape = s

		2: # Cylinder
			var m := CylinderMesh.new()
			m.top_radius = randf_range(0.2, 0.5)
			m.bottom_radius = m.top_radius
			m.height = randf_range(0.5, 1.5)
			mesh_instance.mesh = m
			var s := CylinderShape3D.new()
			s.radius = m.top_radius
			s.height = m.height
			collision_shape.shape = s

		3: # Capsule
			var m := CapsuleMesh.new()
			m.radius = randf_range(0.2, 0.45)
			m.height = m.radius * 2.0 + randf_range(0.3, 1.0)
			mesh_instance.mesh = m
			var s := CapsuleShape3D.new()
			s.radius = m.radius
			s.height = m.height
			collision_shape.shape = s

		4: # Torus (visual only — approximate with sphere collision)
			var m := TorusMesh.new()
			m.inner_radius = randf_range(0.15, 0.3)
			m.outer_radius = m.inner_radius + randf_range(0.15, 0.35)
			mesh_instance.mesh = m
			var s := SphereShape3D.new()
			s.radius = m.outer_radius
			collision_shape.shape = s

	# Material — pick category then apply PBR values
	var mat := _create_surface_material()
	mesh_instance.material_override = mat

	rigid_body.add_child(mesh_instance)
	rigid_body.add_child(collision_shape)
	rigid_body.mass = randf_range(0.5, 2.5)
	rigid_body.physics_material_override = _create_physics_material()

	add_child(rigid_body)
	spawned_objects.append(rigid_body)


func _create_surface_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var base_color: Color = color_palette[randi() % color_palette.size()]

	# Choose category with weighted probability
	var roll := randf()
	var cat: MatCategory
	if roll < 0.35:
		cat = MatCategory.MIRROR
	elif roll < 0.60:
		cat = MatCategory.BRUSHED
	elif roll < 0.85:
		cat = MatCategory.DIELECTRIC
	else:
		cat = MatCategory.EMISSIVE

	match cat:
		MatCategory.MIRROR:
			mat.metallic = 1.0
			mat.roughness = randf_range(0.0, 0.08)
			mat.metallic_specular = 0.7
		MatCategory.BRUSHED:
			mat.metallic = randf_range(0.7, 0.9)
			mat.roughness = randf_range(0.18, 0.35)
			mat.metallic_specular = 0.5
		MatCategory.DIELECTRIC:
			mat.metallic = randf_range(0.0, 0.2)
			mat.roughness = randf_range(0.05, 0.15)
			mat.metallic_specular = 0.5
		MatCategory.EMISSIVE:
			mat.metallic = randf_range(0.5, 1.0)
			mat.roughness = randf_range(0.0, 0.1)
			mat.emission_enabled = true
			mat.emission = base_color
			mat.emission_energy_multiplier = randf_range(1.2, 2.5)

	# Apply overrides if user has set them
	if roughness_override >= 0.0:
		mat.roughness = roughness_override
	if metallic_override >= 0.0:
		mat.metallic = metallic_override

	mat.albedo_color = base_color
	return mat


func _create_physics_material() -> PhysicsMaterial:
	var pm := PhysicsMaterial.new()
	pm.bounce = randf_range(0.3, 0.85)
	pm.friction = randf_range(0.15, 0.55)
	return pm

# ── Helpers ──────────────────────────────────────────────────────────────────

func _apply_material_override_to_existing() -> void:
	for obj in spawned_objects:
		if not is_instance_valid(obj):
			continue
		for child in obj.get_children():
			if child is MeshInstance3D and child.material_override is StandardMaterial3D:
				var m: StandardMaterial3D = child.material_override
				if roughness_override >= 0.0:
					m.roughness = roughness_override
				if metallic_override >= 0.0:
					m.metallic = metallic_override

# ── UI Callbacks — Material overrides ────────────────────────────────────────

func _on_roughness_override_changed(value: float) -> void:
	roughness_override = value
	if value >= 0.0:
		_apply_material_override_to_existing()


func _on_metallic_override_changed(value: float) -> void:
	metallic_override = value
	if value >= 0.0:
		_apply_material_override_to_existing()

# ── Clear ────────────────────────────────────────────────────────────────────

func _on_clear_pressed() -> void:
	for obj in spawned_objects:
		if is_instance_valid(obj):
			obj.queue_free()
	spawned_objects.clear()
	spawn_timer.start()
