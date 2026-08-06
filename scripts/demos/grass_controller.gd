extends Node3D

const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const HEIGHTMAP_SCALE := 5.0

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu
@onready var grass: GrassRenderer = GrassRenderer.new()
@onready var _viewport := ViewportGuard.attach(self)

var config: GrassConfig = GrassConfig.new()
var density_modifier := 1.0
var wind_speed := 1.0


func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	density_modifier = config.density
	wind_speed = config.wind_speed_mps
	grass.config = config
	add_child(grass)
	grass.build()
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 20.0
	orbit_cam.pitch = -25.0
	orbit_cam.yaw = 45.0
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 100.0
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 2.0
	_setup_heightmap_collision()
	_setup_ui()


func _physics_process(delta: float) -> void:
	grass.set_crush_center(orbit_cam.target)
	grass.tick(delta, orbit_cam.target)


func _setup_heightmap_collision() -> void:
	var noise: FastNoiseLite = HEIGHTMAP.noise
	var image := noise.get_image(512, 512)
	var dims := Vector2i(image.get_height(), image.get_width())
	image.convert(Image.FORMAT_RF)
	var map_data := image.get_data().to_float32_array()
	for i in map_data.size():
		map_data[i] = (map_data[i] - 0.5) * HEIGHTMAP_SCALE
	var shape := HeightMapShape3D.new()
	shape.map_width = dims.x
	shape.map_depth = dims.y
	shape.map_data = map_data
	$Ground/CollisionShape3D.shape = shape


func _setup_ui() -> void:
	menu.add_label("Drag: rotate | Scroll: zoom")
	menu.add_separator()
	menu.add_section("🌿 Grass Properties")
	menu.add_slider("Density", 0.0, 1.0, density_modifier,
		func(value: float) -> void:
			density_modifier = value
			grass.set_density(value))
	menu.add_slider("Clumping", 0.0, 1.0, 0.5, grass.set_clumping)
	menu.add_slider("Wind Speed", 0.0, 5.0, wind_speed,
		func(value: float) -> void:
			wind_speed = value
			grass.set_wind_speed(value))
	menu.add_separator()
	menu.add_section("🎨 Colors")
	menu.add_color_picker("Base Color", Color(0.05, 0.2, 0.01),
		func(color: Color) -> void: grass.set_colors(color,
			Color(0.5, 0.5, 0.1), Color(1.0, 0.75, 0.1)))
	menu.add_color_picker("Tip Color", Color(0.5, 0.5, 0.1),
		func(color: Color) -> void: grass.material.set_shader_parameter("tip_color", color))
	menu.add_color_picker("SSS Color", Color(1.0, 0.75, 0.1),
		func(color: Color) -> void:
			grass.material.set_shader_parameter("subsurface_scattering_color", color))
	menu.add_separator()
	menu.add_section("⚙️ Rendering")
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)
	menu.add_action("🌬", "Gust", func() -> void: grass.add_gust(4.0))
	menu.add_action("🎲", "Regen", grass.generate)
	menu.add_debug_toggle("🌑", "Cast shadows", true, grass.set_shadows)


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)
