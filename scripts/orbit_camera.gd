class_name OrbitCamera
extends Node3D
## Caméra orbitale réutilisable avec support souris, tactile et clavier ZQSD/WASD.
## Attacher à un Node3D avec un Camera3D enfant.
## Utilise _unhandled_input() : les événements consommés par l'UI (sliders, boutons)
## n'arrivent jamais ici → pas besoin de flag is_over_ui.

# --- Orbit parameters ---
@export var target := Vector3.ZERO
@export var distance := 15.0
@export var pitch := -25.0   # degrés (négatif = vue plongeante)
@export var yaw := 0.0       # degrés

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

# --- Touch / pinch state ---
var _touch_points := {}       # index → position (Vector2)
var _prev_pinch_distance := 0.0


func _ready() -> void:
	_camera = _find_camera()
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

	# ZQSD / WASD movement (déplace le centre de l'orbite)
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

		if move_dir != Vector3.ZERO:
			move_dir = move_dir.normalized()
			# Rotation relative au yaw de la caméra (pas au pitch, pour rester au sol)
			var yaw_rad := deg_to_rad(yaw)
			var rotated := Vector3(
				move_dir.x * cos(yaw_rad) - move_dir.z * sin(yaw_rad),
				0,
				move_dir.x * sin(yaw_rad) + move_dir.z * cos(yaw_rad)
			)
			target += rotated * move_speed * delta

	_update_transform()


func _unhandled_input(event: InputEvent) -> void:
	# ── Mouse ────────────────────────────────────────────────────────────
	if event is InputEventMouseButton:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging = btn.pressed
		elif enable_zoom:
			# Block zoom when mouse hovers any UI control (panels, sliders, etc.)
			if btn.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				if get_viewport().gui_get_hovered_control() != null:
					return
			if btn.button_index == MOUSE_BUTTON_WHEEL_UP:
				distance = clampf(distance - zoom_speed, min_distance, max_distance)
			elif btn.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				distance = clampf(distance + zoom_speed, min_distance, max_distance)

	elif event is InputEventMouseMotion and _is_dragging:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * rotation_speed
		pitch = clampf(pitch - motion.relative.y * rotation_speed, min_pitch, max_pitch)

	# ── Touch (single finger = orbit, two fingers = pinch-to-zoom) ───────
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
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

## Retourne le nœud Camera3D enfant.
func get_camera() -> Camera3D:
	return _camera


## Recentre l'orbite sur une position.
func set_target(pos: Vector3) -> void:
	target = pos


## Active/désactive tous les contrôles.
func set_enabled(enabled: bool) -> void:
	set_process(enabled)
	set_process_unhandled_input(enabled)
