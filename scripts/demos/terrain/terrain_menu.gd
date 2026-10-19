class_name TerrainMenu extends RefCounted
## SimMenu panel of the Water & Stone demo. The brush buttons behave as a radio
## group, so they live here rather than being rebuilt by the controller.
##
## Physics widgets do NOT persist: their values describe the active preset's
## world, so a saved value must never override what a scene switch just set
## up. Generation sliders preserve user preferences. [method sync_params] pushes the
## solver's current state back into the widgets after every restart.

var solver: HeightfieldTerrain
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, restart, select_tool, set_auto_pour, set_auto_water,
## set_strength, set_brush_size, set_repose, set_water_flow, set_erosion,
## set_sediment_capacity, set_stochasticity, set_evaporation, set_snow_repose,
## set_rain, set_deposition, set_snowline, set_uplift_rate, set_uplift_mode,
## set_uplift_radius, set_snow_flow, set_melt, set_snowfall, set_freeze,
## set_grid_n, set_mesh_n,
## set_render_scale, render_scale, set_balls_enabled, expose the
## SimQualityState named quality and the balls_enabled flag.
var host: Node

var _status: Label
var _hint: Label
var _tool_hint: Label
var _menu: SimMenu
var _tool_buttons := {}
var _balls_toggle: Button
var _preset_option: OptionButton
var _uplift_option: OptionButton
var _mountain_actions: Array[Button] = []
var _mountain_sections: Array = []
var _legacy_sections: Array = []
var _regenerate_action: Button
var _rain_action: Button
var _erosion_action: Button
var _summit_toggle: Button
var _drying_toggle: Button
var _summit_rate: SpinBox
var _summit_rate_row: Control
var _infiltration_rate: SpinBox
var _brush_slider: HSlider
var _snowline_slider: HSlider
var _auto_buttons: Array[Button] = []
## [slider, getter] pairs sync_params pushes solver state through after a
## preset switch. Label keys would collide ("Flow rate" in Sand and Water).
var _sync_entries := []


