extends Node3D
## Contact Refinement Parallax Occlusion Mapping demo
## State-of-the-art CRPOM with self-shadowing and multiple surface presets

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var info_label: Label = $UI/Control/InfoPanel/VBoxContainer/InfoLabel
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel
@onready var parallax_mesh: MeshInstance3D = $ParallaxSurface
@onready var parallax_mesh_cube: MeshInstance3D = $ParallaxCube

# UI Controls
@onready var preset_option: OptionButton = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/PresetOption
@onready var mesh_option: OptionButton = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/MeshOption
@onready var height_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/HeightSlider
@onready var height_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/HeightValue
@onready var min_layers_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/MinLayersSlider
@onready var min_layers_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/MinLayersValue
@onready var max_layers_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/MaxLayersSlider
@onready var max_layers_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/MaxLayersValue
@onready var uv_scale_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/UVScaleSlider
@onready var uv_scale_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/UVScaleValue
@onready var normal_strength_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/NormalStrengthSlider
@onready var normal_strength_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/NormalStrengthValue
@onready var roughness_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/RoughnessSlider
@onready var roughness_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/RoughnessValue
@onready var shadow_strength_slider: HSlider = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/ShadowStrengthSlider
@onready var shadow_strength_value: Label = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/ShadowStrengthValue
@onready var self_shadow_check: CheckButton = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/SelfShadowCheck
@onready var computed_normals_check: CheckButton = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/ComputedNormalsCheck
@onready var control_panel: PanelContainer = $UI/Control/ControlPanel

var parallax_material: ShaderMaterial

# Settings
var height_scale := 0.08
var min_layers := 8
var max_layers := 32
var uv_scale := 2.0
var normal_strength := 1.0
var roughness_val := 0.8
var shadow_strength := 0.8
var self_shadow_enabled := true
var computed_normals := false
var current_preset := 0
var current_mesh := 0 # 0=plane, 1=cube

# Camera controls
const MIN_DISTANCE := 1.5
const MAX_DISTANCE := 12.0

const TEX_SIZE := 1024

# ─── Surface Preset Definitions ──────────────────
# Each preset defines noise params for height, albedo, and normals + defaults

enum Preset { ROCK, BRICKS, COBBLESTONE, DUNES }

const PRESET_NAMES := ["🪨 Rock", "🧱 Bricks", "🪨 Cobblestone", "🏜️ Dunes"]

const PRESET_DEFAULTS := {
	Preset.ROCK: {
		"height_scale": 0.08,
		"min_layers": 8,
		"max_layers": 32,
		"uv_scale": 2.0,
		"roughness": 0.85,
		"normal_strength": 1.0,
		"shadow_strength": 0.8,
	},
	Preset.BRICKS: {
		"height_scale": 0.06,
		"min_layers": 8,
		"max_layers": 48,
		"uv_scale": 3.0,
		"roughness": 0.75,
		"normal_strength": 1.2,
		"shadow_strength": 1.0,
	},
	Preset.COBBLESTONE: {
		"height_scale": 0.1,
		"min_layers": 12,
		"max_layers": 48,
		"uv_scale": 2.5,
		"roughness": 0.9,
		"normal_strength": 1.0,
		"shadow_strength": 0.9,
	},
	Preset.DUNES: {
		"height_scale": 0.12,
		"min_layers": 8,
		"max_layers": 40,
		"uv_scale": 1.5,
		"roughness": 0.95,
		"normal_strength": 0.8,
		"shadow_strength": 0.6,
	},
}


func _ready() -> void:
	_load_settings()
	_setup_material()
	_setup_ui()
	_apply_preset(current_preset, false)
	
	# Configure orbit camera
	orbit_cam.distance = 4.0
	orbit_cam.pitch = -35.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = MIN_DISTANCE
	orbit_cam.max_distance = MAX_DISTANCE
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 0.3
	
	_connect_ui_signals()
	_update_mesh_visibility()


