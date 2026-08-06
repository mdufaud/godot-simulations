extends Node3D
## Voronoi destruction on Jolt. Four walls — concrete, brick, glass and stone,
## each with its own thickness, density and toughness — are fractured once at
## load into [FracturedWall]s, and a projectile's impact is broadcast to all of
## them as a blast. Which cells give way, and what stays standing afterwards, is
## the wall's business.

const REBUILD_DEBOUNCE := 0.35
const FRACTURE_SEED := 0xB16B00B5

const WALLS := [
	preload("res://resources/destruction/presets/concrete.tres"),
	preload("res://resources/destruction/presets/brick.tres"),
	preload("res://resources/destruction/presets/glass.tres"),
	preload("res://resources/destruction/presets/stone.tres"),
]
const PROJECTILES := [
	preload("res://resources/destruction/presets/bullet.tres"),
	preload("res://resources/destruction/presets/cannonball.tres"),
	preload("res://resources/destruction/presets/shell.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var wall_root: Node3D = $Wall
@onready var projectile_root: Node3D = $Projectiles
@onready var _viewport := ViewportGuard.attach(self)

var chunk_count := 100
var fracture_bias := 0.6
var config: DestructionConfig = DestructionConfig.new()

var walls: Array[FracturedWall] = []
var launcher := ProjectileLauncher.new()

var _menu_builder := DestructionMenu.new()
var _rng := RandomNumberGenerator.new()
var _rebuild_pending := false


func _ready() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Destruction config: %s" % config_error)
		return
	chunk_count = config.chunk_count
	fracture_bias = config.fracture_bias
	orbit_cam.target = Vector3(-1.8, 0.8, -1.5)
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -22.0
	orbit_cam.yaw = 14.0
	orbit_cam.min_distance = 4.0
	orbit_cam.max_distance = 50.0

	# The walls face the camera, so the sun comes from over the viewer's shoulder.
	sun.rotation_degrees = Vector3(-48.0, -25.0, 0.0)
	sun.directional_shadow_max_distance = 60.0

	launcher.camera = main_cam
	launcher.container = projectile_root
	launcher.impact.connect(_on_impact)
	launcher.arm(PROJECTILES[1])

	_spawn_wall_labels()
	_setup_ui()
	rebuild()


func _physics_process(_delta: float) -> void:
	launcher.despawn_fallen()
	for wall in walls:
		wall.despawn_below(ProjectileLauncher.DESPAWN_Y)
		wall.settle()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		launcher.fire(event.position)


## Refractures all four walls from a fixed seed, so the same sliders always give
## the same wall.
func rebuild() -> void:
	for wall in walls:
		wall.clear()
	walls.clear()
	launcher.clear()

	_rng.seed = FRACTURE_SEED
	for preset in WALLS:
		var typed: WallPreset = preset
		var error := typed.validate()
		if error != "":
			push_error("Wall preset '%s': %s" % [typed.display_name, error])
			continue
		var wall := FracturedWall.new()
		wall.stats_changed.connect(_update_status)
		wall.build(wall_root, typed, WallMaterials.build(typed.surface),
			chunk_count, fracture_bias, _rng)
		walls.append(wall)
	_update_status()


func fire_at_centre() -> void:
	launcher.fire(get_viewport().get_visible_rect().size * 0.5)


func arm_projectile(index: int) -> void:
	launcher.arm(PROJECTILES[index])


# Rebuilding the walls on every slider tick would refracture 500 hulls per frame,
# so the count and the bias land on release.
func set_chunk_count(value: float) -> void:
	chunk_count = int(round(value))
	_queue_rebuild()


func set_bias(value: float) -> void:
	fracture_bias = value
	_queue_rebuild()


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _on_impact(origin: Vector3, radius_m: float, impulse: float) -> void:
	for wall in walls:
		wall.blast(origin, radius_m, impulse)


func _queue_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	get_tree().create_timer(REBUILD_DEBOUNCE).timeout.connect(func():
		_rebuild_pending = false
		rebuild()
	)


func _spawn_wall_labels() -> void:
	for preset in WALLS:
		var typed: WallPreset = preset
		var label := Label3D.new()
		label.text = typed.display_name
		label.position = typed.position_m + Vector3(0.0, typed.size_m.y + 0.6, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 64
		label.outline_size = 14
		label.modulate = Color(0.95, 0.95, 0.9)
		add_child(label)


func _setup_ui() -> void:
	_menu_builder.launcher = launcher
	_menu_builder.host = self
	_menu_builder.build(menu, PROJECTILES, 1, chunk_count, fracture_bias)


func _update_status() -> void:
	var cells := 0
	var awake := 0
	var asleep := 0
	var gone := 0
	for wall in walls:
		cells += wall.chunks.size()
		awake += wall.awake
		asleep += wall.asleep()
		gone += wall.gone
	_menu_builder.set_status("%d cells · %d awake · %d asleep · %d gone" % [
		cells, awake, asleep, gone,
	])
