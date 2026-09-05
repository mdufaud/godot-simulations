class_name OceanSolver
extends RefCounted
## Tessendorf FFT ocean on RenderingDevice compute. Per cascade and per frame:
## [spectrum_init if dirty] -> spectrum_evolve -> Stockham row IFFT ->
## transpose -> row IFFT -> map_assemble (displacement + normals + Jacobian
## foam). Everything stays on the GPU; the surface material samples the two
## output texture arrays through Texture2DArrayRD.

const SHADER_DIR := "res://shaders/ocean/"
const STAGES: Array[String] = [
	"spectrum_init", "spectrum_init_art_directed", "spectrum_evolve", "fft_butterfly", "fft",
	"transpose", "map_assemble", "foam_feedback",
]
const NUM_SPECTRA := 4
const GRAVITY := 9.81
const FOAM_AMOUNT_REFERENCE := 5.6
const TUTORIAL_FOAM_DECAY_RATE := 3.5
const FOAM_PATTERN_TEXTURE := preload("res://resources/ocean/foam_detail.png")
const FOAM_NOISE_TEXTURE := preload("res://resources/ocean/foam_detail.png")
## All cascades keep feedback history. The tutorial Gerstner displacement and
## its high-resolution foam source live on the short cascade.
var foam_cascade_count := 3
## Full choppiness on short waves folds the surface into black back-faces;
## damp it as the cascades get finer.
const CHOP_PER_CASCADE: PackedFloat32Array = [1.0, 0.8, 0.55]

enum Backend { JONSWAP_TMA, SEA_OF_THIEVES_INSPIRED_FFT }

## Wave generation model, driven by OceanPreset.wave_model (int: 0 = FFT, 1 =
## TUTORIAL_GERSTNER; kept as plain int so the two enum types stay assignable).
## FFT runs all three cascades through the spectrum pipeline; TUTORIAL_GERSTNER
## zeroes long/mid and displaces the short cascade with the five periodic
## tutorial waves.
enum WaveModel { FFT, TUTORIAL_GERSTNER }

var config: OceanConfig = OceanConfig.new()
var map_size := 512
## Pairwise non-commensurate lengths (2039/257, 257/67: no integer ratio), so
## the super-period of the combined field exceeds any view. Sorted large ->
## small; k-space bands are cut between them. Cascade 0 must hold the spectral
## peak: storm winds put lambda_p near 500 m, so the big tile has to exceed
## that or storms lose their swell. The 67 m short tile keeps the dominant
## repetition beyond the 60 m no-tile window.
var tile_lengths: PackedFloat32Array = PackedFloat32Array([2039.0, 257.0, 67.0])
var backend: Backend = Backend.SEA_OF_THIEVES_INSPIRED_FFT
var wave_model: int = WaveModel.FFT
var wind_speed := 11.0
var wind_direction := 0.0
var fetch_km := 120.0
var water_depth := 80.0
var swell := 0.8
var spread := 0.2
var detail := 1.0
var choppiness := 1.15
var long_wave_height_m := 2.6
var long_wave_length_m := 48.0
var mid_wave_height_m := 0.0
var mid_wave_length_m := 24.0
var mid_wave_spread := 0.0
var wind_wave_height_m := 0.8
var wind_wave_length_m := 7.5
var ripple_strength := 0.9
var crosswind_ratio := 0.14
var crest_bias := 0.08
var crest_gain := 2.4
## Master wave height multiplier, applied k-weighted in spectrum_init (swell
## boost, e-fold at 60 m): short wavelets keep physical steepness even at 5x.
## Changing it requires mark_spectrum_dirty().
var height_gain := 1.0
var whitecap := 0.82
var foam_amount := 3.5
var foam_persistence := 5.0
## Accumulated sim time, pushed by the controller every frame.
var sim_time := 0.0
## Update one cascade per frame round-robin instead of all of them.
var amortize := false
var quality_tier: int = OceanQualityProfile.DEFAULT_TIER

var initialized := false
var profiling := false
var foam_feedback_enabled := true

