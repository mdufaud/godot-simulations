extends "res://tests/test_case.gd"
## Unit tests for wrap_world_state.gd — pure math, no scene, no GPU.
## Runs under --headless in a couple of seconds.

const State := preload("res://scripts/non_euclidean/wrap_world_state.gd")

const PERIODS := Vector3(40.0, 60.0, 40.0)


func _initialize() -> void:
	_test_wrap_axis()
	_test_wrap_offset()
	_test_crossing()
	_finish("wrap_world_state")


func _test_wrap_axis() -> void:
	_check(is_zero_approx(State.wrap_axis(0.0, PERIODS.x)), "origin did not stay put")
	_check(is_equal_approx(State.wrap_axis(12.0, PERIODS.x), 12.0), "interior value was moved")
	_check(is_equal_approx(State.wrap_axis(-13.2, PERIODS.x), -13.2), "interior value was moved")
	_check(is_equal_approx(State.wrap_axis(PERIODS.x * 0.5 + 0.4, PERIODS.x),
		-PERIODS.x * 0.5 + 0.4), "high boundary did not wrap onto the low side")
	_check(is_equal_approx(State.wrap_axis(-PERIODS.x * 0.5 - 0.4, PERIODS.x),
		PERIODS.x * 0.5 - 0.4), "low boundary did not wrap onto the high side")
	_check(is_equal_approx(State.wrap_axis(3.0 * PERIODS.x + 5.0, PERIODS.x), 5.0),
		"several periods did not reduce into the cell")
	for copy in range(-3, 4):
		var wrapped := State.wrap_axis(19.9 + float(copy) * PERIODS.x, PERIODS.x)
		_check(absf(wrapped) <= PERIODS.x * 0.5 + 0.000001,
			"wrapped value left the cell for copy %d" % copy)
		var again := State.wrap_axis(wrapped, PERIODS.x)
		_check(is_equal_approx(again, wrapped), "wrapping is not idempotent for copy %d" % copy)
	_check(is_finite(State.wrap_axis(100000.7, PERIODS.x)),
		"large coordinate left the finite range")
	_check(is_equal_approx(State.wrap_axis(25.0, PERIODS.y), 25.0),
		"the axis period leaked into another axis")


func _test_wrap_offset() -> void:
	_check(State.wrap_offset(Vector3.ZERO, PERIODS).length() <= 0.000001,
		"origin produced a non-zero wrap offset")
	_check(State.wrap_offset(Vector3(12.0, -25.0, -19.999), PERIODS).length() <= 0.000001,
		"interior position produced a wrap offset")
	var beyond_x := State.wrap_offset(Vector3(20.3, 0.0, 0.0), PERIODS)
	_check(beyond_x.is_equal_approx(Vector3(-PERIODS.x, 0.0, 0.0)),
		"high X crossing did not return one negative period")
	var below_y := State.wrap_offset(Vector3(0.0, -30.1, 0.0), PERIODS)
	_check(below_y.is_equal_approx(Vector3(0.0, PERIODS.y, 0.0)),
		"low Y crossing did not return one positive period")
	var stray := Vector3(21.0, -31.0, -20.5)
	var combined := State.wrap_offset(stray, PERIODS)
	_check(combined.is_equal_approx(Vector3(-PERIODS.x, PERIODS.y, PERIODS.x)),
		"multi-axis straying did not wrap every axis")
	var wrapped := stray + combined
	_check(absf(wrapped.x) <= PERIODS.x * 0.5 + 0.000001 \
		and absf(wrapped.y) <= PERIODS.y * 0.5 + 0.000001 \
		and absf(wrapped.z) <= PERIODS.z * 0.5 + 0.000001,
		"applying the offset left the position outside the cell")


func _test_crossing() -> void:
	_check(State.crossing(0.0, 0.5, PERIODS.x) == 0, "interior motion reported a crossing")
	_check(State.crossing(19.0, 19.9, PERIODS.x) == 0,
		"motion along the high edge reported a crossing")
	_check(State.crossing(-19.0, -19.9, PERIODS.x) == 0,
		"motion along the low edge reported a crossing")
	_check(State.crossing(19.9, -19.9, PERIODS.x) == 1,
		"exit through the high boundary was not detected")
	_check(State.crossing(-19.9, 19.9, PERIODS.x) == -1,
		"exit through the low boundary was not detected")
	_check(State.crossing(0.0, PERIODS.x * 0.49, PERIODS.x) == 0,
		"a sub-half-period step was read as a crossing")
	_check(State.crossing(-PERIODS.x * 0.5 + 0.1, PERIODS.x * 0.5 - 0.1, PERIODS.x) == -1,
		"a full-period jump upward was not read as a low crossing")