func _connect_ui_signals() -> void:
	# Disable scroll on all sliders so scrolling scrolls the panel, not the values
	for slider in $UI.find_children("*", "HSlider"):
		slider.scrollable = false


func _load_settings() -> void:
	height_scale = GameManager.get_setting("parallax_height", 0.08)
	min_layers = int(GameManager.get_setting("parallax_min_layers", 8))
	max_layers = int(GameManager.get_setting("parallax_max_layers", 32))
	uv_scale = GameManager.get_setting("parallax_uv_scale", 2.0)
	normal_strength = GameManager.get_setting("parallax_normal_strength", 1.0)
	roughness_val = GameManager.get_setting("parallax_roughness", 0.8)
	shadow_strength = GameManager.get_setting("parallax_shadow_strength", 0.8)
	self_shadow_enabled = GameManager.get_setting("parallax_self_shadow", true)
	computed_normals = GameManager.get_setting("parallax_computed_normals", false)
	current_preset = int(GameManager.get_setting("parallax_preset", 0))
	current_mesh = int(GameManager.get_setting("parallax_mesh", 0))


func _setup_material() -> void:
	parallax_material = ShaderMaterial.new()
	parallax_material.shader = preload("res://shaders/parallax.gdshader")


func _setup_ui() -> void:
	# Preset selector
	preset_option.clear()
	for p_name in PRESET_NAMES:
		preset_option.add_item(p_name)
	preset_option.selected = current_preset
	preset_option.item_selected.connect(_on_preset_selected)

	# Mesh selector
	mesh_option.clear()
	mesh_option.add_item("Plane")
	mesh_option.add_item("Cube")
	mesh_option.selected = current_mesh
	mesh_option.item_selected.connect(_on_mesh_selected)

	# Sliders
	height_slider.value = height_scale
	height_value.text = "%.3f" % height_scale
	height_slider.value_changed.connect(_on_height_changed)

	min_layers_slider.value = min_layers
	min_layers_value.text = "%d" % min_layers
	min_layers_slider.value_changed.connect(_on_min_layers_changed)

	max_layers_slider.value = max_layers
	max_layers_value.text = "%d" % max_layers
	max_layers_slider.value_changed.connect(_on_max_layers_changed)

	uv_scale_slider.value = uv_scale
	uv_scale_value.text = "%.1f" % uv_scale
	uv_scale_slider.value_changed.connect(_on_uv_scale_changed)

	normal_strength_slider.value = normal_strength
	normal_strength_value.text = "%.2f" % normal_strength
	normal_strength_slider.value_changed.connect(_on_normal_strength_changed)

	roughness_slider.value = roughness_val
	roughness_value.text = "%.2f" % roughness_val
	roughness_slider.value_changed.connect(_on_roughness_changed)

	shadow_strength_slider.value = shadow_strength
	shadow_strength_value.text = "%.2f" % shadow_strength
	shadow_strength_slider.value_changed.connect(_on_shadow_strength_changed)

	self_shadow_check.button_pressed = self_shadow_enabled
	self_shadow_check.toggled.connect(_on_self_shadow_toggled)

	computed_normals_check.button_pressed = computed_normals
	computed_normals_check.toggled.connect(_on_computed_normals_toggled)


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	info_label.text = "CRPOM · Drag: rotate | Scroll: zoom | ZQSD: move"


func _update_mesh_visibility() -> void:
	parallax_mesh.visible = (current_mesh == 0)
	parallax_mesh_cube.visible = (current_mesh == 1)

	var active_mesh := parallax_mesh if current_mesh == 0 else parallax_mesh_cube
	active_mesh.set_surface_override_material(0, parallax_material)


# ─── Preset System ────────────────────────────────

func _apply_preset(preset_idx: int, update_ui: bool = true) -> void:
	current_preset = preset_idx
	GameManager.set_setting("parallax_preset", preset_idx)

	var defaults: Dictionary = PRESET_DEFAULTS[preset_idx]
	height_scale = defaults["height_scale"]
	min_layers = int(defaults["min_layers"])
	max_layers = int(defaults["max_layers"])
	uv_scale = defaults["uv_scale"]
	roughness_val = defaults["roughness"]
	normal_strength = defaults["normal_strength"]
	shadow_strength = defaults["shadow_strength"]

	if update_ui:
		_sync_ui_to_values()

	_generate_textures_for_preset(preset_idx)
	_apply_shader_settings()


