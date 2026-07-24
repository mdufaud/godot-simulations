class_name FpsWalker
extends CharacterBody3D
const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
## Grounded first-person walker: captured-mouse look, WASD walk relative to yaw,
## sprint on move_down (Shift), jump on move_up (Space), gravity + floor snap.
## Esc releases the cursor for the UI; click in the viewport recaptures it.
## Touch devices get a VirtualJoystickScript for movement and free drag for look.

@export var mouse_sensitivity := 0.15
@export var touch_sensitivity := 0.2
@export var min_pitch := -89.0
@export var max_pitch := 89.0
@export var walk_speed := 4.0
@export var sprint_speed := 7.0
@export var jump_velocity := 4.5
@export var acceleration := 10.0

var pitch := 0.0
var yaw := 0.0

var _captured := false
var _touch_ui := false
var _joystick: VirtualJoystickScript
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.6
	_update_look()
	_touch_ui = VirtualJoystickScript.is_touch_ui()
	if _touch_ui:
		_joystick = VirtualJoystickScript.spawn(self)
	else:
		capture_mouse()


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


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
		yaw -= motion.relative.x * mouse_sensitivity
		pitch = clampf(pitch - motion.relative.y * mouse_sensitivity, min_pitch, max_pitch)
		_update_look()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _touch_ui:
		if event is InputEventScreenDrag:
			var drag := event as InputEventScreenDrag
			yaw -= drag.relative.x * touch_sensitivity
			pitch = clampf(pitch - drag.relative.y * touch_sensitivity, min_pitch, max_pitch)
			_update_look()
		return
	# Recapture only on clicks the GUI did NOT consume — clicking the menu
	# (dropdowns, sliders) must never steal the cursor back.
	if not _captured and event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		capture_mouse()


func _physics_process(delta: float) -> void:
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
	if _joystick != null:
		input_dir.x += _joystick.value.x
		input_dir.z += _joystick.value.y

	var speed := sprint_speed if Input.is_action_pressed("move_down") else walk_speed
	var target := Basis.from_euler(Vector3(0, deg_to_rad(yaw), 0)) * input_dir.limit_length(1.0) * speed
	velocity.x = move_toward(velocity.x, target.x, acceleration * speed * delta)
	velocity.z = move_toward(velocity.z, target.z, acceleration * speed * delta)

	if is_on_floor():
		if _captured and Input.is_action_just_pressed("move_up"):
			velocity.y = jump_velocity
	else:
		velocity.y -= _gravity * delta

	move_and_slide()


func _update_look() -> void:
	rotation_degrees = Vector3(0, yaw, 0)
	if _camera:
		_camera.rotation_degrees = Vector3(pitch, 0, 0)


func _exit_tree() -> void:
	# Leaving the scene (Back button) must free the cursor for the menu.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func set_pose(pos: Vector3, new_yaw: float, new_pitch: float) -> void:
	global_position = pos
	yaw = new_yaw
	pitch = clampf(new_pitch, min_pitch, max_pitch)
	velocity = Vector3.ZERO
	_update_look()


func get_camera() -> Camera3D:
	return _camera
