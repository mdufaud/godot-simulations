class_name OceanLocalSolver
extends RefCounted

const SHADER_DIR := "res://shaders/ocean/"
const FIXED_DT := 1.0 / 30.0
const MAX_SUBSTEPS_PER_RENDER := 8
const MAX_IMPULSES := 8
const NUM_SPECTRA := 4
const COAST_DOMAIN_M := 256.0
const WAKE_DOMAIN_M := 64.0
const COAST_CENTER := Vector2(0.0, 20.0)
const MIN_WAKE_WAVELENGTH_M := 2.0
const MIN_COAST_WAVELENGTH_M := 32.0
const VELOCITY_MAP_N := OceanVelocitySolver.VELOCITY_SIZE
const STAGES := ["butterfly", "pack", "fft", "transpose", "spectral", "assemble", "output"]

var _rd: RenderingDevice
var _displacement_rid := RID()
var _velocity_rid := RID()
var _map_n := 0
var _tiles := PackedFloat32Array()
var _offshore_depth_m := 80.0
var _domains: Dictionary = {}
var _force_buffer := RID()
var _pressure_buffer := RID()
var _pending_impulses := PackedVector4Array()
var _pressure_forces := PackedVector4Array()
var _accumulator_s := 0.0
var _simulation_time_s := 0.0
var _previous_time_s := 0.0
var _clock_started := false
var _wake_center_xz := Vector2.ZERO
var _current_m_s := Vector2.ZERO
var _initialized := false
var _reset_pending := false


func init_render(displacements: RID, velocity: RID, map_n: int,
		tiles: PackedFloat32Array, coast_n: int, wake_n: int,
		depth_m: float) -> bool:
	free_render()
	if not displacements.is_valid() or not velocity.is_valid() \
			or map_n < 32 or tiles.size() != 3 or depth_m <= 0.0 \
			or not _valid_grid_size(coast_n, [64, 128, 256]) \
			or not _valid_grid_size(wake_n, [128, 256]):
		push_error("OceanLocalSolver requires valid source maps and supported coast/wake grids")
		return false
	_rd = GpuPreflight.device("OceanLocalSolver")
	if _rd == null:
		return false
	_displacement_rid = displacements
	_velocity_rid = velocity
	_map_n = map_n
	_tiles = tiles.duplicate()
	_offshore_depth_m = maxf(depth_m, 2.0)
	_force_buffer = _rd.storage_buffer_create(MAX_IMPULSES * 16)
	_pressure_buffer = _rd.storage_buffer_create(MAX_IMPULSES * 16)
	_domains["coast"] = _create_domain(coast_n, COAST_DOMAIN_M)
	if _domains.coast.is_empty():
		free_render()
		return false
	_domains["wake"] = _create_domain(wake_n, WAKE_DOMAIN_M)
	if _domains.wake.is_empty():
		free_render()
		return false
	_initialized = true
	return true


func step_render(delta_s: float, time_s: float, center_xz: Vector2,
		current_m_s: Vector2, wake_impulses: PackedVector4Array,
		pressure_forces: PackedVector4Array = PackedVector4Array()) -> void:
	if not _initialized:
		return
	if _reset_pending:
		_reset_domain_states()
	_current_m_s = current_m_s
	_wake_center_xz = center_xz
	_pressure_forces.clear()
	for force in pressure_forces:
		if _pressure_forces.size() >= MAX_IMPULSES:
			break
		if not is_finite(force.x) or not is_finite(force.y) \
				or not is_finite(force.z) or not is_finite(force.w) \
				or force.z <= 0.0:
			continue
		_pressure_forces.append(Vector4(force.x, force.y, force.z, maxf(force.w, 0.6)))
	_upload_pressure_forces()
	for impulse in wake_impulses:
		if not is_finite(impulse.x) or not is_finite(impulse.y) \
				or not is_finite(impulse.z) or not is_finite(impulse.w):
			continue
		_accumulate_impulse(impulse)
	if not _clock_started:
		_simulation_time_s = time_s - maxf(delta_s, 0.0)
		_previous_time_s = _simulation_time_s
		_clock_started = true
	_accumulator_s += maxf(delta_s, 0.0)
	var substeps := 0
	var impulse_count := mini(_pending_impulses.size(), MAX_IMPULSES)
	if impulse_count > 0 and _accumulator_s >= FIXED_DT:
		_upload_impulses()
	while _accumulator_s >= FIXED_DT and substeps < MAX_SUBSTEPS_PER_RENDER:
		var first_substep := substeps == 0
		_simulation_time_s += FIXED_DT
		_previous_time_s = _simulation_time_s - FIXED_DT
		var coast: Dictionary = _domains.coast
		var wake: Dictionary = _domains.wake
		_advance_domain(coast, COAST_CENTER, 0)
		_advance_domain(wake, _wake_center_xz, impulse_count if first_substep else 0)
		if first_substep:
			_pending_impulses.clear()
		_accumulator_s -= FIXED_DT
		substeps += 1
	var alpha := clampf(_accumulator_s / FIXED_DT, 0.0, 1.0)
	_publish_domain(_domains.coast, COAST_CENTER, alpha)
	_publish_domain(_domains.wake, _wake_center_xz, alpha)


