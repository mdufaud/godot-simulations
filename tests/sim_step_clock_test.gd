extends "res://tests/test_case.gd"
## Unit tests for the fixed-timestep accumulator the demos drain their
## simulations through. No scene, no GPU: runs under --headless instantly.

const STEP := 1.0 / 60.0


func _initialize() -> void:
	_test_reference_rate_is_one_step_per_frame()
	_test_faster_frames_bank_budget()
	_test_slow_frames_run_several_quanta()
	_test_time_scale_changes_quanta_not_step_size()
	_test_three_x_survives_fifty_fps()
	_test_rate_limit_is_reported_only_when_time_is_dropped()
	_test_backlog_is_dropped()
	_test_reset_clears_budget()
	_finish("sim_step_clock")


func _test_reference_rate_is_one_step_per_frame() -> void:
	var clock := SimStepClock.new()
	for i in 120:
		if clock.advance(STEP) != 1:
			_check(false, "at the reference rate every frame should run one quantum")
			return
	_check(true, "")


func _test_faster_frames_bank_budget() -> void:
	var clock := SimStepClock.new()
	# 144 Hz frames run no quantum on their own but bank 1/60 s of budget
	# roughly every 2.4 frames, so the average speed still matches wall time.
	var quanta := 0
	for i in 144:
		quanta += clock.advance(STEP * 60.0 / 144.0)
	# Float dust can cost the boundary quantum: drift stays within one step.
	_check(absi(quanta - 60) <= 1,
		"144 Hz frames should produce ~60 quanta per second, got %d" % quanta)


func _test_slow_frames_run_several_quanta() -> void:
	var clock := SimStepClock.new()
	# A 30 fps frame is two quanta; a long hitch runs the capped remainder.
	if clock.advance(STEP * 2.0) != 2:
		_check(false, "a 2x frame should run two quanta")
		return
	if clock.advance(STEP * 3.0) != 3:
		_check(false, "a 3x frame should run three quanta")
		return
	_check(true, "")


func _test_time_scale_changes_quanta_not_step_size() -> void:
	var slow_clock := SimStepClock.new()
	var slow_quanta := 0
	for _i in 60:
		slow_quanta += slow_clock.advance(STEP, 0.25)
	if absi(slow_quanta - 15) > 1:
		_check(false, "0.25x should run about 15 fixed quanta per second")
		return
	var fast_clock := SimStepClock.new()
	var fast_quanta := 0
	for _i in 60:
		fast_quanta += fast_clock.advance(STEP, 3.0)
	_check(fast_quanta == 180,
		"3x should run three fixed quanta per reference frame")


func _test_three_x_survives_fifty_fps() -> void:
	var clock := SimStepClock.new()
	clock.max_quanta_per_frame = 4
	var quanta := 0
	for _i in 50:
		quanta += clock.advance(1.0 / 50.0, 3.0)
		if clock.rate_limited:
			_check(false, "3x playback at 50 FPS should not be rate-limited")
			return
	_check(quanta == 180,
		"3x playback at 50 FPS should preserve the requested simulation rate")


func _test_rate_limit_is_reported_only_when_time_is_dropped() -> void:
	var clock := SimStepClock.new()
	clock.max_quanta_per_frame = 3
	if clock.advance(STEP * 3.0) != 3 or clock.rate_limited:
		_check(false, "reaching the catch-up limit without backlog is not rate-limited")
		return
	if clock.advance(STEP * 2.0, 3.0) != 3 or not clock.rate_limited:
		_check(false, "dropped scaled backlog should report the rate limit")
		return
	if clock.advance(0.0) != 0 or clock.rate_limited:
		_check(false, "the dropped backlog must not reappear on the next frame")
		return
	_check(true, "")


func _test_backlog_is_dropped() -> void:
	var clock := SimStepClock.new()
	clock.max_quanta_per_frame = 3
	# A 10 s hitch runs at most max_quanta_per_frame and drops the backlog:
	# the next frame must not spiral through hundreds of catch-up steps.
	if clock.advance(10.0) != clock.max_quanta_per_frame:
		_check(false, "a hitch should cap at max_quanta_per_frame")
		return
	if clock.advance(0.0) != 0:
		_check(false, "the backlog should be dropped, not carried")
		return
	if clock.advance(STEP) != 1:
		_check(false, "the clock should resume normal pacing after a hitch")
		return
	_check(true, "")


func _test_reset_clears_budget() -> void:
	var clock := SimStepClock.new()
	clock.advance(STEP * 0.9)
	clock.reset()
	if clock.advance(0.0) != 0:
		_check(false, "reset should clear the banked budget")
		return
	_check(true, "")
