extends SceneTree

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

func _initialize() -> void:
	var failures: Array[String] = []
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
			failures.append("%d FPS error %.6f" % [fps, error])
		var expected_steps_per_frame := 60.0 / float(fps)
		if absf(float(total_steps) / float(frames) - expected_steps_per_frame) > 1e-4:
			failures.append("%d FPS step rate %.6f" % [
				fps, float(total_steps) / float(frames)])

	var pause_solver = FireSolver.new()
	pause_solver.schedule_steps(0.5)
	var pause_stats: Dictionary = pause_solver.get_clock_stats()
	if float(pause_stats["simulation_time"]) > 0.1 + 1e-5:
		failures.append("pause advanced too far")
	if float(pause_stats["dropped_time"]) <= 0.0:
		failures.append("pause was not recorded")

	var rate_solver = FireSolver.new()
	if rate_solver.simulation_hz != 30:
		failures.append("default simulation rate is not 30 Hz")
	rate_solver.schedule_steps(1.0 / 30.0)
	rate_solver.set_simulation_hz(30)
	var rate_stats: Dictionary = rate_solver.get_clock_stats()
	if not is_zero_approx(float(rate_stats["wall_time"])):
		failures.append("rate change did not reset clock")

	var interpolation_solver = FireSolver.new()
	interpolation_solver.set_simulation_hz(15)
	var first_half_steps: int = interpolation_solver.schedule_steps(1.0 / 30.0)
	if first_half_steps != 0:
		failures.append("15 Hz clock stepped on first half tick")
	if absf(interpolation_solver.interpolation_alpha() - 0.5) > 1e-5:
		failures.append("15 Hz interpolation midpoint is not 0.5")
	var second_half_steps: int = interpolation_solver.schedule_steps(1.0 / 30.0)
	if second_half_steps != 1:
		failures.append("15 Hz clock did not step on second half tick")
	if interpolation_solver.interpolation_alpha() > 1e-5:
		failures.append("15 Hz interpolation did not reset after tick")

	for low_rate in [5, 10]:
		var low_rate_solver = FireSolver.new()
		low_rate_solver.set_simulation_hz(low_rate)
		var half_tick := 0.5 / float(low_rate)
		if low_rate_solver.schedule_steps(half_tick) != 0:
			failures.append("%d Hz clock stepped on first half tick" % low_rate)
		if absf(low_rate_solver.interpolation_alpha() - 0.5) > 1e-5:
			failures.append("%d Hz interpolation midpoint is not 0.5" % low_rate)
		if low_rate_solver.schedule_steps(half_tick) != 1:
			failures.append("%d Hz clock did not step on second half tick" % low_rate)

	if failures.is_empty():
		print("TEST PASS fire_clock")
		quit(0)
		return
	for failure in failures:
		printerr("FIRE CLOCK FAIL: " + failure)
	quit(1)
