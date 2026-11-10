class_name TornadoTrack extends RefCounted
## Ground track of a travelling tornado: an endless meandering path inside
## extent_m, walked at a requested ground speed.
##
## Owns: the path parameter and its rate. The host calls advance() once per
## frame, then position_at(lag_s) for the point the storm occupied lag_s ago —
## lag 0 is the parent circulation aloft, larger lags are the lower, slower
## parts of the funnel (see TornadoWindField.axis_lag_s).
##
##     var track := TornadoTrack.new()
##     track.advance(delta, 8.0)
##     field.base_pos = track.position_at(field.axis_lag_s(0.0))

## Rate ceiling: where the path turns back on itself its slope vanishes and the
## requested speed would otherwise ask for an unbounded parameter rate.
const MAX_RATE_HZ := 3.0
const RATE_SMOOTHING_S := 1.0
const SLOPE_STEP := 0.05

var extent_m := Vector2(480.0, 120.0)
var noise := FastNoiseLite.new()

var _parameter := 0.0
var _rate_hz := 0.0


func advance(delta: float, speed_mps: float) -> void:
	var slope_m := (_point(_parameter + SLOPE_STEP) - _point(_parameter - SLOPE_STEP)).length() \
		/ (2.0 * SLOPE_STEP)
	var target_hz := minf(speed_mps / maxf(slope_m, 1e-3), MAX_RATE_HZ)
	_rate_hz = lerpf(_rate_hz, target_hz, 1.0 - exp(-delta / RATE_SMOOTHING_S))
	_parameter += _rate_hz * delta


func position_at(lag_s: float) -> Vector3:
	var point := _point(_parameter - lag_s * _rate_hz)
	return Vector3(point.x, 0.0, point.y)


func _point(parameter: float) -> Vector2:
	return Vector2(noise.get_noise_2d(parameter, 0.0), noise.get_noise_2d(parameter, 500.0)) * extent_m
