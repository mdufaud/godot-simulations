class_name OceanCapture extends RefCounted

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const CaptureMetrics := preload("res://scripts/ocean/ocean_capture_metrics.gd")
const READBACK_TIMEOUT_MS := 15000

class Metadata extends RefCounted:
	var look: String
	var preset: String
	var view: String
	var simulation_time: float
	var fixed_delta: float
	var sun_elevation: float
	var sun_azimuth: float
	var water_height: float

var measurement_active := false
var _solver: OceanSolver
var _profiling: OceanProfiling
var _cloudscape: OceanCloudscape
var _tree: SceneTree
var _viewport: Viewport
var _world_env: WorldEnvironment
var _ocean_mesh: MeshInstance3D
var _underwater_tint: ColorRect
var _readback := TextureReadback.new()
var _pending_request: TextureReadback.Request
var _generation := 0
var _busy := false
var _stopped := false
var _profile_suspended := false
var _metadata_provider := Callable()
var _original_environment: Environment
var _measurement_environment: Environment
var _measurement_material: ShaderMaterial
var _measurement_tint: ColorRect
var _old_debug: Variant
var _tint_visible := false


func setup(solver: OceanSolver, profiling: OceanProfiling, cloudscape: OceanCloudscape,
		tree: SceneTree, viewport: Viewport, world_env: WorldEnvironment,
		ocean_mesh: MeshInstance3D, underwater_tint: ColorRect) -> void:
	_solver = solver
	_profiling = profiling
	_cloudscape = cloudscape
	_tree = tree
	_viewport = viewport
	_world_env = world_env
	_ocean_mesh = ocean_mesh
	_underwater_tint = underwater_tint


func invalidate() -> void:
	_generation += 1
	_busy = false
	_metadata_provider = Callable()
	_restore_measurement()
	if _profile_suspended:
		_profile_suspended = false
		_profiling.end_measurement()
	var pending := _pending_request
	_pending_request = null
	if pending != null:
		pending.cancel()


func stop() -> void:
	_stopped = true
	invalidate()
	_solver = null
	_profiling = null
	_cloudscape = null
	_tree = null
	_viewport = null
	_world_env = null
	_ocean_mesh = null
	_underwater_tint = null


func _current(generation: int) -> bool:
	return generation == _generation and not _stopped and _solver != null \
		and _solver.initialized and is_instance_valid(_tree) and is_instance_valid(_viewport)


func _wait_frame(generation: int, post_draw: bool) -> bool:
	if not _current(generation):
		return false
	var request := TextureReadback.Request.new()
	_pending_request = request
	var frame_signal: Signal = RenderingServer.frame_post_draw if post_draw else _tree.process_frame
	var complete := request.complete.bind(PackedByteArray())
	frame_signal.connect(complete, CONNECT_ONE_SHOT)
	var timer := _tree.create_timer(float(READBACK_TIMEOUT_MS) / 1000.0, true, false, true)
	timer.timeout.connect(request.timeout, CONNECT_ONE_SHOT)
	await request.completed
	if frame_signal.is_connected(complete):
		frame_signal.disconnect(complete)
	if timer.timeout.is_connected(request.timeout):
		timer.timeout.disconnect(request.timeout)
	if _pending_request == request:
		_pending_request = null
	if request.timed_out():
		_fail("render frame timed out", generation)
	return _current(generation) and not request.cancelled() and not request.timed_out()


func _read_layer(rid: RID, layer: int, generation: int) -> PackedByteArray:
	if not _current(generation):
		return PackedByteArray()
	var request := TextureReadback.Request.new()
	_pending_request = request
	var data := await _readback.read_layer(rid, layer, 0, READBACK_TIMEOUT_MS, request)
	if _pending_request == request:
		_pending_request = null
	if request.timed_out():
		_fail("GPU readback timed out", generation)
	return data if _current(generation) else PackedByteArray()


func _fail(message: String, generation: int) -> void:
	if generation != _generation or _stopped:
		return
	var tree := _tree
	invalidate()
	push_error("CAPTURE FAIL: " + message)
	if is_instance_valid(tree):
		tree.create_timer(0.1, true, false, true).timeout.connect(tree.quit.bind(1), CONNECT_ONE_SHOT)


func _finish(generation: int) -> void:
	if generation == _generation:
		_busy = false
		_metadata_provider = Callable()
		_restore_measurement()
		if _profile_suspended:
			_profile_suspended = false
			_profiling.end_measurement()


