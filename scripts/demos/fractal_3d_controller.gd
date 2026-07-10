extends Node3D
## 3D Fractal Explorer — raymarching controller.
## Drives the ShaderMaterial on a viewport-filling BoxMesh, a captured-mouse
## FreeFlyCamera, and a SimMenu whose params are scoped to the selected fractal.
## Selecting a fractal loads its first preset (params + camera pose) so it is
## always framed and never a black void. FractalDE mirrors the DE for adaptive speed.

@onready var _fractal_box: MeshInstance3D = $FractalBox
@onready var _camera: FreeFlyCamera = $FreeFlyCamera
@onready var _menu: SimMenu = $UI/SimMenu
@onready var _post_process: ColorRect = $PostProcess/ColorRect

const FRACTAL_NAMES := ["Pseudo-Kleinian", "Apollonian", "Menger infini", "Kleinian de Jos Leys"]
const PALETTE_NAMES := ["Nacre", "Rainbow", "Fire", "Ocean", "Gold"]
const MIN_STEPS := 60

# Shader-uniform-keyed parameter state. Keys match uniform names exactly and are
# also read by FractalDE.evaluate (extra keys ignored). Vector3 for vec3 uniforms.
const BASE_PARAMS := {
	"fractal_type": 0,
	"iterations": 12,
	"max_steps": 160,
	"max_dist": 60.0,
	"epsilon": 0.0015,
	"kleinian_csize": Vector3(0.808, 0.808, 1.167),
	"kleinian_minrad2": 0.25,
	"apollonian_scale": 1.3,
	"klein_r": 1.95859103011179,
	"klein_i": 0.0112785606117658,
	"klein_box_x": 1.0,
	"klein_box_z": 1.0,
	"palette": 0,
	"color_speed": 0.3,
	"color_offset": 0.0,
	"glow_strength": 1.0,
}

# 2 curated presets per fractal: known-good params + a camera start pose ("cam").
const PRESETS := {
	0: [
		{"name": "Corridors", "kleinian_minrad2": 0.25, "iterations": 10, "palette": 3, "cam": Vector3(0, 0, 2.2)},
		{"name": "Tight", "kleinian_minrad2": 0.42, "iterations": 12, "palette": 0, "cam": Vector3(0, 0, 1.8)},
	],
	1: [
		{"name": "Bubbles", "apollonian_scale": 1.3, "iterations": 10, "palette": 0, "cam": Vector3(0.2, 0.3, 0.7)},
		{"name": "Dense", "apollonian_scale": 1.6, "iterations": 12, "palette": 1, "cam": Vector3(0.1, 0.2, 0.5)},
	],
	2: [
		{"name": "Tunnels", "iterations": 5, "palette": 4, "cam": Vector3(0, 0, 0)},
		{"name": "Profond", "iterations": 8, "palette": 2, "cam": Vector3(0, 0, 0)},
	],
	3: [
		{"name": "Labyrinthe", "klein_r": 1.95859103011179, "klein_i": 0.0112785606117658, "klein_box_x": 1.0, "klein_box_z": 1.0, "iterations": 20, "palette": 1, "cam": Vector3(0.5, 1.0, 0.5)},
		{"name": "Hippocampe", "klein_r": 1.89, "klein_i": 0.1, "klein_box_x": 0.8089, "klein_box_z": 0.68, "iterations": 20, "palette": 0, "cam": Vector3(0.4, 1.0, 0.3)},
	],
}

var _material: ShaderMaterial
var _post_material: ShaderMaterial
var _params: Dictionary = {}

var _sliders: Dictionary = {}          # uniform name -> HSlider (for preset sync)
var _param_groups: Dictionary = {}     # fractal index -> VBoxContainer
var _fractal_option: OptionButton
var _preset_option: OptionButton
var _palette_option: OptionButton
var _speed_slider: HSlider

var _adaptive := true
var _render_scale := 0.75
var _post_enabled := true
var _post := {"aberration_strength": 0.0015, "vignette_strength": 0.35, "grain_strength": 0.015}


