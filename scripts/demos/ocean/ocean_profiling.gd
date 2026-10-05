class_name OceanProfiling extends RefCounted

const OceanSpraySystem := preload("res://scripts/ocean/ocean_spray.gd")

var capture_enabled := false
var _overlay_enabled := false
var _measurement_suspended := false
var _solver: OceanSolver
var _spray: OceanSpraySystem
var _foam_window: OceanFoamWindow
var _cloudscape: OceanCloudscape
var _quality: SimQualityState
var _viewport_rid: RID
var _guard: ViewportGuard
var _profile_viewport_samples: Array[float] = []
var _profile_cloud_samples: Array[float] = []
var _profile_simulation_samples: Array[float] = []
var _profile_foam_samples: Array[float] = []
var _profile_interaction_capture_samples: Array[float] = []
var _profile_interaction_feedback_samples: Array[float] = []
var _profile_frame_samples: Array[float] = []
var _profile_stage_samples: Dictionary = {}
var _profile_last_gpu_frame := -1
var _profile_last_wall_time_us := 0


func setup(solver: OceanSolver, spray: OceanSpraySystem, foam_window: OceanFoamWindow,
		cloudscape: OceanCloudscape, quality: SimQualityState,
		viewport_rid: RID, guard: ViewportGuard) -> void:
	_solver = solver
	_spray = spray
	_foam_window = foam_window
	_cloudscape = cloudscape
	_quality = quality
	_viewport_rid = viewport_rid
	_guard = guard


func set_overlay_enabled(on: bool) -> void:
	_overlay_enabled = on
	_apply_enabled()


func set_capture_enabled(on: bool) -> void:
	capture_enabled = on
	_profile_viewport_samples.clear()
	_profile_cloud_samples.clear()
	_profile_simulation_samples.clear()
	_profile_foam_samples.clear()
	_profile_interaction_capture_samples.clear()
	_profile_interaction_feedback_samples.clear()
	_profile_frame_samples.clear()
	_profile_stage_samples.clear()
	_profile_last_gpu_frame = -1
	_profile_last_wall_time_us = 0
	_apply_enabled()


func begin_measurement() -> void:
	_measurement_suspended = true
	_apply_enabled()


func end_measurement() -> void:
	_measurement_suspended = false
	_apply_enabled()


func _apply_enabled() -> void:
	if _solver == null:
		return
	var on := capture_enabled or _overlay_enabled
	_solver.profiling = on and not _measurement_suspended
	if is_instance_valid(_foam_window):
		_foam_window.set_profiling(on)
	if is_instance_valid(_cloudscape):
		_cloudscape.set_profiling(on)
	if is_instance_valid(_guard):
		_guard.set_measure_render_time(on)


func stop() -> void:
	capture_enabled = false
	_overlay_enabled = false
	_measurement_suspended = false
	_apply_enabled()
	_solver = null
	_spray = null
	_foam_window = null
	_cloudscape = null
	_quality = null
	_guard = null
	_viewport_rid = RID()


func backend_name() -> String:
	return "Tutorial Gerstner" if _solver.wave_model == OceanSolver.WaveModel.TUTORIAL_GERSTNER else "JONSWAP/TMA"


func profile_label() -> String:
	return _quality.label()


func vram_mb() -> float:
	return (_solver.estimate_vram_bytes() + _spray.estimate_vram_bytes()) / 1048576.0


func overlay_lines() -> PackedStringArray:
	var t := _solver.get_timings()
	var backend_name := "Tutorial Gerstner" \
		if _solver.wave_model == OceanSolver.WaveModel.TUTORIAL_GERSTNER else "JONSWAP/TMA"
	var lines := PackedStringArray(["backend %s | profile %s | VRAM ~%.0f MB" % [
		backend_name, profile_label(),
		(_solver.estimate_vram_bytes() + _spray.estimate_vram_bytes()) / 1048576.0]])
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("spectrum"):
		lines.append("  spectrum %.2f | fft %.2f | generate %.2f | feedback %.2f" % [
			t.get("spectrum", 0.0), t.get("fft", 0.0), t.get("assemble", 0.0),
			t.get("foam", 0.0),
		])
	if t.has("foam_near") or t.has("query"):
		lines.append("  foam_near %.2f | query %.2f ms" % [
			t.get("foam_near", 0.0), t.get("query", 0.0)])
	var interaction_capture_gpu := _foam_window.get_capture_gpu_time()
	var interaction_feedback_gpu := _foam_window.get_feedback_gpu_time()
	if interaction_capture_gpu > 0.0 or interaction_feedback_gpu > 0.0:
		lines.append("interaction capture %.2f | feedback %.2f" % [
			interaction_capture_gpu, interaction_feedback_gpu,
		])
	var cloud_gpu := _cloudscape.get_gpu_time()
	if cloud_gpu > 0.0:
		lines.append("cloud GPU %.2f ms" % cloud_gpu)
	return lines


