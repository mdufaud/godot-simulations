class_name NBodySolver
extends RefCounted
## GPU N-body solver. DKD leapfrog, two interchangeable paths: attractors only
## (O(N*K), 1M particles, whole frame merged into one dispatch) or tiled
## self-gravity (O(N^2), ~32k, force/integrate split by a global barrier).

const SHADER_DIR := "res://shaders/nbody/"
const STAGES: Array[String] = ["step_attractors", "force_tiled", "integrate"]
const WG := 256
const MAX_ATTRACTORS := 64
const MAX_SUBSTEPS := 32
const SOURCE_SAMPLE_COUNT := MAX_SUBSTEPS * 2 + 1
const SOURCE_STRIDE_FLOATS := MAX_ATTRACTORS * 8 + 4
const SELF_GRAVITY_BIT := 1 << 30

var config: NBodyConfig = NBodyConfig.new()
var particle_count := 262144
var tex_width := 512
var dt := 0.004
var substeps := 2
var gravity_constant := 1.0
var softening := 0.12
var attractor_softening := 0.04
var escape_radius := 160.0
var v_ref := 0.6
var disk_mass := 0.35
var disk_r_min := 3.0
var disk_r_max := 40.0
var disk_thickness := 0.35
var dispersion := 0.04
var self_gravity := false
var respawn_mode := 0
## step_attractors.comp force law: 0 = attractor/disk gravity, 1 = vortex, 2 = firework.
var force_mode := 0
var jet_speed := 3.0
var axis_dir := Vector3.UP
var axis_spread := 0.15
var vortex_updraft_mps := 0.0
var vortex_swirl_mps := 0.0
var vortex_turbulence_mps2 := 0.0
var vortex_downdraft_ratio := 0.6
var firework_period_s := 0.0
var firework_spread_m := 0.0
var firework_speed_min_mps := 0.0
var firework_gravity_mps2 := 0.0
var firework_speed_max_mps := 0.0
var firework_rocket_groups := 1.0
var firework_drag := 1.1
var random_seed := 0
var sim_time := 0.0

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _tex_rid := RID()
var _seed_pos := PackedFloat32Array()
var _seed_vel := PackedFloat32Array()
var _attractor_data := PackedFloat32Array()
var _attractor_count := 0
var _frame := 0
var _timing_store := GpuTimingStore.new()


func get_position_tex_rid() -> RID:
	return _tex_rid


func set_seed(pos: PackedFloat32Array, vel: PackedFloat32Array) -> void:
	_seed_pos = pos
	_seed_vel = vel


## list: [{pos: Vector3, vel: Vector3, mass: float, radius: float}, ...]
func set_attractors(list: Array) -> void:
	var n := mini(list.size(), MAX_ATTRACTORS)
	_attractor_count = n
	_attractor_data.resize(MAX_ATTRACTORS * 8)
	_attractor_data.fill(0.0)
	for i in n:
		var a: Dictionary = list[i]
		var p: Vector3 = a.pos
		var v: Vector3 = a.vel
		_attractor_data[i * 8] = p.x
		_attractor_data[i * 8 + 1] = p.y
		_attractor_data[i * 8 + 2] = p.z
		_attractor_data[i * 8 + 3] = a.mass
		_attractor_data[i * 8 + 4] = v.x
		_attractor_data[i * 8 + 5] = v.y
		_attractor_data[i * 8 + 6] = v.z
		_attractor_data[i * 8 + 7] = a.radius


