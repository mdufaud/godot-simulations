class_name OceanVelocitySolver
extends RefCounted

const SHADER_DIR := "res://shaders/ocean/"
const VELOCITY_SIZE := 256
const GRAVITY := 9.81
const NUM_SPECTRA := 2
const STAGES: Array[String] = ["velocity_pack", "velocity_fft", "velocity_transpose", "velocity_assemble"]

var depth_m := 80.0
var _rd: RenderingDevice
var _spectrum_rid := RID()
var _velocity_rid := RID()
var _map_size := 0
var _tile_lengths := PackedFloat32Array()
var _current_velocity_m_s := Vector2.ZERO
var _buffers: Dictionary = {}
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _uniform_sets: Dictionary = {}
var _initialized := false


func init_render(spectrum_rid: RID, map_n: int, tiles: PackedFloat32Array,
		depth: float) -> bool:
	free_render()
	if not spectrum_rid.is_valid() or map_n < VELOCITY_SIZE \
			or tiles.size() != 3 or depth <= 0.0:
		push_error("OceanVelocitySolver requires a valid spectrum, map >= 256, three tiles, and positive depth")
		return false
	_rd = GpuPreflight.device("OceanVelocitySolver")
	if _rd == null:
		return false
	_spectrum_rid = spectrum_rid
	_map_size = map_n
	_tile_lengths = tiles.duplicate()
	depth_m = depth
	if not _create_resources():
		free_render()
		return false
	_initialized = true
	return true


func step_render(time_s: float, current_velocity_m_s: Vector2) -> void:
	if not _initialized:
		return
	_current_velocity_m_s = current_velocity_m_s
	var groups_16 := VELOCITY_SIZE / 16
	var groups_32 := VELOCITY_SIZE / 32
	var cl := _rd.compute_list_begin()
	for cascade in 3:
		var pc := _pack_push_constant(cascade, time_s)
		_dispatch(cl, "velocity_pack", pc, groups_16, groups_16, 1)
		_dispatch(cl, "velocity_fft", pc, 1, VELOCITY_SIZE, NUM_SPECTRA)
		_dispatch(cl, "velocity_transpose", pc, groups_32, groups_32, NUM_SPECTRA)
		_dispatch(cl, "velocity_fft", pc, 1, VELOCITY_SIZE, NUM_SPECTRA)
		_dispatch(cl, "velocity_assemble", pc, groups_16, groups_16, 1)
	_rd.compute_list_end()


func set_water_depth(value_m: float) -> void:
	depth_m = maxf(value_m, 0.0)


func get_texture_rid() -> RID:
	return _velocity_rid


func get_current_velocity_m_s() -> Vector2:
	return _current_velocity_m_s


func estimate_vram_bytes() -> int:
	var pixels := VELOCITY_SIZE * VELOCITY_SIZE
	var butterfly_bytes := int(log(float(VELOCITY_SIZE)) / log(2.0)) * VELOCITY_SIZE * 16
	return pixels * 3 * 8 + pixels * NUM_SPECTRA * 2 * 8 + butterfly_bytes


func free_render() -> void:
	if _rd == null:
		return
	for uniform_set in _uniform_sets.values():
		if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
			_rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for rid in _buffers.values():
		if rid.is_valid():
			_rd.free_rid(rid)
	_buffers.clear()
	if _velocity_rid.is_valid():
		_rd.free_rid(_velocity_rid)
	_velocity_rid = RID()
	for rid in _pipelines.values():
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipelines.clear()
	for rid in _shaders.values():
		if rid.is_valid():
			_rd.free_rid(rid)
	_shaders.clear()
	_spectrum_rid = RID()
	_map_size = 0
	_tile_lengths.clear()
	_initialized = false
	_rd = null


static func shader_header() -> String:
	return "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n#define NUM_SPECTRA %du\n\n" % [
		VELOCITY_SIZE, VELOCITY_SIZE, NUM_SPECTRA,
	]


func _create_resources() -> bool:
	var defines := shader_header()
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_velocity_common.comp")
	var sources := {
		"velocity_pack": FileAccess.get_file_as_string(SHADER_DIR + "ocean_velocity_pack.comp"),
		"velocity_fft": FileAccess.get_file_as_string(SHADER_DIR + "ocean_fft.comp"),
		"velocity_transpose": FileAccess.get_file_as_string(SHADER_DIR + "ocean_transpose.comp"),
		"velocity_assemble": FileAccess.get_file_as_string(SHADER_DIR + "ocean_velocity_assemble.comp"),
		"velocity_butterfly": FileAccess.get_file_as_string(SHADER_DIR + "ocean_fft_butterfly.comp"),
	}
	for stage in sources:
		var spirv := ShaderCache.compile(_rd, "ocean_" + stage, defines + common + "\n" + sources[stage])
		if not spirv.compile_error_compute.is_empty():
			push_error("Ocean velocity stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return false
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])

	var fft_bytes := PackedByteArray()
	fft_bytes.resize(VELOCITY_SIZE * VELOCITY_SIZE * NUM_SPECTRA * 2 * 8)
	_buffers["fft_data"] = _rd.storage_buffer_create(fft_bytes.size(), fft_bytes)
	var butterfly_bytes := PackedByteArray()
	butterfly_bytes.resize(int(log(float(VELOCITY_SIZE)) / log(2.0)) * VELOCITY_SIZE * 16)
	_buffers["butterfly"] = _rd.storage_buffer_create(butterfly_bytes.size(), butterfly_bytes)
	_velocity_rid = _create_velocity_texture()
	_rd.texture_clear(_velocity_rid, Color(0, 0, 0, 0), 0, 1, 0, 3)

	for stage in sources:
		var uniforms: Array[RDUniform] = [
			_image_uniform(0, _spectrum_rid),
			_buffer_uniform(1, _buffers["butterfly"]),
			_buffer_uniform(2, _buffers["fft_data"]),
			_image_uniform(3, _velocity_rid),
		]
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	var pc := _pack_push_constant(0, 0.0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["velocity_butterfly"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets["velocity_butterfly"], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, VELOCITY_SIZE / 128, int(log(float(VELOCITY_SIZE)) / log(2.0)), 1)
	_rd.compute_list_end()
	return true


func _dispatch(cl: int, stage: String, pc: PackedByteArray,
		groups_x: int, groups_y: int, groups_z: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, groups_z)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(cascade: int, time_s: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_float(0, _tile_lengths[cascade])
	pc.encode_float(4, depth_m)
	pc.encode_float(8, time_s)
	pc.encode_float(12, _current_velocity_m_s.x)
	pc.encode_float(16, _current_velocity_m_s.y)
	pc.encode_s32(32, cascade)
	pc.encode_s32(36, _map_size)
	return pc


func _create_velocity_texture() -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.width = VELOCITY_SIZE
	format.height = VELOCITY_SIZE
	format.array_layers = 3
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])


func _image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
