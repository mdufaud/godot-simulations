class_name OrbitCamera
extends Node3D
## Reusable orbit camera with mouse, touch and WASD keyboard support.
## Attach to a Node3D with a Camera3D child.
## Uses _unhandled_input(): events consumed by the UI (sliders, buttons)
## never reach here → no need for an is_over_ui flag.

# --- Orbit parameters ---
@export var target := Vector3.ZERO
@export var distance := 15.0
@export var pitch := -25.0   # degrees (negative = looking down)
@export var yaw := 0.0       # degrees

# --- Tuning ---
@export var rotation_speed := 0.3
@export var zoom_speed := 1.0
@export var move_speed := 15.0
@export var min_distance := 5.0
@export var max_distance := 30.0
@export var min_pitch := -80.0
@export var max_pitch := -5.0

# --- Auto-rotate ---
@export var auto_rotate := false
@export var auto_rotate_speed := 0.15

# --- Features toggle ---
@export var enable_movement := true
@export var enable_zoom := true

# --- Internal state ---
var _is_dragging := false
var _camera: Camera3D
var _joystick: VirtualJoystick

# --- Touch / pinch state ---
var _touch_points := {}       # index → position (Vector2)
var _prev_pinch_distance := 0.0


func _ready() -> void:
	_camera = _find_camera()
	if enable_movement and VirtualJoystick.is_touch_ui():
		_joystick = VirtualJoystick.spawn(self)
	_update_transform()


func _find_camera() -> Camera3D:
	for child in get_children():
		if child is Camera3D:
			return child
	push_warning("OrbitCamera: No Camera3D child found")
	return null


func _process(delta: float) -> void:
	# Auto-rotation
	if auto_rotate and not _is_dragging:
		yaw += auto_rotate_speed * delta * 60.0

	# WASD movement (moves the orbit center)
	if enable_movement:
		var move_dir := Vector3.ZERO
		if Input.is_action_pressed("move_forward"):
			move_dir.z -= 1
		if Input.is_action_pressed("move_back"):
			move_dir.z += 1
		if Input.is_action_pressed("move_left"):
			move_dir.x -= 1
		if Input.is_action_pressed("move_right"):
			move_dir.x += 1

		if _joystick != null:
			move_dir.x += _joystick.value.x
			move_dir.z += _joystick.value.y

		if move_dir != Vector3.ZERO:
			auto_rotate = false
			move_dir = move_dir.limit_length(1.0)
			# Rotation relative to the camera's yaw (not pitch, to stay grounded)
			var rotated := move_dir.rotated(Vector3.UP, deg_to_rad(yaw))
			target += rotated * move_speed * delta

	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	# A live finger also emits emulated mouse events; without this guard the
	# same drag rotates the camera twice on mobile.
	if not _touch_points.is_empty() \
			and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	# ── Mouse ────────────────────────────────────────────────────────────
	if event is InputEventMouseButton:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging = btn.pressed
			if btn.pressed:
				auto_rotate = false
		elif enable_zoom:
			# Block zoom when mouse hovers any UI control (panels, sliders, etc.)
			if btn.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				if get_viewport().gui_get_hovered_control() != null:
					return
			if btn.button_index == MOUSE_BUTTON_WHEEL_UP:
				distance = clampf(distance - zoom_speed, min_distance, max_distance)
				auto_rotate = false
			elif btn.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				distance = clampf(distance + zoom_speed, min_distance, max_distance)
				auto_rotate = false

	elif event is InputEventMouseMotion and _is_dragging:
		var motion := event as InputEventMouseMotion
		auto_rotate = false
		yaw -= motion.relative.x * rotation_speed
		pitch = clampf(pitch - motion.relative.y * rotation_speed, min_pitch, max_pitch)

	# ── Touch (single finger = orbit, two fingers = pinch-to-zoom) ───────
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			auto_rotate = false
			_touch_points[touch.index] = touch.position
		else:
			_touch_points.erase(touch.index)

		# Update drag state
		_is_dragging = _touch_points.size() == 1

		# Init pinch distance when second finger lands
		if _touch_points.size() == 2:
			var pts := _touch_points.values()
			_prev_pinch_distance = (pts[0] as Vector2).distance_to(pts[1] as Vector2)

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		auto_rotate = false
		_touch_points[drag.index] = drag.position

		if _touch_points.size() == 1:
			# Single finger → orbit
			yaw -= drag.relative.x * rotation_speed
			pitch = clampf(pitch - drag.relative.y * rotation_speed, min_pitch, max_pitch)
		elif _touch_points.size() >= 2 and enable_zoom:
			# Pinch → zoom
			var pts := _touch_points.values()
			var cur_dist := (pts[0] as Vector2).distance_to(pts[1] as Vector2)
			if _prev_pinch_distance > 0.0:
				var delta_dist := cur_dist - _prev_pinch_distance
				distance = clampf(distance - delta_dist * 0.02, min_distance, max_distance)
			_prev_pinch_distance = cur_dist


func _update_transform() -> void:
	position = target
	rotation_degrees = Vector3(pitch, yaw, 0)
	if _camera:
		_camera.position = Vector3(0, 0, distance)


# ── Public API ───────────────────────────────────────────────────────────────

## Returns the child Camera3D node.
func get_camera() -> Camera3D:
	return _camera


## Enables/disables all controls.
func set_enabled(enabled: bool) -> void:
	set_process(enabled)
	set_process_unhandled_input(enabled)
