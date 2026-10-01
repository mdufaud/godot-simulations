extends Node
## Touch-path UI smoke test for one demo, driven by tests/run_ui_smoke.sh.
##
## Loads the demo scene, waits for it to settle, then taps the SimMenu gear the way
## a finger would (emulated touch through Input) and asserts the options panel opens
## and closes again. Catches the class of regression where a demo overlay, a layout
## change or a mouse_filter covers the always-on controls on mobile.
##
## Then frees the demo and asserts the root viewport's global render state came back:
## render scaling, MSAA and TAA outlive the scene that changed them, so a demo that
## forgets to restore them silently degrades every demo loaded after it (ViewportGuard).

const SETTLE_FRAMES := 120
## Frames the hover and the panel animation are each given to land.
const HOVER_TRIES := 20
const TOGGLE_TRIES := 30

var _demo := ""
var _frames := 0
var _done := false
var _failures: Array[String] = []
var _demo_root: Node = null
var _entry_state := {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene := "" if args.is_empty() else GameManager.demo_scene(args[0])
	if scene.is_empty():
		printerr("usage: godot res://tests/ui_smoke.tscn -- <demo_key>")
		get_tree().quit(2)
		return
	_demo = args[0]
	GameManager.current_demo = _demo
	_entry_state = _viewport_state()
	var packed: PackedScene = load(scene)
	_demo_root = packed.instantiate()
	# A controller that fails to parse is dropped silently: the scene still
	# instantiates, SimMenu still answers taps, and the test would pass on a demo
	# that does nothing.
	if _demo_root.get_script() == null:
		_fail("scene root has no script (parse error in the controller?)")
		_report()
		return
	get_tree().root.add_child.call_deferred(_demo_root)


func _process(_delta: float) -> void:
	_frames += 1
	if _done or _frames < SETTLE_FRAMES:
		return
	_done = true
	_run()


func _run() -> void:
	var menu := _find_sim_menu(get_tree().root)
	if menu == null:
		_fail("no SimMenu in scene tree")
		_report()
		return
	if _demo == "terrain_demo" and not GpuPreflight.available():
		_fail("terrain demo has no GPU compute device")
		_report()
		return
	if _demo == "ocean_demo":
		await _check_ocean_actions(menu)
	if _demo == "ambient_fluid_demo":
		await _check_ambient_fluid_actions(menu)
	if _demo == "mixwell_demo":
		await _check_mixwell_periodic()
	if _demo == "tornado_demo":
		await _check_tornado_actions()
	if _demo == "nbody_demo":
		await _check_nbody_actions(menu)
	if _demo == "terrain_demo":
		await _check_terrain_actions(menu)
		menu = _find_sim_menu(get_tree().root)

	Input.use_accumulated_input = false
	# Real clicks in a focused test window would race the synthetic touches.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	# Drive the profiler overlay through the same setter the demo's toggle wires,
	# so _check_viewport_restored() proves the measurement flag is restored too.
	if "profiler" in _demo_root:
		_demo_root.profiler.set_enabled(true)
		if not _demo_root._viewport.measure_render_time():
			_fail("profiler toggle did not turn on root-viewport measurement")
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), true, "gear opens panel")
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), false, "gear closes panel")
	await _check_viewport_restored()
	_report()


func _check_mixwell_periodic() -> void:
	_demo_root._select_official_example(0)
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = Vector2(720.0, 420.0)
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = Vector2(1280.0, 560.0)
	drag.relative = Vector2(560.0, 140.0)
	Input.parse_input_event(drag)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.pressed = false
	release.position = drag.position
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	await get_tree().process_frame
	if _demo_root.solver.get_segment_count() < 2:
		_fail("Mixwell canvas drag did not create a continuous freehand path")
	_demo_root._select_official_example(3)
	if _demo_root.solver.get_preset_id() != 6 or _demo_root.source_mode != 3:
		_fail("Mixwell BirdWing control did not select its published preset and source")
	_demo_root._previous_official_pass()
	if _demo_root.solver.get_pattern_step() < 0:
		_fail("Mixwell previous-pass control did not change the rendered construction")
	_demo_root._restart_official_example()
	var birdwing_passes: int = _demo_root.solver.get_pattern_operation_count()
	var canvas_size: Vector2 = _demo_root.size
	await _mixwell_touch_drag(canvas_size * Vector2(0.35, 0.55),
			canvas_size * Vector2(0.52, 0.42))
	if _demo_root.solver.get_preset_id() != 6 or _demo_root.source_mode != 3:
		_fail("Mixwell canvas click reset BirdWing to the first example")
	var first_stroke_passes: int = _demo_root.solver.get_pattern_operation_count()
	if _demo_root.strokes.size() != 1 or first_stroke_passes <= birdwing_passes + 1:
		_fail("Mixwell first stroke replaced the selected published construction")
	await _mixwell_touch_drag(canvas_size * Vector2(0.48, 0.62),
			canvas_size * Vector2(0.64, 0.48))
	if _demo_root.strokes.size() != 2 \
			or _demo_root.solver.get_pattern_operation_count() <= first_stroke_passes:
		_fail("Mixwell second stroke did not retain the first stroke")
	_demo_root._select_official_example(0)
	_demo_root._set_profiling(true)
	_demo_root.solver.set_boundary_mode(MixwellConfig.BoundaryMode.PERIODIC)
	_demo_root._request_reset()
	var timings: Dictionary = {}
	for _frame in 120:
		await get_tree().process_frame
		timings = _demo_root.solver.get_timings()
		if timings.has("init") and timings.has("accumulate"):
			break
	if _demo_root.solver.get_active_boundary_mode() != MixwellConfig.BoundaryMode.PERIODIC:
		_fail("periodic path did not pass fullscreen A/B validation")
	if not timings.has("init") or not timings.has("accumulate"):
		_fail("Mixwell GPU profiling missed init or accumulation stage")
	_demo_root.solver.set_preset(9)
	_demo_root.solver.set_boundary_mode(MixwellConfig.BoundaryMode.SLIP_WALLS)
	_demo_root._request_reset()
	for _frame in 8:
		await get_tree().process_frame
	if _demo_root.solver.get_preset_id() != 9 \
			or _demo_root.solver.get_active_boundary_mode() != MixwellConfig.BoundaryMode.SLIP_WALLS:
		_fail("Mixwell affine or slip-wall smoke path did not activate")
	_demo_root.solver.set_preset(10)
	_demo_root._request_reset()
	for _frame in 8:
		await get_tree().process_frame
	if _demo_root.solver.get_preset_id() != 10:
		_fail("Mixwell Pinch extension did not activate")


