extends Node3D

const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const GOLDEN_HOUR := preload("res://resources/ocean/looks/golden_hour.tres")
const POST_FX_SHADER := preload("res://shaders/grass/post_fx.gdshader")
const FILTER_NAMES := ["Off", "Obra Dinn", "Contrast", "Sepia", "Thermal", "Phosphor"]
const BASE_COLOR := Color(0.09, 0.22, 0.09)
const TIP_COLOR := Color(0.46, 0.52, 0.24)
const SSS_COLOR := Color(0.76, 0.8, 0.48)
const COLOR_PALETTES := [
	{"name": "Pampas", "base": BASE_COLOR, "tip": TIP_COLOR,
		"backlight": SSS_COLOR, "plume": Color(0.84, 0.78, 0.68),
		"moss": Color(0.1, 0.18, 0.1), "straw": Color(0.28, 0.29, 0.16),
		"chromatic": 0.0},
	{"name": "Meadow", "base": Color(0.06, 0.25, 0.07),
		"tip": Color(0.3, 0.62, 0.16), "backlight": Color(0.55, 0.85, 0.28),
		"plume": Color(0.72, 0.68, 0.43), "moss": Color(0.08, 0.2, 0.08),
		"straw": Color(0.18, 0.32, 0.1), "chromatic": 0.0},
	{"name": "Ember", "base": Color(0.18, 0.12, 0.055),
		"tip": Color(0.68, 0.37, 0.14), "backlight": Color(0.95, 0.65, 0.26),
		"plume": Color(0.85, 0.68, 0.42), "moss": Color(0.15, 0.1, 0.05),
		"straw": Color(0.34, 0.25, 0.1), "chromatic": 0.0},
	{"name": "Prism", "base": Color(0.1, 0.07, 0.32),
		"tip": Color(0.1, 0.75, 0.78), "backlight": Color(0.9, 0.3, 0.85),
		"plume": Color(0.84, 0.36, 0.92), "moss": Color(0.06, 0.05, 0.18),
		"straw": Color(0.14, 0.12, 0.3), "chromatic": 0.7},
]
const WIND_PRESETS := [
	{"name": "Calm", "speed": 0.0, "direction": 35.0, "gustiness": 0.0},
	{"name": "Breeze", "speed": 1.0, "direction": 35.0, "gustiness": 0.65},
	{"name": "Gusty", "speed": 2.5, "direction": 70.0, "gustiness": 0.85},
	{"name": "Storm", "speed": 4.0, "direction": 115.0, "gustiness": 1.0},
]
const STAGE_DESCRIPTIONS := [
	"Start with one uniform blade shape and an even field distribution.",
	"Curved tufts replace single blades; shared noise shapes their height and facing.",
	"Cream pampas plumes, straw colors, and warm light complete the field.",
	"Tune the wind and watch broad gusts travel through leaves and plumes.",
]

@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var menu: SimMenu = $UI/SimMenu
@onready var ground_mesh: MeshInstance3D = $Ground/MeshInstance3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var main_camera: Camera3D = $CameraPivot/Camera3D
@onready var grass: GrassRenderer = GrassRenderer.new()
@onready var _viewport := ViewportGuard.attach(self)

var config: GrassConfig = GrassConfig.new()
var shadow_distance_m := 40.0
var sun_elevation := 10.0
var sun_azimuth := 215.0
var sky_material := ShaderMaterial.new()
var cloudscape := OceanCloudscape.new()
var _atmosphere_look: OceanLookPreset
var density_modifier := 1.0
var wind_speed := 1.0
var wind_direction_degrees := 35.0
var gustiness := 0.65
var demo_stage := 3
var quality := SimQualityState.new()
var _grass_ready := false
var _stage_description: Label
var _stage_option: OptionButton
var _wind_preset_index := -1
var _applying_wind_preset := false
var _wind_preset_action: Button
var _wind_speed_slider: HSlider
var _wind_direction_slider: HSlider
var _gustiness_slider: HSlider
var _palette_index := 0
var _palette_colors: Dictionary = {}
var _palette_option: OptionButton
var _palette_action: Button
var _palette_pickers: Dictionary = {}
var _chromatic_strength := 0.0
var _chromatic_slider: HSlider
var _filter_index := 0
var _filter_option: OptionButton
var _post_fx_layer: CanvasLayer
var _post_fx_rect: ColorRect
var _post_fx_material: ShaderMaterial


