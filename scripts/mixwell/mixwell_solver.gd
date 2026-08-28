class_name MixwellSolver
extends RefCounted

const Gallery := preload("res://scripts/mixwell/mixwell_gallery.gd")
const Periodicity := preload("res://scripts/mixwell/mixwell_periodicity.gd")
const Boundaries := preload("res://scripts/mixwell/mixwell_boundaries.gd")
const Snapshot := preload("res://scripts/mixwell/mixwell_render_snapshot.gd")
const Pattern := preload("res://scripts/mixwell/mixwell_pattern.gd")
const Diagnostics := preload("res://scripts/mixwell/mixwell_diagnostics.gd")
const SHADER_DIR := "res://shaders/mixwell/"
const WG := 256
const STAGES := ["init", "rd_line", "rd_segment", "affine", "shade", "diagnostics", "accumulate", "diagnostics_reduce"]
const DESKTOP_SEGMENT_LIMIT := 256
const MOBILE_SEGMENT_LIMIT := 128
const DIAGNOSTIC_REDUCTION_STRIDE := 48

var config: MixwellConfig = MixwellConfig.new()
var initialized := false
var profiling := false

var _size := Vector2i.ZERO
var _reference_size := Vector2i.ZERO
var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _init_uniform_set := RID()
var _textures := {}
var _segment_buffer := RID()
var _diagnostic_ops_buffer := RID()
var _diagnostic_reduction_buffer := RID()
var _diagnostic_group_count := 0
var _segments_px: Array[Vector4] = []
var _preset_segments: Array[Vector4] = []
var _pattern = Pattern.new()
var _pattern_step := -1
var _preset_id := Gallery.SINGLE_LINE
var _source_mode := 0
var _parity := 0
var _sample_count := 0
var _period_fixed := Vector2i.ZERO
var _periodic_comparison := {}
var _gpu_periodic_comparison := {}
var _gpu_oracle_comparison := {}
var _force_periodic_validation := false
var _affine_mode := -1
var _wall_calibration := 1.0
var _last_sample_gpu_ms := 1.0
var _timing_store := GpuTimingStore.new()
var _metrics := {
	"area_error": 0.0,
	"max_area_error": 0.0,
	"area_p99": 0.0,
	"area_core": 0.0,
	"area_singularity": 0.0,
	"area_cutoff": 0.0,
	"area_boundary": 0.0,
	"area_wall": 0.0,
	"area_valid_count": 0,
	"area_valid_p99": 0.0,
	"area_core_p99": 0.0,
	"convergence_error": 0.0,
	"convergence_rms": 0.0,
	"convergence_p99": 0.0,
	"sample": 0,
}
var _metrics_mutex := Mutex.new()
var _state_mutex := Mutex.new()
var _snapshot_version := 0
var _render_snapshot
var _render_profiling := false
var _diagnostics_enabled := false


func initialize(size: Vector2i, value: MixwellConfig = null,
		reference_size := Vector2i.ZERO) -> void:
	_size = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	if value != null:
		config = value
	if reference_size.x > 0 and reference_size.y > 0:
		_reference_size = reference_size
	elif _reference_size.x <= 0 or _reference_size.y <= 0:
		_reference_size = _size
	_source_mode = config.source_mode
	_refresh_periodicity()
	_snapshot_version += 1


func create_render_snapshot(size_override := Vector2i.ZERO,
		reference_override := Vector2i.ZERO):
	var result := Snapshot.new()
	result.version = _snapshot_version
	result.size = _size if size_override == Vector2i.ZERO else Vector2i(
		maxi(size_override.x, 1), maxi(size_override.y, 1))
	result.reference_size = _reference_size if reference_override == Vector2i.ZERO else reference_override
	result.source_mode = _source_mode
	result.boundary_mode = config.boundary_mode
	result.active_boundary_mode = get_active_boundary_mode()
	result.periodic_optimized = result.active_boundary_mode == MixwellConfig.BoundaryMode.PERIODIC
	result.drift_compensation = config.drift_compensation
	result.affine_mode = _affine_mode
	result.profiling = profiling
	result.diagnostics_enabled = _diagnostics_enabled
	result.brush_radius_px = config.brush_radius_px
	result.midpoint_alpha = config.midpoint_alpha
	result.cutoff_gamma = config.cutoff_gamma
	result.affine_radius_px = config.affine_radius_px
	result.affine_strength = config.affine_strength
	var pattern_descriptor: Dictionary = _pattern.serialize()
	pattern_descriptor["active_operations"] = _active_pattern_count()
	pattern_descriptor["active_step"] = _pattern_step
	result.pattern = pattern_descriptor
	result.pattern_step = _pattern_step
	result.operations = _physical_operations()
	result.periodic_plan = _periodic_operation_plan(result.operations, true, result.size)
	result.fullscreen_plan = _periodic_operation_plan(result.operations, false, result.size)
	result.periodic_domain = _plan_domain(result.periodic_plan, result.size)
	result.fullscreen_domain = _plan_domain(result.fullscreen_plan, result.size)
	result.periodic_movement_dispatch_pixels = _plan_movement_dispatch_pixels(
			result.periodic_plan, result.size)
	result.fullscreen_movement_dispatch_pixels = _plan_movement_dispatch_pixels(
			result.fullscreen_plan, result.size)
	result.periodic_dispatch_pixels = result.periodic_movement_dispatch_pixels \
			+ result.size.x * result.size.y * 2
	result.fullscreen_dispatch_pixels = result.fullscreen_movement_dispatch_pixels \
			+ result.size.x * result.size.y * 2
	var active_plan := result.periodic_plan if result.periodic_optimized else result.fullscreen_plan
	var active_domain: Vector2i = result.size if active_plan.is_empty() else active_plan.back().current
	result.period_fixed = Periodicity.quantize_period(_periodic_coordinate_period(active_domain,
			result.reference_size, result.size))
	return result


func is_initialized() -> bool:
	_state_mutex.lock()
	var result := initialized
	_state_mutex.unlock()
	return result


func is_profiling() -> bool:
	return profiling


func set_profiling(enabled: bool) -> void:
	profiling = enabled
	_snapshot_version += 1


func set_diagnostics_enabled(enabled: bool) -> void:
	_diagnostics_enabled = enabled
	_snapshot_version += 1


func mark_snapshot_dirty() -> void:
	_snapshot_version += 1


func diagnostics_enabled() -> bool:
	return _diagnostics_enabled


