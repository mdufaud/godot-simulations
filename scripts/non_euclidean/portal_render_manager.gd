class_name PortalRenderManager
extends Node

const MAX_VIEWS := 2
const MIN_NEAR := 0.001
const NEAR_MARGIN := 0.02

var player_camera: Camera3D
var active_view_count := 0
var debug_enabled := false

var _slots: Array[Dictionary] = []
var _portal_environment: Environment


func _ready() -> void:
	process_priority = 1000
	_create_pool()
	get_viewport().size_changed.connect(_resize_pool)


func _process(_delta: float) -> void:
	if player_camera == null or not is_instance_valid(player_camera):
		_disable_all()
		return
	active_view_count = 0
	for slot in _slots:
		var viewport := slot["viewport"] as SubViewport
		var camera := slot["camera"] as Camera3D
		var portal := slot["portal"] as Portal3D
		if portal == null or not is_instance_valid(portal) or not portal.is_visible_from(player_camera):
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			continue
		_configure_camera(camera, portal)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		active_view_count += 1


func set_camera(camera: Camera3D) -> void:
	player_camera = camera


func configure_portals(portals: Array[Portal3D]) -> void:
	assert(portals.size() <= _slots.size())
	for index in _slots.size():
		var portal: Portal3D = portals[index] if index < portals.size() else null
		_slots[index]["portal"] = portal
		if portal != null:
			portal.set_render_texture((_slots[index]["viewport"] as SubViewport).get_texture())


func set_debug_enabled(enabled: bool) -> void:
	debug_enabled = enabled
	for portal in get_tree().get_nodes_in_group("portals"):
		(portal as Portal3D).set_debug_enabled(enabled)


func get_debug_text() -> String:
	var near_values: Array[String] = []
	for slot in _slots:
		if slot["portal"] != null:
			near_values.append("%.3f m" % (slot["camera"] as Camera3D).near)
	return "Portal views: %d/2 · dedicated native HDR targets · near: %s" % [
		active_view_count,
		", ".join(near_values),
	]


func _create_pool() -> void:
	var main_viewport := get_viewport()
	var main_environment := main_viewport.world_3d.environment
	if main_environment != null:
		_portal_environment = main_environment.duplicate(true) as Environment
		_portal_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_portal_environment.tonemap_exposure = 1.0
		_portal_environment.glow_enabled = false
		_portal_environment.adjustment_enabled = false
	for index in MAX_VIEWS:
		var viewport := SubViewport.new()
		viewport.name = "PortalViewport%d" % index
		viewport.own_world_3d = false
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		viewport.audio_listener_enable_3d = false
		viewport.use_hdr_2d = true
		viewport.msaa_3d = main_viewport.msaa_3d
		viewport.screen_space_aa = main_viewport.screen_space_aa
		viewport.use_taa = main_viewport.use_taa
		viewport.use_debanding = main_viewport.use_debanding
		viewport.mesh_lod_threshold = main_viewport.mesh_lod_threshold
		viewport.anisotropic_filtering_level = main_viewport.anisotropic_filtering_level
		viewport.positional_shadow_atlas_size = main_viewport.positional_shadow_atlas_size
		add_child(viewport)
		var camera := Camera3D.new()
		camera.name = "PortalCamera"
		camera.near = MIN_NEAR
		camera.far = 100.0
		camera.environment = _portal_environment
		camera.cull_mask = Portal3D.WORLD_LAYER | Portal3D.PROXY_LAYER
		viewport.add_child(camera)
		camera.current = true
		_slots.append({"viewport": viewport, "camera": camera, "portal": null})
	_resize_pool()


func _resize_pool() -> void:
	var size := Vector2i(get_viewport().get_visible_rect().size)
	for slot in _slots:
		(slot["viewport"] as SubViewport).size = size


func _configure_camera(camera: Camera3D, portal: Portal3D) -> void:
	var pose := PortalMath.map_transform(portal.get_mapping(), player_camera.global_transform)
	camera.global_transform = pose
	camera.projection = player_camera.projection
	camera.fov = player_camera.fov
	camera.keep_aspect = player_camera.keep_aspect
	camera.h_offset = player_camera.h_offset
	camera.v_offset = player_camera.v_offset
	camera.near = _safe_near(portal, pose)
	camera.far = player_camera.far
	camera.environment = _portal_environment


func _safe_near(portal: Portal3D, camera_pose: Transform3D) -> float:
	var forward := -camera_pose.basis.z.normalized()
	var closest := INF
	for corner in portal.get_aperture_corners():
		var mapped_corner := portal.map_position(corner)
		closest = minf(closest, (mapped_corner - camera_pose.origin).dot(forward))
	return maxf(MIN_NEAR, closest - NEAR_MARGIN)


func _disable_all() -> void:
	active_view_count = 0
	for slot in _slots:
		(slot["viewport"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED


func _exit_tree() -> void:
	for slot in _slots:
		var portal := slot["portal"] as Portal3D
		if portal != null and is_instance_valid(portal):
			portal.set_render_texture(null)
		(slot["viewport"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	_slots.clear()
	_portal_environment = null
