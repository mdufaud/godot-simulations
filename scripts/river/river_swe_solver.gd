extends RefCounted

const REGION_M := Rect2(-6.0, -7.0, 16.0, 24.0)
const GRID := Vector2i(128, 192)
const CELL_M := 0.125
const GRAVITY_M_S2 := 9.81
const MAX_STEP_S := 0.0015
const MAX_SUBSTEPS := 128

var _rd: RenderingDevice
var _states: Array[RID] = []
var _sets: Array[RID] = []
var _terrain := RID()
var _surface := RID()
var _foam := RID()
var _shader := RID()
var _pipeline := RID()
var _index := 0
var _backlog_s := 0.0
var _mutex := Mutex.new()
var _status := {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}


func start(field: RiverField, config: RiverConfig) -> void:
	var values := PackedFloat32Array()
	values.resize(GRID.x * GRID.y * 4)
	for y in GRID.y:
		for x in GRID.x:
			var point := REGION_M.position + Vector2(x + 0.5, y + 0.5) * CELL_M
			var bed := RiverField.bed_height(point)
			var flow := field.sample(point, config.water_level_m)
			var offset := (y * GRID.x + x) * 4
			values[offset] = bed
			values[offset + 1] = RiverField.water_height(point, 0.0)
			values[offset + 2] = flow.r
			values[offset + 3] = flow.g
	for instance in field.obstacle_meshes:
		_stamp_rock(values, instance)
	RenderingServer.call_on_render_thread(_init_render.bind(values.to_byte_array(),
		parameters(config, 0.0, Vector4.ZERO)))


func _stamp_rock(values: PackedFloat32Array, instance: MeshInstance3D) -> void:
	var bounds := instance.global_transform * instance.get_aabb()
	if not REGION_M.intersects(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))):
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
		var low := (Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))) - REGION_M.position) / CELL_M - Vector2.ONE * 0.5
		var high := (Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))) - REGION_M.position) / CELL_M - Vector2.ONE * 0.5
		for y in range(maxi(ceili(low.y), 0), mini(floori(high.y) + 1, GRID.y)):
			for x in range(maxi(ceili(low.x), 0), mini(floori(high.x) + 1, GRID.x)):
				var point := REGION_M.position + Vector2(x + 0.5, y + 0.5) * CELL_M - origin
				var wb := point.cross(ac) / area
				var wc := ab.cross(point) / area
				if minf(1.0 - wb - wc, minf(wb, wc)) >= -0.0001:
					var offset := (y * GRID.x + x) * 4
					values[offset] = maxf(values[offset], a.y + wb * (b.y - a.y) + wc * (c.y - a.y))


func parameters(config: RiverConfig, time_s: float, impulse: Vector4) -> PackedByteArray:
	return PackedFloat32Array([
		REGION_M.position.x, REGION_M.position.y, CELL_M, GRAVITY_M_S2,
		GRID.x, GRID.y, 0.0, config.speed_m_s,
		config.water_level_m, config.foam_amount, 0.0, time_s,
		impulse.x, impulse.y, impulse.z, impulse.w,
		0.0, config.whitewater_strength, 0.0, 0.0,
	]).to_byte_array()


func snapshot() -> Dictionary:
	_mutex.lock()
	var result := _status.duplicate()
	_mutex.unlock()
	return result


func stop() -> void:
	RenderingServer.call_on_render_thread(_free_render)


func _init_render(terrain_bytes: PackedByteArray, parameters_bytes: PackedByteArray) -> void:
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
	_terrain = _texture_render(terrain_bytes)
	_surface = _texture_render()
	_foam = _texture_render()
	_states.assign([_texture_render(), _texture_render()])
	for index in 2:
		var uniforms: Array[RDUniform] = []
		var textures: Array[RID] = [_states[index], _states[1 - index], _terrain, _surface, _foam]
		for binding in textures.size():
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			uniform.binding = binding
			uniform.add_id(textures[binding])
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
	var list := _rd.compute_list_begin()
	if reset:
		_backlog_s = 0.0
		_index = 0
		_dispatch_render(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
	_backlog_s += delta_s
	var duration := minf(_backlog_s, MAX_SUBSTEPS * MAX_STEP_S)
	var steps := ceili(duration / MAX_STEP_S)
	var step_s := duration / maxf(steps, 1.0)
	parameters_bytes.encode_float(24, step_s)
	for substep in steps:
		_dispatch_render(list, parameters_bytes, 1.0)
		_rd.compute_list_add_barrier(list)
		_index = 1 - _index
		parameters_bytes.encode_float(60, 0.0)
	_dispatch_render(list, parameters_bytes, 2.0)
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("river_swe/end")
	_backlog_s -= duration
	_mutex.lock()
	_status["state"] = _states[_index]
	_status["gpu_ms"] = float(timing.get("total", 0.0))
	_status["time_s"] = (0.0 if reset else float(_status["time_s"])) + duration
	_status["backlog_s"] = _backlog_s
	_mutex.unlock()


func _dispatch_render(list: int, parameters_bytes: PackedByteArray, mode: float) -> void:
	parameters_bytes.encode_float(64, mode)
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch(list, GRID.x / 8, GRID.y / 8, 1)


func _texture_render(data: PackedByteArray = PackedByteArray()) -> RID:
	var format := RDTextureFormat.new()
	format.width = GRID.x
	format.height = GRID.y
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture := _rd.texture_create(format, RDTextureView.new(), [data] if not data.is_empty() else [])
	if data.is_empty():
		_rd.texture_clear(texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	return texture


func _free_render() -> void:
	_mutex.lock()
	_status = {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}
	_mutex.unlock()
	if _rd == null:
		return
	for set_rid in _sets:
		if set_rid.is_valid():
			_rd.free_rid(set_rid)
	_sets.clear()
	for texture in _states + [_terrain, _surface, _foam]:
		if texture.is_valid():
			_rd.free_rid(texture)
	_states.clear()
	for rid in [_pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_terrain = RID()
	_surface = RID()
	_foam = RID()
	_pipeline = RID()
	_shader = RID()
	_index = 0
	_rd = null
