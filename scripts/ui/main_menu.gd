extends Control
## Main menu controller — buttons generated dynamically from GameManager.DEMOS

@onready var grid: GridContainer = %GridContainer
@onready var exit_btn: Button = %ExitBtn
@onready var particles_bg: GPUParticles2D = $ParticlesBG


func _ready() -> void:
	_setup_background_particles()
	_build_demo_buttons()
	
	exit_btn.pressed.connect(func(): GameManager.quit_game())
	exit_btn.mouse_entered.connect(_on_button_hover.bind(exit_btn))
	exit_btn.mouse_exited.connect(_on_button_exit.bind(exit_btn))


func _build_demo_buttons() -> void:
	for demo: Dictionary in GameManager.DEMOS:
		var btn := Button.new()
		btn.text = "%s  %s" % [demo.icon, demo.title]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 60)
		btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		btn.clip_text = true
		
		# Connect to the right demo
		var key: String = demo.key
		btn.pressed.connect(func(): GameManager.load_demo(key))
		
		# Hover animation
		btn.mouse_entered.connect(_on_button_hover.bind(btn))
		btn.mouse_exited.connect(_on_button_exit.bind(btn))
		
		grid.add_child(btn)


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
