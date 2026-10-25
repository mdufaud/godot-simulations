extends RefCounted

const CELL_M := 0.125
const GRAVITY_M_S2 := 9.81
const MAX_STEP_S := 0.003
const MAX_SUBSTEPS := 64
const MAX_QUERIES := 32
# Bed slope across a face beyond which the flow leaves the height field (Chentanez & Mueller, US8878856).
const SPILL_SLOPE := 1.5
const SPILL_VOLUME_UNIT_M3 := 1.0e-9
const SPILL_EMISSION_HZ := 60.0
const SPILL_CAPACITY := 65536
const SPILL_TEXTURE_WIDTH := 256
const SPILL_FRICTION_HZ := 1.0
const SPILL_MAX_AGE_S := 8.0
const SPILL_ISSUANCE_JITTER := 0.02
const SPILL_STATE_BYTES := 80
const SPILL_PARTICLE_BYTES := 48
const SPILL_IMPACT_TILE_M := 1.0
const SPILL_IMPACT_WEIGHT_UNITS := 16.0
const SPILL_ROCK_HIT_M_S := 2.5
# A landing throws spray and foam in proportion to how far it fell, from nothing below x to fully past y.
const SPILL_SPRAY_DROP_M := Vector2(0.5, 1.5)
const SPILL_IMPACT_READ_S := 0.25

var region_m := Rect2()
## Radius the spill particles are drawn with: a fresh particle is drawn this much lower until it has dropped as far.
var spill_draw_radius_m := 0.0
## A spill particle emitted with fewer volume units than this reference is a thinner stream that breaks up sooner: its
## drawn drop is scaled by the reference over its units to this exponent. Set by the host that measures the discharge.
var spill_breakup_reference_units := 0.0
var spill_breakup_exponent := 0.0
## Water that slid down a face is broken up by the rock: it is drawn as if it had already fallen this far.
var spill_breakup_length_m := 0.0
var loading_stage := Callable()
var cell_m := CELL_M
var grid := Vector2i.ZERO
var _source_domain: Rect2
var _source_size := Vector2i.ZERO
var _render_origin := Vector2.ZERO
var _rd: RenderingDevice
var _states: Array[RID] = []
var _sets: Array[RID] = []
var _terrain := RID()
var _surface := RID()
var _foam := RID()
var _source := RID()
var _sampler := RID()
var _query_points := RID()
var _query_results := RID()
var _shader := RID()
var _pipeline := RID()
var _stamps := RiverObstacleStamp.new()
var _spill_shader := RID()
var _spill_pipeline := RID()
var _spill_sets: Array[RID] = []
var _spill_particles := RID()
var _spill_deposits := RID()
var _spill_outflow := RID()
var _spill_state := RID()
var _spill_out := RID()
var _spill_positions := RID()
var _spill_impacts := RID()
var _spill_phase_s := 0.0
var _impact_window_s := 0.0
var _impact_pending := false
var _spilling := false
var _index := 0
var _query_busy := false
var _query_serial := 0
var _query_reads_pending := 0
var _readback_generation := 0
var _query_batch: Dictionary = {}
var _mutex := Mutex.new()
var _status := {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}


func start(field: RiverField, config: RiverConfig) -> void:
	_spilling = field.spills
	_source_domain = field.domain_rect()
	var image := _solver_terrain(field)
	var parameters_bytes := parameters(config, 0.0)
	_report_stage("Compiling water solver (GPU)")
	RenderingServer.call_on_render_thread(_init_render.bind(image.get_data(), image.get_size(), parameters_bytes))


func move_source(field: RiverField) -> void:
	_source_domain = field.domain_rect()
	var image := _solver_terrain(field)
	RenderingServer.call_on_render_thread(_update_source_render.bind(image.get_data(), image.get_size()))


