class_name PortalRenderManager
extends Node

## Upper bound of the SubViewport pool; the quality tier picks 1-4 of these.
const MAX_POOL := 4
## Doors seen through a slot's door, each through the one before, that still
## get a live view; a door one further shows its placeholder.
const NESTED_DEPTH := 3
const MIN_NEAR := 0.001
const NEAR_MARGIN := 0.02
## Screen-space slack around a projected aperture, for the quad overscan.
const CLIP_MARGIN := 0.01
## Resolution of a nested view relative to its slot's: a door seen through a
## door covers a fraction of the screen, so it keeps its sharpness cheaply.
const NESTED_SCALE := 0.5
## Portal screens are in: a door seen through a door shows its own view or
## placeholder, never the void behind its wall. The destination's own screen
## faces away from its camera and discards itself.
const VIEW_LAYERS := Portal3D.WORLD_LAYER | Portal3D.MAIN_PORTAL_LAYER \
	| Portal3D.PROXY_LAYER | Portal3D.BEHIND_LAYER

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

## One view per slot ([code]viewport[/code], [code]camera[/code],
## [code]portal[/code]); its [code]chain[/code] holds the nested views, each a
## child of the one before.
var _slots: Array[Dictionary] = []
var _portals: Array[Portal3D] = []
var _nested: Dictionary = {}
var _portal_environment: Environment


func _ready() -> void:
	process_priority = 1000
	_create_pool()
	get_viewport().size_changed.connect(_resize_pool)


## A nested view renders only while its door shows inside the aperture it is
## seen through, so the deep levels cost nothing until they are on screen.
func _process(_delta: float) -> void:
	if player_camera == null or not is_instance_valid(player_camera):
		_disable_all()
		return
	active_view_count = 0
	for slot in _slots:
		var eye := player_camera
		var clip := Rect2(Vector2.ZERO, Vector2.ONE)
		var open := true
		for view in _views(slot):
			var viewport := view["viewport"] as SubViewport
			var portal := view["portal"] as Portal3D
			if open:
				open = portal != null and is_instance_valid(portal) and portal.is_visible_from(eye)
			if open:
				clip = clip.intersection(_screen_rect(eye, portal))
				open = clip.has_area()
			if not open:
				viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
				continue
			var camera := view["camera"] as Camera3D
			_configure_camera(camera, portal, eye.global_transform)
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			active_view_count += 1
			eye = camera


func set_camera(camera: Camera3D) -> void:
	player_camera = camera


## [param nested] maps a portal to the door seen through it; the chain is
## followed [constant NESTED_DEPTH] doors deep, each getting its own view from
## the camera of the door before instead of rendering as a hole.
func configure_portals(portals: Array[Portal3D], nested: Dictionary = {}) -> void:
	_portals = portals.duplicate()
	_nested = nested.duplicate()
	_assign_portal_slots()


## Rebuilds the SubViewport pool at the new size and re-binds the portals.
func set_max_views(count: int) -> void:
	count = clampi(count, 1, MAX_POOL)
	if count == max_views and not _slots.is_empty():
		return
	_preserve_capped_portals(count)
	max_views = count
	_teardown_pool()
	_create_pool()
	_assign_portal_slots()


## Portals losing their slot keep the last image they rendered: the pool
## teardown frees the viewport their texture points into, so snapshot it first.
func _preserve_capped_portals(keep: int) -> void:
	for index in range(keep, _portals.size()):
		if index >= _slots.size():
			continue
		for view in _views(_slots[index]):
			var portal := view["portal"] as Portal3D
			if portal == null or not is_instance_valid(portal):
				continue
			var image := (view["viewport"] as SubViewport).get_texture().get_image()
			if image != null and not image.is_empty():
				portal.set_render_texture(ImageTexture.create_from_image(image))


func set_portal_view_scale(scale: float) -> void:
	var clamped := clampf(scale, 0.25, 1.0)
	if is_equal_approx(clamped, portal_view_scale):
		return
	portal_view_scale = clamped
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
	return "Portal views: %d/%d (+nested) · %.0f%% scale · near: %s" % [
		active_view_count,
		max_views,
		portal_view_scale * 100.0,
		", ".join(near_values),
	]


