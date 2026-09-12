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
@onready var _viewport := ViewportGuard.attach(self)

var _info_label: Label
var config: SsrConfig = SsrConfig.new()
var quality := SimQualityState.new()

# ── Constants ────────────────────────────────────────────────────────────────
const SPAWN_HEIGHT := 12.0
const SPAWN_RADIUS := 10.0
const KILL_Y := -12.0
const KEY_LIGHT_ORBIT_RADIUS := 10.0
const KEY_LIGHT_ORBIT_HEIGHT := 10.0
const KEY_LIGHT_ORBIT_SPEED := 0.45

var max_objects: int = 200
var spawned_objects: Array[RigidBody3D] = []
var auto_spawn := true
var _camera_side_walls: Array[Dictionary] = []
var _key_light_angle := 0.0

# Material override values: -1 means "use per-object random"
var roughness_override: float = -1.0
var metallic_override: float = -1.0

# ── Material palette ─────────────────────────────────────────────────────────
# 3 categories: mirror (metallic=1, rough≈0), brushed (metallic≈0.8, rough≈0.25),
#               dielectric / glossy (metallic ≈0.15, rough≈0.1)
var spawner := RigidBodySpawner.new()

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("SSR config: %s" % config_error)
		return
	quality.setup(SsrQualityProfile, "ssr_quality_profile", _apply_quality)
	quality.restore()
	spawner.roughness_override = roughness_override
	spawner.metallic_override = metallic_override
	spawn_timer.wait_time = config.spawn_interval_s

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
	var steps_slider: HSlider = menu.add_slider("Max Steps", 16.0, 256.0,
		env.ssr_max_steps, func(v: float) -> void: env.ssr_max_steps = int(v))
	quality.bind("ssr_steps", steps_slider,
		func(v: float) -> void: env.ssr_max_steps = int(v))
	menu.add_slider("Fade In", 0.0, 1.0, 0.05, func(v: float) -> void: env.ssr_fade_in = v)
	menu.add_slider("Fade Out", 0.0, 5.0, 3.0, func(v: float) -> void: env.ssr_fade_out = v)
	menu.add_slider("Depth Tolerance", 0.01, 1.0, 0.25, func(v: float) -> void: env.ssr_depth_tolerance = v)

	menu.add_section("SSAO")
	menu.add_slider("Intensity", 0.0, 4.0, 1.5, func(v: float) -> void: env.ssao_intensity = v)
	menu.add_slider("Radius", 0.1, 5.0, 1.2, func(v: float) -> void: env.ssao_radius = v)

	menu.add_section("SSIL")
	menu.add_slider("Intensity", 0.0, 3.0, 1.2, func(v: float) -> void: env.ssil_intensity = v)

	menu.add_section("Glow")
	menu.add_slider("Intensity", 0.0, 2.0, 0.5, func(v: float) -> void: env.glow_intensity = v)
	menu.add_slider("Bloom", 0.0, 1.0, 0.05, func(v: float) -> void: env.glow_bloom = v)

	menu.add_section("Lights")
	menu.add_slider("Directional", 0.0, 5.0, 1.3, func(v: float) -> void: dir_light.light_energy = v)
	menu.add_slider("Omni Lights", 0.0, 8.0, 3.0, func(v: float) -> void:
		omni_red.light_energy = v
		omni_blue.light_energy = v
		omni_warm.light_energy = v * 0.83)  # keep warm slightly dimmer
	menu.add_slider("Spot Light", 0.0, 10.0, 6.0, func(v: float) -> void: spot_accent.light_energy = v)

	menu.add_section("Material")
	menu.add_slider("Roughness Override", -1.0, 1.0, -1.0, _on_roughness_override_changed)
	menu.add_slider("Metallic Override", -1.0, 1.0, -1.0, _on_metallic_override_changed)

	# Reflections on/off is the demo's whole point, so it stays one tap away.
	menu.add_action_toggle("🔮", "SSR", true, func(on: bool) -> void: env.ssr_enabled = on)
	menu.add_action("➕", "Spawn", spawn_random_shape)
	menu.add_action_toggle("⏱", "Auto", true, _on_auto_spawn_toggled)
	menu.add_action("🧹", "Clear", _on_clear_pressed)

	var ssao_toggle: Button = menu.add_debug_toggle("🌑", "SSAO", env.ssao_enabled,
		func(on: bool) -> void: env.ssao_enabled = on)
	quality.bind("ssao", ssao_toggle, func(on: bool) -> void: env.ssao_enabled = on)
	var ssil_toggle: Button = menu.add_debug_toggle("💡", "SSIL", env.ssil_enabled,
		func(on: bool) -> void: env.ssil_enabled = on)
	quality.bind("ssil", ssil_toggle, func(on: bool) -> void: env.ssil_enabled = on)
	var glow_toggle: Button = menu.add_debug_toggle("✨", "Glow", env.glow_enabled,
		func(on: bool) -> void: env.glow_enabled = on)
	quality.bind("glow", glow_toggle, func(on: bool) -> void: env.glow_enabled = on)
	menu.add_debug_toggle("🌫", "Volumetric fog", false,
		func(on: bool) -> void: env.volumetric_fog_enabled = on)

	menu.add_section("Performance")
	var scale_slider: HSlider = menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	quality.bind("render_scale", scale_slider, _set_render_scale)
	var msaa_names := ["Off", "2×", "4×"]
	var msaa_option: OptionButton = menu.add_option_button("MSAA", msaa_names,
		_msaa_index(_viewport.msaa()), _set_msaa)
	quality.bind("msaa", msaa_option, _set_msaa,
		func(mode: int) -> int: return _msaa_index(mode))
	var objects_slider: HSlider = menu.add_slider("Max objects", 10.0, 200.0,
		float(max_objects), func(v: float) -> void: max_objects = int(v))
	quality.bind("max_objects", objects_slider,
		func(v: float) -> void: max_objects = int(v))
	quality.attach_menu_option(menu)


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _set_msaa(mode: int) -> void:
	_viewport.set_msaa(mode)


