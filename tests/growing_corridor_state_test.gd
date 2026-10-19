extends "res://tests/test_case.gd"
## Unit tests for growing_corridor_state.gd — pure math, no scene, no GPU.
## Runs under --headless in a couple of seconds.

const State := preload("res://scripts/non_euclidean/growing_corridor_state.gd")

const RIGID := 6.0
const BASE := 8.0
const RATE := 0.6
const MAX_STRETCH := 80.0


func _initialize() -> void:
	_test_rigid_span()
	_test_fold_shape()
	_test_stretch()
	_test_accordion_walk()
	_finish("growing_corridor_state")


func _test_rigid_span() -> void:
	for offset in [-6.0, -3.5, -0.2, 0.0, 1.0, 4.4, 6.0]:
		_check(is_equal_approx(State.apparent_offset(offset, RIGID, 20.0), offset),
			"rigid span moved a point at %.1f m" % offset)
		_check(is_equal_approx(State.apparent_slope(offset, RIGID, 20.0), 1.0),
			"rigid span is not drawn at true scale at %.1f m" % offset)


func _test_fold_shape() -> void:
	var stretch := 20.0
	# The joint is seamless: no jump and no kink where the fold starts.
	_check(absf(State.apparent_offset(RIGID + 0.001, RIGID, stretch) - (RIGID + 0.001)) < 0.0001,
		"the fold jumps at the rigid joint")
	_check(absf(State.apparent_slope(RIGID + 0.001, RIGID, stretch) - 1.0) < 0.001,
		"the fold kinks at the rigid joint")
	var previous := -INF
	for step in range(-400, 401):
		var offset := float(step)
		var drawn := State.apparent_offset(offset, RIGID, stretch)
		_check(drawn > previous, "drawing folds back on itself at %.0f m" % offset)
		_check(absf(drawn) <= RIGID + stretch + 0.0001,
			"drawing escaped the bellows at %.0f m" % offset)
		_check(is_equal_approx(State.apparent_offset(-offset, RIGID, stretch), -drawn),
			"fold is not the same behind and ahead at %.0f m" % offset)
		previous = drawn
	_check(is_equal_approx(State.apparent_offset(26.0, RIGID, stretch),
		RIGID + stretch * (1.0 - exp(-1.0))), "one bellows length past the joint is not 1 - 1/e folded")
	_check(State.apparent_slope(46.0, RIGID, stretch) < State.apparent_slope(26.0, RIGID, stretch),
		"far arches are not packed tighter than near ones")


func _test_stretch() -> void:
	_check(is_equal_approx(State.stretch(0.0, BASE, RATE, MAX_STRETCH), BASE),
		"the bellows does not start at its base length")
	_check(is_equal_approx(State.stretch(-5.0, BASE, RATE, MAX_STRETCH), BASE),
		"standing behind the start shrank the bellows")
	_check(is_equal_approx(State.stretch(10.0, BASE, RATE, MAX_STRETCH), 14.0),
		"the bellows does not widen by the rate per metre walked")
	_check(is_equal_approx(State.stretch(10000.0, BASE, RATE, MAX_STRETCH), MAX_STRETCH),
		"the bellows is not capped")


## Walking toward a far point: in a plain corridor it would come 40 m closer;
## folded, the far door recedes and the arch 2 m ahead still passes at walking
## pace.
func _test_accordion_walk() -> void:
	var far_real := 300.0
	var start_far := _drawn_ahead(far_real, 0.0)
	var later_far := _drawn_ahead(far_real, 40.0)
	_check(later_far > start_far, "the far end came closer while walking toward it")
	var door_start := RIGID + State.stretch(0.0, BASE, RATE, MAX_STRETCH)
	var door_later := RIGID + State.stretch(40.0, BASE, RATE, MAX_STRETCH)
	_check(door_later > door_start + 20.0, "the far door did not recede while walking")
	var near_before := _drawn_ahead(42.0, 40.0)
	var near_after := _drawn_ahead(42.0, 40.5)
	_check(is_equal_approx(near_before - near_after, 0.5),
		"a nearby arch does not pass at walking pace")


func _drawn_ahead(real: float, depth: float) -> float:
	return State.apparent_offset(real - depth, RIGID,
		State.stretch(depth, BASE, RATE, MAX_STRETCH))
