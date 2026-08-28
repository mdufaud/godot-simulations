class_name OceanCloudscape extends Node3D

const CLOUD_SEED := 73021
const CLOUD_FAR := 8000.0
const CLOUD_LAYER := 1 << 18
const CLOUD_BASE := 220.0
const CLOUD_TOP := 680.0
## Overcast palette the look colors are pushed towards as the storm mood rises.
const STORM_TOP_COLOR := Color(0.52, 0.55, 0.54)
const STORM_BASE_COLOR := Color(0.12, 0.15, 0.14)
const STORM_RIM_COLOR := Color(0.55, 0.60, 0.58)

var camera: Camera3D
var sun: DirectionalLight3D

var _cloud_viewport: SubViewport
var _cloud_camera: Camera3D
var _cloud_mesh: MeshInstance3D
var _noise_texture: NoiseTexture3D
var _data_material := ShaderMaterial.new()
var _composite_material := ShaderMaterial.new()
var _composite: MeshInstance3D
var _wind_offset := Vector2.ZERO
var _density := 0.75
var _coverage := 0.78
var _profiling := false
var _viewport_scale := 0.5
var _viewport_size := Vector2i.ZERO


func build() -> void:
	assert(camera != null and sun != null, "OceanCloudscape requires camera and sun")
	process_priority = 10
	_data_material.shader = load("res://shaders/ocean/ocean_cloud_data.gdshader")
	_composite_material.shader = load("res://shaders/ocean/ocean_cloud_composite.gdshader")
	_data_material.set_shader_parameter("cloud_base", CLOUD_BASE)
	_data_material.set_shader_parameter("cloud_top", CLOUD_TOP)
	_data_material.set_shader_parameter("cloud_far", CLOUD_FAR)
	_build_noise()
	_build_cloud_viewport()
	_build_composite()
	if not get_viewport().size_changed.is_connected(_resize_viewports):
		get_viewport().size_changed.connect(_resize_viewports)
	_resize_viewports()
	_sync_camera()


func _process(delta: float) -> void:
	update(delta)


func update(delta: float) -> void:
	if camera == null or _cloud_camera == null:
		return
	_wind_offset += Vector2(7.0, 2.5) * delta
	_sync_camera()
	_data_material.set_shader_parameter("wind_offset", _wind_offset)


func apply_look(look: OceanLookPreset, mood: float) -> void:
	_density = lerpf(look.cloud_density, 0.96, mood)
	_coverage = lerpf(look.cloud_coverage, 1.0, mood)
	_data_material.set_shader_parameter("top_color",
		look.cloud_top_color.lerp(STORM_TOP_COLOR, mood))
	_data_material.set_shader_parameter("base_color",
		look.cloud_base_color.lerp(STORM_BASE_COLOR, mood))
	_data_material.set_shader_parameter("rim_color",
		look.cloud_rim_color.lerp(STORM_RIM_COLOR, mood))
	_data_material.set_shader_parameter("rim_strength",
		lerpf(look.cloud_rim_strength, 0.3, mood))
	# The sun loses most of its energy in a storm; the raymarch lights itself, so
	# it has to be told.
	_data_material.set_shader_parameter("light_scale", lerpf(1.0, 0.58, mood))
	_data_material.set_shader_parameter("storm_mood", mood)
	_data_material.set_shader_parameter("sun_direction", sun.global_transform.basis.z.normalized())
	_data_material.set_shader_parameter("coverage", _coverage)
	_data_material.set_shader_parameter("density", _density)
	_composite_material.set_shader_parameter("density", _density)
	_composite_material.set_shader_parameter("storm_mood", mood)


func set_lightning(position: Vector3, energy: float) -> void:
	_data_material.set_shader_parameter("flash_pos", position)
	_data_material.set_shader_parameter("flash_intensity", energy * 5.0)


func set_sun_direction(direction: Vector3) -> void:
	_data_material.set_shader_parameter("sun_direction", direction)


func reflection_texture() -> Texture2D:
	return _cloud_viewport.get_texture() if _cloud_viewport != null else null


func capture_alpha_coverage() -> float:
	if _cloud_viewport == null:
		return 0.0
	var image := _cloud_viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return 0.0
	var active := 0
	var samples := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			if image.get_pixel(x, y).a > 0.02:
				active += 1
			samples += 1
	return float(active) / maxf(float(samples), 1.0)


