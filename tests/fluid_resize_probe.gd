extends SceneTree

## F-FLU-3 probe: does the screen-space fluid composite follow window resizes?
## Boots the real fluid demo, captures at 1280x720, resizes the window to a
## different aspect (900x720), captures again. With the resize unhandled the
## prepass viewports keep their boot-time size and proj_scale, so the fluid
## surface no longer lines up with the scene behind it.
##
## Output PNGs in res://tmp/flu3/, log lines start with "FLU3 ".

const OUT_DIR := "res://tmp/flu3"
const SETTLE_FRAMES := 240


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for i in 2:
		await process_frame
	root.size = Vector2i(1280, 720)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(1280, 720)
	demo.menu.visible = false

	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var renderer: Node = demo.fluid.renderer
		if renderer != null and renderer._tex_bound:
			break
	for i in SETTLE_FRAMES:
		await process_frame

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _grab("before_resize_1280x720.png")

	root.size = Vector2i(900, 720)
	for i in 20:
		await process_frame
	await _grab("after_resize_900x720.png")

	var cam: Camera3D = demo.fluid.camera
	print("FLU3 PROBE DONE window=%dx%d main_viewport=%s depth_vp=%s" % [
		root.size.x, root.size.y,
		str(cam.get_viewport().get_visible_rect().size),
		str(demo.fluid.renderer.depth_vp.size),
	])
	quit(0)


func _grab(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s" % [OUT_DIR, shot_name]))
	print("FLU3 SHOT " + shot_name)
