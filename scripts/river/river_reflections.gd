extends RefCounted

var views: Array[SubViewport] = []
var cameras: Array[Camera3D] = []
var scale := 0.5
var plane_count := 1
var enabled := true
var include_grass := false
var reflection_layer := 0
var field: RiverField

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
	var count := 4 if value >= 4 else (2 if value == 2 else 1)
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
	var anchors := field.reflection_anchors_m
	for index in views.size():
		var anchor := anchor_z_m if plane_count == 1 and field.waterfall == null else anchors[index]
		var plane := field.reflection_plane(level_m, anchor)
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
		camera.cull_mask = 1 | (reflection_layer << index if field.waterfall != null else reflection_layer) | (4 if include_grass else 0)
		var rect := _crop_rect(index, render_size, level_m) if plane_count > 1 else Rect2(Vector2.ZERO, Vector2(render_size))
		views[index].render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled and rect.has_area() else SubViewport.UPDATE_DISABLED
		if not rect.has_area():
			continue
		var size := Vector2i((rect.size * scale).max(Vector2(16.0, 16.0)))
		if views[index].size != size:
			views[index].size = size
		if plane_count > 1:
			var half_height := tan(deg_to_rad(_source_camera.fov) * 0.5) * camera.near
			if _source_camera.keep_aspect == Camera3D.KEEP_WIDTH:
				half_height *= float(render_size.y) / render_size.x
			var half_width := half_height * float(render_size.x) / render_size.y
			var uv := (rect.get_center() / Vector2(render_size) - Vector2(0.5, 0.5)) * 2.0
			camera.keep_aspect = Camera3D.KEEP_HEIGHT
			camera.set_frustum(2.0 * half_height * rect.size.y / render_size.y,
				Vector2(-uv.x * half_width, -uv.y * half_height), camera.near, camera.far)
		else:
			camera.projection = _source_camera.projection
		_set_slot(index, "reflection_view", camera.global_transform.affine_inverse())
		_set_slot(index, "reflection_projection", camera.get_camera_projection())
		_set_slot(index, "reflection_texture", views[index].get_texture())


func set_profiling(value: bool) -> void:
	_profiling = value
	for view in views:
		RenderingServer.viewport_set_measure_render_time(view.get_viewport_rid(), value)


func gpu_ms() -> float:
	if not enabled or not _profiling:
		return 0.0
	var total := 0.0
	for view in views:
		if view.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			total += RenderingServer.viewport_get_measured_render_time_gpu(view.get_viewport_rid())
	return total


func _crop_rect(index: int, size: Vector2i, level_m: float) -> Rect2:
	var rect := Rect2()
	var first := true
	for point in field.surface_points:
		if field.waterfall != null:
			if field.water_zone(Vector2(point.x, point.z)) != index + 1:
				continue
		else:
			var terrace := point.y - point.z * field.surface_slope
			var low := field.terrace_heights_m[maxi(index - 1, 0)]
			var high := field.terrace_heights_m[mini(index + 1, 3)]
			if terrace < low - 0.01 or terrace > high + 0.01:
				continue
		point.y += level_m
		if _source_camera.is_position_behind(point):
			continue
		for offset: Vector3 in [Vector3(-2.0, -0.8, 0.0), Vector3(2.0, 0.8, 0.0)]:
			var pixel := _source_camera.unproject_position(point + offset)
			rect = Rect2(pixel, Vector2.ZERO) if first else rect.expand(pixel)
			first = false
	return rect.grow(96.0).intersection(Rect2(Vector2.ZERO, Vector2(size))) if not first else Rect2()


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
	_material.set_shader_parameter("terrace_heights_m", field.terrace_heights_m)
	_material.set_shader_parameter("surface_slope", field.surface_slope)


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
