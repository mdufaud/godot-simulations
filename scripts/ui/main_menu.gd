extends Control
## Main menu controller — accordion sections generated dynamically from GameManager.CATEGORIES/DEMOS

const COLUMN_MAX_WIDTH := 640.0
const OUTER_MARGIN := 64.0  # matches MarginContainer left+right (32+32)
const ACCENT := Color(0.35, 0.62, 1.0)
const HEADER_IDLE := Color(0.85, 0.9, 0.95)

@onready var category_list: VBoxContainer = %CategoryList
@onready var exit_btn: Button = %ExitBtn
@onready var particles_bg: GPUParticles2D = $ParticlesBG

var _sections: Array[Dictionary] = []
var _open_key: String = ""


func _ready() -> void:
	_setup_background_particles()
	_build_categories()
	_apply_responsive_width()

	get_viewport().size_changed.connect(_apply_responsive_width)

	exit_btn.pressed.connect(func(): GameManager.quit_game())
	exit_btn.mouse_entered.connect(_on_button_hover.bind(exit_btn))
	exit_btn.mouse_exited.connect(_on_button_exit.bind(exit_btn))


func _apply_responsive_width() -> void:
	var avail: float = get_viewport_rect().size.x - OUTER_MARGIN
	var width: float = minf(COLUMN_MAX_WIDTH, avail)
	category_list.custom_minimum_size.x = width

	# Single column when too narrow for two comfortable tap targets.
	var columns: int = 1 if width < 520.0 else 2
	for section: Dictionary in _sections:
		section.grid.columns = columns


func _build_categories() -> void:
	for cat: Dictionary in GameManager.CATEGORIES:
		var demos_in_cat: Array = GameManager.DEMOS.filter(func(d): return d.category == cat.key)
		if demos_in_cat.is_empty():
			continue
		_create_section(cat, demos_in_cat)


func _create_section(cat: Dictionary, demos_in_cat: Array) -> void:
	var header := Button.new()
	header.custom_minimum_size = Vector2(0, 64)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 22)
	category_list.add_child(header)

	var wrapper := MarginContainer.new()
	wrapper.visible = false
	wrapper.add_theme_constant_override("margin_top", 6)
	wrapper.add_theme_constant_override("margin_bottom", 6)
	wrapper.add_theme_constant_override("margin_left", 8)
	wrapper.add_theme_constant_override("margin_right", 8)
	category_list.add_child(wrapper)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 12)
	wrapper.add_child(grid)

	for demo: Dictionary in demos_in_cat:
		var btn := Button.new()
		btn.text = "%s  %s" % [demo.icon, demo.title]
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 64)
		btn.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		btn.clip_text = true

		var key: String = demo.key
		btn.pressed.connect(func(): GameManager.load_demo(key))
		btn.mouse_entered.connect(_on_button_hover.bind(btn))
		btn.mouse_exited.connect(_on_button_exit.bind(btn))

		grid.add_child(btn)

	var section := {
		key = cat.key, title = cat.title, icon = cat.icon,
		count = demos_in_cat.size(), header = header, wrapper = wrapper, grid = grid,
	}
	_sections.append(section)
	header.pressed.connect(_on_category_header_pressed.bind(section))
	_update_header(section, false)


func _update_header(section: Dictionary, open: bool) -> void:
	section.header.text = "%s  %s  ·  %d" % [section.icon, section.title, section.count]
	section.header.add_theme_color_override("font_color", ACCENT if open else HEADER_IDLE)


func _on_category_header_pressed(section: Dictionary) -> void:
	var key: String = section.key
	var opening: bool = _open_key != key

	for s: Dictionary in _sections:
		if s.key != key and s.wrapper.visible:
			s.wrapper.visible = false
			_update_header(s, false)

	if opening:
		section.wrapper.visible = true
		section.wrapper.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(section.wrapper, "modulate:a", 1.0, 0.15)
		_update_header(section, true)
		_open_key = key
	else:
		section.wrapper.visible = false
		_update_header(section, false)
		_open_key = ""


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
