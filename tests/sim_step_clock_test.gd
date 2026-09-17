extends "res://tests/test_case.gd"
## Unit tests for the fixed-timestep accumulator the demos drain their
## simulations through. No scene, no GPU: runs under --headless instantly.

const STEP := 1.0 / 60.0


func _initialize() -> void:
	_test_reference_rate_is_one_step_per_frame()
	_test_faster_frames_bank_budget()
	_test_slow_frames_run_several_quanta()
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


func _test_backlog_is_dropped() -> void:
	var clock := SimStepClock.new()
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
