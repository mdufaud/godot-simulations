extends Node
## Global game manager for scene switching and configuration

signal settings_changed

const LOADING_PUMP_INTERVAL_MS := 33

# Current demo tracking
var current_demo: String = ""
var _loading_layer: CanvasLayer
var _loading_label: Label
var _loading_spinner: Control
var _loading_angle := 0.0
var _last_pump_ms := 0
var _stage_item := RID()
var _stage_text := ""
var _stage_started_ms := 0
# A --max-fps given on the command line (0 when absent) is a ceiling the
# fps_limit setting cannot raise: the test runners cap every process with it.
var _cli_fps_cap := Engine.max_fps
var _frame_cap_usec := 0

# Global settings
var settings: Dictionary = {
	# App-wide frame cap applied to Engine.max_fps
	"fps_limit": 60,

	# Ocean demo
	"ocean_map_size": 512,
	"ocean_scene_mode": 0,

	# Quality tiers (0 Low / 1 Medium / 2 High / 3 Ultra). Every key must exist
	# here at startup: UserSettings only restores keys already in this dict.
	# Ocean keeps High, the configuration it shipped with; the other demos
	# default to Medium.
	"ocean_quality_profile": 2,
	"river_quality_profile": 1,
	"terrain_quality_profile": 1,
	"nbody_quality_profile": 1,
	"planet_quality_profile": 1,
	"fluid_quality_profile": 1,
	"tornado_quality_profile": 1,
	"cloth_quality_profile": 1,
	"destruction_quality_profile": 1,
	"grass_quality_profile": 1,
	"mixwell_quality_profile": 1,
	"fractal_quality_profile": 1,
	"non_euclidean_quality_profile": 1,
	"ssr_quality_profile": 1,
	"ambient_fluid_quality_profile": 1,
	"parallax_quality_profile": 1,
	"wildfire_quality_profile": 1,
	"smoke_quality_profile": 1,
}

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## Ordered list of categories shown on the main menu accordion.
const CATEGORIES: Array[Dictionary] = [
	{key = "fluids",    title = "Fluids",           icon = "💧"},
	{key = "rigid",     title = "Rigid Bodies",     icon = "🪨"},
	{key = "particles", title = "Particles & Fields", icon = "🌪️"},
	{key = "other",     title = "Others",           icon = "🎨"},
]