func _mixwell_touch_drag(start: Vector2, finish: Vector2) -> void:
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = start
	Input.parse_input_event(press)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = finish
	drag.relative = finish - start
	Input.parse_input_event(drag)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.pressed = false
	release.position = finish
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	await get_tree().process_frame


## Cycles every tornado preset and storm look, and asserts the auto-framing keeps
## the camera outside the dust skirt — the regression class where a preset change
## left the camera engulfed in the funnel volume filling the whole screen.
func _check_tornado_actions() -> void:
	var presets: Array = _demo_root.PRESETS
	for i in presets.size():
		_demo_root.apply_preset(i)
		for _frame in 3:
			await get_tree().process_frame
		# Slider steps quantize preset values ((max-min)/100 = 1.9 m here).
		if absf(_demo_root.field.r_core0 - presets[i].r0) > 2.5:
			_fail("tornado preset %d did not apply its core radius" % i)
		var cam: Camera3D = _demo_root.cam_rig.get_camera()
		var flat := Vector2(cam.global_position.x, cam.global_position.z).length()
		# Widest skirt slider setting with margin.
		var skirt: float = (3.2 + 1.2 * 2.0) * presets[i].r0
		if flat < skirt:
			_fail("tornado preset %d frames the storm from inside the dust skirt" % i)
	for look in 5:
		_demo_root.apply_look(look)
		for _frame in 2:
			await get_tree().process_frame
	_demo_root.apply_look(0)
	_demo_root.apply_preset(0)
	for _frame in 2:
		await get_tree().process_frame
	# Action-strip cycles must wrap back to the boot state with their panel
	# dropdown left on the same entry as the live storm/preset.
	var preset_count: int = _demo_root.PRESETS.size()
	for i in preset_count:
		_demo_root.cycle_genre()
		if _demo_root._preset_btn.selected != (i + 1) % preset_count:
			_fail("genre cycle left the preset dropdown out of sync")
		for _frame in 1:
			await get_tree().process_frame
	for _i in _demo_root.STORM_TYPES.size():
		_demo_root.cycle_storm_type()
		if _demo_root._look_btn.selected != _demo_root.storm_type:
			_fail("storm-type cycle left the look dropdown out of sync")
		for _frame in 1:
			await get_tree().process_frame
	if _demo_root._preset_btn.selected != 0:
		_fail("genre cycle did not wrap back to the first preset")
	if absf(_demo_root.field.r_core0 - presets[0].r0) > 2.5:
		_fail("genre cycle did not restore the first preset's core radius")
	if _demo_root.storm_type != 0:
		_fail("storm-type cycle did not wrap back to Normal")


## Frees the demo and compares the root viewport against what it looked like before.
func _check_viewport_restored() -> void:
	if _demo_root == null:
		return
	_demo_root.queue_free()
	_demo_root = null
	await get_tree().process_frame
	await get_tree().process_frame
	var now := _viewport_state()
	for key in _entry_state:
		if now[key] != _entry_state[key]:
			_fail("viewport %s leaked: %s -> %s" % [key, _entry_state[key], now[key]])


func _viewport_state() -> Dictionary:
	var vp := get_tree().root
	return {
		scaling_3d_mode = vp.scaling_3d_mode,
		scaling_3d_scale = vp.scaling_3d_scale,
		msaa_3d = vp.msaa_3d,
		use_taa = vp.use_taa,
		# No engine getter exists for render-time measurement, so ViewportGuard
		# counts the viewports it is measuring; size_changed connections catch a
		# RefCounted target that survives the demo (Nodes disconnect themselves).
		measure_render_time = ViewportGuard.measured_viewports,
		size_changed_connections = vp.size_changed.get_connections().size(),
	}


## Taps [param button] and asserts the panel ends up in [param want_open].
func _check_toggle(menu: SimMenu, button: Button, want_open: bool, what: String) -> void:
	if not button.is_visible_in_tree():
		_fail("%s: button not visible" % what)
		return
	var rect := button.get_global_rect()
	var viewport := menu.get_viewport()
	var pos: Vector2 = viewport.get_final_transform() * (rect.position + rect.size * 0.5)

	# Hover first: a covering Control shows up here before the tap is even sent.
	# Retried, because the window flag changes above can re-map the window and drop
	# the hover for a frame — one miss is not a covered button.
	var motion := InputEventMouseMotion.new()
	motion.position = rect.position + rect.size * 0.5
	var hovered: Control = null
	for attempt in HOVER_TRIES:
		viewport.push_input(motion, true)
		await get_tree().process_frame
		hovered = viewport.gui_get_hovered_control()
		if hovered == button:
			break
	if hovered != button:
		_fail("%s: tap point covered by %s" % [
			what, hovered.get_path() if hovered != null else "<nothing>",
		])
		return

	for pressed in [true, false]:
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.pressed = pressed
		touch.position = pos
		Input.parse_input_event(touch)
		Input.flush_buffered_events()
		await get_tree().process_frame
		await get_tree().process_frame

	# The panel toggles through an animation, so give it a few frames to land.
	for attempt in TOGGLE_TRIES:
		if menu.is_panel_open() == want_open:
			return
		await get_tree().process_frame
	_fail("%s: panel is %s" % [what, "open" if menu.is_panel_open() else "closed"])


