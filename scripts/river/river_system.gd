class_name RiverSystem extends Node3D

const REFLECTION_LAYER := 1 << 17
const Reflections := preload("res://scripts/river/river_reflections.gd")
const SweSystem := preload("res://scripts/river/river_swe_system.gd")
const WaterfallSystem := preload("res://scripts/river/river_waterfall_system.gd")
const WaterShader := preload("res://shaders/river/river_water.gdshader")
const SkirtShader := preload("res://shaders/river/river_water_skirt.gdshader")
const FoamShader := preload("res://shaders/river/river_foam.gdshader")

signal simulation_changed

var config: RiverConfig
var scenery_materials: Array[ShaderMaterial] = []
var compute_available := false
var swe: SweSystem
var waterfall: WaterfallSystem
var waterfall_quality := 1
var query_generation := 0
var field: RiverField
var loading_stage := Callable()
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
var swe_window_m := Vector2.ZERO
var swe_range_m := 0.0
var swe_cell_m := SweSystem.Solver.CELL_M
var simulation_time_s := 0.0
var flow_distance_m := 0.0
var water_material: ShaderMaterial
var micro_normal: Texture2D
var foam_filaments: Texture2D
var foam_bubbles: Texture2D
var riverbed_albedo: Texture2D
var reflection_viewport: SubViewport
var reflection_camera: Camera3D
var _foam_views: Array[SubViewport] = []
var _foam_materials: Array[ShaderMaterial] = []
var _field_texture: ImageTexture
var _turbulence_texture: NoiseTexture2D
var _foam_index := 0
var _foam_shift_uv := Vector2.ZERO
var _reset_frames := 2
var _started := false
var _reflection_requested := true
var _surface_mesh: PlaneMesh
var _cell_mesh: ArrayMesh
var _surface: MeshInstance3D
var _skirt: MeshInstance3D
var _skirt_material: ShaderMaterial
var _reflections := Reflections.new()
var _query_in_flight := false
var _cpu_query_batch: Dictionary = {}
var _query_guided := PackedFloat32Array()
var _query_weights := PackedFloat32Array()


func start() -> void:
	if _started:
		return
	assert(config != null and field != null and camera != null and scene_world != null)
	var error := config.validate()
	if not error.is_empty():
		push_error(error)
		return
	_report_stage("Creating water surface")
	water_material = ShaderMaterial.new()
	water_material.shader = WaterShader
	water_material.set_shader_parameter("domain_m", field.domain_m)
	water_material.set_shader_parameter("domain_origin_m", field.origin_m)
	water_material.set_shader_parameter("micro_normal", micro_normal)
	water_material.set_shader_parameter("foam_filaments", foam_filaments)
	water_material.set_shader_parameter("foam_bubbles", foam_bubbles if foam_bubbles != null else foam_filaments)
	water_material.set_shader_parameter("surface_detail", surface_detail)
	water_material.set_shader_parameter("foam_detail", foam_detail)
	water_material.set_shader_parameter("riverbed_albedo", riverbed_albedo)
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
	_surface_mesh.size = field.domain_m
	set_surface_cell_size_m(surface_cell_size_m)
	_surface = MeshInstance3D.new()
	_surface.name = "RiverSurface"
	_surface.mesh = _cell_mesh if field.spills else _surface_mesh
	_surface.material_override = water_material
	_surface.layers = 2
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.extra_cull_margin = 2.5
	_surface.position = Vector3(field.origin_m.x, 0.0, field.origin_m.y)
	add_child(_surface)
	if field.spills:
		_build_skirt()
	_report_stage("Building foam and reflections")
	_build_foam()
	_build_reflection()
	swe = SweSystem.new()
	swe.config = config
	swe.field = field
	swe.materials.assign([water_material] + _foam_materials + scenery_materials + ([_skirt_material] if _skirt_material != null else []))
	swe.available = compute_available
	swe.camera = camera
	swe.window_m = swe_window_m
	swe.range_m = swe_range_m
	swe.cell_m = swe_cell_m
	swe.solver.loading_stage = loading_stage
	add_child(swe)
	swe.state_changed.connect(func():
		cancel_queries()
		_sync_surface())
	_report_stage("Starting water solver")
	swe.start()
	_started = true
	set_process(true)
	_report_stage("Baking flow map")
	apply_config(config)
	if field.spills:
		# Started once the flow map is baked: the particle size follows the field's height range.
		waterfall = WaterfallSystem.new()
		waterfall.field = field
		waterfall.water = config
		waterfall.swe = swe
		waterfall.camera = camera
		waterfall.turbulence_texture = _turbulence_texture
		waterfall.quality_tier = waterfall_quality
		add_child(waterfall)
		_report_stage("Starting waterfall")
		waterfall.start()
	_sync_surface()
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
		_bake_field()
		_reset_frames = 2
	water_material.set_shader_parameter("water_level_m", config.water_level_m)
	water_material.set_shader_parameter("speed_m_s", config.speed_m_s)
	var reference_flow := field.sample_solver(field.origin_m, config.water_level_m)
	water_material.set_shader_parameter("foam_reference_flow", Vector2(reference_flow.r, reference_flow.g))
	water_material.set_shader_parameter("clarity", config.clarity)
	water_material.set_shader_parameter("ripple_height_m", config.ripple_height_m)
	water_material.set_shader_parameter("roughness", config.roughness)
	water_material.set_shader_parameter("deep_color", config.deep_color)
	water_material.set_shader_parameter("whitewater_strength", config.whitewater_strength)
	water_material.set_shader_parameter("foam_amount", config.foam_amount)
	if _skirt_material != null:
		_skirt_material.set_shader_parameter("deep_color", config.deep_color)
		_skirt_material.set_shader_parameter("whitewater_strength", config.whitewater_strength)
	if waterfall != null:
		waterfall.apply_config(config)
	set_reflection_enabled(_reflection_requested)


