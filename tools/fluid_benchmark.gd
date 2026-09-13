extends SceneTree

const DEFAULT_WARMUP := 300
const DEFAULT_SAMPLES := 300
const DEFAULT_REPETITIONS := 5

var _demo: Node3D
var _fluid: FluidSystem
var _options := {
	"method": "sph",
	"scenario": "dam",
	"particles": 65536,
	"foam": true,
	"mode": "water",
	"render_scale": 0.5,
	"hash_grid": false,
	"hash_load_factor": 2.0,
	"warmup": DEFAULT_WARMUP,
	"samples": DEFAULT_SAMPLES,
	"repetitions": DEFAULT_REPETITIONS,
	"capture": "",
}


func _initialize() -> void:
	_parse_args()
	_demo = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(_demo)
	_run()


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var key: String = args[i]
		if i + 1 >= args.size():
			printerr("Missing value for %s" % key)
			quit(2)
			return
		var value: String = args[i + 1]
		match key:
			"--method": _options.method = value.to_lower()
			"--scenario": _options.scenario = value.to_lower()
			"--particles": _options.particles = value.to_int()
			"--foam": _options.foam = value.to_lower() in ["1", "true", "on"]
			"--mode": _options.mode = value.to_lower()
			"--render-scale": _options.render_scale = value.to_float()
			"--hash-grid": _options.hash_grid = value.to_lower() in ["1", "true", "on"]
			"--hash-load-factor": _options.hash_load_factor = value.to_float()
			"--warmup": _options.warmup = value.to_int()
			"--samples": _options.samples = value.to_int()
			"--repetitions": _options.repetitions = value.to_int()
			"--capture": _options.capture = value
			_:
				printerr("Unknown option %s" % key)
				quit(2)
				return
		i += 2
	if _options.method not in ["sph", "pbf"]:
		_fail_option("--method must be sph or pbf")
	if _options.scenario not in ["dam", "cascade"]:
		_fail_option("--scenario must be dam or cascade")
	if _options.scenario == "cascade" and _options.method != "sph":
		_fail_option("--scenario cascade requires --method sph")
	if _options.mode not in ["water", "lava"]:
		_fail_option("--mode must be water or lava")
	if _options.particles not in [16384, 32768, 65536]:
		_fail_option("--particles must be 16384, 32768, or 65536")
	if _options.render_scale not in [0.5, 1.0]:
		_fail_option("--render-scale must be 0.5 or 1.0")
	if _options.warmup < 1 or _options.samples < 1 or _options.repetitions < 1:
		_fail_option("--warmup, --samples, and --repetitions must be positive")


func _fail_option(message: String) -> void:
	printerr(message)
	quit(2)


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		printerr("Fluid benchmark requires a non-headless RenderingDevice")
		quit(2)
		return
	for _i in 3:
		await process_frame
	_fluid = _demo.fluid
	var wanted_scenario := FluidSystem.Scenario.CASCADE \
		if _options.scenario == "cascade" else FluidSystem.Scenario.DAM
	if _fluid.scenario != wanted_scenario:
		_demo._on_scenario_selected(wanted_scenario)
		await _settle_rebuild()
	var wanted_method := FluidSystem.Method.PBF if _options.method == "pbf" else FluidSystem.Method.SPH
	if _fluid.method != wanted_method:
		_fluid.set_method(wanted_method)
		await _settle_rebuild()
	if _fluid.particle_count != _options.particles:
		_fluid.set_particle_count(_options.particles)
		await _settle_rebuild()
	var wanted_mode := 1.0 if _options.mode == "lava" else 0.0
	if not is_equal_approx(_fluid.mode, wanted_mode):
		_fluid.set_mode(wanted_mode)
		await _settle_rebuild()
	_fluid.set_foam_enabled(_options.foam)
	_fluid.set_render_scale(_options.render_scale)
	if _fluid.method == FluidSystem.Method.SPH:
		_fluid.sph_solver.hash_grid_enabled = _options.hash_grid
		_fluid.sph_solver.hash_grid_load_factor = _options.hash_load_factor
		if _options.hash_grid:
			_fluid.restart()
			await _settle_rebuild()
	_fluid.set_profiling(true)
	for viewport in _fluid.profiled_viewports() + [root]:
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)

	for _i in _options.warmup:
		await process_frame

	var repetitions: Array[Dictionary] = []
	for repetition in _options.repetitions:
		repetitions.append(await _measure(repetition))

	var validation := {"done": false}
	_fluid.request_validation_stats(validation)
	while not validation.done:
		await process_frame
	validation.erase("done")

	var result := {
		"config": _benchmark_config(),
		"repetitions": repetitions,
		"summary": _summarize_repetitions(repetitions),
		"validation": validation,
	}
	print("FLUID_BENCHMARK %s" % JSON.stringify(result))
	if not _options.capture.is_empty():
		await RenderingServer.frame_post_draw
		var error := root.get_texture().get_image().save_png(_options.capture)
		if error != OK:
			printerr("Could not save capture %s: %s" % [_options.capture, error_string(error)])
			quit(3)
			return
	print("BENCHMARK DONE")
	quit(0)