func build(menu: SimMenu, presets: Array, preset_idx: int, tool_choice: int,
		strength: float, auto_pour: bool) -> void:
	_menu = menu
	var titles: Array = []
	for preset in presets:
		var typed: TerrainPreset = preset
		titles.append(typed.display_name)

	var scene_section := menu.add_section("Scene")
	scene_section.button_pressed = true
	_preset_option = menu.add_option_button("Preset", titles, preset_idx, host.apply_preset)
	menu.add_action("🏞️", "Scene", host.cycle_preset)
	_regenerate_action = menu.add_button("Reset", host.regenerate)
	_rain_action = menu.add_action_toggle("🌧️", "Rain", host.rain_enabled,
		host.set_rain_enabled)
	_mountain_actions.append(_rain_action)
	_erosion_action = menu.add_action_toggle("🪨", "Erosion", host.erosion_running,
		host.set_erosion_running)
	_mountain_actions.append(_erosion_action)
	_drying_toggle = menu.add_action_toggle("💧", "Drying", host.drying_enabled, host.set_drying)
	_status = menu.add_label("")
	_hint = menu.add_label("")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_separator()
	var terrain_header := menu.add_section("Terrain")
	terrain_header.button_pressed = true
	_mountain_sections.append([terrain_header, menu._section_body])
	_generation_slider(menu, "Terrain size m", 1.0, 2000.0, 64.0,
		host.set_mountain_size, func(): return host.mountain_world_size_m, 1.0)
	_generation_slider(menu, "Elevation m", 0.1, 1000.0, 12.0,
		host.set_mountain_height, func(): return host.mountain_height_m, 0.1)
	_generation_slider(menu, "Mountain density", 0.5, 8.0, 2.4,
		host.set_mountain_density, func(): return host.mountain_density, 0.1)
	_generation_slider(menu, "Ruggedness", 0.1, 0.7, 0.46,
		host.set_mountain_ruggedness, func(): return host.mountain_ruggedness, 0.01)
	_generation_slider(menu, "Valley width", 0.04, 0.35, 0.16,
		host.set_mountain_valley_width, func(): return host.mountain_valley_width_fraction, 0.01)
	_generation_slider(menu, "Valley depth", 0.0, 0.95, 0.72,
		host.set_mountain_valley_depth, func(): return host.mountain_valley_depth_fraction, 0.01)
	_generation_slider(menu, "Ridge irregularity", 0.0, 0.3, 0.12,
		host.set_mountain_ridge_irregularity, func(): return host.mountain_ridge_irregularity, 0.01)
	_generation_slider(menu, "Surface detail", 0.0, 2.0, 1.0,
		host.set_mountain_surface_detail, func(): return host.mountain_surface_detail, 0.01)
	menu.add_label("Saved settings apply on New terrain.")
	menu.add_separator()

	menu.add_section("Tool")
	_brush_slider = _slider(menu, "Brush size", 0.08, 4.8, solver.brush.radius_m, host.set_brush_size,
		func(): return solver.brush.radius_m)
	_slider(menu, "Strength", 0.3, 3.0, strength, host.set_strength)
	_tool_hint = menu.add_label("Right-click drag sculpts · Pack compacts snow")

	# The brush is switched mid-sculpt, so it belongs in the strip rather than the panel.
	for entry in [
		["⛰", "Raise mountain", TerrainBrush.MOUNTAIN],
		["⛏", "Dig", TerrainBrush.DIG],
		["🚿", "Pour", TerrainBrush.POUR],
		["🫓", "Flatten", TerrainBrush.SMOOTH],
		["💧", "Water", TerrainBrush.WATER],
		["❄️", "Snow", TerrainBrush.SNOW],
		["🥾", "Pack", TerrainBrush.PACK],
	]:
		var mode: int = entry[2]
		var button := menu.add_action_toggle(entry[0], entry[1], tool_choice == mode,
			func(on: bool) -> void:
				if on:
					host.select_tool(mode)
				else:
					sync_tool(host.tool_choice))
		_tool_buttons[mode] = button
	_auto_buttons.append(menu.add_action_toggle("🏖️", "Auto sand", auto_pour, host.set_auto_pour))
	_auto_buttons.append(menu.add_action_toggle("🌊", "Auto water", host.auto_water, host.set_auto_water))
	menu.add_separator()

	_add_section(menu, "Props", false)
	_balls_toggle = menu.add_action_toggle("⚽", "Balls", host.balls_enabled,
		host.set_balls_enabled)
	menu.add_label("Grab a ball with left-click")
	menu.add_separator()

	_add_section(menu, "Sand", false)
	_slider(menu, "Repose angle °", 20.0, 45.0, solver.repose_deg, host.set_repose,
		func(): return solver.repose_deg)
	_slider(menu, "Flow rate", 0.03, 0.12, solver.flow_rate,
		func(v: float): solver.flow_rate = v,
		func(): return solver.flow_rate)
	var iterations_slider := _slider(menu, "Settle iterations", 2.0, 16.0,
		float(solver.iterations),
		func(v: float): solver.iterations = int(round(v)),
		func(): return float(solver.iterations))
	host.quality.bind("iterations", iterations_slider,
		func(v: float): solver.iterations = int(round(v)))
	menu.add_separator()

	menu.add_section("Erosion")
	_summit_toggle = menu.add_toggle("Summit sources", host.summit_water,
		host.set_summit_water, false)
	_summit_rate = _rate_input(menu, "Summit flow m/s", host.summit_rate_m_s,
		host.set_summit_rate, func(): return host.summit_rate_m_s)
	_summit_rate_row = _summit_rate.get_parent()
	_infiltration_rate = _rate_input(menu, "Infiltration m/s", host.drying_rate_m_s,
		host.set_drying_rate, func(): return host.drying_rate_m_s)
	_infiltration_rate.get_parent().visible = false
	_slider(menu, "Conductance", 0.05, 0.9, solver.water_flow_rate, host.set_water_flow,
		func(): return solver.water_flow_rate)
	_slider(menu, "Erosion strength", 0.0, 2.0,
		host.mountain_erosion_rate if host.preset_idx == 9 else solver.erosion_rate,
		host.set_erosion,
		func(): return host.mountain_erosion_rate if host.preset_idx == 9 else solver.erosion_rate)
	_slider(menu, "Sediment capacity", 0.0, 3.0, solver.sediment_capacity,
		host.set_sediment_capacity,
		func(): return solver.sediment_capacity)
	_slider(menu, "Meandering", 0.0, 0.4, solver.stochasticity, host.set_stochasticity,
		func(): return solver.stochasticity)
	_slider(menu, "Evaporation m/s", 0.0, 0.1, solver.evap_rate_m_s, host.set_evaporation,
		func(): return solver.evap_rate_m_s)
	_slider(menu, "Rain m/s", 0.0, 0.02,
		host.mountain_rain_rate_m_s if host.preset_idx == 9 else solver.rain_rate_m_s,
		host.set_rain,
		func(): return host.mountain_rain_rate_m_s if host.preset_idx == 9 else solver.rain_rate_m_s)
	_slider(menu, "Deposition", 0.0, 2.0, solver.deposition_gain, host.set_deposition,
		func(): return solver.deposition_gain)
	menu.add_separator()

	_add_section(menu, "Snow", false)
	_slider(menu, "Cohesion angle °", 5.0, 75.0, solver.snow_repose_deg, host.set_snow_repose,
		func(): return solver.snow_repose_deg)
	_slider(menu, "Creep rate", 0.01, 1.5, solver.snow_flow_rate, host.set_snow_flow,
		func(): return solver.snow_flow_rate)
	_slider(menu, "Melt m/s", 0.0, 0.1, solver.melt_rate_m_s, host.set_melt,
		func(): return solver.melt_rate_m_s)
	_slider(menu, "Snowfall m/s", 0.0, 0.01, solver.snowfall_rate_m_s, host.set_snowfall,
		func(): return solver.snowfall_rate_m_s)
	_slider(menu, "Freeze m/s", 0.0, 0.01, solver.freeze_rate_m_s, host.set_freeze,
		func(): return solver.freeze_rate_m_s)
	_snowline_slider = _slider(menu, "Snowline m", -1.0, 12.0, solver.snowline_m, host.set_snowline,
		func(): return solver.snowline_m)
	_slider(menu, "Uplift rate m/s", 0.0, 0.2, solver.uplift_rate_m_s, host.set_uplift_rate,
		func(): return solver.uplift_rate_m_s)
	_uplift_option = menu.add_option_button("Uplift profile", ["None", "Dome", "Noise"],
		solver.uplift_mode, host.set_uplift_mode, false)
	_slider(menu, "Uplift radius", 0.01, 1.0, solver.uplift_radius_fraction,
		host.set_uplift_radius, func(): return solver.uplift_radius_fraction)
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	var grid_labels: Array = []
	for n in TerrainQualityProfile.GRID_SIZES:
		grid_labels.append("%d²" % n)
	var grid_option := menu.add_option_button("Grid resolution", grid_labels,
		TerrainQualityProfile.GRID_SIZES.find(solver.grid_n),
		func(idx: int): host.set_grid_n(TerrainQualityProfile.GRID_SIZES[idx]), false)
	host.quality.bind("grid_n", grid_option, host.set_grid_n,
		func(n: int) -> int: return TerrainQualityProfile.GRID_SIZES.find(n))
	var mesh_labels: Array = []
	for n in TerrainQualityProfile.MESH_SIZES:
		mesh_labels.append("%d²" % n)
	var mesh_option := menu.add_option_button("Visual mesh", mesh_labels,
		TerrainQualityProfile.MESH_SIZES.find(host.mesh_n),
		func(idx: int): host.set_mesh_n(TerrainQualityProfile.MESH_SIZES[idx]), false)
	host.quality.bind("mesh_n", mesh_option, host.set_mesh_n,
		func(n: int) -> int: return TerrainQualityProfile.MESH_SIZES.find(n))
	host.quality.attach_menu_option(menu)
	_slider(menu, "Render scale", 0.4, 1.0,
		host.render_scale(), host.set_render_scale)