func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	_viewport.set_taa(true)
	density_modifier = config.density
	wind_speed = config.wind_speed_mps
	quality.setup(GrassQualityProfile, "grass_quality_profile", _apply_quality)
	quality.restore()
	density_modifier = clampf(
		menu.stored_value("🌿 Grass Properties", "Density",
			GrassQualityProfile.values(quality.effective).density), 0.0, 2.0)
	# The Density slider persists its last value and SimMenu's deferred restore
	# would re-emit it after _ready, running the blade fill a second time; seed
	# the build from the same stored value so that restore lands on no change.
	wind_speed = clampf(float(menu.stored_value("🌿 Grass Properties", "Wind Speed",
		wind_speed)), 0.0, 5.0)
	wind_direction_degrees = fposmod(float(menu.stored_value("🌬 Wind Field",
		"Direction", wind_direction_degrees)), 360.0)
	gustiness = clampf(float(menu.stored_value("🌬 Wind Field", "Gustiness", gustiness)),
		0.0, 1.0)
	for index in WIND_PRESETS.size():
		var preset: Dictionary = WIND_PRESETS[index]
		if is_equal_approx(wind_speed, preset.speed) \
				and is_equal_approx(wind_direction_degrees, preset.direction) \
				and is_equal_approx(gustiness, preset.gustiness):
			_wind_preset_index = index
			break
	demo_stage = clampi(int(menu.stored_value("🧭 Learning Steps", "Step", 3)), 0, 3)
	_palette_index = clampi(int(menu.stored_value("🎨 Grass Palette", "Palette", 0)),
		0, COLOR_PALETTES.size() - 1)
	var palette: Dictionary = COLOR_PALETTES[_palette_index]
	_palette_colors = {
		"base": menu.stored_value("🎨 Grass Palette", "Base Color", palette.base),
		"tip": menu.stored_value("🎨 Grass Palette", "Tip Color", palette.tip),
		"backlight": menu.stored_value("🎨 Grass Palette", "Backlight", palette.backlight),
		"plume": menu.stored_value("🎨 Grass Palette", "Plumes", palette.plume),
		"moss": menu.stored_value("🎨 Grass Palette", "Ground Shade", palette.moss),
		"straw": menu.stored_value("🎨 Grass Palette", "Ground Light", palette.straw),
	}
	_chromatic_strength = clampf(float(menu.stored_value("🎨 Grass Palette",
		"Color Gradient", palette.chromatic)), 0.0, 1.0)
	sun_elevation = clampf(float(menu.stored_value("☀️ Sunlight", "Sun elevation",
		sun_elevation)), 2.0, 80.0)
	sun_azimuth = clampf(float(menu.stored_value("☀️ Sunlight", "Sun azimuth",
		sun_azimuth)), 0.0, 360.0)
	_filter_index = clampi(int(menu.stored_value("🎞 Filters", "Filter", 0)),
		0, FILTER_NAMES.size() - 1)
	grass.density = density_modifier
	grass.config = config
	grass.wind_speed = wind_speed
	grass.wind_direction_degrees = wind_direction_degrees
	grass.gustiness = gustiness
	grass.demo_stage = demo_stage
	add_child(grass)
	grass.build()
	ground_mesh.material_override = grass.ground_material()
	for color_key in _palette_colors:
		_set_palette_color(color_key, _palette_colors[color_key])
	_set_chromatic_strength(_chromatic_strength)
	_apply_quality(GrassQualityProfile.values(quality.effective))
	_grass_ready = true
	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 20.0
	orbit_cam.pitch = -14.0
	orbit_cam.yaw = 35.0
	orbit_cam.min_distance = 5.0
	orbit_cam.max_distance = 60.0
	orbit_cam.rotation_speed = 0.4
	orbit_cam.zoom_speed = 2.0
	orbit_cam.enable_movement = false
	_setup_heightmap_collision()
	_setup_environment()
	_setup_post_fx()
	_setup_ui()


func _physics_process(delta: float) -> void:
	grass.tick(delta, orbit_cam.target, orbit_cam.get_camera().global_position)
	var angle := deg_to_rad(grass.wind_direction_degrees)
	cloudscape.wind_velocity = Vector2(cos(angle), sin(angle)) * (2.5 + grass.wind_speed * 2.0)


