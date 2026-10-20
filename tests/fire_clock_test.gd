extends "res://tests/test_case.gd"

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

func _initialize() -> void:
	for fps in [15, 25, 30, 60, 120, 144]:
		var solver = FireSolver.new()
		solver.set_simulation_hz(60)
		var frames := int(round(float(fps) * 10.0))
		var total_steps := 0
		for _frame in frames:
			total_steps += solver.schedule_steps(1.0 / float(fps))
		var stats: Dictionary = solver.get_clock_stats()
		var error := absf(float(stats["simulation_time"]) - 10.0)
		print("CLOCK %d FPS sim=%.6f wall=%.6f steps=%d error=%.6f" % [
			fps, stats["simulation_time"], stats["wall_time"],
			solver.last_substeps, error])
		if error > solver.timestep + 1e-5:
			_check(false, "%d FPS error %.6f" % [fps, error])
		var expected_steps_per_frame := 60.0 / float(fps)
		if absf(float(total_steps) / float(frames) - expected_steps_per_frame) > 1e-4:
			_check(false, "%d FPS step rate %.6f" % [
				fps, float(total_steps) / float(frames)])

	var pause_solver = FireSolver.new()
	pause_solver.schedule_steps(0.5)
	var pause_stats: Dictionary = pause_solver.get_clock_stats()
	if float(pause_stats["simulation_time"]) > 0.1 + 1e-5:
		_check(false, "pause advanced too far")
	if float(pause_stats["dropped_time"]) <= 0.0:
		_check(false, "pause was not recorded")

	var rate_solver = FireSolver.new()
	if rate_solver.simulation_hz != 30:
		_check(false, "default simulation rate is not 30 Hz")
	rate_solver.schedule_steps(1.0 / 30.0)
	rate_solver.set_simulation_hz(30)
	var rate_stats: Dictionary = rate_solver.get_clock_stats()
	if not is_zero_approx(float(rate_stats["wall_time"])):
		_check(false, "rate change did not reset clock")

	var interpolation_solver = FireSolver.new()
	interpolation_solver.set_simulation_hz(15)
	var first_half_steps: int = interpolation_solver.schedule_steps(1.0 / 30.0)
	if first_half_steps != 0:
		_check(false, "15 Hz clock stepped on first half tick")
	if absf(interpolation_solver.interpolation_alpha() - 0.5) > 1e-5:
		_check(false, "15 Hz interpolation midpoint is not 0.5")
	var second_half_steps: int = interpolation_solver.schedule_steps(1.0 / 30.0)
	if second_half_steps != 1:
		_check(false, "15 Hz clock did not step on second half tick")
	if interpolation_solver.interpolation_alpha() > 1e-5:
		_check(false, "15 Hz interpolation did not reset after tick")

	for low_rate in [5, 10]:
		var low_rate_solver = FireSolver.new()
		low_rate_solver.set_simulation_hz(low_rate)
		var half_tick := 0.5 / float(low_rate)
		if low_rate_solver.schedule_steps(half_tick) != 0:
			_check(false, "%d Hz clock stepped on first half tick" % low_rate)
		if absf(low_rate_solver.interpolation_alpha() - 0.5) > 1e-5:
			_check(false, "%d Hz interpolation midpoint is not 0.5" % low_rate)
		if low_rate_solver.schedule_steps(half_tick) != 1:
			_check(false, "%d Hz clock did not step on second half tick" % low_rate)

	# --- Catchup 1 above the simulation rate must hold real time -------------
	for fps in [35, 40, 43, 50, 55]:
		var lean = FireSolver.new()
		lean.set_simulation_hz(30)
		lean.max_catchup_steps = 1
		for _frame in fps * 10:
			lean.schedule_steps(1.0 / float(fps))
		var lean_stats: Dictionary = lean.get_clock_stats()
		if absf(float(lean_stats["simulation_time"]) - 10.0) > 1.0 / 30.0 + 1e-5:
			_check(false, "catchup 1 at %d FPS simulated %.3f s of 10" % [
				fps, lean_stats["simulation_time"]])

	# --- Degraded regimes (30 Hz, catchup 1): capped game policy ---------------
	# 10 s at 20 fps: the backlog is bounded at catchup*timestep and the surplus
	# is dropped, so the run ends with sim 6.667 s, dropped 3.333 s less at most
	# one pending step.
	var capped = FireSolver.new()
	capped.set_simulation_hz(30)
	capped.max_catchup_steps = 1
	for _frame in 200:
		capped.schedule_steps(1.0 / 20.0)
		var alpha: float = capped.interpolation_alpha()
		if alpha < 0.0 or alpha > 1.0:
			_check(false, "interpolation alpha out of range: %s" % str(alpha))
	var capped_stats: Dictionary = capped.get_clock_stats()
	if absf(float(capped_stats["simulation_time"]) - 200.0 / 30.0) > 1e-3:
		_check(false, "capped run simulated the wrong time: %s"
			% str(capped_stats["simulation_time"]))
	if absf(float(capped_stats["dropped_time"]) - (10.0 - 200.0 / 30.0)) > 1.0 / 30.0 + 1e-3:
		_check(false, "capped run did not account the dropped time: %s"
			% str(capped_stats["dropped_time"]))
	if float(capped_stats["accumulator"]) > 1.0 / 30.0 + 1e-6:
		_check(false, "capped backlog exceeded one catchup step")
	for _frame in 600:
		capped.schedule_steps(1.0 / 60.0)
	var recovered: Dictionary = capped.get_clock_stats()
	# Capped policy: dropped time stays dropped, so 20 s of wall yields 16.667 s
	# of sim here — but from now on the clock holds real time.
	if absf(float(recovered["simulation_time"]) - (200.0 / 30.0 + 10.0)) > 1.0 / 30.0 + 1e-3:
		_check(false, "capped recovery did not hold real time: %s"
			% str(recovered["simulation_time"]))
	if absf(float(recovered["wall_time"]) - (float(recovered["simulation_time"])
			+ float(recovered["accumulator"]) + float(recovered["dropped_time"]))) > 1e-4:
		_check(false, "capped clock invariant wall != sim + acc + dropped")

	# --- Uncapped debt (validation policy): time is owed, never dropped --------
	var debt = FireSolver.new()
	debt.clock_debt_capped = false
	debt.set_simulation_hz(30)
	debt.max_catchup_steps = 1
	for _frame in 200:
		debt.schedule_steps(1.0 / 20.0)
	var debt_stats: Dictionary = debt.get_clock_stats()
	if absf(float(debt_stats["simulation_time"]) - 200.0 / 30.0) > 1e-3:
		_check(false, "validation run simulated the wrong time")
	if float(debt_stats["dropped_time"]) > 1e-9:
		_check(false, "validation run dropped time it should owe")
	if absf(float(debt_stats["accumulator"]) - (10.0 - 200.0 / 30.0)) > 1e-3:
		_check(false, "validation run lost the backlog: %s"
			% str(debt_stats["accumulator"]))
	for _frame in 600:
		debt.schedule_steps(1.0 / 60.0)
	var paid: Dictionary = debt.get_clock_stats()
	if absf(float(paid["simulation_time"]) - 20.0) > 1.0 / 30.0 + 1e-3:
		_check(false, "validation recovery did not repay the debt: %s"
			% str(paid["simulation_time"]))

	# --- Sustained 5 fps under the capped policy -------------------------------
	var starved = FireSolver.new()
	starved.set_simulation_hz(30)
	starved.max_catchup_steps = 1
	for _frame in 50:
		starved.schedule_steps(0.2)
	var starved_stats: Dictionary = starved.get_clock_stats()
	# The 0.1 s frame clamp binds first, then the catchup cap: 5 fps buys 0.1 s
	# of wall per frame of which only 0.0333 s is ever simulated.
	if absf(float(starved_stats["wall_time"]) - 10.0) > 1e-4:
		_check(false, "starved wall clock wrong")
	if float(starved_stats["simulation_time"]) < 1.66 \
			or float(starved_stats["simulation_time"]) > 1.672:
		_check(false, "starved simulation time wrong: %s"
			% str(starved_stats["simulation_time"]))
	if absf(float(starved_stats["wall_time"]) - (float(starved_stats["simulation_time"])
			+ float(starved_stats["accumulator"])
			+ float(starved_stats["dropped_time"]))) > 1e-4:
		_check(false, "starved clock invariant broken")

	_finish("fire_clock")
