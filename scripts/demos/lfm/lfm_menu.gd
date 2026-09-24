class_name LfmMenu extends RefCounted

var status: Label
var preset_button: OptionButton
var method_button: OptionButton
var view_button: OptionButton
var quality_button: OptionButton
var reinit_slider: HSlider
var clamp_toggle: CheckButton
var inlet_speed_slider: HSlider
var inlet_angle_slider: HSlider
var render_scale_slider: HSlider
var reset_button: Button


func build(host: Node3D) -> void:
	var menu: SimMenu = host.menu
	menu.title = "Leapfrog Flow Maps 3D"
	menu.add_section("Simulation")
	preset_button = menu.add_option_button("Preset", ["Wind tunnel", "Vortex ring"], 0,
		host.apply_preset)
	method_button = menu.add_option_button("Method", ["LFM", "Semi-Lagrangian"], 0,
		host.set_method)
	view_button = menu.add_option_button("View", ["Density", "Vorticity"], 1, host.set_view)
	reset_button = menu.add_button("Reset", host.reset_simulation)
	reinit_slider = menu.add_slider("Reinitialize every", 2.0, 10.0, 5.0,
		host.set_reinit_every, false, 1.0)
	clamp_toggle = menu.add_toggle("BFECC clamp", true, host.set_bfecc_clamp, false)
	inlet_speed_slider = menu.add_slider("Inlet speed (m/s)", 0.0, 2.0, 0.6,
		host.set_inlet_speed, false)
	inlet_angle_slider = menu.add_slider("Inlet angle (deg)", -45.0, 45.0, 20.0,
		host.set_inlet_angle, false, 1.0)
	quality_button = menu.add_option_button("Quality", ["Low (fast) 64×32×32", "Medium 128×64×64",
		"High 192×96×96"], 1, host.set_quality_profile)
	render_scale_slider = menu.add_slider("Render scale", 0.5, 1.0, 0.5,
		host.set_render_scale)
	status = menu.add_label("Initializing GPU solver…")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func sync_preset(config: LfmConfig, preset_index: int, quality_index: int,
		view_index: int) -> void:
	preset_button.select(preset_index)
	quality_button.select(quality_index)
	view_button.select(view_index)
	_sync_slider(reinit_slider, config.reinit_every)
	clamp_toggle.set_pressed_no_signal(config.bfecc_clamp)
	_sync_slider(inlet_speed_slider, config.inlet_speed_mps)
	_sync_slider(inlet_angle_slider, config.inlet_angle_deg)
	var has_inlet := config.scenario == LfmConfig.Scenario.WIND_TUNNEL
	inlet_speed_slider.editable = has_inlet
	inlet_angle_slider.editable = has_inlet


func _sync_slider(slider: HSlider, value: float) -> void:
	slider.set_value_no_signal(value)
	var value_label := slider.get_parent().get_child(2) as Label
	value_label.text = "%d" % int(round(value)) if slider.step >= 1.0 else "%.2f" % value
