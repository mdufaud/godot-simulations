class_name ExplosionActions extends RefCounted

const CLICK_MAX_DRAG_PX := 6.0
## Engine clock at the 1x label, 1.4 times the original pace; the 0.5x slow-motion step runs at 0.7 times that original pace.
const BASE_PACE := 1.4
## Shown to the user; the engine clock is BASE_PACE times these.
const SLOW_SCALES: Array[float] = [1.0, 0.5, 0.25]
const BARREL_HIT_TOLERANCE_M := 0.2
## Game seconds between two throws, and balls that may be flying at once: stops clicks stacking balls on one spot.
const THROW_COOLDOWN_S := 0.15
const MAX_BALLS_IN_FLIGHT := 16

var paused := false
var slow_index := 0

var shake := ExplosionCameraShake.new()

var _press_position := Vector2.ZERO
var _pressed := false
var _touches := {}
var _cooldown_s := 0.0


static func make_launcher(camera: Camera3D, container: Node3D) -> ProjectileLauncher:
	var launcher := ProjectileLauncher.new()
	launcher.camera = camera
	launcher.container = container
	launcher.report_every_contact = true
	launcher.fired.connect(ExplosionFireball.attach)
	return launcher


static func barrel_ball(fireball: ProjectilePreset) -> ProjectilePreset:
	var ball := fireball.duplicate() as ProjectilePreset
	ball.explodes = false
	return ball


static func is_click(press: Vector2, release: Vector2) -> bool:
	return press.distance_to(release) <= CLICK_MAX_DRAG_PX


static func clamp_time_scale(value: float) -> float:
	return clampf(value, 0.0, BASE_PACE)


## Ground point under [param screen_position], kept inside [param limit_m] of the origin.
static func aim_point(camera: Camera3D, screen_position: Vector2, limit_m: float) -> Vector3:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	var flat := Vector2(origin.x, origin.z)
	if direction.y < -1e-4:
		flat += Vector2(direction.x, direction.z) * (origin.y / -direction.y)
	else:
		flat += Vector2(direction.x, direction.z).normalized() * limit_m
	flat = flat.limit_length(limit_m)
	return Vector3(flat.x, 0.0, flat.y)


## [param base] scaled in radius on a duplicate; the preloaded preset is shared process-wide.
static func scaled_charge(base: ExplosionCharge, scale: float, soot_fraction: float = -1.0) -> ExplosionCharge:
	var charge := base.duplicate() as ExplosionCharge
	charge.radius_m *= scale
	if soot_fraction >= 0.0:
		charge.soot_fraction = soot_fraction
	var link := charge
	for i in ExplosionCharge.MAX_COMPANIONS:
		if link.companion == null:
			break
		link.companion = link.companion.duplicate() as ExplosionCharge
		link = link.companion
		link.radius_m *= scale
		link.sink_m *= scale
		link.front_ring_width_m *= scale
		link.front_ring_height_m *= scale
		link.afterwind_radius_m *= scale
		link.afterwind_height_m *= scale
	return charge


## True when a ball centred at [param point] touches the barrel's axis segment within [param reach_m].
static func barrel_touched(barrel_position: Vector3, barrel_axis: Vector3, point: Vector3, reach_m: float) -> bool:
	var half := barrel_axis.normalized() * ExplosiveBarrel.HEIGHT_M * 0.5
	var segment := Geometry3D.get_closest_point_to_segment(point, barrel_position - half, barrel_position + half)
	return segment.distance_to(point) <= ExplosiveBarrel.RADIUS_M + reach_m


## Tracks the live fingers; true for the mouse events a finger emulates, which must not throw twice (orbit_camera.gd does the same).
func is_emulated_mouse(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touches[touch.index] = true
		else:
			_touches.erase(touch.index)
	return not _touches.is_empty() and (event is InputEventMouseButton or event is InputEventMouseMotion)


## Feeds left-button events; true on the release that ends a press that never travelled.
func left_click(event: InputEventMouseButton) -> bool:
	if event.pressed:
		_press_position = event.position
		_pressed = true
		return false
	var clicked := _pressed and is_click(_press_position, event.position)
	_pressed = false
	return clicked


func tick(delta: float) -> void:
	_cooldown_s = maxf(_cooldown_s - delta, 0.0)
	shake.update(delta)


## True, and the cooldown starts, when a ball may be thrown with [param flying] balls already in the air.
func allow_throw(flying: int) -> bool:
	if _cooldown_s > 0.0 or flying >= MAX_BALLS_IN_FLIGHT:
		return false
	_cooldown_s = THROW_COOLDOWN_S
	return true


func reset() -> void:
	_cooldown_s = 0.0
	shake.stop()


func time_scale() -> float:
	return 0.0 if paused else BASE_PACE * SLOW_SCALES[slow_index]


func set_paused(on: bool) -> void:
	paused = on
	apply_clock()


func cycle_slow() -> float:
	slow_index = (slow_index + 1) % SLOW_SCALES.size()
	apply_clock()
	return SLOW_SCALES[slow_index]


## Engine.time_scale is the one clock: frame deltas, fuses, tweens, particles and the solver's step budget all follow it.
## Jolt ticks stretch by the scale, so the tick rate rises with it to keep each step at 1/60 s of game time.
func apply_clock() -> void:
	var scale := clamp_time_scale(time_scale())
	Engine.time_scale = scale
	Engine.physics_ticks_per_second = int(roundf(default_tick_rate() * maxf(scale, 1.0)))


static func started() -> ExplosionActions:
	var actions := ExplosionActions.new()
	actions.apply_clock()
	return actions


static func default_tick_rate() -> float:
	return float(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60))


static func restore_clock() -> void:
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = int(default_tick_rate())
