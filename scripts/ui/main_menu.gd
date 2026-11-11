extends Control
## Main menu controller — accordion sections generated dynamically from GameManager.CATEGORIES/DEMOS

const COLUMN_MAX_WIDTH := 1500.0
const OUTER_MARGIN := 40.0  # matches MarginContainer left+right (20+20)
const TILE_MIN_WIDTH := 230.0
const ACCENT := Color(0.35, 0.62, 1.0)

@onready var category_list: VBoxContainer = %CategoryList
@onready var quality_row: HBoxContainer = %QualityRow
@onready var exit_btn: Button = %ExitBtn
@onready var clear_cache_btn: Button = %ClearShaderCacheBtn
@onready var particles_bg: GPUParticles2D = $ParticlesBG

var _grids: Array[GridContainer] = []
var _quality_buttons: Array[Button] = []


func _ready() -> void:
	_setup_background_particles()
	_build_categories()
	_build_quality_row()
	_apply_responsive_width()

	get_viewport().size_changed.connect(_apply_responsive_width)

	exit_btn.pressed.connect(func(): GameManager.quit_game())
	exit_btn.mouse_entered.connect(_on_button_hover.bind(exit_btn))
	exit_btn.mouse_exited.connect(_on_button_exit.bind(exit_btn))

	clear_cache_btn.pressed.connect(_on_clear_shader_cache)
	clear_cache_btn.mouse_entered.connect(_on_button_hover.bind(clear_cache_btn))
	clear_cache_btn.mouse_exited.connect(_on_button_exit.bind(clear_cache_btn))
	_update_clear_cache_label()


## One tier for every simulation; no button stays lit while the demos differ.
func _build_quality_row() -> void:
	var names: Array = SimQualityProfile.TIER_NAMES
	for tier in names.size():
		var btn := Button.new()
		btn.text = names[tier]
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(96, 45)
		btn.tooltip_text = "Run every simulation at %s quality." % names[tier]
		btn.pressed.connect(_on_quality_pressed.bind(tier))
		quality_row.add_child(btn)
		_quality_buttons.append(btn)
	_sync_quality_row()


func _on_quality_pressed(tier: int) -> void:
	GameManager.set_global_quality(tier)
	_sync_quality_row()


func _sync_quality_row() -> void:
	var tier := GameManager.global_quality()
	for i in _quality_buttons.size():
		_quality_buttons[i].set_pressed_no_signal(i == tier)


func _update_clear_cache_label() -> void:
	var count := ShaderCache.file_count()
	if count == 0:
		clear_cache_btn.text = "🧹  Shader Cache Empty"
		clear_cache_btn.disabled = true
	else:
		clear_cache_btn.text = "🧹  Clear Shader Cache (%d · %.1f MB)" % [
			count, ShaderCache.size_bytes() / 1048576.0,
		]
		clear_cache_btn.disabled = false


func _on_clear_shader_cache() -> void:
	var removed := ShaderCache.clear()
	print("Shader cache cleared: %d file(s) removed" % removed)
	_update_clear_cache_label()


func _apply_responsive_width() -> void:
	var avail: float = get_viewport_rect().size.x - OUTER_MARGIN
	var width: float = minf(COLUMN_MAX_WIDTH, avail)
	category_list.custom_minimum_size.x = width
	var columns := maxi(1, int(width / TILE_MIN_WIDTH))
	for grid in _grids:
		grid.columns = columns


func _build_categories() -> void:
	for cat: Dictionary in GameManager.CATEGORIES:
		var demos_in_cat: Array = GameManager.DEMOS.filter(func(d): return d.category == cat.key)
		if demos_in_cat.is_empty():
			continue
		_create_section(cat, demos_in_cat)


## Every category stays open: a heading and its tiles, so the whole catalogue
## shows at once.
func _create_section(cat: Dictionary, demos_in_cat: Array) -> void:
	var header := Label.new()
	header.text = "%s  %s  ·  %d" % [cat.icon, cat.title, demos_in_cat.size()]
	header.add_theme_font_size_override("font_size", 18)
	header.add_theme_color_override("font_color", ACCENT)
	category_list.add_child(header)

	var grid := GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	category_list.add_child(grid)
	_grids.append(grid)

	for demo: Dictionary in demos_in_cat:
		var btn := Button.new()
		btn.text = "%s  %s" % [demo.icon, demo.title]
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0, 50)
		btn.add_theme_font_size_override("font_size", 16)
		btn.clip_text = true
		btn.tooltip_text = demo.title

		var key: String = demo.key
		btn.pressed.connect(func(): GameManager.load_demo(key))
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
