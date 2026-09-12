class_name SandMenu extends RefCounted
## SimMenu panel of the sand demo. The three brush buttons behave as a radio
## group, so they live here rather than being rebuilt by the controller.

var solver: HeightfieldSand
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, restart, select_tool, set_auto_pour, set_strength,
## set_brush_size, set_repose, set_grid_n, set_mesh_n, set_render_scale and
## expose the SimQualityState named quality.
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
	var iterations_slider := menu.add_slider("Settle iterations", 2.0, 16.0,
		float(solver.iterations),
		func(v: float): solver.iterations = int(round(v)))
	host.quality.bind("iterations", iterations_slider,
		func(v: float): solver.iterations = int(round(v)))
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	var grid_labels: Array = []
	for n in SandQualityProfile.GRID_SIZES:
		grid_labels.append("%d²" % n)
	var grid_option := menu.add_option_button("Grid resolution", grid_labels,
		SandQualityProfile.GRID_SIZES.find(solver.grid_n),
		func(idx: int): host.set_grid_n(SandQualityProfile.GRID_SIZES[idx]))
	host.quality.bind("grid_n", grid_option, host.set_grid_n,
		func(n: int) -> int: return SandQualityProfile.GRID_SIZES.find(n))
	var mesh_labels: Array = []
	for n in SandQualityProfile.MESH_SIZES:
		mesh_labels.append("%d²" % n)
	var mesh_option := menu.add_option_button("Visual mesh", mesh_labels,
		SandQualityProfile.MESH_SIZES.find(host.mesh_n),
		func(idx: int): host.set_mesh_n(SandQualityProfile.MESH_SIZES[idx]))
	host.quality.bind("mesh_n", mesh_option, host.set_mesh_n,
		func(n: int) -> int: return SandQualityProfile.MESH_SIZES.find(n))
	host.quality.attach_menu_option(menu)
	var scale_slider := menu.add_slider("Render scale", 0.4, 1.0,
		host.render_scale(), host.set_render_scale)
	host.quality.bind("render_scale", scale_slider, host.set_render_scale)


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## Radio behaviour: the pressed brush releases the other two.
func sync_tool(mode: int) -> void:
	for known in _tool_buttons:
		var button: Button = _tool_buttons[known]
		button.set_pressed_no_signal(known == mode)
