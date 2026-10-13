extends RefCounted

const CELL_M := 0.125
const GRAVITY_M_S2 := 9.81
const MAX_STEP_S := 0.003
const MAX_SUBSTEPS := 64
const MAX_QUERIES := 32

var region_m := Rect2()
var cell_m := CELL_M
var grid := Vector2i.ZERO
var _source_domain: Rect2
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
var _index := 0
var _query_busy := false
var _query_serial := 0
var _query_batch: Dictionary = {}
var _mutex := Mutex.new()
var _status := {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}


func start(field: RiverField, config: RiverConfig) -> void:
	_source_domain = Rect2(-field.domain_m * 0.5, field.domain_m)
	if field.solver_terrain_image != null:
		RenderingServer.call_on_render_thread(_init_render.bind(field.solver_terrain_image.get_data(),
			field.solver_terrain_image.get_size(), parameters(config, 0.0)))
		return
	var size := Vector2i(field.domain_m / CELL_M)
	var values := PackedFloat32Array()
	values.resize(size.x * size.y * 4)
	for y in size.y:
		for x in size.x:
			var point := _source_domain.position + Vector2(x + 0.5, y + 0.5) * CELL_M
			var flow := field.sample_solver(point, 0.0)
			var offset := (y * size.x + x) * 4
			values[offset] = field.sample_bed(point)
			values[offset + 1] = field.sample_height(point, 0.0)
			values[offset + 2] = flow.r
			values[offset + 3] = flow.g
	for instance in field.obstacle_meshes:
		_stamp_rock(values, instance, size)
	var bytes := values.to_byte_array()
	field.solver_terrain_image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, bytes)
	RenderingServer.call_on_render_thread(_init_render.bind(bytes, size,
		parameters(config, 0.0)))


func _stamp_rock(values: PackedFloat32Array, instance: MeshInstance3D, size: Vector2i) -> void:
	var bounds := instance.global_transform * instance.get_aabb()
	if not _source_domain.intersects(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))):
		return
	var faces := instance.mesh.get_faces()
	for index in range(0, faces.size(), 3):
		var a := instance.global_transform * faces[index]
		var b := instance.global_transform * faces[index + 1]
		var c := instance.global_transform * faces[index + 2]
		var origin := Vector2(a.x, a.z)
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var area := ab.cross(ac)
		if absf(area) < 0.000001:
			continue
		var low := (Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))) - _source_domain.position) / CELL_M - Vector2.ONE * 0.5
		var high := (Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))) - _source_domain.position) / CELL_M - Vector2.ONE * 0.5
		for y in range(maxi(ceili(low.y), 0), mini(floori(high.y) + 1, size.y)):
			for x in range(maxi(ceili(low.x), 0), mini(floori(high.x) + 1, size.x)):
				var point := _source_domain.position + Vector2(x + 0.5, y + 0.5) * CELL_M - origin
				var wb := point.cross(ac) / area
				var wc := ab.cross(point) / area
				if minf(1.0 - wb - wc, minf(wb, wc)) >= -0.0001:
					var offset := (y * size.x + x) * 4
					values[offset] = maxf(values[offset], a.y + wb * (b.y - a.y) + wc * (c.y - a.y))


func parameters(config: RiverConfig, time_s: float) -> PackedByteArray:
	return PackedFloat32Array([
		region_m.position.x, region_m.position.y, cell_m, GRAVITY_M_S2,
		grid.x, grid.y, 0.0, config.speed_m_s,
		config.water_level_m, config.foam_amount, 0.0, time_s,
		_source_domain.position.x, _source_domain.position.y, _source_domain.size.x, _source_domain.size.y,
		0.0, config.whitewater_strength, 0.0, 0.0,
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
	_query_results = _rd.storage_buffer_create(MAX_QUERIES * 16)
	for index in 2:
		var uniforms: Array[RDUniform] = []
		var textures: Array[RID] = [_states[index], _states[1 - index], _terrain, _surface, _foam]
		for binding in textures.size():
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.binding = binding
			uniform.add_id(textures[binding])
			uniforms.append(uniform)
		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source_uniform.binding = 5
		source_uniform.add_id(_sampler)
		source_uniform.add_id(_source)
		uniforms.append(source_uniform)
		for binding in 2:
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = 6 + binding
			uniform.add_id(_query_points if binding == 0 else _query_results)
			uniforms.append(uniform)
		_sets.append(_rd.uniform_set_create(uniforms, _shader, 0))
	var list := _rd.compute_list_begin()
	_dispatch_render(list, parameters_bytes, 0.0)
	_rd.compute_list_end()
	_mutex.lock()
	_status = {"ready": true, "surface": _surface, "foam": _foam, "terrain": _terrain,
		"state": _states[0], "gpu_ms": 0.0, "time_s": 0.0}
	_mutex.unlock()


func advance_render(delta_s: float, parameters_bytes: PackedByteArray, reset: bool, profiling: bool) -> void:
	if _sets.is_empty():
		return
	var timing := GpuTimings.read(_rd, "river_swe/") if profiling else {}
	if profiling:
		_rd.capture_timestamp("river_swe/start")
	var next_cell := parameters_bytes.decode_float(8)
	var list := _rd.compute_list_begin()
	if reset:
		_index = 0
		_dispatch_render(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
	var max_step := MAX_STEP_S * next_cell / CELL_M
	var duration := minf(delta_s, MAX_SUBSTEPS * max_step)
	var steps := ceili(duration / max_step)
	parameters_bytes.encode_float(24, duration / maxf(steps, 1.0))
	for substep in steps:
		_dispatch_render(list, parameters_bytes, 1.0)
		_rd.compute_list_add_barrier(list)
		_index = 1 - _index
	_dispatch_render(list, parameters_bytes, 2.0)
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("river_swe/end")
	_mutex.lock()
	_status["state"] = _states[_index]
	_status["gpu_ms"] = float(timing.get("total", 0.0))
	_status["time_s"] = (0.0 if reset else float(_status["time_s"])) + duration
	_status["backlog_s"] = 0.0
	_mutex.unlock()


func query_render(points: PackedVector2Array, parameters_bytes: PackedByteArray) -> void:
	if _sets.is_empty() or _query_busy or points.is_empty():
		return
	_query_busy = true
	_query_serial += 1
	var serial := _query_serial
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
		if serial == _query_serial:
			_query_batch = {"points": points, "values": data.to_float32_array()}
			_query_busy = false
		_mutex.unlock(), 0, points.size() * 16)


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
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var texture := _rd.texture_create(format, RDTextureView.new(), [data] if not data.is_empty() else [])
	if data.is_empty():
		_rd.texture_clear(texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	return texture


func _free_render() -> void:
	_mutex.lock()
	var pending_query := _query_busy
	_status = {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}
	_query_serial += 1
	_query_batch = {}
	_query_busy = false
	_mutex.unlock()
	if _rd == null:
		return
	if pending_query:
		_rd.buffer_get_data(_query_results, 0, 16)
	for set_rid in _sets:
		_rd.free_rid(set_rid)
	_sets.clear()
	for texture in _states + [_terrain, _surface, _foam, _source, _sampler, _query_points, _query_results]:
		if texture.is_valid():
			_rd.free_rid(texture)
	_states.clear()
	for rid in [_pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
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
