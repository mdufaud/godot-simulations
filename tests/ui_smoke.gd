extends Node
## Touch-path UI smoke test for one demo, driven by tests/run_ui_smoke.sh.
##
## Loads the demo scene, waits for it to settle, then taps the SimMenu gear the way
## a finger would (emulated touch through Input) and asserts the options panel opens
## and closes again. Catches the class of regression where a demo overlay, a layout
## change or a mouse_filter covers the always-on controls on mobile.

const SETTLE_FRAMES := 120

var _demo := ""
var _frames := 0
var _done := false
var _failures: Array[String] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or not GameManager.SCENES.has(args[0]):
		printerr("usage: godot res://tests/ui_smoke.tscn -- <demo_key>")
		get_tree().quit(2)
		return
	_demo = args[0]
	GameManager.current_demo = _demo
	var packed: PackedScene = load(GameManager.SCENES[_demo])
	get_tree().root.add_child.call_deferred(packed.instantiate())


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
	_report()


## Taps [param button] and asserts the panel ends up in [param want_open].
func _check_toggle(menu: SimMenu, button: Button, want_open: bool, what: String) -> void:
	if not button.is_visible_in_tree():
		_fail("%s: button not visible" % what)
		return
	var rect := button.get_global_rect()
	var viewport := menu.get_viewport()
	var pos: Vector2 = viewport.get_final_transform() * (rect.position + rect.size * 0.5)

	# Hover first: a covering Control shows up here before the tap is even sent.
	var motion := InputEventMouseMotion.new()
	motion.position = rect.position + rect.size * 0.5
	viewport.push_input(motion, true)
	await get_tree().process_frame
	var hovered := viewport.gui_get_hovered_control()
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

	if menu.is_panel_open() != want_open:
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