func _find_sim_menu(node: Node) -> SimMenu:
	if node is SimMenu:
		return node as SimMenu
	for child in node.get_children():
		var found := _find_sim_menu(child)
		if found != null:
			return found
	return null


func _check_ambient_fluid_actions(menu: SimMenu) -> void:
	var action_bar := menu.get_node_or_null("BottomRight/ActionBar") as GridContainer
	if action_bar == null:
		_fail("ambient fluid action bar missing")
		return
	var buttons := {}
	for child in action_bar.get_children():
		if child is Button and child.visible:
			buttons[child.tooltip_text] = child
	for expected in ["Next Fluid", "Throw", "Drop Mix", "Reset", "Clear"]:
		if not buttons.has(expected):
			_fail("ambient fluid action missing: %s" % expected)
	if _failures.size() > 0:
		return
	var initial_count: int = _demo_root.bodies.size()
	var initial_fluid: int = _demo_root._medium_index
	buttons["Next Fluid"].pressed.emit()
	await get_tree().physics_frame
	if _demo_root._medium_index != (initial_fluid + 1) % 5:
		_fail("ambient fluid next action did not change fluid")
	buttons.Throw.pressed.emit()
	await get_tree().physics_frame
	if _demo_root.bodies.size() != initial_count + 1:
		_fail("ambient fluid throw action did not spawn one object")
	buttons["Drop Mix"].pressed.emit()
	await get_tree().physics_frame
	if _demo_root.bodies.size() != initial_count + 5:
		_fail("ambient fluid drop mix action did not spawn four objects")
	buttons.Clear.pressed.emit()
	await get_tree().process_frame
	if not _demo_root.bodies.is_empty():
		_fail("ambient fluid clear action did not remove objects")
	buttons.Reset.pressed.emit()
	await get_tree().physics_frame
	if _demo_root.bodies.size() != 4:
		_fail("ambient fluid reset action did not restore buoyancy set")


func _check_ocean_actions(menu: SimMenu) -> void:
	var action_bar := menu.get_node_or_null("BottomRight/ActionBar") as GridContainer
	if action_bar == null:
		_fail("ocean action bar missing")
		return
	var buttons: Dictionary = {}
	for child in action_bar.get_children():
		if child is Button and child.visible:
			buttons[child.tooltip_text] = child
	for expected in ["Sea", "Mood", "Palette", "Throw", "Clear", "Freeze"]:
		if not buttons.has(expected):
			_fail("ocean action missing: %s" % expected)
	if _failures.size() > 0:
		return

	var initial_preset: int = _demo_root.current_preset_index
	buttons.Sea.pressed.emit()
	await get_tree().process_frame
	if _demo_root.current_preset_index == initial_preset:
		_fail("ocean sea action did not cycle the preset")

	var initial_mood: float = _demo_root.storm.mood_target
	buttons.Mood.pressed.emit()
	await get_tree().process_frame
	if is_equal_approx(_demo_root.storm.mood_target, initial_mood):
		_fail("ocean mood action did not cycle the storm mood")

	var initial_look: int = _demo_root.current_look_index
	buttons.Palette.pressed.emit()
	await get_tree().process_frame
	if _demo_root.current_look_index == initial_look:
		_fail("ocean palette action did not cycle the look")

	var initial_crates: int = _demo_root._crates.size()
	buttons.Throw.pressed.emit()
	await get_tree().physics_frame
	if _demo_root._crates.size() != initial_crates + 1:
		_fail("ocean throw action did not spawn one crate")
	buttons.Clear.pressed.emit()
	await get_tree().process_frame
	if not _demo_root._crates.is_empty():
		_fail("ocean clear action did not remove crates")

	var freeze_button: Button = buttons.Freeze
	freeze_button.set_pressed_no_signal(true)
	freeze_button.toggled.emit(true)
	if not _demo_root._frozen:
		_fail("ocean freeze action did not pause simulation")
	freeze_button.set_pressed_no_signal(false)
	freeze_button.toggled.emit(false)
	if _demo_root._frozen:
		_fail("ocean freeze action did not resume simulation")