func _setup_heightmap_collision() -> void:
	# The grass samples the seamless heightmap texture, so the collision must
	# come from the seamless image too — the raw noise disagrees at the seam.
	# map_data is row-major over (depth, width).
	var image := HEIGHTMAP.noise.get_seamless_image(512, 512)
	var dims := Vector2i(image.get_width(), image.get_height())
	image.convert(Image.FORMAT_RF)
	var source_data := image.get_data().to_float32_array()
	var map_data := PackedFloat32Array()
	map_data.resize(source_data.size())
	var half_dims := dims / 2
	for z in dims.y:
		var source_z := posmod(z - half_dims.y, dims.y)
		for x in dims.x:
			var source_x := posmod(x - half_dims.x, dims.x)
			var index := x + z * dims.x
			map_data[index] = (source_data[source_x + source_z * dims.x] - 0.5) \
				* config.heightmap_scale_m
	var shape := HeightMapShape3D.new()
	shape.map_width = dims.x
	shape.map_depth = dims.y
	shape.map_data = map_data
	$Ground/CollisionShape3D.shape = shape


func _setup_ui() -> void:
	menu.title = "🌾 Windblown Grass Study"
	menu.add_label("Drag: orbit | Scroll: zoom")
	menu.add_separator()
	menu.add_section("🧭 Learning Steps")
	_stage_option = menu.add_option_button("Step", [
		"1 · Blades", "2 · Tufts", "3 · Pampas and light", "4 · Wind",
	], demo_stage, _on_stage_selected)
	_stage_description = menu.add_label(STAGE_DESCRIPTIONS[demo_stage])
	menu.add_separator()
	menu.add_section("☀️ Sunlight")
	menu.add_slider("Sun elevation", 2.0, 80.0, sun_elevation,
		set_sun_elevation, true, 1.0)
	menu.add_slider("Sun azimuth", 0.0, 360.0, sun_azimuth,
		set_sun_azimuth, true, 1.0)
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
	quality.bind("near_detail", null, grass.set_near_detail)
	menu.add_slider("Clumping", 0.0, 1.0, 0.55, grass.set_clumping)
	_wind_speed_slider = menu.add_slider("Wind Speed", 0.0, 5.0, wind_speed,
		func(value: float) -> void:
			wind_speed = value
			grass.set_wind_speed(value)
			_mark_custom_wind())
	menu.add_separator()
	menu.add_section("🌬 Wind Field")
	_wind_direction_slider = menu.add_slider("Direction", 0.0, 360.0, wind_direction_degrees,
		func(value: float) -> void:
			wind_direction_degrees = value
			grass.set_wind_direction(value)
			_mark_custom_wind(), true, 1.0)
	_gustiness_slider = menu.add_slider("Gustiness", 0.0, 1.0, gustiness,
		func(value: float) -> void:
			gustiness = value
			grass.set_gustiness(value)
			_mark_custom_wind())
	menu.add_separator()
	menu.add_section("🎨 Grass Palette")
	_palette_option = menu.add_option_button("Palette", ["Pampas", "Meadow", "Ember", "Prism"],
		_palette_index, _on_palette_selected)
	_palette_pickers["base"] = menu.add_color_picker("Base Color", _palette_colors.base,
		func(color: Color) -> void: _set_palette_color("base", color))
	_palette_pickers["tip"] = menu.add_color_picker("Tip Color", _palette_colors.tip,
		func(color: Color) -> void: _set_palette_color("tip", color))
	_palette_pickers["backlight"] = menu.add_color_picker("Backlight", _palette_colors.backlight,
		func(color: Color) -> void: _set_palette_color("backlight", color))
	_palette_pickers["plume"] = menu.add_color_picker("Plumes", _palette_colors.plume,
		func(color: Color) -> void: _set_palette_color("plume", color))
	_palette_pickers["moss"] = menu.add_color_picker("Ground Shade", _palette_colors.moss,
		func(color: Color) -> void: _set_palette_color("moss", color))
	_palette_pickers["straw"] = menu.add_color_picker("Ground Light", _palette_colors.straw,
		func(color: Color) -> void: _set_palette_color("straw", color))
	_chromatic_slider = menu.add_slider("Color Gradient", 0.0, 1.0,
		_chromatic_strength, _set_chromatic_strength, true, 0.01)
	menu.add_separator()
	menu.add_section("🎞 Filters")
	_filter_option = menu.add_option_button("Filter", FILTER_NAMES, _filter_index,
		_on_filter_selected)
	menu.add_separator()
	menu.add_section("⚙️ Rendering")
	menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	var shadow_slider: HSlider = menu.add_slider("Shadow distance", 0.0, 100.0,
		shadow_distance_m, _set_shadow_distance)
	quality.bind("shadow_distance_m", shadow_slider, _set_shadow_distance)
	var shadows_toggle: Button = menu.add_debug_toggle("🌑", "Cast shadows",
		grass.shadows_enabled, _set_shadows)
	quality.bind("shadows", shadows_toggle, _set_shadows)
	quality.attach_menu_option(menu)
	menu.add_action("🌬", "Gust", func() -> void: grass.add_gust(4.0, orbit_cam.target))
	_wind_preset_action = menu.add_action("🍃", "Wind", cycle_wind_preset)
	_refresh_wind_action()
	_palette_action = menu.add_action("🎨", "Palette", cycle_palette)
	_refresh_palette_action()
	menu.add_action("🎲", "Regen", grass.regenerate)