func _solver_terrain(field: RiverField) -> Image:
	if field.solver_terrain_image != null:
		return field.solver_terrain_image
	_report_stage("Sampling river terrain")
	var size := Vector2i(field.domain_m / CELL_M)
	var rows := []
	rows.resize(size.y)
	var origin := _source_domain.position
	var task := WorkerThreadPool.add_group_task(func(y: int) -> void:
		var row := PackedFloat32Array()
		row.resize(size.x * 4)
		for x in size.x:
			var point := origin + Vector2(x + 0.5, y + 0.5) * CELL_M
			var flow := field.sample_solver(point, 0.0)
			row[x * 4] = field.sample_bed(point)
			row[x * 4 + 1] = field.sample_height(point, 0.0)
			row[x * 4 + 2] = flow.r
			row[x * 4 + 3] = flow.g
		rows[y] = row, size.y)
	RiverField.wait_for_group(task, loading_stage)
	var values := PackedFloat32Array()
	for row: PackedFloat32Array in rows:
		values.append_array(row)
	for instance in field.obstacle_meshes:
		_stamps.stamp(values, 4, size, origin, CELL_M, instance)
	field.solver_terrain_image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, values.to_byte_array())
	return field.solver_terrain_image


func add_obstacles(field: RiverField, meshes: Array[MeshInstance3D], parameters_bytes: PackedByteArray) -> void:
	var image := field.solver_terrain_image
	if image == null:
		return
	var size := image.get_size()
	var values := image.get_data().to_float32_array()
	for instance in meshes:
		_stamps.stamp(values, 4, size, _source_domain.position, CELL_M, instance)
	field.solver_terrain_image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, values.to_byte_array())
	RenderingServer.call_on_render_thread(_add_obstacles_render.bind(field.solver_terrain_image.get_data(), size, parameters_bytes))


func _add_obstacles_render(terrain_bytes: PackedByteArray, source_size: Vector2i, parameters_bytes: PackedByteArray) -> void:
	if _rd == null or _sets.is_empty() or source_size != _source_size:
		return
	_rd.texture_update(_source, 0, terrain_bytes)
	var list := _rd.compute_list_begin()
	_dispatch_render(list, parameters_bytes, 8.0)
	_rd.compute_list_end()


func _update_source_render(terrain_bytes: PackedByteArray, source_size: Vector2i) -> void:
	if _rd == null or not _source.is_valid():
		return
	if source_size != _source_size:
		push_error("River solver source image changed size: %s -> %s" % [_source_size, source_size])
		return
	_rd.texture_update(_source, 0, terrain_bytes)


func _report_stage(label: String) -> void:
	if loading_stage.is_valid():
		loading_stage.call(label)


func parameters(config: RiverConfig, time_s: float) -> PackedByteArray:
	return PackedFloat32Array([
		region_m.position.x, region_m.position.y, cell_m, GRAVITY_M_S2,
		grid.x, grid.y, 0.0, config.speed_m_s,
		config.water_level_m, config.foam_amount, MAX_STEP_S, time_s,
		_source_domain.position.x, _source_domain.position.y, _source_domain.size.x, _source_domain.size.y,
		0.0, config.whitewater_strength, 0.0, 0.0,
		config.current_guidance_hz, config.level_guidance_hz, 0.0, 0.0,
	]).to_byte_array()


func snapshot() -> Dictionary:
	_mutex.lock()
	var result := _status.duplicate()
	_mutex.unlock()
	return result


func stop() -> void:
	var completed := Semaphore.new()
	RenderingServer.call_on_render_thread(func():
		_free_render()
		completed.post())
	completed.wait()


