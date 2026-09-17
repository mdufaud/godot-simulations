class_name OceanSolver
extends RefCounted
## Tessendorf FFT ocean on RenderingDevice compute. Per cascade and per frame:
## [spectrum_init if dirty] -> spectrum_evolve -> Stockham row IFFT ->
## transpose -> row IFFT -> map_assemble (displacement + normals + Jacobian
## foam). Everything stays on the GPU; the surface material samples the two
## output texture arrays through Texture2DArrayRD.

const SHADER_DIR := "res://shaders/ocean/"
const SpectrumMetrics := preload("res://scripts/ocean/ocean_spectrum_metrics.gd")
const STAGES: Array[String] = [
	"spectrum_init", "spectrum_evolve", "fft_butterfly", "fft",
	"transpose", "map_assemble",
]
const NUM_SPECTRA := 4
const GRAVITY := 9.81
const FOAM_AMOUNT_REFERENCE := 5.6
const FOAM_NOISE_TEXTURE := preload("res://resources/ocean/foam_detail.png")
## Chop stays full on the long/mid cascades: crests pinch and the Jacobian
## fold — which the foam feeds on — survives at the scales the eye reads.
## Only the fine cascade is damped: full choppiness there folds the surface
## into black back-faces faster than foam can cover them.
const CHOP_PER_CASCADE: PackedFloat32Array = [1.0, 1.0, 0.78]
const TILE_LENGTHS: PackedFloat32Array = [2039.0, 111.0, 25.0]
const JONSWAP_MAX_HEIGHT_GAIN := 3.0
const JONSWAP_BASE_HEIGHT_KNEE_M := 8.0
const JONSWAP_BASE_HEIGHT_LIMIT_M := 10.0
const JONSWAP_TOTAL_HEIGHT_KNEE_M := 8.0
const JONSWAP_TOTAL_HEIGHT_LIMIT_M := 15.0
const JONSWAP_MAX_CHOPPINESS := 1.8
const JONSWAP_CHOPPINESS_KNEE := 1.1
const JONSWAP_CHOPPINESS_LIMIT := 1.35
const JONSWAP_FINE_CHOPPINESS_LIMIT := 0.86

## Wave generation model, driven by OceanPreset.wave_model (int: 0 = FFT, 1 =
## TUTORIAL_GERSTNER; kept as plain int so the two enum types stay assignable).
## FFT runs all three cascades through the spectrum pipeline; TUTORIAL_GERSTNER
## zeroes long/mid and displaces the short cascade with the five periodic
## tutorial waves.
enum WaveModel { FFT, TUTORIAL_GERSTNER }

var config: OceanConfig = OceanConfig.new()
var map_size := 512
## Pairwise non-commensurate lengths (2039/111 = 18.4, 111/25 = 4.44), so the
## super-period of the combined field exceeds any view. Sorted large ->
## small; k-space bands are cut between them. Cascade 0 must hold the spectral
## peak: storm winds put lambda_p near 500 m, so the big tile has to exceed
## that or storms lose their swell. The short 111/25 m tiles give the mid band
## (lambda 4-20 m, where chop reads) ~11 cm texels at 1024^2 — the density the
## reference GodotOceanWaves demo gets from its 57 m tile.
var tile_lengths: PackedFloat32Array = TILE_LENGTHS.duplicate()
var wave_model: int = WaveModel.FFT
var wind_speed := 11.0
var wind_direction := 0.0
var fetch_km := 120.0
var water_depth := 80.0
var swell := 0.8
var spread := 0.2
var detail := 1.0
var jonswap_gamma := 3.3
var choppiness := 1.15
var long_wave_height_m := 2.6
var long_wave_length_m := 48.0
var mid_wave_height_m := 0.0
var mid_wave_length_m := 24.0
var wind_wave_height_m := 0.8
var wind_wave_length_m := 7.5
var crest_bias := 0.08
var crest_gain := 2.4
## Master wave height multiplier, applied k-weighted in spectrum_init (swell
## boost, e-fold at 60 m): short wavelets keep physical steepness even at 5x.
## Changing it requires mark_spectrum_dirty().
var height_gain := 1.0
## Overall amplitude calibration. 1.0 = the physical JONSWAP amplitude (the
## reference GodotOceanWaves look: every visible wave near its breaking
## steepness). The spectrum shaders keep their 0.25 base calibration factor,
## so the solver folds this into the pushed JONSWAP alpha: h ∝ sqrt(alpha),
## alpha_pushed = alpha * (amplitude_scale / 0.25)^2. 0.25 reproduces the old
## quarter-height look. Requires mark_spectrum_dirty().
var amplitude_scale := 1.0
var whitecap := 0.82
var foam_amount := 3.5
var foam_persistence := 5.0
## Accumulated sim time, pushed by the controller every frame.
var sim_time := 0.0
## Update one cascade per frame round-robin instead of all of them.
var amortize := false
var quality_tier: int = OceanQualityProfile.default_tier()

