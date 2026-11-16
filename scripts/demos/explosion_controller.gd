extends Node3D

const RANGE_CONFIG := preload("res://resources/explosion/presets/range.tres")
const FIREBALL_RANGE_CONFIG := preload("res://resources/explosion/presets/fireball_range.tres")
const MUSHROOM_CONFIG := preload("res://resources/explosion/presets/mushroom.tres")
const NUKE_CHARGE := preload("res://resources/explosion/presets/nuke_charge.tres")
## Cell size the raymarcher's metre constants were tuned at.
const REFERENCE_CELL_M := 0.2
const FIREBALL_CHARGE := preload("res://resources/explosion/presets/fireball_charge.tres")
const FIREBALL_PROJECTILE := preload("res://resources/explosion/presets/fireball_projectile.tres")
## Centre height of the ground charge in radii: half of the sphere is clipped by the ground.
const HALF_BURIED := 0.5
const CAPTURE_POINT := Vector3(0.0, 1.4, 0.0)

@onready var fire_volume: MeshInstance3D = $FireVolume
@onready var fire_light: OmniLight3D = $FireLight
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var ground: Node3D = $Ground/Mesh
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var projectile_root: Node3D = $Projectiles
@onready var menu: SimMenu = $UI/SimMenu
@onready var ui_layer: CanvasLayer = $UI
@onready var viewport_guard := ViewportGuard.attach(self)

var explosion: ExplosionSystem
var presentation: FirePresentation
var launcher := ProjectileLauncher.new()
var scene_index := 0
var charge_scale := 1.0

var _capture := ExplosionCapture.new()
var _fx := ExplosionFx.new()
var _scenery := ExplosionScenery.new()
var _menu_builder := ExplosionMenu.new()
var _capture_pending := false
var _peak_tiles := 0


func _ready() -> void:
	_menu_builder.build(menu, self)
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return
	add_child(_fx)
	_scenery.world_env = world_env
	_scenery.sun = sun
	_scenery.ground = ground
	if not _build_simulation(_config_for(0)):
		return
	launcher.camera = camera
	launcher.container = projectile_root
	launcher.impact.connect(_on_impact)
	launcher.arm(FIREBALL_PROJECTILE)
	set_scene(0)


func _process(delta: float) -> void:
	if presentation == null:
		return
	presentation.update_volume()
	presentation.update_half_res()
	presentation.update_effects(explosion.solver.get_stats(), delta)
	_peak_tiles = maxi(_peak_tiles, int(explosion.solver.get_debug_pool_stats().get("resident", 0)))


func _physics_process(_delta: float) -> void:
	if presentation != null:
		launcher.despawn_fallen()


func _exit_tree() -> void:
	if presentation != null:
		presentation.release()
		explosion.stop()


func _unhandled_input(event: InputEvent) -> void:
	if presentation != null and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_throw_at(event.position)


func set_scene(index: int) -> void:
	if explosion == null:
		return
	scene_index = clampi(index, 0, ExplosionMenu.SCENES.size() - 1)
	if _config_for(scene_index) != explosion.config and not _build_simulation(_config_for(scene_index)):
		return
	_limit_charge_scale()
	ExplosionScenery.apply_framing(orbit_cam, camera, scene_index)
	_menu_builder.scene_option.select(scene_index)
	reset_simulation()


func reset_simulation() -> void:
	if presentation == null:
		return
	launcher.clear()
	_fx.clear()
	explosion.reset()
	_scenery.build(self, scene_index, explosion)
	var lighting := _scenery.smoke_lighting(scene_index, _metric_scale(explosion.config))
	for key: String in lighting:
		presentation.set_volume_parameter(key, lighting[key])


func detonate_barrel() -> void:
	if presentation != null:
		_scenery.detonate_first()


func throw_ball() -> void:
	if presentation != null:
		_throw_at(get_viewport().get_visible_rect().size * 0.5)


func set_charge_scale(value: float) -> void:
	charge_scale = value


func _config_for(index: int) -> ExplosionConfig:
	if index == ExplosionMenu.SCENE_MUSHROOM:
		return MUSHROOM_CONFIG
	return RANGE_CONFIG if index == ExplosionMenu.SCENE_BARRELS else FIREBALL_RANGE_CONFIG