func _check_terrain_actions(menu: SimMenu) -> void:
	var controller := _demo_root
	if not await _wait_terrain_ready(controller):
		_fail("terrain solver did not initialize before action smoke")
		return
	controller.set_frozen(true)
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), true,
		"terrain preset panel opens")
	var preset_option: OptionButton = controller._menu_builder._preset_option
	if preset_option == null or not preset_option.is_visible_in_tree():
		_fail("terrain preset selector is not visible in the open panel")
		return
	preset_option.select(9)
	preset_option.item_selected.emit(9)
	if not await _wait_terrain_ready(controller):
		_fail("terrain Mountain preset did not initialize")
		return
	var actions := _terrain_action_buttons(menu)
	if not actions.has("Scene"):
		_fail("preset cycle action is missing")
		return
	var first_action := (menu.get_node("BottomRight/ActionBar") as GridContainer).get_child(0) as Button
	if first_action.tooltip_text != "Scene":
		_fail("Scene preset cycle is not the first visible action")
		return
	for step in 10:
		first_action.pressed.emit()
		var expected_preset := step % 10
		if not await _wait_terrain_ready(controller):
			_fail("Scene action did not initialize preset %d" % expected_preset)
			return
		if controller.preset_idx != expected_preset or preset_option.selected != expected_preset \
				or int(controller.menu.stored_value("Scene", "Preset", -1)) != expected_preset:
			_fail("Scene action did not cycle/persist preset %d from Mountain" % expected_preset)
		var expected_size: float = controller._preset.world_size_m
		var expected_snow: bool = controller._preset.snow_enabled
		if absf(controller.solver.world_size - expected_size) > 1e-5 \
				or controller.solver.snow_enabled != expected_snow \
				or controller.view.sand_mat.get_shader_parameter("snow_enabled") != expected_snow \
				or controller.view.water_mat.get_shader_parameter("snow_enabled") != expected_snow \
				or not controller.view.water.visible \
				or controller.view.sand_mat.get_shader_parameter("landscape_materials") \
				!= controller._preset.landscape_materials \
				or controller.view.water_mat.get_shader_parameter("landscape_water") \
				!= controller._preset.landscape_materials:
			_fail("preset %d left solver, materials, or water visibility out of sync" % expected_preset)
			return
		if controller.view.terrain.material_override != controller.view.sand_mat \
				or not controller.view.sand_mat.shader.resource_path.ends_with("terrain_surface.gdshader"):
			_fail("preset %d changed the terrain surface material binding" % expected_preset)
			return
	if menu._is_pc():
		var first_key := InputEventKey.new()
		first_key.pressed = true
		first_key.physical_keycode = KEY_1
		menu._unhandled_input(first_key)
		if not await _wait_terrain_ready(controller) or controller.preset_idx != 0 \
				or preset_option.selected != 0:
			_fail("KEY_1 did not trigger the first Scene preset action")
			return
		preset_option.select(9)
		preset_option.item_selected.emit(9)
		if not await _wait_terrain_ready(controller):
			_fail("terrain Mountain did not restore after the KEY_1 action check")
			return
	actions = _terrain_action_buttons(menu)
	for expected in ["Scene", "Rain", "Erosion", "Drying", "Raise mountain", "Flatten", "Lower"]:
		if not actions.has(expected):
			_fail("Mountain action missing: %s" % expected)
	if _failures.size() > 0:
		return
	var regenerate_button: Button = controller._menu_builder._regenerate_action
	if regenerate_button.text != "New terrain" \
			or (menu.get_node("BottomRight/ActionBar") as GridContainer).get_children().has(regenerate_button) \
			or not menu.get_node("Panel").is_ancestor_of(regenerate_button):
		_fail("Mountain New terrain action is not available in the panel")
		return
	_open_terrain_menu_section(menu, "Terrain")
	_open_terrain_menu_section(menu, "Erosion")
	var seed_before: int = controller._mountain_seed
	var live_size_before: float = controller.solver.world_size
	var live_height_before: float = controller._preset.mountain_height_m
	var generation_values := {
		"Terrain size m": 80.0,
		"Elevation m": 14.0,
		"Mountain density": 3.1,
		"Ruggedness": 0.62,
		"Valley width": 0.27,
		"Valley depth": 0.31,
		"Ridge irregularity": 0.24,
		"Surface detail": 1.7,
	}
	for label in generation_values:
		var slider := _terrain_slider(menu, label)
		if slider == null or not slider.is_visible_in_tree():
			_fail("Mountain generation slider is missing: %s" % label)
			return
		slider.value = generation_values[label]
	if controller.solver.world_size != live_size_before \
			or controller._preset.mountain_height_m != live_height_before:
		_fail("Mountain generation controls changed the live terrain before regeneration")
	regenerate_button.pressed.emit()
	if not await _wait_terrain_ready(controller):
		_fail("New terrain action did not initialize")
		return
	if controller.preset_idx != 9 or controller._mountain_seed == seed_before \
			or controller.solver.world_size != 80.0 \
			or controller._preset.mountain_height_m != 14.0 \
			or absf(controller._preset.alpine_density - 3.1) > 1e-5 \
			or absf(controller._preset.alpine_ruggedness - 0.62) > 1e-5 \
			or absf(controller._preset.alpine_valley_width_fraction - 0.27) > 1e-5 \
			or absf(controller._preset.alpine_valley_depth_fraction - 0.31) > 1e-5 \
			or absf(controller._preset.alpine_ridge_irregularity - 0.24) > 1e-5 \
			or absf(controller._preset.alpine_surface_detail - 1.7) > 1e-5:
		_fail("New terrain did not apply pending Alpine generation settings")
	for label in generation_values:
		if absf(float(menu.stored_value("Terrain", label, -999.0))
				- generation_values[label]) > 1e-5:
			_fail("Mountain generation value was not persisted: %s" % label)
	if absf(controller._menu_builder._summit_rate.value - 0.12) > 1e-6:
		_fail("Mountain summit-flow control did not start at 0.12 m/s")
	if controller.rain_enabled or controller.erosion_running \
			or controller.solver.rain_rate_m_s != 0.0 or controller.solver.erosion_rate != 0.0:
		_fail("Mountain Rain or Erosion did not start disabled")
	var rain_slider := _terrain_slider(menu, "Rain m/s")
	if rain_slider == null or not rain_slider.is_visible_in_tree():
		_fail("Mountain rain control is missing from the open Erosion section")
		return
	rain_slider.value = 0.006
	if controller.solver.rain_rate_m_s != 0.0 \
			or absf(controller.mountain_rain_rate_m_s - 0.006) > 1e-6:
		_fail("Mountain rain control changed live rain while Rain was off")
	var rain: Button = actions.Rain
	rain.set_pressed_no_signal(true)
	rain.toggled.emit(true)
	if not controller.rain_enabled or absf(controller.solver.rain_rate_m_s - 0.006) > 1e-6 \
			or controller.erosion_running or controller.solver.erosion_rate != 0.0:
		_fail("Rain toggle did not start rainfall independently")
	var erosion_slider := _terrain_slider(menu, "Erosion strength")
	if erosion_slider == null or not erosion_slider.is_visible_in_tree():
		_fail("Mountain erosion strength control is missing from the open Erosion section")
		return
	erosion_slider.value = 0.8
	if controller.solver.erosion_rate != 0.0 \
			or absf(controller.mountain_erosion_rate - 0.8) > 1e-6:
		_fail("Erosion strength control changed live erosion while Erosion was off")
	var erosion: Button = actions.Erosion
	erosion.set_pressed_no_signal(true)
	erosion.toggled.emit(true)
	if not controller.erosion_running or absf(controller.solver.rain_rate_m_s - 0.006) > 1e-6 \
			or absf(controller.solver.erosion_rate - 0.8) > 1e-6:
		_fail("Erosion toggle changed Rain or did not activate stored strength")
	rain_slider.value = 0.008
	if absf(controller.solver.rain_rate_m_s - 0.008) > 1e-6 \
			or absf(controller.solver.erosion_rate - 0.8) > 1e-6:
		_fail("Mountain rain control changed erosion or failed to update active rain")
	erosion_slider.value = 1.1
	if absf(controller.solver.erosion_rate - 1.1) > 1e-6:
		_fail("Mountain erosion strength did not update while active")
	erosion.set_pressed_no_signal(false)
	erosion.toggled.emit(false)
	if controller.erosion_running or controller.solver.erosion_rate != 0.0 \
			or absf(controller.solver.rain_rate_m_s - 0.008) > 1e-6:
		_fail("Erosion toggle stopped Rain or left erosion active")
	rain.set_pressed_no_signal(false)
	rain.toggled.emit(false)
	if controller.rain_enabled or controller.solver.rain_rate_m_s != 0.0 \
			or controller.erosion_running:
		_fail("Rain toggle changed Erosion state or left rain active")
	var drying: Button = actions.Drying
	var drying_rate: SpinBox = controller._menu_builder._infiltration_rate
	drying_rate.value = 0.27
	if absf(controller.drying_rate_m_s - 0.27) > 1e-6:
		_fail("Infiltration rate control did not update the drying rate")
	drying.set_pressed_no_signal(true)
	drying.toggled.emit(true)
	if not controller.drying_enabled \
			or absf(controller.solver.infiltration_rate_m_s - 0.27) > 1e-6:
		_fail("Drying UI toggle did not enable infiltration")
	drying.set_pressed_no_signal(false)
	drying.toggled.emit(false)
	if controller.drying_enabled or controller.solver.infiltration_rate_m_s != 0.0:
		_fail("Drying UI toggle did not disable infiltration")
	var summit: CheckButton = controller._menu_builder._summit_toggle
	if summit == null or not summit.is_visible_in_tree():
		_fail("Summit sources panel toggle is missing")
	summit.set_pressed_no_signal(true)
	summit.toggled.emit(true)
	var deadline := Time.get_ticks_msec() + 30000
	while not controller.summit_water and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not controller.summit_water or controller.solver.summit_sources.is_empty():
		_fail("Summit water UI toggle did not find Mountain peaks")
	for source in controller.solver.summit_sources:
		if absf(source.w - 0.12) > 1e-6:
			_fail("Summit water source ignored the 0.12 m/s default control")
			break
	summit.set_pressed_no_signal(false)
	summit.toggled.emit(false)
	if controller.summit_water or not controller.solver.summit_sources.is_empty():
		_fail("Summit water UI toggle did not clear its sources")
	for tool in ["Raise mountain", "Flatten", "Lower"]:
		actions[tool].set_pressed_no_signal(true)
		actions[tool].toggled.emit(true)
		var expected_mode := TerrainBrush.MOUNTAIN if tool == "Raise mountain" \
			else TerrainBrush.SMOOTH if tool == "Flatten" else TerrainBrush.DIG
		if controller.tool_choice != expected_mode:
			_fail("%s action did not select its brush mode" % tool)

	preset_option.select(1)
	preset_option.item_selected.emit(1)
	if not await _wait_terrain_ready(controller):
		_fail("legacy terrain preset did not initialize")
		return
	if controller.preset_idx != 1 or controller.solver.world_size != 4.0:
		_fail("terrain preset selector did not return to the legacy 4 m scene")
	actions = _terrain_action_buttons(menu)
	for mountain_action in ["Rain", "Erosion", "Raise mountain", "Flatten", "Lower"]:
		if actions.has(mountain_action):
			_fail("Mountain-only action remained visible on a legacy preset: %s" % mountain_action)
	var legacy_reset: Button = controller._menu_builder._regenerate_action
	if legacy_reset.text != "Reset" \
			or not menu.get_node("Panel").is_ancestor_of(legacy_reset) \
			or not controller.view.water.visible:
		_fail("legacy Reset panel action or physical water surface is missing")
	if not actions.has("Scene") or not actions.has("Drying"):
		_fail("legacy Scene or Drying action is missing")
	legacy_reset.pressed.emit()
	if not await _wait_terrain_ready(controller):
		_fail("legacy Reset panel action did not initialize")
		return
	if controller.preset_idx != 1 or not controller.view.water.visible:
		_fail("legacy Reset changed preset or hid the physical water surface")
	preset_option.select(9)
	preset_option.item_selected.emit(9)
	if not await _wait_terrain_ready(controller):
		_fail("terrain smoke could not restore Mountain before boot persistence check")
		return
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), false,
		"terrain preset panel closes")
	controller.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	var packed: PackedScene = load("res://scenes/terrain_demo.tscn")
	_demo_root = packed.instantiate()
	get_tree().root.add_child(_demo_root)
	controller = _demo_root
	if not await _wait_terrain_ready(controller):
		_fail("terrain scene did not initialize from persisted Mountain settings")
		return
	if controller.preset_idx != 9 \
			or absf(controller.mountain_world_size_m - 80.0) > 1e-5 \
			or absf(controller.mountain_height_m - 14.0) > 1e-5 \
			or absf(controller.mountain_density - 3.1) > 1e-5 \
			or absf(controller.mountain_ruggedness - 0.62) > 1e-5 \
			or absf(controller.mountain_valley_width_fraction - 0.27) > 1e-5 \
			or absf(controller.mountain_valley_depth_fraction - 0.31) > 1e-5 \
			or absf(controller.mountain_ridge_irregularity - 0.24) > 1e-5 \
			or absf(controller.mountain_surface_detail - 1.7) > 1e-5 \
			or controller.solver.world_size != 80.0 \
			or absf(controller._preset.mountain_height_m - 14.0) > 1e-5:
		_fail("fresh terrain boot did not restore persisted Mountain generation settings")
	if int(controller.menu.stored_value("Scene", "Preset", -1)) != 9:
		_fail("Mountain preset was not persisted for the fresh-scene boot check")
	controller.set_frozen(true)


