class_name PbfFluidSolver
extends RefCounted

const SHADER_DIR := "res://shaders/pbf/"
const SHARED_GRID_DIR := "res://shaders/fluid/"
const GRID_STAGES := ["grid_clear", "grid_scan", "grid_scan_blocks", "grid_add_back"]
const STAGES: Array[String] = [
	"grid_clear", "predict", "grid_scan", "grid_scan_blocks",
	"grid_add_back", "grid_scatter", "lambda", "delta", "apply",
	"vorticity_omega", "vorticity_apply", "viscosity",
]
const WG := 256

var particle_count := 65536
var grid_dims := Vector3i(64, 64, 64)
var grid_origin := Vector3(-8.0, 0.0, -8.0)
var cell_size := 0.25
var h := 0.25
var spacing := 0.12
var epsilon := 100.0
var scorr_k := 0.001
var scorr_dq := 0.3
var xsph_c := 0.05
var vorticity_eps := 0.02
var gravity := Vector3(0.0, -9.8, 0.0)
var solver_iterations := 3
var mode := 0.0

var tex_width := 256
var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _tex_rid := RID()
var _inv_rest_density := 1.0
var _seed_data := PackedFloat32Array()
var _parity := 0
var _timings := {}
var _timings_mutex := Mutex.new()


func get_position_tex_rid() -> RID:
	return _tex_rid


