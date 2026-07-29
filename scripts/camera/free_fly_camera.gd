class_name FreeFlyCamera
extends Node3D
const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
## FPS flythrough camera for raymarched fractals (VR-ready, desktop-first).
## Look: captured mouse (free mouselook from relative motion). Esc releases the
## cursor for the UI; click in the viewport recaptures it. No camera roll.
## Move: WASD + move_up/move_down, relative to the full look direction, with
## acceleration/damping smoothing (anti-nausea, no jerk).
## If de_query is set, movement is kept outside nearby fractal surfaces.

# --- Look ---
@export var mouse_sensitivity := 0.15
@export var touch_sensitivity := 0.2
@export var min_pitch := -89.0
@export var max_pitch := 89.0
@export var fov := 70.0

# --- Movement ---
@export var move_speed := 3.0       # cruise units/sec
@export var acceleration := 12.0    # ramp toward target velocity
@export var damping := 8.0          # ramp toward zero on release

## Callable(Vector3) -> float distance estimator, injected by the controller.
var de_query: Callable

var pitch := 0.0
var yaw := 0.0
var velocity := Vector3.ZERO
var motion_intensity := 0.0

var _captured := false
var _camera: Camera3D
var _touch_ui := false
var _joystick: VirtualJoystickScript


func _ready() -> void:
	_camera = _find_camera()
	if _camera:
		_camera.fov = fov
	_update_transform()
	# Touch devices have no mouse to capture: joystick moves, free drag looks.
	_touch_ui = VirtualJoystickScript.is_touch_ui()
	if _touch_ui:
		_joystick = VirtualJoystickScript.spawn(self)
	else:
		capture_mouse()


func _find_camera() -> Camera3D:
	for child in get_children():
		if child is Camera3D:
			return child
	push_warning("FreeFlyCamera: No Camera3D child found")
	return null


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


func is_captured() -> bool:
	return _captured


func _input(event: InputEvent) -> void:
	if _touch_ui:
		return
	if event.is_action_pressed("ui_cancel"):
		if _captured:
			release_mouse()
		else:
			capture_mouse()
		get_viewport().set_input_as_handled()
		return
	# Mouselook must run in _input: the GUI consumes motion events (the pinned
	# cursor can sit over the menu panel) before _unhandled_input ever fires.
	if _captured and event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		motion_intensity = maxf(motion_intensity, clampf(motion.relative.length() / 24.0, 0.0, 1.0))
		yaw -= motion.relative.x * mouse_sensitivity
		pitch = clampf(pitch - motion.relative.y * mouse_sensitivity, min_pitch, max_pitch)
		_update_transform()
		get_viewport().set_input_as_handled()
		return
	if _captured and event is InputEventMouseButton and event.pressed:
		var btn := (event as InputEventMouseButton).button_index
		if btn == MOUSE_BUTTON_WHEEL_UP:
			move_speed = minf(move_speed * 1.2, 150.0)
			get_viewport().set_input_as_handled()
		elif btn == MOUSE_BUTTON_WHEEL_DOWN:
			move_speed = maxf(move_speed / 1.2, 0.1)
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _touch_ui:
		# Any drag reaching here is a look drag: the joystick consumes its own
		# finger through the GUI, so it never shows up as unhandled.
		if event is InputEventScreenDrag:
			var drag := event as InputEventScreenDrag
			motion_intensity = maxf(motion_intensity, clampf(drag.relative.length() / 24.0, 0.0, 1.0))
			yaw -= drag.relative.x * touch_sensitivity
			pitch = clampf(pitch - drag.relative.y * touch_sensitivity, min_pitch, max_pitch)
			_update_transform()
		return

	# Recapture only on clicks the GUI did NOT consume — clicking the menu
	# (dropdowns, sliders) must never steal the cursor back.
	if not _captured and event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		capture_mouse()


func _process(delta: float) -> void:
	motion_intensity *= exp(-8.0 * delta)
	var input_dir := Vector3.ZERO
	if _captured:
		if Input.is_action_pressed("move_forward"):
			input_dir.z -= 1
		if Input.is_action_pressed("move_back"):
			input_dir.z += 1
		if Input.is_action_pressed("move_left"):
			input_dir.x -= 1
		if Input.is_action_pressed("move_right"):
			input_dir.x += 1
		if Input.is_action_pressed("move_up"):
			input_dir.y += 1
		if Input.is_action_pressed("move_down"):
			input_dir.y -= 1

	if _joystick != null:
		input_dir.x += _joystick.value.x
		input_dir.z += _joystick.value.y

	var speed := move_speed
	var dist := -1.0
	if de_query.is_valid():
		dist = maxf(de_query.call(position) as float, 0.0)

	var target := Vector3.ZERO
	if input_dir != Vector3.ZERO:
		var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))
		target = (basis * input_dir.limit_length(1.0)) * speed

	var rate := acceleration if target != Vector3.ZERO else damping
	var previous_velocity := velocity
	var decay := exp(-rate * delta)
	velocity = target + (previous_velocity - target) * decay
	motion_intensity = maxf(motion_intensity,
		clampf(velocity.length() / maxf(move_speed, 0.001), 0.0, 1.0))

	var step := target * delta + (previous_velocity - target) * (1.0 - decay) / maxf(rate, 1e-6)
	if dist >= 0.0 and step != Vector3.ZERO:
		var midpoint_dist := maxf(de_query.call(position + step * 0.5) as float, 0.0)
		var endpoint_dist := maxf(de_query.call(position + step) as float, 0.0)
		var moving_away := midpoint_dist > dist and endpoint_dist > midpoint_dist
		if not moving_away:
			var max_len := maxf(dist * 0.35, 0.0001)
			if step.length() > max_len:
				step = step.normalized() * max_len
	position += step
	_update_transform()


func _update_transform() -> void:
	rotation_degrees = Vector3(pitch, yaw, 0)


func _exit_tree() -> void:
	# Leaving the scene (Back button) must free the cursor for the menu.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ── Public API ───────────────────────────────────────────────────────────────

func get_camera() -> Camera3D:
	return _camera


func set_fov(value: float) -> void:
	fov = value
	if _camera:
		_camera.fov = value


func set_pose(pos: Vector3, new_yaw: float, new_pitch: float) -> void:
	position = pos
	yaw = new_yaw
	pitch = clampf(new_pitch, min_pitch, max_pitch)
	velocity = Vector3.ZERO
	motion_intensity = 0.0
	_update_transform()


func set_enabled(enabled: bool) -> void:
	set_process(enabled)
	set_process_input(enabled)
	set_process_unhandled_input(enabled)
	if _joystick != null:
		_joystick.visible = enabled
	if _touch_ui:
		return
	if enabled:
		capture_mouse()
	else:
		release_mouse()