func set_profiling(on: bool) -> void:
	_profiling = on
	if _cloud_viewport != null:
		RenderingServer.viewport_set_measure_render_time(_cloud_viewport.get_viewport_rid(), on)


func set_enabled(on: bool) -> void:
	if _composite != null:
		_composite.visible = on
	if _cloud_viewport != null:
		_cloud_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS \
			if on else SubViewport.UPDATE_DISABLED


func get_gpu_time() -> float:
	if not _profiling or _cloud_viewport == null:
		return 0.0
	return RenderingServer.viewport_get_measured_render_time_gpu(
		_cloud_viewport.get_viewport_rid())


static func noise_signature() -> Dictionary:
	return {"seed": CLOUD_SEED, "width": 96, "height": 96, "depth": 48}


func _build_noise() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = CLOUD_SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.035
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.52
	noise.fractal_lacunarity = 2.05
	_noise_texture = NoiseTexture3D.new()
	_noise_texture.seamless = true
	_noise_texture.width = 96
	_noise_texture.height = 96
	_noise_texture.depth = 48
	_noise_texture.noise = noise
	_data_material.set_shader_parameter("noise_tex", _noise_texture)


func _build_cloud_viewport() -> void:
	_cloud_viewport = SubViewport.new()
	_cloud_viewport.name = "CloudVolumeViewport"
	_cloud_viewport.own_world_3d = true
	_cloud_viewport.transparent_bg = true
	_cloud_viewport.use_hdr_2d = true
	_cloud_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_cloud_viewport.positional_shadow_atlas_size = 0
	_cloud_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_cloud_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_cloud_viewport)

	_cloud_camera = Camera3D.new()
	_cloud_camera.name = "CloudVolumeCamera"
	_cloud_camera.current = true
	_cloud_camera.cull_mask = CLOUD_LAYER
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	_cloud_camera.environment = environment
	_cloud_viewport.add_child(_cloud_camera)

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_cloud_mesh = MeshInstance3D.new()
	_cloud_mesh.name = "CloudVolumeRaymarch"
	_cloud_mesh.mesh = quad
	_cloud_mesh.material_override = _data_material
	_cloud_mesh.layers = CLOUD_LAYER
	_cloud_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cloud_mesh.custom_aabb = AABB(Vector3(-10000.0, -10000.0, -10000.0),
		Vector3(20000.0, 20000.0, 20000.0))
	_cloud_viewport.add_child(_cloud_mesh)


func _build_composite() -> void:
	_composite_material.set_shader_parameter("cloud_texture", _cloud_viewport.get_texture())
	_composite_material.set_shader_parameter("cloud_far", CLOUD_FAR)
	_composite_material.set_shader_parameter("cloud_base", CLOUD_BASE)
	_composite_material.set_shader_parameter("cloud_top", CLOUD_TOP)
	_composite_material.set_shader_parameter("density", _density)
	_composite_material.render_priority = -1
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = _composite_material
	_composite = MeshInstance3D.new()
	_composite.name = "CloudComposite"
	_composite.mesh = quad
	_composite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_composite.custom_aabb = AABB(Vector3(-10000.0, -10000.0, -10000.0),
		Vector3(20000.0, 20000.0, 20000.0))
	add_child(_composite)


func _resize_viewports() -> void:
	if _cloud_viewport == null:
		return
	_viewport_scale = 0.375 if OS.has_feature("mobile") else 0.5
	var main_size := get_viewport().get_visible_rect().size
	var target := Vector2i(maxi(2, roundi(main_size.x * _viewport_scale)),
		maxi(2, roundi(main_size.y * _viewport_scale)))
	if target == _viewport_size:
		return
	_viewport_size = target
	_cloud_viewport.size = target
	_data_material.set_shader_parameter("march_steps", 24 if OS.has_feature("mobile") else 40)
	_data_material.set_shader_parameter("viewport_size", Vector2(target))


func _sync_camera() -> void:
	_cloud_camera.global_transform = camera.global_transform
	_cloud_camera.fov = camera.fov
	_cloud_camera.keep_aspect = camera.keep_aspect
	_cloud_camera.near = camera.near
	_cloud_camera.far = camera.far
	var inverse_projection := camera.get_camera_projection().inverse()
	var inverse_view := camera.global_transform
	_data_material.set_shader_parameter("inverse_projection", inverse_projection)
	_data_material.set_shader_parameter("inverse_view", inverse_view)
	_composite_material.set_shader_parameter("inverse_projection", inverse_projection)
	_composite_material.set_shader_parameter("inverse_view", inverse_view)
