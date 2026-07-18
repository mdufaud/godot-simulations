extends RefCounted
## GPU heightfield sand: a grid of column heights relaxed toward the angle of
## repose every frame (8-neighbour excess-shedding, mass-conserving), plus a
## brush pass (dig / pour / smooth). Heights live in an r32f texture pair and
## never leave the GPU: the surface shader displaces a grid mesh from the same
## texture the flow steps write.

const SHADER_DIR := "res://shaders/sand/"

const TOOL_NONE := 0
const TOOL_DIG := 1
const TOOL_POUR := 2
const TOOL_SMOOTH := 3

var grid_n := 512
var world_size := 4.0
var repose_deg := 33.0
var flow_rate := 0.11
var iterations := 10

var tool_mode := TOOL_NONE
var tool_pos := Vector2.ZERO
var tool_radius := 0.3
var tool_strength := 1.2

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := [RID(), RID()]
var _seed_data := PackedFloat32Array()
var _timings := {}
var _timings_mutex := Mutex.new()


func cell_size() -> float:
	return world_size / float(grid_n)


func get_height_tex_rid() -> RID:
	return _tex[0]


## grid_n * grid_n floats, row-major, x fastest.
func set_seed(heights: PackedFloat32Array) -> void:
	_seed_data = heights


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()

	var common := FileAccess.get_file_as_string(SHADER_DIR + "hf_common.comp")
	for stage in ["flow", "tool"]:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "hf_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "hf_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Sand stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	if _seed_data.size() != grid_n * grid_n:
		push_error("Sand seed size mismatch: %d != %d" % [_seed_data.size(), grid_n * grid_n])
		return

	var fmt := RDTextureFormat.new()
	fmt.width = grid_n
	fmt.height = grid_n
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var seed_bytes := _seed_data.to_byte_array()
	_tex[0] = _rd.texture_create(fmt, RDTextureView.new(), [seed_bytes])
	_tex[1] = _rd.texture_create(fmt, RDTextureView.new(), [seed_bytes])

	# Parity 0 reads tex 0 and writes tex 1; parity 1 the reverse. The step
	# always runs an even number of flow passes, so the frame's result lands
	# back in tex 0 — the one RID the render material is bound to.
	for stage in _shaders:
		var sets := []
		for parity in 2:
			var u0 := RDUniform.new()
			u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u0.binding = 0
			u0.add_id(_tex[parity])
			var u1 := RDUniform.new()
			u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u1.binding = 1
			u1.add_id(_tex[1 - parity])
			sets.append(_rd.uniform_set_create([u0, u1], _shaders[stage], 0))
		_sets[stage] = sets

	initialized = true


func step_render(dt: float) -> void:
	if not initialized:
		return
	_read_timings()
	var pc := _pack_push_constant(dt)
	var groups := ceili(float(grid_n) / 16.0)
	var iters := iterations + (iterations & 1)

	if profiling:
		_rd.capture_timestamp("sand/start")
	var cl := _rd.compute_list_begin()
	if tool_mode != TOOL_NONE:
		_dispatch(cl, "tool", 0, pc, groups)
	for i in iters:
		_dispatch(cl, "flow", i & 1, pc, groups)
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("sand/end")


func _dispatch(cl: int, stage: String, parity: int, pc: PackedByteArray, groups: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage][parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(dt: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(48)
	pc.encode_float(0, tool_pos.x)
	pc.encode_float(4, tool_pos.y)
	pc.encode_float(8, tool_radius)
	pc.encode_float(12, tool_strength)
	pc.encode_float(16, tan(deg_to_rad(repose_deg)) * cell_size())
	pc.encode_float(20, flow_rate)
	pc.encode_float(24, cell_size())
	pc.encode_float(28, dt)
	pc.encode_s32(32, grid_n)
	pc.encode_s32(36, tool_mode)
	pc.encode_s32(40, 0)
	pc.encode_s32(44, 0)
	return pc


# Render thread; reads last frame's pair of timestamps.
func _read_timings() -> void:
	var start_time := 0
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if nm == "sand/start":
			start_time = _rd.get_captured_timestamp_gpu_time(i)
		elif nm == "sand/end":
			_timings_mutex.lock()
			_timings["total"] = float(_rd.get_captured_timestamp_gpu_time(i) - start_time) / 1e6
			_timings_mutex.unlock()


func get_timings() -> Dictionary:
	_timings_mutex.lock()
	var copy := _timings.duplicate()
	_timings_mutex.unlock()
	return copy


func free_render() -> void:
	initialized = false
	if _rd == null:
		return
	for stage in _sets:
		for s in _sets[stage]:
			if s.is_valid():
				_rd.free_rid(s)
	for i in 2:
		if _tex[i].is_valid():
			_rd.free_rid(_tex[i])
		_tex[i] = RID()
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_sets.clear()
	_pipelines.clear()
	_shaders.clear()
