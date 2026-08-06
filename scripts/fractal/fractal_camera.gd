class_name FractalCamera extends RefCounted
## Float64 view of the complex plane: where we look, how far in, and how many
## iterations that depth needs.
##
## Coordinates are NEVER stored in a [Vector2] (float32) — always separate
## float64 scalars, which is what makes the deep zoom hold together.
##
## [codeblock]
## var camera := FractalCamera.new()
## camera.viewport_size = size
## camera.zoom_at(FractalCamera.ZOOM_STEP, get_local_mouse_position(), true)
## camera.update_motion(delta)
## [/codeblock]

const LN10 := 2.302585092994046
## Half-height of the view, in complex units, at zoom 1.
const VIEW_BASE := 1.75
const ZOOM_STEP := 0.22314355131  # ln(1.25)
const ZOOM_SMOOTHING := 12.0

var fractal_type := 0
var center_x := -0.6
var center_y := 0.0
var log_zoom := 0.0
## Where [member log_zoom] is easing to.
var target_log_zoom := 0.0
var viewport_size := Vector2(1.0, 1.0)
var auto_iterations := true
var manual_iterations := 2000

# Point under the cursor, held fixed while the zoom eases.
var _anchor_active := false
var _anchor_wx := 0.0
var _anchor_wy := 0.0
var _anchor_u := 0.5
var _anchor_v := 0.5


## Zoom that shows the whole set, the resting point of a reset.
static func overview_log_zoom() -> float:
	return log(0.8)


func zoom() -> float:
	return exp(log_zoom)


func view_half() -> float:
	return VIEW_BASE / zoom()


func aspect() -> float:
	return viewport_size.x / viewport_size.y


## Width of the view in complex units.
func span_x() -> float:
	return 2.0 * view_half() * aspect()


func world_x_at(u: float) -> float:
	return center_x + (u - 0.5) * span_x()


func world_y_at(v: float) -> float:
	return center_y + (v - 0.5) * 2.0 * view_half()


func min_log_zoom() -> float:
	return log(0.3)


func max_log_zoom() -> float:
	match fractal_type:
		0: return log(1.0e13)
		1: return log(1.0e10)
		_: return log(1.0e4)


func iterations_full() -> int:
	if not auto_iterations:
		return manual_iterations
	var lz10 := maxf(log_zoom / LN10, 0.0)
	return clampi(int(100.0 * pow(lz10 + 1.0, 1.6)), 128, 20000)


## Content follows the cursor 1:1.
func pan_by(pixels: Vector2) -> void:
	var per_px := 2.0 * view_half() / viewport_size.y
	center_x -= pixels.x * per_px
	center_y -= pixels.y * per_px
	_anchor_active = false


## [param anchored] keeps the point under [param position] fixed while the zoom
## eases; the autopilot drives its own centring instead and passes false.
func zoom_at(delta_log: float, position: Vector2, anchored: bool) -> void:
	var u := position.x / viewport_size.x
	var v := position.y / viewport_size.y
	_anchor_wx = world_x_at(u)
	_anchor_wy = world_y_at(v)
	_anchor_u = u
	_anchor_v = v
	_anchor_active = anchored
	target_log_zoom = clampf(target_log_zoom + delta_log, min_log_zoom(), max_log_zoom())


func clear_anchor() -> void:
	_anchor_active = false


func update_motion(delta: float) -> void:
	if absf(target_log_zoom - log_zoom) < 1e-9:
		return
	var s := 1.0 - exp(-ZOOM_SMOOTHING * delta)
	log_zoom = lerpf(log_zoom, target_log_zoom, s)
	if absf(target_log_zoom - log_zoom) < 1e-4:
		log_zoom = target_log_zoom
	if _anchor_active:
		var half := view_half()
		center_x = _anchor_wx - (_anchor_u - 0.5) * 2.0 * half * aspect()
		center_y = _anchor_wy - (_anchor_v - 0.5) * 2.0 * half
		if log_zoom == target_log_zoom:
			_anchor_active = false


## Back to the overview framing that suits the current fractal type.
func reset_for_type() -> void:
	match fractal_type:
		1:
			center_x = 0.0
			center_y = 0.0
		2:
			center_x = -1.72
			center_y = -0.04
		3:
			center_x = 0.0
			center_y = 0.0
		_:
			center_x = -0.6
			center_y = 0.0
	log_zoom = overview_log_zoom()
	target_log_zoom = log_zoom
	_anchor_active = false
