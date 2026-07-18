class_name ClothSolver
extends RefCounted
## GPU XPBD cloth. The mesh is a regular grid, so neighbours are found by index
## arithmetic — no spatial hash, no ping-pong, one thread per vertex for the whole
## step: predict (gravity + gusty wind + aerodynamic drag), then
## iterations x (distance solve, apply). Positions land in an rgba32f image that
## the surface shader samples in its vertex stage, so vertices never touch the CPU.
## Several instances can run per frame (one per sheet); the SPIR-V is compiled
## once and shared across them.

const SHADER_DIR := "res://shaders/cloth/"
const STAGES: Array[String] = ["predict", "solve", "apply"]
const WG := 256

static var _spirv_cache := {}

var grid_w := 96
var grid_h := 72
var rest_spacing := 0.06
var stretch_compliance := 1e-8
var shear_compliance := 1e-6
var bend_compliance := 5e-6
var damping := 0.995
var relaxation := 1.7
var drag := 0.9
var gravity := Vector3(0.0, -9.8, 0.0)
var iterations := 14
var substeps := 4

# The CPU animates the slow wind (direction wander, gust envelope) into `wind`;
# the shader layers fast spatial turbulence on top, scaled by `wind_gust` with
# spatial frequency `wind_turb`. `time` feeds the shader's noise phases.
var wind_enabled := true
var wind := Vector3.ZERO
var wind_gust := 0.6
var wind_turb := 0.3
var time := 0.0

var sphere_center := Vector3.ZERO
var sphere_radius := 0.0

var initialized := false
var profiling := false
# Timestamp prefix: must be unique per instance or the overlays of concurrent
# solvers parse each other's markers.
var profile_key := "cloth"

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _tex_rid := RID()
var _seed_data := PackedFloat32Array()
var _timings := {}
var _timings_mutex := Mutex.new()


func vertex_count() -> int:
	return grid_w * grid_h


func get_position_tex_rid() -> RID:
	return _tex_rid


## 4 floats per vertex: rest position + pin flag (1 = kinematic).
func set_seed(seed: PackedFloat32Array) -> void:
	_seed_data = seed


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()

	var common := FileAccess.get_file_as_string(SHADER_DIR + "cloth_common.comp")
	for stage in STAGES:
		if not _spirv_cache.has(stage):
			var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "cloth_" + stage + ".comp")
			var src := RDShaderSource.new()
			src.source_compute = "#version 450\n\n" + common + "\n" + stage_src
			var spirv := _rd.shader_compile_spirv_from_source(src)
			if not spirv.compile_error_compute.is_empty():
				push_error("Cloth stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
				return
			_spirv_cache[stage] = spirv
		var shader: RID = _rd.shader_create_from_spirv(_spirv_cache[stage])
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	var n := vertex_count()
	var vec4_bytes := n * 16
	var seed_bytes := _seed_data.to_byte_array()
	if seed_bytes.size() != vec4_bytes:
		push_error("Cloth seed size mismatch: %d != %d" % [seed_bytes.size(), vec4_bytes])
		return
	var zero_vec4 := PackedByteArray()
	zero_vec4.resize(vec4_bytes)

	_buffers["positions"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["velocities"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["predicted"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["deltas"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)

	# One texel per vertex, laid out exactly like the grid: the surface shader
	# indexes it straight from the mesh UV.
	var fmt := RDTextureFormat.new()
	fmt.width = grid_w
	fmt.height = grid_h
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_tex_rid = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(_tex_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var order := ["positions", "velocities", "predicted", "deltas"]
	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		for bi in order.size():
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = bi
			u.add_id(_buffers[order[bi]])
			uniforms.append(u)
		var tu := RDUniform.new()
		tu.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		tu.binding = 4
		tu.add_id(_tex_rid)
		uniforms.append(tu)
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	initialized = true


func step_render(dt: float) -> void:
	if not initialized:
		return
	_read_timings()
	var sub_dt := dt / float(substeps)
	var pc := _pack_push_constant(sub_dt, false)
	var pc_last := _pack_push_constant(sub_dt, true)
	var groups := ceili(float(vertex_count()) / WG)

	_rd.capture_timestamp(profile_key + "/start")
	var cl := _rd.compute_list_begin()
	for _s in substeps:
		_dispatch(cl, "predict", pc, groups)
		cl = _mark(cl, profile_key + "/predict")
		for _iter in iterations:
			_dispatch(cl, "solve", pc, groups)
			cl = _mark(cl, profile_key + "/solve")
			var last := _iter == iterations - 1
			_dispatch(cl, "apply", pc_last if last else pc, groups)
			cl = _mark(cl, profile_key + "/apply")
	_rd.compute_list_end()
	_rd.capture_timestamp(profile_key + "/end")


# Timestamps cannot be captured inside an open compute list; split the list at
# stage boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Reads last frame's timestamps: each <profile_key>/* marker
# closes the segment started by the previous one; repeated names sum across
# iterations.
func _read_timings() -> void:
	var out := {}
	var prev_time := 0
	var start_time := 0
	var in_chain := false
	var prefix := profile_key + "/"
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if not nm.begins_with(prefix):
			continue
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if nm == prefix + "start":
			start_time = t
			prev_time = t
			in_chain = true
			continue
		if not in_chain:
			continue
		var seg := nm.trim_prefix(prefix)
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
	if _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
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
	_tex_rid = RID()


func _dispatch(cl: int, stage: String, pc: PackedByteArray, groups: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(dt: float, last_iter: bool) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, dt)
	pc.encode_float(4, 1.0 / dt)
	pc.encode_float(8, damping)
	pc.encode_float(12, relaxation)
	pc.encode_s32(16, grid_w)
	pc.encode_s32(20, grid_h)
	pc.encode_s32(24, vertex_count())
	pc.encode_s32(28, 1 if last_iter else 0)
	pc.encode_float(32, rest_spacing)
	pc.encode_float(36, stretch_compliance)
	pc.encode_float(40, shear_compliance)
	pc.encode_float(44, bend_compliance)
	pc.encode_float(48, gravity.x)
	pc.encode_float(52, gravity.y)
	pc.encode_float(56, gravity.z)
	pc.encode_float(60, drag)
	pc.encode_float(64, wind.x)
	pc.encode_float(68, wind.y)
	pc.encode_float(72, wind.z)
	pc.encode_float(76, time)
	pc.encode_float(80, wind_gust)
	pc.encode_float(84, wind_turb)
	pc.encode_float(88, 0.0)
	pc.encode_float(92, 0.0)
	pc.encode_float(96, sphere_center.x)
	pc.encode_float(100, sphere_center.y)
	pc.encode_float(104, sphere_center.z)
	pc.encode_float(108, sphere_radius)
	pc.encode_s32(112, grid_w)
	pc.encode_s32(116, 1 if wind_enabled else 0)
	pc.encode_s32(120, 0)
	pc.encode_s32(124, 0)
	return pc
