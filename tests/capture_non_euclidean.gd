extends SceneTree
## Portal image inspection tool, not part of the pass/fail suite: it walks the demo
## through a series of poses, writes every frame to tmp/non_euclidean_*.png for
## eyeballing, and compares each portal view against the reference view the player
## would see standing on the other side. Run it by hand after touching portal
## rendering:
##
##   godot -s res://tests/capture_non_euclidean.gd
##
## Tolerances are tight (mean 0.003) and every capture is a full frame, so a mismatch
## means "go look at the PNGs" first. It only holds while the window matches the
## 1280x720 canvas base, which _run() forces.

var demo: Node3D
var player: NonEuclideanPlayer
var manager: PortalRenderManager


func _initialize() -> void:
	root.size = Vector2i(1280, 720)
	demo = load("res://scenes/non_euclidean_demo.tscn").instantiate()
	root.add_child(demo)
	call_deferred("_run")


func _run() -> void:
	# UserSettings restores the persisted window size after _initialize ran, which would
	# leave captures window-sized while rays are cast in the 1280x720 canvas base.
	root.size = Vector2i(1280, 720)
	await process_frame
	player = demo.get_node("Player") as NonEuclideanPlayer
	manager = demo.get_node("PortalRenderManager") as PortalRenderManager
	var source := demo.get_node("Cells/ReserveCourtyard/ReserveExpansion") as Portal3D
	(demo.get_node("UI") as CanvasLayer).visible = false
	player.release_mouse()
	player.set_physics_process(false)
	for prop in demo._reserve_props:
		(prop as PortalRigidBody3D).visible = false
	for _frame in 90:
		await process_frame
	if not await _test_first_look_activation(source):
		quit(1)
		return
	var poses := [
		{"name": "far", "position": Vector3(0.0, -0.8, 10.0)},
		{"name": "medium", "position": Vector3(0.0, -0.8, 4.0)},
		{"name": "left_angle", "position": Vector3(-2.5, -0.8, 2.0)},
		{"name": "right_angle", "position": Vector3(2.5, -0.8, 2.0)},
		{"name": "left_grazing", "position": Vector3(-2.0, -0.8, 0.45)},
		{"name": "right_grazing", "position": Vector3(2.0, -0.8, 0.45)},
		{"name": "near_angle", "position": Vector3(1.15, -0.8, 0.04)},
		{"name": "near", "position": Vector3(0.0, -0.8, 0.004)},
	]
	for pose in poses:
		if not await _test_portal_pose(source, String(pose["name"]), pose["position"]):
			quit(1)
			return
	if not await _test_crossing_continuity(source):
		quit(1)
		return
	await _capture_reserve_threshold(source.linked_portal)
	if not await _test_stair_wrap_continuity():
		quit(1)
		return
	await _capture_spherical_garden()
	print("CAPTURE_NON_EUCLIDEAN_DONE")
	quit(0)


func _test_first_look_activation(source: Portal3D) -> bool:
	player.set_pose(Transform3D(Basis(Vector3.UP, PI),
		source.to_global(Vector3(0.0, -0.8, 10.0))))
	for _frame in 3:
		await process_frame
	var viewport := manager._slots[0]["viewport"] as SubViewport
	if viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		push_error("PORTAL_OFFSCREEN_TARGET_ACTIVE")
		return false
	player.set_pose(_aimed_pose(source, Vector3(0.0, -0.8, 10.0)))
	await process_frame
	var image := await _capture("res://tmp/non_euclidean_first_look.png")
	if viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		push_error("PORTAL_FIRST_LOOK_NOT_ACTIVE")
		return false
	var center := Vector2i(root.get_final_transform() \
		* player.get_camera().unproject_position(source.global_position))
	var luminance := _mean_luminance(image, Rect2i(center - Vector2i(12, 12), Vector2i(24, 24)))
	print("PORTAL_FIRST_LOOK_LUMINANCE=", luminance)
	if luminance <= 0.08:
		push_error("PORTAL_FIRST_LOOK_BLACK")
		return false
	return true


