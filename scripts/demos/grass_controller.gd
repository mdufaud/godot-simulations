extends Node3D
## Grass shader demo based on GodotGrass (2Retr0/GodotGrass)
## Features LOD multimesh system, wind animation, heightmap terrain

const GRASS_MESH_HIGH := preload("res://resources/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass_material.tres")
const HEIGHTMAP := preload("res://resources/grass_heightmap.tres")

const TILE_SIZE := 5.0
const MAP_RADIUS := 80.0  # Smaller for demo
const HEIGHTMAP_SCALE := 5.0

var grass_multimeshes: Array[Array] = []
var previous_tile_id := Vector3.ZERO
var density_modifier := 1.0

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel
@onready var info_label: Label = $UI/Control/InfoPanel/VBoxContainer/InfoLabel
@onready var control_panel: PanelContainer = $UI/Control/ControlPanel
@onready var back_button: Button = $UI/Control/BackButton


func _ready() -> void:
	# Setup global shader uniforms
	RenderingServer.global_shader_parameter_set("heightmap", HEIGHTMAP)
	RenderingServer.global_shader_parameter_set("heightmap_scale", HEIGHTMAP_SCALE)
	RenderingServer.global_shader_parameter_set("player_position", Vector3.ZERO)
	
	# Configure orbit camera
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 20.0
	orbit_cam.pitch = -25.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 100.0
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 2.0
	
	# Setup heightmap collision for ground
	_setup_heightmap_collision()
	
	# Create grass instances
	_setup_grass_instances()
	_generate_grass_multimeshes()
	
	# Connect UI
	back_button.pressed.connect(_on_back_pressed)
	
	call_deferred("_setup_ui")


func _process(delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	info_label.text = "Drag: rotate | Scroll: zoom | ZQSD/WASD: move"


func _physics_process(_delta: float) -> void:
	RenderingServer.global_shader_parameter_set("player_position", orbit_cam.target)
	
	# Update LOD tiles based on camera position
	var tile_id: Vector3 = ((orbit_cam.target + Vector3.ONE * TILE_SIZE * 0.5) / TILE_SIZE * Vector3(1, 0, 1)).floor()
	if tile_id != previous_tile_id:
		for data in grass_multimeshes:
			data[0].global_position = data[1] + Vector3(1, 0, 1) * TILE_SIZE * tile_id
		previous_tile_id = tile_id



## Creates a HeightMapShape3D from the NoiseTexture2D
func _setup_heightmap_collision() -> void:
	var noise: FastNoiseLite = HEIGHTMAP.noise
	var heightmap_image := noise.get_image(512, 512)
	var dims := Vector2i(heightmap_image.get_height(), heightmap_image.get_width())
	var map_data: PackedFloat32Array
	
	for j in dims.x:
		for i in dims.y:
			map_data.push_back((heightmap_image.get_pixel(i, j).r - 0.5) * HEIGHTMAP_SCALE)
	
	var heightmap_shape := HeightMapShape3D.new()
	heightmap_shape.map_width = dims.x
	heightmap_shape.map_depth = dims.y
	heightmap_shape.map_data = map_data
	$Ground/CollisionShape3D.shape = heightmap_shape


## Creates initial tiled multimesh instances
func _setup_grass_instances() -> void:
	for i in range(-MAP_RADIUS, MAP_RADIUS, TILE_SIZE):
		for j in range(-MAP_RADIUS, MAP_RADIUS, TILE_SIZE):
			var instance := MultiMeshInstance3D.new()
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			instance.material_override = GRASS_MAT
			instance.position = Vector3(i, 0.0, j)
			instance.extra_cull_margin = 1.0
			$GrassContainer.add_child(instance)
			grass_multimeshes.append([instance, instance.position])


## Generates multimeshes with LOD based on distance to origin
func _generate_grass_multimeshes() -> void:
	var multimesh_lods: Array[MultiMesh] = [
		_create_grass_multimesh(1.0 * density_modifier, TILE_SIZE, GRASS_MESH_HIGH),
		_create_grass_multimesh(0.5 * density_modifier, TILE_SIZE, GRASS_MESH_HIGH),
		_create_grass_multimesh(0.25 * density_modifier, TILE_SIZE, GRASS_MESH_LOW),
		_create_grass_multimesh(0.1 * density_modifier, TILE_SIZE, GRASS_MESH_LOW),
		_create_grass_multimesh(0.02 * (1.0 if density_modifier != 0.0 else 0.0), TILE_SIZE, GRASS_MESH_LOW),
	]
	
	for data in grass_multimeshes:
		var distance = data[1].length()  # Distance from center tile
		if distance > MAP_RADIUS:
			continue
		if distance < 12.0:
			data[0].multimesh = multimesh_lods[0]
		elif distance < 40.0:
			data[0].multimesh = multimesh_lods[1]
		elif distance < 70.0:
			data[0].multimesh = multimesh_lods[2]
		else:
			data[0].multimesh = multimesh_lods[3]


func _create_grass_multimesh(density: float, tile_size: float, mesh: Mesh) -> MultiMesh:
	var row_size := int(ceil(tile_size * lerpf(0.0, 10.0, density)))
	var multimesh := MultiMesh.new()
	multimesh.mesh = mesh
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = row_size * row_size
	
	var jitter_offset := tile_size / float(row_size) * 0.5 * 0.9 if row_size > 0 else 0.0
	for i in row_size:
		for j in row_size:
			var grass_position := Vector3(i / float(row_size) - 0.5, 0, j / float(row_size) - 0.5) * tile_size
			var grass_offset := Vector3(randf_range(-jitter_offset, jitter_offset), 0, randf_range(-jitter_offset, jitter_offset))
			multimesh.set_instance_transform(i + j * row_size, Transform3D(Basis(), grass_position + grass_offset))
	
	return multimesh


func _setup_ui() -> void:
	var sliders_vbox: VBoxContainer = $UI/Control/ControlPanel/ScrollContainer/VBoxContainer
	
	for child in sliders_vbox.get_children():
		child.queue_free()
	await get_tree().process_frame
	
	# Section: Grass Properties
	_add_section_label(sliders_vbox, "🌿 Grass Properties")
	_add_slider(sliders_vbox, "Density", "density", 0.0, 1.0, density_modifier, _on_density_changed)
	_add_slider(sliders_vbox, "Clumping", "clumping_factor", 0.0, 1.0, 0.5, _on_shader_param_changed)
	_add_slider(sliders_vbox, "Wind Speed", "wind_speed", 0.0, 5.0, 1.0, _on_shader_param_changed)
	
	# Section: Colors
	_add_separator(sliders_vbox)
	_add_section_label(sliders_vbox, "🎨 Colors")
	_add_color_picker(sliders_vbox, "Base Color", "base_color", Color(0.05, 0.2, 0.01))
	_add_color_picker(sliders_vbox, "Tip Color", "tip_color", Color(0.5, 0.5, 0.1))
	_add_color_picker(sliders_vbox, "SSS Color", "subsurface_scattering_color", Color(1.0, 0.75, 0.1))
	
	# Section: Rendering
	_add_separator(sliders_vbox)
	_add_section_label(sliders_vbox, "⚙️ Rendering")
	_add_checkbox(sliders_vbox, "Cast Shadows", _on_shadows_changed, true)


func _add_section_label(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)


func _add_separator(parent: Control) -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 10)
	parent.add_child(sep)


