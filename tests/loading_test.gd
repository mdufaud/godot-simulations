extends "res://tests/test_case.gd"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	var manager := root.get_node("GameManager")
	var overlay := manager.get_node("LoadingOverlay") as CanvasLayer
	_check(not overlay.visible, "Loading overlay must be hidden at boot")
	manager.call("go_to_menu")
	await scene_changed

	for key: String in ["fractal_demo", "parallax_demo", "fractal_demo"]:
		manager.call("load_demo", key)
		_check(overlay.visible, "Loading overlay must appear immediately")
		_check(manager.is_processing(), "Spinner must animate while loading")
		manager.call("load_demo", "fractal_3d_demo")
		manager.call("go_to_menu")
		var deadline := Time.get_ticks_msec() + 10000
		while overlay.visible and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(not overlay.visible, "Loading overlay must disappear after scene initialization")
		if overlay.visible:
			_finish("loading")
			return
		_check(not manager.is_processing(), "Spinner must stop processing after loading")
		_check(manager.get("current_demo") == key, "Repeated clicks must preserve the requested simulation")
		_check(current_scene != null and current_scene.scene_file_path == manager.call("demo_scene", key),
			"Loading must activate the requested simulation")
		_check(float(manager.get("_loading_angle")) > 0.0, "Spinner must rotate during loading")
		manager.call("go_to_menu")
		await scene_changed
		_check(manager.get("current_demo") == "", "Returning to the menu must clear the current simulation")
		_check(not overlay.visible, "Returning to the menu must leave loading hidden")
	_finish("loading")