## Registers a non-persisting slider. [param getter] feeds sync_params.
func _slider(menu: SimMenu, label_text: String, min_val: float, max_val: float,
		value: float, cb: Callable, getter := Callable()) -> HSlider:
	var slider := menu.add_slider(label_text, min_val, max_val, value, cb, false)
	if getter.is_valid():
		_sync_entries.append([slider, getter])
	return slider


func _add_section(menu: SimMenu, title: String, mountain_only: bool) -> Button:
	var header := menu.add_section(title)
	var section := [header, menu._section_body]
	if mountain_only:
		_mountain_sections.append(section)
	else:
		_legacy_sections.append(section)
	return header


func _generation_slider(menu: SimMenu, label_text: String, min_value: float,
		max_value: float, factory_default: float, cb: Callable, getter: Callable,
		step: float) -> HSlider:
	var slider := menu.add_slider(label_text, min_value, max_value, factory_default,
		cb, true, step)
	slider.value = getter.call()
	_sync_entries.append([slider, getter])
	return slider


func _rate_input(menu: SimMenu, label_text: String, value: float, cb: Callable,
		getter: Callable) -> SpinBox:
	var label := menu.add_label(label_text)
	var parent := label.get_parent()
	parent.remove_child(label)
	var row := HBoxContainer.new()
	parent.add_child(row)
	row.add_child(label)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = 10.0
	spin.step = 0.01
	spin.allow_greater = true
	spin.value = value
	spin.value_changed.connect(cb)
	row.add_child(spin)
	spin.set_value_no_signal(getter.call())
	_sync_entries.append([spin, getter])
	return spin


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func release() -> void:
	_sync_entries.clear()


