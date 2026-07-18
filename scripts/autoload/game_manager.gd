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
	
	# Fire demo
	"fire_particle_count": 500,
	"fire_smoke_enabled": true,
	"fire_sparks_enabled": true,
	
	# N-body demo
	"nbody_particle_count": 262144,
	"nbody_self_gravity": false,

	# Sand demo
	"sand_grid_n": 512,

	# Ocean demo
	"ocean_map_size": 256,

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

	# Forest demo
	"forest_quality_mode": 0,  # 0=photoreal, 1=low-poly
	"forest_tree_density": 1.0,
	"forest_grass_density": 0.6,
	"forest_render_scale": 0.5,  # FSR2 upscale factor in photoreal (user's perf lever)
}

const SCENES := {
	"main_menu": "res://scenes/main_menu.tscn",
	"ssr_demo": "res://scenes/ssr_demo.tscn",
	"ocean_demo": "res://scenes/ocean_demo.tscn",
	"fire_demo": "res://scenes/fire_demo.tscn",
	"nbody_demo": "res://scenes/nbody_demo.tscn",
	"grass_demo": "res://scenes/grass_demo.tscn",
	"parallax_demo": "res://scenes/parallax_demo.tscn",
	"fluid_demo": "res://scenes/fluid_demo.tscn",
	"fractal_demo": "res://scenes/fractal_demo.tscn",
	"fractal_3d_demo": "res://scenes/fractal_3d_demo.tscn",
	"tornado_demo": "res://scenes/tornado_demo.tscn",
	"sand_demo": "res://scenes/sand_demo.tscn",
	"cloth_demo": "res://scenes/cloth_demo.tscn",
	"destruction_demo": "res://scenes/destruction_demo.tscn",
	"non_euclidean_demo": "res://scenes/non_euclidean_demo.tscn",
	"forest_demo": "res://scenes/forest_demo.tscn",
}

## Ordered list of demos shown on the main menu.
## To add a new demo, just append a {key, title, icon} entry here.
const DEMOS: Array[Dictionary] = [
	{key = "ssr_demo",      title = "SSR Physics Demo",     icon = "🔮"},
	{key = "ocean_demo",    title = "FFT Ocean",            icon = "⚓"},
	{key = "fire_demo",     title = "Fire Simulation",      icon = "🔥"},
	{key = "nbody_demo",    title = "N-Body Galaxy",        icon = "🌌"},
	{key = "grass_demo",    title = "Grass Simulation",     icon = "🌿"},
	{key = "parallax_demo", title = "Parallax Mapping",     icon = "🪨"},
	{key = "fluid_demo",    title = "Fluid Simulation (PBF)", icon = "💧"},
	{key = "fractal_demo",  title = "2D Fractal Explorer",  icon = "🧠"},
	{key = "fractal_3d_demo",  title = "3D Fractal Explorer",  icon = "🧊"},
	{key = "tornado_demo",  title = "Tornado Simulation",  icon = "🌪️"},
	{key = "sand_demo",     title = "Heightfield Sand", icon = "🏖️"},
	{key = "cloth_demo",    title = "Cloth in the Wind", icon = "🏳️"},
	{key = "destruction_demo", title = "Voronoi Destruction", icon = "🧱"},
	{key = "non_euclidean_demo", title = "Non-Euclidean Lab", icon = "🚪"},
	{key = "forest_demo",   title = "Forest Walk",          icon = "🌲"},
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