func _add_slider(parent: Control, label_text: String, param: String, min_val: float, max_val: float, default_val: float, callback: Callable) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	parent.add_child(hbox)
	
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)
	
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = (max_val - min_val) / 100.0
	slider.value = default_val
	slider.scrollable = false
	slider.custom_minimum_size.x = 100
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(slider)
	
	var value_label := Label.new()
	value_label.text = "%.2f" % default_val
	value_label.custom_minimum_size.x = 45
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(value_label)
	
	slider.value_changed.connect(func(value: float):
		callback.call(param, value)
		value_label.text = "%.2f" % value
	)


func _add_color_picker(parent: Control, label_text: String, param: String, default_val: Color) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	parent.add_child(hbox)
	
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)
	
	var color_button := ColorPickerButton.new()
	color_button.color = default_val
	color_button.custom_minimum_size = Vector2(60, 28)
	color_button.edit_alpha = false
	hbox.add_child(color_button)
	
	color_button.color_changed.connect(func(color: Color):
		GRASS_MAT.set_shader_parameter(param, color)
	)


func _add_checkbox(parent: Control, label_text: String, callback: Callable, default_val: bool) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	parent.add_child(hbox)
	
	var checkbox := CheckBox.new()
	checkbox.text = label_text
	checkbox.button_pressed = default_val
	hbox.add_child(checkbox)
	
	checkbox.toggled.connect(callback)


func _on_density_changed(_param: String, value: float) -> void:
	density_modifier = value
	_generate_grass_multimeshes()


func _on_shader_param_changed(param: String, value: float) -> void:
	GRASS_MAT.set_shader_parameter(param, value)


func _on_shadows_changed(enabled: bool) -> void:
	var setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for data in grass_multimeshes:
		data[0].cast_shadow = setting


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
