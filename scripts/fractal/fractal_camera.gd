class_name FractalCamera extends RefCounted
## Double-double view of the complex plane: where we look, how far in, and how
## many iterations that depth needs.
##
## Coordinates are NEVER stored in a [Vector2] (float32) — always separate
## float64 scalars. The centre is a double-double (a float64 plus the float64
## rounding error it left behind, ~31 significant digits), which is what lets
## the zoom go past the 1e13 a lone float64 allows. [member center_x] and
## [member center_y] are its leading words: read them freely; writing one
## drops the low word.
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
## Deepest zoom the double-double centre and reference orbit resolve.
const MAX_ZOOM := 1.0e25
const MIN_ITERATIONS := 128
## Bound of the shader loop and of the two-channel mu encoding.
const MAX_ITERATIONS := 30000

var fractal_type := 0
var center_x := -0.6:
	set(value):
		center_x = value
		center_x_lo = 0.0
var center_y := 0.0:
	set(value):
		center_y = value
		center_y_lo = 0.0
## Low words of the centre, each under half an ulp of its leading word.
var center_x_lo := 0.0
var center_y_lo := 0.0
var log_zoom := 0.0
## Where [member log_zoom] is easing to.
var target_log_zoom := 0.0
var viewport_size := Vector2(1.0, 1.0)
var auto_iterations := true
var manual_iterations := 2000
## Factor the view asks on top of the zoom-based count when the picture shows
## orbits still escaping near it (see FractalView). Never under 1.
var iteration_boost := 1.0

# Point under the cursor, held fixed while the zoom eases (double-double).
var _anchor_active := false
var _anchor_wx := 0.0
var _anchor_wx_lo := 0.0
var _anchor_wy := 0.0
var _anchor_wy_lo := 0.0
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
	return log(MAX_ZOOM)


## Iterations the zoom depth alone calls for.
func iterations_for_zoom() -> int:
	var lz10 := maxf(log_zoom / LN10, 0.0)
	return clampi(int(100.0 * pow(lz10 + 1.0, 1.6)), MIN_ITERATIONS, 20000)


func iterations_full() -> int:
	if not auto_iterations:
		return manual_iterations
	return clampi(int(float(iterations_for_zoom()) * maxf(iteration_boost, 1.0)),
		MIN_ITERATIONS, MAX_ITERATIONS)


## Moves the centre by a float64 offset, keeping the low words.
func offset_center(dx: float, dy: float) -> void:
	var x := FractalDD.add(center_x, center_x_lo, dx, 0.0)
	var y := FractalDD.add(center_y, center_y_lo, dy, 0.0)
	_set_center(x[0], x[1], y[0], y[1])


## Centre minus the double-double point (x, y): exact enough at any depth as
## long as the two are within a few views of each other.
func center_delta_x(x: float, x_lo: float) -> float:
	return (center_x - x) + (center_x_lo - x_lo)


func center_delta_y(y: float, y_lo: float) -> float:
	return (center_y - y) + (center_y_lo - y_lo)


## Content follows the cursor 1:1.
func pan_by(pixels: Vector2) -> void:
	var per_px := 2.0 * view_half() / viewport_size.y
	offset_center(-pixels.x * per_px, -pixels.y * per_px)
	_anchor_active = false


## [param anchored] keeps the point under [param position] fixed while the zoom
## eases; the autopilot drives its own centring instead and passes false.
func zoom_at(delta_log: float, position: Vector2, anchored: bool) -> void:
	var u := position.x / viewport_size.x
	var v := position.y / viewport_size.y
	var wx := FractalDD.add(center_x, center_x_lo, (u - 0.5) * span_x(), 0.0)
	var wy := FractalDD.add(center_y, center_y_lo, (v - 0.5) * 2.0 * view_half(), 0.0)
	_anchor_wx = wx[0]
	_anchor_wx_lo = wx[1]
	_anchor_wy = wy[0]
	_anchor_wy_lo = wy[1]
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
		var x := FractalDD.add(_anchor_wx, _anchor_wx_lo,
			-(_anchor_u - 0.5) * 2.0 * half * aspect(), 0.0)
		var y := FractalDD.add(_anchor_wy, _anchor_wy_lo, -(_anchor_v - 0.5) * 2.0 * half, 0.0)
		_set_center(x[0], x[1], y[0], y[1])
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
	iteration_boost = 1.0
	_anchor_active = false


# The leading words go first: their setters clear the low words.
func _set_center(x: float, x_lo: float, y: float, y_lo: float) -> void:
	center_x = x
	center_y = y
	center_x_lo = x_lo
	center_y_lo = y_lo
