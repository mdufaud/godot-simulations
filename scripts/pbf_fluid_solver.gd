class_name PbfFluidSolver
extends RefCounted

const SHADER_DIR := "res://shaders/pbf/"
const STAGES: Array[String] = [
	"predict", "grid_clear", "grid_count", "grid_scan", "grid_scan_blocks",
	"grid_add_back", "grid_scatter", "lambda", "delta", "apply",
	"finalize", "vorticity_omega", "vorticity_apply", "viscosity", "write_tex",
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

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _tex_rid := RID()
var _inv_rest_density := 1.0
var _seed_data := PackedFloat32Array()


func get_position_tex_rid() -> RID:
	return _tex_rid


func set_seed_positions(seed: PackedFloat32Array) -> void:
	_seed_data = seed


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	_inv_rest_density = 1.0 / _compute_rest_density()

	var common := FileAccess.get_file_as_string(SHADER_DIR + "pbf_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "pbf_" + stage + ".comp")
		var src := RDShaderSource.new()
		src.source_compute = "#version 450\n\n" + common + "\n" + stage_src
		var spirv := _rd.shader_compile_spirv_from_source(src)
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

	_buffers["positions"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["velocities"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["predicted"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["lambdas"] = _rd.storage_buffer_create(n * 4, zero_f)
	_buffers["deltas"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["cell_count"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["cell_start"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["block_sums"] = _rd.storage_buffer_create(num_blocks * 4, zero_blocks)
	_buffers["sorted_indices"] = _rd.storage_buffer_create(n * 4, zero_f)
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

	var buffer_order: Array[String] = [
		"positions", "velocities", "predicted", "lambdas", "deltas",
		"cell_count", "cell_start", "block_sums", "sorted_indices", "densities",
	]
	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		for bi in buffer_order.size():
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = bi
			u.add_id(_buffers[buffer_order[bi]])
			uniforms.append(u)
		var tex_u := RDUniform.new()
		tex_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		tex_u.binding = 10
		tex_u.add_id(_tex_rid)
		uniforms.append(tex_u)
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)

	initialized = true


func step_render(dt: float) -> void:
	if not initialized:
		return
	var pc := _pack_push_constant(dt)
	var n_groups := ceili(float(particle_count) / WG)
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var cell_groups := ceili(float(cells) / WG)

	var cl := _rd.compute_list_begin()
	_dispatch(cl, "predict", pc, n_groups)
	_dispatch(cl, "grid_clear", pc, cell_groups)
	_dispatch(cl, "grid_count", pc, n_groups)
	_dispatch(cl, "grid_scan", pc, cell_groups)
	_dispatch(cl, "grid_scan_blocks", pc, 1)
	_dispatch(cl, "grid_add_back", pc, cell_groups)
	_dispatch(cl, "grid_clear", pc, cell_groups)
	_dispatch(cl, "grid_scatter", pc, n_groups)
	for _iter in solver_iterations:
		_dispatch(cl, "lambda", pc, n_groups)
		_dispatch(cl, "delta", pc, n_groups)
		_dispatch(cl, "apply", pc, n_groups)
	_dispatch(cl, "finalize", pc, n_groups)
	if vorticity_eps > 0.0:
		_dispatch(cl, "vorticity_omega", pc, n_groups)
		_dispatch(cl, "vorticity_apply", pc, n_groups)
	_dispatch(cl, "viscosity", pc, n_groups)
	_dispatch(cl, "write_tex", pc, n_groups)
	_rd.compute_list_end()


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
