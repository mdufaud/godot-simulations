class_name RiverSystem extends Node3D

const REFLECTION_LAYER := 1 << 17
const Reflections := preload("res://scripts/river/river_reflections.gd")
const SweSystem := preload("res://scripts/river/river_swe_system.gd")

signal simulation_changed

var config: RiverConfig
var scenery_materials: Array[ShaderMaterial] = []
var compute_available := false
var swe: SweSystem
var field: RiverField
var camera: Camera3D
var scene_world: World3D
var render_size := Vector2i(1280, 720)
var reflection_anchor_z_m := 0.0
var surface_cell_size_m := 0.5
var foam_size_px := Vector2i(512, 1024)
var foam_detail := true
var reflection_scale := 0.5
var reflection_plane_count := 1
var surface_detail := 0.0
var rapids_reflection := false
var frozen := false
var fixed_delta_s := -1.0
var simulation_time_s := 0.0
var flow_distance_m := 0.0
var water_material: ShaderMaterial
var reflection_viewport: SubViewport
var reflection_camera: Camera3D
var _foam_views: Array[SubViewport] = []
var _foam_materials: Array[ShaderMaterial] = []
var _field_texture: ImageTexture
var _turbulence_texture: NoiseTexture2D
var _foam_index := 0
var _reset_frames := 2
var _started := false
var _reflection_requested := true
var _surface_mesh: PlaneMesh
var _swe_surface_mesh: Mesh
var _surface: MeshInstance3D
var _reflections := Reflections.new()


func start() -> void:
	if _started:
		return
	assert(config != null and field != null and camera != null and scene_world != null)
	var error := config.validate()
	if not error.is_empty():
		push_error(error)
		return
	water_material = ShaderMaterial.new()
	water_material.shader = load("res://shaders/river/river_water.gdshader")
	water_material.set_shader_parameter("domain_m", RiverField.DOMAIN_M)
	water_material.set_shader_parameter("micro_normal", load("res://resources/ocean/micro_normal.png"))
	water_material.set_shader_parameter("foam_filaments", load("res://resources/ocean/foam_variant_03_flowing_filaments.png"))
	water_material.set_shader_parameter("foam_bubbles", load("res://resources/ocean/foam_variant_01_microbubbles.png"))
	water_material.set_shader_parameter("surface_detail", surface_detail)
	water_material.set_shader_parameter("foam_detail", foam_detail)
	water_material.set_shader_parameter("riverbed_albedo", load("res://resources/materials/clean_pebbles/clean_pebbles_diff_2k.jpg"))
	var noise := FastNoiseLite.new()
	noise.seed = 5289
	noise.frequency = 0.04
	noise.fractal_octaves = 3
	_turbulence_texture = NoiseTexture2D.new()
	_turbulence_texture.width = 256
	_turbulence_texture.height = 256
	_turbulence_texture.seamless = true
	_turbulence_texture.generate_mipmaps = true
	_turbulence_texture.noise = noise
	water_material.set_shader_parameter("turbulence_texture", _turbulence_texture)
	_surface_mesh = PlaneMesh.new()
	_surface_mesh.size = RiverField.DOMAIN_M
	set_surface_cell_size_m(surface_cell_size_m)
	_surface = MeshInstance3D.new()
	_surface.name = "RiverSurface"
	_surface.mesh = _surface_mesh
	_surface.material_override = water_material
	_surface.layers = 2
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.extra_cull_margin = 2.5
	add_child(_surface)
	_build_foam()
	_build_reflection()
	swe = SweSystem.new()
	swe.config = config
	swe.field = field
	swe.materials.assign([water_material] + _foam_materials + scenery_materials)
	swe.available = compute_available
	add_child(swe)
	swe.state_changed.connect(_sync_surface)
	swe.start()
	_started = true
	set_process(true)
	apply_config(config)
	process_priority = 20


func apply_config(value: RiverConfig) -> void:
	var error := value.validate()
	if not error.is_empty():
		push_error(error)
		return
	var previous_level: Variant = water_material.get_shader_parameter("water_level_m") if _field_texture != null else null
	config = value
	swe.config = config
	if previous_level == null or not is_equal_approx(float(previous_level), config.water_level_m):
		_field_texture = field.bake(config.water_level_m)
		water_material.set_shader_parameter("flow_map", _field_texture)
		water_material.set_shader_parameter("bed_height_texture", field.bed_texture)
		for material in _foam_materials:
			material.set_shader_parameter("flow_map", _field_texture)
		_reset_frames = 2
	water_material.set_shader_parameter("water_level_m", config.water_level_m)
	water_material.set_shader_parameter("speed_m_s", config.speed_m_s)
	water_material.set_shader_parameter("clarity", config.clarity)
	water_material.set_shader_parameter("ripple_height_m", config.ripple_height_m)
	water_material.set_shader_parameter("roughness", config.roughness)
	water_material.set_shader_parameter("deep_color", config.deep_color)
	water_material.set_shader_parameter("whitewater_strength", config.whitewater_strength)
	water_material.set_shader_parameter("foam_amount", config.foam_amount)
	set_reflection_enabled(_reflection_requested)


func set_reflection_enabled(enabled: bool) -> void:
	_reflection_requested = enabled
	var active := enabled and reflection_scale > 0.0 and (rapids_reflection or config.whitewater_strength < 0.85)
	water_material.set_shader_parameter("reflection_enabled", active)
	_reflections.set_active(active)


func set_surface_detail(value: float) -> void:
	surface_detail = value
	if water_material != null:
		water_material.set_shader_parameter("surface_detail", value)


