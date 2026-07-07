extends Control
## Main menu controller

@onready var ssr_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/SSRDemoBtn
@onready var water_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/WaterDemoBtn
@onready var fire_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/FireDemoBtn
@onready var dice_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/DiceDemoBtn
@onready var grass_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/GrassDemoBtn
@onready var parallax_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/ParallaxDemoBtn
@onready var fluid_btn: Button = $CenterContainer/VBoxContainer/ButtonsContainer/FluidDemoBtn
@onready var exit_btn: Button = $CenterContainer/VBoxContainer/BottomButtons/ExitBtn
@onready var particles_bg: GPUParticles2D = $ParticlesBG


func _ready() -> void:
	_setup_background_particles()
	
	ssr_btn.pressed.connect(func(): GameManager.load_demo("ssr_demo"))
	water_btn.pressed.connect(func(): GameManager.load_demo("water_demo"))
	fire_btn.pressed.connect(func(): GameManager.load_demo("fire_demo"))
	dice_btn.pressed.connect(func(): GameManager.load_demo("dice_demo"))
	grass_btn.pressed.connect(func(): GameManager.load_demo("grass_demo"))
	parallax_btn.pressed.connect(func(): GameManager.load_demo("parallax_demo"))
	fluid_btn.pressed.connect(func(): GameManager.load_demo("fluid_demo"))
	exit_btn.pressed.connect(func(): GameManager.quit_game())

	# Button hover animations
	for btn in [ssr_btn, water_btn, fire_btn, dice_btn, grass_btn, parallax_btn, fluid_btn, exit_btn]:
		btn.mouse_entered.connect(_on_button_hover.bind(btn))
		btn.mouse_exited.connect(_on_button_exit.bind(btn))


func _setup_background_particles() -> void:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(800, 500, 0)
	material.direction = Vector3(0, -1, 0)
	material.spread = 10.0
	material.initial_velocity_min = 10.0
	material.initial_velocity_max = 30.0
	material.gravity = Vector3(0, 0, 0)
	material.scale_min = 0.5
	material.scale_max = 2.0
	material.color = Color(0.3, 0.5, 1.0, 0.3)
	
	particles_bg.process_material = material
	particles_bg.position = get_viewport_rect().size / 2


func _on_button_hover(btn: Button) -> void:
	var tween := create_tween()
	tween.tween_property(btn, "scale", Vector2(1.05, 1.05), 0.1)


func _on_button_exit(btn: Button) -> void:
	var tween := create_tween()
	tween.tween_property(btn, "scale", Vector2.ONE, 0.1)
