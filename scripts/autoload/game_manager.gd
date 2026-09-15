extends Node
## Global game manager for scene switching and configuration

signal settings_changed

# Current demo tracking
var current_demo: String = ""

# Global settings
var settings: Dictionary = {
	# App-wide frame cap applied to Engine.max_fps
	"fps_limit": 60,

	# Ocean demo
	"ocean_map_size": 512,

	# Quality tiers (0 Low / 1 Medium / 2 High / 3 Ultra). Every key must exist
	# here at startup: UserSettings only restores keys already in this dict.
	# Ocean keeps High, the configuration it shipped with; the other demos
	# default to Medium.
	"ocean_quality_profile": 2,
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
	{key = "fire_demo",     title = "Fire Simulation",      icon = "🔥", category = "particles",
		scene = "res://scenes/fire_demo.tscn"},
	{key = "fire_game_demo", title = "Wildfire (game fire)", icon = "🔥", category = "particles",
		scene = "res://scenes/fire_game_demo.tscn"},
	{key = "nbody_demo",    title = "N-Body Galaxy",        icon = "🌌", category = "particles",
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
	{key = "terrain_demo",  title = "Sand & Snow",  icon = "🏔️", category = "particles",
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
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	apply_fps_limit()


## Push settings["fps_limit"] into the engine. Headless runs (tests, CI) rely on
## uncapped frames, so they keep spinning as fast as the CPU allows.
func apply_fps_limit() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Engine.max_fps = int(settings["fps_limit"])


## Scene path for a demo key, or "" when the key is not registered.
static func demo_scene(demo_name: String) -> String:
	for demo in DEMOS:
		if demo.key == demo_name:
			return demo.scene
	return ""


func load_demo(demo_name: String) -> void:
	var scene := demo_scene(demo_name)
	if scene.is_empty():
		push_error("Unknown demo: %s" % demo_name)
		return

	current_demo = demo_name
	get_tree().change_scene_to_file(scene)


func go_to_menu() -> void:
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