func _benchmark_config() -> Dictionary:
	var config := _options.duplicate()
	config["effective_foam"] = _fluid.method == FluidSystem.Method.SPH \
		and _fluid.foam_enabled and _fluid.mode < 0.5
	return config


func _settle_rebuild() -> void:
	for _i in 8:
		await process_frame
	while _fluid.active() == null or not _fluid.active().initialized:
		await process_frame


func _measure(index: int) -> Dictionary:
	var samples := {}
	var last_ticks := Time.get_ticks_usec()
	for _frame in _options.samples:
		await process_frame
		var now := Time.get_ticks_usec()
		_add_sample(samples, "frame", float(now - last_ticks) / 1000.0)
		last_ticks = now
		var timings: Dictionary = _fluid.get_timings()
		for key in timings:
			_add_sample(samples, "sim_" + String(key), float(timings[key]))
		var viewports := _fluid.profiled_viewports()
		for entry in [["depth", 0], ["thickness", 1], ["filter_h", 2], ["filter_v", 3], ["foam", 4]]:
			var viewport: SubViewport = viewports[entry[1]]
			_add_sample(samples, entry[0], RenderingServer.viewport_get_measured_render_time_gpu(
				viewport.get_viewport_rid()))
		_add_sample(samples, "root_gpu", RenderingServer.viewport_get_measured_render_time_gpu(
			root.get_viewport_rid()))
	var out := {"index": index}
	for key in samples:
		out[key] = _stats(samples[key])
	out["composite"] = await _estimate_composite(out.root_gpu)
	return out


func _estimate_composite(active_root_gpu: Dictionary) -> Dictionary:
	_fluid.renderer.composite_mi.visible = false
	var values: Array[float] = []
	for _frame in 30:
		await process_frame
		var value := RenderingServer.viewport_get_measured_render_time_gpu(
			root.get_viewport_rid())
		if value > 0.0 and is_finite(value):
			values.append(value)
	_fluid.renderer.composite_mi.visible = true
	var without_composite := _stats(values)
	return {
		"mean": maxf(0.0, float(active_root_gpu.mean) - float(without_composite.mean)),
		"median": maxf(0.0, float(active_root_gpu.median) - float(without_composite.median)),
		"p95": maxf(0.0, float(active_root_gpu.p95) - float(without_composite.p95)),
		"samples": values.size(),
	}


func _add_sample(samples: Dictionary, key: String, value: float) -> void:
	if value <= 0.0 or not is_finite(value):
		return
	if not samples.has(key):
		samples[key] = [] as Array[float]
	(samples[key] as Array[float]).append(value)


func _stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "median": 0.0, "p95": 0.0, "samples": 0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	return {
		"mean": total / float(sorted.size()),
		"median": _percentile(sorted, 0.5),
		"p95": _percentile(sorted, 0.95),
		"samples": sorted.size(),
	}


func _percentile(sorted: Array[float], quantile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := clampi(int(ceil(quantile * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return sorted[index]


func _summarize_repetitions(repetitions: Array[Dictionary]) -> Dictionary:
	var combined := {}
	for repetition in repetitions:
		for key in repetition:
			if key == "index":
				continue
			if not combined.has(key):
				combined[key] = [] as Array[float]
			(combined[key] as Array[float]).append(float(repetition[key].median))
	var out := {}
	for key in combined:
		out[key] = _stats(combined[key])
	return out
