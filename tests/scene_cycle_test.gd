extends "res://tests/test_case.gd"
## Cycles main menu -> every registered demo -> main menu and checks each
## transition and scene root. Viewport state restoration after a demo is freed
## is asserted per-demo by ui_smoke, not here.

const TRANSITION_TIMEOUT_MS := 10000


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	root.size = Vector2i(1920, 1080)
	await _load_scene("res://scenes/main_menu.tscn")
	for demo in GameManager.DEMOS:
		var key: String = demo.key
		var path: String = demo.scene
		await _load_scene(path)
		var scene_root: Node = current_scene
		_check(scene_root != null, "%s did not produce a current scene" % key)
		if scene_root != null:
			_check(scene_root.get_script() != null, "%s scene root has no script" % key)
		await _load_scene("res://scenes/main_menu.tscn")
	_finish("scene_cycle")


func _load_scene(path: String) -> void:
	var error := change_scene_to_file(path)
	_check(error == OK, "could not request scene %s" % path)
	var deadline := Time.get_ticks_msec() + TRANSITION_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var scene: Node = current_scene
		if scene != null and scene.scene_file_path == path:
			await process_frame
			return
	_check(false, "scene transition timed out: %s" % path)
