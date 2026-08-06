class_name ParallaxMenu extends RefCounted
## Settings panel of the parallax demo. Slider and toggle callbacks write
## straight into the live [ParallaxConfig]; the host is only called back for the
## two changes it has to act on itself (surface preset, mesh swap).

var _settings: ParallaxConfig
var _on_changed: Callable
var _on_preset: Callable
var _on_mesh: Callable

var _height_slider: HSlider
var _min_layers_slider: HSlider
var _max_layers_slider: HSlider
var _uv_scale_slider: HSlider
var _normal_slider: HSlider
var _roughness_slider: HSlider
var _shadow_slider: HSlider
var _mode_option: OptionButton
var _preset_option: OptionButton
var _mesh_option: OptionButton


func _init(settings: ParallaxConfig, on_changed: Callable, on_preset: Callable,
		on_mesh: Callable) -> void:
	_settings = settings
	_on_changed = on_changed
	_on_preset = on_preset
	_on_mesh = on_mesh


func build(menu: SimMenu, preset_names: Array) -> void:
	menu.title = "🪨 Parallax Mapping"

	menu.add_section("Surface")
	_mode_option = menu.add_option_button("Render Mode",
		["Flat (no relief)", "Normal Map Only", "Parallax (POM)"], _settings.display_mode,
		func(index: int) -> void:
			_settings.display_mode = index
			_on_changed.call()
	)
	_preset_option = menu.add_option_button("Preset", preset_names, 0, _on_preset)
	_mesh_option = menu.add_option_button("Mesh", ["Plane", "Cube"], 0, _on_mesh)

	menu.add_section("Relief")
	_height_slider = menu.add_slider("Height", 0.005, 0.4, 0.04,
		func(value: float) -> void:
			_settings.height_scale = value
			_on_changed.call()
	)
	_min_layers_slider = menu.add_slider("Min Layers", 4.0, 64.0, 8.0,
		func(value: float) -> void:
			_settings.min_layer_count = int(value)
			if _settings.min_layer_count > _settings.max_layer_count:
				_max_layers_slider.value = value
			_on_changed.call()
	)
	_max_layers_slider = menu.add_slider("Max Layers", 8.0, 128.0, 32.0,
		func(value: float) -> void:
			_settings.max_layer_count = int(value)
			if _settings.max_layer_count < _settings.min_layer_count:
				_min_layers_slider.value = value
			_on_changed.call()
	)
	_uv_scale_slider = menu.add_slider("UV Scale", 0.5, 8.0, 2.0,
		func(value: float) -> void:
			_settings.uv_scale = value
			_on_changed.call()
	)
	_normal_slider = menu.add_slider("Normal Strength", 0.0, 2.0, 1.0,
		func(value: float) -> void:
			_settings.normal_strength = value
			_on_changed.call()
	)
	_roughness_slider = menu.add_slider("Roughness", 0.0, 1.0, 0.8,
		func(value: float) -> void:
			_settings.roughness = value
			_on_changed.call()
	)

	menu.add_section("Shadow")
	_shadow_slider = menu.add_slider("Shadow Strength", 0.0, 2.0, 0.8,
		func(value: float) -> void:
			_settings.shadow_strength = value
			_on_changed.call()
	)

	# Flipping relief on and off is the comparison this demo exists for.
	menu.add_action("🪨", "Relief", func() -> void: _cycle(_mode_option))
	menu.add_action("🎨", "Preset", func() -> void: _cycle(_preset_option))
	menu.add_action("🧊", "Mesh", func() -> void: _cycle(_mesh_option))

	menu.add_debug_toggle("🌑", "Self-shadowing", true,
		func(pressed: bool) -> void:
			_settings.self_shadow_enabled = pressed
			_on_changed.call()
	)
	menu.add_debug_toggle("🧭", "Heightmap normals", false,
		func(pressed: bool) -> void:
			_settings.computed_normals = pressed
			_on_changed.call()
	)


## Drives the sliders from the settings, which re-fires their callbacks and so
## persists the new values.
func sync_sliders() -> void:
	_height_slider.value = _settings.height_scale
	_min_layers_slider.value = _settings.min_layer_count
	_max_layers_slider.value = _settings.max_layer_count
	_uv_scale_slider.value = _settings.uv_scale
	_normal_slider.value = _settings.normal_strength
	_roughness_slider.value = _settings.roughness
	_shadow_slider.value = _settings.shadow_strength


## Steps a panel dropdown from the action strip; emitting keeps it persisted and in sync.
func _cycle(option: OptionButton) -> void:
	if option == null:
		return
	var next := (option.selected + 1) % option.item_count
	option.select(next)
	option.item_selected.emit(next)