func _ready() -> void:
	_material = _fractal_box.get_active_material(0) as ShaderMaterial
	if not _material:
		_material = _fractal_box.material_override as ShaderMaterial
	_post_material = _post_process.material as ShaderMaterial
	_camera.de_query = _evaluate_de

	# Fragment-bound raymarch: render the 3D pass at reduced resolution and let
	# FSR upscale it. UI/post-process stay at native resolution.
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	get_viewport().scaling_3d_scale = _render_scale

	_params = BASE_PARAMS.duplicate(true)
	_setup_ui()
	_add_hint_label()
	_select_fractal(0)
	_apply_post()


func _add_hint_label() -> void:
	var hint := Label.new()
	hint.text = "Échap : libérer/capturer souris   •   ZQSD + Espace/Shift : voler   •   Molette : vitesse"
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	$UI.add_child(hint)


func _process(_delta: float) -> void:
	var budget: int = _params["max_steps"]
	if _adaptive:
		var cruise: float = maxf(_camera.move_speed, 0.001)
		var q := clampf(_camera.velocity.length() / cruise, 0.0, 1.0)
		var steps := int(round(lerpf(float(budget), float(MIN_STEPS), q * 0.6)))
		_material.set_shader_parameter("max_steps", steps)
	else:
		_material.set_shader_parameter("max_steps", budget)
	# Mouse wheel changes speed on the camera; mirror it into the slider (+label).
	if absf(_speed_slider.value - _camera.move_speed) > 0.01:
		_speed_slider.value = _camera.move_speed


func _evaluate_de(p: Vector3) -> float:
	return FractalDE.evaluate(p, _params)


# --- UI ------------------------------------------------------------------------

func _setup_ui() -> void:
	_menu.title = "Fractale 3D"

	_menu.add_section("Fractale")
	_fractal_option = _menu.add_option_button("Type", FRACTAL_NAMES, 0, _select_fractal)
	_preset_option = _menu.add_option_button("Preset", ["-"], 0, _on_preset_selected)

	_menu.add_section("Look")
	_palette_option = _menu.add_option_button("Palette", PALETTE_NAMES, _params["palette"], _on_palette_selected)
	_sliders["color_speed"] = _menu.add_slider("Vitesse couleur", 0.0, 3.0, _params["color_speed"], func(v: float) -> void: _set_param("color_speed", v))
	_sliders["color_offset"] = _menu.add_slider("Teinte", 0.0, 1.0, _params["color_offset"], func(v: float) -> void: _set_param("color_offset", v))
	_sliders["glow_strength"] = _menu.add_slider("Glow", 0.0, 3.0, _params["glow_strength"], func(v: float) -> void: _set_param("glow_strength", v))
	_sliders["iterations"] = _menu.add_slider("Détail (iter.)", 2.0, 40.0, _params["iterations"], func(v: float) -> void: _set_param("iterations", int(round(v))))

	_menu.add_section("Paramètres")
	_build_param_groups()

	_menu.add_section("Navigation")
	_speed_slider = _menu.add_slider("Vitesse", 0.1, 15.0, _camera.move_speed, func(v: float) -> void: _camera.move_speed = v)
	_menu.add_slider("Sensibilité", 0.02, 0.5, _camera.mouse_sensitivity, func(v: float) -> void: _camera.mouse_sensitivity = v)
	_menu.add_slider("FOV", 50.0, 110.0, _camera.fov, func(v: float) -> void: _camera.set_fov(v))

	_menu.add_section("Qualité")
	_menu.add_toggle("Qualité adaptative", _adaptive, func(on: bool) -> void: _adaptive = on)
	_menu.add_slider("Échelle rendu", 0.4, 1.0, _render_scale, func(v: float) -> void: _set_render_scale(v))
	_sliders["max_steps"] = _menu.add_slider("Steps max", 30.0, 400.0, _params["max_steps"], func(v: float) -> void: _set_param("max_steps", int(round(v))))
	_sliders["max_dist"] = _menu.add_slider("Distance max", 5.0, 200.0, _params["max_dist"], func(v: float) -> void: _set_param("max_dist", v))
	_sliders["epsilon"] = _menu.add_slider("Précision", 0.0002, 0.01, _params["epsilon"], func(v: float) -> void: _set_param("epsilon", v))

	_menu.add_section("Effets (confort)")
	_menu.add_toggle("Post-FX", _post_enabled, func(on: bool) -> void: _set_post_enabled(on))
	_menu.add_slider("Aberration", 0.0, 0.02, _post["aberration_strength"], func(v: float) -> void: _set_post("aberration_strength", v))
	_menu.add_slider("Vignette", 0.0, 2.0, _post["vignette_strength"], func(v: float) -> void: _set_post("vignette_strength", v))
	_menu.add_slider("Grain", 0.0, 0.2, _post["grain_strength"], func(v: float) -> void: _set_post("grain_strength", v))