func init_render() -> void:
	var config_error := validate()
	if config_error != "":
		push_error("N-body config: %s" % config_error)
		return
	_rd = GpuPreflight.device("NBodySolver")
	if _rd == null:
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "nbody_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "nbody_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "nbody_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("N-body stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	var n := particle_count
	var vec4_bytes := n * 16
	var pos_bytes := _seed_pos.to_byte_array()
	var vel_bytes := _seed_vel.to_byte_array()
	if pos_bytes.size() != vec4_bytes or vel_bytes.size() != vec4_bytes:
		push_error("N-body seed size mismatch: %d/%d != %d" % [
			pos_bytes.size(), vel_bytes.size(), vec4_bytes,
		])
		return
	if tex_width * tex_width < n:
		push_error("N-body tex_width %d too small for %d particles" % [tex_width, n])
		return
	var zero_vec4 := PackedByteArray()
	zero_vec4.resize(vec4_bytes)
	var source_data := PackedFloat32Array()
	source_data.resize(SOURCE_STRIDE_FLOATS * SOURCE_SAMPLE_COUNT)
	source_data.fill(0.0)
	for i in _attractor_data.size():
		source_data[i] = _attractor_data[i]
	source_data[MAX_ATTRACTORS * 8] = axis_dir.x
	source_data[MAX_ATTRACTORS * 8 + 1] = axis_dir.y
	source_data[MAX_ATTRACTORS * 8 + 2] = axis_dir.z

	_buffers["positions"] = _rd.storage_buffer_create(vec4_bytes, pos_bytes)
	_buffers["velocities"] = _rd.storage_buffer_create(vec4_bytes, vel_bytes)
	_buffers["accels"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["attractors"] = _rd.storage_buffer_create(
		source_data.size() * 4, source_data.to_byte_array()
	)

	var fmt := RDTextureFormat.new()
	fmt.width = tex_width
	fmt.height = tex_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_tex_rid = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(_tex_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var order := ["positions", "velocities", "accels", "attractors"]
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

	_frame = random_seed
	initialized = true
	_publish_seed_render()


func make_step_constants(step_dt: float, step_time: float, step_count: int = -1) -> PackedByteArray:
	return _pack_push_constant(step_dt, substeps if step_count < 0 else step_count, step_time)


func pack_attractor_samples(samples: Array, axes: Array[Vector3]) -> PackedFloat32Array:
	if samples.is_empty() or samples.size() > SOURCE_SAMPLE_COUNT \
			or samples.size() % 2 == 0 or axes.size() != samples.size():
		return PackedFloat32Array()
	var data := PackedFloat32Array()
	data.resize(samples.size() * SOURCE_STRIDE_FLOATS)
	data.fill(0.0)
	for sample_index in samples.size():
		var sample: Array = samples[sample_index]
		var base := sample_index * SOURCE_STRIDE_FLOATS
		for i in mini(sample.size(), MAX_ATTRACTORS):
			var a: Dictionary = sample[i]
			var p: Vector3 = a.pos
			var v: Vector3 = a.vel
			var offset := base + i * 8
			data[offset] = p.x
			data[offset + 1] = p.y
			data[offset + 2] = p.z
			data[offset + 3] = a.mass
			data[offset + 4] = v.x
			data[offset + 5] = v.y
			data[offset + 6] = v.z
			data[offset + 7] = a.radius
		var axis := axes[sample_index]
		var axis_offset := base + MAX_ATTRACTORS * 8
		data[axis_offset] = axis.x
		data[axis_offset + 1] = axis.y
		data[axis_offset + 2] = axis.z
	return data


func step_render(constants: PackedByteArray, source_samples: PackedFloat32Array,
		frame_advance: int = 1) -> void:
	if not initialized:
		return
	frame_advance = maxi(frame_advance, 1)
	_read_timings()
	if constants.size() != 128:
		push_error("N-body step snapshot must contain 128 bytes of constants")
		return
	var steps := constants.decode_s32(64)
	var count := constants.decode_s32(16)
	var sample_count := steps * 2 + 1
	if steps < 0 or steps > MAX_SUBSTEPS \
			or source_samples.size() != sample_count * SOURCE_STRIDE_FLOATS:
		push_error("N-body step snapshot has inconsistent constants or attractor samples")
		return
	var pc := constants.duplicate()
	var frame_index := _frame
	if pc.decode_s32(72) == 2:
		frame_index += frame_advance - 1
	pc.encode_s32(28, frame_index)
	_rd.buffer_update(_buffers["attractors"], 0, source_samples.size() * 4,
		source_samples.to_byte_array())
	var groups := ceili(float(count) / WG)
	var meta := pc.decode_s32(76)
	var use_pair_gravity := (meta & SELF_GRAVITY_BIT) != 0 \
		and pc.decode_s32(72) == 0 and steps > 0

	_rd.capture_timestamp("nbody/start")
	var cl := _rd.compute_list_begin()
	if use_pair_gravity:
		for s in steps:
			var phase_pc := pc.duplicate()
			phase_pc.encode_s32(76, SELF_GRAVITY_BIT | (s << 1))
			_dispatch(cl, "integrate", phase_pc, groups)
			cl = _mark(cl, "nbody/integrate")
			phase_pc.encode_s32(76, SELF_GRAVITY_BIT | (s << 1) | 1)
			_dispatch(cl, "force_tiled", phase_pc, groups)
			cl = _mark(cl, "nbody/force")
			_dispatch(cl, "integrate", phase_pc, groups)
			cl = _mark(cl, "nbody/integrate")
	else:
		# Test-particle, vortex and analytic paths stay fused in one dispatch.
		_dispatch(cl, "step_attractors", pc, groups)
		cl = _mark(cl, "nbody/step")
	_rd.compute_list_end()
	_rd.capture_timestamp("nbody/end")
	_frame += frame_advance


func _publish_seed_render() -> void:
	var pc := _pack_push_constant(0.0, 0, sim_time)
	var groups := ceili(float(particle_count) / WG)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "step_attractors", pc, groups)
	_rd.compute_list_end()


# Timestamps cannot be captured inside an open compute list; split the list
# at stage boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Reads last frame's timestamps.
func _read_timings() -> void:
	var out := GpuTimings.read(_rd, "nbody/")
	if out.is_empty():
		return
	_timing_store.publish(out)


# Main thread. GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	return _timing_store.snapshot()


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


func _pack_push_constant(step_dt: float, step_count: int, step_time: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, step_dt)
	pc.encode_float(4, gravity_constant)
	pc.encode_float(8, softening * softening)
	pc.encode_float(12, attractor_softening * attractor_softening)
	pc.encode_s32(16, particle_count)
	pc.encode_s32(20, _attractor_count)
	pc.encode_s32(24, tex_width)
	pc.encode_s32(28, _frame)
	pc.encode_float(32, escape_radius)
	pc.encode_float(36, 1.0 / maxf(v_ref, 1e-4))
	pc.encode_float(40, disk_mass)
	pc.encode_float(44, jet_speed)
	pc.encode_float(48, disk_r_min)
	pc.encode_float(52, disk_r_max)
	pc.encode_float(56, disk_thickness)
	pc.encode_float(60, dispersion)
	pc.encode_s32(64, step_count)
	pc.encode_s32(68, respawn_mode)
	pc.encode_s32(72, force_mode)
	pc.encode_float(80, axis_dir.x)
	pc.encode_float(84, axis_dir.y)
	pc.encode_float(88, axis_dir.z)
	pc.encode_float(92, firework_drag if force_mode == 2 else axis_spread)
	pc.encode_float(96, float(substeps))
	pc.encode_float(100, vortex_updraft_mps if force_mode == 1 else firework_period_s)
	pc.encode_float(104, vortex_swirl_mps if force_mode == 1 else firework_spread_m)
	pc.encode_float(108, step_time)
	pc.encode_float(112, vortex_turbulence_mps2 if force_mode == 1 else firework_speed_min_mps)
	pc.encode_float(116, 0.0 if force_mode == 1 else firework_gravity_mps2)
	pc.encode_float(120, 0.0 if force_mode == 1 else firework_speed_max_mps)
	pc.encode_float(124, vortex_downdraft_ratio if force_mode == 1 else firework_rocket_groups)
	pc.encode_s32(76, SELF_GRAVITY_BIT if self_gravity else (
		random_seed if force_mode == 2 else 0))
	return pc


func validate() -> String:
	config.particle_count = particle_count
	config.texture_width = tex_width
	config.self_gravity = self_gravity
	config.time_step_s = dt
	config.substeps = substeps
	if substeps > MAX_SUBSTEPS:
		return "substeps exceed the N-body limit of %d" % MAX_SUBSTEPS
	return config.validate()
