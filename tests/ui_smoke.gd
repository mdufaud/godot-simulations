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
	if _demo == "ocean_demo":
		await _check_ocean_actions(menu)
	if _demo == "ambient_fluid_demo":
		await _check_ambient_fluid_actions(menu)
	if _demo == "mixwell_demo":
		await _check_mixwell_periodic()
	if _demo == "tornado_demo":
		await _check_tornado_actions()

	Input.use_accumulated_input = false
	# Real clicks in a focused test window would race the synthetic touches.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
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
	for expected in ["Sea", "Throw", "Clear", "Freeze"]:
		if not buttons.has(expected):
			_fail("ocean action missing: %s" % expected)
	if _failures.size() > 0:
		return

	var initial_preset: int = _demo_root.current_preset_index
	buttons.Sea.pressed.emit()
	await get_tree().process_frame
	if _demo_root.current_preset_index == initial_preset:
		_fail("ocean sea action did not cycle the preset")

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
