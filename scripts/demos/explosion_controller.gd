extends Node3D

const FIREBALL_PROJECTILE := preload("res://resources/explosion/presets/fireball_projectile.tres")
## Centre height of the mushroom charge in radii: an air burst, the fireball clears the ground.
const BURST_HEIGHT := 1.5
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
var _actions := ExplosionActions.new()
var _barrel_ball := FIREBALL_PROJECTILE.duplicate() as ProjectilePreset
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
	_scenery.bind(world_env, sun, ground, orbit_cam, camera, fire_volume)
	_menu_builder.settings.scenery = _scenery
	if not _build_simulation(ExplosionScenery.config_for(0)):
		return
	launcher.camera = camera
	launcher.container = projectile_root
	launcher.report_every_contact = true
	launcher.impact.connect(_on_impact)
	_barrel_ball.explodes = false
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
	ExplosionActions.restore_clock()
	if presentation != null:
		presentation.release()
		explosion.stop()


func _unhandled_input(event: InputEvent) -> void:
	if presentation == null or _actions.is_emulated_mouse(event) or not event is InputEventMouseButton:
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_throw_at(event.position)
	elif event.button_index == MOUSE_BUTTON_LEFT and _actions.left_click(event):
		_throw_at(event.position)


func set_scene(index: int) -> void:
	if explosion == null:
		return
	scene_index = clampi(index, 0, ExplosionMenu.SCENES.size() - 1)
	if ExplosionScenery.config_for(scene_index) != explosion.config and not _build_simulation(ExplosionScenery.config_for(scene_index)):
		return
	_limit_charge_scale()
	_menu_builder.show_scene(scene_index)
	launcher.arm(_barrel_ball if scene_index == ExplosionMenu.SCENE_BARRELS else FIREBALL_PROJECTILE)
	reset_simulation()


func reset_simulation() -> void:
	if presentation == null:
		return
	launcher.clear()
	_clear_effects()
	explosion.reset()
	ExplosionScenery.apply_framing(orbit_cam, camera, scene_index)
	_scenery.build(self, scene_index, explosion)
	_menu_builder.settings.apply_lighting()
	_sync_barrel_charge()


func detonate_scene() -> void:
	if presentation == null:
		return
	if scene_index == ExplosionMenu.SCENE_BARRELS:
		_scenery.detonate_first()
	elif scene_index == ExplosionMenu.SCENE_MUSHROOM:
		explosion.detonate(_ground_zero(), _charge())
	else:
		var origin := ExplosionActions.aim_point(camera, get_viewport().get_visible_rect().size * 0.5,
			ExplosionScenery.POST_RING_M)
		origin.y = _charge().radius_m
		launcher.flash(origin)
		explosion.detonate(origin, _charge())


func clear_smoke() -> void:
	if presentation != null:
		explosion.clear_smoke()
		_clear_effects()


func _clear_effects() -> void:
	_fx.clear()
	_scenery.clear_effects()
	presentation.reset_light()


func set_paused(on: bool) -> void:
	_actions.set_paused(on)


func cycle_slow() -> void:
	_menu_builder.set_slow_label(_actions.cycle_slow())


func throw_ball() -> void:
	if presentation != null:
		_throw_at(get_viewport().get_visible_rect().size * 0.5)


func set_charge_scale(value: float) -> void:
	charge_scale = value
	_sync_barrel_charge()


func _sync_barrel_charge() -> void:
	if scene_index == ExplosionMenu.SCENE_BARRELS:
		_scenery.set_barrel_charge(_charge())


## The slider stops at the largest step the system still accepts, so the UI cannot ask for a refused charge.
func _limit_charge_scale() -> void:
	var limit := minf(ExplosionMenu.charge_scale_max(scene_index), explosion.max_charge_scale(ExplosionScenery.base_charge(scene_index)))
	var slider := _menu_builder.charge_slider
	slider.max_value = maxf(floorf(limit / slider.step) * slider.step, slider.min_value)
	charge_scale = minf(charge_scale, slider.max_value)


func _throw_at(screen_position: Vector2) -> void:
	if scene_index == ExplosionMenu.SCENE_MUSHROOM:
		explosion.detonate(_ground_zero(), _charge())
	else:
		launcher.fire(screen_position)


func _ground_zero() -> Vector3:
	return Vector3(0.0, _charge().radius_m * BURST_HEIGHT, 0.0)


func _charge() -> ExplosionCharge:
	return ExplosionActions.scaled_charge(ExplosionScenery.base_charge(scene_index), charge_scale, _capture.soot_fraction)


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
	var metric_scale := ExplosionScenery.metric_scale(config)
	presentation = ExplosionScenery.make_presentation(explosion.solver, fire_volume, camera, fire_light, metric_scale)
	add_child(presentation)
	presentation.start()
	presentation.refresh_temporal_blend()
	ExplosionScenery.scale_volume(presentation, metric_scale, config)
	_menu_builder.settings.attach(explosion, presentation, viewport_guard, scene_index)
	_fx.attach(explosion, fire_light)
	return true


func _on_impact(origin: Vector3, _radius_m: float, _impulse: float) -> void:
	if scene_index == ExplosionMenu.SCENE_BARRELS:
		_scenery.detonate_touching(origin, FIREBALL_PROJECTILE.radius_m + ExplosionActions.BARREL_HIT_TOLERANCE_M)
		return
	var charge := _charge()
	origin.y = maxf(origin.y, charge.radius_m)
	explosion.detonate(origin, charge)


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
