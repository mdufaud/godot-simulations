class_name PortalRenderManager
extends Node

## Upper bound of the SubViewport pool; the quality tier picks 1-4 of these.
const MAX_POOL := 4
const MIN_NEAR := 0.001
const NEAR_MARGIN := 0.02

var player_camera: Camera3D
var active_view_count := 0
var debug_enabled := false
## Live portal views; viewports are full-window renders, so capping the pool
## is the cheapest lever on a weak GPU. Portals past the cap keep their last
## image instead of re-rendering.
var max_views := 2
## Resolution factor of each portal target relative to the window; the image
## is stretched back over the portal quad, so low values cost sharpness only.
var portal_view_scale := 1.0

var _slots: Array[Dictionary] = []
var _portals: Array[Portal3D] = []
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
	_portals = portals.duplicate()
	_assign_portal_slots()


## Rebuilds the SubViewport pool at the new size and re-binds the portals.
func set_max_views(count: int) -> void:
	count = clampi(count, 1, MAX_POOL)
	if count == max_views and not _slots.is_empty():
		return
	max_views = count
	_teardown_pool()
	_create_pool()
	_assign_portal_slots()


func set_portal_view_scale(scale: float) -> void:
	portal_view_scale = clampf(scale, 0.25, 1.0)
	_resize_pool()


func set_debug_enabled(enabled: bool) -> void:
	debug_enabled = enabled
	for portal in get_tree().get_nodes_in_group("portals"):
		(portal as Portal3D).set_debug_enabled(enabled)


func get_debug_text() -> String:
	var near_values: Array[String] = []
	for slot in _slots:
		if slot["portal"] != null:
			near_values.append("%.3f m" % (slot["camera"] as Camera3D).near)
	return "Portal views: %d/%d · %.0f%% scale · near: %s" % [
		active_view_count,
		max_views,
		portal_view_scale * 100.0,
		", ".join(near_values),
	]


## Binds each portal to its pool slot; portals without a slot (views capped)
## fall back to their static image.
func _assign_portal_slots() -> void:
	for index in _portals.size():
		var portal := _portals[index]
		if index < _slots.size():
			_slots[index]["portal"] = portal
			portal.set_render_texture((_slots[index]["viewport"] as SubViewport).get_texture())
		else:
			portal.set_render_texture(null)


func _create_pool() -> void:
	var main_viewport := get_viewport()
	var main_environment := main_viewport.world_3d.environment
	if main_environment != null:
		_portal_environment = main_environment.duplicate(true) as Environment
		_portal_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_portal_environment.tonemap_exposure = 1.0
		_portal_environment.glow_enabled = false
		_portal_environment.adjustment_enabled = false
	for index in max_views:
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
	var size := Vector2(get_viewport().get_visible_rect().size) * portal_view_scale
	for slot in _slots:
		(slot["viewport"] as SubViewport).size = Vector2i(size)


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


func _teardown_pool() -> void:
	for slot in _slots:
		var viewport := slot["viewport"] as SubViewport
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		viewport.free()
	_slots.clear()


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
