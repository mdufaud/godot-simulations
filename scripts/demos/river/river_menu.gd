extends RefCounted

const SCENES := ["River", "Waterfall 50°", "Waterfall 90°"]

var preset_option: OptionButton
var scene_option: OptionButton
var scene_action: Button
var angle_slider: HSlider
var sliders: Array[HSlider] = []
var pause_button: Button
var preset_action: Button
var quality_option: OptionButton
var flow_action: Button
var crate_action: Button
var _menu: SimMenu
var _level_dragging := false
var _angle_dragging := false


func build(menu: SimMenu, controller: Node, presets: Array) -> void:
	_menu = menu
	menu.add_section("River")
	scene_option = menu.add_option_button("Scene", SCENES, 0, controller.set_scene, false)
	angle_slider = menu.add_slider("Angle (°)", 20.0, 90.0, 50.0, func(value: float):
		if not _angle_dragging:
			controller.set_waterfall_angle(value), false, 0.1)
	angle_slider.drag_started.connect(func(): _angle_dragging = true)
	angle_slider.drag_ended.connect(func(changed: bool):
		_angle_dragging = false
		if changed:
			controller.set_waterfall_angle(angle_slider.value))
	var names: Array[String] = []
	for preset: RiverConfig in presets:
		names.append(preset.display_name)
	preset_option = menu.add_option_button("Preset", names, 1, controller.apply_preset, false)
	sliders.append(menu.add_slider("Speed (m/s)", 0.0, 4.0, 0.85, controller.set_speed, false, 0.01))
	var level := menu.add_slider("Level (m)", -0.2, 0.65, 0.06, func(value: float):
		if not _level_dragging:
			controller.set_level(value), false, 0.01)
	level.drag_started.connect(func(): _level_dragging = true)
	level.drag_ended.connect(func(changed: bool):
		_level_dragging = false
		if changed:
			controller.set_level(level.value))
	sliders.append(level)
	sliders.append(menu.add_slider("Clarity", 0.0, 1.0, 0.82, controller.set_clarity, false, 0.01))
	sliders.append(menu.add_slider("Foam", 0.0, 2.0, 0.65, controller.set_foam, false, 0.01))
	menu.add_label("Drag to orbit · Scroll to zoom · WASD to move")
	pause_button = menu.add_toggle("Pause", false, controller.set_frozen, false)
	menu.add_button("Reset river", controller.reset_river)
	menu.add_section("Performance")
	quality_option = controller.quality.attach_menu_option(menu)
	menu.add_slider("Render scale", 0.4, 1.0, controller.viewport_guard.render_scale(),
		controller.set_render_scale)
	menu.add_toggle("3D grass", true, controller.set_grass_enabled, false)
	preset_action = menu.add_action("🌊", "River", controller.cycle_preset)
	flow_action = menu.add_action("💧", "Flow", func():
		controller.river.swe.set_enabled(not controller.river.swe.enabled)
		sync_flow(controller.river.swe))
	crate_action = menu.add_action("📦", "Throw crate", controller.interactions.throw_crate)
	scene_action = menu.add_action("➡", "Scene", controller.cycle_scene)
	sync_scene(controller.scene_index, controller.waterfall_angles)
	sync_flow(controller.river.swe)
	menu.settings_reset.connect(func():
		controller.waterfall_angles = PackedFloat32Array([0.0, 50.0, 90.0])
		controller.set_scene(0)
		sync_scene(0, controller.waterfall_angles)
		controller.apply_preset(1))


func sync(config: RiverConfig, index: int) -> void:
	preset_option.select(index)
	_menu.set_action_label(preset_action, config.display_name)
	preset_action.tooltip_text = "Next river preset · Current: " + config.display_name
	var values := [config.speed_m_s, config.water_level_m, config.clarity, config.foam_amount]
	for i in sliders.size():
		sliders[i].value = values[i]


func sync_scene(index: int, angles: PackedFloat32Array) -> void:
	for i in range(1, SCENES.size()):
		scene_option.set_item_text(i, "Waterfall %.1f°" % angles[i])
	scene_option.select(index)
	angle_slider.editable = index > 0
	angle_slider.set_value_no_signal(angles[maxi(index, 1)])
	scene_action.tooltip_text = "Next scene: %s · Current: %s" % [scene_option.get_item_text((index + 1) % SCENES.size()), scene_option.get_item_text(index)]


func sync_flow(swe: Node3D) -> void:
	var live: bool = swe.active
	_menu.set_action_label(flow_action, "SWE" if live else "Guided flow")
	flow_action.disabled = not swe.available
	flow_action.tooltip_text = "Compare live flow around the rocks with guided flow"
	crate_action.tooltip_text = "Throw a floating crate into the current"
