class_name SimStepClock
extends RefCounted
## Drains real elapsed time in fixed wall-clock quanta so a fixed-dt simulation
## advances at the same speed at any frame rate. One quantum per frame at the
## reference rate; longer frames run several quanta up to the cap, and any
## backlog beyond the cap is dropped instead of spiraling.

var reference_step := 1.0 / 60.0
var max_quanta_per_frame := 4
var _budget := 0.0


## Adds `delta` seconds of real time and returns the number of quanta to run.
func advance(delta: float) -> int:
	_budget += minf(delta, 0.25)
	var quanta := 0
	while _budget >= reference_step and quanta < max_quanta_per_frame:
		_budget -= reference_step
		quanta += 1
	if quanta == max_quanta_per_frame:
		_budget = 0.0
	return quanta


func reset() -> void:
	_budget = 0.0