## Binds each portal and the chain behind it to its pool slot; portals without
## a slot (views capped) keep the last image they rendered (see
## _preserve_capped_portals).
func _assign_portal_slots() -> void:
	for index in _slots.size():
		var portal: Portal3D = _portals[index] if index < _portals.size() else null
		for view in _views(_slots[index]):
			view["portal"] = portal
			if portal != null:
				portal.set_render_texture((view["viewport"] as SubViewport).get_texture())
				portal = _nested.get(portal)


func _views(slot: Dictionary) -> Array[Dictionary]:
	var views: Array[Dictionary] = [slot]
	views.append_array(slot["chain"])
	return views


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
		var slot := _create_view(self, "PortalViewport%d" % index)
		var chain: Array[Dictionary] = []
		var parent: Node = slot["viewport"]
		for level in NESTED_DEPTH:
			# A SubViewport renders before its parent, so the door seen through
			# a view is ready when that view samples it.
			var view := _create_view(parent, "NestedViewport%d" % (level + 1))
			chain.append(view)
			parent = view["viewport"]
		slot["chain"] = chain
		_slots.append(slot)
	_resize_pool()


func _create_view(parent: Node, view_name: String) -> Dictionary:
	var main_viewport := get_viewport()
	var viewport := SubViewport.new()
	viewport.name = view_name
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
	parent.add_child(viewport)
	var camera := Camera3D.new()
	camera.name = "PortalCamera"
	camera.near = MIN_NEAR
	camera.far = 100.0
	camera.environment = _portal_environment
	viewport.add_child(camera)
	camera.current = true
	return {"viewport": viewport, "camera": camera, "portal": null}


func _resize_pool() -> void:
	var size := Vector2(get_viewport().get_visible_rect().size) * portal_view_scale
	for slot in _slots:
		(slot["viewport"] as SubViewport).size = Vector2i(size)
		for view in slot["chain"]:
			(view["viewport"] as SubViewport).size = Vector2i(size * NESTED_SCALE)


## [param eye] is the pose looking at [param portal]: the player camera, or the
## view of the portal this one is seen through.
func _configure_camera(camera: Camera3D, portal: Portal3D, eye: Transform3D) -> void:
	var pose := PortalMath.map_transform(portal.get_mapping(), eye)
	camera.global_transform = pose
	camera.projection = player_camera.projection
	camera.fov = player_camera.fov
	camera.keep_aspect = player_camera.keep_aspect
	camera.h_offset = player_camera.h_offset
	camera.v_offset = player_camera.v_offset
	camera.near = _safe_near(portal, pose)
	camera.far = player_camera.far
	camera.environment = _portal_environment
	camera.cull_mask = VIEW_LAYERS & ~portal.linked_portal.exit_hidden_layers


## Aperture bounds on screen in UV, the space every view shares. An aperture
## wholly behind the eye is off screen (empty rect: the view is not rendered,
## e.g. the door just walked through); one straddling the eye plane may cover
## any of it, so it keeps the whole screen.
func _screen_rect(eye: Camera3D, portal: Portal3D) -> Rect2:
	var size := eye.get_viewport().get_visible_rect().size
	var points := PackedVector2Array()
	var corners := portal.get_aperture_corners()
	var behind := 0
	for corner in corners:
		if eye.is_position_behind(corner):
			behind += 1
	if behind == corners.size():
		return Rect2()
	if behind > 0:
		return Rect2(Vector2.ZERO, Vector2.ONE)
	for corner in corners:
		points.append(eye.unproject_position(corner) / size)
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return bounds.grow(CLIP_MARGIN)


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
		for view in _views(slot):
			(view["viewport"] as SubViewport).render_target_update_mode = \
				SubViewport.UPDATE_DISABLED


func _exit_tree() -> void:
	for slot in _slots:
		for view in _views(slot):
			var portal := view["portal"] as Portal3D
			if portal != null and is_instance_valid(portal):
				portal.set_render_texture(null)
		(slot["viewport"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
	_slots.clear()
	_portal_environment = null
