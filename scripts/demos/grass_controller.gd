extends Node3D

const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu
@onready var ground_mesh: MeshInstance3D = $Ground/MeshInstance3D
@onready var grass: GrassRenderer = GrassRenderer.new()
@onready var _viewport := ViewportGuard.attach(self)

var config: GrassConfig = GrassConfig.new()
var density_modifier := 1.0
var wind_speed := 1.0
var quality := SimQualityState.new()
var _grass_ready := false


func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	density_modifier = config.density
	wind_speed = config.wind_speed_mps
	quality.setup(GrassQualityProfile, "grass_quality_profile", _apply_quality)
	quality.restore()
	# The Density slider persists its last value and SimMenu's deferred restore
	# would re-emit it after _ready, running the blade fill a second time; seed
	# the build from the same stored value so that restore lands on no change.
	density_modifier = clampf(
		menu.stored_value("🌿 Grass Properties", "Density",
			GrassQualityProfile.values(quality.effective).density), 0.0, 2.0)
	grass.density = density_modifier
	grass.config = config
	add_child(grass)
	grass.build()
	ground_mesh.material_override = grass.ground_material()
	_apply_quality(GrassQualityProfile.values(quality.effective))
	_grass_ready = true
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
	# The grass samples the seamless heightmap texture, so the collision must
	# come from the seamless image too — the raw noise disagrees at the seam.
	# map_data is row-major over (depth, width).
	var image := HEIGHTMAP.noise.get_seamless_image(512, 512)
	var dims := Vector2i(image.get_width(), image.get_height())
	image.convert(Image.FORMAT_RF)
	var map_data := image.get_data().to_float32_array()
	for i in map_data.size():
		map_data[i] = (map_data[i] - 0.5) * config.heightmap_scale_m
	var shape := HeightMapShape3D.new()
	shape.map_width = dims.x
	shape.map_depth = dims.y
	shape.map_data = map_data
	$Ground/CollisionShape3D.shape = shape


func _setup_ui() -> void:
	menu.add_label("Drag: rotate | Scroll: zoom")
	menu.add_separator()
	menu.add_section("🌿 Grass Properties")
	var density_slider: HSlider = menu.add_slider("Density", 0.0, 2.0, density_modifier,
		func(value: float) -> void:
			density_modifier = value
			grass.set_density(value))
	quality.bind("density", density_slider,
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
	var scale_slider: HSlider = menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	quality.bind("render_scale", scale_slider, _set_render_scale)
	var shadow_slider: HSlider = menu.add_slider("Shadow distance", 0.0, 100.0,
		config.shadow_distance_m, grass.set_shadow_distance)
	quality.bind("shadow_distance_m", shadow_slider, grass.set_shadow_distance)
	var shadows_toggle: Button = menu.add_debug_toggle("🌑", "Cast shadows",
		grass.shadows_enabled, grass.set_shadows)
	quality.bind("shadows", shadows_toggle, grass.set_shadows)
	quality.attach_menu_option(menu)
	menu.add_action("🌬", "Gust", func() -> void: grass.add_gust(4.0))
	menu.add_action("🎲", "Regen", grass.generate)


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


## Before grass.build() the values land on the fields the build reads; density
## is owned by the persisted slider value at launch (seeded in _ready). After,
## the setters regenerate and re-flag. Set_density runs the GDScript blade
## fill, so it must not run twice at launch.
func _apply_quality(values: Dictionary) -> void:
	_set_render_scale(values.render_scale)
	if not _grass_ready:
		grass.shadows_enabled = values.shadows
		grass.config.shadow_distance_m = values.shadow_distance_m
		return
	grass.set_density(values.density)
	grass.set_shadows(values.shadows)
	grass.set_shadow_distance(values.shadow_distance_m)
