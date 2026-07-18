class_name NonEuclideanPlayer
extends CharacterBody3D

const PORTAL_EXIT_EPSILON := 0.001

@export var walk_speed := 4.5
@export var sprint_speed := 7.0
@export var acceleration := 24.0
@export var air_acceleration := 7.0
@export var jump_speed := 5.2
@export var gravity_strength := 12.0
@export var push_force := 90.0
@export var mouse_sensitivity := 0.12
@export var touch_sensitivity := 0.2
@export var fov := 75.0

var gravity_vector := Vector3.DOWN * 12.0
var gravity_field: GravityField3D
var controls_enabled := true

var _camera_pivot: Node3D
var _camera: Camera3D
var _pitch := 0.0
var _captured := false
var _touch_ui := false
var _joystick: VirtualJoystick
var _touch_sprinting := false
var _touch_jump_requested := false
var _portal_lock: Portal3D
var _last_portal_tick := -1
var _portal_previous_position := Vector3.ZERO


func _ready() -> void:
	add_to_group("portal_traveller")
	floor_snap_length = 0.35
	floor_max_angle = deg_to_rad(52.0)
	safe_margin = 0.03
	_camera_pivot = get_node_or_null("CameraPivot") as Node3D
	if _camera_pivot != null:
		_camera = _camera_pivot.get_node_or_null("Camera3D") as Camera3D
	if _camera != null:
		_camera.fov = fov
		_camera.cull_mask = Portal3D.WORLD_LAYER | Portal3D.MAIN_PORTAL_LAYER | Portal3D.PROXY_LAYER
	gravity_vector = gravity_vector.normalized() * gravity_strength
	_portal_previous_position = global_position
	_align_to_gravity()
	_touch_ui = VirtualJoystick.is_touch_ui()
	if _touch_ui:
		_joystick = VirtualJoystick.spawn(self)
	elif DisplayServer.get_name() != "headless":
		call_deferred("_capture_if_focused")


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
	if _captured and event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var yaw_delta := deg_to_rad(-motion.relative.x * mouse_sensitivity)
		global_basis = (Basis(up_direction, yaw_delta) * global_basis).orthonormalized()
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, -88.0, 88.0)
		if _camera_pivot != null:
			_camera_pivot.rotation.x = deg_to_rad(_pitch)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _touch_ui:
		if event is InputEventScreenDrag:
			var drag := event as InputEventScreenDrag
			var yaw_delta := deg_to_rad(-drag.relative.x * touch_sensitivity)
			global_basis = (Basis(up_direction, yaw_delta) * global_basis).orthonormalized()
			_pitch = clampf(_pitch - drag.relative.y * touch_sensitivity, -88.0, 88.0)
			if _camera_pivot != null:
				_camera_pivot.rotation.x = deg_to_rad(_pitch)
		return
	if not _captured and event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		capture_mouse()


func _physics_process(delta: float) -> void:
	_portal_previous_position = global_position
	if gravity_field != null:
		gravity_vector = gravity_field.sample_gravity(global_position)
	_align_to_gravity()
	_update_portal_lock()

	var local_input := Vector2.ZERO
	if controls_enabled and (_captured or _touch_ui):
		local_input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if controls_enabled and _joystick != null:
		local_input += _joystick.value
	var forward := (-global_basis.z).slide(up_direction).normalized()
	var right := global_basis.x.slide(up_direction).normalized()
	var movement := (right * local_input.x - forward * local_input.y).limit_length(1.0)
	var sprinting := controls_enabled and (Input.is_action_pressed("move_down") or _touch_sprinting)
	var speed := sprint_speed if sprinting else walk_speed
	var jump_requested := Input.is_action_just_pressed("move_up") or _touch_jump_requested
	_touch_jump_requested = false
	var target_tangent := movement * speed
	var tangent_velocity := velocity.slide(up_direction)
	var rate := acceleration if is_on_floor() else air_acceleration
	tangent_velocity = tangent_velocity.move_toward(target_tangent, rate * delta)
	var vertical_velocity := up_direction * velocity.dot(up_direction)
	velocity = tangent_velocity + vertical_velocity

	if is_on_floor():
		if velocity.dot(gravity_vector) > 0.0:
			velocity = velocity.slide(up_direction)
		if controls_enabled and (_captured or _touch_ui) and jump_requested:
			velocity += up_direction * jump_speed
	else:
		velocity += gravity_vector * delta

	move_and_slide()
	_push_rigid_bodies(movement)