func metadata(path: String, context: Metadata) -> String:
	var cam := _viewport.get_camera_3d()
	var position := cam.global_position if cam != null else Vector3.ZERO
	var water_height := context.water_height
	var metrics := _profiling.statistics()
	var cloud_coverage := _cloudscape.capture_alpha_coverage()
	var backend_name := _profiling.backend_name()
	return "CAPTURE META backend=%s profile=%s vram_mb=%.1f look=%s preset=%s view=%s frame=%d time=%.6f fixed_dt=%.6f wind=%.6f sun_elevation=%.3f sun_azimuth=%.3f camera=%s water=%.3f sim_gpu=%.3f sim_gpu_p95=%.3f foam_gpu=%.3f foam_gpu_p95=%.3f foam_near_gpu=%.3f query_gpu=%.3f interaction_capture_gpu=%.3f interaction_feedback_gpu=%.3f cloud_gpu=%.3f cloud_gpu_p95=%.3f viewport_gpu=%.3f viewport_gpu_p95=%.3f frame_ms=%.3f frame_p95_ms=%.3f profile_samples=%d stage_p95=%s cloud_cov=%.4f path=%s" % [
		backend_name, _profiling.profile_label(),
		_profiling.vram_mb(),
		context.look,
		context.preset,
		context.view, _solver._frame, context.simulation_time, context.fixed_delta,
		_solver.wind_direction, context.sun_elevation, context.sun_azimuth, position, water_height,
		metrics.sim_gpu, metrics.sim_gpu_p95, metrics.foam_gpu, metrics.foam_gpu_p95,
		metrics.foam_near_gpu, metrics.query_gpu,
		metrics.interaction_capture_gpu, metrics.interaction_feedback_gpu, metrics.cloud_gpu, metrics.cloud_gpu_p95,
		metrics.viewport_gpu, metrics.viewport_gpu_p95,
		metrics.frame_ms, metrics.frame_p95_ms,
		metrics.profile_samples, JSON.stringify(metrics.stage_p95), cloud_coverage, path,
	]


func metadata_async(path: String, provider: Callable) -> String:
	if _busy or not _current(_generation) or not provider.is_valid():
		return "CAPTURE FAIL capture unavailable"
	_busy = true
	_metadata_provider = provider
	var generation := _generation
	if not await _wait_frame(generation, true):
		return "CAPTURE FAIL capture cancelled"
	_profile_suspended = true
	_profiling.begin_measurement()
	var state := _solver.foam_state()
	var near_size := _solver.foam_near_size
	var fields: Array[Dictionary] = []
	for layer in 3:
		var data := await _read_layer(_solver.get_foam_near_read_tex_rid(), layer, generation)
		if not _current(generation):
			return "CAPTURE FAIL capture cancelled"
		var expected := 0
		var size := near_size
		while size > 0:
			expected += size * size * 8
			size /= 2
		if data.size() != expected:
			_fail("foam field %d has %d bytes, expected %d" % [layer, data.size(), expected], generation)
			return "CAPTURE FAIL incomplete foam readback"
		var values := data.slice(0, near_size * near_size * 8).to_float32_array()
		var persistent := 0.0
		var fresh := 0.0
		var covered := 0
		var maximum := 0.0
		for i in range(0, values.size(), 2):
			if not is_finite(values[i]) or not is_finite(values[i + 1]):
				_fail("non-finite foam field %d" % layer, generation)
				return "CAPTURE FAIL non-finite foam"
			persistent += values[i]
			fresh += values[i + 1]
			maximum = maxf(maximum, maxf(values[i], values[i + 1]))
			if maxf(values[i], values[i + 1]) > OceanConfig.MEASURE_FOAM_THRESHOLD:
				covered += 1
		var count := values.size() / 2
		fields.append({"layer": layer, "domain_m": _solver.foam_field_domains()[layer],
			"texel_m": _solver.foam_field_domains()[layer] / near_size,
			"persistent_mean": persistent / count, "fresh_mean": fresh / count,
			"coverage": float(covered) / count, "maximum": maximum})
	var rings := await _foam_rings(generation)
	if not _current(generation):
		return "CAPTURE FAIL capture cancelled"
	var waves := await _wave_metrics(generation)
	if not _current(generation) or not _metadata_provider.is_valid():
		return "CAPTURE FAIL capture cancelled"
	var context: Metadata = _metadata_provider.call()
	_finish(generation)
	print("CAPTURE FOAM_FIELDS %s" % JSON.stringify(fields))
	print("CAPTURE FOAM_PIXELS %s" % JSON.stringify(rings))
	print("CAPTURE WAVES %s" % JSON.stringify(waves))
	return "%s state_time=%.6f state_step=%d seed=1000,31337 measure_version=%d" % [
		metadata(path, context), state.time, state.step, OceanConfig.MEASURE_VERSION]


