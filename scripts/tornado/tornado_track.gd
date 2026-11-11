class_name TornadoTrack extends RefCounted
## Ground track of a travelling tornado: an endless figure-eight inside
## extent_m whose lobes slowly lean, walked at exactly the requested ground speed.
##
## Owns: the path parameter and the path walked over the last HISTORY_S. The
## host calls advance() once per frame, then position_at(lag_s) for the point
## the storm occupied lag_s ago — lag 0 is the parent circulation aloft, larger
## lags are the lower, slower parts of the funnel (see
## TornadoWindField.axis_lag_s). Every lag reads the same recorded path, so the
## whole funnel travels at one speed and a speed change never moves its past.
##
##     var track := TornadoTrack.new()
##     track.advance(delta, 8.0)
##     field.base_pos = track.position_at(field.axis_lag_s(0.0))

const SLOPE_STEP := 0.01
## Largest lean of the figure-eight's lobes. A quarter turn would fold each end
## of the path into a cusp; this keeps the end turns near 90 m of radius.
const LOBE_LEAN_RAD := 0.4
## Path parameter span over which the lean changes, in noise units per radian.
const LOBE_LEAN_RATE := 12.0
const HISTORY_STEP_S := 0.25
## 32 s of path, past TornadoWindField.AXIS_LAG_MAX_S.
const HISTORY_SAMPLES := 128

var extent_m := Vector2(480.0, 120.0)
var noise := FastNoiseLite.new()

var _parameter := 0.0
## Ring of past positions, HISTORY_STEP_S apart, _newest the latest.
var _history := PackedVector2Array()
var _newest := 0
var _since_sample_s := 0.0


func advance(delta: float, speed_mps: float) -> void:
	if _history.is_empty():
		_history.resize(HISTORY_SAMPLES)
		_history.fill(_point(_parameter))
	var remaining_s := delta
	while remaining_s > 0.0:
		var step_s := minf(remaining_s, HISTORY_STEP_S - _since_sample_s)
		# Midpoint rule on d(parameter)/dt = speed / slope.
		var half := _parameter + 0.5 * speed_mps * step_s / _slope_m(_parameter)
		_parameter += speed_mps * step_s / _slope_m(half)
		_since_sample_s += step_s
		remaining_s -= step_s
		if _since_sample_s > HISTORY_STEP_S - 1e-6:
			_since_sample_s = 0.0
			_newest = (_newest + 1) % HISTORY_SAMPLES
			_history[_newest] = _point(_parameter)


func position_at(lag_s: float) -> Vector3:
	var point := _point(_parameter)
	if not _history.is_empty() and lag_s > 0.0:
		if lag_s < _since_sample_s:
			point = point.lerp(_sample(0), lag_s / _since_sample_s)
		else:
			var age := minf((lag_s - _since_sample_s) / HISTORY_STEP_S, HISTORY_SAMPLES - 1.0)
			var index := mini(int(age), HISTORY_SAMPLES - 2)
			point = _sample(index).lerp(_sample(index + 1), age - index)
	return Vector3(point.x, 0.0, point.y)


func _sample(samples_back: int) -> Vector2:
	return _history[posmod(_newest - samples_back, HISTORY_SAMPLES)]


func _slope_m(parameter: float) -> float:
	return (_point(parameter + SLOPE_STEP) - _point(parameter - SLOPE_STEP)).length() / (2.0 * SLOPE_STEP)


func _point(parameter: float) -> Vector2:
	var lean := LOBE_LEAN_RAD * noise.get_noise_1d(parameter * LOBE_LEAN_RATE)
	return Vector2(sin(parameter), sin(2.0 * parameter + lean)) * extent_m