var initialized := false
var profiling := false
var foam_feedback_enabled := true
## Update the finest cascade every other frame. Its wave periods (lambda <
## tile/6) are seconds long, and phases keep advancing with sim_time, so a
## 33 ms displacement hold is invisible; the foam decay compensates through
## foam_step_scale. Saves one spectrum+FFT+assemble chain in three.
var short_cascade_half_rate := false

## Camera-centred near-field foam feedback (shaders/ocean/ocean_foam_near.comp).
## The controller pushes the camera xz every frame; the window follows it and
## reprojects RG (residual, active) coverage so foam stays world-anchored. Its radius
## follows the active quality profile and can be overridden from the menu.
## Production (FFT) wave model only: the tutorial keeps its own per-cascade
## ping-pong.
var foam_near_enabled := true
var foam_near_size := 2048
var foam_near_domain := 256.0
## Update the near feedback every Nth frame (Performance profile: 2).
var foam_near_stride := 1
## Camera xz for the near feedback window; main-thread write, render-thread read.
var near_center := Vector2.ZERO

## GPU point queries against the rendered surface (shaders/ocean/ocean_query.comp):
## the controller submits world xz positions each tick and reads the previous
## tick's results — max one frame of latency, never a blocking readback.
const MAX_QUERY_POINTS := 64

var _query_points_pending := PackedVector2Array()
var _query_has_pending := false
var _query_submitted_count := 0
var _query_latest := PackedVector4Array()
var _query_results_valid := false
var _query_generation := 0

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _spectrum_tex := RID()
var _displacement_tex := RID()
var _normal_tex := RID()
var _derivative_tex := RID()
var _foam_near_tex_a := RID()
var _foam_near_tex_b := RID()
var _foam_mip_views: Array[RID] = []
var _foam_mip_count := 1
var _spectral_references: Array[Dictionary] = []
var _render_time := 0.0
var _render_center := Vector2.ZERO
var _published_foam_state := {"center": Vector2.ZERO, "index": 0, "time": 0.0, "step": 0}
var _foam_state_mutex := Mutex.new()
var _spectral_mutex := Mutex.new()
var _foam_near_read_index := 0
var _foam_near_dt := 0.0
var _near_center_prev := Vector2.ZERO
var _foam_noise_rd := RID()
var _foam_sampler := RID()
var _foam_reset_pending := false
var _foam_near_reset_pending := false
var _cascade_dirty: Array[bool] = []
var _render_refresh_pending := false
var _frame := 0
var _timing_store := GpuTimingStore.new()


func num_cascades() -> int:
	return tile_lengths.size()


func get_displacement_tex_rid() -> RID:
	return _displacement_tex


func get_normal_tex_rid() -> RID:
	return _normal_tex


func get_derivative_tex_rid() -> RID:
	return _derivative_tex


func get_foam_near_read_tex_rid() -> RID:
	return _foam_near_tex_a if _foam_near_read_index == 0 else _foam_near_tex_b


func get_foam_near_tex_rid(index: int) -> RID:
	return _foam_near_tex_a if index == 0 else _foam_near_tex_b


func get_foam_near_read_index() -> int:
	return _foam_near_read_index


func foam_field_domains() -> Vector3:
	return Vector3(foam_near_domain, foam_near_domain * 4.0, foam_near_domain * 16.0)


