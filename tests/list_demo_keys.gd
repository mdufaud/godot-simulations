extends SceneTree

## Prints the demo keys from the GameManager registry, one per line, so shell
## gates (run_ui_smoke.sh) consume the same list scene_cycle cycles through.

const GAME_MANAGER := preload("res://scripts/autoload/game_manager.gd")


func _initialize() -> void:
	for demo in GAME_MANAGER.DEMOS:
		print(demo.key)
	print("DEMO KEYS DONE")
	quit(0)