func _on_stage_selected(index: int) -> void:
	demo_stage = clampi(index, 0, STAGE_DESCRIPTIONS.size() - 1)
	grass.set_demo_stage(demo_stage)
	if _stage_description != null:
		_stage_description.text = STAGE_DESCRIPTIONS[demo_stage]


func cycle_wind_preset() -> void:
	apply_preset((_wind_preset_index + 1) % WIND_PRESETS.size())


func apply_preset(index: int) -> void:
	_wind_preset_index = clampi(index, 0, WIND_PRESETS.size() - 1)
	var preset: Dictionary = WIND_PRESETS[_wind_preset_index]
	_applying_wind_preset = true
	_wind_speed_slider.value = preset.speed
	_wind_direction_slider.value = preset.direction
	_gustiness_slider.value = preset.gustiness
	_applying_wind_preset = false
	wind_speed = preset.speed
	wind_direction_degrees = preset.direction
	gustiness = preset.gustiness
	grass.set_wind_speed(wind_speed)
	grass.set_wind_direction(wind_direction_degrees)
	grass.set_gustiness(gustiness)
	_refresh_wind_action()


func _mark_custom_wind() -> void:
	if _applying_wind_preset:
		return
	_wind_preset_index = -1
	_refresh_wind_action()


func _refresh_wind_action() -> void:
	if _wind_preset_action == null:
		return
	var preset_name: String = "Wind" if _wind_preset_index < 0 else WIND_PRESETS[_wind_preset_index].name
	menu.set_action_label(_wind_preset_action, preset_name)


func cycle_palette() -> void:
	apply_look((_palette_index + 1) % COLOR_PALETTES.size())


func apply_look(index: int) -> void:
	index = clampi(index, 0, COLOR_PALETTES.size() - 1)
	_palette_option.select(index)
	_palette_option.item_selected.emit(index)


func _on_palette_selected(index: int) -> void:
	_palette_index = clampi(index, 0, COLOR_PALETTES.size() - 1)
	var palette: Dictionary = COLOR_PALETTES[_palette_index]
	for color_key in _palette_colors:
		var picker: ColorPickerButton = _palette_pickers[color_key]
		picker.color = palette[color_key]
		picker.color_changed.emit(palette[color_key])
	_chromatic_slider.value = palette.chromatic
	_set_chromatic_strength(float(palette.chromatic))
	_refresh_palette_action()


func _set_palette_color(color_key: String, color: Color) -> void:
	_palette_colors[color_key] = color
	match color_key:
		"base": grass.set_base_color(color)
		"tip":
			grass.set_tip_color(color)
			(ground_mesh.material_override as ShaderMaterial).set_shader_parameter("distant_color", color)
		"backlight": grass.set_sss_color(color)
		"plume": grass.set_plume_color(color)
		"moss": (ground_mesh.material_override as ShaderMaterial).set_shader_parameter("moss_color", color)
		"straw": (ground_mesh.material_override as ShaderMaterial).set_shader_parameter("straw_color", color)


func _set_chromatic_strength(value: float) -> void:
	_chromatic_strength = value
	grass.set_chromatic_strength(value)
	(ground_mesh.material_override as ShaderMaterial).set_shader_parameter("chromatic_strength", value)


