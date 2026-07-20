extends Node3D
## Contact Refinement Parallax Occlusion Mapping demo
## State-of-the-art CRPOM with self-shadowing and multiple surface presets

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel
@onready var parallax_mesh: MeshInstance3D = $ParallaxSurface
@onready var parallax_mesh_cube: MeshInstance3D = $ParallaxCube

# UI Controls
@onready var render_mode_option: OptionButton = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer/RenderModeOption
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

var parallax_material: ShaderMaterial
var _tex_cache := {}

# Settings
var display_mode := 2 # 0=flat, 1=normal map only, 2=POM
var height_scale := 0.04
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

# height_scale values account for the uv_scale factor applied in the shader
# (apparent depth is world-constant: depth ≈ height_scale × plane size)
const PRESET_DEFAULTS := {
	Preset.ROCK: {
		"height_scale": 0.04,
		"min_layers": 8,
		"max_layers": 32,
		"uv_scale": 2.0,
		"roughness": 0.85,
		"normal_strength": 1.0,
		"shadow_strength": 0.8,
	},
	Preset.BRICKS: {
		"height_scale": 0.02,
		"min_layers": 8,
		"max_layers": 48,
		"uv_scale": 3.0,
		"roughness": 0.75,
		"normal_strength": 1.2,
		"shadow_strength": 1.0,
	},
	Preset.COBBLESTONE: {
		"height_scale": 0.04,
		"min_layers": 12,
		"max_layers": 48,
		"uv_scale": 2.5,
		"roughness": 0.9,
		"normal_strength": 1.0,
		"shadow_strength": 0.9,
	},
	Preset.DUNES: {
		"height_scale": 0.08,
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
	# Restore saved values as-is; presets only apply on explicit selection
	_generate_textures_for_preset(current_preset)
	_apply_shader_settings()

	# Configure orbit camera
	orbit_cam.distance = 4.0
	orbit_cam.pitch = -35.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = MIN_DISTANCE
	orbit_cam.max_distance = MAX_DISTANCE
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 0.3


func _load_settings() -> void:
	display_mode = int(GameManager.get_setting("parallax_display_mode", 2))
	height_scale = GameManager.get_setting("parallax_height", 0.04)
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
	parallax_material.shader = preload("res://shaders/parallax/parallax.gdshader")


func _setup_ui() -> void:
	# Disable scroll on all sliders so scrolling scrolls the panel, not the values
	for slider in $UI.find_children("*", "HSlider"):
		slider.scrollable = false

	# Render mode selector (Flat / Normal Map / POM comparison)
	render_mode_option.clear()
	render_mode_option.add_item("Flat (no relief)")
	render_mode_option.add_item("Normal Map Only")
	render_mode_option.add_item("Parallax (POM)")
	render_mode_option.selected = display_mode
	render_mode_option.item_selected.connect(_on_render_mode_selected)

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
	if not _tex_cache.has(preset_idx):
		_tex_cache[preset_idx] = _build_preset_maps(preset_idx)

	var maps: Array = _tex_cache[preset_idx]
	parallax_material.set_shader_parameter("texture_albedo", maps[0])
	parallax_material.set_shader_parameter("texture_normal", maps[1])
	parallax_material.set_shader_parameter("texture_height", maps[2])

	# Apply material to active mesh
	_update_mesh_visibility()


func _build_preset_maps(preset_idx: int) -> Array:
	match preset_idx:
		Preset.BRICKS:
			return _create_brick_maps()
		Preset.COBBLESTONE:
			return _noise_maps(_create_cobble_albedo(), _cobble_height_noise(), true, 12.0)
		Preset.DUNES:
			return _noise_maps(_create_dune_albedo(), _dune_height_noise(), false, 8.0)
		_:
			return _noise_maps(_create_rock_albedo(), _rock_height_noise(), true, 10.0)


# Normal map is derived from the SAME noise (and same invert) as the height map,
# so lighting cues match the parallax displacement.
func _noise_maps(albedo: Texture2D, height_noise: FastNoiseLite, inv: bool, bump: float) -> Array:
	var height_tex := NoiseTexture2D.new()
	height_tex.noise = height_noise
	height_tex.width = TEX_SIZE
	height_tex.height = TEX_SIZE
	height_tex.seamless = true
	height_tex.invert = inv

	var normal_tex := NoiseTexture2D.new()
	normal_tex.noise = height_noise
	normal_tex.width = TEX_SIZE
	normal_tex.height = TEX_SIZE
	normal_tex.seamless = true
	normal_tex.invert = inv
	normal_tex.as_normal_map = true
	normal_tex.bump_strength = bump

	return [albedo, normal_tex, height_tex]


func _apply_shader_settings() -> void:
	if not parallax_material:
		return
	parallax_material.set_shader_parameter("display_mode", display_mode)
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
	GameManager.set_setting("parallax_display_mode", display_mode)
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


func _rock_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.018
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.4
	return noise


# ─── Brick Preset ─────────────────────────────────
# Real brick grid generated pixel-by-pixel: straight mortar lines give hard
# silhouettes that make the parallax offset clearly visible (unlike noise).

@warning_ignore("integer_division")
func _create_brick_maps() -> Array:
	var size := 512
	var cols := 4
	var rows := 8
	var brick_w := size / cols
	var brick_h := size / rows
	var mortar_px := 3
	var bevel_px := 6

	var detail := FastNoiseLite.new()
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.06

	var height_img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var albedo_img := Image.create(size, size, false, Image.FORMAT_RGB8)

	var mortar_color := Color(0.62, 0.6, 0.57)
	var brick_colors: Array[Color] = [
		Color(0.55, 0.26, 0.16),
		Color(0.62, 0.32, 0.2),
		Color(0.48, 0.22, 0.14),
		Color(0.58, 0.3, 0.22),
	]

	for y in size:
		var row := y / brick_h
		var py := y % brick_h
		for x in size:
			# Alternate rows are offset by half a brick; wraps seamlessly
			# because size is divisible by brick_w
			var xs := x + (brick_w / 2 if row % 2 == 1 else 0)
			var col := xs / brick_w
			var px := xs % brick_w
			var dx := mini(px, brick_w - 1 - px)
			var dy := mini(py, brick_h - 1 - py)
			var d := mini(dx, dy)

			var n := detail.get_noise_2d(x, y) * 0.5 + 0.5
			var h := clampf(float(d - mortar_px) / float(bevel_px), 0.0, 1.0)
			h *= 0.85 + 0.15 * n
			height_img.set_pixel(x, y, Color(h, h, h))

			if d <= mortar_px:
				albedo_img.set_pixel(x, y, mortar_color.darkened(0.15 * n))
			else:
				var brick_col: Color = brick_colors[(row * 7 + col * 3) % brick_colors.size()]
				albedo_img.set_pixel(x, y, brick_col.darkened(0.2 * (1.0 - n)))

	var normal_img: Image = height_img.duplicate()
	normal_img.bump_map_to_normal_map(6.0)

	albedo_img.generate_mipmaps()
	normal_img.generate_mipmaps()
	height_img.generate_mipmaps()

	return [
		ImageTexture.create_from_image(albedo_img),
		ImageTexture.create_from_image(normal_img),
		ImageTexture.create_from_image(height_img),
	]


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


func _cobble_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.025
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.3
	return noise


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


func _dune_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008
	return noise


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
	if min_layers > max_layers:
		max_layers_slider.value = value
	_apply_shader_settings()


func _on_max_layers_changed(value: float) -> void:
	max_layers = int(value)
	max_layers_value.text = "%d" % max_layers
	if max_layers < min_layers:
		min_layers_slider.value = value
	_apply_shader_settings()


func _on_render_mode_selected(idx: int) -> void:
	display_mode = idx
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
