extends Node
# Boots the explosion demo through GameManager like the main menu does, runs steps, then leaves (go_to_menu+quit_game or quit_game).
# usage: godot res://tests/explosion_leak_game.tscn -- explosion_leak <step,...> <menu|quit>


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var steps: PackedStringArray = String(args[1]).split(",") if args.size() > 1 else PackedStringArray()
	var mode := String(args[2]) if args.size() > 2 else "menu"
	await get_tree().process_frame
	var placeholder := Node.new()
	get_tree().root.add_child(placeholder)
	get_tree().current_scene = placeholder
	var key := String(args[3]) if args.size() > 3 else "explosion_demo"
	if key == "none":
		print("LEAK DONE")
		GameManager.quit_game()
		return
	await GameManager.load_demo(key)
	for i in 60:
		await get_tree().process_frame
	var demo: Node = get_tree().current_scene
	var deadline := Time.get_ticks_msec() + 60000
	while key == "explosion_demo" and not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	for step in steps:
		match step:
			"scene0", "scene1", "scene2":
				demo.set_scene(int(step.right(1)))
			"next":
				demo.next_scene()
			"throw":
				demo.launcher.fire(Vector2(get_tree().root.size) * Vector2(0.5, 0.62))
			"detonate":
				demo.detonate_scene()
			"barrels":
				demo.add_barrels()
			"reset":
				demo.reset_simulation()
		for i in 90:
			await get_tree().process_frame
		print("LEAK step=%s scene=%s" % [step, demo.get("scene_index")])
	if mode == "menu":
		GameManager.go_to_menu()
		for i in 30:
			await get_tree().process_frame
	print("LEAK DONE")
	GameManager.quit_game()