func _terrain_action_buttons(menu: SimMenu) -> Dictionary:
	var result := {}
	var action_bar := menu.get_node_or_null("BottomRight/ActionBar") as GridContainer
	if action_bar == null:
		_fail("terrain action bar missing")
		return result
	for child in action_bar.get_children():
		if child is Button and child.visible:
			result[child.tooltip_text] = child
	return result


func _open_terrain_menu_section(menu: SimMenu, section_name: String) -> void:
	for node in menu.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text.ends_with(section_name):
			if not button.button_pressed:
				button.set_pressed_no_signal(true)
				button.toggled.emit(true)
			return
	_fail("terrain menu section missing: %s" % section_name)


func _terrain_slider(menu: SimMenu, label_text: String) -> HSlider:
	for row in menu.find_children("*", "HBoxContainer", true, false):
		if row.get_child_count() < 2:
			continue
		var label := row.get_child(0) as Label
		if label != null and label.text == label_text:
			return row.get_child(1) as HSlider
	return null


func _wait_terrain_ready(controller: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline \
			and (not controller.solver.initialized or not controller.texture_bound):
		await get_tree().process_frame
	return controller.solver.initialized and controller.texture_bound


func _check_nbody_actions(menu: SimMenu) -> void:
	var controller := _demo_root
	var deadline := Time.get_ticks_msec() + 30000
	while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not controller.capture_ready():
		_fail("N-body solver did not initialize")
		return

	var actions: Dictionary = {}
	var action_bar := menu.get_node_or_null("BottomRight/ActionBar") as GridContainer
	if action_bar == null:
		_fail("N-body action bar missing")
		return
	for child in action_bar.get_children():
		if child is Button and child.visible:
			actions[child.tooltip_text] = child
	for expected in ["Pause", "Reset"]:
		if not actions.has(expected):
			_fail("N-body action missing: %s" % expected)
	if not action_bar.get_children().has(controller.scene_action) \
			or not action_bar.get_children().has(controller.speed_action) \
			or not action_bar.get_children().has(controller.step_action) \
			or (controller.scene_action.find_child("ActionCaption", true, false) as Label).text != "Scene" \
			or (controller.speed_action.find_child("ActionCaption", true, false) as Label).text != "1.00x":
		_fail("N-body Scene or Speed action missing from the visible action strip")
	if not controller.step_action.disabled or controller.step_action.modulate.a >= 0.5 \
			or controller.seed_action.get_parent() != menu.get_node("Panel/VBox/Scroll/Margin/Content"):
		_fail("N-body Step must be visible but inactive, and New seed must be a top-level control")
	if _failures.size() > 0:
		return

	var scene_action: Button = controller.scene_action
	var speed: Button = controller.speed_action
	var pause: Button = actions.Pause
	var step: Button = controller.step_action
	var reset: Button = actions.Reset
	var seed: Button = controller.seed_action
	var defaults: Button = controller.defaults_button
	var frame: Button = controller.frame_button
	scene_action.pressed.emit()
	await _wait_nbody_scene(controller, 1)
	if controller.active_preset.scene_type != 1 or controller.scene_option.selected != 1:
		_fail("N-body Scene action did not advance the visible scene selector")
	controller._on_scene_selected(0)
	await _wait_nbody_scene(controller, 0)
	controller.time_scale_slider.value = 1.0
	speed.pressed.emit()
	if not is_equal_approx(controller.time_scale, 2.0) \
			or not is_equal_approx(controller.time_scale_slider.value, 2.0):
		_fail("N-body Speed action did not update the live time-scale slider")
	controller.time_scale_slider.value = 1.0
	if not step.disabled:
		_fail("N-body Step should be inactive while the simulation is running")
	controller._paused = true
	pause.set_pressed_no_signal(true)
	pause.toggled.emit(true)
	if not controller._paused or step.disabled or step.modulate.a < 0.99 \
			or pause.tooltip_text != "Resume":
		_fail("N-body pause did not expose Step and Resume")
	var before_step: float = controller._sim_time
	step.pressed.emit()
	if not is_equal_approx(controller._sim_time, before_step + controller.integration_dt):
		_fail("N-body Step did not advance exactly one fixed integration quantum")
	var step_dt: float = controller.solver.dt
	if not is_equal_approx(step_dt,
			controller.integration_dt / float(controller.solver.substeps)):
		_fail("N-body substeps changed the fixed integration quantum")
	pause.set_pressed_no_signal(false)
	pause.toggled.emit(false)
	var before_running_step: float = controller._sim_time
	step.pressed.emit()
	if not controller._paused and (not step.disabled or step.modulate.a >= 0.5 \
			or not is_equal_approx(controller._sim_time, before_running_step)):
		_fail("N-body Step ran while the simulation was not paused")
	controller._paused = true
	pause.set_pressed_no_signal(true)
	pause.toggled.emit(true)
	var paused_time: float = controller._sim_time
	for _frame_index in 2:
		await get_tree().process_frame
	if not is_equal_approx(controller._sim_time, paused_time):
		_fail("N-body Pause still advanced simulation time")

	# Drive every scene slider to its maximum and commit once per scene. The solver
	# is reduced to a tiny particle count so these UI checks exercise the real
	# reset/init path without benchmarking the selected GPU.
	controller._on_self_gravity(false)
	controller._set_particle_count(65536)
	await _wait_nbody_scene(controller, 0)
	controller.gravity_toggle.set_pressed_no_signal(true)
	controller.gravity_toggle.toggled.emit(true)
	await _wait_nbody_scene(controller, 0)
	if not controller.solver.self_gravity \
			or controller.solver.particle_count != controller.config.self_gravity_max_particles:
		_fail("N-body self-gravity toggle did not apply the pairwise particle cap")
	controller.gravity_toggle.set_pressed_no_signal(false)
	controller.gravity_toggle.toggled.emit(false)
	await _wait_nbody_scene(controller, 0)
	if controller.solver.self_gravity or controller.solver.particle_count != 65536:
		_fail("N-body self-gravity toggle did not restore the previous particle count")
	scene_action.pressed.emit()
	await _wait_nbody_scene(controller, 1)
	controller._on_scene_selected(0)
	await _wait_nbody_scene(controller, 0)
	if controller.solver.self_gravity or controller.solver.particle_count != 65536:
		_fail("N-body self-gravity toggled twice broke the scene on return")
	controller._set_particle_count(64)
	deadline = Time.get_ticks_msec() + 30000
	while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not controller.capture_ready():
		_fail("N-body reduced-count solver did not reinitialize")
		return
	controller.time_scale_slider.value = 1.5
	controller.gravity_constant_slider.value = 1.25
	controller.integration_dt_slider.value = 0.09
	controller.substeps_slider.value = 3.0
	controller.pair_softening_slider.value = 0.2
	controller.attractor_softening_slider.value = 0.13
	controller._on_physics_drag_ended(true)
	if not is_equal_approx(controller.time_scale, 1.5) \
			or not is_equal_approx(controller.gravity_constant, 1.25) \
			or not is_equal_approx(controller.integration_dt, 0.09) \
			or controller.solver.substeps != 3 \
			or not is_equal_approx(controller.solver.dt, 0.03) \
			or not is_equal_approx(controller.solver.softening, 0.2) \
			or not is_equal_approx(controller.solver.attractor_softening, 0.13):
		_fail("N-body physics and numerics sliders did not reach the running solver")
	deadline = Time.get_ticks_msec() + 30000
	while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not controller.capture_ready():
		_fail("N-body physics-control change did not reinitialize")
		return

	for scene_index in controller.PRESETS.size():
		controller._on_scene_selected(scene_index)
		deadline = Time.get_ticks_msec() + 30000
		while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not controller.capture_ready():
			_fail("N-body scene %d did not reinitialize" % scene_index)
			return
		var all_params: Array = controller.scene_def.params() \
			+ controller.scene_def.advanced_params()
		var slider_map: Dictionary = controller.scene_param_sliders.duplicate()
		slider_map.merge(controller.advanced_param_sliders)
		for param: Dictionary in all_params:
			var key: String = param.key
			if not slider_map.has(key):
				_fail("N-body scene %d parameter has no slider: %s" % [scene_index, key])
				continue
			var slider: HSlider = slider_map[key]
			slider.value = float(param.max)
			if not is_equal_approx(float(controller.scene_def.get(key)), slider.value):
				_fail("N-body slider %s is not wired to its scene parameter" % key)
		controller._on_param_drag_ended(true)
		deadline = Time.get_ticks_msec() + 30000
		while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not controller.capture_ready():
			_fail("N-body scene %d failed after slider commit" % scene_index)
			return
		match scene_index:
			0:
				if not is_equal_approx(controller.solver.escape_radius,
						controller.solver.disk_r_max * 4.0):
					_fail("N-body black-hole sliders did not reach the solver bounds")
				controller._on_scene_selected(1)
				await _wait_nbody_scene(controller, 1)
				controller._on_scene_selected(0)
				await _wait_nbody_scene(controller, 0)
				if not is_equal_approx(controller.scene_def.bh_mass, 8.0):
					_fail("N-body black-hole controls did not persist across scenes")
				controller.random_seed = 9
				defaults.pressed.emit()
				if not is_equal_approx(controller.scene_def.bh_mass, 1.0) \
						or not is_equal_approx(controller.scene_def.bulge_fraction, 0.03) \
						or controller.random_seed != 9:
					_fail("N-body Scene defaults did not restore scene values and keep the seed")
				await _wait_nbody_scene(controller, 0)
			1:
				if not is_equal_approx(controller.scene_def.absorb_radius, 2.0) \
						or not is_equal_approx(controller.attractor_list[0].radius, 2.0):
					_fail("N-body pulsar absorb-radius slider did not reach the attractor")
			2:
				if not is_equal_approx(controller.solver.disk_thickness, 3.0):
					_fail("N-body collision thickness slider did not reach the solver")
			3:
				if not is_equal_approx(controller.scene_def.outer_moon_ratio, 1.5):
					_fail("N-body ring moon-orbit slider did not reach the scene")
			4:
				if not is_equal_approx(controller.solver.vortex_downdraft_ratio, 1.5):
					_fail("N-body vortex downdraft slider did not reach the shader")
			5:
				if not is_equal_approx(controller.solver.firework_drag, 3.0):
					_fail("N-body firework drag slider did not reach the shader")
			6:
				if not is_equal_approx(controller.solver.disk_r_max, 90.0):
					_fail("N-body planetary belt slider did not reach the solver bounds")
			7:
				if not is_equal_approx(controller.solver.v_ref * controller.solver.v_ref,
						controller.gravity_constant * 60.0 / 24.0):
					_fail("N-body cluster mass and radius sliders did not reach the solver")
			8:
				if not is_equal_approx(controller.solver.escape_radius, 140.0):
					_fail("N-body Trojan orbit slider did not reach the solver bounds")
			9:
				if controller.solver.respawn_mode != 3 \
						or not is_equal_approx(controller.solver.escape_radius, 360.0):
					_fail("N-body tidal stream sliders did not reach respawn and solver bounds")

	controller._on_scene_selected(5)
	await _wait_nbody_scene(controller, 5)
	if not controller.star_mat.get_shader_parameter("firework_mode") \
			or controller.mm.visible_instance_count != mini(controller.solver.particle_count,
				int(controller.scene_def.rockets) * 2048):
		_fail("N-body Fireworks must render its active analytic stars")
	controller.star_size_slider.value = 0.11
	controller.brightness_slider.value = 2.0
	controller.min_pixel_size_slider.value = 2.3
	if not is_equal_approx(controller.star_mat.get_shader_parameter("sprite_size"), 0.11) \
			or not is_equal_approx(controller.star_mat.get_shader_parameter("brightness"), 2.0) \
			or not is_equal_approx(controller.star_mat.get_shader_parameter("min_pixel_size"), 2.3) \
			or not is_equal_approx(controller._scene_render_values[5].min_pixel_size, 2.3):
		_fail("N-body render sliders did not reach the star material")
	controller._on_scene_selected(4)
	await _wait_nbody_scene(controller, 4)
	if controller.star_mat.get_shader_parameter("firework_mode") \
			or controller.mm.visible_instance_count != -1:
		_fail("N-body Fireworks rendering must clear on scene switch")
	controller._on_scene_selected(5)
	await _wait_nbody_scene(controller, 5)
	if not is_equal_approx(controller.min_pixel_size_slider.value, 2.3) \
			or not is_equal_approx(controller.star_mat.get_shader_parameter("min_pixel_size"), 2.3):
		_fail("N-body render sliders did not persist across scenes")
	frame.pressed.emit()
	if not is_equal_approx(controller.orbit_cam.distance,
			controller.scene_def.view_distance(controller.solver)):
		_fail("N-body Frame did not restore the full scene framing")

	var original_positions: PackedFloat32Array = controller.solver._seed_pos.duplicate()
	var original_velocities: PackedFloat32Array = controller.solver._seed_vel.duplicate()
	var original_tint: Color = controller.star_mat.get_shader_parameter("seed_tint")
	seed.pressed.emit()
	if controller.random_seed != 10 \
			or (controller.solver._seed_pos == original_positions \
				and controller.solver._seed_vel == original_velocities) \
			or controller.star_mat.get_shader_parameter("seed_tint") == original_tint:
		_fail("N-body New seed did not increment the seed and change the initial state")
	var current_positions: PackedFloat32Array = controller.solver._seed_pos.duplicate()
	var current_velocities: PackedFloat32Array = controller.solver._seed_vel.duplicate()
	reset.pressed.emit()
	if controller.random_seed != 10 \
			or controller.solver._seed_pos != current_positions \
			or controller.solver._seed_vel != current_velocities:
		_fail("N-body Reset did not reproduce the current seed")


func _wait_nbody_scene(controller: Node, scene_index: int) -> void:
	var deadline := Time.get_ticks_msec() + 30000
	while not controller.capture_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not controller.capture_ready():
		_fail("N-body scene %d did not become ready" % scene_index)


func _fail(message: String) -> void:
	_failures.append(message)


func _report() -> void:
	if _failures.is_empty():
		print("SMOKE PASS %s" % _demo)
		get_tree().quit(0)
		return
	for message in _failures:
		print("SMOKE FAIL %s: %s" % [_demo, message])
	get_tree().quit(1)
