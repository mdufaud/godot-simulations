extends RefCounted

var views: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var scale := 0.5
var plane_count := 1
var enabled := true
var include_grass := false
var reflection_layer := 0

var _owner: Node3D
var _source_camera: Camera3D
var _world: World3D
var _material: ShaderMaterial
var _profiling := false


func build(owner: Node3D, source_camera: Camera3D, world: World3D, material: ShaderMaterial) -> void:
	stop()
	_owner = owner
	_source_camera = source_camera
	_world = world
	_material = material
	set_plane_count(plane_count)
	_sync_environment()


func set_plane_count(value: int) -> void:
	var count := 4 if value >= 4 else 1
	if count == plane_count and views.size() == count:
		return
	_clear_bindings()
	for view in views:
		if is_instance_valid(view):
			view.free()
	views.clear()
	cameras.clear()
	plane_count = count
	if _owner == null:
		return
	for index in plane_count:
		var view := SubViewport.new()
		view.name = "RiverReflection%d" % index
		view.world_3d = _world
		view.use_hdr_2d = true
		view.msaa_3d = Viewport.MSAA_4X if plane_count == 4 else Viewport.MSAA_DISABLED
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
		_owner.add_child(view)
		RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), _profiling)
		var camera := Camera3D.new()
		camera.current = true
		view.add_child(camera)
		views.append(view)
		cameras.append(camera)
	_sync_environment()
	_set_material_parameters()


func set_active(value: bool) -> void:
	enabled = value
	for view in views:
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED


func sync(render_size: Vector2i, level_m: float, anchor_z_m: float) -> void:
	if views.is_empty() or _source_camera == null:
		return
	var anchors := _anchors()
	for index in views.size():
		var anchor := anchor_z_m if plane_count == 1 else anchors[index]
		var plane := RiverField.water_plane(level_m, anchor)
		var origin := _source_camera.global_position - 2.0 * plane.distance_to(_source_camera.global_position) * plane.normal
		var forward := -_source_camera.global_basis.z
		var up := _source_camera.global_basis.y
		forward -= 2.0 * forward.dot(plane.normal) * plane.normal
		up -= 2.0 * up.dot(plane.normal) * plane.normal
		var camera := cameras[index]
		camera.global_transform = Transform3D(Basis.looking_at(forward, up), origin)
		camera.fov = _source_camera.fov
		camera.keep_aspect = _source_camera.keep_aspect
		camera.near = _source_camera.near
		camera.far = _source_camera.far
		camera.cull_mask = 1 | reflection_layer | (4 if include_grass else 0)
		var size := Vector2i((Vector2(render_size) * scale).max(Vector2(16.0, 16.0)))
		if views[index].size != size:
			views[index].size = size
		_set_slot(index, "reflection_view", camera.global_transform.affine_inverse())
		_set_slot(index, "reflection_projection", camera.get_camera_projection())
		_set_slot(index, "reflection_texture", views[index].get_texture())
	_sync_environment()
	_set_material_parameters()


func set_profiling(value: bool) -> void:
	_profiling = value
	for view in views:
		RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), value)


func gpu_ms() -> float:
	if not enabled or not _profiling:
		return 0.0
	var total := 0.0
	for view in views:
		total += RenderingServer.viewport_get_measured_render_time_gpu(view.get_viewport_rid())
	return total


func stop() -> void:
	_clear_bindings()
	for view in views:
		if is_instance_valid(view):
			view.free()
	views.clear()
	cameras.clear()
	_owner = null
	_source_camera = null
	_world = null
	_material = null


func _anchors() -> Vector4:
	var centers := RiverField.DROP_CENTERS_M
	var half_width := RiverField.DROP_HALF_WIDTH_M
	return Vector4(
		centers.z - half_width,
		(centers.z + centers.y) * 0.5,
		(centers.y + centers.x) * 0.5,
		centers.x + half_width
	)


func _sync_environment() -> void:
	if _world == null:
		return
	for camera in cameras:
		if _world.environment == null:
			camera.environment = null
			continue
		var environment := camera.environment
		if environment == null:
			environment = _world.environment.duplicate() as Environment
			camera.environment = environment
		environment.background_mode = _world.environment.background_mode
		environment.sky = _world.environment.sky
		environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		environment.tonemap_exposure = 1.0
		environment.glow_enabled = false
		environment.ssao_enabled = plane_count == 4


func _set_material_parameters() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("reflection_planes", plane_count)
	var heights := RiverField.DROP_HEIGHTS_M
	_material.set_shader_parameter("terrace_heights_m", Vector4(0.0, heights.z, heights.z + heights.y,
		heights.z + heights.y + heights.x))
	_material.set_shader_parameter("surface_slope", RiverField.SLOPE)


func _set_slot(index: int, base_name: String, value: Variant) -> void:
	if _material == null:
		return
	_material.set_shader_parameter(base_name if index == 0 else "%s_%d" % [base_name, index], value)


func _clear_bindings() -> void:
	if _material == null:
		return
	for index in views.size():
		_set_slot(index, "reflection_texture", null)
		_set_slot(index, "reflection_view", Transform3D.IDENTITY)
		_set_slot(index, "reflection_projection", Projection.IDENTITY)
