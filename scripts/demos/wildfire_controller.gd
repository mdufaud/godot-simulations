extends Node3D
## Wildfire Demo Controller — the RDR2-model game fire scene.
##
## A CPU cell grid (Far Cry 2 propagation rules) decides where fire spreads;
## every ignited cell spawns a pooled flipbook fire in FireBillboardSystem, so a
## burning hillside costs a fraction of a millisecond instead of a volumetric
## solve. The hero campfire runs both renderers — the billboard atlas and the
## full Fire-X solver — and the menu toggles between them for a side-by-side
## cost readout in the HUD.

const FLAME_ATLAS := preload("res://resources/game_fire/atlases/flame_atlas.png")
const SMOKE_ATLAS := preload("res://resources/game_fire/atlases/smoke_atlas.png")
const PRESET_TORCH := preload("res://resources/game_fire/presets/torch.tres")
const PRESET_CAMPFIRE := preload("res://resources/game_fire/presets/campfire.tres")
const PRESET_BONFIRE := preload("res://resources/game_fire/presets/bonfire.tres")
const PRESET_GRASS := preload("res://resources/game_fire/presets/grass.tres")

## Flame damage per second while the flamethrower beam holds a cell.
const FLAMETHROWER_DAMAGE := 90.0
const FLAMETHROWER_REACH := 14.0

@onready var player: FpsWalker = $Player
@onready var weapons: FireWeapons = $Player/Camera3D/Weapons
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI
@onready var scenery: FireGameScenery = $Scenery
@onready var viewport_guard := ViewportGuard.attach(self)

var debug_info := false
var system: FireBillboardSystem
var grid: CellPropagation
var hud: FireGameHud
var menu_builder: FireGameMenu
var hero: HeroFire
var hero_available := false
var hero_starting := false
var hero_mode := 0
var hero_billboard_id := -1

var wind_enabled := false
var wind_angle := deg_to_rad(25.0)
var wind_strength := 2.5

var flamethrower_firing := false

var _frame_ms := 0.0
var _fire_by_cell := {}
var _grid_config: CellPropagationConfig


func _ready() -> void:
	var game_config := GameFireConfig.new()
	system = FireBillboardSystem.new()
	add_child(system)
	system.build(game_config, FLAME_ATLAS, SMOKE_ATLAS)

	_grid_config = CellPropagationConfig.new()
	_grid_config.grid_size = FireGameScenery.GRID_SIZE
	_grid_config.cell_size_m = FireGameScenery.CELL_SIZE
	grid = CellPropagation.new()
	_reset_grid()

	hero = HeroFire.new()
	hero.position = FireGameScenery.HERO_POS
	add_child(hero)
	# The Fire-X solver's init (shader compile + pool alloc) only happens when
	# the player actually switches to it — the billboard boot path stays cheap.
	hero.active = false
	_light_torches()
	hero_billboard_id = system.add_fire(
		FireGameScenery.HERO_POS + Vector3(0, 0.25, 0), PRESET_CAMPFIRE, false)
	system.set_target(hero_billboard_id, 1.0)

	hud = FireGameHud.new()
	hud.build(ui_layer)
	menu_builder = FireGameMenu.new()
	menu_builder.build(self)
	set_flamethrower(false)


func _process(delta: float) -> void:
	_frame_ms = delta * 1000.0 if _frame_ms == 0.0 else lerpf(
		_frame_ms, delta * 1000.0, 0.1)
	var wind_xz := Vector2.ZERO
	if wind_enabled:
		var heading := Vector2(cos(wind_angle), sin(wind_angle))
		wind_xz = heading * wind_strength
		system.set_wind(heading, wind_strength)
		grid.step(delta, wind_xz)
		if hero != null:
			hero.wind_enabled = true
			hero.wind = Vector3(wind_xz.x, 0.0, wind_xz.y)
	else:
		grid.step(delta, Vector2.ZERO)
		if hero != null:
			hero.wind_enabled = false

	system.update(delta, player.get_camera().global_position)

	var hero_ms := 0.0
	if hero != null and hero_available:
		hero.active = hero_mode == 1
		hero.update_fire(delta)
		if hero_mode == 1:
			var timings := hero.solver.get_timings()
			hero_ms = float(timings.get("total", 0.0))
	if hero_billboard_id > 0:
		system.set_target(hero_billboard_id,
			1.0 if hero_mode == 0 or not hero_available else 0.0)

	if flamethrower_firing:
		_flamethrower_beam(delta)

	hud.overlay.visible = debug_info
	if debug_info:
		hud.update(_frame_ms, system, grid, "billboard" if hero_mode == 0
			else "fire-x", hero_mode == 0 or (hero_mode == 1 and hero_available),
			hero_ms)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not (event as InputEventKey).echo:
		match (event as InputEventKey).keycode:
			KEY_T:
				set_hero_mode(1 - hero_mode)
			KEY_F:
				set_flamethrower(not flamethrower_firing)


## Ray from the camera; the cell under the hit takes beam damage every frame.
func _flamethrower_beam(delta: float) -> void:
	var camera := player.get_camera()
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * FLAMETHROWER_REACH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		grid.ignite_at(hit.position, FLAMETHROWER_DAMAGE * delta)


