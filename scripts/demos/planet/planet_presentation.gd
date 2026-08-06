class_name PlanetPresentation extends RefCounted
## Everything the planet demo draws with: the three shader materials, the sky
## environment and the aiming crosshair. Built once, then only written through.

var surface: ShaderMaterial
var atmosphere: ShaderMaterial
var sky: ShaderMaterial
var crosshair: Control


func build(planet_mesh: MeshInstance3D, atmosphere_quad: MeshInstance3D,
		world_env: WorldEnvironment, ui_layer: Node, mobile: bool) -> void:
	surface = ShaderMaterial.new()
	surface.shader = load("res://shaders/planet/planet_surface.gdshader")
	surface.set_shader_parameter("detail_octaves", 3 if mobile else 8)
	planet_mesh.material_override = surface

	atmosphere = ShaderMaterial.new()
	atmosphere.shader = load("res://shaders/planet/planet_atmosphere.gdshader")

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = atmosphere
	atmosphere_quad.mesh = quad
	# The quad is pinned to the near plane in the shader, so its real bounds are
	# meaningless: make them big enough never to be culled.
	atmosphere_quad.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))

	_build_environment(world_env)
	_build_crosshair(ui_layer)


func _build_environment(world_env: WorldEnvironment) -> void:
	sky = ShaderMaterial.new()
	sky.shader = load("res://shaders/planet/planet_sky.gdshader")

	var sky_resource := Sky.new()
	sky_resource.sky_material = sky
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky_resource
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = false
	world_env.environment = env


func _build_crosshair(ui_layer: Node) -> void:
	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 28)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.visible = false
	ui_layer.add_child(crosshair)


## Height gradient of the active preset, rescaled by how far the live radius has
## moved from the radius it was quoted at; otherwise a small planet falls entirely
## below the gradient and renders in a single flat colour.
func set_height_range(preset: PlanetPreset, radius_m: float) -> void:
	var scale := radius_m / preset.radius_m
	surface.set_shader_parameter("height_min", preset.height_min_m * scale)
	surface.set_shader_parameter("height_max", preset.height_max_m * scale)


func set_sun_direction(dir_to_sun: Vector3) -> void:
	surface.set_shader_parameter("sun_direction", dir_to_sun)
	sky.set_shader_parameter("sun_direction", dir_to_sun)


func set_atmosphere_params(params: Dictionary) -> void:
	for key in params:
		atmosphere.set_shader_parameter(key, params[key])
