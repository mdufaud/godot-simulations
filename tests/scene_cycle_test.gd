extends "res://tests/test_case.gd"

const TRANSITION_TIMEOUT_FRAMES := 180


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	root.size = Vector2i(1920, 1080)
	await _load_scene("res://scenes/main_menu.tscn")
	var entry := _viewport_state()
	for demo in GameManager.DEMOS:
		var key: String = demo.key
		var path: String = demo.scene
		await _load_scene(path)
		var scene_root: Node = current_scene
		_check(scene_root != null, "%s did not produce a current scene" % key)
		if scene_root != null:
			_check(scene_root.get_script() != null, "%s scene root has no script" % key)
		await _load_scene("res://scenes/main_menu.tscn")
		_check_viewport_state(entry, key)
	_finish("scene_cycle")


func _load_scene(path: String) -> void:
	var error := change_scene_to_file(path)
	_check(error == OK, "could not request scene %s" % path)
	for _frame in TRANSITION_TIMEOUT_FRAMES:
		await process_frame
		var scene: Node = current_scene
		if scene != null and scene.scene_file_path == path:
			await process_frame
			return
	_check(false, "scene transition timed out: %s" % path)


func _viewport_state() -> Dictionary:
	return {
		scaling_3d_mode = root.scaling_3d_mode,
		scaling_3d_scale = root.scaling_3d_scale,
		msaa_3d = root.msaa_3d,
	}


func _check_viewport_state(entry: Dictionary, demo: String) -> void:
	_check(root.scaling_3d_mode == entry.scaling_3d_mode,
		"%s leaked viewport scaling mode" % demo)
	_check(is_equal_approx(root.scaling_3d_scale, entry.scaling_3d_scale),
		"%s leaked viewport scaling scale" % demo)
	_check(root.msaa_3d == entry.msaa_3d, "%s leaked viewport MSAA" % demo)