func set_strokes(strokes: Array, base_preset := Gallery.FREEHAND_LAB) -> void:
	_segments_px.clear()
	_preset_segments.clear()
	var preset_id := clampi(base_preset, Gallery.SINGLE_LINE, Gallery.PAINT_SPREAD)
	_pattern = Gallery.preset_pattern(preset_id) if preset_id != Gallery.FREEHAND_LAB \
			else Pattern.new()
	_pattern_step = -1
	_pattern.id = preset_id
	_pattern.name = Gallery.preset_name(preset_id)
	_pattern.source_metadata = {
		"family": "Mixwell RDF construction with user brush strokes",
		"preset_id": preset_id,
		"construction": "published preset followed by retained user strokes",
	}
	_affine_mode = preset_id if Gallery.is_affine(preset_id) else -1
	_preset_id = preset_id
	_preset_segments = Gallery.preset_segments(preset_id)
	_snapshot_version += 1
	var segment_limit := get_segment_limit()
	var operations: Array[Dictionary] = _pattern.to_render_operations()
	var segment_pass_index := 0
	for item in strokes:
		if item is MixwellStroke:
			var stroke := item as MixwellStroke
			if stroke.validate() == "":
				for segment in stroke.to_segments(segment_limit - _segments_px.size()):
					_segments_px.append(segment)
					operations.append({"type": Gallery.SEGMENT, "segment": _normalize_segment(segment),
						"period": Vector2.ZERO, "period_pixels": Vector2i.ZERO,
						"pitch": 0.0, "count": 1, "noise": 0.0,
						"radius_px": stroke.radius_px, "curve_group": 100000 + segment_pass_index})
					segment_pass_index += 1
					if _segments_px.size() >= segment_limit:
						_pattern.set_operations(operations)
						_refresh_periodicity()
						return
	_pattern.set_operations(operations)
	_refresh_periodicity()


func set_preset(id: int) -> void:
	_segments_px.clear()
	_preset_segments.clear()
	_preset_id = clampi(id, Gallery.SINGLE_LINE, Gallery.PAINT_SPREAD)
	if Gallery.is_affine(id):
		_preset_id = clampi(id, Gallery.TWIST, Gallery.PINCH)
	_affine_mode = _preset_id if Gallery.is_affine(_preset_id) else -1
	_pattern = Gallery.preset_pattern(_preset_id)
	_pattern_step = -1
	_preset_segments = Gallery.preset_segments(_preset_id)
	_snapshot_version += 1
	_refresh_periodicity()


func set_source_mode(mode: int) -> void:
	_source_mode = clampi(mode, 0, 3)
	config.source_mode = _source_mode
	_snapshot_version += 1


func set_drift_compensation(mode: int) -> void:
	config.drift_compensation = clampi(mode, MixwellConfig.DriftCompensation.NONE,
			MixwellConfig.DriftCompensation.MEAN)
	_snapshot_version += 1


func set_boundary_mode(mode: int) -> void:
	config.boundary_mode = clampi(mode, MixwellConfig.BoundaryMode.FULLSCREEN,
		MixwellConfig.BoundaryMode.SLIP_WALLS)
	_snapshot_version += 1
	_refresh_periodicity()


func get_boundary_mode() -> int:
	return config.boundary_mode


func get_active_boundary_mode() -> int:
	if config.boundary_mode == MixwellConfig.BoundaryMode.SLIP_WALLS:
		return MixwellConfig.BoundaryMode.SLIP_WALLS
	if config.boundary_mode != MixwellConfig.BoundaryMode.PERIODIC:
		return MixwellConfig.BoundaryMode.FULLSCREEN
	if _force_periodic_validation:
		return MixwellConfig.BoundaryMode.PERIODIC
	return MixwellConfig.BoundaryMode.PERIODIC if _periodic_comparison.get("passes", true) \
			else MixwellConfig.BoundaryMode.FULLSCREEN


func get_period_fixed() -> Vector2i:
	return _period_fixed


func get_period() -> Vector2:
	return Periodicity.dequantize_period(_period_fixed)


func get_periodic_comparison() -> Dictionary:
	return _periodic_comparison.duplicate()


func get_gpu_periodic_comparison() -> Dictionary:
	return _gpu_periodic_comparison.duplicate()


func get_periodic_dispatch_stats() -> Dictionary:
	var snapshot = create_render_snapshot()
	var periodic_pixels := maxi(snapshot.periodic_dispatch_pixels, 1)
	var fullscreen_pixels := maxi(snapshot.fullscreen_dispatch_pixels, 1)
	return {
		"periodic_domain": snapshot.periodic_domain,
		"fullscreen_domain": snapshot.fullscreen_domain,
		"periodic_movement_pixels": snapshot.periodic_movement_dispatch_pixels,
		"fullscreen_movement_pixels": snapshot.fullscreen_movement_dispatch_pixels,
		"periodic_dispatch_pixels": snapshot.periodic_dispatch_pixels,
		"fullscreen_dispatch_pixels": snapshot.fullscreen_dispatch_pixels,
		"dispatch_reduction": 1.0 - float(periodic_pixels) / float(fullscreen_pixels),
		"estimated_speedup": float(fullscreen_pixels) / float(periodic_pixels),
	}


func get_gpu_oracle_comparison() -> Dictionary:
	return _gpu_oracle_comparison.duplicate()


func get_wall_calibration() -> float:
	return _wall_calibration


func get_drift_compensation() -> int:
	return config.drift_compensation


func get_preset_id() -> int:
	return _preset_id


func get_preset_names() -> Array[String]:
	return Gallery.all_preset_names()


func get_compensation_names() -> Array[String]:
	return Gallery.compensation_names()


func get_segment_limit() -> int:
	return MOBILE_SEGMENT_LIMIT if OS.has_feature("mobile") \
			or OS.get_environment("FORCE_TOUCH_UI") == "1" else DESKTOP_SEGMENT_LIMIT


func get_segment_count() -> int:
	return _segments_px.size() if _preset_id == Gallery.FREEHAND_LAB else _preset_segments.size()


func get_operation_count() -> int:
	return _pattern.operation_count()


func get_pattern_operation_count() -> int:
	return _pattern.operation_count()


func get_pattern_step() -> int:
	return _pattern_step


func set_pattern_step(step: int) -> void:
	var total: int = _pattern.operation_count()
	var next := -1 if step < 0 or step >= total else maxi(step, 0)
	if next == _pattern_step:
		return
	_pattern_step = next
	_snapshot_version += 1
	_refresh_periodicity()


func get_pattern_descriptor() -> Dictionary:
	var result: Dictionary = _pattern.serialize()
	result["active_operations"] = _active_pattern_count()
	result["active_step"] = _pattern_step
	return result


func get_segments() -> Array[Vector4]:
	return _normalized_segments()


func get_segments_physical_order() -> Array[Vector4]:
	var result: Array[Vector4] = []
	var segments := _normalized_segments()
	for index in range(segments.size() - 1, -1, -1):
		result.append(segments[index])
	return result


func get_sample_count() -> int:
	_state_mutex.lock()
	var result := _sample_count
	_state_mutex.unlock()
	return result


func get_samples_for_budget(current_index: int, target_spp: int,
		preview := false) -> int:
	var target := 1 if preview else target_spp
	if current_index >= target:
		return 0
	if preview:
		return 1
	var estimate := maxf(_last_sample_gpu_ms, 0.25)
	var count := maxi(1, int(floor(config.gpu_budget_ms / estimate)))
	return mini(count, target - current_index)


