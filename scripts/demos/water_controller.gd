extends Node3D
## Procedural water demo: Gerstner waves + interactive ripples + Jolt buoyancy

const SIM_SIZE := 256
const WATER_AREA := Vector2(128.0, 128.0)
const MAX_OBJECTS := 30
const WAVE_SEED := 1337

@onready var water_mesh: MeshInstance3D = $Water
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var fps_label: Label = $UI/Control/InfoPanel/VBoxContainer/FPSLabel
@onready var buoyancy: WaterBuoyancy = $WaterBuoyancy
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var floating_objects: Node3D = $FloatingObjects
@onready var ripple_viewports: Array[SubViewport] = [$RippleA, $RippleB]

var shader_material: ShaderMaterial
var waves: Array[Vector4] = []
var wave_time := 0.0
var wave_speed := 1.0
var spawned: Array[RigidBody3D] = []

var _ping := 0
var _reset_frames := 2
var _splash_queue: Array = []
var _live_splashes: Array[Sprite2D] = []
var _splash_texture: GradientTexture2D
var _splash_material: CanvasItemMaterial

var object_colors := [
	Color(0.6, 0.4, 0.2),
	Color(0.75, 0.55, 0.3),
	Color(0.8, 0.3, 0.2),
	Color(0.3, 0.5, 0.7),
	Color(0.85, 0.8, 0.7),
]


func _ready() -> void:
	shader_material = water_mesh.get_surface_override_material(0)
	_generate_waves()
	_setup_ripples()
	_setup_ui()

	shader_material.set_shader_parameter("gerstner_waves", waves)
	shader_material.set_shader_parameter("water_area", WATER_AREA)
	shader_material.set_shader_parameter("sun_direction", -sun.global_transform.basis.z)

	buoyancy.waves = waves
	buoyancy.water_level = water_mesh.global_position.y
	buoyancy.body_splashed.connect(_on_body_splashed)

	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 0.0
	orbit_cam.min_distance = 8.0
	orbit_cam.max_distance = 40.0

	$UI/Control/BackButton.pressed.connect(_on_back_pressed)

	for i in 4:
		_spawn_object()


func _process(delta: float) -> void:
	wave_time += delta * wave_speed
	shader_material.set_shader_parameter("wave_time", wave_time)
	buoyancy.wave_time = wave_time
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _physics_process(_delta: float) -> void:
	_step_ripples()


func _generate_waves() -> void:
	waves.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = WAVE_SEED
	var wind := rng.randf_range(0.0, TAU)
	var wavelength := 26.0
	var steepness := 0.16
	for i in 6:
		var angle := wind + rng.randf_range(-0.6, 0.6)
		waves.append(Vector4(cos(angle), sin(angle), steepness, wavelength))
		wavelength *= 0.62
		steepness *= 0.92


func _setup_ripples() -> void:
	for i in 2:
		var vp := ripple_viewports[i]
		var other := ripple_viewports[1 - i]
		var mat: ShaderMaterial = vp.get_node("Sim").material
		mat.set_shader_parameter("prev_texture", other.get_texture())

	_splash_texture = GradientTexture2D.new()
	_splash_texture.width = 64
	_splash_texture.height = 64
	_splash_texture.fill = GradientTexture2D.FILL_RADIAL
	_splash_texture.fill_from = Vector2(0.5, 0.5)
	_splash_texture.fill_to = Vector2(0.5, 0.0)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	_splash_texture.gradient = gradient

	_splash_material = CanvasItemMaterial.new()
	_splash_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD


func _step_ripples() -> void:
	for sprite in _live_splashes:
		sprite.queue_free()
	_live_splashes.clear()

	_ping = 1 - _ping
	var current := ripple_viewports[_ping]
	var mat: ShaderMaterial = current.get_node("Sim").material
	mat.set_shader_parameter("reset", _reset_frames > 0)
	if _reset_frames > 0:
		_reset_frames -= 1
	else:
		_spawn_splash_sprites(current.get_node("Splashes"))

	current.render_target_update_mode = SubViewport.UPDATE_ONCE
	shader_material.set_shader_parameter("ripple_texture", current.get_texture())


func _spawn_splash_sprites(parent: Node2D) -> void:
	for item in _splash_queue:
		var pos: Vector3 = item[0]
		var strength: float = item[1]
		var uv := Vector2(pos.x, pos.z) / WATER_AREA + Vector2(0.5, 0.5)
		if uv.x < 0.02 or uv.x > 0.98 or uv.y < 0.02 or uv.y > 0.98:
			continue
		var sprite := Sprite2D.new()
		sprite.texture = _splash_texture
		sprite.material = _splash_material
		sprite.position = uv * float(SIM_SIZE)
		sprite.modulate = Color(clampf(strength * 0.05, 0.02, 0.3), 0.0, 0.0, 1.0)
		var radius_px := 1.4 / WATER_AREA.x * float(SIM_SIZE)
		sprite.scale = Vector2.ONE * (radius_px * 2.0 / float(_splash_texture.width))
		parent.add_child(sprite)
		_live_splashes.append(sprite)
	_splash_queue.clear()