func _wave_metrics(generation: int) -> Dictionary:
	var map_size := _solver.map_size
	var displacement: Array[PackedFloat32Array] = []
	var derivative: Array[PackedFloat32Array] = []
	for layer in 3:
		for kind in 2:
			var rid := _solver.get_displacement_tex_rid() if kind == 0 else _solver.get_derivative_tex_rid()
			var data := await _read_layer(rid, layer, generation)
			if not _current(generation):
				return {}
			if data.size() != map_size * map_size * 8:
				_fail("incomplete wave field readback", generation)
				return {}
			var image := Image.create_from_data(map_size, map_size, false, Image.FORMAT_RGBAH, data)
			image.convert(Image.FORMAT_RGBAF)
			if kind == 0:
				displacement.append(image.get_data().to_float32_array())
			else:
				derivative.append(image.get_data().to_float32_array())
	var metrics: Dictionary = CaptureMetrics.measure(
		displacement, derivative, map_size, _solver.tile_lengths, clampf(_solver.whitecap, 0.05, 0.95))
	metrics["spectral_references"] = _solver.spectral_references()
	if metrics.has("error"):
		_fail(metrics.error, generation)
	return metrics


func foam_rings() -> Array[Dictionary]:
	if _busy or not _current(_generation):
		return []
	_busy = true
	var generation := _generation
	var rings := await _foam_rings(generation)
	_finish(generation)
	return rings


func _foam_rings(generation: int) -> Array[Dictionary]:
	if not _current(generation) or not is_instance_valid(_world_env) \
		or not is_instance_valid(_ocean_mesh) or not is_instance_valid(_underwater_tint):
		return []
	_original_environment = _world_env.environment
	_measurement_environment = _original_environment.duplicate()
	_measurement_material = _ocean_mesh.material_override as ShaderMaterial
	_measurement_tint = _underwater_tint
	_old_debug = _measurement_material.get_shader_parameter("debug_view")
	_tint_visible = _measurement_tint.visible
	_measurement_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_measurement_environment.tonemap_exposure = 1.0
	_measurement_environment.glow_enabled = false
	_measurement_environment.adjustment_enabled = false
	_measurement_environment.fog_enabled = false
	_measurement_environment.volumetric_fog_enabled = false
	_measurement_environment.background_mode = Environment.BG_COLOR
	_measurement_environment.background_color = Color.BLACK
	_world_env.environment = _measurement_environment
	measurement_active = true
	_measurement_tint.hide()
	_measurement_material.set_shader_parameter("debug_view", 8)
	if not await _wait_frame(generation, false) or not await _wait_frame(generation, true):
		return []
	var image := _viewport.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("empty foam measurement image", generation)
		return []
	var rings: Array[Dictionary] = []
	var edges := [0.0, 50.0, 150.0, 500.0, 1500.0]
	for i in 4:
		rings.append({"from_m": edges[i], "to_m": edges[i + 1], "pixels": 0,
			"coverage_sum": 0.0, "active_pixels": 0})
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y).srgb_to_linear()
			if pixel.b < 0.98:
				continue
			var distance := pixel.g * 2000.0
			for ring in rings:
				if distance >= ring.from_m and distance < ring.to_m:
					ring.pixels += 1
					ring.coverage_sum += pixel.r
					if pixel.r > OceanConfig.MEASURE_FOAM_THRESHOLD:
						ring.active_pixels += 1
					break
	for ring in rings:
		ring["mean_coverage"] = ring.coverage_sum / ring.pixels if ring.pixels > 0 else -1.0
		ring["active_fraction"] = float(ring.active_pixels) / ring.pixels if ring.pixels > 0 else -1.0
		ring.erase("coverage_sum")
	_restore_measurement()
	if not await _wait_frame(generation, false) or not await _wait_frame(generation, true):
		return []
	return rings


func preserve_underwater_state(visible: bool, fog_density: float, fog_color: Color) -> void:
	if not measurement_active:
		return
	_tint_visible = visible
	if is_instance_valid(_world_env) and _world_env.environment == _measurement_environment:
		_original_environment.fog_density = fog_density
		_original_environment.fog_light_color = fog_color


