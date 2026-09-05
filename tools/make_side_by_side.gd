extends SceneTree
## Compositing tool for the ocean refonte validation: place two (or three)
## images side by side at a common height — engine captures next to reference
## video frames extracted outside the engine (ffmpeg), per refonte plan §7.
## No pixels are ever generated: this only arranges existing images.
##
## Usage (from the project root):
##   godot --headless -s res://tools/make_side_by_side.gd -- \
##       out.png left.png right.png [second_right.png] [gap=8]
## Every input after out.png is one panel, left to right. Panels keep their
## aspect ratio; each is scaled to the smallest panel height.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("usage: -- out.png panel1.png panel2.png [panel3.png] [gap=N]")
		quit(1)
		return
	var gap := 8
	var paths: Array[String] = []
	for i in args.size():
		if i == 0:
			continue
		if args[i].begins_with("gap="):
			gap = maxi(0, int(args[i].get_slice("=", 1)))
			continue
		paths.append(args[i])
	var out_path := args[0]

	var panels: Array[Image] = []
	for path in paths:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			push_error("cannot load %s" % path)
			quit(1)
			return
		panels.append(img)

	var target_height := panels[0].get_height()
	for img in panels:
		target_height = mini(target_height, img.get_height())

	var total_width := gap * (panels.size() - 1)
	for img in panels:
		total_width += int(round(float(img.get_width())
			* float(target_height) / float(img.get_height())))

	var canvas := Image.create(total_width, target_height, false, Image.FORMAT_RGB8)
	canvas.fill(Color(0.05, 0.05, 0.05))
	var x := 0
	for img in panels:
		var w := int(round(float(img.get_width())
			* float(target_height) / float(img.get_height())))
		img.resize(w, target_height, Image.INTERPOLATE_LANCZOS)
		var converted := img
		if img.get_format() != Image.FORMAT_RGB8:
			converted = img.duplicate()
			converted.convert_to(Image.FORMAT_RGB8)
		canvas.blit_rect(converted, Rect2i(0, 0, w, target_height), Vector2i(x, 0))
		x += w + gap

	canvas.save_png(ProjectSettings.globalize_path(out_path))
	print("MAKE_SIDE_BY_SIDE out=%s panels=%d size=%dx%d" % [
		out_path, panels.size(), canvas.get_width(), canvas.get_height()])
	quit(0)