func set_seed_positions(seed: PackedFloat32Array) -> void:
	_seed_data = seed


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	_inv_rest_density = 1.0 / _compute_rest_density()

	var common := FileAccess.get_file_as_string(SHADER_DIR + "pbf_common.comp")
	for stage in STAGES:
		var stage_dir := SHARED_GRID_DIR if GRID_STAGES.has(stage) else SHADER_DIR
		var stage_name := stage if GRID_STAGES.has(stage) else "pbf_" + stage
		var stage_src := FileAccess.get_file_as_string(stage_dir + stage_name + ".comp")
		var spirv := ShaderCache.compile(_rd, "pbf_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("PBF stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	var n := particle_count
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var num_blocks := ceili(float(cells) / WG)
	var vec4_bytes := n * 16
	var zero_vec4 := PackedByteArray()
	zero_vec4.resize(vec4_bytes)
	var zero_f := PackedByteArray()
	zero_f.resize(n * 4)
	var zero_cells := PackedByteArray()
	zero_cells.resize(cells * 4)
	var zero_blocks := PackedByteArray()
	zero_blocks.resize(num_blocks * 4)

	var seed_bytes := _seed_data.to_byte_array()
	if seed_bytes.size() != vec4_bytes:
		push_error("PBF seed size mismatch: %d != %d" % [seed_bytes.size(), vec4_bytes])
		return

	_buffers["positions_a"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["positions_b"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["velocities"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["predicted_a"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["predicted_b"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["lambdas"] = _rd.storage_buffer_create(n * 4, zero_f)
	_buffers["deltas"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["cell_count"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["cell_start"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["block_sums"] = _rd.storage_buffer_create(num_blocks * 4, zero_blocks)
	_buffers["densities"] = _rd.storage_buffer_create(n * 4, zero_f)

	var fmt := RDTextureFormat.new()
	fmt.width = tex_width
	fmt.height = tex_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_tex_rid = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(_tex_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	# Bindings 0/2 = src (canonical order), 8/11 = dst (cell-sorted this frame);
	# parity swaps src and dst each step.
	var binding_orders := [
		["positions_a", "velocities", "predicted_a", "lambdas", "deltas",
			"cell_count", "cell_start", "block_sums", "positions_b", "densities",
			"", "predicted_b"],
		["positions_b", "velocities", "predicted_b", "lambdas", "deltas",
			"cell_count", "cell_start", "block_sums", "positions_a", "densities",
			"", "predicted_a"],
	]
	for stage in STAGES:
		var sets := []
		for parity in 2:
			var uniforms: Array[RDUniform] = []
			var order: Array = binding_orders[parity]
			for bi in order.size():
				var u := RDUniform.new()
				if bi == 10:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
					u.add_id(_tex_rid)
				else:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
					u.add_id(_buffers[order[bi]])
				u.binding = bi
				uniforms.append(u)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_uniform_sets[stage] = sets

	_parity = 0
	initialized = true


func step_render(dt: float) -> void:
	if not initialized:
		return
	_read_timings()
	var pc := _pack_push_constant(dt)
	var pc_last := _pack_push_constant(dt)
	pc_last.encode_s32(104, 1)
	var n_groups := ceili(float(particle_count) / WG)
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var cell_groups := ceili(float(cells) / WG)

	_rd.capture_timestamp("pbf/start")
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "grid_clear", pc, cell_groups)
	_dispatch(cl, "predict", pc, n_groups)
	_dispatch(cl, "grid_scan", pc, cell_groups)
	_dispatch(cl, "grid_scan_blocks", pc, 1)
	_dispatch(cl, "grid_add_back", pc, cell_groups)
	_dispatch(cl, "grid_scatter", pc, n_groups)
	cl = _mark(cl, "pbf/grid")
	for _iter in solver_iterations:
		_dispatch(cl, "lambda", pc, n_groups)
		cl = _mark(cl, "pbf/lambda")
		_dispatch(cl, "delta", pc, n_groups)
		cl = _mark(cl, "pbf/delta")
		var last := _iter == solver_iterations - 1
		_dispatch(cl, "apply", pc_last if last else pc, n_groups)
		cl = _mark(cl, "pbf/apply")
	if vorticity_eps > 0.0:
		_dispatch(cl, "vorticity_omega", pc, n_groups)
		_dispatch(cl, "vorticity_apply", pc, n_groups)
	_dispatch(cl, "viscosity", pc, n_groups)
	_rd.compute_list_end()
	_rd.capture_timestamp("pbf/end")
	_parity = 1 - _parity


# Timestamps cannot be captured inside an open compute list; split the list
# at group boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Reads last frame's timestamps: each pbf/* marker closes the
# segment started by the previous pbf/* marker; repeated names sum across iterations.
func _read_timings() -> void:
	var out := {}
	var prev_time := 0
	var start_time := 0
	var in_chain := false
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if not nm.begins_with("pbf/"):
			continue
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if nm == "pbf/start":
			start_time = t
			prev_time = t
			in_chain = true
			continue
		if not in_chain:
			continue
		var seg := nm.trim_prefix("pbf/")
		if seg == "end":
			out["total"] = float(t - start_time) / 1e6
			if profiling:
				out["post"] = out.get("post", 0.0) + float(t - prev_time) / 1e6
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
		for s in _uniform_sets[stage]:
			if s.is_valid():
				_rd.free_rid(s)
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
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage][_parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(dt: float) -> PackedByteArray:
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var num_blocks := ceili(float(cells) / WG)
	var h2 := h * h
	var poly6_c := 315.0 / (64.0 * PI * pow(h, 9))
	var spiky_c := -45.0 / (PI * pow(h, 6))
	var dq := scorr_dq * h
	var w_dq := poly6_c * pow(h2 - dq * dq, 3)

	var pc := PackedByteArray()
	pc.resize(112)
	pc.encode_float(0, grid_origin.x)
	pc.encode_float(4, grid_origin.y)
	pc.encode_float(8, grid_origin.z)
	pc.encode_float(12, cell_size)
	pc.encode_s32(16, grid_dims.x)
	pc.encode_s32(20, grid_dims.y)
	pc.encode_s32(24, grid_dims.z)
	pc.encode_s32(28, particle_count)
	pc.encode_float(32, h)
	pc.encode_float(36, h2)
	pc.encode_float(40, poly6_c)
	pc.encode_float(44, spiky_c)
	pc.encode_float(48, dt)
	pc.encode_float(52, 1.0 / dt)
	pc.encode_float(56, epsilon)
	pc.encode_float(60, _inv_rest_density)
	pc.encode_float(64, scorr_k)
	pc.encode_float(68, 1.0 / w_dq)
	pc.encode_float(72, vorticity_eps)
	pc.encode_float(76, xsph_c)
	pc.encode_float(80, gravity.x)
	pc.encode_float(84, gravity.y)
	pc.encode_float(88, gravity.z)
	pc.encode_float(92, mode)
	pc.encode_s32(96, tex_width)
	pc.encode_s32(100, num_blocks)
	pc.encode_s32(104, 0)
	pc.encode_s32(108, 0)
	return pc


func _compute_rest_density() -> float:
	var poly6_c := 315.0 / (64.0 * PI * pow(h, 9))
	var h2 := h * h
	var sum := 0.0
	var steps := int(ceil(h / spacing))
	for x in range(-steps, steps + 1):
		for y in range(-steps, steps + 1):
			for z in range(-steps, steps + 1):
				var r2 := (Vector3(x, y, z) * spacing).length_squared()
				if r2 < h2:
					sum += poly6_c * pow(h2 - r2, 3)
	return sum
