extends SceneTree
## Fire performance probe for the lot-K baseline: p50/p95 frame times at a fixed
## window size with vsync off, plus video memory, solver state, pool occupancy
## and the GPU stage breakdown at the end. Read-only with respect to
## persistence; quits when done.
##
##   godot -s res://tools/fire_perf_probe.gd -- label=wood preset=2
##   godot -s res://tools/fire_perf_probe.gd -- label=p32 pressure=32 size=2560x1440
##   godot -s res://tools/fire_perf_probe.gd -- label=atlas4096 pool=3 warmup=450

var _label := "fire"
var _size := Vector2i(2560, 1440)
var _preset := 2 # Balanced: the playable default the captures document
var _seconds := 8.0
var _warmup := 450 # frames to an established flame at fixed dt (lot 1 protocol)
var _pressure := -1
var _pool := -1
var _fuel := ""
var _jet := -1
var _scale := -1.0
var _advection := -1
var _vorticity := -1
var _vort_interval := -1
var _sim_hz := -1
var _max_fps := 0
var _keep := -1.0
var _windx := 0.0
var _demo: Node = null


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var split: PackedStringArray = arg.split("=", true, 1)
		if split.size() != 2:
			continue
		match String(split[0]):
			"label": _label = split[1]
			"size":
				var dims := split[1].split("x")
				if dims.size() == 2:
					_size = Vector2i(maxi(16, int(dims[0])), maxi(16, int(dims[1])))
			"preset": _preset = int(split[1])
			"seconds": _seconds = clampf(float(split[1]), 1.0, 60.0)
			"warmup": _warmup = maxi(0, int(split[1]))
			"pressure": _pressure = int(split[1])
			"pool": _pool = int(split[1])
			"fuel": _fuel = split[1]
			"jet": _jet = int(split[1])
			"scale": _scale = float(split[1])
			"advection": _advection = int(split[1])
			"vorticity": _vorticity = int(split[1])
			"vort_interval": _vort_interval = int(split[1])
			"sim_hz": _sim_hz = int(split[1])
			"max_fps": _max_fps = int(split[1])
			"keep": _keep = float(split[1])
			"windx": _windx = float(split[1])
	var packed := load("res://scenes/fire_demo.tscn") as PackedScene
	if packed == null:
		push_error("PERF FAIL: cannot load fire_demo.tscn")
		quit(1)
		return
	root.size = _size
	_demo = packed.instantiate()
	root.add_child(_demo)
	call_deferred("_run")


func _run() -> void:
	await process_frame
	if not await _wait_ready():
		return
	# The preset first (it owns the pool key), then the explicit overrides.
	_demo.apply_preset(_preset)
	if _pool >= 0:
		_demo.set_pool_budget(_pool)
	if not await _wait_ready():
		return
	var solver = _demo.solver
	if _pressure > 0:
		solver.pressure_iterations = _pressure
	if not _fuel.is_empty():
		_demo.set_capture_fuel(_fuel == "gas")
	if _jet >= 0:
		_demo.set_capture_jet(_jet)
	if _windx != 0.0:
		_demo.set_capture_wind_x(_windx)
	if _scale > 0.0:
		_demo.set_render_scale(_scale)
	if _advection >= 0:
		_demo.set_advection_mode(_advection)
	if _vorticity >= 0:
		_demo.set_vorticity_mode(_vorticity)
	if _vort_interval > 0:
		solver.vorticity_interval = _vort_interval
	if _keep > 0.0:
		solver.tile_keep_scale = _keep
	if _sim_hz > 0:
		solver.set_simulation_hz(_sim_hz)
	solver.profiling = true
	if not await _wait_ready():
		return
	# UserSettings restores the persisted window size once the autoloads are in;
	# force the requested size back so the measurement is deterministic.
	root.size = _size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = _max_fps
	for frame in _warmup:
		await process_frame

	var clock_start: Dictionary = solver.get_clock_stats()
	var deltas := PackedFloat64Array()
	var last := Time.get_ticks_usec()
	var deadline := last + int(_seconds * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		var now := Time.get_ticks_usec()
		deltas.append(float(now - last) / 1000.0)
		last = now

	var sorted := deltas.duplicate()
	sorted.sort()
	var total := 0.0
	for ms in deltas:
		total += ms
	var p50 := sorted[int(sorted.size() * 0.5)]
	var p95 := sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)]
	var missed := 0
	for ms in deltas:
		if ms > 1000.0 / 30.0 * 1.1:
			missed += 1
	print("PERF MISS30 label=%s missed=%d/%d (%.1f%%)" % [
		_label, missed, deltas.size(), 100.0 * missed / maxf(deltas.size(), 1.0)])
	var mem_mb := float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0
	var stats: Dictionary = solver.get_stats()
	var pool: Dictionary = solver.get_debug_pool_stats()
	print("PERF label=%s p50=%.2f p95=%.2f mean=%.2f min=%.2f max=%.2f frames=%d size=%dx%d preset=%d pressure=%d slots=%d budget=%s tiles=%d/%d mem_mb=%.1f temp=%d react=%.3f div=%.4f" % [
		_label, p50, p95, total / deltas.size(), sorted[0], sorted[-1],
		deltas.size(), _size.x, _size.y, _preset,
		solver.pressure_iterations, solver.atlas_slots,
		str(solver.pool_budget),
		int(pool.get("resident", 0)), int(pool.get("budget", solver.pool_budget)),
		mem_mb, int(stats["max_temperature"]), stats["total_reaction"],
		stats["max_divergence"]])
	var clock_end: Dictionary = solver.get_clock_stats()
	var sim_span := float(clock_end["simulation_time"]) - float(clock_start["simulation_time"])
	var wall_span := float(clock_end["wall_time"]) - float(clock_start["wall_time"])
	print("PERF CLOCK label=%s ratio=%.3f scale=%.2f advection=%d vorticity=%d interval=%d sim_hz=%d" % [
		_label, sim_span / maxf(wall_span, 1e-6), _scale, solver.advection_mode,
		solver.vorticity_mode, solver.vorticity_interval, solver.simulation_hz])
	var timings: Dictionary = solver.get_timings()
	if not timings.is_empty():
		var pairs := []
		for key in timings:
			pairs.append("%s=%.2f" % [key, timings[key]])
		pairs.sort_custom(func(a, b): return float(a.split("=")[1]) > float(b.split("=")[1]))
		print("PERF STAGES label=%s %s" % [_label, " ".join(pairs)])
	quit(0)


## Same readiness contract as capture_demo: the demo reports capture_ready()
## when its GPU resources are up, and a pool switch rebuilds them.
func _wait_ready() -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("PERF FAIL: demo did not become ready")
		quit(1)
		return false
	return true
