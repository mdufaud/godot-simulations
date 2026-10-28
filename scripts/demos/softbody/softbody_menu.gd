class_name SoftBodyMenu extends RefCounted
## Soft body panel and action lane. Material rows belong to the preset (not
## persisted, rewritten by [method refresh]); Solver and Graphics rows are driven
## by the quality tier.

const MSAA_LABELS := ["Off", "2×", "4×"]

var _menu: SimMenu
var _preset_option: OptionButton
var _press: Button
var _hint: Label
var _stiffness: HSlider
var _poisson: HSlider
var _density: HSlider
var _damping: HSlider


func build(menu: SimMenu, host, presets: Array[SoftBodyPreset]) -> void:
	_menu = menu
	var quality: SimQualityState = host.quality
	var config: SoftBodyConfig = host.solver.config
	var names: Array[String] = []
	for preset in presets:
		names.append(preset.display_name)

	menu.add_section("Scene")
	menu.add_action("🎬", "Scene", host.next_preset)
	menu.add_action("↺", "Reset", host.reset_scene)
	menu.add_action_toggle("⏸", "Pause", false, host.set_paused)
	menu.add_action("🍮", "Drop", host.drop_body)
	_press = menu.add_action_toggle("🔨", "Press", false, host.set_press)
	menu.add_action("⚾", "Throw", host.throw_ball)
	menu.add_action("🪨", "Rocks", host.rock_rain)
	_preset_option = menu.add_option_button("Preset", names, host.preset_idx, host.apply_preset)
	_hint = menu.add_label("")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_separator()

	menu.add_section("Material")
	_stiffness = menu.add_slider("Stiffness ×", 0.1, 5.0, config.stiffness_scale,
		func(v: float) -> void: host.set_material("stiffness_scale", v), false, 0.05)
	_poisson = menu.add_slider("Poisson ν", 0.0, 0.49, config.poisson_ratio,
		func(v: float) -> void: host.set_material("poisson_ratio", v), false, 0.01)
	_density = menu.add_slider("Density kg/m³", 100.0, 3000.0, config.density_kg_m3,
		func(v: float) -> void: host.set_material("density_kg_m3", v), false, 10.0)
	_damping = menu.add_slider("Damping s", 0.0, 0.05, config.damping_s,
		func(v: float) -> void: host.set_material("damping_s", v), false, 0.001)
	menu.add_separator()

	menu.add_section("Solver")
	var iterations := menu.add_slider("Iterations", 1.0, 24.0, float(config.iterations),
		func(v: float) -> void: host.set_quality_value("iterations", v), false, 1.0)
	quality.bind("iterations", iterations,
		func(v: float) -> void: host.set_quality_value("iterations", v))
	var substeps := menu.add_slider("Substeps", 1.0, 6.0, float(config.substeps),
		func(v: float) -> void: host.set_quality_value("substeps", v), false, 1.0)
	quality.bind("substeps", substeps,
		func(v: float) -> void: host.set_quality_value("substeps", v))
	var cell := menu.add_slider("Lattice cell m", 0.04, 0.12, config.lattice_cell_m,
		func(v: float) -> void: host.set_quality_value("lattice_cell_m", v), false, 0.005)
	quality.bind("lattice_cell_m", cell,
		func(v: float) -> void: host.set_quality_value("lattice_cell_m", v))
	menu.add_debug_toggle("📊", "Profiler overlay", false, host.profiler.set_enabled)
	menu.add_separator()

	menu.add_section("Graphics")
	quality.attach_menu_option(menu)
	menu.add_slider("Render scale", 0.4, 1.0, host.render_scale(), host.set_render_scale)
	var msaa := menu.add_option_button("MSAA", MSAA_LABELS, host.msaa_mode(),
		func(i: int) -> void: host.set_quality_value("msaa", i), false)
	quality.bind("msaa", msaa, func(v: int) -> void: host.set_quality_value("msaa", v))


## Rewrites the preset-owned rows from the live config.
func refresh(host, preset: SoftBodyPreset) -> void:
	var config: SoftBodyConfig = host.solver.config
	_preset_option.select(host.preset_idx)
	_menu.store_value("Scene", "Preset", host.preset_idx)
	_hint.text = "%s\nDrag a body to pull it · Drop, Throw and Rocks add more" % preset.hint
	_press.visible = host.props.press_available()
	_press.set_pressed_no_signal(false)
	_menu.set_slider_value(_stiffness, config.stiffness_scale)
	_menu.set_slider_value(_poisson, config.poisson_ratio)
	_menu.set_slider_value(_density, config.density_kg_m3)
	_menu.set_slider_value(_damping, config.damping_s)


func profiler_lines(host) -> PackedStringArray:
	var solver: SoftBodySolver = host.solver
	var t := solver.get_timings()
	return PackedStringArray([
		"soft bodies GPU %.2f ms · %d vertices · %s" % [t.get("total", 0.0),
			solver.vertex_count(), host.quality.label()],
		"  predict %.2f | contacts %.2f | vbd %.2f | finalize %.2f" % [t.get("predict", 0.0),
			t.get("contacts", 0.0), t.get("vbd", 0.0), t.get("finalize", 0.0)],
	])