# Call after appending rock meshes to `field.obstacle_meshes`: the solver bed adapts without resetting the water.
func obstacles_added(meshes: Array[MeshInstance3D]) -> void:
	if not _started:
		return
	swe.add_obstacles(meshes, simulation_time_s)


func move_domain(origin_m: Vector2) -> void:
	if not _started:
		field.origin_m = origin_m
		return
	if field.spills:
		push_error("RiverSystem.move_domain() does not support spilling fields")
		return
	var was_dry := not field.has_water
	_foam_shift_uv = (origin_m - field.origin_m) / field.domain_m
	field.origin_m = origin_m
	_surface.position = Vector3(origin_m.x, 0.0, origin_m.y)
	for material: ShaderMaterial in [water_material] + _foam_materials:
		material.set_shader_parameter("domain_origin_m", origin_m)
	_bake_field()
	swe.move_domain()
	if was_dry and field.has_water:
		swe.reset()
		_reset_frames = 2
	set_reflection_enabled(_reflection_requested)
	_sync_surface()


func _bake_field() -> void:
	_field_texture = field.bake(config.water_level_m, Vector2i(384, 512), loading_stage)
	_fit_surface_bounds()
	_surface.visible = field.has_water
	if _skirt != null:
		_skirt.visible = field.has_water
	water_material.set_shader_parameter("flow_map", _field_texture)
	water_material.set_shader_parameter("bed_height_texture", field.bed_texture)
	for material in _foam_materials:
		material.set_shader_parameter("flow_map", _field_texture)


func _report_stage(label: String) -> void:
	if loading_stage.is_valid():
		loading_stage.call(label)


func _fit_surface_bounds() -> void:
	if field.height_range_m == Vector2.ZERO:
		return
	var low := field.height_range_m.x - 1.0
	_surface.custom_aabb = AABB(Vector3(-field.domain_m.x * 0.5, low, -field.domain_m.y * 0.5),
		Vector3(field.domain_m.x, field.height_range_m.y + 1.0 - low, field.domain_m.y))
	if _skirt != null:
		_skirt.custom_aabb = _surface.custom_aabb


func set_reflection_enabled(enabled: bool) -> void:
	_reflection_requested = enabled
	var active := enabled and reflection_scale > 0.0 and field.has_water and (rapids_reflection or config.whitewater_strength < 0.85)
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
		if field.spills:
			# The solver's own grid over the whole domain: spilling fields are never windowed.
			var cells := SweSystem.grid_for(field.domain_m, swe_cell_m)
			if _cell_mesh == null or water_material.get_shader_parameter("cell_grid") != cells:
				_cell_mesh = _build_quad_mesh(cells.x * cells.y)
				water_material.set_shader_parameter("cell_grid", cells)
			water_material.set_shader_parameter("cell_size_m", swe_cell_m)
		else:
			water_material.set_shader_parameter("cell_grid", Vector2i.ZERO)
			_surface_mesh.size = field.domain_m
			_surface_mesh.subdivide_width = maxi(ceili(field.domain_m.x / value) - 1, 0)
			_surface_mesh.subdivide_depth = maxi(ceili(field.domain_m.y / value) - 1, 0)
		if _surface != null:
			_sync_surface()


