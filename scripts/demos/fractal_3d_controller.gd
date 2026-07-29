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

const FRACTAL_NAMES := ["Apollonian", "Menger infini", "Kleinian de Jos Leys"]
const PALETTE_NAMES := ["Nacre", "Rainbow", "Fire", "Ocean", "Gold"]
const QUALITY_PROFILE_NAMES := ["Quality · 30 FPS", "Balanced · 45 FPS", "Performance · 60 FPS"]
const QUALITY_PROFILES := [
	{"target_fps": 30.0, "start_scales": [0.75, 0.75, 0.55], "scale_floors": [0.6, 0.65, 0.45], "step_floors": [200, 140, 480], "iteration_floors": [10, 6, 20], "ao_samples": 3, "pixel_tolerance": 0.18},
	{"target_fps": 45.0, "start_scales": [0.75, 0.75, 0.45], "scale_floors": [0.5, 0.55, 0.4], "step_floors": [160, 120, 420], "iteration_floors": [9, 5, 18], "ao_samples": 2, "pixel_tolerance": 0.22},
	{"target_fps": 60.0, "start_scales": [0.75, 0.75, 0.4], "scale_floors": [0.45, 0.45, 0.4], "step_floors": [120, 100, 380], "iteration_floors": [8, 5, 16], "ao_samples": 1, "pixel_tolerance": 0.28},
]
const QUALITY_WARMUP_FRAMES := 120
const QUALITY_INTERVAL := 0.25
const QUALITY_RECOVERY_DELAY := 1.5