## Camera-centred near-field foam feedback (shaders/ocean/ocean_foam_near.comp).
## The controller pushes the camera xz every frame; the 20 m window follows it
## and reprojects the previous coverage so foam stays world-anchored. Production
## (FFT) wave model only: the tutorial keeps its own per-cascade ping-pong.
var foam_near_enabled := true
var foam_near_size := 2048
var foam_near_domain := 20.0
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

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _spectrum_tex := RID()
var _displacement_tex := RID()
var _normal_tex := RID()
var _foam_tex_a := RID()
var _foam_tex_b := RID()
var _foam_near_tex_a := RID()
var _foam_near_tex_b := RID()
var _foam_near_read_index := 0
var _foam_near_dt := 0.0
var _near_center_prev := Vector2.ZERO
var _foam_pattern_rd := RID()
var _foam_noise_rd := RID()
var _foam_sampler := RID()
var _foam_read_indices := PackedInt32Array()
var _foam_last_update_frame := PackedInt32Array()
var _foam_reset_pending := false
var _cascade_dirty: Array[bool] = []
var _frame := 0
var _timing_store := GpuTimingStore.new()


func num_cascades() -> int:
	return tile_lengths.size()


func get_displacement_tex_rid() -> RID:
	return _displacement_tex


func get_normal_tex_rid() -> RID:
	return _normal_tex


func get_foam_read_tex_rid(cascade: int) -> RID:
	if cascade < 0 or cascade >= _foam_read_indices.size():
		return RID()
	return _foam_tex_a if _foam_read_indices[cascade] == 0 else _foam_tex_b


func get_foam_tex_rid(index: int) -> RID:
	return _foam_tex_a if index == 0 else _foam_tex_b


func get_foam_read_indices() -> Vector4:
	var indices := Vector4(0.0, 0.0, 0.0, 0.0)
	if _foam_read_indices.size() > 0:
		indices.x = float(_foam_read_indices[0])
	if _foam_read_indices.size() > 1:
		indices.y = float(_foam_read_indices[1])
	if _foam_read_indices.size() > 2:
		indices.z = float(_foam_read_indices[2])
	return indices


func get_foam_near_read_tex_rid() -> RID:
	return _foam_near_tex_a if _foam_near_read_index == 0 else _foam_near_tex_b


func get_foam_near_tex_rid(index: int) -> RID:
	return _foam_near_tex_a if index == 0 else _foam_near_tex_b


func get_foam_near_read_index() -> int:
	return _foam_near_read_index


## True when the near feedback runs: the textures exist and the pass is
## dispatched (FFT wave model only). The surface must refresh its
## foam_near_enabled flag from this every frame — the solver stops updating
## the near textures in tutorial mode, and stale blending would fade the
## near-camera foam toward half its history value.
func foam_near_active() -> bool:
	return foam_near_enabled and wave_model == WaveModel.FFT \
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


func set_backend(value: Backend) -> void:
	if backend == value:
		return
	backend = value
	mark_spectrum_dirty()


