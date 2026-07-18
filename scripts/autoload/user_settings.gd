extends Node
## Persists user-facing state to `user://user_settings.cfg`:
##  - `[window]`      window size / position / mode
##  - `[game]`        the GameManager.settings dictionary
##  - `[sim.<demo>]`  every SimMenu widget value of that demo
##
## Writes are debounced so dragging a slider does not hit the disk every frame.

const PATH := "user://user_settings.cfg"
const SAVE_DELAY := 0.5

var _config := ConfigFile.new()
var _save_timer: Timer
var _restoring_window := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY
	_save_timer.timeout.connect(_flush)
	add_child(_save_timer)

	_config.load(PATH)

	_restore_game_settings()
	GameManager.settings_changed.connect(_on_game_settings_changed)

	if not _is_mobile():
		_restore_window()
		var window := get_window()
		window.size_changed.connect(_on_window_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		_flush()


# --- Public API used by SimMenu ------------------------------------------------

func has_sim_value(demo: String, key: String) -> bool:
	var section := "sim." + demo
	return _config.has_section(section) and _config.has_section_key(section, key)


func get_sim_value(demo: String, key: String, default: Variant) -> Variant:
	if not has_sim_value(demo, key):
		return default
	return _config.get_value("sim." + demo, key)


func set_sim_value(demo: String, key: String, value: Variant) -> void:
	_config.set_value("sim." + demo, key, value)
	_queue_save()


func clear_sim(demo: String) -> void:
	if _config.has_section("sim." + demo):
		_config.erase_section("sim." + demo)
		_queue_save()


# --- Internals -----------------------------------------------------------------

func _queue_save() -> void:
	_save_timer.start()


func _flush() -> void:
	_config.save(PATH)


func _on_game_settings_changed() -> void:
	for key in GameManager.settings:
		_config.set_value("game", key, GameManager.settings[key])
	_queue_save()


func _restore_game_settings() -> void:
	if not _config.has_section("game"):
		return
	for key in _config.get_section_keys("game"):
		if GameManager.settings.has(key):
			GameManager.settings[key] = _config.get_value("game", key)


func _is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web")


func _restore_window() -> void:
	if not _config.has_section("window"):
		return
	var window := get_window()
	var mode: int = _config.get_value("window", "mode", DisplayServer.WINDOW_MODE_WINDOWED)

	_restoring_window = true
	var size: Vector2i = _config.get_value("window", "size", window.size)
	window.size = size.max(Vector2i(320, 240))
	if _config.has_section_key("window", "position"):
		window.position = _config.get_value("window", "position")
	if mode != DisplayServer.WINDOW_MODE_WINDOWED:
		window.mode = mode as Window.Mode
	_restoring_window = false


func _on_window_changed() -> void:
	if _restoring_window:
		return
	var window := get_window()
	_config.set_value("window", "mode", int(window.mode))
	if window.mode == Window.MODE_WINDOWED:
		_config.set_value("window", "size", window.size)
		_config.set_value("window", "position", window.position)
	_queue_save()
