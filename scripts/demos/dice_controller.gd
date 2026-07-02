extends Node3D
## Dice throwing demo with mouse/touch swipe mechanics

@onready var table: StaticBody3D = $Table
@onready var dice_container: Node3D = $DiceContainer
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var throw_indicator: MeshInstance3D = $ThrowIndicator
@onready var info_label: Label = $UI/Control/InfoPanel/VBoxContainer/InfoLabel
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel
@onready var result_label: Label = $UI/Control/InfoPanel/VBoxContainer/ResultLabel
@onready var throw_btn: Button = $UI/Control/ThrowButton
@onready var reset_btn: Button = $UI/Control/ResetButton

const DICE_SIZE := 0.5
const THROW_HEIGHT := 2.0
const MIN_THROW_FORCE := 2.0
const MAX_THROW_FORCE := 10.0
const SWIPE_FORCE_MULTIPLIER := 0.005

var dice_meshes: Array[RigidBody3D] = []
var is_dragging := false
var drag_start := Vector2.ZERO
var drag_current := Vector2.ZERO
var dice_count: int = 5
var dice_are_rolling := false
var roll_check_timer := 0.0

# Dice face values (dot positions for each face)
const DICE_DOTS := {
	1: [Vector2(0.5, 0.5)],
	2: [Vector2(0.25, 0.25), Vector2(0.75, 0.75)],
	3: [Vector2(0.25, 0.25), Vector2(0.5, 0.5), Vector2(0.75, 0.75)],
	4: [Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.25, 0.75), Vector2(0.75, 0.75)],
	5: [Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.5, 0.5), Vector2(0.25, 0.75), Vector2(0.75, 0.75)],
	6: [Vector2(0.25, 0.2), Vector2(0.75, 0.2), Vector2(0.25, 0.5), Vector2(0.75, 0.5), Vector2(0.25, 0.8), Vector2(0.75, 0.8)],
}


func _ready() -> void:
	dice_count = GameManager.get_setting("dice_count", 1)
	_create_dice()
	_setup_throw_indicator()
	_create_walls()
	
	# Configure orbit camera (top-down view of the table)
	orbit_cam.target = Vector3(0, 0, 0)
	orbit_cam.distance = 8.0
	orbit_cam.pitch = -55.0
	orbit_cam.yaw = 0.0
	orbit_cam.min_distance = 4.0
	orbit_cam.max_distance = 20.0
	orbit_cam.move_speed = 8.0
	
	throw_btn.pressed.connect(_on_throw_pressed)
	reset_btn.pressed.connect(_on_reset_pressed)


func _process(delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	
	# Update throw indicator during drag
	if is_dragging:
		_update_throw_indicator()
	
	# Check if dice stopped rolling
	if dice_are_rolling:
		roll_check_timer += delta
		if roll_check_timer > 0.5:
			roll_check_timer = 0.0
			if _check_dice_stopped():
				dice_are_rolling = false
				_calculate_results()


func _input(event: InputEvent) -> void:
	# Mouse swipe input (consumes event to prevent orbit camera from interfering)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				if _is_swipe_area(mouse_event.position):
					_start_drag(mouse_event.position)
					get_viewport().set_input_as_handled()
			else:
				if is_dragging:
					_end_drag(mouse_event.position)
					get_viewport().set_input_as_handled()
	
	if event is InputEventMouseMotion and is_dragging:
		drag_current = event.position
		get_viewport().set_input_as_handled()
	
	# Touch input (same logic)
	if event is InputEventScreenTouch:
		if event.pressed:
			if _is_swipe_area(event.position):
				_start_drag(event.position)
				get_viewport().set_input_as_handled()
		else:
			if is_dragging:
				_end_drag(event.position)
				get_viewport().set_input_as_handled()
	
	if event is InputEventScreenDrag and is_dragging:
		drag_current = event.position
		get_viewport().set_input_as_handled()


func _start_drag(pos: Vector2) -> void:
	is_dragging = true
	drag_start = pos
	drag_current = pos
	throw_indicator.visible = true


## Check if position is in the swipe area (not over UI elements)
func _is_swipe_area(pos: Vector2) -> bool:
	return pos.y >= 100 and pos.x >= 200


func _end_drag(position: Vector2) -> void:
	if not is_dragging:
		return
	
	is_dragging = false
	throw_indicator.visible = false
	
	var swipe := position - drag_start
	if swipe.length() > 30:  # Minimum swipe distance
		_throw_dice(swipe)


func _throw_dice(swipe: Vector2) -> void:
	# Calculate throw direction and force from swipe
	var force := clampf(swipe.length() * SWIPE_FORCE_MULTIPLIER, MIN_THROW_FORCE, MAX_THROW_FORCE)
	
	# Convert 2D swipe to 3D direction - gentle arc
	var direction := Vector3(
		swipe.x * 0.008,
		0.3 + (force / MAX_THROW_FORCE) * 0.2,
		-swipe.y * 0.008
	).normalized()
	
	dice_are_rolling = true
	result_label.text = "Rolling..."
	
	for dice in dice_meshes:
		# Reset position - start in center
		dice.linear_velocity = Vector3.ZERO
		dice.angular_velocity = Vector3.ZERO
		dice.position = Vector3(
			randf_range(-0.3, 0.3),
			THROW_HEIGHT,
			randf_range(0, 0.5)
		)
		dice.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		
		# Apply throw impulse - much gentler
		var random_offset := Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05))
		dice.apply_central_impulse((direction + random_offset) * force * dice.mass)
		
		# Very gentle spin - just enough to tumble
		dice.apply_torque_impulse(Vector3(
			randf_range(-0.5, 0.5),
			randf_range(-0.5, 0.5),
			randf_range(-0.5, 0.5)
		))