func get_coast_texture_rid() -> RID:
	return _domains.coast.output if _domains.has("coast") else RID()


func get_wake_texture_rid() -> RID:
	return _domains.wake.output if _domains.has("wake") else RID()


func coast_center() -> Vector2:
	return COAST_CENTER


func wake_center() -> Vector2:
	return _wake_center_xz


func state() -> Dictionary:
	return {
		"initialized": _initialized,
		"coast_center": COAST_CENTER,
		"wake_center": _wake_center_xz,
		"previous_time_s": _previous_time_s,
		"current_time_s": _simulation_time_s,
		"interpolation_alpha": clampf(_accumulator_s / FIXED_DT, 0.0, 1.0),
	}


func request_reset() -> void:
	_reset_pending = true


func set_water_depth(depth_m: float) -> void:
	var next_depth := maxf(depth_m, 2.0)
	if absf(next_depth - _offshore_depth_m) <= 0.001:
		return
	_offshore_depth_m = next_depth
	if _initialized:
		request_reset()


func get_water_depth() -> float:
	return _offshore_depth_m


static func shader_header(size: int) -> String:
	return "#version 450\n#define LOCAL_N %du\n#define LOCAL_N_I %d\n#define LOCAL_SPECTRA %du\n#define MAX_IMPULSES %du\n#define WATER_DENSITY %.6f\n\n" % [
		size, size, NUM_SPECTRA, MAX_IMPULSES, OceanSolver.WATER_DENSITY_KG_M3]


static func domain_defines() -> String:
	return "#define LOCAL_COAST_DOMAIN_M %.6f\n#define LOCAL_WAKE_DOMAIN_M %.6f\n" % [
		COAST_DOMAIN_M, WAKE_DOMAIN_M]


func estimate_vram_bytes() -> int:
	var total := 0
	for domain in _domains.values():
		if domain.is_empty():
			continue
		var n: int = domain.size
		var pixels := n * n
		var state_bytes := pixels * 5 * 3 * 16
		var output_bytes := pixels * 8
		var fft_bytes := pixels * 5 * 2 * NUM_SPECTRA * 8
		var butterfly_bytes := int(log(float(n)) / log(2.0)) * n * 16
		total += state_bytes + output_bytes + fft_bytes + butterfly_bytes
	return total + (MAX_IMPULSES * 16 if _force_buffer.is_valid() else 0) \
		+ (MAX_IMPULSES * 16 if _pressure_buffer.is_valid() else 0)


func free_render() -> void:
	_initialized = false
	if _rd != null:
		for domain in _domains.values():
			_free_domain(domain)
		if _force_buffer.is_valid():
			_rd.free_rid(_force_buffer)
		if _pressure_buffer.is_valid():
			_rd.free_rid(_pressure_buffer)
	_domains.clear()
	_force_buffer = RID()
	_pressure_buffer = RID()
	_displacement_rid = RID()
	_velocity_rid = RID()
	_map_n = 0
	_tiles.clear()
	_pending_impulses.clear()
	_pressure_forces.clear()
	_accumulator_s = 0.0
	_simulation_time_s = 0.0
	_previous_time_s = 0.0
	_clock_started = false
	_reset_pending = false
	_rd = null


func _reset_domain_states() -> void:
	_reset_pending = false
	_accumulator_s = 0.0
	_simulation_time_s = 0.0
	_previous_time_s = 0.0
	_clock_started = false
	_pending_impulses.clear()
	for domain_name in ["coast", "wake"]:
		var domain: Dictionary = _domains[domain_name]
		for texture in domain.states:
			_rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 5)
		_rd.texture_clear(domain.output, Color(0, 0, 0, 0), 0, 1, 0, 1)
		domain.previous_index = 0
		domain.current_index = 1
		domain.next_index = 2
		var center: Vector2 = COAST_CENTER if domain_name == "coast" else _wake_center_xz
		domain.previous_center = center
		domain.state_center = center
		domain.initialized = false


func _accumulate_impulse(impulse: Vector4) -> void:
	for i in _pending_impulses.size():
		var pending := _pending_impulses[i]
		if Vector2(pending.x, pending.y).distance_to(Vector2(impulse.x, impulse.y)) <= 1.0:
			_pending_impulses[i] = _merge_impulses(pending, impulse)
			return
	if _pending_impulses.size() < MAX_IMPULSES:
		_pending_impulses.append(impulse)
		return
	var nearest_index := 0
	var nearest_distance := INF
	for i in _pending_impulses.size():
		var pending := _pending_impulses[i]
		var distance := Vector2(pending.x, pending.y).distance_squared_to(
			Vector2(impulse.x, impulse.y))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = i
	_pending_impulses[nearest_index] = _merge_impulses(
		_pending_impulses[nearest_index], impulse)


func _merge_impulses(a: Vector4, b: Vector4) -> Vector4:
	var a_weight := Vector2(a.z, a.w).length()
	var b_weight := Vector2(b.z, b.w).length()
	var total_weight := a_weight + b_weight
	var position := (Vector2(a.x, a.y) * a_weight + Vector2(b.x, b.y) * b_weight) \
		/ total_weight if total_weight > 1.0e-8 else (Vector2(a.x, a.y) + Vector2(b.x, b.y)) * 0.5
	return Vector4(position.x, position.y, a.z + b.z, a.w + b.w)


func _create_domain(size: int, domain_length_m: float) -> Dictionary:
	var domain := {
		"size": size,
		"length": domain_length_m,
		"shaders": {},
		"pipelines": {},
		"uniform_sets": {},
		"buffers": {},
		"states": [],
		"output": RID(),
		"previous_index": 0,
		"current_index": 1,
		"next_index": 2,
		"previous_center": COAST_CENTER if domain_length_m == COAST_DOMAIN_M else Vector2.ZERO,
		"state_center": COAST_CENTER if domain_length_m == COAST_DOMAIN_M else Vector2.ZERO,
		"initialized": false,
	}
	var defines := shader_header(size)
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_local_common.comp")
	for stage in STAGES:
		var source := FileAccess.get_file_as_string(SHADER_DIR + "ocean_local_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "ocean_local_%s_%d" % [stage, size],
			defines + common + "\n" + source)
		if not spirv.compile_error_compute.is_empty():
			push_error("Ocean local stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			_free_domain(domain)
			return {}
		domain.shaders[stage] = _rd.shader_create_from_spirv(spirv)
		domain.pipelines[stage] = _rd.compute_pipeline_create(domain.shaders[stage])
	var log2n := int(log(float(size)) / log(2.0) + 0.5)
	domain.buffers.butterfly = _rd.storage_buffer_create(log2n * size * 16)
	domain.buffers.fft = _rd.storage_buffer_create(size * size * 5 * 2 * NUM_SPECTRA * 8)
	for _index in 3:
		domain.states.append(_create_state_texture(size))
	domain.output = _create_output_texture(size)
	for state_texture in domain.states:
		_rd.texture_clear(state_texture, Color(0, 0, 0, 0), 0, 1, 0, 5)
	_rd.texture_clear(domain.output, Color(0, 0, 0, 0), 0, 1, 0, 1)
	for source_index in 3:
		for target_index in 3:
			if source_index == target_index:
				continue
			var sets: Dictionary = {}
			for stage in STAGES:
				sets[stage] = _create_uniform_set(domain, stage,
					domain.states[source_index], domain.states[target_index])
			domain.uniform_sets["%d_%d" % [source_index, target_index]] = sets
	var butterfly_pc := _pack_params(domain, COAST_CENTER, COAST_CENTER,
		0.0, 0.0, Vector2.ZERO, 0, 0, 0, 0, MIN_COAST_WAVELENGTH_M)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, domain, "butterfly", "0_1", butterfly_pc,
			maxi(size / 128, 1), log2n, 1)
	_rd.compute_list_end()
	return domain


func _free_domain(domain: Dictionary) -> void:
	if domain.is_empty():
		return
	for stage_sets in domain.uniform_sets.values():
		for uniform_set in stage_sets.values():
			if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
				_rd.free_rid(uniform_set)
	for pipeline in domain.pipelines.values():
		if pipeline.is_valid():
			_rd.free_rid(pipeline)
	for shader in domain.shaders.values():
		if shader.is_valid():
			_rd.free_rid(shader)
	for buffer in domain.buffers.values():
		if buffer.is_valid():
			_rd.free_rid(buffer)
	for texture in domain.states:
		if texture.is_valid():
			_rd.free_rid(texture)
	if domain.output.is_valid():
		_rd.free_rid(domain.output)


func _create_uniform_set(domain: Dictionary, stage: String,
		source_state: RID, target_state: RID) -> RID:
	var uniforms: Array[RDUniform] = [
		_image_uniform(0, _displacement_rid),
		_image_uniform(1, _velocity_rid),
		_image_uniform(2, source_state),
		_image_uniform(3, target_state),
		_image_uniform(4, domain.output),
		_buffer_uniform(5, domain.buffers.butterfly),
		_buffer_uniform(6, domain.buffers.fft),
		_buffer_uniform(7, _force_buffer),
		_image_uniform(8, source_state),
		_image_uniform(9, target_state),
		_buffer_uniform(10, _pressure_buffer),
	]
	return _rd.uniform_set_create(uniforms, domain.shaders[stage], 0)


func _advance_domain(domain: Dictionary, next_center: Vector2,
		impulse_count: int) -> void:
	var source_index: int = domain.current_index
	var target_index: int = domain.next_index
	var source_center: Vector2 = domain.state_center
	var previous_center: Vector2 = domain.previous_center
	var init_state: bool = not domain.initialized
	var bank_group: int = int(domain.size) / 16
	var fft_pc: PackedByteArray
	var cl := _rd.compute_list_begin()
	for bank in 5:
		var pc := _pack_params(domain, next_center, source_center,
			_simulation_time_s, FIXED_DT, _current_m_s, bank,
			impulse_count, 1, 1 if init_state else 0,
			MIN_COAST_WAVELENGTH_M if domain.length == COAST_DOMAIN_M
			else MIN_WAKE_WAVELENGTH_M)
		_dispatch(cl, domain, "pack", "%d_%d" % [source_index, target_index],
			pc, bank_group, bank_group, 1)
		fft_pc = _pack_params(domain, next_center, source_center,
			_simulation_time_s, FIXED_DT, _current_m_s, bank,
			impulse_count, 1, 1 if init_state else 0,
			MIN_COAST_WAVELENGTH_M if domain.length == COAST_DOMAIN_M
			else MIN_WAKE_WAVELENGTH_M)
		_dispatch(cl, domain, "fft", "%d_%d" % [source_index, target_index],
			fft_pc, 1, domain.size, NUM_SPECTRA)
		_dispatch(cl, domain, "transpose", "%d_%d" % [source_index, target_index],
			fft_pc, domain.size / 32, domain.size / 32, NUM_SPECTRA)
		_dispatch(cl, domain, "fft", "%d_%d" % [source_index, target_index],
			fft_pc, 1, domain.size, NUM_SPECTRA)
		_dispatch(cl, domain, "spectral", "%d_%d" % [source_index, target_index],
			pc, bank_group, bank_group, 1)
		fft_pc = _pack_params(domain, next_center, source_center,
			_simulation_time_s, FIXED_DT, _current_m_s, bank,
			impulse_count, 0, 1 if init_state else 0,
			MIN_COAST_WAVELENGTH_M if domain.length == COAST_DOMAIN_M
			else MIN_WAKE_WAVELENGTH_M)
		_dispatch(cl, domain, "fft", "%d_%d" % [source_index, target_index],
			fft_pc, 1, domain.size, NUM_SPECTRA)
		_dispatch(cl, domain, "transpose", "%d_%d" % [source_index, target_index],
			fft_pc, domain.size / 32, domain.size / 32, NUM_SPECTRA)
		_dispatch(cl, domain, "fft", "%d_%d" % [source_index, target_index],
			fft_pc, 1, domain.size, NUM_SPECTRA)
		_dispatch(cl, domain, "assemble", "%d_%d" % [source_index, target_index],
			pc, bank_group, bank_group, 1)
	_rd.compute_list_end()
	domain.previous_index = source_index
	domain.current_index = target_index
	domain.next_index = domain.previous_index if domain.previous_index != source_index \
		else 3 - source_index - target_index
	var old_center: Vector2 = domain.state_center
	domain.previous_center = old_center
	domain.state_center = next_center
	domain.initialized = true


func _publish_domain(domain: Dictionary, render_center: Vector2, alpha: float) -> void:
	var previous_index: int = domain.previous_index
	var current_index: int = domain.current_index
	var set_key := "%d_%d" % [previous_index, current_index]
	var params := _pack_params(domain, domain.state_center,
		domain.previous_center, _simulation_time_s, alpha,
		_current_m_s, 0, 0, 0, 0,
		MIN_COAST_WAVELENGTH_M if domain.length == COAST_DOMAIN_M
		else MIN_WAKE_WAVELENGTH_M)
	var render_offset := 80
	params.encode_float(render_offset, render_center.x)
	params.encode_float(render_offset + 4, render_center.y)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, domain, "output", set_key, params,
		domain.size / 16, domain.size / 16, 1)
	_rd.compute_list_end()


func _pack_params(domain: Dictionary, center: Vector2, previous_center: Vector2,
		time_s: float, dt_s: float, current: Vector2, bank: int,
		force_count: int, fft_forward: int, initialize: int,
		minimum_wavelength_m: float) -> PackedByteArray:
	var params := PackedByteArray()
	params.resize(112)
	params.encode_float(0, domain.length)
	params.encode_float(4, float(domain.size))
	params.encode_float(8, float(_map_n))
	params.encode_float(12, float(VELOCITY_MAP_N))
	params.encode_float(16, center.x)
	params.encode_float(20, center.y)
	params.encode_float(24, previous_center.x)
	params.encode_float(28, previous_center.y)
	params.encode_float(32, time_s)
	params.encode_float(36, dt_s)
	params.encode_float(40, current.x)
	params.encode_float(44, current.y)
	params.encode_float(48, _tiles[0])
	params.encode_float(52, _tiles[1])
	params.encode_float(56, _tiles[2])
	params.encode_float(60, minimum_wavelength_m)
	params.encode_float(64, _offshore_depth_m)
	params.encode_float(68, 24.0)
	params.encode_float(72, 2.0)
	params.encode_float(76, 2.0)
	params.encode_float(80, center.x)
	params.encode_float(84, center.y)
	params.encode_float(88, float(_pressure_forces.size()))
	params.encode_s32(96, bank)
	params.encode_s32(100, force_count)
	params.encode_s32(104, fft_forward)
	params.encode_s32(108, initialize)
	return params


func _upload_impulses() -> void:
	var bytes := PackedByteArray()
	bytes.resize(MAX_IMPULSES * 16)
	for i in mini(_pending_impulses.size(), MAX_IMPULSES):
		var impulse := _pending_impulses[i]
		bytes.encode_float(i * 16, impulse.x)
		bytes.encode_float(i * 16 + 4, impulse.y)
		bytes.encode_float(i * 16 + 8, impulse.z)
		bytes.encode_float(i * 16 + 12, impulse.w)
	_rd.buffer_update(_force_buffer, 0, bytes.size(), bytes)


func _upload_pressure_forces() -> void:
	var bytes := PackedByteArray()
	bytes.resize(MAX_IMPULSES * 16)
	for i in _pressure_forces.size():
		var force := _pressure_forces[i]
		bytes.encode_float(i * 16, force.x)
		bytes.encode_float(i * 16 + 4, force.y)
		bytes.encode_float(i * 16 + 8, force.z)
		bytes.encode_float(i * 16 + 12, force.w)
	_rd.buffer_update(_pressure_buffer, 0, bytes.size(), bytes)


func _dispatch(cl: int, domain: Dictionary, stage: String, set_key: String,
		params: PackedByteArray, groups_x: int, groups_y: int,
		groups_z: int) -> void:
	var uniform_set: RID = domain.uniform_sets[set_key][stage]
	_rd.compute_list_bind_compute_pipeline(cl, domain.pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, params, params.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, groups_z)
	_rd.compute_list_add_barrier(cl)


func _create_state_texture(size: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.width = size
	format.height = size
	format.array_layers = 5
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])


func _create_output_texture(size: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = size
	format.height = size
	format.array_layers = 1
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


func _valid_grid_size(size: int, choices: Array) -> bool:
	return choices.has(size) and size % 32 == 0
