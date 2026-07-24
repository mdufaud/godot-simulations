extends Control
## On-screen analog stick for touch devices, polled each frame via `value`.
## x = right, y = down (so stick-up = -y = forward for a camera).
## Handles mouse too, so FORCE_TOUCH_UI=1 lets you test the mobile layout on desktop.

const RADIUS := 90.0
const KNOB_RADIUS := 34.0
const MARGIN := 40.0
const DEADZONE := 0.15

## Normalized stick offset, zeroed inside the deadzone.
var value := Vector2.ZERO

var _knob := Vector2.ZERO
var _touch := -1
var _mouse := false


## True on Android/iOS. FORCE_TOUCH_UI=1 fakes it for desktop testing.
static func is_touch_ui() -> bool:
	return OS.has_feature("mobile") or OS.get_environment("FORCE_TOUCH_UI") == "1"


## Adds a joystick on its own CanvasLayer under `parent` (any Node works).
static func spawn(parent: Node) -> Control:
	var layer := CanvasLayer.new()
	layer.name = "TouchControls"
	parent.add_child(layer)
	var Script: GDScript = load("res://scripts/ui/virtual_joystick.gd")
	var stick: Control = Script.new()
	layer.add_child(stick)
	return stick


func _ready() -> void:
	var side := RADIUS * 2.0
	anchor_left = 0.0
	anchor_top = 1.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_left = MARGIN
	offset_top = -(side + MARGIN)
	offset_right = MARGIN + side
	offset_bottom = -MARGIN
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	# A live finger also emits emulated mouse events; ignore those or the knob
	# gets driven twice.
	if _touch != -1 and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _touch == -1:
				_touch = touch.index
				_move_knob(touch.position)
		elif touch.index == _touch:
			_release()
		accept_event()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _touch:
			_move_knob(drag.position)
			accept_event()

	elif event is InputEventMouseButton:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_LEFT:
			if btn.pressed:
				_mouse = true
				_move_knob(btn.position)
			else:
				_release()
			accept_event()

	elif event is InputEventMouseMotion and _mouse:
		_move_knob((event as InputEventMouseMotion).position)
		accept_event()


func _move_knob(pos: Vector2) -> void:
	_knob = ((pos - size * 0.5) / RADIUS).limit_length(1.0)
	value = Vector2.ZERO if _knob.length() < DEADZONE else _knob
	queue_redraw()


func _release() -> void:
	_touch = -1
	_mouse = false
	_knob = Vector2.ZERO
	value = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var knob := center + _knob * RADIUS
	# Dark rim under the light one so the stick stays readable on bright scenes.
	draw_circle(center, RADIUS, Color(0, 0, 0, 0.18))
	draw_arc(center, RADIUS, 0.0, TAU, 48, Color(0, 0, 0, 0.35), 4.0, true)
	draw_arc(center, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.45), 2.0, true)
	draw_circle(knob, KNOB_RADIUS, Color(1, 1, 1, 0.45))
	draw_arc(knob, KNOB_RADIUS, 0.0, TAU, 32, Color(0, 0, 0, 0.4), 2.0, true)
