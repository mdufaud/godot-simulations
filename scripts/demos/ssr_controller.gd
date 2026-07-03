extends Node3D
## SSR Physics Demo — Refined reflections, multi-light, material categories,
## full slider control panel for SSR / SSAO / SSIL / Glow / Lighting / Materials.

# ── Scene references ─────────────────────────────────────────────────────────
@onready var spawn_timer: Timer = $SpawnTimer
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var info_label: Label = $UI/Control/InfoPanel/ScrollContainer/VBoxContainer/InfoLabel
@onready var fps_label: Label = $UI/Control/InfoPanel/ScrollContainer/VBoxContainer/FPSLabel
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var dir_light: DirectionalLight3D = $DirectionalLight3D
@onready var omni_red: OmniLight3D = $OmniLightRed
@onready var omni_blue: OmniLight3D = $OmniLightBlue
@onready var omni_warm: OmniLight3D = $OmniLightWarm
@onready var spot_accent: SpotLight3D = $SpotLightAccent

# ── UI label references (updated by sliders) ────────────────────────────────
const _V := "UI/Control/InfoPanel/ScrollContainer/VBoxContainer/"
@onready var ssr_max_steps_label: Label = get_node(_V + "SSRMaxStepsLabel")
@onready var ssr_fade_in_label: Label = get_node(_V + "SSRFadeInLabel")
@onready var ssr_fade_out_label: Label = get_node(_V + "SSRFadeOutLabel")
@onready var ssr_depth_tol_label: Label = get_node(_V + "SSRDepthToleranceLabel")
@onready var ssao_intensity_label: Label = get_node(_V + "SSAOIntensityLabel")
@onready var ssao_radius_label: Label = get_node(_V + "SSAORadiusLabel")
@onready var ssil_intensity_label: Label = get_node(_V + "SSILIntensityLabel")
@onready var glow_intensity_label: Label = get_node(_V + "GlowIntensityLabel")
@onready var glow_bloom_label: Label = get_node(_V + "GlowBloomLabel")
@onready var dir_light_energy_label: Label = get_node(_V + "DirLightEnergyLabel")
@onready var omni_light_energy_label: Label = get_node(_V + "OmniLightEnergyLabel")
@onready var spot_light_energy_label: Label = get_node(_V + "SpotLightEnergyLabel")
@onready var roughness_label: Label = get_node(_V + "RoughnessLabel")
@onready var metallic_label: Label = get_node(_V + "MetallicLabel")

# ── Constants ────────────────────────────────────────────────────────────────
const SPAWN_HEIGHT := 12.0
const SPAWN_RADIUS := 10.0
const KILL_Y := -12.0
const WALL_FADE_ALPHA := 0.12
const WALL_FADE_DISTANCE := 2.0

var max_objects: int = 200
var spawned_objects: Array[RigidBody3D] = []
var _wall_fades: Array[Dictionary] = []

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

	var env := world_env.environment
	env.ssr_enabled = GameManager.get_setting("ssr_enabled", true)
	env.ssr_max_steps = GameManager.get_setting("ssr_max_steps", 96)

	# Configure orbit camera
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -25.0
	orbit_cam.yaw = 0.0
	orbit_cam.auto_rotate = true
	orbit_cam.auto_rotate_speed = 0.15
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 30.0

	spawn_timer.timeout.connect(_on_spawn_timer_timeout)

	# Disable scroll on all sliders so scrolling scrolls the panel, not the values
	for slider in $UI.find_children("*", "HSlider"):
		slider.scrollable = false

	# Give each wall its own material so it can fade independently when the
	# camera moves outside the room (walls no longer block the view)
	for info: Array in [
		[$WallBack/MeshInstance3D, Vector3(0, 0, -1)],
		[$WallLeft/MeshInstance3D, Vector3(-1, 0, 0)],
		[$WallRight/MeshInstance3D, Vector3(1, 0, 0)],
	]:
		var mesh: MeshInstance3D = info[0]
		var mat: StandardMaterial3D = mesh.get_surface_override_material(0).duplicate()
		mesh.set_surface_override_material(0, mat)
		_wall_fades.append({"mesh": mesh, "normal": info[1], "mat": mat})


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	info_label.text = "Objects: %d / %d" % [spawned_objects.size(), max_objects]
	_update_wall_fade()
	_cleanup_fallen_objects()


