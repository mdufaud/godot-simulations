class_name OceanFoamWindow
extends Node

const MAP_SIZE := 512
const WORLD_SIZE := 128.0
const CAPTURE_LAYER := 1 << 19
const CAPTURE_LAYER_INDEX := 20

var _surface_material: ShaderMaterial
var _main_camera: Camera3D
var _capture_viewport: SubViewport
var _capture_camera: Camera3D
var _feedback_viewports: Array[SubViewport] = []
var _feedback_materials: Array[ShaderMaterial] = []
var _proxy_root: Node3D
var _proxy_material: ShaderMaterial
var _dynamic_proxies: Dictionary = {}
var _black_texture: ImageTexture
var _center := Vector2.ZERO
var _history_center := Vector2.ZERO
var _history_ready := false
var _frame := 0
var _enabled := false
var _ocean_bound := false
var _profiling := false


func build(surface_material: ShaderMaterial, main_camera: Camera3D, static_root: Node) -> void:
	_surface_material = surface_material
	_main_camera = main_camera
	_main_camera.set_cull_mask_value(CAPTURE_LAYER_INDEX, false)
	_black_texture = _make_black_texture()
	_proxy_material = ShaderMaterial.new()
	_proxy_material.shader = load("res://shaders/ocean/ocean_intersection_capture.gdshader")
	_proxy_root = Node3D.new()
	add_child(_proxy_root)
	_clone_static_meshes(static_root)
	_build_capture()
	_build_feedback()
	_surface_material.set_shader_parameter("interaction_foam", _black_texture)
	_surface_material.set_shader_parameter("interaction_size", WORLD_SIZE)
	set_enabled(false)


func set_enabled(on: bool) -> void:
	_enabled = on
	_history_ready = false
	_frame = 0
	_refresh_capture_state()
	for viewport in _feedback_viewports:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not on and _surface_material != null:
		_surface_material.set_shader_parameter("interaction_foam", _black_texture)


func bind_ocean(displacements: Texture2DArrayRD, tile_lengths: PackedFloat32Array) -> void:
	var scales := PackedVector4Array()
	for tile in tile_lengths:
		var inverse := 1.0 / tile
		scales.append(Vector4(inverse, inverse, 1.0, 1.0))
	_proxy_material.set_shader_parameter("map_scales", scales)
	_proxy_material.set_shader_parameter("displacements", displacements)
	_ocean_bound = true
	_refresh_capture_state()


func release_ocean() -> void:
	_ocean_bound = false
	_refresh_capture_state()


func set_profiling(on: bool) -> void:
	_profiling = on
	if _capture_viewport != null:
		RenderingServer.viewport_set_measure_render_time(_capture_viewport.get_viewport_rid(), on)
	for viewport in _feedback_viewports:
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), on)


func get_gpu_time() -> float:
	return get_capture_gpu_time() + get_feedback_gpu_time()


func get_capture_gpu_time() -> float:
	if not _profiling or _capture_viewport == null:
		return 0.0
	return RenderingServer.viewport_get_measured_render_time_gpu(
		_capture_viewport.get_viewport_rid())


func get_feedback_gpu_time() -> float:
	if not _profiling:
		return 0.0
	var total := 0.0
	for viewport in _feedback_viewports:
		total += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	return total


func track_body(body: Node3D) -> void:
	if _dynamic_proxies.has(body):
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.25, 1.25, 1.25)
	var proxy := _make_proxy(mesh)
	_dynamic_proxies[body] = proxy


func update(delta: float, world_position: Vector3) -> void:
	if not _enabled or not _ocean_bound:
		return
	_update_dynamic_proxies()
	var texel_world := WORLD_SIZE / MAP_SIZE
	_center = Vector2(
		snappedf(world_position.x, texel_world),
		snappedf(world_position.z, texel_world)
	)
	_capture_camera.global_position = Vector3(_center.x, 12.0, _center.y)
	_capture_camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)

	var current := _frame & 1
	var previous := 1 - current
	var material := _feedback_materials[current]
	material.set_shader_parameter("previous_foam",
		_feedback_viewports[previous].get_texture() if _history_ready else _black_texture)
	material.set_shader_parameter("scroll_uv",
		(_center - _history_center) / WORLD_SIZE if _history_ready else Vector2.ZERO)
	material.set_shader_parameter("decay", exp(-delta * 0.45))
	material.set_shader_parameter("blur_amount", minf(delta * 3.0, 0.3))
	material.set_shader_parameter("injection_strength", minf(delta * 8.0, 1.0))
	_feedback_viewports[current].render_target_update_mode = SubViewport.UPDATE_ONCE
	_surface_material.set_shader_parameter("interaction_foam",
		_feedback_viewports[current].get_texture())
	_surface_material.set_shader_parameter("interaction_center", _center)
	_history_center = _center
	_history_ready = true
	_frame += 1


func _build_capture() -> void:
	_capture_viewport = SubViewport.new()
	_capture_viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
	_capture_viewport.transparent_bg = true
	_capture_viewport.own_world_3d = false
	_capture_viewport.positional_shadow_atlas_size = 0
	_capture_viewport.msaa_3d = Viewport.MSAA_2X
	_capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_capture_viewport)

	_capture_camera = Camera3D.new()
	_capture_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_capture_camera.size = WORLD_SIZE
	_capture_camera.near = 0.05
	_capture_camera.far = 30.0
	_capture_camera.cull_mask = CAPTURE_LAYER
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	_capture_camera.environment = environment
	_capture_viewport.add_child(_capture_camera)
	_capture_camera.current = true


func _build_feedback() -> void:
	for i in 2:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
		viewport.disable_3d = true
		viewport.use_hdr_2d = true
		viewport.transparent_bg = true
		viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var rect := ColorRect.new()
		rect.position = Vector2.ZERO
		rect.size = Vector2(MAP_SIZE, MAP_SIZE)
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/ocean/ocean_foam_feedback.gdshader")
		material.set_shader_parameter("previous_foam", _black_texture)
		material.set_shader_parameter("injection_mask", _capture_viewport.get_texture())
		material.set_shader_parameter("texel_size", Vector2.ONE / MAP_SIZE)
		rect.material = material
		viewport.add_child(rect)
		add_child(viewport)
		_feedback_viewports.append(viewport)
		_feedback_materials.append(material)


func _clone_static_meshes(root: Node) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var source := child as MeshInstance3D
		if source.mesh == null:
			continue
		var proxy := _make_proxy(source.mesh)
		proxy.global_transform = source.global_transform


func _make_proxy(mesh: Mesh) -> MeshInstance3D:
	var proxy := MeshInstance3D.new()
	proxy.mesh = mesh
	proxy.material_override = _proxy_material
	proxy.layers = CAPTURE_LAYER
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_proxy_root.add_child(proxy)
	return proxy


func _update_dynamic_proxies() -> void:
	var stale: Array[Node3D] = []
	for body: Node3D in _dynamic_proxies:
		var proxy: MeshInstance3D = _dynamic_proxies[body]
		if not is_instance_valid(body):
			proxy.queue_free()
			stale.append(body)
		else:
			proxy.global_transform = body.global_transform
	for body in stale:
		_dynamic_proxies.erase(body)


func _make_black_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(image)


func _refresh_capture_state() -> void:
	if _capture_viewport != null:
		_capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS \
			if _enabled and _ocean_bound else SubViewport.UPDATE_DISABLED
