extends "res://tests/test_case.gd"
## Unit tests for growing_corridor_state.gd — pure math, no scene, no GPU.
## Runs under --headless in a couple of seconds.

const State := preload("res://scripts/non_euclidean/growing_corridor_state.gd")

const GROWTH := 1.7
const MAX_SCALE := 8.0


func _initialize() -> void:
	_test_segment_scale()
	_test_advance()
	_test_next_state()
	_finish("growing_corridor_state")


func _test_segment_scale() -> void:
	_check(is_equal_approx(State.segment_scale(0, GROWTH, MAX_SCALE), 1.0),
		"first segment does not start at scale 1")
	var previous := 0.0
	for index in range(0, 24):
		var scale := State.segment_scale(index, GROWTH, MAX_SCALE)
		_check(is_finite(scale), "segment scale is not finite at index %d" % index)
		_check(scale >= previous - 0.000001, "segment scale decreased at index %d" % index)
		_check(scale <= MAX_SCALE + 0.000001, "segment scale exceeded the bound at index %d" % index)
		previous = scale
	_check(is_equal_approx(State.segment_scale(3, GROWTH, MAX_SCALE), pow(GROWTH, 3.0)),
		"geometric progression broken before the clamp")
	_check(is_equal_approx(State.segment_scale(12, GROWTH, MAX_SCALE), MAX_SCALE),
		"progression does not clamp to max_scale")


func _test_advance() -> void:
	_check(is_zero_approx(State.advance(0.0, 0.0, 1.0)), "no step must not advance")
	_check(is_equal_approx(State.advance(5.0, 2.0, 3.0), 11.0),
		"advance does not weigh the step by the local scale")
	var total := 0.0
	var step := 0.35
	for scale_step in range(0, 40):
		total = State.advance(total, step, State.segment_scale(scale_step, GROWTH, MAX_SCALE))
		_check(is_finite(total), "virtual distance left the finite range")
		_check(total >= step * float(scale_step) - 0.000001,
			"virtual distance regressed at step %d" % scale_step)


func _test_next_state() -> void:
	var states: Array = []
	var updated := State.next_state(states, 2, State.Entered.FORWARD)
	_check(updated.size() == 3, "forward entry did not grow the state table")
	_check((updated[2] as Dictionary).get("forward", false), "forward entry not recorded")
	_check(int((updated[2] as Dictionary).get("revision", 0)) == 1,
		"forward entry did not start a revision")
	_check(states.is_empty(), "next_state mutated its input array")

	updated = State.next_state(updated, 2, State.Entered.FORWARD)
	_check(int((updated[2] as Dictionary).get("revision", 0)) == 2,
		"repeated forward entry did not bump the revision")

	updated = State.next_state(updated, 2, State.Entered.BACKWARD)
	_check((updated[2] as Dictionary).get("backward", false), "backward entry not recorded")
	_check(int((updated[2] as Dictionary).get("revision", 0)) == 2,
		"backward entry changed the revision")

	var untouched := State.next_state(updated, 1, State.Entered.NONE)
	_check(untouched.size() == updated.size(), "NONE entry changed the table size")
	_check(_states_equal(untouched, updated), "NONE entry changed the table contents")

	_check(State.next_state([], -1, State.Entered.FORWARD).is_empty(),
		"negative cell index was served")


func _states_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if (a[index] as Dictionary).hash() != (b[index] as Dictionary).hash():
			return false
	return true