## Metre constants only grow with coarse cells; a finer grid resolves the same picture.
func _metric_scale(config: ExplosionConfig) -> float:
	return maxf(config.cell_size_m / REFERENCE_CELL_M, 1.0)


func _base_charge() -> ExplosionCharge:
	return NUKE_CHARGE if scene_index == ExplosionMenu.SCENE_MUSHROOM else FIREBALL_CHARGE


## The slider stops at the largest step the system still accepts, so the UI cannot ask for a refused charge.
func _limit_charge_scale() -> void:
	var limit := minf(ExplosionMenu.CHARGE_SCALE_MAX, explosion.max_charge_scale(_base_charge()))
	var slider := _menu_builder.charge_slider
	slider.max_value = maxf(floorf(limit / slider.step) * slider.step, slider.min_value)
	charge_scale = minf(charge_scale, slider.max_value)


func _throw_at(screen_position: Vector2) -> void:
	if scene_index == ExplosionMenu.SCENE_MUSHROOM:
		explosion.detonate(_ground_zero(), _charge())
	else:
		launcher.fire(screen_position)


func _ground_zero() -> Vector3:
	return Vector3(0.0, _charge().radius_m * HALF_BURIED, 0.0)


func _charge() -> ExplosionCharge:
	var charge := _base_charge().duplicate() as ExplosionCharge
	charge.radius_m *= charge_scale
	if _capture.soot_fraction >= 0.0:
		charge.soot_fraction = _capture.soot_fraction
	if charge.companion != null:
		charge.companion = charge.companion.duplicate() as ExplosionCharge
		charge.companion.radius_m *= charge_scale
		charge.companion.sink_m *= charge_scale
	return charge


## Rebuilds the solver and its presentation: the cell size is fixed per instance.
func _build_simulation(config: ExplosionConfig) -> bool:
	if presentation != null:
		presentation.release()
		presentation.queue_free()
		explosion.stop()
		explosion.queue_free()
	presentation = null
	explosion = ExplosionSystem.new()
	explosion.config = config
	add_child(explosion)
	explosion.start()
	if not explosion.solver:
		return false
	var metric_scale := _metric_scale(config)
	presentation = FirePresentation.new()
	presentation.solver = explosion.solver
	presentation.fire_volume = fire_volume
	presentation.camera = camera
	presentation.fire_light = fire_light
	presentation.proxy_margin_m *= metric_scale
	presentation.smoke_light_gain = 0.06 if metric_scale <= 1.0 else 0.0
	add_child(presentation)
	presentation.start()
	presentation.set_half_res(true)
	presentation.refresh_temporal_blend()
	ExplosionScenery.scale_volume(presentation, metric_scale, config)
	explosion.detonated.connect(_on_detonated)
	explosion.detonated.connect(_fx.on_detonated)
	return true


func _on_impact(origin: Vector3, _radius_m: float, _impulse: float) -> void:
	var charge := _charge()
	origin.y = maxf(origin.y, charge.radius_m)
	explosion.detonate(origin, charge)


func _on_detonated(origin: Vector3, _detonation_charge: ExplosionCharge) -> void:
	fire_light.position = origin


func capture_ready() -> bool:
	return presentation != null and explosion.solver.initialized and presentation.texture_bound


func set_capture_scene(index: int) -> void:
	set_scene(index)
	_capture_pending = true


func set_capture_params(values: Dictionary) -> void:
	_capture.apply(self, values)


func set_frozen(on: bool) -> void:
	if explosion == null:
		return
	explosion.set_process(not on)
	if not on and _capture_pending:
		_capture_pending = false
		if scene_index == ExplosionMenu.SCENE_BARRELS:
			_scenery.detonate_first()
		else:
			explosion.detonate(_ground_zero() if scene_index == ExplosionMenu.SCENE_MUSHROOM else CAPTURE_POINT, _charge())


func set_capture_fixed_delta(value: float) -> void:
	if explosion != null:
		explosion.fixed_delta_s = value


func set_capture_ui(visible_ui: bool) -> void:
	ui_layer.visible = visible_ui


func capture_metadata(path: String) -> String:
	return ExplosionCapture.metadata(explosion.solver, _peak_tiles, path)
