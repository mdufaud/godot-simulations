class_name FractalMenu extends RefCounted
## Settings panel of the 2D fractal explorer, plus the live zoom / iteration /
## state readout. Writes straight into the camera, the view and the autopilot.

var _camera: FractalCamera
var _view: FractalView
var _autopilot: FractalAutopilot
var _on_reset: Callable

var _zoom_label: Label
var _iterations_label: Label
var _state_label: Label
var _morph_button: Button
var _label_timer := 0.0


func _init(camera: FractalCamera, view: FractalView, autopilot: FractalAutopilot,
		on_reset: Callable) -> void:
	_camera = camera
	_view = view
	_autopilot = autopilot
	_on_reset = on_reset


# Not a member: quality keeps the lambdas below, which capture self.
func build(menu: SimMenu, quality: SimQualityState) -> void:
	menu.title = "2D Fractal Explorer"

	menu.add_separator()
	menu.add_section("Fractal")
	var type_option: OptionButton = menu.add_option_button("Type",
		["Mandelbrot", "Julia", "Burning Ship", "Tricorn"], 0,
		func(index: int) -> void:
			_camera.fractal_type = index
			# A restored selection fires while the menu is still being built.
			if _morph_button != null:
				_morph_button.visible = index == 1
			_autopilot.pick(0)
			_on_reset.call()
	)

	menu.add_separator()
	menu.add_section("Julia")
	menu.add_slider("Julia Re", -2.0, 2.0, _view.julia_re,
		func(value: float) -> void: _view.julia_re = value)
	menu.add_slider("Julia Im", -2.0, 2.0, _view.julia_im,
		func(value: float) -> void: _view.julia_im = value)

	menu.add_separator()
	menu.add_section("Navigation")
	menu.add_slider("Dive Speed", 0.1, 1.5, _autopilot.speed,
		func(value: float) -> void: _autopilot.speed = value)

	menu.add_action("↺", "Reset", _on_reset)
	menu.add_action("🔷", "Shape", func() -> void: _cycle_option(type_option))
	menu.add_action_toggle("🎬", "Auto", _autopilot.enabled, func(on: bool) -> void:
		_autopilot.enabled = on
		if on:
			_autopilot.restart()
			_camera.clear_anchor()
			_camera.target_log_zoom = _camera.log_zoom
	)
	# Morphing only moves the Julia constant: the action shows for Julia alone.
	_morph_button = menu.add_action_toggle("🌀", "Morph", _view.julia_morph,
		_view.set_julia_morph)
	_morph_button.visible = _camera.fractal_type == 1

	menu.add_separator()
	menu.add_section("Color")
	var color_option: OptionButton = menu.add_option_button("Mode",
		["Cosmic", "Orbit Trap", "HSV Cycle", "Thermal"], 0,
		func(index: int) -> void: _view.set_display_parameter("color_mode", index))
	menu.add_action("🎨", "Colors", func() -> void: _cycle_option(color_option))
	menu.add_slider("Speed", 0.0, 5.0, 0.3,
		func(value: float) -> void: _view.set_display_parameter("color_speed", value))
	menu.add_slider("Offset", 0.0, 1.0, 0.0,
		func(value: float) -> void: _view.set_display_parameter("color_offset", value))
	menu.add_slider("Edge Shade", 0.0, 1.0, 0.35,
		func(value: float) -> void: _view.set_display_parameter("edge_strength", value))

	menu.add_separator()
	menu.add_section("Orbit Trap")
	menu.add_option_button("Shape", ["Circle", "Line", "Cross", "Flower"], 0,
		func(index: int) -> void: _view.trap_shape = index)
	menu.add_slider("Scale", 0.1, 5.0, _view.trap_scale,
		func(value: float) -> void: _view.trap_scale = value)

	menu.add_separator()
	menu.add_section("Quality")
	var aa_slider: HSlider = menu.add_slider("AA Samples", 1, 64, float(_view.aa_samples),
		func(value: float) -> void: _view.aa_samples = int(value))
	quality.bind("aa_samples", aa_slider,
		func(value: float) -> void: _view.aa_samples = int(value))
	var budget_slider: HSlider = menu.add_slider("GPU ms / frame", 1.0, 30.0,
		_view.config.sample_budget_ms,
		func(value: float) -> void: _view.config.sample_budget_ms = value)
	quality.bind("sample_budget_ms", budget_slider,
		func(value: float) -> void: _view.config.sample_budget_ms = value)
	quality.attach_menu_option(menu)
	menu.add_toggle("Auto Iterations", _camera.auto_iterations,
		func(on: bool) -> void: _camera.auto_iterations = on)
	menu.add_slider("Max Iterations", 100, FractalCamera.MAX_ITERATIONS,
		float(_camera.manual_iterations),
		func(value: float) -> void: _camera.manual_iterations = int(value))

	menu.add_separator()
	menu.add_section("Info")
	_zoom_label = menu.add_label("Zoom: 1.00e+00")
	_iterations_label = menu.add_label("Iterations: 0")
	_state_label = menu.add_label("State: idle")


## Selects the next item of a menu dropdown, as if picked by hand.
func _cycle_option(option: OptionButton) -> void:
	var index := (option.selected + 1) % option.item_count
	option.select(index)
	option.item_selected.emit(index)


## Refreshed ten times a second: the numbers move faster than they can be read.
func update_labels(delta: float) -> void:
	_label_timer += delta
	if _label_timer < 0.1:
		return
	_label_timer = 0.0
	_zoom_label.text = "Zoom: " + _format_zoom(_camera.zoom())
	_iterations_label.text = "Iterations: %d" % _camera.iterations_full()
	var stride := _view.sample_stride()
	match _view.state:
		FractalView.State.MOVING:
			_state_label.text = "State: moving, 1/%d px per frame" % (stride * stride)
		FractalView.State.REFINING:
			_state_label.text = "State: refining %d%%, 1/%d px per frame" % [mini(
				int(100.0 * _view.refine_progress()), 100), stride * stride]
		FractalView.State.IDLE:
			_state_label.text = "State: idle"


func _format_zoom(zoom: float) -> String:
	if zoom < 1000.0:
		return "%.1f" % zoom
	var exponent := int(floor(log(zoom) / FractalCamera.LN10))
	var mantissa := zoom / pow(10.0, exponent)
	return "%.2fe%d" % [mantissa, exponent]