func _init_render(terrain_bytes: PackedByteArray, source_size: Vector2i, parameters_bytes: PackedByteArray) -> void:
	_free_render()
	_rd = GpuPreflight.device("RiverSWE")
	if _rd == null:
		return
	var spirv := ShaderCache.compile(_rd, "river_swe",
		FileAccess.get_file_as_string("res://shaders/river/river_swe.comp"))
	if not spirv.compile_error_compute.is_empty():
		push_error("River SWE compile error: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	_source = _texture_render(source_size, terrain_bytes)
	_source_size = source_size
	_render_origin = Vector2(parameters_bytes.decode_float(0), parameters_bytes.decode_float(4))
	var size := Vector2i(parameters_bytes.decode_float(16), parameters_bytes.decode_float(20))
	_terrain = _texture_render(size)
	_surface = _texture_render(size)
	_foam = _texture_render(size)
	_states.assign([_texture_render(size), _texture_render(size)])
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler)
	_query_points = _rd.storage_buffer_create(MAX_QUERIES * 16)
	_query_results = _rd.storage_buffer_create(MAX_QUERIES * 48)
	var spilling := _spilling
	var cells := size.x * size.y if spilling else 1
	_spill_particles = _rd.storage_buffer_create((SPILL_CAPACITY if spilling else 1) * SPILL_PARTICLE_BYTES)
	_spill_deposits = _rd.storage_buffer_create(cells * 16)
	_spill_outflow = _rd.storage_buffer_create(cells * 32)
	_spill_state = _rd.storage_buffer_create(SPILL_STATE_BYTES, _spill_header(SPILL_SLOPE if spilling else 0.0))
	_spill_out = _texture_render(size if spilling else Vector2i.ONE)
	_spill_phase_s = 0.0
	_impact_window_s = 0.0
	for index in 2:
		var uniforms: Array[RDUniform] = []
		for binding in 5:
			uniforms.append(_uniform(binding, [_states[index], _states[1 - index], _terrain, _surface, _foam][binding], RenderingDevice.UNIFORM_TYPE_IMAGE))
		var source_uniform := _uniform(5, _sampler, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE)
		source_uniform.add_id(_source)
		uniforms.append(source_uniform)
		uniforms.append(_uniform(6, _query_points, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(7, _query_results, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(8, _spill_deposits, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(9, _spill_outflow, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(10, _spill_state, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(11, _spill_out, RenderingDevice.UNIFORM_TYPE_IMAGE))
		_sets.append(_rd.uniform_set_create(uniforms, _shader, 0))
	if spilling:
		_init_spill_render(size)
	var list := _rd.compute_list_begin()
	_dispatch_render(list, parameters_bytes, 0.0)
	_rd.compute_list_end()
	_mutex.lock()
	_status = {"ready": true, "surface": _surface, "foam": _foam, "terrain": _terrain, "spill": _spill_out,
		"state": _states[0], "gpu_ms": 0.0, "time_s": 0.0}
	if spilling:
		_status["spill_positions"] = _spill_positions
	_mutex.unlock()


func _init_spill_render(size: Vector2i) -> void:
	var spirv := ShaderCache.compile(_rd, "river_spill", FileAccess.get_file_as_string("res://shaders/river/river_spill.comp"))
	if not spirv.compile_error_compute.is_empty():
		push_error("River spill compile error: " + spirv.compile_error_compute)
		return
	_spill_shader = _rd.shader_create_from_spirv(spirv)
	_spill_pipeline = _rd.compute_pipeline_create(_spill_shader)
	_spill_positions = _texture_render(Vector2i(SPILL_TEXTURE_WIDTH, SPILL_CAPACITY / SPILL_TEXTURE_WIDTH))
	_spill_impacts = _rd.storage_buffer_create(_impact_bytes(size))
	for index in 2:
		var uniforms: Array[RDUniform] = [
			_uniform(0, _terrain, RenderingDevice.UNIFORM_TYPE_IMAGE),
			_uniform(1, _states[index], RenderingDevice.UNIFORM_TYPE_IMAGE),
			_uniform(2, _spill_particles, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			_uniform(3, _spill_deposits, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			_uniform(4, _spill_outflow, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			_uniform(5, _spill_state, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
			_uniform(6, _spill_positions, RenderingDevice.UNIFORM_TYPE_IMAGE),
			_uniform(7, _spill_impacts, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
		]
		_spill_sets.append(_rd.uniform_set_create(uniforms, _spill_shader, 0))


static func impact_tiles(size: Vector2i, cell: float) -> Vector2i:
	return Vector2i((Vector2(size) * cell / SPILL_IMPACT_TILE_M).ceil())


func _impact_bytes(size: Vector2i) -> int:
	var tiles := impact_tiles(size, cell_m)
	return tiles.x * tiles.y * 32


func _grid_size() -> Vector2i:
	var format := _rd.texture_get_format(_terrain)
	return Vector2i(format.width, format.height)


func _spill_header(slope: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SPILL_STATE_BYTES)
	bytes.encode_float(48, slope)
	bytes.encode_float(52, SPILL_VOLUME_UNIT_M3)
	return bytes


func _reset_spill_render() -> void:
	if _spill_sets.is_empty():
		return
	var size := _grid_size()
	_rd.buffer_clear(_spill_particles, 0, SPILL_CAPACITY * SPILL_PARTICLE_BYTES)
	_rd.buffer_clear(_spill_deposits, 0, size.x * size.y * 16)
	_rd.buffer_clear(_spill_outflow, 0, size.x * size.y * 32)
	_rd.buffer_clear(_spill_impacts, 0, _impact_bytes(size))
	_rd.buffer_update(_spill_state, 0, SPILL_STATE_BYTES, _spill_header(SPILL_SLOPE))
	_spill_phase_s = 0.0
	_impact_window_s = 0.0


func _dispatch_spill(list: int, parameters_bytes: PackedByteArray, mode: float) -> void:
	var bytes := PackedFloat32Array([
		parameters_bytes.decode_float(0), parameters_bytes.decode_float(4), parameters_bytes.decode_float(8), GRAVITY_M_S2,
		parameters_bytes.decode_float(16), parameters_bytes.decode_float(20), parameters_bytes.decode_float(24), SPILL_CAPACITY,
		SPILL_FRICTION_HZ, SPILL_MAX_AGE_S, mode, SPILL_ISSUANCE_JITTER,
		SPILL_IMPACT_TILE_M, SPILL_ROCK_HIT_M_S, SPILL_IMPACT_WEIGHT_UNITS, spill_draw_radius_m,
		SPILL_SPRAY_DROP_M.x, SPILL_SPRAY_DROP_M.y, spill_breakup_reference_units, spill_breakup_exponent,
		spill_breakup_length_m, 0.0, 0.0, 0.0,
	]).to_byte_array()
	_rd.compute_list_bind_compute_pipeline(list, _spill_pipeline)
	_rd.compute_list_bind_uniform_set(list, _spill_sets[_index], 0)
	_rd.compute_list_set_push_constant(list, bytes, bytes.size())
	var count := int(parameters_bytes.decode_float(16) * parameters_bytes.decode_float(20)) if is_equal_approx(mode, 1.0) else SPILL_CAPACITY
	_rd.compute_list_dispatch(list, ceili(count / 64.0), 1, 1)


func _read_impacts_render() -> void:
	if _impact_pending:
		return
	_impact_pending = true
	var generation := _readback_generation
	var window := _impact_window_s
	_impact_window_s = 0.0
	var size := _impact_bytes(_grid_size())
	_rd.buffer_get_data_async(_spill_state, func(data: PackedByteArray):
		_mutex.lock()
		if generation == _readback_generation:
			_status["spill_words"] = data
		_mutex.unlock(), 0, SPILL_STATE_BYTES)
	_rd.buffer_get_data_async(_spill_impacts, func(data: PackedByteArray):
		_mutex.lock()
		if generation == _readback_generation:
			_impact_pending = false
			_status["spill_impacts"] = data.to_int32_array()
			_status["spill_impact_window_s"] = window
			_status["spill_impact_serial"] = int(_status.get("spill_impact_serial", 0)) + 1
		_mutex.unlock(), 0, size)
	_rd.buffer_clear(_spill_impacts, 0, size)


func _uniform(binding: int, rid: RID, type: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


func advance_render(delta_s: float, parameters_bytes: PackedByteArray, reset: bool, profiling: bool) -> void:
	if _sets.is_empty():
		return
	var cpu_start := Time.get_ticks_usec() if profiling else 0
	var timing := GpuTimings.read(_rd, "river_swe/") if profiling else {}
	if profiling:
		_rd.capture_timestamp("river_swe/start")
	var next_cell := parameters_bytes.decode_float(8)
	var origin := Vector2(parameters_bytes.decode_float(0), parameters_bytes.decode_float(4))
	var spilling := not _spill_sets.is_empty()
	if reset and spilling:
		_reset_spill_render()
	var list := _rd.compute_list_begin()
	if reset:
		_index = 0
		_dispatch_render(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
	elif origin != _render_origin:
		parameters_bytes.encode_float(72, _render_origin.x)
		parameters_bytes.encode_float(76, _render_origin.y)
		_dispatch_render(list, parameters_bytes, 7.0)
		_rd.compute_list_add_barrier(list)
		_index = 1 - _index
	_render_origin = origin
	var max_step := MAX_STEP_S * next_cell / CELL_M
	var duration := minf(delta_s, MAX_SUBSTEPS * max_step)
	var steps := ceili(duration / max_step)
	parameters_bytes.encode_float(24, duration / maxf(steps, 1.0))
	for substep in steps:
		if spilling:
			_dispatch_spill(list, parameters_bytes, 0.0)
			_rd.compute_list_add_barrier(list)
		_dispatch_render(list, parameters_bytes, 1.0)
		_rd.compute_list_add_barrier(list)
		_index = 1 - _index
		_spill_phase_s += duration / maxf(steps, 1.0)
		if spilling and _spill_phase_s >= 1.0 / SPILL_EMISSION_HZ:
			_spill_phase_s -= 1.0 / SPILL_EMISSION_HZ
			_dispatch_spill(list, parameters_bytes, 1.0)
			_rd.compute_list_add_barrier(list)
	# The output pass turns the spill landings counted since the last frame into a rate over this frame.
	parameters_bytes.encode_float(24, duration)
	_dispatch_render(list, parameters_bytes, 2.0)
	if spilling:
		_dispatch_spill(list, parameters_bytes, 2.0)
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("river_swe/end")
	if spilling:
		_impact_window_s += duration
		if _impact_window_s >= SPILL_IMPACT_READ_S:
			_read_impacts_render()
	_mutex.lock()
	_status["state"] = _states[_index]
	_status["gpu_ms"] = float(timing.get("total", 0.0))
	_status["cpu_ms"] = float(Time.get_ticks_usec() - cpu_start) / 1000.0 if profiling else 0.0
	_status["time_s"] = (0.0 if reset else float(_status["time_s"])) + duration
	if spilling:
		_status["spill_particles"] = _spill_particles
		_status["spill_state"] = _spill_state
		_status["spill_deposits"] = _spill_deposits
	_mutex.unlock()


func query_render(points: PackedVector2Array, parameters_bytes: PackedByteArray, generation: int = -1) -> void:
	if _sets.is_empty() or points.is_empty() or points.size() > MAX_QUERIES:
		return
	_mutex.lock()
	if _query_busy or (generation >= 0 and generation != _query_serial):
		_mutex.unlock()
		return
	_query_busy = true
	_query_reads_pending += 1
	var readback_generation := _readback_generation
	var serial := _query_serial
	_mutex.unlock()
	var bytes := PackedFloat32Array()
	for point in points:
		bytes.append_array(PackedFloat32Array([point.x, point.y, 0.0, 0.0]))
	_rd.buffer_update(_query_points, 0, bytes.size() * 4, bytes.to_byte_array())
	parameters_bytes.encode_float(72, points.size())
	parameters_bytes.encode_float(64, 4.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_end()
	_rd.buffer_get_data_async(_query_results, func(data: PackedByteArray):
		_mutex.lock()
		if readback_generation == _readback_generation:
			_query_reads_pending = maxi(_query_reads_pending - 1, 0)
		if serial == _query_serial:
			_query_batch = {"points": points, "values": data.to_float32_array(), "body": false}
			_query_busy = false
		_mutex.unlock(), 0, points.size() * 16)


func query_body_render(points: PackedVector3Array, parameters_bytes: PackedByteArray, generation: int = -1) -> void:
	if _sets.is_empty() or points.is_empty() or points.size() > MAX_QUERIES:
		return
	_mutex.lock()
	if _query_busy or (generation >= 0 and generation != _query_serial):
		_mutex.unlock()
		return
	_query_busy = true
	_query_reads_pending += 1
	var readback_generation := _readback_generation
	var serial := _query_serial
	_mutex.unlock()
	var bytes := PackedFloat32Array()
	for point in points:
		bytes.append_array(PackedFloat32Array([point.x, point.y, point.z, 0.0]))
	_rd.buffer_update(_query_points, 0, bytes.size() * 4, bytes.to_byte_array())
	parameters_bytes.encode_float(72, points.size())
	parameters_bytes.encode_float(64, 5.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_end()
	_rd.buffer_get_data_async(_query_results, func(data: PackedByteArray):
		_mutex.lock()
		if readback_generation == _readback_generation:
			_query_reads_pending = maxi(_query_reads_pending - 1, 0)
		if serial == _query_serial:
			_query_batch = {"points": points, "values": data.to_float32_array(), "body": true}
			_query_busy = false
		_mutex.unlock(), 0, points.size() * 48)


func cancel_queries() -> void:
	_mutex.lock()
	_query_serial += 1
	_query_batch = {}
	_query_busy = false
	_mutex.unlock()


func query_serial() -> int:
	_mutex.lock()
	var serial := _query_serial
	_mutex.unlock()
	return serial


func take_query_batch() -> Dictionary:
	_mutex.lock()
	var result := _query_batch
	_query_batch = {}
	_mutex.unlock()
	return result


func _dispatch_render(list: int, parameters_bytes: PackedByteArray, mode: float) -> void:
	parameters_bytes.encode_float(64, mode)
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch(list, ceili(parameters_bytes.decode_float(16) / 8.0), ceili(parameters_bytes.decode_float(20) / 8.0), 1)


func _texture_render(size: Vector2i, data: PackedByteArray = PackedByteArray()) -> RID:
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture := _rd.texture_create(format, RDTextureView.new(), [data] if not data.is_empty() else [])
	if data.is_empty():
		_rd.texture_clear(texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	return texture


func _free_render() -> void:
	_mutex.lock()
	var pending_query := _query_reads_pending > 0 or _impact_pending
	_query_reads_pending = 0
	_readback_generation += 1
	_status = {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}
	_query_serial += 1
	_query_batch = {}
	_query_busy = false
	_impact_pending = false
	_impact_window_s = 0.0
	_mutex.unlock()
	if _rd == null:
		return
	if pending_query:
		_rd.buffer_get_data(_query_results, 0, 16)
	for set_rid in _sets + _spill_sets:
		if set_rid.is_valid():
			_rd.free_rid(set_rid)
	_sets.clear()
	_spill_sets.clear()
	for buffer in [_spill_particles, _spill_deposits, _spill_outflow, _spill_state, _spill_impacts]:
		if buffer.is_valid():
			_rd.free_rid(buffer)
	_spill_particles = RID()
	_spill_deposits = RID()
	_spill_outflow = RID()
	_spill_state = RID()
	_spill_impacts = RID()
	for texture in _states + [_terrain, _surface, _foam, _source, _spill_out, _spill_positions, _sampler, _query_points, _query_results]:
		if texture.is_valid():
			_rd.free_rid(texture)
	_states.clear()
	for rid in [_pipeline, _shader, _spill_pipeline, _spill_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_spill_pipeline = RID()
	_spill_shader = RID()
	_spill_out = RID()
	_spill_positions = RID()
	_terrain = RID()
	_surface = RID()
	_foam = RID()
	_source = RID()
	_sampler = RID()
	_query_points = RID()
	_query_results = RID()
	_pipeline = RID()
	_shader = RID()
	_index = 0
	_rd = null
