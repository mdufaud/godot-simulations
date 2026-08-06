class_name SandMenu extends RefCounted
## SimMenu panel of the sand demo. The three brush buttons behave as a radio
## group, so they live here rather than being rebuilt by the controller.

const GRID_SIZES: Array[int] = [256, 512, 1024]

var solver: HeightfieldSand
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, restart, select_tool, set_auto_pour, set_strength,
## set_brush_size, set_repose, set_grid_n and set_render_scale.
var host: Node

var _status: Label
var _tool_buttons := {}


func build(menu: SimMenu, presets: Array, preset_idx: int, tool_choice: int,
		strength: float, auto_pour: bool) -> void:
	var titles: Array = []
	for preset in presets:
		var typed: SandPreset = preset
		titles.append(typed.display_name)

	menu.add_section("Scene")
	menu.add_option_button("Preset", titles, preset_idx, host.apply_preset)
	menu.add_action("↺", "Reset", host.restart)
	_status = menu.add_label("")
	menu.add_separator()

	menu.add_section("Tool")
	menu.add_slider("Brush size", 0.08, 0.8, solver.brush.radius_m, host.set_brush_size)
	menu.add_slider("Strength", 0.3, 3.0, strength, host.set_strength)
	menu.add_label("Right-click drag to sculpt")

	# The brush is switched mid-sculpt, so it belongs in the strip rather than the panel.
	for entry in [
		["⛏", "Dig", SandBrush.DIG],
		["🚿", "Pour", SandBrush.POUR],
		["🫓", "Smooth", SandBrush.SMOOTH],
	]:
		var mode: int = entry[2]
		var button := menu.add_action_toggle(entry[0], entry[1], tool_choice == mode,
			func(on: bool) -> void:
				if on:
					host.select_tool(mode))
		_tool_buttons[mode] = button
	menu.add_action_toggle("💧", "Auto", auto_pour, host.set_auto_pour)
	menu.add_separator()

	menu.add_section("Sand")
	menu.add_slider("Repose angle °", 20.0, 45.0, solver.repose_deg, host.set_repose)
	menu.add_slider("Flow rate", 0.03, 0.12, solver.flow_rate,
		func(v: float): solver.flow_rate = v)
	menu.add_slider("Settle iterations", 2.0, 16.0, float(solver.iterations),
		func(v: float): solver.iterations = int(round(v)))
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	menu.add_label("Grid resolution")
	for n in GRID_SIZES:
		menu.add_button("%d²" % n, host.set_grid_n.bind(n))
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, host.set_render_scale)


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## Radio behaviour: the pressed brush releases the other two.
func sync_tool(mode: int) -> void:
	for known in _tool_buttons:
		var button: Button = _tool_buttons[known]
		button.set_pressed_no_signal(known == mode)
