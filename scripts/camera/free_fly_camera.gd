class_name FreeFlyCamera
extends Node3D
const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
## FPS flythrough camera for raymarched fractals (VR-ready, desktop-first).
## Look: captured mouse (free mouselook from relative motion). Esc releases the
## cursor for the UI; click in the viewport recaptures it. No camera roll.
## Move: WASD + move_up/fly_down (Space/Ctrl), relative to the full look
## direction, with acceleration/damping smoothing (anti-nausea, no jerk);
## fly_boost (Shift) multiplies the speed while held.
## If de_query is set, flight is scaled to the free distance in view (the
## nearest surface a few rays through the frustum reach): move_speed is then
## the fraction of that distance covered per second, so what is on screen
## always streams by at the same rate, at any scale. No step ever exceeds half
## the free length sphere-traced along it, so it never passes through.
## The position is kept in float64 ([member precise_position]) and mirrored
## onto the node: a Node3D position (float32) stops resolving moves under 1e-7.

# --- Look ---
@export var mouse_sensitivity := 0.15
@export var touch_sensitivity := 0.2
@export var min_pitch := -89.0
@export var max_pitch := 89.0
@export var fov := 70.0

# --- Movement ---
@export var move_speed := 3.0       # cruise units/sec, or free distances/sec with de_query
@export var acceleration := 12.0    # ramp toward target velocity
@export var damping := 8.0          # ramp toward zero on release

## Callable(x: float, y: float, z: float) -> float distance estimator, injected
## by the controller.
var de_query: Callable
## Free distance below which the camera counts as touching a surface: only
## moves that do not close in further get through.
var min_flight_distance := 1e-4
## The camera position, in float64 (x, y, z).
var precise_position := PackedFloat64Array([0.0, 0.0, 0.0])

var pitch := 0.0
var yaw := 0.0
var velocity := Vector3.ZERO
var motion_intensity := 0.0

## Seconds the speed takes to follow the free distance, in log space: a change
## of scale eases in both ways, the step clamp alone guards against collisions.
const DISTANCE_SMOOTH_S := 0.2
## Speed factor while fly_boost is held.
const BOOST_FACTOR := 4.0
## Frustum directions (x, y at z = -1) probed for the free distance in view.
const VIEW_RAYS: Array[Vector2] = [
	Vector2(0.0, 0.0), Vector2(0.5, 0.3), Vector2(-0.5, 0.3), Vector2(0.5, -0.3),
	Vector2(-0.5, -0.3),
]
const VIEW_RAY_STEPS := 16
const STEP_TRACE_STEPS := 8
var _flight_distance := -1.0

var _captured := false
var _camera: Camera3D
var _touch_ui := false
var _joystick: VirtualJoystickScript


func _ready() -> void:
	precise_position = PackedFloat64Array([position.x, position.y, position.z])
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
	if get_tree().has_group("open_sim_menu"):
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true
	add_to_group("captured_mouse")


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false
	remove_from_group("captured_mouse")


func is_captured() -> bool:
	return _captured


func _input(event: InputEvent) -> void:
	if _touch_ui:
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
	if event.is_action_pressed("ui_cancel") and not _touch_ui:
		if _captured:
			release_mouse()
		else:
			capture_mouse()
		get_viewport().set_input_as_handled()
		return
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
		if Input.is_action_pressed("fly_down"):
			input_dir.y -= 1

	if _joystick != null:
		input_dir.x += _joystick.value.x
		input_dir.z += _joystick.value.y

	var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))
	var speed := move_speed
	if _captured and Input.is_action_pressed("fly_boost"):
		speed *= BOOST_FACTOR
	var dist := -1.0
	if de_query.is_valid():
		dist = maxf(_distance_at(Vector3.ZERO), 0.0)
		var open := maxf(_view_free_distance(basis, dist), min_flight_distance)
		if _flight_distance <= 0.0:
			_flight_distance = open
		else:
			_flight_distance = exp(lerpf(log(open), log(_flight_distance),
				exp(-delta / DISTANCE_SMOOTH_S)))
		speed *= _flight_distance

	var target := Vector3.ZERO
	if input_dir != Vector3.ZERO:
		target = (basis * input_dir.limit_length(1.0)) * speed

	var rate := acceleration if target != Vector3.ZERO else damping
	var previous_velocity := velocity
	var decay := exp(-rate * delta)
	velocity = target + (previous_velocity - target) * decay
	motion_intensity = maxf(motion_intensity,
		clampf(velocity.length() / maxf(speed, 1e-6), 0.0, 1.0))

	var step := target * delta + (previous_velocity - target) * (1.0 - decay) / maxf(rate, 1e-6)
	var step_len := step.length()
	if dist >= min_flight_distance and step_len > dist * 0.5:
		var direction := step / step_len
		var max_len := _trace(direction, dist, step_len * 2.0, STEP_TRACE_STEPS) * 0.5
		if step_len > max_len:
			step = direction * max_len
			velocity = velocity.limit_length(max_len / maxf(delta, 1e-6))
	elif dist >= 0.0 and dist < min_flight_distance and _distance_at(step) < dist:
		# Touching: only moves that do not close in further, so it can back out.
		step = Vector3.ZERO
		velocity = Vector3.ZERO
	precise_position[0] += step.x
	precise_position[1] += step.y
	precise_position[2] += step.z
	position = Vector3(precise_position[0], precise_position[1], precise_position[2])
	_update_transform()


## Distance estimate at the camera plus [param offset].
func _distance_at(offset: Vector3) -> float:
	return de_query.call(precise_position[0] + offset.x, precise_position[1] + offset.y,
		precise_position[2] + offset.z) as float


## Free length along [param direction], sphere-traced from [param start] (the
## camera's own free distance, already known to be clear) up to [param limit].
func _trace(direction: Vector3, start: float, limit: float, steps: int) -> float:
	var t := start
	for i in steps:
		if t >= limit:
			return limit
		var d := _distance_at(direction * t)
		if d <= t * 1e-3:
			break
		t += d
	return minf(t, limit)


## Distance to the nearest surface the view rays reach, never under the
## camera's own free distance.
func _view_free_distance(basis: Basis, dist: float) -> float:
	var best := INF
	for ray in VIEW_RAYS:
		var direction := (basis * Vector3(ray.x, ray.y, -1.0)).normalized()
		best = _trace(direction, dist, best, VIEW_RAY_STEPS)
	return best


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
	set_precise_pose(pos.x, pos.y, pos.z, new_yaw, new_pitch)


func set_precise_pose(x: float, y: float, z: float, new_yaw: float, new_pitch: float) -> void:
	precise_position = PackedFloat64Array([x, y, z])
	position = Vector3(x, y, z)
	yaw = new_yaw
	pitch = clampf(new_pitch, min_pitch, max_pitch)
	velocity = Vector3.ZERO
	_flight_distance = -1.0
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
