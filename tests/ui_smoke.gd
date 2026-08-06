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

	Input.use_accumulated_input = false
	# Real clicks in a focused test window would race the synthetic touches.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), true, "gear opens panel")
	await _check_toggle(menu, menu.get_node("TopRight/GearButton"), false, "gear closes panel")
	await _check_viewport_restored()
	_report()


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