func _update_wall_fade() -> void:
	var cam := orbit_cam.get_camera()
	if cam == null:
		return
	var cam_pos := cam.global_position
	for w in _wall_fades:
		var mesh: MeshInstance3D = w["mesh"]
		var outside: float = (cam_pos - mesh.global_position).dot(w["normal"])
		var alpha := clampf(1.0 - outside / WALL_FADE_DISTANCE, WALL_FADE_ALPHA, 1.0)
		var mat: StandardMaterial3D = w["mat"]
		# Keep the wall opaque (so SSR reflects it) unless it actually needs to fade
		if alpha >= 0.99:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = alpha


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

# ── UI Callbacks — SSR ───────────────────────────────────────────────────────

func _on_ssr_toggled(enabled: bool) -> void:
	world_env.environment.ssr_enabled = enabled

func _on_ssr_max_steps_changed(value: float) -> void:
	world_env.environment.ssr_max_steps = int(value)
	ssr_max_steps_label.text = "Max Steps: %d" % int(value)

func _on_ssr_fade_in_changed(value: float) -> void:
	world_env.environment.ssr_fade_in = value
	ssr_fade_in_label.text = "Fade In: %.2f" % value

func _on_ssr_fade_out_changed(value: float) -> void:
	world_env.environment.ssr_fade_out = value
	ssr_fade_out_label.text = "Fade Out: %.1f" % value

func _on_ssr_depth_tolerance_changed(value: float) -> void:
	world_env.environment.ssr_depth_tolerance = value
	ssr_depth_tol_label.text = "Depth Tolerance: %.2f" % value

# ── UI Callbacks — SSAO ──────────────────────────────────────────────────────

func _on_ssao_toggled(enabled: bool) -> void:
	world_env.environment.ssao_enabled = enabled

func _on_ssao_intensity_changed(value: float) -> void:
	world_env.environment.ssao_intensity = value
	ssao_intensity_label.text = "Intensity: %.1f" % value

func _on_ssao_radius_changed(value: float) -> void:
	world_env.environment.ssao_radius = value
	ssao_radius_label.text = "Radius: %.1f" % value

# ── UI Callbacks — SSIL ──────────────────────────────────────────────────────

func _on_ssil_toggled(enabled: bool) -> void:
	world_env.environment.ssil_enabled = enabled

func _on_ssil_intensity_changed(value: float) -> void:
	world_env.environment.ssil_intensity = value
	ssil_intensity_label.text = "Intensity: %.1f" % value

# ── UI Callbacks — Glow ──────────────────────────────────────────────────────

func _on_glow_toggled(enabled: bool) -> void:
	world_env.environment.glow_enabled = enabled

func _on_glow_intensity_changed(value: float) -> void:
	world_env.environment.glow_intensity = value
	glow_intensity_label.text = "Intensity: %.2f" % value

func _on_glow_bloom_changed(value: float) -> void:
	world_env.environment.glow_bloom = value
	glow_bloom_label.text = "Bloom: %.2f" % value

# ── UI Callbacks — Lights ────────────────────────────────────────────────────

func _on_dir_light_energy_changed(value: float) -> void:
	dir_light.light_energy = value
	dir_light_energy_label.text = "Directional: %.1f" % value

func _on_omni_light_energy_changed(value: float) -> void:
	omni_red.light_energy = value
	omni_blue.light_energy = value
	omni_warm.light_energy = value * 0.83  # keep warm slightly dimmer
	omni_light_energy_label.text = "Omni Lights: %.1f" % value

func _on_spot_light_energy_changed(value: float) -> void:
	spot_accent.light_energy = value
	spot_light_energy_label.text = "Spot Light: %.1f" % value

func _on_vfog_toggled(enabled: bool) -> void:
	world_env.environment.volumetric_fog_enabled = enabled

# ── UI Callbacks — Material overrides ────────────────────────────────────────

func _on_roughness_override_changed(value: float) -> void:
	roughness_override = value
	if value < 0.0:
		roughness_label.text = "Roughness Override: OFF"
	else:
		roughness_label.text = "Roughness Override: %.2f" % value
		_apply_material_override_to_existing()

func _on_metallic_override_changed(value: float) -> void:
	metallic_override = value
	if value < 0.0:
		metallic_label.text = "Metallic Override: OFF"
	else:
		metallic_label.text = "Metallic Override: %.2f" % value
		_apply_material_override_to_existing()

# ── Clear / Back ─────────────────────────────────────────────────────────────

func _on_clear_pressed() -> void:
	for obj in spawned_objects:
		if is_instance_valid(obj):
			obj.queue_free()
	spawned_objects.clear()
	spawn_timer.start()


func _on_back_pressed() -> void:
	GameManager.go_to_menu()
