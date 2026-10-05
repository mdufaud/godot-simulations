class_name OceanShoreSolver
extends RefCounted

const SHADER_DIR := "res://shaders/ocean/"
const DOMAIN_M := 160.0
const GRID_SIZES := [128, 256, 384, 384]
const MACRO_DT := 1.0 / 30.0
const MAX_SUBSTEPS_PER_RENDER := 24
const MIN_SUBSTEPS_PER_RENDER := 8
const MAX_FORCES := 32
const BOUNDARY_SIZE := 128
const OUTER_DEPTH_M := 4.0
const DRY_DEPTH_M := 0.002
const ABSORB_WIDTH_M := 12.0
const MIN_WAVELENGTH_M := 32.0
const GRAVITY := 9.81
const CONTROL_BYTES := 128
const STAGES := ["init", "schedule", "cfl", "reconstruct", "update", "output", "pack", "fft", "transpose", "assemble", "butterfly"]

var enabled := false
var source_depth_m := OUTER_DEPTH_M
var grid_size := 0
var _rd: RenderingDevice
var _spectrum_rid := RID()
var _surface_rid := RID()
var _foam_rid := RID()
var _derivative_rid := RID()
var _boundary_rid := RID()
var _source_n := 0
var _tiles := PackedFloat32Array()
var _bed := PackedFloat32Array()
var _buffers: Dictionary = {}
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _sets: Dictionary = {}
var _initialized := false
var _reset_pending := false
var _progress_mutex := Mutex.new()
var _progress_pending := false
var _progress_backlog_s := 0.0
var _progress_signal_m_s := 0.0
var _progress_generation := 0
var _progress_interval_s := 0.0


func init_render(spectrum: RID, map_n: int, tiles: PackedFloat32Array,
		tier: int, bed: PackedFloat32Array) -> bool:
	free_render()
	if not spectrum.is_valid() or map_n < BOUNDARY_SIZE or tiles.size() != 3 \
			or tier < 0 or tier >= GRID_SIZES.size():
		push_error("OceanShoreSolver requires a spectrum, three tiles, and a supported tier")
		return false
	grid_size = GRID_SIZES[tier]
	if bed.size() != grid_size * grid_size:
		push_error("OceanShoreSolver bathymetry does not match its grid")
		grid_size = 0
		return false
	for height in bed:
		if not is_finite(height):
			push_error("OceanShoreSolver bathymetry contains a non-finite height")
			grid_size = 0
			return false
	_rd = GpuPreflight.device("OceanShoreSolver")
	if _rd == null:
		return false
	_spectrum_rid = spectrum
	_source_n = map_n
	_tiles = tiles.duplicate()
	_bed = bed.duplicate()
	if not _create_resources():
		free_render()
		return false
	_initialized = true
	enabled = true
	_reset_render()
	return true


func step_render(delta_s: float, time_s: float, current_m_s: Vector2,
		foam_amount: float, foam_decay: float, impulses: PackedVector4Array,
		pressures: PackedVector4Array = PackedVector4Array()) -> void:
	if not _initialized or not enabled:
		return
	if _reset_pending:
		_reset_render()
	var events := _inside_forces(impulses, false)
	var supports := _inside_forces(pressures, true)
	if not events.is_empty():
		var bytes := events.to_byte_array()
		_rd.buffer_update(_buffers.events, 0, bytes.size(), bytes)
	if not supports.is_empty():
		var bytes := supports.to_byte_array()
		_rd.buffer_update(_buffers.pressures, 0, bytes.size(), bytes)
	var pc := _push_constants(maxf(delta_s, 0.0), time_s, current_m_s,
		maxf(foam_amount, 0.0), maxf(foam_decay, 0.0), events.size(), supports.size())
	var cl := _rd.compute_list_begin()
	pc.encode_s32(80, 0)
	_dispatch(cl, "schedule", pc, 1, 1, 1)
	_progress_mutex.lock()
	var pending_s := _progress_backlog_s
	var signal_m_s := _progress_signal_m_s
	_progress_mutex.unlock()
	var budget := clampi(int(ceil((maxf(delta_s, 0.0) + pending_s)
		* signal_m_s / (0.40 * DOMAIN_M / float(grid_size)))) + 2,
		MIN_SUBSTEPS_PER_RENDER, MAX_SUBSTEPS_PER_RENDER)
	for substep in budget:
		pc.encode_s32(80, 1)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		for cascade in 3:
			if _tiles[cascade] < MIN_WAVELENGTH_M \
					or (cascade > 0 and _tiles[cascade] / 6.0 < MIN_WAVELENGTH_M):
				continue
			pc.encode_s32(84, cascade)
			_dispatch_indirect(cl, "pack", pc, 80)
			_dispatch_indirect(cl, "fft", pc, 96)
			_dispatch_indirect(cl, "transpose", pc, 112)
			_dispatch_indirect(cl, "fft", pc, 96)
			_dispatch_indirect(cl, "assemble", pc, 80)
		_dispatch_indirect(cl, "cfl", pc, 64)
		pc.encode_s32(80, 2)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		pc.encode_s32(88, 0)
		_dispatch_indirect(cl, "reconstruct", pc, 64)
		_dispatch_indirect(cl, "update", pc, 64)
		pc.encode_s32(80, 4)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		pc.encode_s32(88, 1)
		_dispatch_indirect(cl, "reconstruct", pc, 64)
		_dispatch_indirect(cl, "update", pc, 64)
		pc.encode_s32(80, 3)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
	_dispatch(cl, "output", pc, grid_size / 8, grid_size / 8, 1)
	_rd.compute_list_end()
	_progress_interval_s += maxf(delta_s, 0.0)
	if _progress_interval_s >= 0.25:
		_read_progress_render()


