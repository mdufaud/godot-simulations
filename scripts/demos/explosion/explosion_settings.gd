class_name ExplosionSettings extends RefCounted
## The user-chosen look and force values of the explosion demo. Each value has one owner here;
## [method attach] re-applies them on top of the scene defaults whenever the solver is rebuilt.

const BLAST_FORCE_MIN := 0.85
const BLAST_FORCE_MAX := 2.0
const BLAST_FORCE_STEP := 0.05
## Smoke albedo at darkness 0 and 1; every scene's smoke colour is a point between them.
const ALBEDO_LIGHT := Vector3(0.6, 0.56, 0.5)
const ALBEDO_BLACK := Vector3(0.01, 0.01, 0.01)
## Peak wind per scene, the largest speed that keeps the resident tiles under the pool for a full minute.
const WIND_MAX_MPS: Array[float] = [4.0, 3.0, 6.0]
const WIND_STEP_MPS := 0.5
## Darkness each scene starts at, so the slider shows the albedo the scene really uses.
const DARKNESS_DEFAULTS: Array[float] = [0.6, 0.6, 0.0]
const QUALITY_NAMES := ["Low", "Medium", "High"]
const QUALITY_MEDIUM := 1
## Per level: march step and budget factors on the scene's values, volume at half resolution, global render scale.
const QUALITY_LEVELS: Array[Dictionary] = [
	{step = 1.6, budget = 0.5, half_res = true, render_scale = 0.75},
	{step = 1.0, budget = 1.0, half_res = true, render_scale = 1.0},
	{step = 0.85, budget = 1.5, half_res = true, render_scale = 1.0},
]

var blast_force := 1.0
var darkness := DARKNESS_DEFAULTS[0]
var wind_mps := 0.0
var wind_deg := 0.0
var quality := QUALITY_MEDIUM
var detail := 1.0

## The host's scenery, which turns the albedo into the full smoke lighting.
var scenery: ExplosionScenery

var _darkness_set := false
var _scene_index := 0
var _explosion: ExplosionSystem
var _presentation: FirePresentation
var _guard: ViewportGuard
var _base_step := 0.75
var _base_budget := 320


static func albedo_for(value: float) -> Vector3:
	return ALBEDO_LIGHT.lerp(ALBEDO_BLACK, clampf(value, 0.0, 1.0))


static func wind_vector(speed_mps: float, degrees: float) -> Vector3:
	var angle := deg_to_rad(degrees)
	return Vector3(cos(angle), 0.0, sin(angle)) * speed_mps


static func wind_max(scene: int) -> float:
	return WIND_MAX_MPS[clampi(scene, 0, WIND_MAX_MPS.size() - 1)]


## Rigid bodies only feel the blast in the barrels scene.
static func force_acts(scene: int) -> bool:
	return scene == ExplosionMenu.SCENE_BARRELS


## The preset's billow on a duplicate with [param strength]; 0 turns the effect off.
static func billow_for(base: FireBillowConfig, strength: float) -> FireBillowConfig:
	var billow := base.duplicate() as FireBillowConfig
	billow.strength = clampf(strength, 0.0, 1.0)
	if strength <= 0.0:
		billow.mode = 0
	return billow


## Call after the scene defaults ([method ExplosionScenery.scale_volume]) so the user's values win.
func attach(explosion: ExplosionSystem, presentation: FirePresentation, guard: ViewportGuard, scene: int) -> void:
	_explosion = explosion
	_presentation = presentation
	_guard = guard
	_scene_index = scene
	_base_step = float(presentation.volume_material.get_shader_parameter("march_step"))
	_base_budget = int(presentation.volume_material.get_shader_parameter("march_budget"))
	if not _darkness_set:
		darkness = DARKNESS_DEFAULTS[clampi(scene, 0, DARKNESS_DEFAULTS.size() - 1)]
	apply_force()
	apply_wind()
	apply_quality()
	apply_detail()


func apply_force() -> void:
	if _explosion != null:
		_explosion.blast_force_scale = blast_force


func set_darkness(value: float) -> void:
	darkness = value
	_darkness_set = true
	apply_lighting()


func albedo() -> Vector3:
	return albedo_for(darkness)


## Smoke lighting of the current scene with the albedo (and the ambient that follows it) of the current darkness.
func apply_lighting() -> void:
	if _presentation == null or scenery == null:
		return
	var lighting := scenery.smoke_lighting(albedo())
	for key: String in lighting:
		_presentation.set_volume_parameter(key, lighting[key])


func set_wind_speed(value: float) -> void:
	wind_mps = value
	apply_wind()


func set_wind_direction(value: float) -> void:
	wind_deg = value
	apply_wind()


func set_detail(value: float) -> void:
	detail = value
	apply_detail()


func apply_wind() -> void:
	if _explosion != null:
		_explosion.solver.wind = wind_vector(minf(wind_mps, wind_max(_scene_index)), wind_deg)


func apply_quality() -> void:
	if _presentation == null:
		return
	var level := QUALITY_LEVELS[clampi(quality, 0, QUALITY_LEVELS.size() - 1)]
	_presentation.set_volume_parameter("march_step", _base_step * float(level.step))
	_presentation.set_volume_parameter("march_budget", int(float(_base_budget) * float(level.budget)))
	_presentation.set_half_res(bool(level.half_res))
	if float(level.render_scale) < 1.0:
		_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, float(level.render_scale))
	else:
		_guard.restore_render_scale()


func apply_detail() -> void:
	if _presentation != null:
		var config := _explosion.config
		_presentation.apply_billow(billow_for(config.billow, detail), config.cell_size_m)