func _setup_environment() -> void:
	_atmosphere_look = GOLDEN_HOUR.duplicate() as OceanLookPreset
	_atmosphere_look.cloud_coverage = 0.22
	_atmosphere_look.cloud_density = 0.32
	_atmosphere_look.cloud_base_color = Color(0.29, 0.37, 0.49)
	_atmosphere_look.cloud_rim_strength = 0.65
	var look := _atmosphere_look
	sun.light_angular_distance = 1.0
	sun.shadow_enabled = grass.shadows_enabled
	sun.shadow_opacity = 0.8
	# Softens the shadow-map lookup: at low sun the sparse shadow proxy casts
	# long streaks whose rasterized edges would read as blocks from above.
	sun.shadow_blur = 1.1
	# Light3D shadow_normal_bias defaults to 2 m: the lookups would land 2 m
	# above the <1.5 m canopy, washing the shadows off the blades.
	sun.shadow_normal_bias = 0.1
	# Single cascade (directional_shadow_mode = 0 in grass_demo.tscn): PSSM
	# splits draw a visible shadow-density boundary that moves with the camera,
	# which reads far worse than the coarser single-map texels (~7 mm at the
	# 30 m MEDIUM range). The fade ring is pushed out to keep it off close views.
	sun.directional_shadow_fade_start = 0.9

	var environment := world_env.environment
	sun.directional_shadow_max_distance = shadow_distance_m
	environment.ambient_light_energy = 0.55
	environment.ambient_light_color = Color(0.52, 0.64, 0.8)
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = look.exposure
	environment.tonemap_white = look.white_point
	environment.glow_enabled = true
	environment.glow_intensity = look.glow_intensity
	environment.glow_bloom = look.glow_bloom
	environment.glow_hdr_threshold = look.glow_hdr_threshold
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.61, 0.69, 0.77)
	environment.fog_density = 0.0025
	environment.fog_aerial_perspective = look.fog_aerial_perspective

	sky_material.shader = load("res://shaders/ocean/ocean_sky.gdshader")
	sky_material.set_shader_parameter("zenith_color", look.sky_zenith)
	sky_material.set_shader_parameter("horizon_color", look.sky_horizon)
	sky_material.set_shader_parameter("haze_color", look.haze_color)
	sky_material.set_shader_parameter("sun_color", look.sun_disk_color)
	sky_material.set_shader_parameter("energy", look.sky_energy)
	sky_material.set_shader_parameter("gradient_height", 0.22)
	sky_material.set_shader_parameter("haze_strength", 0.16)
	sky_material.set_shader_parameter("sun_disk_energy", 4.0)
	sky_material.set_shader_parameter("sun_halo_energy", 0.8)
	var sky := Sky.new()
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.sky_material = sky_material
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	cloudscape.camera = main_camera
	cloudscape.sun = sun
	cloudscape.shadow_receivers = [grass.material, ground_mesh.material_override as ShaderMaterial]
	add_child(cloudscape)
	cloudscape.build()
	_apply_sun()


func set_sun_elevation(value: float) -> void:
	sun_elevation = clampf(value, 2.0, 80.0)
	_apply_sun()


func set_sun_azimuth(value: float) -> void:
	sun_azimuth = clampf(value, 0.0, 360.0)
	_apply_sun()


func _apply_sun() -> void:
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth, 0.0)
	var daylight := smoothstep(8.0, 42.0, sun_elevation)
	sun.light_color = Color(1.0, 0.86, 0.67).lerp(Color(1.0, 0.98, 0.92), daylight)
	sun.light_energy = lerpf(4.0, 3.8, daylight)
	world_env.environment.ambient_light_energy = lerpf(0.55, 0.7, daylight)
	sky_material.set_shader_parameter("zenith_color",
		Color(0.1, 0.35, 0.72).lerp(Color(0.12, 0.4, 0.76), daylight))
	sky_material.set_shader_parameter("horizon_color",
		Color(0.8, 0.66, 0.48).lerp(Color(0.68, 0.78, 0.87), daylight))
	sky_material.set_shader_parameter("haze_color",
		Color(0.69, 0.65, 0.58).lerp(Color(0.72, 0.8, 0.88), daylight))
	sky_material.set_shader_parameter("sun_color", sun.light_color)
	var direction := sun.global_transform.basis.z.normalized()
	sky_material.set_shader_parameter("sun_direction", direction)
	sky_material.set_shader_parameter("sun_radius",
		deg_to_rad(sun.light_angular_distance) * 0.5)
	if cloudscape.is_inside_tree():
		_atmosphere_look.cloud_top_color = Color(0.92, 0.86, 0.76).lerp(
			Color(0.95, 0.97, 1.0), daylight)
		_atmosphere_look.cloud_rim_color = sun.light_color
		cloudscape.apply_look(_atmosphere_look, 0.0)
		cloudscape.set_sun_direction(direction)