func get_refinement_state(target_spp := -1, preview := false) -> Dictionary:
	var target := 1 if preview else (config.target_spp if target_spp < 0 else target_spp)
	var completed := mini(get_sample_count(), target)
	return {
		"sample": completed,
		"target": target,
		"progress": float(completed) / float(maxi(target, 1)),
		"budget_ms": config.gpu_budget_ms,
		"sample_gpu_ms": _last_sample_gpu_ms,
		"timings": get_timings(),
	}


func get_render_size() -> Vector2i:
	_state_mutex.lock()
	var result := _size
	_state_mutex.unlock()
	return result


func get_metrics() -> Dictionary:
	_metrics_mutex.lock()
	var result := _metrics.duplicate()
	_metrics_mutex.unlock()
	return result


func reset_accumulation() -> void:
	_state_mutex.lock()
	_sample_count = 0
	_state_mutex.unlock()
	_metrics_mutex.lock()
	_metrics = {
		"area_error": 0.0,
		"max_area_error": 0.0,
		"area_p99": 0.0,
		"area_core": 0.0,
		"area_singularity": 0.0,
		"area_cutoff": 0.0,
		"area_boundary": 0.0,
		"area_wall": 0.0,
		"area_valid_count": 0,
		"area_valid_p99": 0.0,
		"area_core_p99": 0.0,
		"convergence_error": 0.0,
		"convergence_rms": 0.0,
		"convergence_p99": 0.0,
		"sample": 0,
	}
	_metrics_mutex.unlock()
	if _rd == null or not initialized:
		return
	if _textures.has("accumulation") and _textures.accumulation.is_valid():
		_rd.texture_clear(_textures.accumulation, Color(0, 0, 0, 0), 0, 1, 0, 1)
	if _textures.has("convergence") and _textures.convergence.is_valid():
		_rd.texture_clear(_textures.convergence, Color(0, 0, 0, 0), 0, 1, 0, 1)


func render_sample(index: int, snapshot = null) -> void:
	if not initialized or _rd == null:
		return
	var active_snapshot = snapshot if snapshot != null else _render_snapshot
	if active_snapshot == null:
		return
	_render_snapshot = active_snapshot
	_render_profiling = active_snapshot.profiling
	_read_timings()
	var operations: Array[Dictionary] = active_snapshot.operations
	var optimized: bool = active_snapshot.periodic_optimized
	var plan: Array[Dictionary] = active_snapshot.periodic_plan if optimized \
		else active_snapshot.fullscreen_plan
	var initial_domain: Vector2i = active_snapshot.size if plan.is_empty() else plan[0]["current"]
	var initial_period := _periodic_coordinate_period(initial_domain, active_snapshot.reference_size,
			active_snapshot.size)
	var pc := _pack_push_constant(index, Vector4.ZERO, -1.0, {}, initial_domain,
			initial_domain, initial_period, optimized, active_snapshot)
	var groups_x := ceili(float(initial_domain.x * initial_domain.y) / WG)
	_upload_segment_buffer(operations)
	if active_snapshot.diagnostics_enabled:
		_upload_diagnostic_operations(operations)
	if _render_profiling:
		_rd.capture_timestamp("mixwell/start")
	var cl := _rd.compute_list_begin()
	_parity = 1
	var segment_buffer_offset := 0
	_dispatch(cl, "init", pc, groups_x, true)
	cl = _mark(cl, "mixwell/init")

	var operation_index := 0
	while operation_index < operations.size():
		var operation: Dictionary = operations[operation_index]
		var period_pass: Dictionary = plan[operation_index]
		var operation_count := 1
		if int(operation.get("type", Gallery.LINE)) == Gallery.SEGMENT:
			while operation_index + operation_count < operations.size() \
					and int(operations[operation_index + operation_count].get("type", Gallery.LINE)) \
					== Gallery.SEGMENT \
					and operations[operation_index + operation_count].get("curve_group", -1) \
							== operation.get("curve_group", -1) \
					and plan[operation_index + operation_count]["current"] == period_pass["current"] \
					and plan[operation_index + operation_count]["previous"] == period_pass["previous"]:
				operation_count += 1
		var stage := "affine" if int(operation.type) == Gallery.LINE and active_snapshot.affine_mode >= 0 \
				else ("rd_line" if int(operation.type) != Gallery.SEGMENT else "rd_segment")
		var segment: Vector4 = operation.get("segment", Vector4.ZERO)
		var radius: float = _operation_radius(operation, active_snapshot)
		var current_domain: Vector2i = period_pass["current"]
		var previous_domain: Vector2i = period_pass["previous"]
		var operation_pc := _pack_push_constant(index, segment, radius, operation,
				current_domain, previous_domain, _periodic_coordinate_period(current_domain,
				active_snapshot.reference_size, active_snapshot.size), optimized, active_snapshot)
		if stage == "rd_segment":
			var dispatch_count := operation_count
			if optimized:
				dispatch_count = mini(dispatch_count,
						maxi(int(operation.get("periodic_segment_count", 0)), 0) \
							if operation.get("curve_group", -1) >= 0 else dispatch_count)
			if dispatch_count <= 0:
				operation_index += operation_count
				segment_buffer_offset += operation_count
				continue
			operation_pc.encode_s32(88, dispatch_count)
			operation_pc.encode_float(92, float(segment_buffer_offset))
		var operation_groups := ceili(float(current_domain.x * current_domain.y) / WG)
		_dispatch(cl, stage, operation_pc, operation_groups)
		_parity = 1 - _parity
		cl = _mark(cl, "mixwell/%s" % stage)
		if stage == "rd_segment":
			segment_buffer_offset += operation_count
		operation_index += operation_count

	var final_previous: Vector2i = initial_domain if plan.is_empty() else plan.back()["current"]
	var final_period := _periodic_coordinate_period(final_previous, active_snapshot.reference_size,
			active_snapshot.size)
	var shade_pc := _pack_push_constant(index, Vector4.ZERO, -1.0, {}, active_snapshot.size,
			final_previous, final_period, optimized, active_snapshot)
	var full_groups := ceili(float(active_snapshot.size.x * active_snapshot.size.y) / WG)
	_dispatch(cl, "shade", shade_pc, full_groups)
	cl = _mark(cl, "mixwell/shade")
	if active_snapshot.diagnostics_enabled:
		_dispatch(cl, "diagnostics", shade_pc, full_groups)
		cl = _mark(cl, "mixwell/diagnostics")
	_dispatch(cl, "accumulate", shade_pc, full_groups)
	_rd.compute_list_end()
	if _render_profiling:
		_rd.capture_timestamp("mixwell/accumulate")
		_rd.capture_timestamp("mixwell/end")
	_state_mutex.lock()
	_sample_count = maxi(_sample_count, index + 1)
	_state_mutex.unlock()


func render_samples(first_index: int, count: int, snapshot = null) -> void:
	if count <= 0:
		return
	for index in count:
		render_sample(first_index + index, snapshot)


