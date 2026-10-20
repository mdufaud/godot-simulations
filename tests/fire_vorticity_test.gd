extends "res://tests/test_case.gd"

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

func _initialize() -> void:
	# The confinement impulse over a run must not depend on how often it is
	# dispatched: the interval is a cost lever, not a strength knob.
	for interval in [1, 2, 3, 4]:
		var solver = FireSolver.new()
		solver.vorticity_interval = interval
		var steps := 0
		var integrated := 0.0
		for step in 12:
			if solver.vorticity_runs_on_step(step):
				steps += 1
				integrated += solver.timestep * solver.vorticity_dt_scale()
		if steps != 12 / interval:
			_check(false, "interval %d dispatched %d of 12 steps" % [interval, steps])
		if absf(integrated - 12.0 * solver.timestep) > 1e-6:
			_check(false, "interval %d integrated %.4f s of %.4f" % [
				interval, integrated, 12.0 * solver.timestep])

	var off = FireSolver.new()
	off.vorticity_mode = FireSolver.VORTICITY_OFF
	for step in 4:
		if off.vorticity_runs_on_step(step):
			_check(false, "vorticity Off dispatched on step %d" % step)

	_finish("fire_vorticity")
