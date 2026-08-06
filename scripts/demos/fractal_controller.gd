extends Control
## 2D Fractal Explorer — deep-zoom fractal viewer.
##
## Rendering lives in [FractalView], the float64 view state in [FractalCamera],
## the cinematic tour in [FractalAutopilot]. What is left here is interaction:
## drag = pan (content follows the cursor), wheel = smooth zoom anchored at the
## cursor, one finger = pan, two fingers = pinch zoom.

const DRAG_DEADZONE := 3.0

@onready var _view_low: SubViewport = $ViewLow
@onready var _view_high: SubViewport = $ViewHigh
@onready var _rect_low: ColorRect = $ViewLow/Rect
@onready var _rect_high: ColorRect = $ViewHigh/Rect
@onready var _display: ColorRect = $Display
@onready var _menu: SimMenu = $UI/SimMenu

var _camera := FractalCamera.new()
var _view := FractalView.new()
var config: FractalConfig = FractalConfig.new()
var _autopilot := FractalAutopilot.new(_camera)
var _menu_builder: FractalMenu

var _mouse_down := false
var _is_dragging := false
var _drag_start := Vector2.ZERO

# index → position; a live finger also emits emulated mouse events.
var _touch_points := {}
var _prev_pinch_distance := 0.0


func _ready() -> void:
	_view.config = config
	_view.camera = _camera
	_view.view_low = _view_low
	_view.view_high = _view_high
	_view.rect_low = _rect_low
	_view.rect_high = _rect_high
	_view.display = _display
	_view.host = self
	_view.start()

	get_window().size_changed.connect(_resize_viewports)
	_resize_viewports()

	_menu_builder = FractalMenu.new(_camera, _view, _autopilot, reset)
	_menu_builder.build(_menu)

	_autopilot.pick(0)
	reset()


func _process(delta: float) -> void:
	_camera.viewport_size = size
	if not _mouse_down:
		_autopilot.update(delta)
	_camera.update_motion(delta)
	_view.update(delta)
	_menu_builder.update_labels(delta)


## Back to the overview framing of the current fractal type.
func reset() -> void:
	_camera.reset_for_type()
	_view.invalidate_orbit()
	_autopilot.restart()


func _resize_viewports() -> void:
	_view.resize(get_window().size)


func _gui_input(event: InputEvent) -> void:
	_camera.viewport_size = size
	# A live finger also emits emulated mouse events; without this guard a
	# one-finger drag pans twice on mobile, and pinching pans while zooming.
	if not _touch_points.is_empty() \
			and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_mouse_down = button.pressed
			_is_dragging = false
			if button.pressed:
				_drag_start = button.position
		elif button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and button.pressed:
			accept_event()
			var direction := 1.0 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			_camera.zoom_at(direction * FractalCamera.ZOOM_STEP, button.position,
				not _autopilot.enabled)

	elif event is InputEventMouseMotion and _mouse_down:
		var motion := event as InputEventMouseMotion
		if not _is_dragging:
			if _drag_start.distance_squared_to(motion.position) < DRAG_DEADZONE * DRAG_DEADZONE:
				return
			_is_dragging = true
		_camera.pan_by(motion.relative)

	# ── Touch: one finger = pan, two fingers = pinch-to-zoom ─────────────
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_points[touch.index] = touch.position
		else:
			_touch_points.erase(touch.index)
		if _touch_points.size() == 2:
			var points := _touch_points.values()
			_prev_pinch_distance = (points[0] as Vector2).distance_to(points[1] as Vector2)

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touch_points[drag.index] = drag.position

		if _touch_points.size() < 2:
			_camera.pan_by(drag.relative)
		else:
			var points := _touch_points.values()
			var a := points[0] as Vector2
			var b := points[1] as Vector2
			var current := a.distance_to(b)
			# Spreading the fingers by a factor f zooms in by ln(f) in log space.
			if _prev_pinch_distance > 1.0 and current > 1.0:
				_camera.zoom_at(log(current / _prev_pinch_distance), (a + b) * 0.5,
					not _autopilot.enabled)
			_prev_pinch_distance = current
