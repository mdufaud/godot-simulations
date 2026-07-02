extends Node3D
## Water shader demo from godot-realistic-water

@onready var water_mesh: MeshInstance3D = $Water
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel

var shader_material: ShaderMaterial

const DEFAULT_VALUES := {
	"wave_speed": 0.5,
	"refraction": 0.075,
	"beers_law": 2.0,
	"depth_offset": -0.75,
	"foam_level": 0.5,
	"uv_sampler_strength": 0.04,
}


func _ready() -> void:
	shader_material = water_mesh.get_surface_override_material(0)
	_setup_ui()
	
	# Configure orbit camera
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 0.0
	orbit_cam.min_distance = 8.0
	orbit_cam.max_distance = 40.0
	
	$UI/Control/BackButton.pressed.connect(_on_back_pressed)


func _process(delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _setup_ui() -> void:
	var sliders_vbox: VBoxContainer = $UI/Control/InfoPanel/VBoxContainer/SlidersContainer
	
	_add_slider(sliders_vbox, "Wave Speed", "wave_speed", 0.0, 2.0, DEFAULT_VALUES["wave_speed"])
	_add_slider(sliders_vbox, "Refraction", "refraction", 0.0, 0.5, DEFAULT_VALUES["refraction"])
	_add_slider(sliders_vbox, "Beer's Law", "beers_law", 0.0, 10.0, DEFAULT_VALUES["beers_law"])
	_add_slider(sliders_vbox, "Depth Offset", "depth_offset", -5.0, 0.0, DEFAULT_VALUES["depth_offset"])
	_add_slider(sliders_vbox, "Foam Level", "foam_level", 0.0, 2.0, DEFAULT_VALUES["foam_level"])
	_add_slider(sliders_vbox, "UV Distortion", "uv_sampler_strength", 0.0, 0.2, DEFAULT_VALUES["uv_sampler_strength"])


func _add_slider(parent: Control, label_text: String, param: String, min_val: float, max_val: float, default_val: float) -> void:
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
	slider.step = 0.01
	slider.value = default_val
	slider.scrollable = false
	slider.custom_minimum_size.x = 120
	hbox.add_child(slider)
	
	var value_label := Label.new()
	value_label.text = "%.3f" % default_val
	value_label.custom_minimum_size.x = 50
	hbox.add_child(value_label)
	
	slider.value_changed.connect(func(value: float):
		shader_material.set_shader_parameter(param, value)
		value_label.text = "%.3f" % value
	)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