func set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text
		_hint.visible = not text.is_empty()


## After a preset switch: push the solver's actual state into the widgets so
## the panel never shows a value the simulation does not have.
func sync_params() -> void:
	for entry in _sync_entries:
		var widget: Control = entry[0]
		var getter: Callable = entry[1]
		if widget is HSlider:
			var slider := widget as HSlider
			slider.set_value_no_signal(clampf(getter.call(), slider.min_value, slider.max_value))
		elif widget is SpinBox:
			(widget as SpinBox).set_value_no_signal(getter.call())
	if _uplift_option != null:
		_uplift_option.select(clampi(solver.uplift_mode, 0, _uplift_option.item_count - 1))
	if _rain_action != null:
		_rain_action.set_pressed_no_signal(host.rain_enabled)
	if _drying_toggle != null:
		_drying_toggle.set_pressed_no_signal(host.drying_enabled)
	if _erosion_action != null:
		_erosion_action.set_pressed_no_signal(host.erosion_running)


func sync_mountain(active: bool, water_on: bool) -> void:
	for section in _mountain_sections:
		var header: Button = section[0]
		var body: Control = section[1]
		header.visible = active
		body.visible = active and header.button_pressed
	for section in _legacy_sections:
		var header: Button = section[0]
		var body: Control = section[1]
		header.visible = not active
		body.visible = not active and header.button_pressed
	for action in _mountain_actions:
		action.visible = active
	_summit_toggle.set_pressed_no_signal(water_on)
	_summit_toggle.visible = active
	_drying_toggle.set_pressed_no_signal(host.drying_enabled)
	_summit_rate_row.visible = active
	_infiltration_rate.get_parent().visible = true
	_tool_hint.text = "Right-click drag sculpts" if active else "Right-click drag sculpts · Pack compacts snow"
	for mode in _tool_buttons:
		_tool_buttons[mode].visible = mode in [TerrainBrush.MOUNTAIN, TerrainBrush.DIG,
			TerrainBrush.SMOOTH] if active else mode != TerrainBrush.MOUNTAIN
	_balls_toggle.visible = not active
	for button in _auto_buttons:
		button.visible = not active
	_brush_slider.max_value = solver.world_size * 0.15 if active else 0.8
	_snowline_slider.max_value = maxf(2.0, host._preset.mountain_height_m * 1.5) if active else 2.0
	if active:
		_menu.set_action_label(_tool_buttons[TerrainBrush.MOUNTAIN], "Raise mountain")
		_menu.set_action_label(_tool_buttons[TerrainBrush.SMOOTH], "Flatten")
		_menu.set_action_label(_tool_buttons[TerrainBrush.DIG], "Lower")
		_regenerate_action.text = "New terrain"
	else:
		_menu.set_action_label(_tool_buttons[TerrainBrush.SMOOTH], "Smooth")
		_menu.set_action_label(_tool_buttons[TerrainBrush.DIG], "Dig")
		_regenerate_action.text = "Reset"
	sync_params()


## Radio behaviour: the pressed brush releases the others.
func sync_tool(mode: int) -> void:
	for known in _tool_buttons:
		var button: Button = _tool_buttons[known]
		button.set_pressed_no_signal(known == mode)


## Preset switches can turn the balls on or off; keep the toggle in step.
func sync_balls(on: bool) -> void:
	if _balls_toggle != null:
		_balls_toggle.set_pressed_no_signal(on)
