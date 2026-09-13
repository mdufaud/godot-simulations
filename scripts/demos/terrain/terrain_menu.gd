class_name TerrainMenu extends RefCounted
## SimMenu panel of the Sand & Snow demo. The brush buttons behave as a radio
## group, so they live here rather than being rebuilt by the controller.
##
## Value widgets do NOT persist: every slider describes the active preset's
## world (a physics state, not a user preference), so a saved value must never
## override what a scene switch just set up. [method sync_params] pushes the
## solver's current state back into the widgets after every restart.

var solver: HeightfieldTerrain
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, restart, select_tool, set_auto_pour, set_auto_water,
## set_strength, set_brush_size, set_repose, set_water_flow, set_erosion,
## set_sediment_capacity, set_stochasticity, set_evaporation, set_snow_repose,
## set_snow_flow, set_melt, set_snowfall, set_freeze, set_grid_n, set_mesh_n,
## set_render_scale, render_scale, set_balls_enabled, expose the
## SimQualityState named quality and the balls_enabled flag.
var host: Node

var _status: Label
var _hint: Label
var _tool_buttons := {}
var _balls_toggle: Button
## [slider, getter] pairs sync_params pushes solver state through after a
## preset switch. Label keys would collide ("Flow rate" in Sand and Water).
var _sync_entries := []


func build(menu: SimMenu, presets: Array, preset_idx: int, tool_choice: int,
		strength: float, auto_pour: bool) -> void:
	var titles: Array = []
	for preset in presets:
		var typed: TerrainPreset = preset
		titles.append(typed.display_name)

	menu.add_section("Scene")
	# The one persisted widget: returning to the demo reopens the last scene.
	menu.add_option_button("Preset", titles, preset_idx, host.apply_preset)
	menu.add_action("↺", "Reset", host.restart)
	_status = menu.add_label("")
	_hint = menu.add_label("")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_separator()

	menu.add_section("Tool")
	_slider(menu, "Brush size", 0.08, 0.8, solver.brush.radius_m, host.set_brush_size)
	_slider(menu, "Strength", 0.3, 3.0, strength, host.set_strength)
	menu.add_label("Right-click drag sculpts · Pack compacts snow")

	# The brush is switched mid-sculpt, so it belongs in the strip rather than the panel.
	for entry in [
		["⛏", "Dig", TerrainBrush.DIG],
		["🚿", "Pour", TerrainBrush.POUR],
		["🫓", "Smooth", TerrainBrush.SMOOTH],
		["💧", "Water", TerrainBrush.WATER],
		["❄️", "Snow", TerrainBrush.SNOW],
		["🥾", "Pack", TerrainBrush.PACK],
	]:
		var mode: int = entry[2]
		var button := menu.add_action_toggle(entry[0], entry[1], tool_choice == mode,
			func(on: bool) -> void:
				if on:
					host.select_tool(mode))
		_tool_buttons[mode] = button
	menu.add_action_toggle("🏖️", "Auto sand", auto_pour, host.set_auto_pour)
	menu.add_action_toggle("🌊", "Auto water", host.auto_water, host.set_auto_water)
	menu.add_separator()

	menu.add_section("Props")
	_balls_toggle = menu.add_action_toggle("⚽", "Balls", host.balls_enabled,
		host.set_balls_enabled)
	menu.add_label("Grab a ball with left-click")
	menu.add_separator()

	menu.add_section("Sand")
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

	menu.add_section("Water")
	_slider(menu, "Flow rate", 0.05, 0.9, solver.water_flow_rate, host.set_water_flow,
		func(): return solver.water_flow_rate)
	_slider(menu, "Erosion", 0.0, 1.0, solver.erosion_rate, host.set_erosion,
		func(): return solver.erosion_rate)
	_slider(menu, "Sediment capacity", 0.0, 3.0, solver.sediment_capacity,
		host.set_sediment_capacity,
		func(): return solver.sediment_capacity)
	_slider(menu, "Meandering", 0.0, 0.4, solver.stochasticity, host.set_stochasticity,
		func(): return solver.stochasticity)
	_slider(menu, "Evaporation m/s", 0.0, 0.1, solver.evap_rate_m_s, host.set_evaporation,
		func(): return solver.evap_rate_m_s)
	menu.add_separator()

	menu.add_section("Snow")
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
	var scale_slider := _slider(menu, "Render scale", 0.4, 1.0,
		host.render_scale(), host.set_render_scale)
	host.quality.bind("render_scale", scale_slider, host.set_render_scale)


## Registers a non-persisting slider. [param getter] feeds sync_params.
func _slider(menu: SimMenu, label_text: String, min_val: float, max_val: float,
		value: float, cb: Callable, getter := Callable()) -> HSlider:
	var slider := menu.add_slider(label_text, min_val, max_val, value, cb, false)
	if getter.is_valid():
		_sync_entries.append([slider, getter])
	return slider


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text
		_hint.visible = not text.is_empty()


## After a preset switch: push the solver's actual state into the widgets so
## the panel never shows a value the simulation does not have.
func sync_params() -> void:
	for entry in _sync_entries:
		var slider: HSlider = entry[0]
		var getter: Callable = entry[1]
		slider.set_value_no_signal(clampf(getter.call(), slider.min_value, slider.max_value))


## Radio behaviour: the pressed brush releases the others.
func sync_tool(mode: int) -> void:
	for known in _tool_buttons:
		var button: Button = _tool_buttons[known]
		button.set_pressed_no_signal(known == mode)


## Preset switches can turn the balls on or off; keep the toggle in step.
func sync_balls(on: bool) -> void:
	if _balls_toggle != null:
		_balls_toggle.set_pressed_no_signal(on)