func _sync_ui_to_values() -> void:
	height_slider.value = height_scale
	height_value.text = "%.3f" % height_scale
	min_layers_slider.value = min_layers
	min_layers_value.text = "%d" % min_layers
	max_layers_slider.value = max_layers
	max_layers_value.text = "%d" % max_layers
	uv_scale_slider.value = uv_scale
	uv_scale_value.text = "%.1f" % uv_scale
	normal_strength_slider.value = normal_strength
	normal_strength_value.text = "%.2f" % normal_strength
	roughness_slider.value = roughness_val
	roughness_value.text = "%.2f" % roughness_val
	shadow_strength_slider.value = shadow_strength
	shadow_strength_value.text = "%.2f" % shadow_strength


func _generate_textures_for_preset(preset_idx: int) -> void:
	var albedo_tex: NoiseTexture2D
	var normal_tex: NoiseTexture2D
	var height_tex: NoiseTexture2D

	match preset_idx:
		Preset.ROCK:
			albedo_tex = _create_rock_albedo()
			normal_tex = _create_rock_normal()
			height_tex = _create_rock_height()
		Preset.BRICKS:
			albedo_tex = _create_brick_albedo()
			normal_tex = _create_brick_normal()
			height_tex = _create_brick_height()
		Preset.COBBLESTONE:
			albedo_tex = _create_cobble_albedo()
			normal_tex = _create_cobble_normal()
			height_tex = _create_cobble_height()
		Preset.DUNES:
			albedo_tex = _create_dune_albedo()
			normal_tex = _create_dune_normal()
			height_tex = _create_dune_height()
		_:
			albedo_tex = _create_rock_albedo()
			normal_tex = _create_rock_normal()
			height_tex = _create_rock_height()

	parallax_material.set_shader_parameter("texture_albedo", albedo_tex)
	parallax_material.set_shader_parameter("texture_normal", normal_tex)
	parallax_material.set_shader_parameter("texture_height", height_tex)

	# Apply material to active mesh
	_update_mesh_visibility()


func _apply_shader_settings() -> void:
	if not parallax_material:
		return
	parallax_material.set_shader_parameter("height_scale", height_scale)
	parallax_material.set_shader_parameter("min_layers", min_layers)
	parallax_material.set_shader_parameter("max_layers", max_layers)
	parallax_material.set_shader_parameter("uv_scale", uv_scale)
	parallax_material.set_shader_parameter("normal_strength", normal_strength)
	parallax_material.set_shader_parameter("roughness", roughness_val)
	parallax_material.set_shader_parameter("shadow_strength", shadow_strength)
	parallax_material.set_shader_parameter("self_shadow_enabled", self_shadow_enabled)
	parallax_material.set_shader_parameter("use_computed_normals", computed_normals)

	_save_all_settings()


func _save_all_settings() -> void:
	GameManager.set_setting("parallax_height", height_scale)
	GameManager.set_setting("parallax_min_layers", min_layers)
	GameManager.set_setting("parallax_max_layers", max_layers)
	GameManager.set_setting("parallax_uv_scale", uv_scale)
	GameManager.set_setting("parallax_normal_strength", normal_strength)
	GameManager.set_setting("parallax_roughness", roughness_val)
	GameManager.set_setting("parallax_shadow_strength", shadow_strength)
	GameManager.set_setting("parallax_self_shadow", self_shadow_enabled)
	GameManager.set_setting("parallax_computed_normals", computed_normals)
	GameManager.set_setting("parallax_mesh", current_mesh)


# ─── Rock Preset ──────────────────────────────────