func reset() -> void:
	_reset_pending = true


func request_reset() -> void:
	reset()


func set_bathymetry(bed: PackedFloat32Array) -> void:
	if bed.size() != grid_size * grid_size:
		return
	for height in bed:
		if not is_finite(height):
			return
	_bed = bed.duplicate()
	if _initialized:
		var bytes := _bed.to_byte_array()
		_rd.buffer_update(_buffers.bed, 0, bytes.size(), bytes)
		_reset_pending = true


func get_texture_rid() -> RID:
	return _surface_rid


func get_foam_texture_rid() -> RID:
	return _foam_rid


func get_derivative_texture_rid() -> RID:
	return _derivative_rid


func estimate_vram_bytes() -> int:
	if not _initialized:
		return 0
	var pixels := grid_size * grid_size
	var boundary_pixels := BOUNDARY_SIZE * BOUNDARY_SIZE
	return pixels * (128 + 48 + 4 + 16 + 64) + boundary_pixels * (48 + 32) \
		+ BOUNDARY_SIZE * 7 * 16 + CONTROL_BYTES + MAX_FORCES * 48


func free_render() -> void:
	enabled = false
	_initialized = false
	if _rd != null:
		for uniform_set: RID in _sets.values():
			if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
				_rd.free_rid(uniform_set)
		for buffer: RID in _buffers.values():
			if buffer.is_valid():
				_rd.free_rid(buffer)
		for texture: RID in [_surface_rid, _foam_rid, _derivative_rid, _boundary_rid]:
			if texture.is_valid():
				_rd.free_rid(texture)
		for pipeline: RID in _pipelines.values():
			if pipeline.is_valid():
				_rd.free_rid(pipeline)
		for shader: RID in _shaders.values():
			if shader.is_valid():
				_rd.free_rid(shader)
	_sets.clear()
	_buffers.clear()
	_pipelines.clear()
	_shaders.clear()
	_surface_rid = RID()
	_foam_rid = RID()
	_derivative_rid = RID()
	_boundary_rid = RID()
	_spectrum_rid = RID()
	_source_n = 0
	grid_size = 0
	_tiles.clear()
	_bed.clear()
	_reset_pending = false
	_progress_mutex.lock()
	_progress_generation += 1
	_progress_pending = false
	_progress_backlog_s = 0.0
	_progress_signal_m_s = 0.0
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd = null


func _create_resources() -> bool:
	var defines := "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n" % [BOUNDARY_SIZE, BOUNDARY_SIZE]
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_shore_common.comp")
	for stage: String in STAGES:
		var file := "ocean_shore_" + stage + ".comp"
		if stage in ["fft", "transpose", "butterfly"]:
			file = "ocean_" + ("fft_butterfly" if stage == "butterfly" else stage) + ".comp"
		var source := FileAccess.get_file_as_string(SHADER_DIR + file)
		var spirv := ShaderCache.compile(_rd, "ocean_shore_" + stage, defines + common + "\n" + source)
		if not spirv.compile_error_compute.is_empty():
			push_error("Ocean shore stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return false
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])
	var pixels := grid_size * grid_size
	_buffers.bed = _rd.storage_buffer_create(pixels * 4, _bed.to_byte_array())
	_buffers.balance = _rd.storage_buffer_create(pixels * 16)
	_buffers.slopes = _rd.storage_buffer_create(pixels * 64)
	for name: String in ["state", "foam", "completed_state", "completed_foam"]:
		_buffers[name] = _rd.storage_buffer_create(pixels * 32)
	_buffers.control = _rd.storage_buffer_create(CONTROL_BYTES, PackedByteArray(),
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_buffers.fft = _rd.storage_buffer_create(BOUNDARY_SIZE * BOUNDARY_SIZE * 32)
	_buffers.butterfly = _rd.storage_buffer_create(7 * BOUNDARY_SIZE * 16)
	_buffers.events = _rd.storage_buffer_create(MAX_FORCES * 32)
	_buffers.pressures = _rd.storage_buffer_create(MAX_FORCES * 16)
	_surface_rid = _texture(grid_size, 1)
	_foam_rid = _texture(grid_size, 1)
	_derivative_rid = _texture(grid_size, 1)
	_boundary_rid = _texture(BOUNDARY_SIZE, 3)
	_rd.texture_clear(_boundary_rid, Color(0, 0, 0, 0), 0, 1, 0, 3)
	for stage: String in STAGES:
		var uniforms: Array[RDUniform] = [
			_uniform(0, _spectrum_rid, true), _uniform(1, _buffers.bed),
			_uniform(2, _buffers.state), _uniform(3, _buffers.foam),
			_uniform(4, _buffers.completed_state), _uniform(5, _buffers.completed_foam),
			_uniform(6, _buffers.control), _uniform(7, _buffers.fft),
			_uniform(8, _buffers.butterfly), _uniform(9, _boundary_rid, true),
			_uniform(10, _surface_rid, true), _uniform(11, _foam_rid, true),
			_uniform(12, _buffers.events), _uniform(13, _buffers.pressures),
			_uniform(14, _derivative_rid, true),
			_uniform(15, _buffers.balance),
			_uniform(16, _buffers.slopes),
		]
		_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)
	var pc := _push_constants(0.0, 0.0, Vector2.ZERO, 0.0, 0.0, 0, 0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "butterfly", pc, BOUNDARY_SIZE / 128, 7, 1)
	_rd.compute_list_end()
	return true


