extends Node3D
## Wildfire Demo Controller — the RDR2-model game fire scene.
##
## A CPU cell grid (Far Cry 2 propagation rules) decides which log-pile cells
## burn; every ignited cell spawns a GPU-particle fire in WildfireSystem. The
## ground is inert: only the log piles take fire from the flamethrower.

const PRESET_TORCH := preload("res://resources/wildfire/presets/torch.tres")
const PRESET_CAMPFIRE := preload("res://resources/wildfire/presets/campfire.tres")
const PRESET_BONFIRE := preload("res://resources/wildfire/presets/bonfire.tres")
## Frames of viewport GPU time kept for the capture cost readout.
const GPU_SAMPLES := 120

## capture.sh view name -> [player position, pitch in degrees], facing -Z.
const CAPTURE_VIEWS := {
	"close": [Vector3(0.3, 0.0, 6.7), -6.0],
	"mid": [Vector3(0.0, 0.0, 12.0), -8.0],
	"far": [Vector3(0.0, 0.0, 26.0), -4.0],
	"top": [Vector3(0.0, 0.0, 5.6), -50.0],
	"torch": [Vector3(10.0, 0.0, 7.2), 4.0],
	"pile": [Vector3(9.0, 0.0, 0.6), -10.0],
	"aim_ground": [Vector3(0.0, 0.0, -6.0), -20.0],
	"aim_pile": [Vector3(9.0, 0.0, 1.5), -20.0],
	"aim_level": [Vector3(0.0, 0.0, -6.0), 0.0],
}

@onready var player: FpsWalker = $Player
@onready var weapons: FireWeapons = $Player/Camera3D/Weapons
@onready var muzzle: Marker3D = $Player/Camera3D/Weapons/Flamethrower/Muzzle
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI
@onready var scenery: WildfireScenery = $Scenery
@onready var viewport_guard := ViewportGuard.attach(self)

var debug_info := false
var system: WildfireSystem
var grid: CellPropagation
var hud: WildfireHud
var menu_builder: WildfireMenu
var flamethrower: WildfireFlamethrower
var quality := SimQualityState.new()

var wind_enabled := false
var wind_angle_deg := 25.0
var wind_strength := 2.5

var flamethrower_firing := false

var _frame_ms := 0.0
var _gpu_samples := PackedFloat32Array()
var _grid_config: CellPropagationConfig


func _ready() -> void:
	system = WildfireSystem.new()
	add_child(system)
	system.build(WildfireConfig.new())
	quality.setup(WildfireQualityProfile, "wildfire_quality_profile", _apply_quality)
	quality.restore()

	_grid_config = CellPropagationConfig.new()
	_grid_config.grid_size = WildfireScenery.GRID_SIZE
	_grid_config.cell_size_m = WildfireScenery.CELL_SIZE
	grid = CellPropagation.new()
	_reset_grid()
	_light_fixed_fires()
	flamethrower = WildfireFlamethrower.new()
	add_child(flamethrower)
	flamethrower.setup(grid, muzzle, system)

	hud = WildfireHud.new()
	hud.build(ui_layer)
	menu_builder = WildfireMenu.new()
	menu_builder.build(self)
	set_flamethrower(false)


func _process(delta: float) -> void:
	_frame_ms = delta * 1000.0 if _frame_ms == 0.0 else lerpf(
		_frame_ms, delta * 1000.0, 0.1)
	var heading := Vector2.from_angle(deg_to_rad(wind_angle_deg))
	var strength := wind_strength if wind_enabled else 0.0
	system.set_wind(heading, strength)
	grid.step(delta, heading * strength)
	system.update(delta, player.get_camera().global_position)

	hud.overlay.visible = debug_info
	if debug_info:
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(
			get_viewport().get_viewport_rid())
		_gpu_samples.append(gpu_ms)
		if _gpu_samples.size() > GPU_SAMPLES:
			_gpu_samples.remove_at(0)
		hud.update(_frame_ms, gpu_ms, quality.label(), system, grid)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F:
		set_flamethrower(not flamethrower_firing)


func _on_cell_ignited(cell: Vector2i) -> void:
	var pos := grid.cell_center(cell)
	scenery.place_soot(pos)
	scenery.ignite_pile_near(pos)
	system.add_fire(pos + Vector3(0, 0.15, 0), PRESET_BONFIRE, false)


func _on_cell_burned_out(cell: Vector2i) -> void:
	scenery.place_soot(grid.cell_center(cell))


## The campfire and the torch poles burn from the start; reset re-lights them.
func _light_fixed_fires() -> void:
	system.add_fire(WildfireScenery.HERO_POS + Vector3(0, 0.25, 0), PRESET_CAMPFIRE,
		false)
	for pos in WildfireScenery.TORCHES:
		system.add_fire(pos + Vector3(0, WildfireScenery.TORCH_HEIGHT, 0),
			PRESET_TORCH, false)


