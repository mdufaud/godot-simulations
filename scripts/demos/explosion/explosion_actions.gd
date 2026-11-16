class_name ExplosionActions extends RefCounted

const CLICK_MAX_DRAG_PX := 6.0
## Never above 1: the solver's tile band bounds the field's travel per frame.
const SLOW_SCALES: Array[float] = [1.0, 0.5, 0.25]
const BARREL_HIT_TOLERANCE_M := 0.2

var paused := false
var slow_index := 0

var _press_position := Vector2.ZERO
var _pressed := false
var _touches := {}


static func is_click(press: Vector2, release: Vector2) -> bool:
	return press.distance_to(release) <= CLICK_MAX_DRAG_PX


static func clamp_time_scale(value: float) -> float:
	return clampf(value, 0.0, 1.0)


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
	if charge.companion != null:
		charge.companion = charge.companion.duplicate() as ExplosionCharge
		charge.companion.radius_m *= scale
		charge.companion.sink_m *= scale
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


func time_scale() -> float:
	return 0.0 if paused else SLOW_SCALES[slow_index]


func set_paused(on: bool) -> void:
	paused = on
	apply_clock()


func cycle_slow() -> float:
	slow_index = (slow_index + 1) % SLOW_SCALES.size()
	apply_clock()
	return SLOW_SCALES[slow_index]


## Engine.time_scale is the one clock: frame deltas, fuses, tweens, particles and the solver's step budget all follow it.
func apply_clock() -> void:
	Engine.time_scale = clamp_time_scale(time_scale())


static func restore_clock() -> void:
	Engine.time_scale = 1.0
