extends Node
## Global game manager for scene switching and configuration

signal settings_changed

# Current demo tracking
var current_demo: String = ""

# Global settings
var settings: Dictionary = {
	# Graphics
	"ssr_enabled": true,
	"ssr_max_steps": 96,
	"particle_quality": 1.0,  # Multiplier for particle counts
	"shadow_quality": 2,  # 0=off, 1=low, 2=high
	
	# Water demo
	"water_wave_intensity": 1.0,
	"water_foam_enabled": true,
	"water_caustics_enabled": true,
	
	# Fire demo
	"fire_particle_count": 500,
	"fire_smoke_enabled": true,
	"fire_sparks_enabled": true,
	
	# Dice demo
	"dice_count": 5,
	"dice_table_friction": 0.6,
	"dice_throw_force": 15.0,
	
	# SSR demo
	"ssr_demo_max_objects": 200,
	"ssr_demo_spawn_rate": 0.25,
	
	# Parallax demo
	"parallax_height": 0.08,
	"parallax_min_layers": 8,
	"parallax_max_layers": 32,
	"parallax_uv_scale": 2.0,
	"parallax_normal_strength": 1.0,
	"parallax_roughness": 0.8,
	"parallax_shadow_strength": 0.8,
	"parallax_self_shadow": true,
	"parallax_computed_normals": false,
	"parallax_preset": 0,
	"parallax_mesh": 0,
	
	# Fractal demo
	"fractal_type": 0,
	"fractal_color_mode": 0,
	"fractal_color_speed": 0.3,
	"fractal_auto_zoom": true,
	"fractal_zoom_speed": 0.15,
}

const SCENES := {
	"main_menu": "res://scenes/main_menu.tscn",
	"ssr_demo": "res://scenes/ssr_demo.tscn",
	"water_demo": "res://scenes/water_demo.tscn",
	"fire_demo": "res://scenes/fire_demo.tscn",
	"dice_demo": "res://scenes/dice_demo.tscn",
	"grass_demo": "res://scenes/grass_demo.tscn",
	"parallax_demo": "res://scenes/parallax_demo.tscn",
	"fluid_demo": "res://scenes/fluid_demo.tscn",
	"fractal_demo": "res://scenes/fractal_demo.tscn",
	"fractal_3d_demo": "res://scenes/fractal_3d_demo.tscn",
	"tornado_demo": "res://scenes/tornado_demo.tscn",
}

## Ordered list of demos shown on the main menu.
## To add a new demo, just append a {key, title, icon} entry here.
const DEMOS: Array[Dictionary] = [
	{key = "ssr_demo",      title = "SSR Physics Demo",     icon = "🔮"},
	{key = "water_demo",    title = "Water Simulation",     icon = "🌊"},
	{key = "fire_demo",     title = "Fire Simulation",      icon = "🔥"},
	{key = "dice_demo",     title = "Dice Throw",           icon = "🎲"},
	{key = "grass_demo",    title = "Grass Simulation",     icon = "🌿"},
	{key = "parallax_demo", title = "Parallax Mapping",     icon = "🪨"},
	{key = "fluid_demo",    title = "Fluid Simulation (PBF)", icon = "💧"},
	{key = "fractal_demo",  title = "2D Fractal Explorer",  icon = "🧠"},
	{key = "fractal_3d_demo",  title = "3D Fractal Explorer",  icon = "🧊"},
	{key = "tornado_demo",  title = "Tornado Simulation",  icon = "🌪️"},
]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func load_demo(demo_name: String) -> void:
	if not SCENES.has(demo_name):
		push_error("Unknown demo: %s" % demo_name)
		return
	
	current_demo = demo_name
	get_tree().change_scene_to_file(SCENES[demo_name])


func go_to_menu() -> void:
	current_demo = ""
	get_tree().change_scene_to_file(SCENES["main_menu"])


func get_setting(key: String, default = null):
	return settings.get(key, default)


func set_setting(key: String, value) -> void:
	settings[key] = value
	settings_changed.emit()


func quit_game() -> void:
	get_tree().quit()
