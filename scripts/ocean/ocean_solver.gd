class_name OceanSolver
extends RefCounted
## Tessendorf FFT ocean on RenderingDevice compute. Per cascade and per frame:
## [spectrum_init if dirty] -> spectrum_evolve -> Stockham row IFFT ->
## transpose -> row IFFT -> map_assemble (displacement + normals + Jacobian
## foam). Everything stays on the GPU; the surface material samples the two
## output texture arrays through Texture2DArrayRD.

const SHADER_DIR := "res://shaders/ocean/"
const STAGES: Array[String] = [
	"spectrum_init", "spectrum_evolve", "fft_butterfly", "fft", "transpose", "map_assemble",
]
const NUM_SPECTRA := 4
const GRAVITY := 9.81
## Full choppiness on short waves folds the surface into black back-faces;
## damp it as the cascades get finer.
const CHOP_PER_CASCADE: PackedFloat32Array = [1.0, 0.8, 0.55]

var map_size := 256
## Pairwise non-commensurate (prime) lengths: integer ratios would tile with a
## visible super-period. Sorted large -> small; k-space bands are cut between
## them. Cascade 0 must hold the spectral peak: storm winds put lambda_p near
## 500 m, so the big tile has to exceed that or storms lose their swell.
var tile_lengths: PackedFloat32Array = PackedFloat32Array([1013.0, 127.0, 17.0])
var wind_speed := 11.0
var wind_direction := 0.0
var fetch_km := 120.0
var water_depth := 80.0
var swell := 0.8
var spread := 0.2
var detail := 1.0
var choppiness := 1.15
## Master wave height multiplier, applied k-weighted in spectrum_init (swell
## boost, e-fold at 60 m): short wavelets keep physical steepness even at 5x.
## Changing it requires mark_spectrum_dirty().
var height_gain := 1.0
var whitecap := 0.82
var foam_amount := 3.5
## Accumulated sim time, pushed by the controller every frame.
var sim_time := 0.0
## Update one cascade per frame round-robin instead of all of them.
var amortize := false

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _spectrum_tex := RID()
var _displacement_tex := RID()
var _normal_tex := RID()
var _cascade_dirty: Array[bool] = []
var _frame := 0
var _timings := {}
var _timings_mutex := Mutex.new()


func num_cascades() -> int:
	return tile_lengths.size()


func get_displacement_tex_rid() -> RID:
	return _displacement_tex


func get_normal_tex_rid() -> RID:
	return _normal_tex


## Sea-state params changed: regenerate the initial spectra (cheap, one 256²
## dispatch per cascade; phases stay stable thanks to the fixed seeds).
func mark_spectrum_dirty() -> void:
	for i in _cascade_dirty.size():
		_cascade_dirty[i] = true


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()

	var defines := "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n\n" % [
		map_size, map_size,
	]
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "ocean_" + stage + ".comp")
		var src := RDShaderSource.new()
		src.source_compute = defines + common + "\n" + stage_src
		var spirv := _rd.shader_compile_spirv_from_source(src)
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
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex]:
		_rd.texture_clear(tex, Color(0, 0, 0, 0), 0, 1, 0, cascades)

	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		uniforms.append(_image_uniform(0, _spectrum_tex))
		uniforms.append(_buffer_uniform(1, _buffers["butterfly"]))
		uniforms.append(_buffer_uniform(2, _buffers["fft_data"]))
		uniforms.append(_image_uniform(3, _displacement_tex))
		uniforms.append(_image_uniform(4, _normal_tex))
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	_cascade_dirty.resize(cascades)
	mark_spectrum_dirty()

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

	# Amortized cascades update every num_cascades() frames: scale the foam
	# rates so accumulation/decay equilibrium stays frame-rate independent.
	var eff_delta := delta * (float(num_cascades()) if amortize else 1.0)
	var grow_rate := eff_delta * foam_amount * 7.5
	var decay_rate := eff_delta * maxf(0.5, 10.0 - foam_amount) * 1.15

	var g16 := map_size / 16
	var g32 := map_size / 32
	var cascade_list: Array = range(num_cascades()) if not amortize \
		else [_frame % num_cascades()]

	_rd.capture_timestamp("ocean/start")
	var cl := _rd.compute_list_begin()
	for i in cascade_list:
		var pc := _pack_push_constant(i, grow_rate, decay_rate)
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
	_rd.compute_list_end()
	_rd.capture_timestamp("ocean/end")
	_frame += 1


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
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex]:
		if tex.is_valid():
			_rd.free_rid(tex)
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


func _dispatch(cl: int, stage: String, pc: PackedByteArray, gx: int, gy: int, gz: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, gz)
	_rd.compute_list_add_barrier(cl)


## k-space boundary between cascade i and i+1: the finer cascade takes over at
## 6 of its tile wavelengths, where it has ~9 texels per wavelength.
func _k_max(cascade: int) -> float:
	if cascade >= num_cascades() - 1:
		return 1e9
	return TAU / tile_lengths[cascade + 1] * 6.0


func _pack_push_constant(cascade: int, grow_rate: float, decay_rate: float) -> PackedByteArray:
	var fetch_m := fetch_km * 1000.0
	var alpha := 0.076 * pow(wind_speed * wind_speed / (fetch_m * GRAVITY), 0.22)
	var omega_p := 22.0 * pow(GRAVITY * GRAVITY / (wind_speed * fetch_m), 1.0 / 3.0)
	var k_min := 0.0001 if cascade == 0 else _k_max(cascade - 1)
	var eff_chop := choppiness * CHOP_PER_CASCADE[cascade]

	var pc := PackedByteArray()
	pc.resize(96)
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
	pc.encode_float(52, grow_rate)
	pc.encode_float(56, decay_rate)
	pc.encode_float(60, sim_time)
	pc.encode_s32(64, cascade)
	pc.encode_s32(68, 1000 + cascade * 7919)
	pc.encode_s32(72, 31337 + cascade * 104729)
	pc.encode_s32(76, 0)
	pc.encode_float(80, height_gain)
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
	var out := {}
	var prev_time := 0
	var start_time := 0
	var in_chain := false
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if not nm.begins_with("ocean/"):
			continue
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if nm == "ocean/start":
			start_time = t
			prev_time = t
			in_chain = true
			continue
		if not in_chain:
			continue
		var seg := nm.trim_prefix("ocean/")
		if seg == "end":
			out["total"] = float(t - start_time) / 1e6
			in_chain = false
		else:
			out[seg] = out.get(seg, 0.0) + float(t - prev_time) / 1e6
		prev_time = t
	if out.is_empty():
		return
	_timings_mutex.lock()
	_timings = out
	_timings_mutex.unlock()


# Main thread. GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	_timings_mutex.lock()
	var copy := _timings.duplicate()
	_timings_mutex.unlock()
	return copy