func _reset_render() -> void:
	_reset_pending = false
	_progress_mutex.lock()
	_progress_generation += 1
	_progress_pending = false
	_progress_backlog_s = 0.0
	_progress_signal_m_s = 4.0 * sqrt(GRAVITY * OUTER_DEPTH_M)
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd.buffer_clear(_buffers.control, 0, CONTROL_BYTES)
	var pc := _push_constants(0.0, 0.0, Vector2.ZERO, 0.0, 0.0, 0, 0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "init", pc, grid_size / 8, grid_size / 8, 1)
	_dispatch(cl, "output", pc, grid_size / 8, grid_size / 8, 1)
	_rd.compute_list_end()


func _read_progress_render() -> void:
	_progress_mutex.lock()
	if _progress_pending:
		_progress_mutex.unlock()
		return
	_progress_pending = true
	var generation := _progress_generation
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd.buffer_get_data_async(_buffers.control, _store_progress.bind(generation), 0, 64)


func _store_progress(data: PackedByteArray, generation: int) -> void:
	_progress_mutex.lock()
	if generation == _progress_generation:
		_progress_pending = false
		if data.size() == 64:
			_progress_backlog_s = data.decode_float(4) + data.decode_float(8)
			_progress_signal_m_s = data.decode_float(52)
	_progress_mutex.unlock()


func _inside_forces(forces: PackedVector4Array, pressure: bool) -> PackedVector4Array:
	var inside := PackedVector4Array()
	for force in forces:
		if not is_finite(force.x) or not is_finite(force.y) \
				or not is_finite(force.z) or not is_finite(force.w) \
				or absf(force.x) >= DOMAIN_M * 0.5 or absf(force.y) >= DOMAIN_M * 0.5:
			continue
		if pressure and force.z <= 0.0:
			continue
		inside.append(Vector4(force.x, force.y, force.z, maxf(force.w, 0.6)) if pressure else force)
		if inside.size() == MAX_FORCES:
			break
	return inside


func _push_constants(delta_s: float, time_s: float, current_m_s: Vector2,
		foam_amount: float, foam_decay: float, impulses: int, pressures: int) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(112)
	pc.encode_float(0, DOMAIN_M)
	pc.encode_float(4, DOMAIN_M / float(grid_size))
	pc.encode_float(8, GRAVITY)
	pc.encode_float(12, DRY_DEPTH_M)
	pc.encode_float(16, delta_s)
	pc.encode_float(20, time_s)
	pc.encode_float(24, foam_amount)
	pc.encode_float(28, foam_decay)
	for cascade in 3:
		pc.encode_float(32 + cascade * 4, _tiles[cascade])
	pc.encode_float(44, OUTER_DEPTH_M)
	pc.encode_float(48, current_m_s.x)
	pc.encode_float(52, current_m_s.y)
	pc.encode_float(56, MACRO_DT)
	pc.encode_float(60, MIN_WAVELENGTH_M)
	pc.encode_s32(64, grid_size)
	pc.encode_s32(68, _source_n)
	pc.encode_s32(72, impulses)
	pc.encode_s32(76, pressures)
	pc.encode_s32(92, MAX_FORCES)
	pc.encode_float(96, maxf(source_depth_m, 0.01))
	pc.encode_float(100, ABSORB_WIDTH_M)
	pc.encode_float(104, 20.0)
	pc.encode_float(108, 1000.0)
	return pc


func _dispatch(cl: int, stage: String, pc: PackedByteArray, x: int, y: int, z: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, x, y, z)
	_rd.compute_list_add_barrier(cl)


func _dispatch_indirect(cl: int, stage: String, pc: PackedByteArray, offset: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch_indirect(cl, _buffers.control, offset)
	_rd.compute_list_add_barrier(cl)


func _texture(size: int, layers: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if layers > 1 else RenderingDevice.TEXTURE_TYPE_2D
	format.width = size
	format.height = size
	format.array_layers = layers
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])


func _uniform(binding: int, rid: RID, image: bool = false) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if image else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform
