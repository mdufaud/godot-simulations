extends RefCounted

const CELL_M := 0.125
const GRAVITY_M_S2 := 9.81
const MAX_STEP_S := 0.003
const MAX_SUBSTEPS := 64
const MAX_QUERIES := 32
const CFL_LIMIT := 0.40
const LANES := 48
const FILM_CELLS := 63
const PACKET_CAPACITY := 256
const EMISSION_HZ := 120.0
const ROCK_MAP_SIZE := 96

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
var _balance := RID()
var _source := RID()
var _ground := RID()
var _ground_image: Image
var _sampler := RID()
var _query_points := RID()
var _query_results := RID()
var _shader := RID()
var _pipeline := RID()
var _waterfall_shader := RID()
var _waterfall_pipeline := RID()
var _cfl_shader := RID()
var _cfl_pipeline := RID()
var _schedule_shader := RID()
var _schedule_pipeline := RID()
var _control := RID()
var _cascade := RID()
var _film_states: Array[RID] = []
var _waterfall_surface := RID()
var _waterfall_velocity := RID()
var _waterfall_clock := RID()
var _waterfall_boundary := RID()
var _waterfall: Variant
var _waterfall_sets: Array[RID] = []
var _rock_maps: Dictionary = {}
var _cfl_sets: Array[RID] = []
var _schedule_set := RID()
var _index := 0
var _query_busy := false
var _query_serial := 0
var _query_reads_pending := 0
var _readback_generation := 0
var _query_batch: Dictionary = {}
var _mutex := Mutex.new()
var _status := {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}
var _progress_interval_s := 0.0
var _progress_pending := false
var _progress_backlog_s := 0.0
var _progress_generation := 0


func start(field: RiverField, config: RiverConfig) -> void:
	_waterfall = field.get("waterfall")
	_ground_image = field.ground_height_image
	_source_domain = Rect2(-field.domain_m * 0.5, field.domain_m)
	if field.solver_terrain_image != null:
		RenderingServer.call_on_render_thread(_init_render.bind(field.solver_terrain_image.get_data(),
			field.solver_terrain_image.get_size(), parameters(config, 0.0)))
		return
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
	WorkerThreadPool.wait_for_group_task_completion(task)
	var values := PackedFloat32Array()
	for row: PackedFloat32Array in rows:
		values.append_array(row)
	for instance in field.obstacle_meshes:
		_stamp_rock(values, instance, size)
	var bytes := values.to_byte_array()
	field.solver_terrain_image = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, bytes)
	RenderingServer.call_on_render_thread(_init_render.bind(bytes, size,
		parameters(config, 0.0)))


func _stamp_rock(values: PackedFloat32Array, instance: MeshInstance3D, size: Vector2i) -> void:
	var transform := instance.global_transform
	var bounds := transform * instance.get_aabb()
	if not _source_domain.intersects(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))):
		return
	var basis := transform.basis
	var tolerance := 0.001 * basis.get_scale().length()
	if absf(basis.x.y) > tolerance or absf(basis.z.y) > tolerance or absf(basis.y.x) > tolerance or absf(basis.y.z) > tolerance:
		_stamp_faces(values, instance, size)
		return
	var map := _rock_map(instance.mesh)
	var local := instance.mesh.get_aabb()
	var texel := Vector2(local.size.x, local.size.z) / float(ROCK_MAP_SIZE - 1)
	var inverse := transform.affine_inverse()
	var low := ((Vector2(bounds.position.x, bounds.position.z) - _source_domain.position) / CELL_M - Vector2.ONE * 0.5).ceil()
	var high := ((Vector2(bounds.end.x, bounds.end.z) - _source_domain.position) / CELL_M - Vector2.ONE * 0.5).floor()
	for y in range(maxi(int(low.y), 0), mini(int(high.y) + 1, size.y)):
		for x in range(maxi(int(low.x), 0), mini(int(high.x) + 1, size.x)):
			var world := _source_domain.position + Vector2(x + 0.5, y + 0.5) * CELL_M
			var point := inverse * Vector3(world.x, 0.0, world.y)
			var cell := ((Vector2(point.x, point.z) - Vector2(local.position.x, local.position.z)) / texel).round()
			if cell.x < 0.0 or cell.y < 0.0 or cell.x >= ROCK_MAP_SIZE or cell.y >= ROCK_MAP_SIZE:
				continue
			var top := map[int(cell.y) * ROCK_MAP_SIZE + int(cell.x)]
			if top == -INF:
				continue
			var offset := (y * size.x + x) * 4
			values[offset] = maxf(values[offset], (transform * Vector3(point.x, top, point.z)).y)


func _rock_map(mesh: Mesh) -> PackedFloat32Array:
	if _rock_maps.has(mesh):
		return _rock_maps[mesh]
	var bounds := mesh.get_aabb()
	var texel := Vector2(bounds.size.x, bounds.size.z) / float(ROCK_MAP_SIZE - 1)
	var origin := Vector2(bounds.position.x, bounds.position.z)
	var map := PackedFloat32Array()
	map.resize(ROCK_MAP_SIZE * ROCK_MAP_SIZE)
	map.fill(-INF)
	var faces := mesh.get_faces()
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var area := ab.cross(ac)
		if absf(area) < 0.0000001:
			continue
		var low := ((Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))) - origin) / texel).ceil()
		var high := ((Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))) - origin) / texel).floor()
		for y in range(maxi(int(low.y), 0), mini(int(high.y) + 1, ROCK_MAP_SIZE)):
			for x in range(maxi(int(low.x), 0), mini(int(high.x) + 1, ROCK_MAP_SIZE)):
				var point := origin + Vector2(x, y) * texel - Vector2(a.x, a.z)
				var wb := point.cross(ac) / area
				var wc := ab.cross(point) / area
				if minf(1.0 - wb - wc, minf(wb, wc)) >= -0.0001:
					var cell := y * ROCK_MAP_SIZE + x
					map[cell] = maxf(map[cell], a.y + wb * (b.y - a.y) + wc * (c.y - a.y))
	_rock_maps[mesh] = map
	return map


func _stamp_faces(values: PackedFloat32Array, instance: MeshInstance3D, size: Vector2i) -> void:
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
	var waterfall := Vector4.ZERO
	var cascade := Vector4(1.0, 1.0, 1.0, EMISSION_HZ)
	if _waterfall != null:
		waterfall = Vector4(_waterfall.angle_degrees, _waterfall.height_m, _waterfall.width_m, _waterfall.crest_z_m)
		cascade = Vector4(_waterfall.lane_count, _waterfall.film_cells, _waterfall.packet_capacity, _waterfall.emission_rate_hz)
	return PackedFloat32Array([
		region_m.position.x, region_m.position.y, cell_m, GRAVITY_M_S2,
		grid.x, grid.y, 0.0, config.speed_m_s,
		config.water_level_m, config.foam_amount, MAX_STEP_S, time_s,
		_source_domain.position.x, _source_domain.position.y, _source_domain.size.x, _source_domain.size.y,
		0.0, config.whitewater_strength, 0.0, 0.0,
		waterfall.x, waterfall.y, waterfall.z, waterfall.w,
		cascade.x, cascade.y, cascade.z, cascade.w,
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
	_balance = _texture_render(size if _waterfall != null else Vector2i.ONE)
	_states.assign([_texture_render(size), _texture_render(size)])
	var lanes := int(parameters_bytes.decode_float(96)) if _waterfall != null else LANES
	var film_cells := int(parameters_bytes.decode_float(100)) if _waterfall != null else FILM_CELLS
	var packet_capacity := int(parameters_bytes.decode_float(104)) if _waterfall != null else PACKET_CAPACITY
	var waterfall_angle := parameters_bytes.decode_float(80) if _waterfall != null else 0.0
	var waterfall_size := Vector2i(lanes, packet_capacity if waterfall_angle >= 90.0 else film_cells)
	var film_size := Vector2i(lanes, maxi(film_cells, 1))
	_film_states.assign([_texture_render(film_size), _texture_render(film_size)])
	_waterfall_surface = _texture_render(waterfall_size)
	_waterfall_velocity = _texture_render(waterfall_size)
	_waterfall_clock = _texture_render(Vector2i.ONE)
	_waterfall_boundary = _texture_render(Vector2i(lanes, 1))
	_control = _rd.storage_buffer_create(128, PackedByteArray(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var cascade_bytes := PackedByteArray()
	cascade_bytes.resize((LANES + LANES * PACKET_CAPACITY * 2 + LANES * 2 + LANES) * 16)
	_cascade = _rd.storage_buffer_create(cascade_bytes.size(), cascade_bytes)
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler)
	_query_points = _rd.storage_buffer_create(MAX_QUERIES * 16)
	_query_results = _rd.storage_buffer_create(MAX_QUERIES * 48)
	for index in 2:
		var uniforms: Array[RDUniform] = []
		for binding in 5:
			uniforms.append(_uniform(binding, [_states[index], _states[1 - index], _terrain, _surface, _foam][binding], RenderingDevice.UNIFORM_TYPE_IMAGE))
		var source_uniform := _uniform(5, _sampler, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE)
		source_uniform.add_id(_source)
		uniforms.append(source_uniform)
		uniforms.append(_uniform(6, _query_points, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(7, _query_results, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(8, _cascade, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(9, _control, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
		uniforms.append(_uniform(10, _waterfall_surface, RenderingDevice.UNIFORM_TYPE_IMAGE))
		uniforms.append(_uniform(11, _waterfall_velocity, RenderingDevice.UNIFORM_TYPE_IMAGE))
		uniforms.append(_uniform(12, _waterfall_clock, RenderingDevice.UNIFORM_TYPE_IMAGE))
		uniforms.append(_uniform(13, _balance, RenderingDevice.UNIFORM_TYPE_IMAGE))
		_sets.append(_rd.uniform_set_create(uniforms, _shader, 0))
	if _waterfall != null:
		var waterfall_source := ShaderCache.compile(_rd, "river_waterfall",
			FileAccess.get_file_as_string("res://shaders/river/river_waterfall.comp"))
		var cfl_source := ShaderCache.compile(_rd, "river_swe_cfl",
			FileAccess.get_file_as_string("res://shaders/river/river_swe_cfl.comp"))
		var schedule_source := ShaderCache.compile(_rd, "river_swe_schedule",
			FileAccess.get_file_as_string("res://shaders/river/river_swe_schedule.comp"))
		for result in [waterfall_source, cfl_source, schedule_source]:
			if not result.compile_error_compute.is_empty():
				push_error("River waterfall compile error: " + result.compile_error_compute)
				return
		_waterfall_shader = _rd.shader_create_from_spirv(waterfall_source)
		_waterfall_pipeline = _rd.compute_pipeline_create(_waterfall_shader)
		_ground = _texture_render(_ground_image.get_size(), _ground_image.get_data())
		_cfl_shader = _rd.shader_create_from_spirv(cfl_source)
		_cfl_pipeline = _rd.compute_pipeline_create(_cfl_shader)
		_schedule_shader = _rd.shader_create_from_spirv(schedule_source)
		_schedule_pipeline = _rd.compute_pipeline_create(_schedule_shader)
		for index in 2:
			var wf_uniforms: Array[RDUniform] = []
			var wf_images: Array[RID] = [_film_states[index], _film_states[1 - index], _waterfall_surface, _waterfall_velocity]
			for binding in wf_images.size():
				wf_uniforms.append(_uniform(binding, wf_images[binding], RenderingDevice.UNIFORM_TYPE_IMAGE))
			wf_uniforms.append(_uniform(4, _cascade, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
			wf_uniforms.append(_uniform(5, _control, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER))
			wf_uniforms.append(_uniform(6, _states[0], RenderingDevice.UNIFORM_TYPE_IMAGE))
			wf_uniforms.append(_uniform(7, _terrain, RenderingDevice.UNIFORM_TYPE_IMAGE))
			var wf_sampler := _uniform(8, _sampler, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE)
			wf_sampler.add_id(_source)
			wf_uniforms.append(wf_sampler)
			wf_uniforms.append(_uniform(9, _states[1], RenderingDevice.UNIFORM_TYPE_IMAGE))
			var ground_sampler := _uniform(10, _sampler, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE)
			ground_sampler.add_id(_ground)
			wf_uniforms.append(ground_sampler)
			wf_uniforms.append(_uniform(11, _waterfall_boundary, RenderingDevice.UNIFORM_TYPE_IMAGE))
			_waterfall_sets.append(_rd.uniform_set_create(wf_uniforms, _waterfall_shader, 0))
			var cfl_uniforms: Array[RDUniform] = [
				_uniform(0, _states[index], RenderingDevice.UNIFORM_TYPE_IMAGE),
				_uniform(1, _film_states[index], RenderingDevice.UNIFORM_TYPE_IMAGE),
				_uniform(2, _control, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
				_uniform(3, _cascade, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER),
				_uniform(4, _states[1], RenderingDevice.UNIFORM_TYPE_IMAGE),
				_uniform(5, _film_states[1], RenderingDevice.UNIFORM_TYPE_IMAGE),
			]
			_cfl_sets.append(_rd.uniform_set_create(cfl_uniforms, _cfl_shader, 0))
		_schedule_set = _rd.uniform_set_create([
			_uniform(0, _control, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)], _schedule_shader, 0)
	var list := _rd.compute_list_begin()
	_dispatch_render(list, parameters_bytes, 0.0)
	if _waterfall != null:
		_rd.compute_list_add_barrier(list)
		_dispatch_waterfall(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
		_dispatch_schedule(list, parameters_bytes, 0.0, -1.0)
	_rd.compute_list_end()
	_mutex.lock()
	_status = {"ready": true, "surface": _surface, "foam": _foam, "terrain": _terrain,
		"state": _states[0], "gpu_ms": 0.0, "time_s": 0.0,
		"waterfall_surface": _waterfall_surface, "waterfall_velocity": _waterfall_velocity,
		"waterfall_clock": _waterfall_clock, "waterfall_boundary": _waterfall_boundary,
		"volume_removed": 0.0, "volume_received": 0.0,
		"transport_volume": 0.0, "backlog_s": 0.0, "cfl_max": 0.0, "overflow": 0}
	_status["level_relaxation_volume"] = 0.0
	_status["boundary_volume"] = 0.0
	_mutex.unlock()


func _uniform(binding: int, rid: RID, type: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


func advance_render(delta_s: float, parameters_bytes: PackedByteArray, reset: bool, profiling: bool) -> void:
	if _sets.is_empty():
		return
	if _waterfall != null:
		_advance_waterfall_render(delta_s, parameters_bytes, reset, profiling)
		return
	var cpu_start := Time.get_ticks_usec() if profiling else 0
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
	_status["cpu_ms"] = float(Time.get_ticks_usec() - cpu_start) / 1000.0 if profiling else 0.0
	_status["time_s"] = (0.0 if reset else float(_status["time_s"])) + duration
	_status["backlog_s"] = 0.0
	_mutex.unlock()


func _advance_waterfall_render(delta_s: float, parameters_bytes: PackedByteArray,
		reset: bool, profiling: bool) -> void:
	var cpu_start := Time.get_ticks_usec() if profiling else 0
	var timing := GpuTimings.read(_rd, "river_swe/") if profiling else {}
	if profiling:
		_rd.capture_timestamp("river_swe/start")
	var list := _rd.compute_list_begin()
	if reset:
		_index = 0
		_dispatch_schedule(list, parameters_bytes, delta_s, -1.0)
		_rd.compute_list_add_barrier(list)
		_dispatch_render(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
		_dispatch_waterfall(list, parameters_bytes, 0.0)
		_rd.compute_list_add_barrier(list)
	_dispatch_schedule(list, parameters_bytes, delta_s, 0.0)
	_rd.compute_list_add_barrier(list)
	for _substep in MAX_SUBSTEPS:
		parameters_bytes.encode_float(64, 3.0)
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _sets[0], 0)
		_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
		_rd.compute_list_dispatch_indirect(list, _control, 40)
		_rd.compute_list_add_barrier(list)
		_dispatch_waterfall_indirect(list, parameters_bytes, 3.0, 100)
		_rd.compute_list_add_barrier(list)
		_dispatch_cfl(list, parameters_bytes)
		_rd.compute_list_add_barrier(list)
		_dispatch_schedule(list, parameters_bytes, 0.0, 1.0)
		_rd.compute_list_add_barrier(list)
		parameters_bytes.encode_float(64, 1.0)
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
		_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
		_rd.compute_list_dispatch_indirect(list, _control, 40)
		_rd.compute_list_add_barrier(list)
		_dispatch_waterfall_indirect(list, parameters_bytes, 1.0, 52)
		_rd.compute_list_add_barrier(list)
		_dispatch_schedule(list, parameters_bytes, 0.0, 2.0)
		_rd.compute_list_add_barrier(list)
	_dispatch_waterfall(list, parameters_bytes, 2.0)
	_rd.compute_list_add_barrier(list)
	_dispatch_waterfall(list, parameters_bytes, 4.0)
	_rd.compute_list_add_barrier(list)
	parameters_bytes.encode_float(64, 2.0)
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch(list, ceili(parameters_bytes.decode_float(16) / 8.0),
		ceili(parameters_bytes.decode_float(20) / 8.0), 1)
	if _progress_interval_s + delta_s >= 0.25:
		_rd.compute_list_add_barrier(list)
		parameters_bytes.encode_float(64, 6.0)
		_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
		_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("river_swe/end")
	_progress_interval_s += delta_s
	if _progress_interval_s >= 0.25:
		_read_progress_render()
	_mutex.lock()
	_status["gpu_ms"] = float(timing.get("total", 0.0))
	_status["cpu_ms"] = float(Time.get_ticks_usec() - cpu_start) / 1000.0 if profiling else 0.0
	_status["waterfall_surface"] = _waterfall_surface
	_status["waterfall_velocity"] = _waterfall_velocity
	_status["waterfall_clock"] = _waterfall_clock
	_status["waterfall_boundary"] = _waterfall_boundary
	_mutex.unlock()


func _schedule_parameters(parameters_bytes: PackedByteArray, delta_s: float, mode: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(48)
	bytes.encode_float(0, delta_s)
	bytes.encode_float(4, MAX_STEP_S)
	bytes.encode_float(8, cell_m)
	bytes.encode_float(12, CFL_LIMIT)
	bytes.encode_s32(16, ceili(parameters_bytes.decode_float(16) / 8.0))
	bytes.encode_s32(20, ceili(parameters_bytes.decode_float(20) / 8.0))
	bytes.encode_s32(24, ceili(parameters_bytes.decode_float(96) / 8.0))
	bytes.encode_s32(28, ceili(maxf(parameters_bytes.decode_float(100), parameters_bytes.decode_float(104)) / 8.0))
	bytes.encode_float(32, parameters_bytes.decode_float(80))
	bytes.encode_float(36, parameters_bytes.decode_float(104))
	bytes.encode_float(40, parameters_bytes.decode_float(108))
	bytes.encode_float(44, mode)
	return bytes


func _dispatch_schedule(list: int, parameters_bytes: PackedByteArray, delta_s: float, mode: float) -> void:
	var pc := _schedule_parameters(parameters_bytes, delta_s, mode)
	_rd.compute_list_bind_compute_pipeline(list, _schedule_pipeline)
	_rd.compute_list_bind_uniform_set(list, _schedule_set, 0)
	_rd.compute_list_set_push_constant(list, pc, pc.size())
	if mode > 0.5:
		_rd.compute_list_dispatch_indirect(list, _control, 88)
	else:
		_rd.compute_list_dispatch(list, 1, 1, 1)


func _dispatch_cfl(list: int, parameters_bytes: PackedByteArray) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _cfl_pipeline)
	_rd.compute_list_bind_uniform_set(list, _cfl_sets[_index], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch_indirect(list, _control, 40)


func _dispatch_waterfall(list: int, parameters_bytes: PackedByteArray, mode: float) -> void:
	parameters_bytes.encode_float(64, mode)
	_rd.compute_list_bind_compute_pipeline(list, _waterfall_pipeline)
	_rd.compute_list_bind_uniform_set(list, _waterfall_sets[0], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	var rows := int(parameters_bytes.decode_float(104)) if parameters_bytes.decode_float(80) >= 90.0 else int(parameters_bytes.decode_float(100))
	_rd.compute_list_dispatch(list, ceili(parameters_bytes.decode_float(96) / 8.0), ceili(rows / 8.0), 1)


func _dispatch_waterfall_indirect(list: int, parameters_bytes: PackedByteArray, mode: float, offset: int) -> void:
	parameters_bytes.encode_float(64, mode)
	_rd.compute_list_bind_compute_pipeline(list, _waterfall_pipeline)
	_rd.compute_list_bind_uniform_set(list, _waterfall_sets[0], 0)
	_rd.compute_list_set_push_constant(list, parameters_bytes, parameters_bytes.size())
	_rd.compute_list_dispatch_indirect(list, _control, offset)


func _read_progress_render() -> void:
	if _progress_pending or not _control.is_valid():
		return
	_progress_pending = true
	_progress_generation += 1
	var generation := _progress_generation
	_progress_interval_s = 0.0
	_rd.buffer_get_data_async(_control, _store_progress.bind(generation), 0, 128)


func _store_progress(data: PackedByteArray, generation: int) -> void:
	_mutex.lock()
	if generation == _progress_generation and data.size() >= 128:
		_progress_pending = false
		_progress_backlog_s = maxf(data.decode_float(4), 0.0)
		var accepted := data.decode_float(8)
		var removed := data.decode_float(24)
		var received := data.decode_float(28)
		_status["state"] = _states[int(data.decode_u32(76))]
		_status["time_s"] = accepted
		_status["backlog_s"] = _progress_backlog_s
		_status["volume_removed"] = removed
		_status["volume_received"] = received
		_status["transport_volume"] = data.decode_float(80)
		_status["cfl_max"] = data.decode_float(64)
		_status["overflow"] = data.decode_u32(68)
		_status["level_relaxation_volume"] = data.decode_float(116)
		_status["boundary_volume"] = data.decode_float(120)
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
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var texture := _rd.texture_create(format, RDTextureView.new(), [data] if not data.is_empty() else [])
	if data.is_empty():
		_rd.texture_clear(texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	return texture


func _free_render() -> void:
	_mutex.lock()
	var pending_query := _query_reads_pending > 0 or _progress_pending
	_query_reads_pending = 0
	_readback_generation += 1
	_status = {"ready": false, "gpu_ms": 0.0, "time_s": 0.0}
	_query_serial += 1
	_query_batch = {}
	_query_busy = false
	_progress_generation += 1
	_progress_pending = false
	_progress_interval_s = 0.0
	_progress_backlog_s = 0.0
	_mutex.unlock()
	if _rd == null:
		return
	if pending_query:
		_rd.buffer_get_data(_query_results, 0, 16)
	for set_rid in _sets + _waterfall_sets + _cfl_sets + [_schedule_set]:
		if set_rid.is_valid():
			_rd.free_rid(set_rid)
	_sets.clear()
	_waterfall_sets.clear()
	_cfl_sets.clear()
	_schedule_set = RID()
	for texture in _states + _film_states + [_terrain, _surface, _foam, _balance, _source, _ground, _sampler,
		_query_points, _query_results, _control, _cascade, _waterfall_surface, _waterfall_velocity, _waterfall_clock,
		_waterfall_boundary]:
		if texture.is_valid():
			_rd.free_rid(texture)
	_states.clear()
	_film_states.clear()
	for rid in [_pipeline, _shader, _waterfall_pipeline, _waterfall_shader, _cfl_pipeline, _cfl_shader,
		_schedule_pipeline, _schedule_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_terrain = RID()
	_surface = RID()
	_foam = RID()
	_balance = RID()
	_source = RID()
	_sampler = RID()
	_query_points = RID()
	_query_results = RID()
	_pipeline = RID()
	_shader = RID()
	_waterfall_pipeline = RID()
	_waterfall_shader = RID()
	_cfl_pipeline = RID()
	_cfl_shader = RID()
	_schedule_pipeline = RID()
	_schedule_shader = RID()
	_control = RID()
	_cascade = RID()
	_waterfall_surface = RID()
	_waterfall_velocity = RID()
	_waterfall_clock = RID()
	_waterfall_boundary = RID()
	_ground = RID()
	_ground_image = null
	_index = 0
	_rd = null
