class_name FractalAutopilot extends RefCounted
## Cinematic tour: dives into a [FractalPoi], holds, rises back to the overview,
## then moves on to the next point.
##
## Drives the camera directly, so anything the user does with the mouse wins as
## soon as the host stops calling [method update].

enum Phase { DIVE, HOLD, RISE }

var enabled := false
## Dive rate, in decades of zoom per second.
var speed := 0.45

var _camera: FractalCamera
var _phase := Phase.DIVE
var _hold := 0.0
var _index := 0
var _poi_x := 0.0
var _poi_y := 0.0
var _poi_max_log_zoom := 0.0


func _init(camera: FractalCamera) -> void:
	_camera = camera


## Selects the point at [param index], wrapping around the list of the current
## fractal type.
func pick(index: int) -> void:
	var points := FractalPoi.list_for(_camera.fractal_type)
	_index = index % points.size()
	var poi := points[_index]
	_poi_x = poi.x
	_poi_y = poi.y
	_poi_max_log_zoom = minf(log(poi.max_zoom), _camera.max_log_zoom())


func restart() -> void:
	_phase = Phase.DIVE
	_hold = 0.0


## Moves the zoom target along with the tour, keeping whatever offset a wheel or
## pinch put on it (target - log). Overwriting the target with the tour's zoom
## threw that input away every frame of DIVE and RISE; with no user input the
## offset is zero and the target follows the tour exactly as before.
func _carry_user_zoom(previous_log_zoom: float) -> void:
	_camera.target_log_zoom = clampf(
		_camera.log_zoom + (_camera.target_log_zoom - previous_log_zoom),
		_camera.min_log_zoom(), _camera.max_log_zoom())


func update(delta: float) -> void:
	if not enabled:
		return
	match _phase:
		Phase.DIVE:
			var head := clampf((_poi_max_log_zoom - _camera.log_zoom) / 1.5, 0.08, 1.0)
			var rate := speed * FractalCamera.LN10 * head
			var previous := _camera.log_zoom
			_camera.log_zoom = minf(_camera.log_zoom + rate * delta, _poi_max_log_zoom)
			_carry_user_zoom(previous)
			# Pin the point on screen while zooming, with a gentle pull to centre
			var ratio := exp(previous - _camera.log_zoom)
			var pull := exp(-delta * 0.8)
			_camera.center_x = _poi_x + (_camera.center_x - _poi_x) * ratio * pull
			_camera.center_y = _poi_y + (_camera.center_y - _poi_y) * ratio * pull
			if _camera.log_zoom >= _poi_max_log_zoom - 1e-6:
				_phase = Phase.HOLD
				_hold = 0.0
		Phase.HOLD:
			_hold += delta
			if _hold >= 2.0:
				_phase = Phase.RISE
		Phase.RISE:
			var overview := FractalCamera.overview_log_zoom()
			var head := clampf((_camera.log_zoom - overview) / 1.5, 0.08, 1.0)
			var before := _camera.log_zoom
			_camera.log_zoom = maxf(
				_camera.log_zoom - speed * FractalCamera.LN10 * 2.5 * head * delta, overview)
			_carry_user_zoom(before)
			if _camera.log_zoom <= overview + 1e-6:
				pick(_index + 1)
				_phase = Phase.DIVE