func statistics() -> Dictionary:
	var timings := _solver.get_timings()
	var simulation_gpu := _median(_profile_simulation_samples,
		timings.get("total", 0.0))
	var simulation_gpu_p95 := _percentile(_profile_simulation_samples, 0.95,
		timings.get("total", 0.0))
	var foam_gpu := _median(_profile_foam_samples,
		timings.get("foam", 0.0) + timings.get("foam_near", 0.0))
	var foam_gpu_p95 := _percentile(_profile_foam_samples, 0.95, foam_gpu)
	var interaction_capture_gpu := _median(_profile_interaction_capture_samples,
		_foam_window.get_capture_gpu_time())
	var interaction_feedback_gpu := _median(_profile_interaction_feedback_samples,
		_foam_window.get_feedback_gpu_time())
	var cloud_gpu := _median(_profile_cloud_samples, _cloudscape.get_gpu_time())
	var cloud_gpu_p95 := _percentile(_profile_cloud_samples, 0.95, cloud_gpu)
	var viewport_gpu := _median(_profile_viewport_samples,
		RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid))
	var viewport_gpu_p95 := _percentile(_profile_viewport_samples, 0.95, viewport_gpu)
	return {
		"sim_gpu": simulation_gpu,
		"sim_gpu_p95": simulation_gpu_p95,
		"foam_gpu": foam_gpu,
		"foam_gpu_p95": foam_gpu_p95,
		"interaction_capture_gpu": interaction_capture_gpu,
		"interaction_feedback_gpu": interaction_feedback_gpu,
		"cloud_gpu": cloud_gpu,
		"cloud_gpu_p95": cloud_gpu_p95,
		"viewport_gpu": viewport_gpu,
		"viewport_gpu_p95": viewport_gpu_p95,
		"foam_near_gpu": timings.get("foam_near", 0.0),
		"query_gpu": timings.get("query", 0.0),
		"frame_ms": _median(_profile_frame_samples, 0.0),
		"frame_p95_ms": _percentile(_profile_frame_samples, 0.95, 0.0),
		"profile_samples": _profile_simulation_samples.size(),
		"stage_p95": _stage_percentiles(),
	}


func collect_sample() -> void:
	if not capture_enabled or _measurement_suspended:
		return
	var wall_time := Time.get_ticks_usec()
	if _profile_last_wall_time_us > 0:
		_profile_frame_samples.append(float(wall_time - _profile_last_wall_time_us) / 1000.0)
		if _profile_frame_samples.size() > 240:
			_profile_frame_samples.pop_front()
	_profile_last_wall_time_us = wall_time
	var timings := _solver.get_timings()
	var gpu_frame: int = timings.get("frame", -1)
	if gpu_frame < 0 or gpu_frame == _profile_last_gpu_frame:
		return
	_profile_last_gpu_frame = gpu_frame
	var simulation: float = timings.get("total", 0.0)
	var foam: float = timings.get("foam_near", 0.0)
	var viewport := RenderingServer.viewport_get_measured_render_time_gpu(
		_viewport_rid)
	if simulation > 0.0 and viewport > 0.0:
		for stage in timings:
			if stage == "frame":
				continue
			if not _profile_stage_samples.has(stage):
				_profile_stage_samples[stage] = [] as Array[float]
			var samples: Array[float] = _profile_stage_samples[stage]
			samples.append(float(timings[stage]))
			if samples.size() > 240:
				samples.pop_front()
		_profile_simulation_samples.append(simulation)
		_profile_foam_samples.append(foam)
		_profile_interaction_capture_samples.append(_foam_window.get_capture_gpu_time())
		_profile_interaction_feedback_samples.append(_foam_window.get_feedback_gpu_time())
		_profile_cloud_samples.append(_cloudscape.get_gpu_time())
		_profile_viewport_samples.append(viewport)
		if _profile_viewport_samples.size() > 240:
			_profile_simulation_samples.pop_front()
			_profile_foam_samples.pop_front()
			_profile_interaction_capture_samples.pop_front()
			_profile_interaction_feedback_samples.pop_front()
			_profile_cloud_samples.pop_front()
			_profile_viewport_samples.pop_front()


func _stage_percentiles() -> Dictionary:
	var values := {}
	for stage in _profile_stage_samples:
		values[stage] = _percentile(_profile_stage_samples[stage], 0.95, 0.0)
	return values


static func _median(values: Array[float], fallback: float) -> float:
	if values.is_empty():
		return fallback
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	return sorted[middle] if sorted.size() % 2 == 1 \
		else (sorted[middle - 1] + sorted[middle]) * 0.5


static func _percentile(values: Array[float], quantile: float, fallback: float) -> float:
	if values.is_empty():
		return fallback
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size()) * quantile)) - 1, 0, sorted.size() - 1)
	return sorted[index]