func _reset_grid() -> void:
	grid.setup(_grid_config, WildfireScenery.GRID_ORIGIN, 1234)
	grid.cell_ignited.connect(_on_cell_ignited)
	grid.cell_burned_out.connect(_on_cell_burned_out)
	for z in _grid_config.grid_size.y:
		for x in _grid_config.grid_size.x:
			grid.set_cell_material(Vector2i(x, z), CellPropagation.MATERIAL_NONE)
	for zone in scenery.wood_zones():
		_mark_wood(zone)


func _mark_wood(zone: Dictionary) -> void:
	var center: Vector3 = zone["pos"]
	var radius: float = zone["radius"]
	var reach := int(ceil(radius / _grid_config.cell_size_m)) + 1
	var base := grid.world_to_cell(center - Vector3(radius, 0, radius))
	for dy in reach * 2:
		for dx in reach * 2:
			var cell := base + Vector2i(dx, dy)
			var at := grid.cell_center(cell)
			if at.distance_to(center) <= radius:
				grid.set_cell_material(cell, CellPropagation.MATERIAL_WOOD)


# --- capture harness hooks --------------------------------------------------
## Explicit states for capture.sh (preset=N): 0 boot, 1 log pile burning in
## wind, 2 boot with the debug overlay (GPU readout), 3 flamethrower firing, 4 wind only, 5 log pile burning, 6 flamethrower
## holstered after 1 s, 7 flamethrower firing in wind. Ignitions go through
## grid.ignite_at, the same path the flamethrower uses; firing goes through
## set_flamethrower, the same path as the F key and the menu toggle.
func apply_preset(index: int) -> void:
	if index > 0:
		set_debug_info(true)
	if index in [1, 4, 7]:
		wind_enabled = true
		wind_strength = 3.0
	if index in [1, 5]:
		# Every cell of the pile at once: the fire count must not depend on how
		# fast the capture's frames advance the spread.
		for offset in [Vector3(-0.5, 0, -0.5), Vector3(0.5, 0, -0.5),
				Vector3(-0.5, 0, 0.5), Vector3(0.5, 0, 0.5)]:
			grid.ignite_at(WildfireScenery.LOG_PILES[1] + offset, 999.0)
	if index in [3, 6, 7]:
		set_flamethrower(true)
	if index == 6:
		get_tree().create_timer(1.0).timeout.connect(set_flamethrower.bind(false))


## Harness camera poses (capture.sh view=...): presentation only.
func set_capture_view(view: String) -> void:
	if CAPTURE_VIEWS.has(view):
		player.set_pose(CAPTURE_VIEWS[view][0], 0.0, CAPTURE_VIEWS[view][1])


## Median viewport GPU time over the last GPU_SAMPLES frames (debug on).
func capture_metadata(_path: String) -> String:
	var sorted := _gpu_samples.duplicate()
	sorted.sort()
	var median := sorted[sorted.size() / 2] if not sorted.is_empty() else -1.0
	return "CAPTURE META wildfire quality=%s gpu_ms=%.2f samples=%d fires=%d particles=%d" % [
		quality.label(), median, sorted.size(), system.fire_count(), system.live_particles()]


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


## Unbound tier keys; flame_density only lands here before the menu binds it.
func _apply_quality(values: Dictionary) -> void:
	if values.has("flame_density"):
		set_flame_density(values.flame_density)
	system.set_shadow_level(values.shadow_level)
	system.heat_haze = values.heat_haze
	system.set_lit_smoke(values.lit_smoke)
	system.fire_fog = values.fire_fog


# --- menu callbacks ---------------------------------------------------------

func set_wind_enabled(on: bool) -> void:
	wind_enabled = on


func set_wind_angle(value: float) -> void:
	wind_angle_deg = value


func set_wind_strength(value: float) -> void:
	wind_strength = value


func set_flame_density(value: float) -> void:
	system.rate_scale = value


func set_flamethrower(on: bool) -> void:
	flamethrower_firing = on
	weapons.equip(FireWeapons.Kind.FLAMETHROWER if on else FireWeapons.Kind.NONE)
	weapons.set_firing(on)
	flamethrower.set_firing(on)
	if menu_builder != null:
		menu_builder.flamethrower_button.set_pressed_no_signal(on)


func set_debug_info(on: bool) -> void:
	debug_info = on
	viewport_guard.set_measure_render_time(on)
	_gpu_samples.clear()


func reset_simulation() -> void:
	grid.cell_ignited.disconnect(_on_cell_ignited)
	grid.cell_burned_out.disconnect(_on_cell_burned_out)
	system.clear_all()
	scenery.clear_soot()
	scenery.extinguish_piles()
	_reset_grid()
	_light_fixed_fires()