func _on_cell_ignited(cell: Vector2i) -> void:
	var wood := _is_wood_cell(cell)
	var pos := grid.cell_center(cell)
	scenery.place_soot(pos)
	var preset := PRESET_BONFIRE if wood else PRESET_GRASS
	_fire_by_cell[cell] = system.add_fire(pos + Vector3(0, 0.15, 0), preset,
		not wood)


func _on_cell_burned_out(cell: Vector2i) -> void:
	var id: int = _fire_by_cell.get(cell, -1)
	if id > 0 and not _is_wood_cell(cell):
		system.set_target(id, 0.0)
		_fire_by_cell.erase(cell)
	scenery.place_soot(grid.cell_center(cell))


func _is_wood_cell(cell: Vector2i) -> bool:
	return _wood_indices.has(grid.index_of(cell))


var _wood_indices := {}


## The torch poles burn from the start; reset_simulation re-lights them.
func _light_torches() -> void:
	for pos in FireGameScenery.TORCHES:
		system.add_fire(pos + Vector3(0, FireGameScenery.TORCH_HEIGHT, 0),
			PRESET_TORCH, false)


func _reset_grid() -> void:
	grid.setup(_grid_config, FireGameScenery.GRID_ORIGIN, 1234)
	grid.cell_ignited.connect(_on_cell_ignited)
	grid.cell_burned_out.connect(_on_cell_burned_out)
	_wood_indices.clear()
	for zone in scenery.wood_zones():
		_mark_zone(zone, CellPropagation.MATERIAL_WOOD)
	for zone in scenery.inert_zones():
		_mark_zone(zone, CellPropagation.MATERIAL_NONE)


func _mark_zone(zone: Dictionary, material: int) -> void:
	var center: Vector3 = zone["pos"]
	var radius: float = zone["radius"]
	var reach := int(ceil(radius / _grid_config.cell_size_m)) + 1
	var base := grid.world_to_cell(center - Vector3(radius, 0, radius))
	for dy in reach * 2:
		for dx in reach * 2:
			var cell := base + Vector2i(dx, dy)
			var at := grid.cell_center(cell)
			if at.distance_to(center) <= radius:
				grid.set_cell_material(cell, material)


func _apply_wind_state() -> void:
	if not wind_enabled:
		system.set_wind(Vector2.RIGHT, 0.0)


# --- capture harness hooks --------------------------------------------------
## capture.sh waits on this before shooting: true while nothing Fire-X is in
## flight, false while the deferred hero solver start is initializing.
func capture_ready() -> bool:
	if hero_starting:
		return false
	return hero == null or not hero_available \
		or (hero.solver != null and hero.solver.initialized)


## Explicit states for capture.sh (preset=N): 0 boot, 1 wildfire front with
## wind, 2 Fire-X hero mode, 3 flamethrower firing. Ignitions go through
## grid.ignite_at, the same path the runtime beam uses; the flamethrower goes
## through set_flamethrower, the same path as the F key and the menu toggle.
func apply_preset(index: int) -> void:
	if index > 0:
		debug_info = true
	match index:
		1:
			wind_enabled = true
			wind_angle = deg_to_rad(25.0)
			wind_strength = 3.0
			for i in 11:
				grid.ignite_at(Vector3(-7.5 + i * 1.5, 0.0, -1.5), 999.0)
		2:
			set_hero_mode(1)
		3:
			set_flamethrower(true)


## Harness camera poses (capture.sh view=...): presentation only.
func set_capture_view(view: String) -> void:
	if view == "close":
		player.position = FireGameScenery.HERO_POS + Vector3(0.3, 0.0, 2.7)
		player.yaw = 0.0
		player.pitch = -6.0


# --- menu callbacks ---------------------------------------------------------

func set_wind_enabled(on: bool) -> void:
	wind_enabled = on
	_apply_wind_state()


func set_wind_angle(value: float) -> void:
	wind_angle = deg_to_rad(value)


func set_wind_strength(value: float) -> void:
	wind_strength = value


func set_spread_budget(value: float) -> void:
	grid.points_left = int(value)


func set_flame_density(value: float) -> void:
	system.rate_scale = value


func set_hero_mode(index: int) -> void:
	if index == 1 and not hero_available and not hero_starting:
		hero_starting = true
		hero_available = await hero.start()
		hero_starting = false
	hero_mode = index if hero_available else 0


func set_flamethrower(on: bool) -> void:
	flamethrower_firing = on
	weapons.equip(FireWeapons.Kind.FLAMETHROWER if on else FireWeapons.Kind.NONE)
	weapons.set_firing(on)


func set_debug_info(on: bool) -> void:
	debug_info = on


func reset_simulation() -> void:
	grid.cell_ignited.disconnect(_on_cell_ignited)
	grid.cell_burned_out.disconnect(_on_cell_burned_out)
	system.clear_all()
	scenery.clear_soot()
	_fire_by_cell.clear()
	_reset_grid()
	_light_torches()
	hero_billboard_id = system.add_fire(
		FireGameScenery.HERO_POS + Vector3(0, 0.25, 0), PRESET_CAMPFIRE, false)