func set_foam_detail(enabled: bool) -> void:
	foam_detail = enabled
	if water_material != null:
		water_material.set_shader_parameter("foam_detail", enabled)


func set_reflection_plane_count(value: int) -> void:
	reflection_plane_count = value
	_reflections.include_grass = value == 4
	if water_material != null:
		_reflections.set_plane_count(value)
		reflection_viewport = _reflections.views[0]
		reflection_camera = _reflections.cameras[0]
		_sync_reflection()


func set_reflection_profiling(enabled: bool) -> void:
	_reflections.set_profiling(enabled)


func reflection_gpu_ms() -> float:
	return _reflections.gpu_ms()


func set_surface_cell_size_m(value: float) -> void:
	surface_cell_size_m = value
	if _surface_mesh != null:
		_surface_mesh.subdivide_width = maxi(ceili(RiverField.DOMAIN_M.x / value) - 1, 0)
		_surface_mesh.subdivide_depth = maxi(ceili(RiverField.DOMAIN_M.y / value) - 1, 0)
		_swe_surface_mesh = null
		if _surface != null:
			_sync_surface()


func _sync_surface() -> void:
	if swe != null and swe.enabled and swe.initialized:
		if _swe_surface_mesh == null:
			_swe_surface_mesh = SweSystem.surface_mesh(_surface_mesh)
		_surface.mesh = _swe_surface_mesh
	else:
		_surface.mesh = _surface_mesh
	simulation_changed.emit()


func set_foam_size_px(value: Vector2i) -> void:
	if value == foam_size_px:
		return
	foam_size_px = value
	for viewport in _foam_views:
		viewport.size = value
		(viewport.get_child(0) as ColorRect).size = Vector2(value)
	_reset_frames = 2


func set_reflection_scale(value: float) -> void:
	reflection_scale = value
	_reflections.scale = value
	if reflection_viewport != null:
		set_reflection_enabled(_reflection_requested)
		_sync_reflection()


func _build_foam() -> void:
	for i in 2:
		var viewport := SubViewport.new()
		viewport.name = "Foam%d" % i
		viewport.size = foam_size_px
		viewport.disable_3d = true
		viewport.use_hdr_2d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(viewport)
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/river/river_foam.gdshader")
		material.set_shader_parameter("domain_m", RiverField.DOMAIN_M)
		material.set_shader_parameter("turbulence_texture", _turbulence_texture)
		var rect := ColorRect.new()
		rect.size = Vector2(viewport.size)
		rect.material = material
		viewport.add_child(rect)
		_foam_views.append(viewport)
		_foam_materials.append(material)


func _build_reflection() -> void:
	_reflections.reflection_layer = REFLECTION_LAYER
	_reflections.scale = reflection_scale
	_reflections.plane_count = reflection_plane_count
	_reflections.include_grass = reflection_plane_count == 4
	_reflections.build(self, camera, scene_world, water_material)
	reflection_viewport = _reflections.views[0]
	reflection_camera = _reflections.cameras[0]
	_sync_reflection()


func _sync_reflection() -> void:
	_reflections.sync(render_size, config.water_level_m, reflection_anchor_z_m)


func _process(delta: float) -> void:
	if not _started:
		return
	_sync_reflection()
	var step := (fixed_delta_s if fixed_delta_s > 0.0 else delta) if not frozen else 0.0
	swe.tick(step, delta, simulation_time_s)
	if frozen and _reset_frames == 0:
		return
	simulation_time_s += step
	flow_distance_m += config.speed_m_s * step
	water_material.set_shader_parameter("flow_distance_m", flow_distance_m)
	var previous := 1 - _foam_index
	_foam_views[previous].render_target_update_mode = SubViewport.UPDATE_DISABLED
	_foam_materials[previous].set_shader_parameter("previous_foam", null)
	var material := _foam_materials[_foam_index]
	material.set_shader_parameter("previous_foam", _foam_views[previous].get_texture())
	material.set_shader_parameter("speed_m_s", config.speed_m_s)
	material.set_shader_parameter("foam_amount", config.foam_amount)
	material.set_shader_parameter("delta_s", step)
	material.set_shader_parameter("simulation_time_s", simulation_time_s)
	material.set_shader_parameter("whitewater_strength", config.whitewater_strength)
	material.set_shader_parameter("reset", _reset_frames > 0)
	_foam_views[_foam_index].render_target_update_mode = SubViewport.UPDATE_ONCE
	water_material.set_shader_parameter("foam_map", _foam_views[_foam_index].get_texture())
	_foam_index = previous
	_reset_frames = maxi(0, _reset_frames - 1)


func reset() -> void:
	simulation_time_s = 0.0
	flow_distance_m = 0.0
	_reset_frames = 2
	swe.reset()
	water_material.set_shader_parameter("flow_distance_m", 0.0)


func stop() -> void:
	if not _started:
		return
	_started = false
	set_process(false)
	_reflections.stop()
	swe.stop()
	water_material.set_shader_parameter("foam_map", null)
	for material in _foam_materials:
		material.set_shader_parameter("previous_foam", null)
	for child in get_children():
		child.free()
	swe = null
	_foam_views.clear()
	_foam_materials.clear()
	_field_texture = null
	_turbulence_texture = null
	field.bed_texture = null
	water_material = null
	reflection_viewport = null
	reflection_camera = null
	_surface_mesh = null
	_swe_surface_mesh = null
	_surface = null


func _exit_tree() -> void:
	stop()