func resize_render(size: Vector2i, reference_size := Vector2i.ZERO,
		snapshot = null) -> void:
	var next_size := Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	if reference_size.x > 0 and reference_size.y > 0:
		_reference_size = reference_size
	if _rd != null or initialized:
		free_render()
	_state_mutex.lock()
	_size = next_size
	_state_mutex.unlock()
	init_render(snapshot)


func get_display_texture() -> RID:
	return _textures.get("accumulation", RID())


func get_source_texture() -> RID:
	return _textures.get("source", RID())


func get_diagnostic_texture() -> RID:
	return _textures.get("diagnostic", RID())


func get_timings() -> Dictionary:
	return _timing_store.snapshot()


func poll_timings() -> void:
	if _rd == null or not initialized:
		return
	_read_timings()


func readback_displacement() -> PackedFloat32Array:
	if _rd == null or not initialized:
		return PackedFloat32Array()
	var key := "disp_a" if _parity == 0 else "disp_b"
	var bytes := _rd.texture_get_data(_textures[key], 0)
	return bytes.to_float32_array()


func readback_diagnostics() -> PackedFloat32Array:
	if _rd == null or not initialized:
		return PackedFloat32Array()
	return _readback_rgba16f(_textures.diagnostic)


func verify_gpu_oracle() -> void:
	_gpu_oracle_comparison = {}
	if _rd == null or not initialized or _render_snapshot == null:
		_gpu_oracle_comparison = {"passes": false, "reason": "renderer unavailable"}
		return
	if _render_snapshot.operations.size() != 1:
		_gpu_oracle_comparison = {"passes": false, "reason": "oracle expects one operation"}
		return
	var pixel := Vector2i(_size.x / 2, _size.y / 2)
	var sample_index := maxi(get_sample_count() - 1, 0)
	var jitter := Periodicity.r2_sample(sample_index)
	var aspect := float(_size.x) / float(maxi(_size.y, 1))
	var coordinate := (Vector2(pixel) + jitter) / Vector2(_size) * 2.0 \
			* Vector2(aspect, 1.0) - Vector2(aspect, 1.0)
	var reference_min := float(maxi(mini(_render_snapshot.reference_size.x,
			_render_snapshot.reference_size.y), 1))
	var operation: Dictionary = _render_snapshot.operations[0]
	var radius := _operation_radius(operation, _render_snapshot)
	var epsilon := radius * 2.0 / reference_min
	var expected := Diagnostics.oracle_expected(operation, coordinate, epsilon,
			_render_snapshot.midpoint_alpha)
	var values := readback_diagnostics()
	var offset := (pixel.y * _size.x + pixel.x) * 4
	if values.size() < offset + 2 or expected.size() != 2:
		_gpu_oracle_comparison = {"passes": false, "reason": "diagnostic readback unavailable"}
		return
	var actual := Vector2(values[offset], values[offset + 1])
	var error := actual.distance_to(Vector2(expected[0], expected[1]))
	_gpu_oracle_comparison = {
		"passes": error <= 8.0e-4,
		"preset": _preset_id,
		"sample": sample_index,
		"pixel": pixel,
		"error": error,
		"actual": actual,
		"expected": Vector2(expected[0], expected[1]),
	}


func verify_periodic_gpu_ab() -> void:
	_gpu_periodic_comparison = {}
	if _rd == null or not initialized:
		_gpu_periodic_comparison = {"passes": false, "reason": "renderer unavailable"}
		return
	var base_snapshot = _render_snapshot
	if base_snapshot == null:
		_gpu_periodic_comparison = {"passes": false, "reason": "render snapshot unavailable"}
		return
	var periodic_snapshot = base_snapshot.boundary_copy(
		MixwellConfig.BoundaryMode.PERIODIC, true)
	var fullscreen_snapshot = base_snapshot.boundary_copy(
		MixwellConfig.BoundaryMode.PERIODIC, false)
	periodic_snapshot.profiling = true
	fullscreen_snapshot.profiling = true
	var periodic_start := Time.get_ticks_usec()
	reset_accumulation()
	render_sample(0, periodic_snapshot)
	var periodic_values := readback_diagnostics()
	var periodic_colours := _readback_rgba16f(_textures.sample)
	var periodic_elapsed_ms := float(Time.get_ticks_usec() - periodic_start) / 1000.0
	var periodic_gpu_timing := GpuTimings.read(_rd, "mixwell/", true)
	var fullscreen_start := Time.get_ticks_usec()
	reset_accumulation()
	render_sample(0, fullscreen_snapshot)
	var fullscreen_values := readback_diagnostics()
	var fullscreen_colours := _readback_rgba16f(_textures.sample)
	var fullscreen_elapsed_ms := float(Time.get_ticks_usec() - fullscreen_start) / 1000.0
	var fullscreen_gpu_timing := GpuTimings.read(_rd, "mixwell/", true)
	_gpu_periodic_comparison = Diagnostics.compare_gpu_diagnostics(periodic_values,
			fullscreen_values, periodic_colours, fullscreen_colours, _size,
			_coordinate_period(_size))
	_gpu_periodic_comparison["periodic_domain"] = periodic_snapshot.periodic_domain
	_gpu_periodic_comparison["fullscreen_domain"] = fullscreen_snapshot.fullscreen_domain
	_gpu_periodic_comparison["periodic_movement_pixels"] = \
			periodic_snapshot.periodic_movement_dispatch_pixels
	_gpu_periodic_comparison["fullscreen_movement_pixels"] = \
			fullscreen_snapshot.fullscreen_movement_dispatch_pixels
	_gpu_periodic_comparison["periodic_dispatch_pixels"] = periodic_snapshot.periodic_dispatch_pixels
	_gpu_periodic_comparison["fullscreen_dispatch_pixels"] = fullscreen_snapshot.fullscreen_dispatch_pixels
	_gpu_periodic_comparison["dispatch_reduction"] = 1.0 - float(
			periodic_snapshot.periodic_dispatch_pixels) / float(maxi(
			fullscreen_snapshot.fullscreen_dispatch_pixels, 1))
	var periodic_measured_ms := float(periodic_gpu_timing.get("total", periodic_elapsed_ms))
	var fullscreen_measured_ms := float(fullscreen_gpu_timing.get("total", fullscreen_elapsed_ms))
	_gpu_periodic_comparison["periodic_elapsed_ms"] = periodic_measured_ms
	_gpu_periodic_comparison["fullscreen_elapsed_ms"] = fullscreen_measured_ms
	_gpu_periodic_comparison["measured_speedup"] = fullscreen_measured_ms / maxf(periodic_measured_ms, 1.0e-6)
	_gpu_periodic_comparison["timing_source"] = "gpu_timestamp" \
			if periodic_gpu_timing.has("total") and fullscreen_gpu_timing.has("total") else "wall_sync"
	if not _gpu_periodic_comparison.get("passes", false):
		_periodic_comparison["passes"] = false
		_periodic_comparison["active"] = false
	reset_accumulation()
	_render_snapshot = base_snapshot