func foam_state() -> Dictionary:
	_foam_state_mutex.lock()
	var snapshot := _published_foam_state.duplicate()
	_foam_state_mutex.unlock()
	return snapshot


func spectral_references() -> Array[Dictionary]:
	_spectral_mutex.lock()
	if _spectral_references.is_empty():
		_spectral_references = SpectrumMetrics.compute(self)
	var snapshot: Array[Dictionary] = _spectral_references
	_spectral_mutex.unlock()
	return snapshot


func foam_near_active() -> bool:
	return foam_near_enabled \
			and _foam_near_tex_a.is_valid()


## VRAM actually allocated by the current map/near-foam sizes.
func estimate_vram_bytes() -> int:
	return OceanQualityProfile.estimate_vram_bytes_for(map_size, foam_near_size)


## Queue world-space query points for the next step. Results land one frame
## later; read them with latest_results(). At most MAX_QUERY_POINTS are kept.
func submit_queries(points: PackedVector2Array) -> void:
	_query_points_pending = points.slice(0, mini(points.size(), MAX_QUERY_POINTS))
	_query_has_pending = true


## Last completed query results, one vec4 per submitted slot:
## (height, normal_x, normal_z, valid). Empty until the first readback lands.
func latest_results() -> PackedVector4Array:
	return _query_latest


func query_results_valid() -> bool:
	return _query_results_valid


func set_foam_distance(distance: float) -> void:
	var domain := clampf(distance, 16.0, 512.0) * 2.0
	if is_equal_approx(foam_near_domain, domain):
		return
	foam_near_domain = domain
	_near_center_prev = near_center
	_foam_near_reset_pending = true
	_render_refresh_pending = true


## Sea-state params changed: regenerate the initial spectra (cheap, one 256²
## dispatch per cascade; phases stay stable thanks to the fixed seeds).
func mark_spectrum_dirty() -> void:
	_spectral_mutex.lock()
	_spectral_references = SpectrumMetrics.compute(self)
	_spectral_mutex.unlock()
	_query_generation += 1
	_query_results_valid = false
	for i in _cascade_dirty.size():
		_cascade_dirty[i] = true
	_foam_reset_pending = true
	_render_refresh_pending = true


func request_render_refresh() -> void:
	_render_refresh_pending = true


func take_render_refresh_request() -> bool:
	var pending := _render_refresh_pending
	_render_refresh_pending = false
	return pending