## Full-screen stylization pass: a ColorRect on its own CanvasLayer BELOW the
## SimMenu layer, so SCREEN_TEXTURE holds the rendered field while the menu
## above stays unfiltered. Off hides the rect entirely (zero fragment cost).
func _setup_post_fx() -> void:
	_post_fx_layer = CanvasLayer.new()
	_post_fx_layer.layer = 0
	_post_fx_material = ShaderMaterial.new()
	_post_fx_material.shader = POST_FX_SHADER
	_post_fx_material.set_shader_parameter("filter_mode", _filter_index)
	_post_fx_rect = ColorRect.new()
	_post_fx_rect.material = _post_fx_material
	_post_fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_post_fx_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_post_fx_rect.visible = _filter_index != 0
	_post_fx_layer.add_child(_post_fx_rect)
	add_child(_post_fx_layer)


func _apply_filter() -> void:
	_post_fx_rect.visible = _filter_index != 0
	_post_fx_material.set_shader_parameter("filter_mode", _filter_index)


func _on_filter_selected(index: int) -> void:
	_filter_index = clampi(index, 0, FILTER_NAMES.size() - 1)
	_apply_filter()


func _refresh_palette_action() -> void:
	if _palette_action != null:
		menu.set_action_label(_palette_action, COLOR_PALETTES[_palette_index].name)


func set_capture_params(params: Dictionary) -> void:
	if params.has("stage"):
		_on_stage_selected(int(round(float(params["stage"]))))
		if _stage_option != null:
			_stage_option.select(demo_stage)
	if params.has("wind_speed"):
		wind_speed = clampf(float(params["wind_speed"]), 0.0, 5.0)
		grass.set_wind_speed(wind_speed)
	if params.has("wind_direction"):
		wind_direction_degrees = fposmod(float(params["wind_direction"]), 360.0)
		grass.set_wind_direction(wind_direction_degrees)
	if params.has("gustiness"):
		gustiness = clampf(float(params["gustiness"]), 0.0, 1.0)
		grass.set_gustiness(gustiness)
	if params.has("gust") and float(params["gust"]) > 0.0:
		grass.add_gust(float(params["gust"]), orbit_cam.target)
	if params.has("filter"):
		var index := clampi(int(params["filter"]), 0, FILTER_NAMES.size() - 1)
		if _filter_option != null:
			_filter_option.select(index)
			_filter_option.item_selected.emit(index)
		else:
			_filter_index = index
			_apply_filter()
	if params.has("shadows"):
		_set_shadows(bool(params["shadows"]))
	if params.has("light_energy"):
		sun.light_energy = clampf(float(params["light_energy"]), 0.0, 40.0)


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


func set_capture_view(view: String) -> void:
	match view:
		"near":
			orbit_cam.distance = 9.0
			orbit_cam.pitch = -18.0
		"far":
			orbit_cam.distance = 38.0
			orbit_cam.pitch = -12.0
		"high":
			orbit_cam.distance = 26.0
			orbit_cam.pitch = -42.0
		"horizon":
			orbit_cam.distance = 20.0
			orbit_cam.pitch = -5.0
		"overhead":
			orbit_cam.distance = 32.0
			orbit_cam.pitch = -78.0
		"top":
			orbit_cam.distance = 14.0
			orbit_cam.pitch = -87.0
		_:
			orbit_cam.distance = 20.0
			orbit_cam.pitch = -28.0


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _set_shadow_distance(value: float) -> void:
	shadow_distance_m = value
	sun.directional_shadow_max_distance = value


func _set_shadows(enabled: bool) -> void:
	grass.set_shadows(enabled)
	sun.shadow_enabled = enabled
	cloudscape.set_shadows_enabled(enabled)


## Before grass.build() the values land on the fields the build reads; density
## is owned by the persisted slider value at launch (seeded in _ready). After,
## the setters regenerate and re-flag. Set_density runs the GDScript blade
## fill, so it must not run twice at launch.
func _apply_quality(values: Dictionary) -> void:
	if not _grass_ready:
		grass.near_detail = values.near_detail
		grass.shadows_enabled = values.shadows
		shadow_distance_m = values.shadow_distance_m
		return
	grass.set_near_detail(values.near_detail)
	grass.set_density(values.density)
	_set_shadows(values.shadows)
	_set_shadow_distance(values.shadow_distance_m)