func update_metrics(force := false) -> void:
	if _rd == null or not initialized:
		return
	if not _diagnostics_enabled and not force:
		return
	if not _diagnostic_reduction_buffer.is_valid() or _diagnostic_group_count <= 0:
		return
	var sample_index := maxi(get_sample_count() - 1, 0)
	var snapshot = _render_snapshot if _render_snapshot != null else create_render_snapshot()
	var pc := _pack_push_constant(sample_index, Vector4.ZERO, -1.0, {}, _size, _size,
			_periodic_coordinate_period(_size, snapshot.reference_size, _size),
			snapshot.periodic_optimized, snapshot)
	pc.encode_float(120, 1.0)
	pc.encode_float(124, 1.0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "diagnostics_reduce", pc, _diagnostic_group_count)
	_rd.compute_list_end()
	var calibration_values := _rd.buffer_get_data(_diagnostic_reduction_buffer).to_float32_array()
	if calibration_values.is_empty():
		return
	var max_area := 0.0
	var max_convergence := 0.0
	for group in mini(_diagnostic_group_count,
			int(calibration_values.size() / DIAGNOSTIC_REDUCTION_STRIDE)):
		var base := group * DIAGNOSTIC_REDUCTION_STRIDE
		max_area = maxf(max_area, calibration_values[base + 1])
		max_convergence = maxf(max_convergence, calibration_values[base + 3])
	pc.encode_float(120, 15.0 / maxf(max_area, 1.0e-6))
	pc.encode_float(124, 15.0 / maxf(max_convergence, 1.0e-6))
	cl = _rd.compute_list_begin()
	_dispatch(cl, "diagnostics_reduce", pc, _diagnostic_group_count)
	_rd.compute_list_end()
	var reduced_values := _rd.buffer_get_data(_diagnostic_reduction_buffer).to_float32_array()
	if reduced_values.is_empty():
		return
	var result := Diagnostics.analyse_reduced_metrics(reduced_values, _diagnostic_group_count,
		DIAGNOSTIC_REDUCTION_STRIDE, _size, snapshot, sample_index)
	var diagnostic_values := _readback_rgba16f(_textures.diagnostic)
	var zone_values := _rd.texture_get_data(_textures.diagnostic_zone, 0)
	result.merge(Diagnostics.analyse_zone_metrics(diagnostic_values, zone_values, _size))
	_metrics_mutex.lock()
	_metrics = result
	_metrics_mutex.unlock()


func _readback_rgba16f(texture: RID) -> PackedFloat32Array:
	if not texture.is_valid():
		return PackedFloat32Array()
	var bytes := _rd.texture_get_data(texture, 0)
	if bytes.is_empty():
		return PackedFloat32Array()
	var image := Image.create_from_data(_size.x, _size.y, false, Image.FORMAT_RGBAH, bytes)
	image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array()