## Ordered list of demos shown on the main menu, and the single demo registry.
## To add a new demo, just append a {key, title, icon, category, scene} entry here.
const DEMOS: Array[Dictionary] = [
	{key = "ssr_demo",      title = "Screen space reflection",     icon = "🔮", category = "rigid",
		scene = "res://scenes/ssr_demo.tscn"},
	{key = "ocean_demo",    title = "FFT Ocean",            icon = "⚓", category = "fluids",
		scene = "res://scenes/ocean_demo.tscn"},
	{key = "river_demo",    title = "River",                icon = "🏞️", category = "fluids",
		scene = "res://scenes/river_demo.tscn"},
	{key = "fire_demo",     title = "Fire Simulation",      icon = "🔥", category = "particles",
		scene = "res://scenes/fire_demo.tscn"},
	{key = "wildfire_demo", title = "Wildfire",            icon = "🔥", category = "particles",
		scene = "res://scenes/wildfire_demo.tscn"},
	{key = "nbody_demo",    title = "N-Body Gallery",       icon = "🌌", category = "particles",
		scene = "res://scenes/nbody_demo.tscn"},
	{key = "grass_demo",    title = "Grass Simulation",     icon = "🌿", category = "other",
		scene = "res://scenes/grass_demo.tscn"},
	{key = "parallax_demo", title = "Parallax Mapping",     icon = "🪨", category = "other",
		scene = "res://scenes/parallax_demo.tscn"},
	{key = "fluid_demo",    title = "Fluid Simulation",      icon = "💧", category = "fluids",
		scene = "res://scenes/fluid_demo.tscn"},
	{key = "mixwell_demo",  title = "Mixwell 2D Mixing",     icon = "🌀", category = "fluids",
		scene = "res://scenes/mixwell_demo.tscn"},
	{key = "fractal_demo",  title = "2D Fractal Explorer",  icon = "🧠", category = "other",
		scene = "res://scenes/fractal_demo.tscn"},
	{key = "fractal_3d_demo",  title = "3D Fractal Explorer",  icon = "🧊", category = "other",
		scene = "res://scenes/fractal_3d_demo.tscn"},
	{key = "tornado_demo",  title = "Tornado Simulation",  icon = "🌪️", category = "particles",
		scene = "res://scenes/tornado_demo.tscn"},
	{key = "terrain_demo",  title = "Water & Stone",  icon = "🏔️", category = "particles",
		scene = "res://scenes/terrain_demo.tscn"},
	{key = "cloth_demo",    title = "Cloth in the Wind", icon = "🏳️", category = "rigid",
		scene = "res://scenes/cloth_demo.tscn"},
	{key = "destruction_demo", title = "Voronoi Destruction", icon = "🧱", category = "rigid",
		scene = "res://scenes/destruction_demo.tscn"},
	{key = "ambient_fluid_demo", title = "Ambient Fluid Rigid Body", icon = "🍃", category = "rigid",
		scene = "res://scenes/ambient_fluid_demo.tscn"},
	{key = "non_euclidean_demo", title = "Non-Euclidean Lab", icon = "🚪", category = "other",
		scene = "res://scenes/non_euclidean_demo.tscn"},
	{key = "planet_demo",   title = "Procedural Planet",    icon = "🪐", category = "other",
		scene = "res://scenes/planet_demo.tscn"},
	{key = "smoke_demo",    title = "Smoke Simulation",     icon = "💨", category = "fluids",
		scene = "res://scenes/smoke_demo.tscn"},
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	apply_fps_limit()
	if _cli_fps_cap > 0:
		get_tree().process_frame.connect(_hold_frame_cap)
	_create_loading_overlay()
	LoadingPump.set_hook(pump_loading)
	set_process(false)


func _process(delta: float) -> void:
	_loading_angle = fmod(_loading_angle + delta * TAU, TAU)
	_loading_spinner.rotation = _loading_angle
	_draw_loading_stage()


func _create_loading_overlay() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.name = "LoadingOverlay"
	_loading_layer.layer = 100
	_loading_layer.hide()
	add_child(_loading_layer)

	var background := ColorRect.new()
	background.color = Color(0.02, 0.03, 0.06, 0.98)
	_loading_layer.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var content := VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", 20)
	center.add_child(content)

	var spinner_row := CenterContainer.new()
	spinner_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(spinner_row)
	_loading_spinner = Control.new()
	_loading_spinner.custom_minimum_size = Vector2(56, 56)
	_loading_spinner.pivot_offset = Vector2(28, 28)
	_loading_spinner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading_spinner.draw.connect(_draw_loading_spinner)
	spinner_row.add_child(_loading_spinner)

	_loading_label = Label.new()
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 22)
	_loading_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	content.add_child(_loading_label)

	# Drawn straight on a canvas item: a Label's own redraw is deferred to the
	# message queue, which never flushes while a demo's _ready blocks.
	_stage_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_stage_item, _loading_layer.get_canvas())


func _exit_tree() -> void:
	if _stage_item.is_valid():
		RenderingServer.free_rid(_stage_item)


func _draw_loading_stage() -> void:
	RenderingServer.canvas_item_clear(_stage_item)
	if _stage_text.is_empty():
		return
	var elapsed_s := float(Time.get_ticks_msec() - _stage_started_ms) * 0.001
	var anchor := _loading_label.get_global_rect()
	ThemeDB.fallback_font.draw_string(_stage_item,
		Vector2(0.0, anchor.end.y + 36.0), "%s  %.1f s" % [_stage_text, elapsed_s],
		HORIZONTAL_ALIGNMENT_CENTER, get_viewport().get_visible_rect().size.x, 18,
		Color(0.55, 0.7, 0.9))


func _draw_loading_spinner() -> void:
	var center := _loading_spinner.size * 0.5
	_loading_spinner.draw_arc(center, 24.0, 0.0, TAU, 48, Color(0.12, 0.18, 0.28), 4.0, true)
	_loading_spinner.draw_arc(center, 24.0, 0.0, TAU * 0.75, 48, Color(0.35, 0.62, 1.0), 4.0, true)