func _create_rock_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.02
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.25, 0.5, 0.7, 1.0], [
		Color(0.2, 0.18, 0.16),
		Color(0.3, 0.27, 0.24),
		Color(0.42, 0.38, 0.34),
		Color(0.36, 0.32, 0.28),
		Color(0.48, 0.45, 0.42),
	])
	return tex


func _create_rock_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.03
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.6

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 14.0
	return tex


func _create_rock_height() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.018
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.4

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.invert = true
	return tex


# ─── Brick Preset ─────────────────────────────────

func _create_brick_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.015
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.3

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.3, 0.5, 0.7, 1.0], [
		Color(0.45, 0.2, 0.12),
		Color(0.55, 0.28, 0.15),
		Color(0.6, 0.32, 0.18),
		Color(0.5, 0.25, 0.14),
		Color(0.65, 0.35, 0.2),
	])
	return tex


func _create_brick_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.015

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 16.0
	return tex


func _create_brick_height() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	noise.frequency = 0.015

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.invert = false
	return tex


# ─── Cobblestone Preset ───────────────────────────

func _create_cobble_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.025
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.4

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.3, 0.55, 0.75, 1.0], [
		Color(0.3, 0.3, 0.3),
		Color(0.4, 0.39, 0.38),
		Color(0.5, 0.49, 0.47),
		Color(0.45, 0.44, 0.42),
		Color(0.55, 0.54, 0.52),
	])
	return tex


func _create_cobble_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.025

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 12.0
	return tex


func _create_cobble_height() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.025
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.3

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.invert = true
	return tex


# ─── Dune / Sand Preset ──────────────────────────

func _create_dune_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.3, 0.6, 0.8, 1.0], [
		Color(0.65, 0.52, 0.35),
		Color(0.72, 0.58, 0.4),
		Color(0.78, 0.65, 0.45),
		Color(0.74, 0.6, 0.42),
		Color(0.82, 0.7, 0.5),
	])
	return tex


func _create_dune_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 8.0
	return tex


func _create_dune_height() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	return tex


# ─── Utility ─────────────────────────────────────

func _gradient(offsets: Array, colors: Array) -> Gradient:
	var g := Gradient.new()
	var off_pf := PackedFloat32Array()
	var col_pf := PackedColorArray()
	for o in offsets:
		off_pf.append(o)
	for c in colors:
		col_pf.append(c)
	g.offsets = off_pf
	g.colors = col_pf
	return g


# ─── UI Callbacks ─────────────────────────────────

func _on_preset_selected(idx: int) -> void:
	_apply_preset(idx)


func _on_mesh_selected(idx: int) -> void:
	current_mesh = idx
	GameManager.set_setting("parallax_mesh", idx)
	_update_mesh_visibility()


func _on_height_changed(value: float) -> void:
	height_scale = value
	height_value.text = "%.3f" % value
	_apply_shader_settings()


func _on_min_layers_changed(value: float) -> void:
	min_layers = int(value)
	min_layers_value.text = "%d" % min_layers
	_apply_shader_settings()


func _on_max_layers_changed(value: float) -> void:
	max_layers = int(value)
	max_layers_value.text = "%d" % max_layers
	_apply_shader_settings()


func _on_uv_scale_changed(value: float) -> void:
	uv_scale = value
	uv_scale_value.text = "%.1f" % value
	_apply_shader_settings()


func _on_normal_strength_changed(value: float) -> void:
	normal_strength = value
	normal_strength_value.text = "%.2f" % value
	_apply_shader_settings()


func _on_roughness_changed(value: float) -> void:
	roughness_val = value
	roughness_value.text = "%.2f" % value
	_apply_shader_settings()


func _on_shadow_strength_changed(value: float) -> void:
	shadow_strength = value
	shadow_strength_value.text = "%.2f" % value
	_apply_shader_settings()


func _on_self_shadow_toggled(pressed: bool) -> void:
	self_shadow_enabled = pressed
	_apply_shader_settings()


func _on_computed_normals_toggled(pressed: bool) -> void:
	computed_normals = pressed
	_apply_shader_settings()


func _on_back_pressed() -> void:
	GameManager.go_to_menu()