func _restore_measurement() -> void:
	if measurement_active:
		if is_instance_valid(_world_env) and _world_env.environment == _measurement_environment:
			_world_env.environment = _original_environment
		if is_instance_valid(_ocean_mesh) and _ocean_mesh.material_override == _measurement_material \
			and _measurement_material.get_shader_parameter("debug_view") == 8:
			_measurement_material.set_shader_parameter("debug_view", _old_debug)
		if is_instance_valid(_measurement_tint) and _measurement_tint == _underwater_tint:
			_measurement_tint.visible = _tint_visible
	measurement_active = false
	_original_environment = null
	_measurement_environment = null
	_measurement_material = null
	_measurement_tint = null
	_old_debug = null


static func image_metrics(image: Image, debug_view: int) -> String:
	var sum := 0.0
	var sum_sq := 0.0
	var saturation_sum := 0.0
	var count := 0
	var y_start := int(float(image.get_height()) * 0.5)
	for y in range(y_start, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color := image.get_pixel(x, y)
			var luminance := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			sum += luminance
			sum_sq += luminance * luminance
			var maximum := maxf(color.r, maxf(color.g, color.b))
			var minimum := minf(color.r, minf(color.g, color.b))
			saturation_sum += (maximum - minimum) / maxf(maximum, 1e-4)
			count += 1
	var mean := sum / maxf(float(count), 1.0)
	var variance := maxf(sum_sq / maxf(float(count), 1.0) - mean * mean, 0.0)
	var coverage := water_coverage(image, debug_view)
	return "CAPTURE IMAGE lower_luma=%.4f lower_luma_sd=%.4f lower_sat=%.4f water_cov=%.4f orient_coh=%.4f banding=%.4f" % [
		mean, sqrt(variance), saturation_sum / maxf(float(count), 1.0), coverage,
		orientation_coherence(image), banding_fraction(image)]


static func orientation_coherence(image: Image) -> float:
	var y_start := int(float(image.get_height()) * 0.5)
	var block := 16
	var coherence_sum := 0.0
	var blocks := 0
	for by in range(y_start, image.get_height() - block, block * 2):
		for bx in range(0, image.get_width() - block, block * 2):
			var jxx := 0.0
			var jxy := 0.0
			var jyy := 0.0
			for y in range(by + 1, by + block - 1, 2):
				for x in range(bx + 1, bx + block - 1, 2):
					var gx := _luma_difference(image, x + 1, y) - _luma_difference(image, x - 1, y)
					var gy := _luma_difference(image, x, y + 1) - _luma_difference(image, x, y - 1)
					jxx += gx * gx
					jxy += gx * gy
					jyy += gy * gy
			var trace := jxx + jyy
			if trace < 1e-7:
				continue
			var discriminant := sqrt(maxf((jxx - jyy) * (jxx - jyy) + 4.0 * jxy * jxy, 0.0))
			coherence_sum += discriminant / trace
			blocks += 1
	return coherence_sum / maxf(float(blocks), 1.0)


static func banding_fraction(image: Image) -> float:
	var y_start := int(float(image.get_height()) * 0.5)
	var flat := 0
	var pairs := 0
	for y in range(y_start, image.get_height(), 4):
		for x in range(0, image.get_width() - 1, 4):
			var l0 := _luma_byte(image, x, y)
			var l1 := _luma_byte(image, x + 1, y)
			if l0 == l1:
				flat += 1
			pairs += 1
	return float(flat) / maxf(float(pairs), 1.0)


static func _luma_difference(image: Image, x: int, y: int) -> float:
	x = clampi(x, 0, image.get_width() - 1)
	y = clampi(y, 0, image.get_height() - 1)
	return _luma_byte(image, x, y)


static func _luma_byte(image: Image, x: int, y: int) -> float:
	var color := image.get_pixel(x, y)
	return floorf((color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722) * 255.0)


static func water_coverage(image: Image, debug_view: int) -> float:
	if debug_view != 1:
		return -1.0
	var row_step := 4
	var previous := Vector3.ZERO
	var strongest_delta := 0.0
	var horizon_y := 0
	for y in range(0, image.get_height(), row_step):
		var row := Vector3.ZERO
		var samples := 0
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			row += Vector3(color.r, color.g, color.b)
			samples += 1
		row /= maxf(float(samples), 1.0)
		if y >= int(image.get_height() * 0.1) and y <= int(image.get_height() * 0.9):
			var delta := row.distance_to(previous)
			if delta > strongest_delta:
				strongest_delta = delta
				horizon_y = y
		previous = row
	if strongest_delta < 0.01:
		return 1.0
	return clampf(float(image.get_height() - horizon_y) / float(image.get_height()), 0.0, 1.0)
