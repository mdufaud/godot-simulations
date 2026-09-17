class_name FractalMenu extends RefCounted
## Settings panel of the 2D fractal explorer, plus the live zoom / iteration /
## state readout. Writes straight into the camera, the view and the autopilot.

var _camera: FractalCamera
var _view: FractalView
var _autopilot: FractalAutopilot
var _on_reset: Callable
var _quality: SimQualityState

var _zoom_label: Label
var _iterations_label: Label
var _state_label: Label
var _label_timer := 0.0


func _init(camera: FractalCamera, view: FractalView, autopilot: FractalAutopilot,
		on_reset: Callable, quality: SimQualityState) -> void:
	_camera = camera
	_view = view
	_autopilot = autopilot
	_on_reset = on_reset
	_quality = quality


func build(menu: SimMenu) -> void:
	menu.title = "2D Fractal Explorer"

	menu.add_separator()
	menu.add_section("Fractal")
	menu.add_option_button("Type", ["Mandelbrot", "Julia", "Burning Ship", "Tricorn"], 0,
		func(index: int) -> void:
			_camera.fractal_type = index
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
	menu.add_action_toggle("🎬", "Auto", _autopilot.enabled, func(on: bool) -> void:
		_autopilot.enabled = on
		if on:
			_autopilot.restart()
			_camera.clear_anchor()
			_camera.target_log_zoom = _camera.log_zoom
	)
	menu.add_action_toggle("🌀", "Morph", _view.julia_morph, _view.set_julia_morph)

	menu.add_separator()
	menu.add_section("Color")
	menu.add_option_button("Mode", ["Cosmic", "Orbit Trap", "HSV Cycle", "Thermal"], 0,
		func(index: int) -> void: _view.set_display_parameter("color_mode", index))
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
	var aa_slider: HSlider = menu.add_slider("Anti-Alias", 1, 3, float(_view.aa_quality),
		func(value: float) -> void: _view.aa_quality = int(value))
	_quality.bind("aa_quality", aa_slider,
		func(value: float) -> void: _view.aa_quality = int(value))
	var band_slider: HSlider = menu.add_slider("Refine band", 32.0, 4096.0,
		float(_view.config.refine_band_rows),
		func(value: float) -> void: _view.config.refine_band_rows = int(value))
	_quality.bind("refine_band_rows", band_slider,
		func(value: float) -> void: _view.config.refine_band_rows = int(value))
	_quality.attach_menu_option(menu)
	menu.add_toggle("Auto Iterations", _camera.auto_iterations,
		func(on: bool) -> void: _camera.auto_iterations = on)
	menu.add_slider("Max Iterations", 100, 20000, float(_camera.manual_iterations),
		func(value: float) -> void: _camera.manual_iterations = int(value))

	menu.add_separator()
	menu.add_section("Info")
	_zoom_label = menu.add_label("Zoom: 1.00e+00")
	_iterations_label = menu.add_label("Iterations: 0")
	_state_label = menu.add_label("State: idle")


## Refreshed ten times a second: the numbers move faster than they can be read.
func update_labels(delta: float) -> void:
	_label_timer += delta
	if _label_timer < 0.1:
		return
	_label_timer = 0.0
	_zoom_label.text = "Zoom: " + _format_zoom(_camera.zoom())
	_iterations_label.text = "Iterations: %d" % _camera.iterations_full()
	match _view.state:
		FractalView.State.MOVING:
			_state_label.text = "State: rendering"
		FractalView.State.REFINING:
			_state_label.text = "State: refining %d%%" % mini(
				int(100.0 * _view.refine_progress()), 100)
		FractalView.State.IDLE:
			_state_label.text = "State: idle"


func _format_zoom(zoom: float) -> String:
	if zoom < 1000.0:
		return "%.1f" % zoom
	var exponent := int(floor(log(zoom) / FractalCamera.LN10))
	var mantissa := zoom / pow(10.0, exponent)
	return "%.2fe%d" % [mantissa, exponent]
