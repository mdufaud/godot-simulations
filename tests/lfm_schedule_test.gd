extends "res://tests/test_case.gd"


func _initialize() -> void:
	var expected := [
		[-1, -1, 0.5, false],
		[0, 0, 1.0, false],
		[0, 1, 2.0, false],
		[1, 2, 2.0, false],
		[2, 3, 2.0, true],
	]
	for step in expected.size():
		var entry := LfmLeapfrogSchedule.entry(step, 5)
		_check(entry.src == expected[step][0], "source at step %d" % step)
		_check(entry.last_proj == expected[step][1], "advecting field at step %d" % step)
		_check(entry.dt_factor == expected[step][2], "mid dt at step %d" % step)
		_check(entry.reinit_after == expected[step][3], "reinit at step %d" % step)
	var wrap := LfmLeapfrogSchedule.entry(5, 5)
	_check(wrap.src == -1 and wrap.last_proj == -1, "new window starts at init")
	var config := LfmConfig.new()
	_check(config.validate() == "", "default config validates")
	_check(absf(config.substep_dt_s() - 1.0 / 300.0) < 1.0e-9,
		"five substeps cover one 60 Hz frame")
	_check(absf(config.bounded_frame_dt_s(1.0 / 60.0) - 1.0 / 60.0) < 1.0e-8,
		"60 fps advances 1/60 second per image")
	_check(absf(config.bounded_frame_dt_s(1.0 / 30.0) - 1.0 / 30.0) < 1.0e-8,
		"30 fps advances 1/30 second per image")
	_check(config.bounded_frame_dt_s(0.7) <= 1.0 / 30.0 + 1.0e-8,
		"slow hardware cannot request an unstable catch-up step")
	config.inlet_speed_mps = 2.0
	_check(config.bounded_frame_dt_s(1.0 / 30.0) < 1.0 / 30.0,
		"high inlet speed respects the CFL limit")
	_finish("lfm_schedule")