func _create_dice() -> void:
	for i in range(dice_count):
		var dice := _create_single_die()
		dice.position = Vector3(
			(i - dice_count / 2.0) * DICE_SIZE * 1.5,
			DICE_SIZE,
			0
		)
		dice_container.add_child(dice)
		dice_meshes.append(dice)


func _create_walls() -> void:
	# Create box walls to contain dice
	var wall_height := 0.5
	var wall_thickness := 0.3
	var table_size := Vector2(8, 6)  # Match table dimensions
	
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.35, 0.2, 0.12)
	wall_mat.roughness = 0.7
	
	# Wall positions: front, back, left, right
	var walls := [
		{"pos": Vector3(0, wall_height / 2, table_size.y / 2), "size": Vector3(table_size.x, wall_height, wall_thickness)},
		{"pos": Vector3(0, wall_height / 2, -table_size.y / 2), "size": Vector3(table_size.x, wall_height, wall_thickness)},
		{"pos": Vector3(-table_size.x / 2, wall_height / 2, 0), "size": Vector3(wall_thickness, wall_height, table_size.y)},
		{"pos": Vector3(table_size.x / 2, wall_height / 2, 0), "size": Vector3(wall_thickness, wall_height, table_size.y)},
	]
	
	for wall_data in walls:
		var wall := StaticBody3D.new()
		wall.position = wall_data["pos"]
		
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = wall_data["size"]
		mesh.mesh = box
		mesh.material_override = wall_mat
		wall.add_child(mesh)
		
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = wall_data["size"]
		collision.shape = shape
		wall.add_child(collision)
		
		add_child(wall)


func _create_single_die() -> RigidBody3D:
	var dice := RigidBody3D.new()
	dice.mass = 1.0  # Heavier dice for more realistic physics
	dice.angular_damp = 3.0  # Stop crazy spinning
	dice.linear_damp = 0.5  # Slow down movement
	
	# Physics material for good bouncing
	var physics_mat := PhysicsMaterial.new()
	physics_mat.bounce = 0.2  # Less bouncy
	physics_mat.friction = GameManager.get_setting("dice_table_friction", 0.8)
	dice.physics_material_override = physics_mat
	
	# Main cube mesh
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3.ONE * DICE_SIZE
	mesh_instance.mesh = box_mesh
	
	# White dice material
	var dice_mat := StandardMaterial3D.new()
	dice_mat.albedo_color = Color(0.95, 0.95, 0.92)
	dice_mat.roughness = 0.3
	dice_mat.metallic = 0.0
	mesh_instance.material_override = dice_mat
	
	dice.add_child(mesh_instance)
	
	# Collision shape
	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3.ONE * DICE_SIZE
	collision.shape = box_shape
	dice.add_child(collision)
	
	# Add dots to each face
	_add_dots_to_die(dice)
	
	return dice