func init_render(snapshot = null) -> void:
	if snapshot != null:
		_render_snapshot = snapshot
	elif _render_snapshot == null:
		_render_snapshot = create_render_snapshot()
	var active_snapshot = _render_snapshot
	if initialized:
		free_render()
	_render_snapshot = active_snapshot
	if active_snapshot.size.x < 1 or active_snapshot.size.y < 1:
		push_error("Mixwell size must be positive")
		return
	_state_mutex.lock()
	_size = active_snapshot.size
	_reference_size = active_snapshot.reference_size
	_state_mutex.unlock()
	_period_fixed = active_snapshot.period_fixed
	_render_profiling = active_snapshot.profiling
	if not is_initialized() and config.validate() != "" and snapshot == null:
		push_error("Mixwell config: %s" % config.validate())
		return
	_rd = GpuPreflight.device("MixwellSolver")
	if _rd == null:
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "mixwell_common.comp")
	for stage in STAGES:
		var stage_source := FileAccess.get_file_as_string(SHADER_DIR + "mixwell_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "mixwell_" + stage,
				"#version 450\n\n" + common + "\n" + stage_source)
		if not spirv.compile_error_compute.is_empty():
			push_error("Mixwell stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			free_render()
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	_create_textures()
	_segment_buffer = _rd.storage_buffer_create(DESKTOP_SEGMENT_LIMIT * 32)
	_diagnostic_ops_buffer = _rd.storage_buffer_create(DESKTOP_SEGMENT_LIMIT * 64)
	_diagnostic_group_count = ceili(float(_size.x * _size.y) / WG)
	_diagnostic_reduction_buffer = _rd.storage_buffer_create(
			DIAGNOSTIC_REDUCTION_STRIDE * _diagnostic_group_count * 4)
	for stage in STAGES:
		var sets: Array[RID] = []
		for parity in 2:
			sets.append(_create_uniform_set(_shaders[stage], parity, stage))
		_uniform_sets[stage] = sets
	_init_uniform_set = _create_init_uniform_set(_shaders.init)
	_parity = 1
	_state_mutex.lock()
	_sample_count = 0
	_state_mutex.unlock()
	_metrics_mutex.lock()
	_metrics = {
		"area_error": 0.0,
		"max_area_error": 0.0,
		"area_p99": 0.0,
		"area_core": 0.0,
		"area_singularity": 0.0,
		"area_cutoff": 0.0,
		"area_boundary": 0.0,
		"area_wall": 0.0,
		"area_valid_count": 0,
		"area_valid_p99": 0.0,
		"area_core_p99": 0.0,
		"convergence_error": 0.0,
		"convergence_rms": 0.0,
		"convergence_p99": 0.0,
		"sample": 0,
	}
	_metrics_mutex.unlock()
	_state_mutex.lock()
	initialized = true
	_state_mutex.unlock()


func free_render() -> void:
	_state_mutex.lock()
	initialized = false
	_state_mutex.unlock()
	if _rd == null:
		return
	for stage in _uniform_sets:
		for uniform_set in _uniform_sets[stage]:
			if uniform_set.is_valid():
				_rd.free_rid(uniform_set)
	if _init_uniform_set.is_valid():
		_rd.free_rid(_init_uniform_set)
	for key in _textures:
		if _textures[key].is_valid():
			_rd.free_rid(_textures[key])
	if _segment_buffer.is_valid():
		_rd.free_rid(_segment_buffer)
	if _diagnostic_ops_buffer.is_valid():
		_rd.free_rid(_diagnostic_ops_buffer)
	if _diagnostic_reduction_buffer.is_valid():
		_rd.free_rid(_diagnostic_reduction_buffer)
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_uniform_sets.clear()
	_init_uniform_set = RID()
	_textures.clear()
	_segment_buffer = RID()
	_diagnostic_ops_buffer = RID()
	_diagnostic_reduction_buffer = RID()
	_diagnostic_group_count = 0
	_pipelines.clear()
	_shaders.clear()
	_rd = null
	_render_snapshot = null


func _create_textures() -> void:
	for key in ["coords_a", "coords_b", "disp_a", "disp_b"]:
		_textures[key] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32_SFLOAT)
	for key in ["sample", "accumulation", "source", "diagnostic", "convergence"]:
		_textures[key] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_textures["diagnostic_zone"] = _create_texture(RenderingDevice.DATA_FORMAT_R8_UINT)
	_rd.texture_clear(_textures.sample, Color(0, 0, 0, 1), 0, 1, 0, 1)
	_rd.texture_clear(_textures.accumulation, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rd.texture_clear(_textures.convergence, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rd.texture_clear(_textures.diagnostic_zone, Color(0, 0, 0, 0), 0, 1, 0, 1)


func _create_texture(format: int) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.width = _size.x
	texture_format.height = _size.y
	texture_format.format = format
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(texture_format, RDTextureView.new(), [])


func _create_uniform_set(shader: RID, parity: int, stage := "") -> RID:
	var texture_order: Array[String] = ["coords_a", "coords_b", "disp_a", "disp_b"]
	if parity == 1:
		texture_order = ["coords_b", "coords_a", "disp_b", "disp_a"]
	var uniforms: Array[RDUniform] = []
	for binding in 4:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = binding
		uniform.add_id(_textures[texture_order[binding]])
		uniforms.append(uniform)
	for binding in [4, 5, 6, 7]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = binding
		var texture_name := "sample" if binding == 4 else "accumulation"
		if binding == 6:
			texture_name = "source"
		elif binding == 7:
			texture_name = "diagnostic"
		uniform.add_id(_textures[texture_name])
		uniforms.append(uniform)
	if stage == "rd_segment":
		var segment_uniform := RDUniform.new()
		segment_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		segment_uniform.binding = 8
		segment_uniform.add_id(_segment_buffer)
		uniforms.append(segment_uniform)
	elif stage == "diagnostics":
		var operations_uniform := RDUniform.new()
		operations_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		operations_uniform.binding = 8
		operations_uniform.add_id(_diagnostic_ops_buffer)
		uniforms.append(operations_uniform)
		var zone_uniform := RDUniform.new()
		zone_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		zone_uniform.binding = 9
		zone_uniform.add_id(_textures.diagnostic_zone)
		uniforms.append(zone_uniform)
	elif stage == "accumulate":
		var convergence_uniform := RDUniform.new()
		convergence_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		convergence_uniform.binding = 8
		convergence_uniform.add_id(_textures.convergence)
		uniforms.append(convergence_uniform)
	elif stage == "diagnostics_reduce":
		var zone_uniform := RDUniform.new()
		zone_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		zone_uniform.binding = 8
		zone_uniform.add_id(_textures.diagnostic_zone)
		uniforms.append(zone_uniform)
		var convergence_uniform := RDUniform.new()
		convergence_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		convergence_uniform.binding = 9
		convergence_uniform.add_id(_textures.convergence)
		uniforms.append(convergence_uniform)
		var reduction_uniform := RDUniform.new()
		reduction_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		reduction_uniform.binding = 10
		reduction_uniform.add_id(_diagnostic_reduction_buffer)
		uniforms.append(reduction_uniform)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _create_init_uniform_set(shader: RID) -> RID:
	return _create_uniform_set(shader, 0, "init")


func _dispatch(cl: int, stage: String, pc: PackedByteArray, groups: int,
		initialization := false) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	var uniform_set: RID = _init_uniform_set
	if not initialization:
		uniform_set = _uniform_sets[stage][_parity]
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)


func _upload_segment_buffer(operations: Array[Dictionary]) -> void:
	if not _segment_buffer.is_valid() or _render_snapshot == null:
		return
	var values := PackedFloat32Array()
	var reference_min := float(maxi(mini(_render_snapshot.reference_size.x,
		_render_snapshot.reference_size.y), 1))
	for operation in operations:
		if int(operation.get("type", Gallery.LINE)) != Gallery.SEGMENT:
			continue
		var segment: Vector4 = operation.get("segment", Vector4.ZERO)
		var radius := _operation_radius(operation, _render_snapshot)
		var epsilon: float = radius * 2.0 / reference_min
		values.append(segment.x)
		values.append(segment.y)
		values.append(segment.z)
		values.append(segment.w)
		values.append(epsilon)
		values.append(0.0)
		values.append(0.0)
		values.append(0.0)
	if not values.is_empty():
		var bytes := values.to_byte_array()
		_rd.buffer_update(_segment_buffer, 0, bytes.size(), bytes)


func _upload_diagnostic_operations(operations: Array[Dictionary]) -> void:
	if not _diagnostic_ops_buffer.is_valid() or _render_snapshot == null:
		return
	var values := PackedFloat32Array()
	var reference_min := float(maxi(mini(_render_snapshot.reference_size.x,
		_render_snapshot.reference_size.y), 1))
	for operation in operations:
		if values.size() / 16 >= DESKTOP_SEGMENT_LIMIT:
			break
		var operation_type := int(operation.get("type", Gallery.LINE))
		var radius := _operation_radius(operation, _render_snapshot)
		var epsilon: float = radius * 2.0 / reference_min
		var origin: Vector2 = operation.get("origin", Vector2.ZERO)
		var direction: Vector2 = operation.get("direction", Vector2.RIGHT)
		var segment: Vector4 = operation.get("segment", Vector4.ZERO)
		var extent: Vector2 = operation.get("extent", Vector2.ZERO)
		var period: Vector2 = operation.get("period", Vector2.ZERO)
		values.append(float(operation_type))
		values.append(epsilon)
		values.append(extent.x)
		values.append(extent.y)
		values.append(origin.x)
		values.append(origin.y)
		values.append(direction.x)
		values.append(direction.y)
		values.append(segment.x)
		values.append(segment.y)
		values.append(segment.z)
		values.append(segment.w)
		values.append(period.x if operation_type == Gallery.SEGMENT else float(operation.get("pitch", 0.0)))
		values.append(period.y if operation_type == Gallery.SEGMENT else float(operation.get("count", 1)))
		values.append(0.0 if operation_type == Gallery.SEGMENT else float(operation.get("noise", 0.0)))
		values.append(float(operation.get("phase", 0.0)))
	if not values.is_empty():
		var bytes := values.to_byte_array()
		_rd.buffer_update(_diagnostic_ops_buffer, 0, bytes.size(), bytes)


func _mark(cl: int, name: String) -> int:
	if not _render_profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


func _read_timings() -> void:
	var result := GpuTimings.read(_rd, "mixwell/", _render_profiling)
	if result.is_empty():
		if _render_profiling:
			_timing_store.publish({
				"init": 0.0,
				"rd_line": 0.0,
				"rd_segment": 0.0,
				"affine": 0.0,
				"shade": 0.0,
				"diagnostics": 0.0,
				"accumulate": 0.0,
				"total": 0.0,
				"timestamps_available": false,
			})
		return
	if result.has("total") and is_finite(float(result.total)) and result.total > 0.0:
		_last_sample_gpu_ms = float(result.total)
	_timing_store.publish(result)


func _pack_push_constant(index: int, segment: Vector4, radius_px: float,
		operation := {}, current_domain := Vector2i.ZERO, previous_domain := Vector2i.ZERO,
		period := Vector2.ZERO, optimized := false, snapshot = null) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	var active_snapshot = snapshot if snapshot != null else _render_snapshot
	if current_domain == Vector2i.ZERO:
		current_domain = active_snapshot.size
	if previous_domain == Vector2i.ZERO:
		previous_domain = current_domain
	if period == Vector2.ZERO:
		period = Periodicity.canonical_period(active_snapshot.reference_size)
	pc.encode_s32(0, active_snapshot.size.x)
	pc.encode_s32(4, active_snapshot.size.y)
	pc.encode_s32(8, index)
	pc.encode_s32(12, active_snapshot.source_mode)
	var brush_radius_px: float = active_snapshot.brush_radius_px if radius_px <= 0.0 else radius_px
	if active_snapshot.affine_mode >= 0:
		brush_radius_px = active_snapshot.affine_radius_px
	var reference_min := mini(active_snapshot.reference_size.x, active_snapshot.reference_size.y)
	var epsilon: float = brush_radius_px * 2.0 / float(maxi(reference_min, 1))
	pc.encode_float(16, epsilon)
	pc.encode_float(20, active_snapshot.midpoint_alpha)
	pc.encode_float(24, active_snapshot.cutoff_gamma)
	pc.encode_float(28, float(active_snapshot.drift_compensation))
	var origin: Vector2 = operation.get("origin", Vector2.ZERO)
	var direction: Vector2 = operation.get("direction", Vector2.RIGHT)
	pc.encode_float(32, origin.x)
	pc.encode_float(36, origin.y)
	pc.encode_float(40, direction.x if active_snapshot.affine_mode < 0 else active_snapshot.affine_strength)
	pc.encode_float(44, direction.y if active_snapshot.affine_mode < 0 \
				else (0.0 if active_snapshot.affine_mode == Gallery.TWIST else 1.0))
	var operation_type := int(operation.get("type", Gallery.LINE))
	if operation_type == Gallery.SEGMENT and segment != Vector4.ZERO:
		pc.encode_float(48, segment.x)
		pc.encode_float(52, segment.y)
		pc.encode_float(56, segment.z)
		pc.encode_float(60, segment.w)
	else:
		var extent: Vector2 = operation.get("extent", Vector2.ZERO)
		pc.encode_float(48, float(operation.get("phase", 0.0)))
		pc.encode_float(52, epsilon)
		pc.encode_float(56, extent.x)
		pc.encode_float(60, extent.y)
	if operation_type == Gallery.SEGMENT:
		var operation_period: Vector2 = operation.get("period", Vector2.ZERO)
		pc.encode_float(56, operation_period.x)
		pc.encode_float(60, operation_period.y)
	pc.encode_float(64, period.x)
	pc.encode_float(68, period.y)
	pc.encode_float(72, float(active_snapshot.active_boundary_mode))
	pc.encode_float(76, 1.0 if optimized else 0.0)
	pc.encode_float(80, float(operation.get("type", Gallery.LINE)))
	pc.encode_float(84, float(operation.get("pitch", 0.0)))
	pc.encode_float(88, float(operation.get("count", 1)))
	pc.encode_float(92, float(operation.get("noise", 0.0)))
	pc.encode_s32(96, current_domain.x)
	pc.encode_s32(100, current_domain.y)
	pc.encode_s32(104, previous_domain.x)
	pc.encode_s32(108, previous_domain.y)
	pc.encode_float(112, 1.0 if active_snapshot.diagnostics_enabled else 0.0)
	pc.encode_float(116, float(active_snapshot.operations.size()))
	pc.encode_float(120, 1.0)
	pc.encode_float(124, 1.0)
	return pc


func _physical_operations() -> Array[Dictionary]:
	return _pattern.render_operations(_pattern_step)


func _active_pattern_count() -> int:
	return _pattern.operation_count() if _pattern_step < 0 else _pattern_step


func _operation_radius(operation: Dictionary,
		snapshot = null) -> float:
	var active_snapshot = snapshot if snapshot != null else _render_snapshot
	if active_snapshot != null and active_snapshot.affine_mode >= 0:
		return active_snapshot.affine_radius_px
	var value := float(operation.get("radius_px", -1.0))
	return config.brush_radius_px if value <= 0.0 else value


func get_periodic_domain_size() -> Vector2i:
	var operations := _physical_operations()
	var plan := _periodic_operation_plan(operations, true)
	return _plan_domain(plan, _size)


func _periodic_operation_plan(operations: Array[Dictionary], optimized: bool,
		render_size := Vector2i.ZERO) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var target_size := _size if render_size == Vector2i.ZERO else render_size
	var previous := target_size
	var previous_period_fixed := Vector2i.ZERO
	var full_period_fixed := Periodicity.quantize_period(
			Periodicity.canonical_period(_reference_size))
	for operation in operations:
		var operation_domain := _operation_period_pixels(operation, target_size) if optimized else target_size
		var operation_period_fixed := full_period_fixed
		var composite_period_fixed := full_period_fixed
		if optimized:
			operation_period_fixed = _operation_period_fixed(operation, target_size)
			if operation_period_fixed == Vector2i.ZERO:
				composite_period_fixed = full_period_fixed
			else:
				composite_period_fixed = Periodicity.composite_period_components_fixed([
						previous_period_fixed, operation_period_fixed])
				operation_domain = _domain_from_period_fixed(operation_period_fixed, target_size)
		var first := result.is_empty()
		var current := operation_domain
		if optimized:
			current = _domain_from_period_fixed(composite_period_fixed, target_size)
		if not optimized:
			current = target_size
		result.append({
			"current": current,
			"previous": current if first else previous,
			"operation_period": operation_domain,
			"operation_period_fixed": operation_period_fixed,
			"composite_period_fixed": composite_period_fixed,
		})
		previous = current
		previous_period_fixed = composite_period_fixed
	return result


func _plan_domain(plan: Array[Dictionary], render_size: Vector2i) -> Vector2i:
	return render_size if plan.is_empty() else plan.back()["current"]


func _plan_movement_dispatch_pixels(plan: Array[Dictionary], render_size: Vector2i) -> int:
	var pixels := _plan_domain(plan, render_size).x * _plan_domain(plan, render_size).y
	for pass_info in plan:
		var domain: Vector2i = pass_info["current"]
		pixels += domain.x * domain.y
	return pixels


func _operation_period_pixels(operation: Dictionary, render_size := Vector2i.ZERO) -> Vector2i:
	var target_size := _size if render_size == Vector2i.ZERO else render_size
	var explicit: Vector2i = operation.get("period_pixels", Vector2i.ZERO)
	if explicit.x > 0 and explicit.y > 0:
		return Vector2i(mini(explicit.x, target_size.x), mini(explicit.y, target_size.y))
	var period: Vector2 = operation.get("period", Vector2.ZERO)
	if period == Vector2.ZERO:
		return target_size
	var canonical := Periodicity.canonical_period(_reference_size)
	var result := Vector2i.ONE
	if period.x > 0.0:
		result.x = clampi(ceili(period.x / canonical.x * float(target_size.x)), 1, target_size.x)
	if period.y > 0.0:
		result.y = clampi(ceili(period.y / canonical.y * float(target_size.y)), 1, target_size.y)
	return result


func _operation_period_fixed(operation: Dictionary, render_size := Vector2i.ZERO) -> Vector2i:
	var explicit: Vector2i = operation.get("period_pixels", Vector2i.ZERO)
	if explicit.x > 0 and explicit.y > 0:
		return Periodicity.quantize_period_components(_coordinate_period(explicit,
				_reference_size, render_size))
	return Periodicity.quantize_period_components(operation.get("period", Vector2.ZERO))


func _domain_from_period_fixed(period_fixed: Vector2i, render_size: Vector2i) -> Vector2i:
	if period_fixed == Vector2i.ZERO:
		return Vector2i.ONE
	var canonical := Periodicity.canonical_period(_reference_size)
	var result := Vector2i.ONE
	if period_fixed.x > 0:
		result.x = clampi(ceili(float(period_fixed.x) / float(Periodicity.FIXED_SCALE)
				/ canonical.x * float(render_size.x)), 1, render_size.x)
	if period_fixed.y > 0:
		result.y = clampi(ceili(float(period_fixed.y) / float(Periodicity.FIXED_SCALE)
				/ canonical.y * float(render_size.y)), 1, render_size.y)
	return result


func _coordinate_period(domain: Vector2i, reference_size := Vector2i.ZERO,
		render_size := Vector2i.ZERO) -> Vector2:
	var target_reference := _reference_size if reference_size == Vector2i.ZERO else reference_size
	var target_size := _size if render_size == Vector2i.ZERO else render_size
	var canonical := Periodicity.canonical_period(target_reference)
	return Vector2(float(domain.x) / float(maxi(target_size.x, 1)) * canonical.x,
			float(domain.y) / float(maxi(target_size.y, 1)) * canonical.y)


func _periodic_coordinate_period(domain: Vector2i, reference_size := Vector2i.ZERO,
		render_size := Vector2i.ZERO) -> Vector2:
	var target_reference := _reference_size if reference_size == Vector2i.ZERO else reference_size
	var target_size := _size if render_size == Vector2i.ZERO else render_size
	var canonical := Periodicity.canonical_period(target_reference)
	var result := _coordinate_period(domain, target_reference, target_size)
	if domain.x <= 1:
		result.x = canonical.x
	if domain.y <= 1:
		result.y = canonical.y
	return result


func _pixel_lcm(a: Vector2i, b: Vector2i, render_size := Vector2i.ZERO) -> Vector2i:
	var target_size := _size if render_size == Vector2i.ZERO else render_size
	return Vector2i(mini(target_size.x, _lcm(a.x, b.x)), mini(target_size.y, _lcm(a.y, b.y)))


func _lcm(a: int, b: int) -> int:
	if a <= 0 or b <= 0:
		return maxi(a, b)
	var left := a
	var right := b
	while right != 0:
		var remainder := left % right
		left = right
		right = remainder
	return maxi(1, int(a / left) * b)


func _refresh_periodicity() -> void:
	_refresh_wall_calibration()
	_period_fixed = Periodicity.quantize_period(_periodic_coordinate_period(get_periodic_domain_size()))
	if config.boundary_mode != MixwellConfig.BoundaryMode.PERIODIC:
		_periodic_comparison = {"passes": true, "active": false, "samples": 0}
		return
	var period := get_period()
	var canonical := Periodicity.canonical_period(_reference_size)
	var periodic_values := PackedFloat32Array()
	var fullscreen_values := PackedFloat32Array()
	var periodic_colours := PackedFloat32Array()
	var fullscreen_colours := PackedFloat32Array()
	var operations := _physical_operations()
	for y in 4:
		for x in 4:
			var uv := Vector2((float(x) + 0.5) / 4.0, (float(y) + 0.5) / 4.0)
			var point := Vector2(
				(uv.x * 2.0 - 1.0) * canonical.x * 0.5,
				(uv.y * 2.0 - 1.0) * canonical.y * 0.5)
			var fullscreen := Diagnostics.cpu_advect(point, operations, false, period,
					config.brush_radius_px, _reference_size, _affine_mode, config.affine_radius_px,
					config.affine_strength, config.cutoff_gamma, config.drift_compensation,
					config.midpoint_alpha)
			var periodic := Diagnostics.cpu_advect(point, operations, true, period,
					config.brush_radius_px, _reference_size, _affine_mode, config.affine_radius_px,
					config.affine_strength, config.cutoff_gamma, config.drift_compensation,
					config.midpoint_alpha)
			var fullscreen_wrapped := Periodicity.wrap_coordinate(fullscreen, period)
			fullscreen_values.append(fullscreen_wrapped.x)
			fullscreen_values.append(fullscreen_wrapped.y)
			periodic_values.append(periodic.x)
			periodic_values.append(periodic.y)
			var periodic_colour := Diagnostics.cpu_pigment(periodic, _source_mode, _reference_size)
			var fullscreen_colour := Diagnostics.cpu_pigment(fullscreen_wrapped, _source_mode,
					_reference_size)
			for component in 3:
				periodic_colours.append(periodic_colour[component])
				fullscreen_colours.append(fullscreen_colour[component])
	_periodic_comparison = Periodicity.compare_paths(periodic_values, fullscreen_values, period,
			periodic_colours, fullscreen_colours)
	_periodic_comparison["active"] = _periodic_comparison.get("passes", false)
	_periodic_comparison["domain_pixels"] = get_periodic_domain_size()
	var dispatch_stats := get_periodic_dispatch_stats()
	_periodic_comparison.merge(dispatch_stats)


func _normalized_segments() -> Array[Vector4]:
	if not _preset_segments.is_empty():
		var copy: Array[Vector4] = []
		copy.append_array(_preset_segments)
		return copy
	var result: Array[Vector4] = []
	var half := Vector2(_reference_size) * 0.5
	var scale := 2.0 / float(maxi(mini(_reference_size.x, _reference_size.y), 1))
	for segment in _segments_px:
		result.append(Vector4(
			(segment.x - half.x) * scale, (segment.y - half.y) * scale,
			(segment.z - half.x) * scale, (segment.w - half.y) * scale))
	return result


func _normalize_segment(segment: Vector4) -> Vector4:
	var half := Vector2(_reference_size) * 0.5
	var scale := 2.0 / float(maxi(mini(_reference_size.x, _reference_size.y), 1))
	return Vector4(
		(segment.x - half.x) * scale, (segment.y - half.y) * scale,
		(segment.z - half.x) * scale, (segment.w - half.y) * scale)


func _refresh_wall_calibration() -> void:
	_wall_calibration = 1.0