func _build_param_groups() -> void:
	var g0 := _menu.add_group()
	_sliders["kleinian_minrad2"] = _menu.add_slider("Min radius²", 0.1, 1.0, _params["kleinian_minrad2"], func(v: float) -> void: _set_param("kleinian_minrad2", v))
	_menu.end_group()
	_param_groups[0] = g0

	var g1 := _menu.add_group()
	_sliders["apollonian_scale"] = _menu.add_slider("Packing", 1.0, 2.5, _params["apollonian_scale"], func(v: float) -> void: _set_param("apollonian_scale", v))
	_menu.end_group()
	_param_groups[1] = g1

	var g2 := _menu.add_group()
	_menu.add_label("Menger : ajuste le Détail.")
	_menu.end_group()
	_param_groups[2] = g2

	var g3 := _menu.add_group()
	_sliders["klein_r"] = _menu.add_slider("Klein R", 1.8, 1.96, _params["klein_r"], func(v: float) -> void: _set_param("klein_r", v))
	_sliders["klein_i"] = _menu.add_slider("Klein I", -0.2, 0.2, _params["klein_i"], func(v: float) -> void: _set_param("klein_i", v))
	_sliders["klein_box_x"] = _menu.add_slider("Boîte X", 0.3, 2.0, _params["klein_box_x"], func(v: float) -> void: _set_param("klein_box_x", v))
	_sliders["klein_box_z"] = _menu.add_slider("Boîte Z", 0.3, 2.0, _params["klein_box_z"], func(v: float) -> void: _set_param("klein_box_z", v))
	_menu.end_group()
	_param_groups[3] = g3


func _select_fractal(idx: int) -> void:
	_params["fractal_type"] = idx
	for key in _param_groups:
		(_param_groups[key] as Control).visible = (key == idx)

	_preset_option.clear()
	var list: Array = PRESETS[idx]
	for i in list.size():
		_preset_option.add_item(str(list[i]["name"]), i)
	_preset_option.select(0)
	_apply_preset(list[0])


func _on_preset_selected(idx: int) -> void:
	var list: Array = PRESETS[_params["fractal_type"]]
	if idx >= 0 and idx < list.size():
		_apply_preset(list[idx])


func _on_palette_selected(idx: int) -> void:
	_set_param("palette", idx)


func _apply_preset(preset: Dictionary) -> void:
	for key in preset:
		if key == "cam" or key == "name":
			continue
		if _sliders.has(key):
			(_sliders[key] as HSlider).value = preset[key]   # drives cb -> _params + label
		else:
			_params[key] = preset[key]
	if preset.has("palette"):
		_palette_option.select(int(preset["palette"]))
	var cam: Vector3 = preset.get("cam", Vector3(0, 0, 3))
	_camera.set_pose(cam, 0.0, 0.0)
	_push()


# --- Parameter push ------------------------------------------------------------

func _set_param(key: String, value: Variant) -> void:
	_params[key] = value
	_push()


func _set_render_scale(v: float) -> void:
	_render_scale = v
	get_viewport().scaling_3d_scale = v


func _push() -> void:
	for key in _params:
		_material.set_shader_parameter(key, _params[key])


# --- Post-process --------------------------------------------------------------

func _set_post(key: String, value: float) -> void:
	_post[key] = value
	_apply_post()


func _set_post_enabled(on: bool) -> void:
	_post_enabled = on
	_apply_post()


func _apply_post() -> void:
	var f := 1.0 if _post_enabled else 0.0
	for key in _post:
		_post_material.set_shader_parameter(key, _post[key] * f)