func _test_portal_pose(source: Portal3D, test_name: String,
		local_position: Vector3) -> bool:
	var main_camera := player.get_camera()
	main_camera.near = 0.01
	main_camera.cull_mask = Portal3D.WORLD_LAYER | Portal3D.MAIN_PORTAL_LAYER \
		| Portal3D.PROXY_LAYER
	player.set_pose(_aimed_pose(source, local_position))
	for _frame in 5:
		await process_frame
	var portal_samples := _portal_samples(source, main_camera, 0.92)
	if portal_samples.is_empty():
		push_error("PORTAL_HAS_NO_VISIBLE_PIXELS_%s" % test_name.to_upper())
		return false
	var source_slot := manager._slots[0]
	var portal_camera := source_slot["camera"] as Camera3D
	if (source_slot["viewport"] as SubViewport).render_target_update_mode \
			!= SubViewport.UPDATE_ALWAYS:
		push_error("PORTAL_TARGET_DISABLED_%s" % test_name.to_upper())
		return false
	var before := await _capture("res://tmp/non_euclidean_%s_before.png" % test_name)
	var reference_pose := source.map_transform(player.global_transform)
	player.set_pose(reference_pose)
	main_camera.cull_mask = Portal3D.WORLD_LAYER | Portal3D.PROXY_LAYER
	main_camera.near = portal_camera.near
	for _frame in 8:
		await process_frame
	var reference := await _capture("res://tmp/non_euclidean_%s_reference.png" % test_name)
	var difference := _compare_points(before, reference, portal_samples)
	print("PORTAL_", test_name.to_upper(), "_MEAN=", difference.x, " MAX=", difference.y,
		" OUTLIERS=", difference.z, " SAMPLES=", portal_samples.size())
	if difference.x > 0.003 or difference.z > 0.01:
		for _frame in 12:
			await process_frame
		reference = await _capture("res://tmp/non_euclidean_%s_reference_retry.png" % test_name)
		difference = _compare_points(before, reference, portal_samples)
		print("PORTAL_", test_name.to_upper(), "_RETRY_MEAN=", difference.x,
			" MAX=", difference.y, " OUTLIERS=", difference.z)
		if difference.x > 0.003 or difference.z > 0.01:
			push_error("PORTAL_PIXEL_MISMATCH_%s" % test_name.to_upper())
			return false
	return true


func _test_crossing_continuity(source: Portal3D) -> bool:
	var camera := player.get_camera()
	camera.near = 0.01
	camera.cull_mask = Portal3D.WORLD_LAYER | Portal3D.MAIN_PORTAL_LAYER \
		| Portal3D.PROXY_LAYER
	var before_local := Vector3(0.0, -0.8, 0.004)
	player.set_pose(_aimed_pose(source, before_local))
	for _frame in 5:
		await process_frame
	var before := await _capture("res://tmp/non_euclidean_crossing_before.png")
	player._portal_previous_position = source.to_global(before_local)
	player.global_position = source.to_global(Vector3(0.0, -0.8, -0.004))
	source._physics_process(0.0)
	await process_frame
	var after := await _capture("res://tmp/non_euclidean_crossing_after.png")
	var size := Vector2(root.size)
	var difference := _compare(before, after, Rect2(size * 0.08, size * 0.84))
	print("PORTAL_CROSSING_MEAN=", difference.x, " MAX=", difference.y)
	if difference.x > 0.018:
		push_error("PORTAL_CROSSING_BLIP")
		return false
	if manager._slots[1]["portal"] != source.linked_portal \
			or (manager._slots[1]["viewport"] as SubViewport).render_target_update_mode \
			!= SubViewport.UPDATE_ALWAYS:
		push_error("ARRIVAL_PORTAL_TARGET_NOT_ACTIVE")
		return false
	return true


func _test_stair_wrap_continuity() -> bool:
	demo._go_to_case(1)
	var stair := demo.get_node("Cells/InfiniteStaircase") as Node3D
	for _frame in 4:
		await process_frame
	var overview := await _capture("res://tmp/non_euclidean_stair_overview.png")
	player.set_pose(Transform3D(Basis(Vector3.UP, PI),
		stair.to_global(Vector3(-0.6, 0.9, 8.5))))
	for _frame in 4:
		await process_frame
	await _capture("res://tmp/non_euclidean_stair_label.png")
	var radius := float(demo.STAIR_CENTER_RADIUS)
	var inspection_angle := PI * 1.5
	var inspection_radial := Vector3(cos(inspection_angle), 0.0, sin(inspection_angle))
	var inspection_tangent := Vector3(-sin(inspection_angle), 0.0, cos(inspection_angle))
	var inspection_position := inspection_radial * radius
	inspection_position.y = 2.95
	player.set_pose(Transform3D(_basis_from_forward(-inspection_tangent),
		stair.to_global(inspection_position)))
	(player.get_node("CameraPivot") as Node3D).rotation.x = -0.55
	for _frame in 4:
		await process_frame
	await _capture("res://tmp/non_euclidean_stair_look_down.png")
	player.set_pose(Transform3D(_basis_from_forward(inspection_tangent),
		stair.to_global(inspection_position)))
	(player.get_node("CameraPivot") as Node3D).rotation.x = 0.55
	for _frame in 4:
		await process_frame
	await _capture("res://tmp/non_euclidean_stair_look_up.png")
	player.set_pose(Transform3D(Basis.IDENTITY,
		stair.to_global(Vector3(0.0, demo.STAIR_WRAP_HEIGHT + 0.13, radius))))
	player.velocity = stair.global_basis.y
	for _frame in 4:
		await process_frame
	var before := await _capture("res://tmp/non_euclidean_stair_wrap_before.png")
	demo._physics_process(0.0)
	for _frame in 4:
		await process_frame
	var after := await _capture("res://tmp/non_euclidean_stair_wrap_after.png")
	var size := Vector2(root.size)
	var difference := _compare(before, after, Rect2(size * 0.05, size * 0.9))
	print("STAIR_WRAP_MEAN=", difference.x, " MAX=", difference.y)
	if difference.x > 0.004 or difference.y > 0.05:
		push_error("STAIR_WRAP_VISUAL_BLIP")
		return false
	player.global_position = stair.to_global(Vector3(0.0, 4.0, radius))
	player.velocity = Vector3.ZERO
	demo._physics_process(0.0)
	if (stair.get_node("LoopSeal") as Node3D).visible:
		push_error("STAIR_CORRIDOR_STAYS_SEALED_WHILE_DESCENDING")
		return false
	player.set_pose(demo._exhibit_poses[1])
	for _frame in 4:
		await process_frame
	var returned := await _capture("res://tmp/non_euclidean_stair_descended.png")
	var returned_difference := _compare(overview, returned, Rect2(size * 0.05, size * 0.9))
	print("STAIR_RETURN_MEAN=", returned_difference.x, " MAX=", returned_difference.y)
	if returned_difference.x > 0.001 or returned_difference.y > 0.02:
		push_error("STAIR_GROUND_FLOOR_DID_NOT_RETURN")
		return false
	return true