func _push_rigid_bodies(movement: Vector3) -> void:
	if movement.length_squared() <= 0.000001:
		return
	for index in get_slide_collision_count():
		var collision := get_slide_collision(index)
		var body := collision.get_collider() as RigidBody3D
		if body == null or body.freeze:
			continue
		var push_direction := (-collision.get_normal()).slide(up_direction).normalized()
		if push_direction.dot(movement) <= 0.2:
			continue
		body.sleeping = false
		body.apply_central_force(push_direction * push_force)


func _align_to_gravity() -> void:
	if gravity_vector.length_squared() <= 0.000001:
		return
	var target_up := -gravity_vector.normalized()
	var current_up := global_basis.y.normalized()
	var cosine := clampf(current_up.dot(target_up), -1.0, 1.0)
	if cosine < 0.999999:
		var axis := current_up.cross(target_up)
		if axis.length_squared() <= 0.000001:
			axis = global_basis.x
		global_basis = (Basis(axis.normalized(), acos(cosine)) * global_basis).orthonormalized()
	up_direction = target_up


func request_portal_teleport(mapping_transform: Transform3D, exit_portal: Portal3D) -> void:
	if _last_portal_tick == Engine.get_physics_frames():
		return
	_last_portal_tick = Engine.get_physics_frames()
	global_transform = PortalMath.map_transform(mapping_transform, global_transform)
	velocity = PortalMath.map_vector(mapping_transform, velocity)
	gravity_vector = PortalMath.map_vector(mapping_transform, gravity_vector)
	gravity_field = null
	_portal_lock = exit_portal
	if exit_portal != null:
		global_position += exit_portal.get_normal() * minf(
			exit_portal.exit_clearance, PORTAL_EXIT_EPSILON)
		if exit_portal.gravity_override_enabled:
			gravity_vector = exit_portal.gravity_override
	_align_to_gravity()
	_portal_previous_position = global_position
	reset_physics_interpolation()


func can_use_portal(portal: Portal3D) -> bool:
	return _last_portal_tick != Engine.get_physics_frames() and portal != _portal_lock


func get_portal_previous_position() -> Vector3:
	return _portal_previous_position


func set_gravity_field(field: GravityField3D) -> void:
	gravity_field = field
	gravity_vector = field.sample_gravity(global_position)
	_align_to_gravity()


func clear_gravity_field(field: GravityField3D) -> void:
	if gravity_field == field:
		gravity_field = null


func set_pose(pose: Transform3D, new_gravity: Vector3 = Vector3.DOWN * 12.0) -> void:
	global_transform = pose
	velocity = Vector3.ZERO
	gravity_vector = new_gravity
	gravity_field = null
	_portal_lock = null
	_pitch = 0.0
	if _camera_pivot != null:
		_camera_pivot.rotation = Vector3.ZERO
	_align_to_gravity()
	_portal_previous_position = global_position
	reset_physics_interpolation()


func get_camera() -> Camera3D:
	return _camera


func set_controls_enabled(enabled: bool) -> void:
	controls_enabled = enabled
	if not enabled:
		_touch_sprinting = false
		_touch_jump_requested = false
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


func set_touch_sprinting(enabled: bool) -> void:
	_touch_sprinting = enabled


func request_touch_jump() -> void:
	_touch_jump_requested = true


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


func _capture_if_focused() -> void:
	if DisplayServer.window_is_focused():
		capture_mouse()


func _update_portal_lock() -> void:
	if _portal_lock == null:
		return
	var signed_distance := _portal_lock.signed_distance(global_position)
	if signed_distance >= PORTAL_EXIT_EPSILON * 0.5:
		_portal_lock = null
		return
	var release_distance := _portal_lock.activation_depth * 0.65 + 0.1
	if absf(signed_distance) > release_distance:
		_portal_lock = null


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