func _on_body_splashed(world_pos: Vector3, strength: float) -> void:
	_splash_queue.append([world_pos, strength])


func _spawn_object() -> void:
	if spawned.size() >= MAX_OBJECTS:
		return
	var body := RigidBody3D.new()
	body.position = Vector3(randf_range(-12.0, 12.0), 4.0 + randf_range(0.0, 2.0), randf_range(-12.0, 12.0))
	body.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
	body.mass = randf_range(0.8, 1.5)

	var mesh_instance := MeshInstance3D.new()
	var collision := CollisionShape3D.new()
	var half := Vector3.ONE * 0.5

	match randi() % 3:
		0:
			var sphere := SphereMesh.new()
			sphere.radius = randf_range(0.3, 0.6)
			sphere.height = sphere.radius * 2.0
			mesh_instance.mesh = sphere
			var shape := SphereShape3D.new()
			shape.radius = sphere.radius
			collision.shape = shape
			half = Vector3.ONE * sphere.radius
		1:
			var box := BoxMesh.new()
			var size := randf_range(0.6, 1.2)
			box.size = Vector3(size, size * randf_range(0.5, 1.0), size)
			mesh_instance.mesh = box
			var shape := BoxShape3D.new()
			shape.size = box.size
			collision.shape = shape
			half = box.size * 0.5
		2:
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = randf_range(0.25, 0.5)
			cylinder.bottom_radius = cylinder.top_radius
			cylinder.height = randf_range(0.8, 1.6)
			mesh_instance.mesh = cylinder
			var shape := CylinderShape3D.new()
			shape.radius = cylinder.top_radius
			shape.height = cylinder.height
			collision.shape = shape
			half = Vector3(cylinder.top_radius, cylinder.height * 0.5, cylinder.top_radius)

	var material := StandardMaterial3D.new()
	material.albedo_color = object_colors[randi() % object_colors.size()]
	material.roughness = 0.8
	mesh_instance.material_override = material

	body.add_child(mesh_instance)
	body.add_child(collision)
	floating_objects.add_child(body)
	spawned.append(body)
	buoyancy.register_body(body, half)


func _clear_objects() -> void:
	for obj in spawned:
		if is_instance_valid(obj):
			obj.queue_free()
	spawned.clear()
	buoyancy.clear_bodies()


func _setup_ui() -> void:
	var sliders_vbox: VBoxContainer = $UI/Control/InfoPanel/VBoxContainer/SlidersContainer

	_add_slider(sliders_vbox, "Wave Height", 0.0, 2.0, 1.0, func(v: float):
		shader_material.set_shader_parameter("wave_height", v)
		buoyancy.wave_height = v)
	_add_slider(sliders_vbox, "Choppiness", 0.0, 1.5, 1.0, func(v: float):
		shader_material.set_shader_parameter("choppiness", v)
		buoyancy.choppiness = v)
	_add_slider(sliders_vbox, "Wave Speed", 0.0, 2.0, 1.0, func(v: float):
		wave_speed = v)
	_add_slider(sliders_vbox, "Foam", 0.0, 2.0, 1.0, func(v: float):
		shader_material.set_shader_parameter("foam_amount", v))
	_add_slider(sliders_vbox, "SSS", 0.0, 2.0, 1.0, func(v: float):
		shader_material.set_shader_parameter("sss_strength", v))
	_add_slider(sliders_vbox, "Ripples", 0.0, 2.0, 1.0, func(v: float):
		shader_material.set_shader_parameter("ripple_strength", v))

	var ssr_toggle := CheckButton.new()
	ssr_toggle.text = "SSR Reflections"
	ssr_toggle.button_pressed = true
	ssr_toggle.toggled.connect(func(enabled: bool):
		world_env.environment.ssr_enabled = enabled)
	sliders_vbox.add_child(ssr_toggle)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	sliders_vbox.add_child(buttons)

	var spawn_button := Button.new()
	spawn_button.text = "Spawn"
	spawn_button.pressed.connect(_spawn_object)
	buttons.add_child(spawn_button)

	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_clear_objects)
	buttons.add_child(clear_button)


func _add_slider(parent: Control, label_text: String, min_val: float, max_val: float, default_val: float, on_change: Callable) -> void:
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
	value_label.text = "%.2f" % default_val
	value_label.custom_minimum_size.x = 50
	hbox.add_child(value_label)

	slider.value_changed.connect(func(value: float):
		on_change.call(value)
		value_label.text = "%.2f" % value
	)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