func init_render() -> void:
	config.map_size = map_size
	config.clipmap_tile_lengths_m = tile_lengths
	var config_error := config.validate()
	if config_error != "":
		push_error("Ocean config: %s" % config_error)
		return
	_rd = GpuPreflight.device("OceanSolver")
	if _rd == null:
		return

	var defines := "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n\n" % [
		map_size, map_size,
	]
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "ocean_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "ocean_" + stage, defines + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Ocean stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	var n := map_size
	var cascades := num_cascades()
	var log2n := int(log(float(n)) / log(2.0) + 0.5)

	var butterfly_bytes := PackedByteArray()
	butterfly_bytes.resize(log2n * n * 16)
	_buffers["butterfly"] = _rd.storage_buffer_create(butterfly_bytes.size(), butterfly_bytes)

	var fft_bytes := PackedByteArray()
	fft_bytes.resize(cascades * 2 * NUM_SPECTRA * n * n * 8)
	_buffers["fft_data"] = _rd.storage_buffer_create(fft_bytes.size(), fft_bytes)

	_spectrum_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_displacement_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_normal_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_derivative_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_foam_noise_rd = RenderingServer.texture_get_rd_texture(FOAM_NOISE_TEXTURE.get_rid())
	_foam_sampler = _create_foam_sampler()
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _derivative_tex]:
		_rd.texture_clear(tex, Color(0, 0, 0, 0), 0, 1, 0, cascades)

	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		uniforms.append(_image_uniform(0, _spectrum_tex))
		uniforms.append(_buffer_uniform(1, _buffers["butterfly"]))
		uniforms.append(_buffer_uniform(2, _buffers["fft_data"]))
		uniforms.append(_image_uniform(3, _displacement_tex))
		uniforms.append(_image_uniform(4, _normal_tex))
		if stage == "map_assemble":
			uniforms.append(_sampled_texture_uniform(7, _foam_noise_rd))
			uniforms.append(_image_uniform(8, _derivative_tex))
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	var near_spirv := ShaderCache.compile(_rd, "ocean_foam_near", defines
		+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_foam_near.comp"))
	if not near_spirv.compile_error_compute.is_empty():
		push_error("Ocean stage 'foam_near' compile error:\n%s" % near_spirv.compile_error_compute)
		return
	_shaders["foam_near"] = _rd.shader_create_from_spirv(near_spirv)
	_pipelines["foam_near"] = _rd.compute_pipeline_create(_shaders["foam_near"])
	_foam_mip_count = int(log(float(foam_near_size)) / log(2.0)) + 1
	_foam_near_tex_a = _create_foam_array()
	_foam_near_tex_b = _create_foam_array()
	# Vulkan image memory is undefined until cleared, and the first near
	# dispatch reads the input half.
	_clear_foam_fields()
	var mip_spirv := ShaderCache.compile(_rd, "ocean_foam_mipmap", defines
		+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_foam_mipmap.comp"))
	if not mip_spirv.compile_error_compute.is_empty():
		push_error(mip_spirv.compile_error_compute)
		return
	_shaders["foam_mipmap"] = _rd.shader_create_from_spirv(mip_spirv)
	_pipelines["foam_mipmap"] = _rd.compute_pipeline_create(_shaders["foam_mipmap"])
	for index in 2:
		var output := get_foam_near_tex_rid(index)
		for layer in 3:
			var previous_view := RID()
			for mip in _foam_mip_count:
				var view := _rd.texture_create_shared_from_slice(RDTextureView.new(), output, layer, mip)
				_foam_mip_views.append(view)
				if mip == 0:
					var stage := ("foam_near_ab" if index == 1 else "foam_near_ba")
					if layer > 0:
						stage += "_%d" % layer
					var uniforms: Array[RDUniform] = [
						_sampled_texture_uniform(0, _derivative_tex),
						_sampled_texture_uniform(1, get_foam_near_tex_rid(1 - index)),
						_image_uniform(2, view),
					]
					_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders["foam_near"], 0)
					_pipelines[stage] = _rd.compute_pipeline_create(_shaders["foam_near"])
				else:
					var key := "foam_mip_%d_%d_%d" % [index, layer, mip]
					var uniforms: Array[RDUniform] = [_image_uniform(0, previous_view), _image_uniform(1, view)]
					_uniform_sets[key] = _rd.uniform_set_create(uniforms, _shaders["foam_mipmap"], 0)
				previous_view = view
	_foam_near_read_index = 0
	_foam_near_dt = 0.0

	# GPU point queries: two tiny buffers plus one dispatch per submitted
	# batch; results come back through buffer_get_data_async.
	var query_spirv := ShaderCache.compile(_rd, "ocean_query", defines
		+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_query.comp"))
	if not query_spirv.compile_error_compute.is_empty():
		push_error("Ocean stage 'query' compile error:\n%s" % query_spirv.compile_error_compute)
		return
	_shaders["query"] = _rd.shader_create_from_spirv(query_spirv)
	_pipelines["query"] = _rd.compute_pipeline_create(_shaders["query"])
	_buffers["query_in"] = _rd.storage_buffer_create(MAX_QUERY_POINTS * 8)
	_buffers["query_out"] = _rd.storage_buffer_create(MAX_QUERY_POINTS * 16)
	var query_uniforms: Array[RDUniform] = [
		_buffer_uniform(0, _buffers["query_in"]),
		_buffer_uniform(1, _buffers["query_out"]),
		_image_uniform(2, _displacement_tex),
		_image_uniform(3, _normal_tex),
	]
	_uniform_sets["query"] = _rd.uniform_set_create(
		query_uniforms, _shaders["query"], 0)
	_query_has_pending = false
	_query_results_valid = false
	_query_submitted_count = 0

	_cascade_dirty.resize(cascades)
	mark_spectrum_dirty()
	_foam_reset_pending = false
	_foam_near_reset_pending = false

	# Butterfly factors depend only on MAP_SIZE: dispatch once.
	var pc := _pack_push_constant(0, 0.0, 0.0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "fft_butterfly", pc, maxi(n / 128, 1), log2n, 1)
	_rd.compute_list_end()

	_frame = 0
	initialized = true


func step_render(delta: float, step_time: float = -1.0, step_center: Vector2 = Vector2(INF, INF)) -> void:
	if not initialized:
		return
	_render_time = sim_time if step_time < 0.0 else step_time
	_render_center = near_center if not step_center.is_finite() else step_center
	if profiling:
		_read_timings()
	if _foam_reset_pending:
		_clear_foam_fields()
		_foam_near_read_index = 0
		_foam_near_dt = 0.0
		_foam_reset_pending = false
		_foam_near_reset_pending = false
	elif _foam_near_reset_pending:
		_clear_foam_fields()
		_foam_near_read_index = 0
		_foam_near_dt = 0.0
		_foam_near_reset_pending = false

	var g16 := map_size / 16
	var g32 := map_size / 32
	var cascade_list: Array = []
	if amortize:
		for i in num_cascades():
			if i == _frame % num_cascades() or _cascade_dirty[i]:
				cascade_list.append(i)
	else:
		for i in num_cascades():
			# The fine cascade skips odd frames once short_cascade_half_rate is
			# set; a dirty spectrum (preset edit) always runs immediately.
			if i < num_cascades() - 1 or not short_cascade_half_rate \
					or _frame % 2 == 0 or _cascade_dirty[i]:
				cascade_list.append(i)

	if profiling:
		_rd.capture_timestamp("ocean/start")
	var cl := _rd.compute_list_begin()
	for i in cascade_list:
		var pc := _pack_push_constant(i, 0.0, 0.0, _render_time)
		if _cascade_dirty[i]:
			_dispatch(cl, "spectrum_init", pc, g16, g16, 1)
			_cascade_dirty[i] = false
		_dispatch(cl, "spectrum_evolve", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/spectrum")
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		_dispatch(cl, "transpose", pc, g32, g32, NUM_SPECTRA)
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		cl = _mark(cl, "ocean/fft")
		_dispatch(cl, "map_assemble", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/assemble")
		cl = _mark(cl, "ocean/foam")
	# Near-field feedback once per (stride) frames, on the accumulated dt.
	_foam_near_dt += delta
	if foam_near_enabled:
		if _frame % maxi(foam_near_stride, 1) == 0:
			var near_stage := "foam_near_ab" if _foam_near_read_index == 0 \
				else "foam_near_ba"
			for layer in 3:
				var stage := near_stage if layer == 0 else near_stage + "_%d" % layer
				_dispatch(cl, stage, _pack_near_push_constant(_foam_near_dt, layer),
					foam_near_size / 16, foam_near_size / 16, 1)
			_foam_near_read_index = 1 - _foam_near_read_index
			_generate_foam_mips(cl, _foam_near_read_index)
			_near_center_prev = _render_center
			_foam_near_dt = 0.0
			cl = _mark(cl, "ocean/foam_near")
	else:
		# Keep the accumulator pinned while the field is off, so re-enabling
		# never replays the whole off period as one giant decay/injection step.
		_foam_near_dt = 0.0
	_rd.compute_list_end()
	_dispatch_pending_queries()
	if profiling:
		_rd.capture_timestamp("ocean/end")
	_frame += 1
	_foam_state_mutex.lock()
	_published_foam_state = {"center": _near_center_prev, "index": _foam_near_read_index,
		"time": _render_time, "step": _frame}
	_foam_state_mutex.unlock()


## Render thread. Uploads the pending points, dispatches one query pass and
## kicks the async readback. buffer_update must run between compute lists.
func _dispatch_pending_queries() -> void:
	if not _query_has_pending:
		return
	_query_has_pending = false
	var points := _query_points_pending
	if points.is_empty():
		return
	_query_submitted_count = points.size()
	var in_bytes := PackedByteArray()
	in_bytes.resize(MAX_QUERY_POINTS * 8)
	for i in points.size():
		in_bytes.encode_float(i * 8, points[i].x)
		in_bytes.encode_float(i * 8 + 4, points[i].y)
	_rd.buffer_update(_buffers["query_in"], 0, in_bytes.size(), in_bytes)
	var pc := PackedByteArray()
	pc.resize(32)
	pc.encode_float(0, tile_lengths[0])
	pc.encode_float(4, tile_lengths[1])
	pc.encode_float(8, tile_lengths[2])
	pc.encode_float(12, float(map_size))
	pc.encode_s32(16, num_cascades())
	pc.encode_s32(20, points.size())
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "query", pc, 1, 1, 1)
	_rd.compute_list_end()
	# Timestamped as its own segment: everything after the last stage mark and
	# before "ocean/end" is the query dispatch.
	if profiling:
		_rd.capture_timestamp("ocean/query")
	_rd.buffer_get_data_async(_buffers["query_out"],
		_store_query_results.bind(_query_submitted_count, _query_generation),
		0, MAX_QUERY_POINTS * 16)


# Render thread: decode the readback, then hop to the main thread. Only the
# submitted slots are meaningful; the rest of the buffer stays stale.
func _store_query_results(data: PackedByteArray, submitted_count: int, generation: int) -> void:
	var floats := data.to_float32_array()
	var results := PackedVector4Array()
	var count := mini(submitted_count, MAX_QUERY_POINTS)
	results.resize(count)
	for i in count:
		results[i] = Vector4(floats[i * 4], floats[i * 4 + 1],
			floats[i * 4 + 2], floats[i * 4 + 3])
	_apply_query_results.call_deferred(results, generation)


# Main thread.
func _apply_query_results(results: PackedVector4Array, generation: int) -> void:
	if generation != _query_generation:
		return
	_query_latest = results
	_query_results_valid = true


func free_render() -> void:
	initialized = false
	if _rd == null:
		return
	for stage in _uniform_sets:
		if _uniform_sets[stage].is_valid():
			_rd.free_rid(_uniform_sets[stage])
	for key in _buffers:
		if _buffers[key].is_valid():
			_rd.free_rid(_buffers[key])
	for view in _foam_mip_views:
		if view.is_valid():
			_rd.free_rid(view)
	_foam_mip_views.clear()
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _derivative_tex,
			_foam_near_tex_a, _foam_near_tex_b]:
		if tex.is_valid():
			_rd.free_rid(tex)
	if _foam_sampler.is_valid():
		_rd.free_rid(_foam_sampler)
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_uniform_sets.clear()
	_buffers.clear()
	_pipelines.clear()
	_shaders.clear()
	_spectrum_tex = RID()
	_displacement_tex = RID()
	_normal_tex = RID()
	_derivative_tex = RID()
	_foam_near_tex_a = RID()
	_foam_near_tex_b = RID()
	_foam_noise_rd = RID()
	_foam_sampler = RID()
	_cascade_dirty.clear()


func _create_tex_array(format: RenderingDevice.DataFormat) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = map_size
	fmt.height = map_size
	fmt.array_layers = num_cascades()
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _create_foam_array() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = foam_near_size
	fmt.height = foam_near_size
	fmt.array_layers = 3
	fmt.mipmaps = _foam_mip_count
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _clear_foam_fields() -> void:
	for texture in [_foam_near_tex_a, _foam_near_tex_b]:
		_rd.texture_clear(texture, Color(0, 0, 0, 0), 0, _foam_mip_count, 0, 3)


func _generate_foam_mips(cl: int, index: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["foam_mipmap"])
	for mip in range(1, _foam_mip_count):
		var size := maxi(foam_near_size >> mip, 1)
		var pc := PackedByteArray()
		pc.resize(16)
		pc.encode_s32(0, size)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		for layer in 3:
			var key := "foam_mip_%d_%d_%d" % [index, layer, mip]
			_rd.compute_list_bind_uniform_set(cl, _uniform_sets[key], 0)
			_rd.compute_list_dispatch(cl, maxi((size + 15) / 16, 1), maxi((size + 15) / 16, 1), 1)
		_rd.compute_list_add_barrier(cl)


func _image_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _sampled_texture_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_foam_sampler)
	u.add_id(rid)
	return u


func _create_foam_sampler() -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	return _rd.sampler_create(state)


func _dispatch(cl: int, stage: String, pc: PackedByteArray, gx: int, gy: int, gz: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, gz)
	_rd.compute_list_add_barrier(cl)


func _jonswap_significant_height(scale: float) -> float:
	var wind := maxf(wind_speed, 0.01)
	var fetch_m := maxf(fetch_km * 1000.0, 1.0)
	var alpha := 0.076 * pow(wind * wind / (fetch_m * GRAVITY), 0.22)
	var omega_p := 22.0 * pow(GRAVITY * GRAVITY / (wind * fetch_m), 1.0 / 3.0)
	return 2.20903 * sqrt(alpha) * GRAVITY \
		/ maxf(omega_p * omega_p, 0.0001) * maxf(scale, 0.0)


func _soft_limit(value: float, knee: float, limit: float) -> float:
	if value <= knee:
		return value
	var span := limit - knee
	return knee + span * (1.0 - exp(-(value - knee) / span))


func effective_amplitude_scale() -> float:
	var raw_height := _jonswap_significant_height(amplitude_scale)
	if raw_height <= 0.0:
		return maxf(amplitude_scale, 0.0)
	var safe_height := _soft_limit(raw_height,
		JONSWAP_BASE_HEIGHT_KNEE_M, JONSWAP_BASE_HEIGHT_LIMIT_M)
	return amplitude_scale * safe_height / raw_height


func effective_height_gain() -> float:
	var base_height := _jonswap_significant_height(effective_amplitude_scale())
	var input_gain := clampf(height_gain, 0.0, JONSWAP_MAX_HEIGHT_GAIN)
	if base_height <= 0.0:
		return input_gain
	if input_gain <= 1.0:
		return input_gain
	var max_height := _soft_limit(base_height * JONSWAP_MAX_HEIGHT_GAIN,
		JONSWAP_TOTAL_HEIGHT_KNEE_M, JONSWAP_TOTAL_HEIGHT_LIMIT_M)
	var safe_height := lerpf(base_height, max_height,
		(input_gain - 1.0) / (JONSWAP_MAX_HEIGHT_GAIN - 1.0))
	return safe_height / base_height


func effective_choppiness(cascade: int = 0) -> float:
	var raw := clampf(choppiness, 0.0, JONSWAP_MAX_CHOPPINESS)
	var compressed := raw
	if raw > JONSWAP_CHOPPINESS_KNEE:
		compressed = remap(raw, JONSWAP_CHOPPINESS_KNEE, JONSWAP_MAX_CHOPPINESS,
			JONSWAP_CHOPPINESS_KNEE, JONSWAP_CHOPPINESS_LIMIT)
	if cascade == 2:
		if raw <= JONSWAP_CHOPPINESS_KNEE:
			return raw * CHOP_PER_CASCADE[cascade]
		return remap(raw, JONSWAP_CHOPPINESS_KNEE, JONSWAP_MAX_CHOPPINESS,
			JONSWAP_CHOPPINESS_KNEE * CHOP_PER_CASCADE[cascade],
			JONSWAP_FINE_CHOPPINESS_LIMIT)
	return compressed * CHOP_PER_CASCADE[cascade]


func _pack_near_push_constant(dt: float, layer: int = 0) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(96)
	var texel := foam_field_domains()[layer] / foam_near_size
	var center := (_render_center / texel).floor() * texel
	var previous_center := (_near_center_prev / texel).floor() * texel
	pc.encode_float(0, center.x)
	pc.encode_float(4, center.y)
	pc.encode_float(8, previous_center.x)
	pc.encode_float(12, previous_center.y)
	var foam_gain := clampf(foam_amount / FOAM_AMOUNT_REFERENCE, 0.0, 1.0) \
		if foam_feedback_enabled else 0.0
	pc.encode_float(16, dt * 0.693 / maxf(foam_persistence, 0.05))
	pc.encode_float(20, dt * 0.693 / maxf(foam_persistence * 0.167, 0.02))
	pc.encode_float(24, dt * 0.693 / maxf(foam_persistence, 0.05) * 0.68)
	pc.encode_float(28, dt * foam_gain * 6.0)
	pc.encode_float(32, foam_field_domains()[layer])
	pc.encode_float(36, maxf(dt, 0.0001))
	pc.encode_float(40, 0.15)
	pc.encode_float(44, float(foam_near_size))
	var enabled_mask := 0
	for i in num_cascades():
		enabled_mask |= 1 << i
	pc.encode_s32(48, layer)
	pc.encode_s32(52, enabled_mask)
	pc.encode_s32(56, 0)
	pc.encode_s32(60, 0)
	pc.encode_float(64, tile_lengths[0])
	pc.encode_float(68, tile_lengths[1])
	pc.encode_float(72, tile_lengths[2])
	pc.encode_float(76, clampf(whitecap, 0.05, 0.95))
	pc.encode_float(80, 1.0)
	pc.encode_float(84, 1.0)
	# Waves travel world (cos θ, sin θ): the FFT texture axes swap into world
	# axes, the same convention the rain and spray layers already follow.
	var wind_dir := Vector2(cos(wind_direction), sin(wind_direction))
	pc.encode_float(88, wind_dir.x)
	pc.encode_float(92, wind_dir.y)
	return pc


## k-space boundary between cascade i and i+1: the finer cascade takes over at
## 6 of its tile wavelengths, where it has ~9 texels per wavelength.
func _k_max(cascade: int) -> float:
	if cascade >= num_cascades() - 1:
		return 1e9
	return TAU / tile_lengths[cascade + 1] * 6.0


func _pack_push_constant(cascade: int, foam_gain: float, decay_rate: float, step_time: float = -1.0) -> PackedByteArray:
	var fetch_m := fetch_km * 1000.0
	var alpha := 0.076 * pow(wind_speed * wind_speed / (fetch_m * GRAVITY), 0.22)
	# amplitude_scale rides on alpha: the JONSWAP/TMA spectrum is linear in
	# alpha, so the height amplitude scales with its square root exactly.
	alpha *= pow(effective_amplitude_scale() / 0.25, 2.0)
	var omega_p := 22.0 * pow(GRAVITY * GRAVITY / (wind_speed * fetch_m), 1.0 / 3.0)
	var k_min := 0.0001 if cascade == 0 else _k_max(cascade - 1)
	var eff_chop := effective_choppiness(cascade)

	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, tile_lengths[cascade])
	pc.encode_float(4, alpha)
	pc.encode_float(8, omega_p)
	pc.encode_float(12, wind_speed)
	pc.encode_float(16, wind_direction)
	pc.encode_float(20, water_depth)
	pc.encode_float(24, swell)
	pc.encode_float(28, detail)
	pc.encode_float(32, spread)
	pc.encode_float(36, k_min)
	pc.encode_float(40, _k_max(cascade))
	pc.encode_float(44, eff_chop)
	pc.encode_float(48, whitecap)
	pc.encode_float(52, foam_gain)
	pc.encode_float(56, decay_rate)
	pc.encode_float(60, sim_time if step_time < 0.0 else step_time)
	pc.encode_s32(64, cascade)
	pc.encode_s32(68, 1000 + cascade * 7919)
	pc.encode_s32(72, 31337 + cascade * 104729)
	pc.encode_s32(76, int(wave_model == WaveModel.TUTORIAL_GERSTNER))
	pc.encode_float(80, effective_height_gain())
	var reference: Dictionary = spectral_references()[cascade]
	pc.encode_float(84, reference.height_rms_m if wave_model == WaveModel.FFT else long_wave_height_m)
	pc.encode_float(88, reference.wavelength_m if wave_model == WaveModel.FFT else long_wave_length_m)
	pc.encode_float(92, wind_wave_height_m)
	pc.encode_float(96, wind_wave_length_m)
	pc.encode_float(104, jonswap_gamma)
	pc.encode_float(108, crest_gain)
	pc.encode_float(112, crest_bias)
	pc.encode_float(116, mid_wave_height_m)
	pc.encode_float(120, mid_wave_length_m)
	return pc


# Timestamps cannot be captured inside an open compute list; split the list
# at stage boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Reads last frame's timestamps; repeated names sum across cascades.
func _read_timings() -> void:
	var out := GpuTimings.read(_rd, "ocean/")
	if out.is_empty():
		return
	_timing_store.publish(out)


# Main thread. GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	return _timing_store.snapshot()