# Shader-uniform-keyed parameter state. Keys match uniform names exactly and are
# also read by FractalDE.evaluate (extra keys ignored). Vector3 for vec3 uniforms.
const BASE_PARAMS := {
	"fractal_type": 0,
	"iterations": 12,
	"max_steps": 480,
	"max_dist": 60.0,
	"epsilon": 0.0001,
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
		{"name": "Gasket", "apollonian_scale": 1.15, "iterations": 16, "max_steps": 600, "max_dist": 60.0, "palette": 3, "cam": Vector3(0.35, 0.35, 0.85)},
		{"name": "Bubbles", "apollonian_scale": 1.3, "iterations": 12, "max_steps": 480, "max_dist": 60.0, "palette": 0, "cam": Vector3(0.4, 0.4, 0.8)},
		{"name": "Dense", "apollonian_scale": 1.6, "iterations": 14, "max_steps": 480, "max_dist": 60.0, "palette": 1, "cam": Vector3(0.5, 0.5, 1.0)},
		{"name": "Coral", "apollonian_scale": 1.9, "iterations": 16, "max_steps": 600, "max_dist": 60.0, "palette": 3, "cam": Vector3(0.45, 0.45, 0.95)},
	],
	1: [
		{"name": "Tunnels", "iterations": 6, "max_steps": 320, "max_dist": 60.0, "palette": 4, "cam": Vector3(0, 0, 0)},
		{"name": "Profond", "iterations": 9, "max_steps": 320, "max_dist": 60.0, "palette": 2, "cam": Vector3(0, 0, 0)},
	],
	2: [
		{"name": "Labyrinthe", "klein_r": 1.95859103011179, "klein_i": 0.0112785606117658, "klein_box_x": 1.0, "klein_box_z": 1.0, "iterations": 32, "max_steps": 1000, "max_dist": 30.0, "palette": 1, "cam": Vector3(0.5, 1.0, 0.5)},
		{"name": "Hippocampe", "klein_r": 1.89, "klein_i": 0.1, "klein_box_x": 0.8089, "klein_box_z": 0.68, "iterations": 32, "max_steps": 1000, "max_dist": 30.0, "palette": 0, "cam": Vector3(0.4, 1.0, 0.3)},
		{"name": "Organique", "klein_r": 1.84, "klein_i": 0.18, "klein_box_x": 0.55, "klein_box_z": 1.45, "iterations": 32, "max_steps": 1000, "max_dist": 30.0, "palette": 0, "cam": Vector3(0.3, 0.92, 0.25)},
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
var _quality_label: Label

var _adaptive := true
var _render_scale := 0.75
var _effective_scale := 0.75
var _effective_steps := 480
var _effective_iterations := 12
var _quality_profile := 0
var _preset_index := 0
var _quality_warmup := QUALITY_WARMUP_FRAMES
var _quality_timer := 0.0
var _headroom_time := 0.0
var _frame_time_ema := 0.0
var _quality_cache: Dictionary = {}
var _applying_preset := false
var _animate_packing := false
var _packing_animation_time := 0.0
var _packing_center := 1.3
var _updating_packing := false
var _post_enabled := true
var _post := {"aberration_strength": 0.0, "vignette_strength": 0.35, "grain_strength": 0.0}


func _ready() -> void:
	_material = _fractal_box.get_active_material(0) as ShaderMaterial
	if not _material:
		_material = _fractal_box.material_override as ShaderMaterial
	_post_material = _post_process.material as ShaderMaterial
	_camera.de_query = _evaluate_de

	# FSR remains available for manual/adaptive scaling; maximum quality uses
	# native resolution. UI/post-process always stay at native resolution.
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	get_viewport().scaling_3d_scale = _render_scale
	get_viewport().size_changed.connect(_apply_effective_quality)

	_params = BASE_PARAMS.duplicate(true)
	_setup_ui()
	_add_hint_label()
	_select_fractal(0)
	_apply_post()


func _add_hint_label() -> void:
	var hint := Label.new()
	hint.text = "Esc: release/capture mouse   •   WASD + Space/Shift: fly   •   Wheel: speed"
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	$UI.add_child(hint)


func _process(delta: float) -> void:
	if absf(_speed_slider.value - _camera.move_speed) > 0.01:
		_speed_slider.value = _camera.move_speed
	_update_packing_animation(delta)
	if _quality_warmup > 0:
		_quality_warmup -= 1
		return
	var blend := 1.0 - exp(-delta / 0.5)
	_frame_time_ema = delta if _frame_time_ema <= 0.0 else lerpf(_frame_time_ema, delta, blend)
	_quality_timer += delta
	if _quality_timer < QUALITY_INTERVAL:
		return
	_quality_timer = 0.0
	if _adaptive:
		_update_adaptive_quality()
	_update_quality_label()


func _evaluate_de(p: Vector3) -> float:
	return FractalDE.evaluate(p, _params)


# --- UI ------------------------------------------------------------------------

func _setup_ui() -> void:
	_menu.title = "3D Fractal"

	_menu.add_section("Fractal")
	_fractal_option = _menu.add_option_button("Type", FRACTAL_NAMES, 0, _select_fractal)
	_preset_option = _menu.add_option_button("Preset", ["-"], 0, _on_preset_selected)

	_menu.add_section("Look")
	_palette_option = _menu.add_option_button("Palette", PALETTE_NAMES, _params["palette"], _on_palette_selected)
	_sliders["color_speed"] = _menu.add_slider("Color speed", 0.0, 3.0, _params["color_speed"], func(v: float) -> void: _set_param("color_speed", v))
	_sliders["color_offset"] = _menu.add_slider("Hue", 0.0, 1.0, _params["color_offset"], func(v: float) -> void: _set_param("color_offset", v))
	_sliders["glow_strength"] = _menu.add_slider("Glow", 0.0, 3.0, _params["glow_strength"], func(v: float) -> void: _set_param("glow_strength", v))
	_sliders["iterations"] = _menu.add_slider("Detail (iter.)", 2.0, 40.0, _params["iterations"], func(v: float) -> void: _set_param("iterations", int(round(v))))

	_menu.add_section("Parameters")
	_build_param_groups()

	_menu.add_section("Navigation")
	_speed_slider = _menu.add_slider("Speed", 0.1, 15.0, _camera.move_speed, func(v: float) -> void: _camera.move_speed = v)
	_menu.add_slider("Sensitivity", 0.02, 0.5, _camera.mouse_sensitivity, func(v: float) -> void: _camera.mouse_sensitivity = v)
	_menu.add_slider("FOV", 50.0, 110.0, _camera.fov, _set_fov)

	_menu.add_section("Quality")
	_menu.add_option_button("Quality profile", QUALITY_PROFILE_NAMES, _quality_profile, _set_quality_profile)
	_menu.add_slider("Render scale", 0.4, 1.0, _render_scale, func(v: float) -> void: _set_render_scale(v))
	_sliders["max_steps"] = _menu.add_slider("Max steps", 30.0, 1200.0, _params["max_steps"], func(v: float) -> void: _set_param("max_steps", int(round(v))))
	_sliders["max_dist"] = _menu.add_slider("Max distance", 5.0, 200.0, _params["max_dist"], func(v: float) -> void: _set_param("max_dist", v))
	_sliders["epsilon"] = _menu.add_slider("Precision", 0.00002, 0.01, _params["epsilon"], func(v: float) -> void: _set_param("epsilon", v))
	_quality_label = _menu.add_label("")

	_menu.add_section("Effects (comfort)")
	_menu.add_slider("Aberration", 0.0, 0.02, _post["aberration_strength"], func(v: float) -> void: _set_post("aberration_strength", v))
	_menu.add_slider("Vignette", 0.0, 2.0, _post["vignette_strength"], func(v: float) -> void: _set_post("vignette_strength", v))
	_menu.add_slider("Grain", 0.0, 0.2, _post["grain_strength"], func(v: float) -> void: _set_post("grain_strength", v))

	# Free flight makes it easy to drift into empty space; Reset flies back to the preset pose.
	_menu.add_action("↺", "Reset", _reset_view)
	_menu.add_action("🎲", "Preset", _random_preset)

	_menu.add_debug_toggle("⚡", "Adaptive quality", _adaptive,
		_set_adaptive)
	_menu.add_debug_toggle("🎞", "Post-FX", _post_enabled,
		func(on: bool) -> void: _set_post_enabled(on))


func _reset_view() -> void:
	var list: Array = PRESETS[_params["fractal_type"]]
	_apply_preset(list[clampi(_preset_option.selected, 0, list.size() - 1)])


func _random_preset() -> void:
	var list: Array = PRESETS[_params["fractal_type"]]
	if list.size() < 2:
		_reset_view()
		return
	var idx := randi() % list.size()
	if idx == _preset_option.selected:
		idx = (idx + 1) % list.size()
	_preset_option.select(idx)
	_preset_option.item_selected.emit(idx)


func _build_param_groups() -> void:
	var g0 := _menu.add_group()
	_sliders["apollonian_scale"] = _menu.add_slider("Packing", 1.0, 2.5, _params["apollonian_scale"], _set_packing)
	_menu.add_toggle("Animate packing", _animate_packing, _set_animate_packing)
	_menu.end_group()
	_param_groups[0] = g0

	var g1 := _menu.add_group()
	_menu.add_label("Menger: adjust Detail.")
	_menu.end_group()
	_param_groups[1] = g1

	var g2 := _menu.add_group()
	_sliders["klein_r"] = _menu.add_slider("Klein R", 1.8, 1.96, _params["klein_r"], func(v: float) -> void: _set_param("klein_r", v))
	_sliders["klein_i"] = _menu.add_slider("Klein I", -0.2, 0.2, _params["klein_i"], func(v: float) -> void: _set_param("klein_i", v))
	_sliders["klein_box_x"] = _menu.add_slider("Box X", 0.3, 2.0, _params["klein_box_x"], func(v: float) -> void: _set_param("klein_box_x", v))
	_sliders["klein_box_z"] = _menu.add_slider("Box Z", 0.3, 2.0, _params["klein_box_z"], func(v: float) -> void: _set_param("klein_box_z", v))
	_menu.end_group()
	_param_groups[2] = g2


func _select_fractal(idx: int) -> void:
	_cache_quality()
	_params["fractal_type"] = idx
	for key in _param_groups:
		(_param_groups[key] as Control).visible = (key == idx)

	_preset_option.clear()
	var list: Array = PRESETS[idx]
	for i in list.size():
		_preset_option.add_item(str(list[i]["name"]), i)
	_preset_index = 0
	_preset_option.select(0)
	_apply_preset(list[0])


func _on_preset_selected(idx: int) -> void:
	var list: Array = PRESETS[_params["fractal_type"]]
	if idx >= 0 and idx < list.size():
		_cache_quality()
		_preset_index = idx
		_apply_preset(list[idx])


func _on_palette_selected(idx: int) -> void:
	_set_param("palette", idx)


func _apply_preset(preset: Dictionary) -> void:
	_applying_preset = true
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
	_packing_center = float(_params["apollonian_scale"])
	_applying_preset = false
	_reset_effective_quality()
	_push()


# --- Parameter push ------------------------------------------------------------

func _set_param(key: String, value: Variant) -> void:
	_params[key] = value
	if not _applying_preset and (key == "iterations" or key == "max_steps"):
		_reset_effective_quality(true)
	_push()


func _set_packing(value: float) -> void:
	if not _updating_packing:
		_packing_center = value
	_set_param("apollonian_scale", value)


func _set_animate_packing(on: bool) -> void:
	_animate_packing = on
	_packing_animation_time = 0.0
	_packing_center = float(_params["apollonian_scale"])


func _update_packing_animation(delta: float) -> void:
	if not _animate_packing or int(_params.get("fractal_type", 0)) != 0:
		return
	_packing_animation_time += delta
	var value := clampf(_packing_center + sin(_packing_animation_time * 0.55) * 0.3, 1.0, 2.5)
	_updating_packing = true
	(_sliders["apollonian_scale"] as HSlider).value = value
	_updating_packing = false


func _set_render_scale(v: float) -> void:
	_render_scale = v
	_reset_effective_quality(true)
	_apply_effective_quality()


func _set_fov(v: float) -> void:
	_camera.set_fov(v)
	_apply_effective_quality()


func _push() -> void:
	for key in _params:
		if key == "iterations" or key == "max_steps":
			continue
		_material.set_shader_parameter(key, _params[key])
	_apply_effective_quality()


func _set_quality_profile(index: int) -> void:
	_cache_quality()
	_quality_profile = clampi(index, 0, QUALITY_PROFILES.size() - 1)
	_reset_effective_quality()
	_apply_effective_quality()


func _set_adaptive(on: bool) -> void:
	_adaptive = on
	_reset_effective_quality(true)
	_apply_effective_quality()


func _quality_key() -> String:
	return "%d:%d:%d" % [_params.get("fractal_type", 0), _preset_index, _quality_profile]


func _cache_quality() -> void:
	if _params.is_empty():
		return
	_quality_cache[_quality_key()] = {
		"scale": _effective_scale,
		"steps": _effective_steps,
		"iterations": _effective_iterations,
	}


func _reset_effective_quality(keep_current := false) -> void:
	var requested_steps: int = _params.get("max_steps", 160)
	var requested_iterations: int = _params.get("iterations", 12)
	if not _adaptive:
		_effective_scale = _render_scale
		_effective_steps = requested_steps
		_effective_iterations = requested_iterations
	elif keep_current:
		_effective_scale = minf(_effective_scale, _render_scale)
		_effective_steps = mini(_effective_steps, requested_steps)
		_effective_iterations = mini(_effective_iterations, requested_iterations)
	elif _quality_cache.has(_quality_key()):
		var cached: Dictionary = _quality_cache[_quality_key()]
		_effective_scale = minf(float(cached["scale"]), _render_scale)
		_effective_steps = mini(int(cached["steps"]), requested_steps)
		_effective_iterations = mini(int(cached["iterations"]), requested_iterations)
	elif int(_params.get("fractal_type", 0)) == 2:
		var profile: Dictionary = QUALITY_PROFILES[_quality_profile]
		var fractal_type: int = _params.get("fractal_type", 0)
		_effective_scale = minf(_render_scale, float((profile["start_scales"] as Array)[fractal_type]))
		_effective_steps = mini(requested_steps, int((profile["step_floors"] as Array)[fractal_type]))
		_effective_iterations = mini(requested_iterations, int((profile["iteration_floors"] as Array)[2]))
	else:
		_effective_scale = _render_scale
		_effective_steps = requested_steps
		_effective_iterations = requested_iterations
	_quality_warmup = QUALITY_WARMUP_FRAMES
	_quality_timer = 0.0
	_headroom_time = 0.0
	_frame_time_ema = 0.0


func _update_adaptive_quality() -> void:
	var profile: Dictionary = QUALITY_PROFILES[_quality_profile]
	var target_time := 1.0 / float(profile["target_fps"])
	var slow_limit := target_time * (1.0 if _camera.motion_intensity > 0.05 else 1.1)
	if _frame_time_ema > slow_limit:
		_headroom_time = 0.0
		_lower_quality(profile)
	elif _frame_time_ema < target_time * 0.9:
		_headroom_time += QUALITY_INTERVAL
		if _headroom_time >= QUALITY_RECOVERY_DELAY:
			_raise_quality()
			_headroom_time = 0.0
	else:
		_headroom_time = 0.0


func _lower_quality(profile: Dictionary) -> void:
	var changed := false
	var fractal_type: int = _params["fractal_type"]
	var min_scale: float = (profile["scale_floors"] as Array)[fractal_type]
	var min_steps: int = (profile["step_floors"] as Array)[fractal_type]
	if _effective_scale > min_scale + 0.001:
		_effective_scale = maxf(min_scale, _effective_scale - 0.05)
		changed = true
	elif _effective_steps > min_steps:
		_effective_steps = maxi(min_steps, _effective_steps - 10)
		changed = true
	else:
		var floor_iterations: int = (profile["iteration_floors"] as Array)[fractal_type]
		if _effective_iterations > floor_iterations:
			_effective_iterations -= 1
			changed = true
	if changed:
		_apply_effective_quality()
		_cache_quality()


func _raise_quality() -> void:
	var requested_iterations: int = _params["iterations"]
	var requested_steps: int = _params["max_steps"]
	if _effective_scale < _render_scale - 0.001:
		_effective_scale = minf(_render_scale, _effective_scale + 0.05)
	elif _effective_steps < requested_steps:
		_effective_steps = mini(requested_steps, _effective_steps + 20)
	elif _effective_iterations < requested_iterations:
		_effective_iterations += 1
	else:
		return
	_apply_effective_quality()
	_cache_quality()


func _apply_effective_quality() -> void:
	if not _material:
		return
	_material.set_shader_parameter("iterations", _effective_iterations)
	_material.set_shader_parameter("max_steps", _effective_steps)
	var profile: Dictionary = QUALITY_PROFILES[_quality_profile]
	_material.set_shader_parameter("ao_samples", int(profile["ao_samples"]) if _adaptive else 5)
	_material.set_shader_parameter("pixel_tolerance", float(profile["pixel_tolerance"]) if _adaptive else 0.08)
	get_viewport().scaling_3d_scale = _effective_scale
	var internal_height := maxf(get_viewport().get_visible_rect().size.y * _effective_scale, 1.0)
	var pixel_angle := 2.0 * tan(deg_to_rad(_camera.fov) * 0.5) / internal_height
	_material.set_shader_parameter("pixel_angle", pixel_angle)
	_update_quality_label()


func _update_quality_label() -> void:
	if not _quality_label:
		return
	var fps := 0.0 if _frame_time_ema <= 0.0 else 1.0 / _frame_time_ema
	_quality_label.text = "Effective: %d%% · %d steps · %d iter · %.0f FPS" % [
		int(round(_effective_scale * 100.0)), _effective_steps, _effective_iterations, fps]


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