func _add_dots_to_die(dice: RigidBody3D) -> void:
	# Face normal directions and their corresponding values
	# Standard dice: opposite faces sum to 7
	var faces := {
		Vector3.UP: 1,      # +Y = 1
		Vector3.DOWN: 6,    # -Y = 6
		Vector3.RIGHT: 2,   # +X = 2
		Vector3.LEFT: 5,    # -X = 5
		Vector3.BACK: 3,    # +Z = 3
		Vector3.FORWARD: 4, # -Z = 4
	}
	
	var dot_mat := StandardMaterial3D.new()
	dot_mat.albedo_color = Color(0.1, 0.1, 0.1)
	dot_mat.roughness = 0.5
	
	for face_dir in faces:
		var face_value: int = faces[face_dir]
		var dots: Array = DICE_DOTS[face_value]
		
		for dot_pos in dots:
			var dot := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.04
			sphere.height = 0.08
			dot.mesh = sphere
			dot.material_override = dot_mat
			
			# Position dot on face
			var local_pos := Vector3.ZERO
			var half_size := DICE_SIZE / 2.0 + 0.02
			var dot_offset: Vector2 = (dot_pos - Vector2(0.5, 0.5)) * DICE_SIZE * 0.7
			
			if face_dir == Vector3.UP:
				local_pos = Vector3(dot_offset.x, half_size, dot_offset.y)
			elif face_dir == Vector3.DOWN:
				local_pos = Vector3(dot_offset.x, -half_size, -dot_offset.y)
			elif face_dir == Vector3.RIGHT:
				local_pos = Vector3(half_size, dot_offset.y, dot_offset.x)
			elif face_dir == Vector3.LEFT:
				local_pos = Vector3(-half_size, dot_offset.y, -dot_offset.x)
			elif face_dir == Vector3.BACK:
				local_pos = Vector3(dot_offset.x, dot_offset.y, half_size)
			elif face_dir == Vector3.FORWARD:
				local_pos = Vector3(-dot_offset.x, dot_offset.y, -half_size)
			
			dot.position = local_pos
			dice.add_child(dot)


func _setup_throw_indicator() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.05
	mesh.bottom_radius = 0.15
	mesh.height = 1.0
	throw_indicator.mesh = mesh
	
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.8, 0.3, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	throw_indicator.material_override = mat
	throw_indicator.visible = false


func _update_throw_indicator() -> void:
	var swipe := drag_current - drag_start
	var force := clampf(swipe.length() * SWIPE_FORCE_MULTIPLIER, MIN_THROW_FORCE, MAX_THROW_FORCE)
	var force_normalized := force / MAX_THROW_FORCE
	
	# Position indicator in front of dice
	throw_indicator.position = Vector3(0, 0.5, 2)
	
	# Rotate to point in throw direction
	var angle := atan2(swipe.x, -swipe.y)
	throw_indicator.rotation = Vector3(-PI/4 * force_normalized, angle, 0)
	
	# Scale based on force
	throw_indicator.scale = Vector3(1, force_normalized * 2, 1)
	
	# Color based on force
	var mat := throw_indicator.material_override as StandardMaterial3D
	mat.albedo_color = Color.from_hsv(0.3 - force_normalized * 0.3, 0.8, 0.8, 0.7)


func _check_dice_stopped() -> bool:
	for dice in dice_meshes:
		if dice.linear_velocity.length() > 0.1 or dice.angular_velocity.length() > 0.1:
			return false
		if dice.position.y > DICE_SIZE + 0.1:  # Still in air
			return false
	return true


func _calculate_results() -> void:
	var total := 0
	var results: Array[int] = []
	
	for dice in dice_meshes:
		var value := _get_die_top_face(dice)
		results.append(value)
		total += value
	
	var result_str := ""
	for i in range(results.size()):
		result_str += str(results[i])
		if i < results.size() - 1:
			result_str += " + "
	result_str += " = " + str(total)
	
	result_label.text = result_str
	info_label.text = "Total: %d" % total


func _get_die_top_face(dice: RigidBody3D) -> int:
	# Check which face is pointing up
	var faces := {
		Vector3.UP: 1,
		Vector3.DOWN: 6,
		Vector3.RIGHT: 2,
		Vector3.LEFT: 5,
		Vector3.BACK: 3,
		Vector3.FORWARD: 4,
	}
	
	var best_dot := -2.0
	var best_value := 1
	
	for face_dir in faces:
		var world_dir: Vector3 = dice.global_transform.basis * face_dir
		var dot := world_dir.dot(Vector3.UP)
		if dot > best_dot:
			best_dot = dot
			best_value = faces[face_dir]
	
	return best_value


func _on_throw_pressed() -> void:
	# Quick throw with random direction
	_throw_dice(Vector2(randf_range(-50, 50), randf_range(-200, -100)))


func _on_reset_pressed() -> void:
	# Reset dice positions
	for i in range(dice_meshes.size()):
		var dice := dice_meshes[i]
		dice.linear_velocity = Vector3.ZERO
		dice.angular_velocity = Vector3.ZERO
		dice.position = Vector3(
			(i - dice_count / 2.0) * DICE_SIZE * 1.5,
			DICE_SIZE,
			0
		)
		dice.rotation = Vector3.ZERO
	
	result_label.text = "Swipe to throw!"
	info_label.text = "Dice: %d" % dice_count


func _on_back_pressed() -> void:
	GameManager.go_to_menu()