## Sea-state params changed: regenerate the initial spectra (cheap, one 256²
## dispatch per cascade; phases stay stable thanks to the fixed seeds).
func mark_spectrum_dirty() -> void:
	for i in _cascade_dirty.size():
		_cascade_dirty[i] = true
	_foam_reset_pending = true


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
	_foam_tex_a = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT)
	_foam_tex_b = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT)
	_foam_pattern_rd = RenderingServer.texture_get_rd_texture(FOAM_PATTERN_TEXTURE.get_rid())
	_foam_noise_rd = RenderingServer.texture_get_rd_texture(FOAM_NOISE_TEXTURE.get_rid())
	_foam_sampler = _create_foam_sampler()
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _foam_tex_a, _foam_tex_b]:
		_rd.texture_clear(tex, Color(0, 0, 0, 0), 0, 1, 0, cascades)

	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		uniforms.append(_image_uniform(0, _spectrum_tex))
		uniforms.append(_buffer_uniform(1, _buffers["butterfly"]))
		uniforms.append(_buffer_uniform(2, _buffers["fft_data"]))
		uniforms.append(_image_uniform(3, _displacement_tex))
		uniforms.append(_image_uniform(4, _normal_tex))
		uniforms.append(_image_uniform(5, _foam_tex_a))
		uniforms.append(_image_uniform(6, _foam_tex_b))
		if stage == "map_assemble":
			uniforms.append(_sampled_texture_uniform(7, _foam_noise_rd))
		elif stage == "foam_feedback":
			uniforms.append(_sampled_texture_uniform(7, _foam_pattern_rd))
			uniforms.append(_sampled_texture_uniform(8, _foam_noise_rd))
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	var foam_ab: Array[RDUniform] = []
	foam_ab.append(_image_uniform(0, _spectrum_tex))
	foam_ab.append(_buffer_uniform(1, _buffers["butterfly"]))
	foam_ab.append(_buffer_uniform(2, _buffers["fft_data"]))
	foam_ab.append(_image_uniform(3, _displacement_tex))
	foam_ab.append(_image_uniform(4, _normal_tex))
	foam_ab.append(_image_uniform(5, _foam_tex_a))
	foam_ab.append(_image_uniform(6, _foam_tex_b))
	foam_ab.append(_sampled_texture_uniform(7, _foam_pattern_rd))
	foam_ab.append(_sampled_texture_uniform(8, _foam_noise_rd))
	_uniform_sets["foam_feedback_ab"] = _rd.uniform_set_create(
		foam_ab, _shaders["foam_feedback"], 0)

	var foam_ba: Array[RDUniform] = []
	foam_ba.append(_image_uniform(0, _spectrum_tex))
	foam_ba.append(_buffer_uniform(1, _buffers["butterfly"]))
	foam_ba.append(_buffer_uniform(2, _buffers["fft_data"]))
	foam_ba.append(_image_uniform(3, _displacement_tex))
	foam_ba.append(_image_uniform(4, _normal_tex))
	foam_ba.append(_image_uniform(5, _foam_tex_b))
	foam_ba.append(_image_uniform(6, _foam_tex_a))
	foam_ba.append(_sampled_texture_uniform(7, _foam_pattern_rd))
	foam_ba.append(_sampled_texture_uniform(8, _foam_noise_rd))
	_uniform_sets["foam_feedback_ba"] = _rd.uniform_set_create(
		foam_ba, _shaders["foam_feedback"], 0)
	_pipelines["foam_feedback_ab"] = _rd.compute_pipeline_create(_shaders["foam_feedback"])
	_pipelines["foam_feedback_ba"] = _rd.compute_pipeline_create(_shaders["foam_feedback"])

	# Near-field foam feedback: standalone shader (own bindings and push
	# constant), single 2D ping-pong textures, camera-centred 20 m window.
	var near_spirv := ShaderCache.compile(_rd, "ocean_foam_near", defines
		+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_foam_near.comp"))
	if not near_spirv.compile_error_compute.is_empty():
		push_error("Ocean stage 'foam_near' compile error:\n%s" % near_spirv.compile_error_compute)
		return
	_shaders["foam_near"] = _rd.shader_create_from_spirv(near_spirv)
	_pipelines["foam_near"] = _rd.compute_pipeline_create(_shaders["foam_near"])
	_foam_near_tex_a = _create_tex_2d(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, foam_near_size)
	_foam_near_tex_b = _create_tex_2d(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, foam_near_size)
	# Vulkan image memory is undefined until cleared, and the first near
	# dispatch reads the input half.
	_rd.texture_clear(_foam_near_tex_a, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rd.texture_clear(_foam_near_tex_b, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var near_ab: Array[RDUniform] = [
		_image_uniform(0, _foam_tex_a),
		_image_uniform(1, _foam_tex_b),
		_image_uniform(2, _foam_near_tex_a),
		_image_uniform(3, _foam_near_tex_b),
	]
	_uniform_sets["foam_near_ab"] = _rd.uniform_set_create(
		near_ab, _shaders["foam_near"], 0)
	var near_ba: Array[RDUniform] = [
		_image_uniform(0, _foam_tex_a),
		_image_uniform(1, _foam_tex_b),
		_image_uniform(2, _foam_near_tex_b),
		_image_uniform(3, _foam_near_tex_a),
	]
	_uniform_sets["foam_near_ba"] = _rd.uniform_set_create(
		near_ba, _shaders["foam_near"], 0)
	_pipelines["foam_near_ab"] = _rd.compute_pipeline_create(_shaders["foam_near"])
	_pipelines["foam_near_ba"] = _rd.compute_pipeline_create(_shaders["foam_near"])
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
	_foam_read_indices.resize(cascades)
	_foam_last_update_frame.resize(cascades)
	for i in cascades:
		_foam_read_indices[i] = 0
		_foam_last_update_frame[i] = -1
	mark_spectrum_dirty()
	_foam_reset_pending = false

	# Butterfly factors depend only on MAP_SIZE: dispatch once.
	var pc := _pack_push_constant(0, 0.0, 0.0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "fft_butterfly", pc, maxi(n / 128, 1), log2n, 1)
	_rd.compute_list_end()

	_frame = 0
	initialized = true


func step_render(delta: float) -> void:
	if not initialized:
		return
	_read_timings()
	if _foam_reset_pending:
		_rd.texture_clear(_foam_tex_a, Color(0, 0, 0, 0), 0, 1, 0, num_cascades())
		_rd.texture_clear(_foam_tex_b, Color(0, 0, 0, 0), 0, 1, 0, num_cascades())
		_rd.texture_clear(_foam_near_tex_a, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(_foam_near_tex_b, Color(0, 0, 0, 0), 0, 1, 0, 1)
		for i in _foam_read_indices.size():
			_foam_read_indices[i] = 0
			_foam_last_update_frame[i] = _frame - 1
		_foam_near_read_index = 0
		_foam_near_dt = 0.0
		_foam_reset_pending = false

	var tutorial_model := wave_model == WaveModel.TUTORIAL_GERSTNER
	var foam_injection := clampf(foam_amount / FOAM_AMOUNT_REFERENCE, 0.0, 1.0) \
		if tutorial_model else delta * foam_amount * 0.49
	var decay_rate := delta * TUTORIAL_FOAM_DECAY_RATE if tutorial_model \
		else delta * 0.693 / maxf(foam_persistence, 0.05)

	var g16 := map_size / 16
	var g32 := map_size / 32
	var cascade_list: Array = range(num_cascades()) if not amortize \
		else [_frame % num_cascades()]

	_rd.capture_timestamp("ocean/start")
	var cl := _rd.compute_list_begin()
	for i in cascade_list:
		var pc := _pack_push_constant(i, foam_injection, decay_rate)
		if _cascade_dirty[i]:
			var init_stage := "spectrum_init_art_directed" \
				if backend == Backend.SEA_OF_THIEVES_INSPIRED_FFT else "spectrum_init"
			_dispatch(cl, init_stage, pc, g16, g16, 1)
			_cascade_dirty[i] = false
		_dispatch(cl, "spectrum_evolve", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/spectrum")
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		_dispatch(cl, "transpose", pc, g32, g32, NUM_SPECTRA)
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		cl = _mark(cl, "ocean/fft")
		_dispatch(cl, "map_assemble", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/assemble")
		var should_update_foam: bool = foam_feedback_enabled \
			and i < foam_cascade_count
		if should_update_foam:
			var elapsed_frames := _frame - _foam_last_update_frame[i]
			var foam_step_scale := float(maxi(elapsed_frames, 1))
			var feedback_injection := foam_injection if tutorial_model \
				else foam_injection * foam_step_scale
			var foam_pc := _pack_push_constant(i, feedback_injection,
				decay_rate * foam_step_scale)
			var foam_stage := "foam_feedback_ab" if _foam_read_indices[i] == 0 \
				else "foam_feedback_ba"
			_dispatch(cl, foam_stage, foam_pc, g16, g16, 1)
			_foam_read_indices[i] = 1 - _foam_read_indices[i]
			_foam_last_update_frame[i] = _frame
		cl = _mark(cl, "ocean/foam")
	# Near-field feedback once per (stride) frames, on the accumulated dt.
	_foam_near_dt += delta
	if foam_near_enabled and wave_model == WaveModel.FFT \
			and _frame % maxi(foam_near_stride, 1) == 0:
		var near_stage := "foam_near_ab" if _foam_near_read_index == 0 \
			else "foam_near_ba"
		_dispatch(cl, near_stage, _pack_near_push_constant(_foam_near_dt),
			foam_near_size / 16, foam_near_size / 16, 1)
		_foam_near_read_index = 1 - _foam_near_read_index
		_near_center_prev = near_center
		_foam_near_dt = 0.0
		cl = _mark(cl, "ocean/foam_near")
	_rd.compute_list_end()
	_dispatch_pending_queries()
	_rd.capture_timestamp("ocean/end")
	_frame += 1


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
	_rd.buffer_get_data_async(_buffers["query_out"], _store_query_results,
		0, MAX_QUERY_POINTS * 16)


# Render thread: decode the readback, then hop to the main thread. Only the
# submitted slots are meaningful; the rest of the buffer stays stale.
func _store_query_results(data: PackedByteArray) -> void:
	var floats := data.to_float32_array()
	var results := PackedVector4Array()
	var count := mini(_query_submitted_count, MAX_QUERY_POINTS)
	results.resize(count)
	for i in count:
		results[i] = Vector4(floats[i * 4], floats[i * 4 + 1],
			floats[i * 4 + 2], floats[i * 4 + 3])
	_apply_query_results.call_deferred(results)


# Main thread.
func _apply_query_results(results: PackedVector4Array) -> void:
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
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _foam_tex_a, _foam_tex_b,
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
	_foam_tex_a = RID()
	_foam_tex_b = RID()
	_foam_near_tex_a = RID()
	_foam_near_tex_b = RID()
	_foam_pattern_rd = RID()
	_foam_noise_rd = RID()
	_foam_sampler = RID()
	_foam_read_indices.clear()
	_foam_last_update_frame.clear()
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


func _create_tex_2d(format: RenderingDevice.DataFormat, size: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.width = size
	fmt.height = size
	fmt.array_layers = 1
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [])


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


## Push constant of the near-field foam feedback (96 B, layout documented in
## ocean_foam_near.comp). Injection weights: the short cascade dominates, mid
## and long add context.
func _pack_near_push_constant(dt: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(96)
	pc.encode_float(0, near_center.x)
	pc.encode_float(4, near_center.y)
	pc.encode_float(8, _near_center_prev.x)
	pc.encode_float(12, _near_center_prev.y)
	var foam_gain := clampf(foam_amount / FOAM_AMOUNT_REFERENCE, 0.0, 1.0)
	pc.encode_float(16, dt * 0.693 / maxf(foam_persistence, 0.05))
	pc.encode_float(20, dt * 0.693 / maxf(foam_persistence * 0.167, 0.02))
	pc.encode_float(24, foam_gain * 0.02)
	pc.encode_float(28, foam_gain * 0.5)
	pc.encode_float(32, foam_near_domain)
	pc.encode_float(36, maxf(dt, 0.0001))
	pc.encode_float(40, 0.6)
	pc.encode_float(44, float(foam_near_size))
	var read_mask := 0
	var enabled_mask := 0
	for i in num_cascades():
		if _foam_read_indices[i] == 0:
			read_mask |= 1 << i
		enabled_mask |= 1 << i
	pc.encode_s32(48, read_mask)
	pc.encode_s32(52, enabled_mask)
	pc.encode_s32(56, 0)
	pc.encode_s32(60, 0)
	pc.encode_float(64, tile_lengths[0])
	pc.encode_float(68, tile_lengths[1])
	pc.encode_float(72, tile_lengths[2])
	pc.encode_float(76, 0.35)
	pc.encode_float(80, 0.7)
	pc.encode_float(84, 1.0)
	var wind_dir := Vector2(sin(wind_direction), cos(wind_direction))
	pc.encode_float(88, wind_dir.x)
	pc.encode_float(92, wind_dir.y)
	return pc


## k-space boundary between cascade i and i+1: the finer cascade takes over at
## 6 of its tile wavelengths, where it has ~9 texels per wavelength.
func _k_max(cascade: int) -> float:
	if cascade >= num_cascades() - 1:
		return 1e9
	return TAU / tile_lengths[cascade + 1] * 6.0


func _pack_push_constant(cascade: int, foam_gain: float, decay_rate: float) -> PackedByteArray:
	var fetch_m := fetch_km * 1000.0
	var alpha := 0.076 * pow(wind_speed * wind_speed / (fetch_m * GRAVITY), 0.22)
	var omega_p := 22.0 * pow(GRAVITY * GRAVITY / (wind_speed * fetch_m), 1.0 / 3.0)
	var k_min := 0.0001 if cascade == 0 else _k_max(cascade - 1)
	var eff_chop := choppiness * CHOP_PER_CASCADE[cascade]

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
	pc.encode_float(60, sim_time)
	pc.encode_s32(64, cascade)
	pc.encode_s32(68, 1000 + cascade * 7919)
	pc.encode_s32(72, 31337 + cascade * 104729)
	# Shader flag bits (replaces the old backend enum): bit 0 selects the
	# tutorial Gerstner path in map_assemble/foam_feedback, bit 1 selects the
	# JONSWAP spectrum flavour.
	var shader_flags := 0
	if wave_model == WaveModel.TUTORIAL_GERSTNER:
		shader_flags |= 1
	if backend == Backend.JONSWAP_TMA:
		shader_flags |= 2
	pc.encode_s32(76, shader_flags)
	pc.encode_float(80, height_gain)
	pc.encode_float(84, long_wave_height_m)
	pc.encode_float(88, long_wave_length_m)
	pc.encode_float(92, wind_wave_height_m)
	pc.encode_float(96, wind_wave_length_m)
	pc.encode_float(100, ripple_strength)
	pc.encode_float(104, crosswind_ratio)
	pc.encode_float(108, crest_gain)
	pc.encode_float(112, crest_bias)
	pc.encode_float(116, mid_wave_height_m)
	pc.encode_float(120, mid_wave_length_m)
	pc.encode_float(124, mid_wave_spread)
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