static func _msaa_index(mode: int) -> int:
	match mode:
		Viewport.MSAA_2X: return 1
		Viewport.MSAA_4X: return 2
		_: return 0


## Tier launch path: the environment and spawner settings before the menu is
## built; the bound keys re-push through their widgets on a tier switch.
func _apply_quality(values: Dictionary) -> void:
	var env := world_env.environment
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, values.render_scale)
	_viewport.set_msaa(values.msaa)
	env.ssr_max_steps = int(values.ssr_steps)
	max_objects = int(values.max_objects)
	env.ssao_enabled = values.ssao
	env.ssil_enabled = values.ssil
	env.glow_enabled = values.glow


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
		elif obj.global_position.y < config.kill_height_m:
			obj.queue_free()
			spawned_objects.remove_at(i)
			removed = true
	if removed and auto_spawn and spawn_timer.is_stopped() and spawned_objects.size() < max_objects:
		spawn_timer.start()

# ── Spawning ─────────────────────────────────────────────────────────────────

func _on_auto_spawn_toggled(on: bool) -> void:
	auto_spawn = on
	if on:
		if spawned_objects.size() < max_objects:
			spawn_timer.start()
	else:
		spawn_timer.stop()


func _on_spawn_timer_timeout() -> void:
	if spawned_objects.size() >= max_objects:
		spawn_timer.stop()
		return
	spawn_random_shape()


func spawn_random_shape() -> RigidBody3D:
	if spawned_objects.size() >= max_objects:
		return null
	var body := spawner.spawn(self, Vector3(
			randf_range(-config.spawn_radius_m, config.spawn_radius_m),
			config.spawn_height_m + randf_range(0.0, 4.0),
			randf_range(-config.spawn_radius_m, config.spawn_radius_m)),
		Vector3(randf() * TAU, randf() * TAU, randf() * TAU),
		Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)))
	spawned_objects.append(body)
	return body

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
	spawner.roughness_override = value
	if value >= 0.0:
		_apply_material_override_to_existing()


func _on_metallic_override_changed(value: float) -> void:
	metallic_override = value
	spawner.metallic_override = value
	if value >= 0.0:
		_apply_material_override_to_existing()

# ── Clear ────────────────────────────────────────────────────────────────────

func _on_clear_pressed() -> void:
	for obj in spawned_objects:
		if is_instance_valid(obj):
			obj.queue_free()
	spawned_objects.clear()
	if auto_spawn:
		spawn_timer.start()