func _capture_reserve_threshold(destination: Portal3D) -> void:
	var interior := destination.get_parent() as Node3D
	player.set_pose(Transform3D(Basis(Vector3.UP, PI),
		interior.to_global(Vector3(0.0, 0.9, 13.8))))
	(player.get_node("CameraPivot") as Node3D).rotation.x = -0.62
	for _frame in 4:
		await process_frame
	await _capture("res://tmp/non_euclidean_reserve_threshold.png")


func _capture_spherical_garden() -> void:
	demo._go_to_case(2)
	for _frame in 4:
		await process_frame
	await _capture("res://tmp/non_euclidean_spherical_garden.png")


func _aimed_pose(portal: Portal3D, local_position: Vector3) -> Transform3D:
	var body_position := portal.to_global(local_position)
	var camera_position := body_position + Vector3.UP * 0.75
	var direction := portal.global_position - camera_position
	direction.y = 0.0
	direction = direction.normalized()
	var yaw := atan2(-direction.x, -direction.z)
	return Transform3D(Basis(Vector3.UP, yaw), body_position)


func _basis_from_forward(forward: Vector3) -> Basis:
	var normalized_forward := forward.normalized()
	var right := normalized_forward.cross(Vector3.UP).normalized()
	return Basis(right, Vector3.UP, -normalized_forward).orthonormalized()


func _capture(path: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(path)
	return image


func _portal_samples(portal: Portal3D, camera: Camera3D,
		aperture_fraction: float) -> PackedVector2Array:
	var samples := PackedVector2Array()
	var normal := portal.get_normal()
	var half := portal.opening_size * 0.5 * aperture_fraction
	var viewport := camera.get_viewport()
	var viewport_size := Vector2i(viewport.get_visible_rect().size)
	# Rays are cast in canvas coordinates (1280x720 stretch base) while captures are
	# window-sized, so samples go through the stretch transform before indexing an Image.
	var to_image := viewport.get_final_transform()
	for y in range(0, viewport_size.y, 3):
		for x in range(0, viewport_size.x, 3):
			var screen := Vector2(x, y)
			var ray_origin := camera.project_ray_origin(screen)
			var ray_direction := camera.project_ray_normal(screen)
			var denominator := ray_direction.dot(normal)
			if absf(denominator) <= 0.000001:
				continue
			var distance := (portal.global_position - ray_origin).dot(normal) / denominator
			if distance <= 0.0:
				continue
			var local_hit := portal.to_local(ray_origin + ray_direction * distance)
			if absf(local_hit.x) <= half.x and absf(local_hit.y) <= half.y:
				samples.append(to_image * screen)
	return samples


func _compare(before: Image, after: Image, rect: Rect2) -> Vector3:
	var points := PackedVector2Array()
	var start := Vector2i(rect.position)
	var end := Vector2i(rect.end)
	for y in range(start.y, end.y, 3):
		for x in range(start.x, end.x, 3):
			points.append(Vector2(x, y))
	return _compare_points(before, after, points)


func _compare_points(before: Image, after: Image, points: PackedVector2Array) -> Vector3:
	var total := 0.0
	var maximum_difference := 0.0
	var outliers := 0
	for point in points:
		var pixel := Vector2i(point)
		var difference := before.get_pixelv(pixel) - after.get_pixelv(pixel)
		var magnitude := (absf(difference.r) + absf(difference.g) \
			+ absf(difference.b)) / 3.0
		total += magnitude
		maximum_difference = maxf(maximum_difference, magnitude)
		if magnitude > 0.035:
			outliers += 1
	if points.is_empty():
		return Vector3(INF, INF, INF)
	return Vector3(total / float(points.size()), maximum_difference,
		float(outliers) / float(points.size()))


func _mean_luminance(image: Image, rect: Rect2i) -> float:
	var total := 0.0
	var samples := 0
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	for y in range(clipped.position.y, clipped.end.y):
		for x in range(clipped.position.x, clipped.end.x):
			total += image.get_pixel(x, y).get_luminance()
			samples += 1
	return total / maxf(float(samples), 1.0)
