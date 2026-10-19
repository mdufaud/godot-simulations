class_name SimStepClock
extends RefCounted
## Drains real elapsed time in fixed wall-clock quanta so a fixed-dt simulation
## advances at the same speed at any frame rate. One quantum per frame at the
## reference rate; longer frames run several quanta up to the cap, and any
## backlog beyond the cap is dropped instead of spiraling.

var reference_step := 1.0 / 60.0
var max_quanta_per_frame := 4
var _budget := 0.0
var rate_limited := false


## Adds scaled wall time and returns fixed simulation quanta to run.
func advance(delta: float, time_scale: float = 1.0) -> int:
	rate_limited = false
	_budget += maxf(delta, 0.0) * maxf(time_scale, 0.0)
	var available := int(floor((_budget + 1e-10) / reference_step))
	var quanta := mini(available, max_quanta_per_frame)
	rate_limited = available > max_quanta_per_frame
	_budget -= float(available if rate_limited else quanta) * reference_step
	if _budget < 0.0 and _budget > -1e-10:
		_budget = 0.0
	return quanta


func reset() -> void:
	_budget = 0.0
	rate_limited = false