func _finish_loading() -> void:
	if get_tree().node_added.is_connected(_pump_loading_on_node):
		get_tree().node_added.disconnect(_pump_loading_on_node)
	_loading_layer.hide()
	_stage_text = ""
	RenderingServer.canvas_item_clear(_stage_item)
	set_process(false)


func _set_loading_stage(label: String) -> void:
	_stage_text = label
	_stage_started_ms = Time.get_ticks_msec()


## Redraws the overlay from inside a blocking main-thread step (a demo's
## _ready), where no process frame can run. A non-empty [param stage] names the
## step about to run and redraws at once; otherwise the redraw is rate-limited.
## A no-op unless a simulation is loading, so a demo may call it freely.
func pump_loading(stage: String = "") -> void:
	if not _loading_layer.visible or DisplayServer.get_name() == "headless":
		return
	var now := Time.get_ticks_msec()
	if not stage.is_empty():
		_set_loading_stage(stage)
	elif now - _last_pump_ms < LOADING_PUMP_INTERVAL_MS:
		return
	_last_pump_ms = now
	_loading_angle = fmod(float(now) * 0.001 * TAU, TAU)
	_loading_spinner.rotation = _loading_angle
	_draw_loading_stage()
	var root_viewport := get_viewport()
	root_viewport.disable_3d = true
	RenderingServer.force_draw()
	root_viewport.disable_3d = false


func _pump_loading_on_node(_node: Node) -> void:
	pump_loading()


## Push settings["fps_limit"] into the engine. Headless runs (tests, CI) keep
## the command-line cap, uncapped without one.
func apply_fps_limit() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var limit := int(settings["fps_limit"])
	if _cli_fps_cap > 0:
		limit = _cli_fps_cap if limit <= 0 else mini(limit, _cli_fps_cap)
	Engine.max_fps = limit


# --fixed-fps bypasses the engine frame limiter, so the gates' --max-fps would
# be ignored; hold each frame to the Engine.max_fps budget here instead.
func _hold_frame_cap() -> void:
	if Engine.max_fps > 0:
		var remaining := 1_000_000 / Engine.max_fps - (Time.get_ticks_usec() - _frame_cap_usec)
		if remaining > 0:
			OS.delay_usec(remaining)
	_frame_cap_usec = Time.get_ticks_usec()


## Scene path for a demo key, or "" when the key is not registered.
static func demo_scene(demo_name: String) -> String:
	for demo in DEMOS:
		if demo.key == demo_name:
			return demo.scene
	return ""


func load_demo(demo_name: String) -> void:
	if _loading_layer.visible:
		return
	var scene := demo_scene(demo_name)
	if scene.is_empty():
		push_error("Unknown demo: %s" % demo_name)
		return

	for demo in DEMOS:
		if demo.key == demo_name:
			_loading_label.text = "Loading simulation…\n%s" % demo.title
	_loading_angle = 0.0
	_set_loading_stage("Loading resources")
	_loading_layer.show()
	set_process(true)
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

	var error := ResourceLoader.load_threaded_request(scene, "PackedScene")
	if error != OK:
		push_error("Could not load simulation %s: %s" % [demo_name, error_string(error)])
		_finish_loading()
		return
	var status := ResourceLoader.load_threaded_get_status(scene)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(scene)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		push_error("Could not load simulation: %s" % demo_name)
		_finish_loading()
		return

	var packed := ResourceLoader.load_threaded_get(scene) as PackedScene
	var previous_demo := current_demo
	current_demo = demo_name
	_set_loading_stage("Building scene")
	get_tree().node_added.connect(_pump_loading_on_node)
	error = get_tree().change_scene_to_packed(packed)
	if error != OK:
		current_demo = previous_demo
		push_error("Could not start simulation %s: %s" % [demo_name, error_string(error)])
		_finish_loading()
		return
	await get_tree().scene_changed
	_set_loading_stage("Rendering first frame")
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	_finish_loading()


func go_to_menu() -> void:
	if _loading_layer.visible:
		return
	current_demo = ""
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func get_setting(key: String, default = null):
	return settings.get(key, default)


func set_setting(key: String, value) -> void:
	settings[key] = value
	if key == "fps_limit":
		apply_fps_limit()
	settings_changed.emit()


func quit_game() -> void:
	get_tree().quit()