func _sync_surface() -> void:
	var region := field.domain_rect()
	water_material.set_shader_parameter("geometry_region_m", Vector4(region.position.x, region.position.y, region.size.x, region.size.y))
	_surface.mesh = _cell_mesh if field.spills else _surface_mesh
	simulation_changed.emit()


# Quads of four unshared vertices, placed by their shader from the vertex index: one per solver cell for the surface,
# so a lip or a wall can split it along a cell edge, and two per cell for the sides where it splits.
static func _build_quad_mesh(count: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	vertices.resize(count * 4)
	var indices := PackedInt32Array()
	indices.resize(count * 6)
	for cell in count:
		var v := cell * 4
		var i := cell * 6
		indices[i] = v
		indices[i + 1] = v + 1
		indices[i + 2] = v + 3
		indices[i + 3] = v
		indices[i + 4] = v + 3
		indices[i + 5] = v + 2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_skirt() -> void:
	var cells := SweSystem.grid_for(field.domain_m, swe_cell_m)
	_skirt_material = ShaderMaterial.new()
	_skirt_material.shader = SkirtShader
	_skirt_material.set_shader_parameter("cell_grid", cells)
	_skirt_material.set_shader_parameter("cell_size_m", swe_cell_m)
	_skirt_material.set_shader_parameter("domain_m", field.domain_m)
	_skirt_material.set_shader_parameter("domain_origin_m", field.origin_m)
	_skirt = MeshInstance3D.new()
	_skirt.name = "RiverSkirt"
	_skirt.mesh = _build_quad_mesh(cells.x * cells.y * 2)
	_skirt.material_override = _skirt_material
	_skirt.layers = _surface.layers
	_skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_skirt.extra_cull_margin = _surface.extra_cull_margin
	_skirt.position = _surface.position
	add_child(_skirt)


func set_waterfall_quality(tier: int) -> void:
	waterfall_quality = clampi(tier, 0, 3)
	if waterfall != null:
		waterfall.set_quality(waterfall_quality)


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
		material.shader = FoamShader
		material.set_shader_parameter("domain_m", field.domain_m)
		material.set_shader_parameter("domain_origin_m", field.origin_m)
		material.set_shader_parameter("turbulence_texture", _turbulence_texture)
		var rect := ColorRect.new()
		rect.size = Vector2(viewport.size)
		rect.material = material
		viewport.add_child(rect)
		_foam_views.append(viewport)
		_foam_materials.append(material)


func _build_reflection() -> void:
	_reflections.field = field
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
	if field.has_water:
		_sync_reflection()
	var step := (fixed_delta_s if fixed_delta_s > 0.0 else delta) if not frozen and field.has_water else 0.0
	swe.tick(step, delta, simulation_time_s)
	if waterfall != null:
		waterfall.tick(simulation_time_s, frozen)
	if not field.has_water or (frozen and _reset_frames == 0):
		return
	simulation_time_s += step
	flow_distance_m += config.speed_m_s * step
	water_material.set_shader_parameter("flow_distance_m", flow_distance_m)
	water_material.set_shader_parameter("simulation_time_s", simulation_time_s)
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
	material.set_shader_parameter("history_shift_uv", _foam_shift_uv)
	_foam_shift_uv = Vector2.ZERO
	_foam_views[_foam_index].render_target_update_mode = SubViewport.UPDATE_ONCE
	water_material.set_shader_parameter("foam_map", _foam_views[_foam_index].get_texture())
	_foam_index = previous
	_reset_frames = maxi(0, _reset_frames - 1)


func reset() -> void:
	cancel_queries()
	simulation_time_s = 0.0
	flow_distance_m = 0.0
	_reset_frames = 2
	swe.reset()
	if waterfall != null:
		waterfall.reset()
	water_material.set_shader_parameter("flow_distance_m", 0.0)
	water_material.set_shader_parameter("simulation_time_s", 0.0)


func submit_queries(points: PackedVector2Array) -> bool:
	if not _started or _query_in_flight or points.is_empty() or points.size() > SweSystem.Solver.MAX_QUERIES:
		return false
	points = points.duplicate()
	_query_in_flight = true
	var values := PackedFloat32Array()
	var weights := PackedFloat32Array()
	var domain := field.domain_rect()
	var needs_gpu := false
	for point in points:
		var height := field.sample_height(point, config.water_level_m)
		var flow := field.sample(point, config.water_level_m)
		var wet := domain.has_point(point) and flow.a > 0.0
		values.append_array(PackedFloat32Array([height,
			flow.r * config.speed_m_s if wet else 0.0, flow.g * config.speed_m_s if wet else 0.0,
			maxf(height - field.sample_bed(point), 0.0) if wet else 0.0]))
		var edge := (point - swe.region_m.position).min(swe.region_m.end - point)
		var weight := smoothstep(1.0, 2.5, minf(edge.x, edge.y)) * swe.blend if swe.live and domain.has_point(point) else 0.0
		weights.append(weight)
		needs_gpu = needs_gpu or weight > 0.0
	if needs_gpu:
		_query_guided = values
		_query_weights = weights
		var parameters := swe.solver.parameters(config, simulation_time_s)
		RenderingServer.call_on_render_thread(swe.solver.query_render.bind(points, parameters, swe.solver.query_serial()))
	else:
		_cpu_query_batch = {"points": points, "values": values}
	return true


func take_query_batch() -> Dictionary:
	if not _started:
		return {}
	var batch := _cpu_query_batch
	if batch.is_empty() and swe.initialized:
		batch = swe.solver.take_query_batch()
		if not batch.is_empty() and not batch.get("body", false):
			var live: PackedFloat32Array = batch.values
			for index in _query_weights.size():
				for channel in 4:
					var offset := index * 4 + channel
					live[offset] = lerpf(_query_guided[offset], live[offset], _query_weights[index])
			batch["values"] = live
	if not batch.is_empty():
		batch["generation"] = query_generation
		_query_in_flight = false
		_cpu_query_batch = {}
		_query_guided = PackedFloat32Array()
		_query_weights = PackedFloat32Array()
	return batch


func submit_body_queries(points: PackedVector3Array) -> bool:
	if not _started or _query_in_flight or points.is_empty() or points.size() > SweSystem.Solver.MAX_QUERIES:
		return false
	_query_in_flight = true
	points = points.duplicate()
	if swe.live and swe.blend > 0.0:
		RenderingServer.call_on_render_thread(swe.solver.query_body_render.bind(points, swe.solver.parameters(config, simulation_time_s), swe.solver.query_serial()))
	else:
		var values := PackedFloat32Array()
		for point in points:
			var contact: Array[Vector4] = []
			var p := Vector2(point.x, point.z)
			if field.water_zone(p) != 0:
				var height := field.sample_height(p, config.water_level_m)
				var flow := field.sample(p, config.water_level_m)
				var wet := field.domain_rect().has_point(p) and flow.a > 0.0 \
					and point.y < height + 0.8 and point.y > field.sample_bed(p) - 0.8
				contact.assign([Vector4(point.x, height, point.z, maxf(height - field.sample_bed(p), 0.0) if wet else 0.0),
					Vector4(flow.r * config.speed_m_s, 0.0, flow.g * config.speed_m_s, 1.0 if wet else 0.0), Vector4(0.0, 1.0, 0.0, point.y - height)])
			if contact.is_empty():
				contact.assign([Vector4.ZERO, Vector4.ZERO, Vector4(0.0, 1.0, 0.0, 0.0)])
			for value in contact:
				values.append_array(PackedFloat32Array([value.x, value.y, value.z, value.w]))
		_cpu_query_batch = {"points": points, "values": values, "body": true}
	return true


func cancel_queries() -> void:
	query_generation += 1
	_query_in_flight = false
	_cpu_query_batch = {}
	_query_guided.clear()
	_query_weights.clear()
	if swe != null:
		swe.solver.cancel_queries()


func stop() -> void:
	if not _started:
		return
	_started = false
	cancel_queries()
	_query_in_flight = false
	_cpu_query_batch = {}
	_query_guided = PackedFloat32Array()
	_query_weights = PackedFloat32Array()
	set_process(false)
	_reflections.stop()
	if waterfall != null:
		waterfall.stop()
	swe.stop()
	water_material.set_shader_parameter("foam_map", null)
	for material in _foam_materials:
		material.set_shader_parameter("previous_foam", null)
	for child in get_children():
		child.free()
	swe = null
	waterfall = null
	_foam_views.clear()
	_foam_materials.clear()
	_field_texture = null
	_turbulence_texture = null
	field.bed_texture = null
	water_material = null
	reflection_viewport = null
	reflection_camera = null
	_surface_mesh = null
	_cell_mesh = null
	_surface = null
	_skirt = null
	_skirt_material = null


func _exit_tree() -> void:
	stop()
