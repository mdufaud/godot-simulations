class_name LfmSolver3D extends RefCounted

const SHADER_MAIN := "res://shaders/lfm/lfm_main.comp"
const SHADER_COMMON := "res://shaders/lfm/lfm_common.comp"
const WG := 256
const INIT := 0
const TMP := 1
const ERR := 2
const U := 3
const MID := 4
const PSI := 5
const T_MAP := 6
const PHI := 7
const F_MAP := 8
const SDF := 9
const SMOKE_INIT := 10
const SMOKE := 11
const SMOKE_TMP := 12
const SMOKE_ERR := 13
const B := 14
const PRESSURE := 15
const RESIDUAL := 16
const Z_FIELD := 17
const D_FIELD := 18
const AP := 19
const DIAG := 20
const BC_MASK := 21
const BC_VALUE := 22
const CENTER_PSI := 23
const CENTER_PHI := 24
const REDUCE := 25
const SCALARS := 26

var config: LfmConfig
var initialized := false
var method := 0
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _uniform_set := RID()
var _data := RID()
var _params := RID()
var _density := RID()
var _vorticity := RID()
var _density_prev := RID()
var _vorticity_prev := RID()
var _offsets: PackedInt32Array
var _faces := 0
var _cells := 0
var _floats := 0
var _frame := 0
var _last_frame_dt_s := 0.0
var _mg_dims: Array[Vector3i] = []
var _mg_offsets: Array[PackedInt32Array] = []
var _mg_enabled := true
var _lock := Mutex.new()
var _diagnostics := {}
var _timings := {}


func start(preset: LfmConfig, seed_velocity: Array[PackedFloat32Array] = [],
		seed_smoke: PackedFloat32Array = PackedFloat32Array(),
		seed_sdf: PackedFloat32Array = PackedFloat32Array()) -> void:
	var error := preset.validate()
	if error != "":
		push_error("LFM config: %s" % error)
		return
	config = preset.duplicate(true) as LfmConfig
	var sdf := seed_sdf if not seed_sdf.is_empty() else LfmShapes.cell_sdf(config)
	var x := seed_velocity[0] if seed_velocity.size() == 3 else LfmShapes.initial_velocity(config, 0)
	var y := seed_velocity[1] if seed_velocity.size() == 3 else LfmShapes.initial_velocity(config, 1)
	var z := seed_velocity[2] if seed_velocity.size() == 3 else LfmShapes.initial_velocity(config, 2)
	var smoke := seed_smoke if not seed_smoke.is_empty() else LfmShapes.initial_smoke(config)
	RenderingServer.call_on_render_thread(init_render.bind(sdf, x, y, z, smoke))


func step_frame(frame_dt_s: float = -1.0) -> void:
	if is_initialized():
		RenderingServer.call_on_render_thread(step_render.bind(
			config.frame_dt_s if frame_dt_s <= 0.0 else frame_dt_s))


func restart_preserving(next_config: LfmConfig) -> void:
	if next_config.validate() != "" or not is_initialized():
		return
	_lock.lock()
	initialized = false
	_lock.unlock()
	RenderingServer.call_on_render_thread(_restart_preserving_render.bind(
		next_config.duplicate(true)))


func set_method(next_method: int) -> void:
	RenderingServer.call_on_render_thread(_set_method_render.bind(clampi(next_method, 0, 1)))


func set_inlet(speed_mps: float, angle_deg: float) -> void:
	RenderingServer.call_on_render_thread(_set_inlet_render.bind(maxf(0.0, speed_mps), angle_deg))


func set_bfecc_clamp(enabled: bool) -> void:
	RenderingServer.call_on_render_thread(_set_bfecc_clamp_render.bind(enabled))


func set_multigrid(enabled: bool) -> void:
	RenderingServer.call_on_render_thread(_set_multigrid_render.bind(enabled))


func stop() -> void:
	RenderingServer.call_on_render_thread(free_render)


func is_initialized() -> bool:
	_lock.lock()
	var value := initialized
	_lock.unlock()
	return value


func get_display_texture_rid(view: int) -> RID:
	_lock.lock()
	var result := _density if view == 0 else _vorticity
	_lock.unlock()
	return result


func get_previous_display_texture_rid(view: int) -> RID:
	_lock.lock()
	var result := _density_prev if view == 0 else _vorticity_prev
	_lock.unlock()
	return result


func get_diagnostics() -> Dictionary:
	_lock.lock()
	var result := _diagnostics.duplicate()
	_lock.unlock()
	return result


func get_timings() -> Dictionary:
	_lock.lock()
	var result := _timings.duplicate()
	_lock.unlock()
	return result


func get_last_frame_dt_s() -> float:
	_lock.lock()
	var result := _last_frame_dt_s
	_lock.unlock()
	return result


func get_step_count() -> int:
	_lock.lock()
	var result := _frame
	_lock.unlock()
	return result


func get_map_sample() -> Dictionary:
	_lock.lock()
	var result: Dictionary = _diagnostics.get("map_sample", {}).duplicate()
	_lock.unlock()
	return result


func init_render(sdf: PackedFloat32Array, x: PackedFloat32Array,
		y: PackedFloat32Array, z: PackedFloat32Array, smoke: PackedFloat32Array) -> void:
	free_render()
	_rd = GpuPreflight.device("LfmSolver3D")
	if _rd == null:
		return
	var source := FileAccess.get_file_as_string(SHADER_MAIN)
	source = source.replace("#include \"lfm_common.comp\"",
		FileAccess.get_file_as_string(SHADER_COMMON))
	var spirv := ShaderCache.compile(_rd, "lfm_main", source)
	if not spirv.compile_error_compute.is_empty():
		push_error("LFM shader compile failed:\n%s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("LFM compute pipeline creation failed")
		return
	_build_layout()
	_data = _rd.storage_buffer_create(_floats * 4)
	var params := PackedInt32Array()
	params.resize(64 + _mg_dims.size() * 8)
	var d := config.grid_dims
	params[0] = d.x
	params[1] = d.y
	params[2] = d.z
	params[3] = (d.x + 1) * d.y * d.z
	params[4] = d.x * (d.y + 1) * d.z
	params[5] = d.x * d.y * (d.z + 1)
	params[6] = _faces
	params[7] = _cells
	params[8] = _floats
	params[9] = config.reinit_every
	params[10] = ceili(float(_cells) / WG)
	params[11] = _mg_dims.size()
	for slot in _offsets.size():
		params[16 + slot] = _offsets[slot]
	for level in _mg_dims.size():
		var dims: Vector3i = _mg_dims[level]
		params[64 + level * 8] = dims.x
		params[64 + level * 8 + 1] = dims.y
		params[64 + level * 8 + 2] = dims.z
		for field in 5:
			params[64 + level * 8 + 3 + field] = _mg_offsets[level][field]
	_params = _rd.storage_buffer_create(params.size() * 4, params.to_byte_array())
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = d.x
	fmt.height = d.y
	fmt.depth = d.z
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if config.interpolate_frames:
		fmt.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if not _rd.texture_is_format_supported_for_usage(fmt.format, fmt.usage_bits):
		push_error("LFM requires R32 3D storage/sampled textures")
		return
	_density = _rd.texture_create(fmt, RDTextureView.new(), [])
	_vorticity = _rd.texture_create(fmt, RDTextureView.new(), [])
	if config.interpolate_frames:
		_density_prev = _rd.texture_create(fmt, RDTextureView.new(), [])
		_vorticity_prev = _rd.texture_create(fmt, RDTextureView.new(), [])
	if not _data.is_valid() or not _params.is_valid() or not _density.is_valid() \
			or not _vorticity.is_valid() or (config.interpolate_frames \
			and (not _density_prev.is_valid() or not _vorticity_prev.is_valid())):
		push_error("LFM GPU resource allocation failed")
		return
	var uniforms: Array[RDUniform] = []
	for binding in 4:
		var uniform := RDUniform.new()
		uniform.binding = binding
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER \
			if binding < 2 else RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.add_id([_data, _params, _density, _vorticity][binding])
		uniforms.append(uniform)
	_uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _uniform_set.is_valid():
		push_error("LFM uniform set creation failed")
		return
	var cl := _rd.compute_list_begin()
	_dispatch(cl, 0, _floats)
	_rd.compute_list_end()
	_upload(INIT, 0, x)
	_upload(INIT, 1, y)
	_upload(INIT, 2, z)
	_rd.buffer_update(_data, _offsets[SDF] * 4, sdf.size() * 4, sdf.to_byte_array())
	_rd.buffer_update(_data, _offsets[SMOKE_INIT] * 4, smoke.size() * 4, smoke.to_byte_array())
	cl = _rd.compute_list_begin()
	_dispatch(cl, 1, _faces, 0, 0, 0, 0, 0, config.scenario)
	for level in _mg_dims.size():
		_dispatch(cl, 26, _mg_count(level), 0, 0, 0, 0, 0, 0, 0.0, level)
	_project(cl, INIT)
	_dispatch(cl, 23, _cells, INIT, 0, 0, 0, 0, config.scenario)
	_rd.compute_list_end()
	_frame = 0
	_lock.lock()
	initialized = true
	_last_frame_dt_s = 0.0
	_diagnostics = {"memory_bytes": _floats * 4 + params.size() * 4 \
		+ _cells * (16 if config.interpolate_frames else 8)}
	_lock.unlock()


func step_render(frame_dt_s: float) -> void:
	if not initialized:
		return
	_lock.lock()
	_last_frame_dt_s = frame_dt_s
	_lock.unlock()
	var timing := GpuTimings.read(_rd, "lfm/")
	if not timing.is_empty():
		_lock.lock()
		_timings = timing
		_lock.unlock()
	_rd.capture_timestamp("lfm/start")
	if config.interpolate_frames and _frame > 0:
		_copy_display_to_previous()
	var dt := frame_dt_s / config.reinit_every
	var cl := _rd.compute_list_begin()
	if method == 0:
		for s in config.reinit_every:
			var schedule := LfmLeapfrogSchedule.entry(s, config.reinit_every)
			var src: int = INIT if schedule.src == -1 else 100 + schedule.src
			var adv: int = INIT if schedule.last_proj == -1 else 100 + schedule.last_proj
			var dest := 100 + s
			_dispatch(cl, 2, _faces, src, dest, adv, 0, 0, 0,
				dt * float(schedule.dt_factor))
			_project(cl, dest)
	else:
		for s in config.reinit_every:
			_dispatch(cl, 2, _faces, INIT, U, INIT, 0, 0, 0, dt)
			_project(cl, U)
			_dispatch(cl, 17, _faces, U, INIT, U, 0, 0, 0, 0.0)
			_dispatch(cl, 22, _cells, SMOKE_INIT, SMOKE, INIT, 0, 0, 0, dt)
			_dispatch(cl, 21, _cells, SMOKE, SMOKE_INIT, SMOKE, 0, 0, 0, 0.0)
	_rd.compute_list_end()
	_rd.capture_timestamp("lfm/advance")
	if method == 0:
		cl = _rd.compute_list_begin()
		_march_maps(cl, dt)
		_rd.compute_list_end()
		_rd.capture_timestamp("lfm/maps")
		cl = _rd.compute_list_begin()
		_dispatch(cl, 16, _faces, INIT, U, 0, PSI, T_MAP)
		_dispatch(cl, 16, _faces, U, ERR, 0, PHI, F_MAP)
		_dispatch(cl, 17, _faces, ERR, ERR, INIT, 0, 0, 0, -1.0)
		_dispatch(cl, 16, _faces, ERR, TMP, 0, PSI, T_MAP)
		_dispatch(cl, 17, _faces, U, INIT, TMP, 0, 0, 0, -0.5)
		if config.bfecc_clamp:
			_dispatch(cl, 18, _faces, U, INIT)
		_project(cl, INIT)
		_dispatch(cl, 19, _cells, 0, CENTER_PSI, 0, PSI)
		_dispatch(cl, 19, _cells, 0, CENTER_PHI, 0, PHI)
		_dispatch(cl, 20, _cells, SMOKE_INIT, SMOKE, 0, CENTER_PSI)
		_dispatch(cl, 20, _cells, SMOKE, SMOKE_ERR, 0, CENTER_PHI)
		_dispatch(cl, 21, _cells, SMOKE_ERR, SMOKE_ERR, SMOKE_INIT, 0, 0, 0, -1.0)
		_dispatch(cl, 20, _cells, SMOKE_ERR, SMOKE_TMP, 0, CENTER_PSI)
		_dispatch(cl, 21, _cells, SMOKE, SMOKE_INIT, SMOKE_TMP, 0, 0, 0, -0.5)
		_rd.compute_list_end()
		_rd.capture_timestamp("lfm/reinit")
	cl = _rd.compute_list_begin()
	if config.scenario == LfmConfig.Scenario.WIND_TUNNEL:
		_dispatch(cl, 25, _cells)
	_dispatch(cl, 23, _cells, INIT, 0, 0, 0, 0, config.scenario)
	_rd.compute_list_end()
	if config.interpolate_frames and _frame == 0:
		_copy_display_to_previous()
	_rd.capture_timestamp("lfm/display")
	_rd.capture_timestamp("lfm/end")
	_lock.lock()
	_frame += 1
	_lock.unlock()


func march_seed_maps_render(velocity: Array[PackedFloat32Array]) -> void:
	if not initialized or velocity.size() != 3:
		return
	for s in config.reinit_every:
		for axis in 3:
			var d := config.grid_dims
			var face_offset := 0
			if axis >= 1:
				face_offset += (d.x + 1) * d.y * d.z
			if axis >= 2:
				face_offset += d.x * (d.y + 1) * d.z
			_rd.buffer_update(_data, (_offsets[MID] + s * _faces + face_offset) * 4,
				velocity[axis].size() * 4, velocity[axis].to_byte_array())
	var cl := _rd.compute_list_begin()
	_march_maps(cl, config.substep_dt_s())
	_rd.compute_list_end()


func _restart_preserving_render(next_config: LfmConfig) -> void:
	if _rd == null:
		return
	var velocity: Array[PackedFloat32Array] = []
	var d := config.grid_dims
	var face_offset := 0
	for length in [(d.x + 1) * d.y * d.z, d.x * (d.y + 1) * d.z,
		d.x * d.y * (d.z + 1)]:
		velocity.append(_rd.buffer_get_data(_data,
			(_offsets[INIT] + face_offset) * 4, length * 4).to_float32_array())
		face_offset += length
	var smoke := _rd.buffer_get_data(_data,
		_offsets[SMOKE_INIT] * 4, _cells * 4).to_float32_array()
	var sdf := _rd.buffer_get_data(_data,
		_offsets[SDF] * 4, _cells * 4).to_float32_array()
	config = next_config
	init_render(sdf, velocity[0], velocity[1], velocity[2], smoke)


func _march_maps(cl: int, dt: float) -> void:
	_dispatch(cl, 14, _faces, 0, 0, 0, PSI, T_MAP)
	_dispatch(cl, 14, _faces, 0, 0, 0, PHI, F_MAP)
	for i in range(config.reinit_every - 1, -1, -1):
		_dispatch(cl, 15, _faces, 100 + i, 0, 0, PSI, T_MAP,
			0 if config.map_rk4 else 1, dt)
	for i in config.reinit_every:
		_dispatch(cl, 15, _faces, 100 + i, 0, 0, PHI, F_MAP,
			0 if config.map_rk4 else 1, -dt)


func capture_diagnostics_render() -> void:
	if not initialized:
		return
	var rhs := _rd.buffer_get_data(_data, _offsets[B] * 4, _cells * 4).to_float32_array()
	var residual := _rd.buffer_get_data(_data,
		_offsets[RESIDUAL] * 4, _cells * 4).to_float32_array()
	var rhs_norm2 := 0.0
	var residual_norm2 := 0.0
	for i in rhs.size():
		rhs_norm2 += rhs[i] * rhs[i]
		residual_norm2 += residual[i] * residual[i]
	var cl := _rd.compute_list_begin()
	_dispatch(cl, 24, _cells, INIT)
	_rd.compute_list_end()
	var div := _rd.buffer_get_data(_data, _offsets[B] * 4, _cells * 4).to_float32_array()
	var vel := _rd.buffer_get_data(_data, _offsets[INIT] * 4, _faces * 4).to_float32_array()
	var smoke := _rd.buffer_get_data(_data, _offsets[SMOKE_INIT] * 4, _cells * 4).to_float32_array()
	var vorticity := _rd.buffer_get_data(_data,
		_offsets[SMOKE_ERR] * 4, _cells * 4).to_float32_array()
	var axial_vorticity := _rd.buffer_get_data(_data,
		_offsets[SMOKE_TMP] * 4, _cells * 4).to_float32_array()
	var max_div := 0.0
	var max_speed := 0.0
	var energy := 0.0
	var mass := 0.0
	var peak_vorticity := 0.0
	var mean_vorticity := 0.0
	var peak_axial_vorticity := 0.0
	var nonfinite := 0
	for value in div:
		if not is_finite(value):
			nonfinite += 1
		else:
			max_div = maxf(max_div, absf(value) / config.cell_size_m())
	for value in vel:
		if not is_finite(value):
			nonfinite += 1
		else:
			max_speed = maxf(max_speed, absf(value))
			energy += value * value
	for value in smoke:
		if not is_finite(value):
			nonfinite += 1
		else:
			mass += value
	for value in vorticity:
		if not is_finite(value):
			nonfinite += 1
		else:
			peak_vorticity = maxf(peak_vorticity, value)
			mean_vorticity += value
	for value in axial_vorticity:
		if not is_finite(value):
			nonfinite += 1
		else:
			peak_axial_vorticity = maxf(peak_axial_vorticity, absf(value))
	_lock.lock()
	_diagnostics["max_abs_div"] = max_div
	_diagnostics["normalized_max_div"] = max_div * config.cell_size_m() / maxf(max_speed, 1.0e-6)
	_diagnostics["kinetic_energy"] = 0.5 * energy * config.cell_size_m() ** 3
	_diagnostics["smoke_mass"] = mass * config.cell_size_m() ** 3
	_diagnostics["peak_vorticity"] = peak_vorticity
	_diagnostics["mean_vorticity"] = mean_vorticity / _cells
	_diagnostics["peak_axial_vorticity"] = peak_axial_vorticity
	_diagnostics["nonfinite"] = nonfinite
	_diagnostics["cg_relative_residual"] = sqrt(residual_norm2 / maxf(rhs_norm2, 1.0e-30))
	_diagnostics["frame"] = _frame
	_diagnostics["last_frame_dt_s"] = _last_frame_dt_s
	_lock.unlock()


func capture_map_sample_render(axis: int, c: Vector3i) -> void:
	if not initialized:
		return
	var d := config.grid_dims
	var id := 0
	var position := Vector3.ZERO
	if axis == 0:
		id = (c.x * d.y + c.y) * d.z + c.z
		position = Vector3(c.x, c.y + 0.5, c.z + 0.5)
	elif axis == 1:
		id = (d.x + 1) * d.y * d.z + (c.x * (d.y + 1) + c.y) * d.z + c.z
		position = Vector3(c.x + 0.5, c.y, c.z + 0.5)
	else:
		id = (d.x + 1) * d.y * d.z + d.x * (d.y + 1) * d.z \
			+ (c.x * d.y + c.y) * (d.z + 1) + c.z
		position = Vector3(c.x + 0.5, c.y + 0.5, c.z)
	var result := {"position": position * config.cell_size_m()}
	for entry in [[PSI, "psi"], [T_MAP, "T"], [PHI, "phi"], [F_MAP, "F"]]:
		var values := _rd.buffer_get_data(_data,
			(_offsets[int(entry[0])] + id * 4) * 4, 16).to_float32_array()
		result[str(entry[1])] = Vector3(values[0], values[1], values[2])
	_lock.lock()
	_diagnostics["map_sample"] = result
	_lock.unlock()


func _copy_display_to_previous() -> void:
	_rd.texture_copy(_density, _density_prev, Vector3.ZERO, Vector3.ZERO,
		Vector3(config.grid_dims), 0, 0, 0, 0)
	_rd.texture_copy(_vorticity, _vorticity_prev, Vector3.ZERO, Vector3.ZERO,
		Vector3(config.grid_dims), 0, 0, 0, 0)


func free_render() -> void:
	_lock.lock()
	initialized = false
	_lock.unlock()
	if _rd == null:
		return
	for rid in [_uniform_set, _data, _params, _density, _vorticity,
			_density_prev, _vorticity_prev, _pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_uniform_set = RID()
	_data = RID()
	_params = RID()
	_density = RID()
	_vorticity = RID()
	_density_prev = RID()
	_vorticity_prev = RID()
	_pipeline = RID()
	_shader = RID()
	_rd = null


func _build_layout() -> void:
	var d := config.grid_dims
	_cells = d.x * d.y * d.z
	_faces = (d.x + 1) * d.y * d.z + d.x * (d.y + 1) * d.z \
		+ d.x * d.y * (d.z + 1)
	var lengths := PackedInt32Array()
	lengths.resize(SCALARS + 1)
	for slot in [INIT, TMP, ERR, U, BC_MASK, BC_VALUE]:
		lengths[slot] = _faces
	lengths[MID] = _faces * config.reinit_every
	for slot in [PSI, T_MAP, PHI, F_MAP]:
		lengths[slot] = _faces * 4
	for slot in [SDF, SMOKE_INIT, SMOKE, SMOKE_TMP, SMOKE_ERR, B,
			PRESSURE, RESIDUAL, Z_FIELD, D_FIELD, AP, DIAG]:
		lengths[slot] = _cells
	lengths[CENTER_PSI] = _cells * 4
	lengths[CENTER_PHI] = _cells * 4
	lengths[REDUCE] = ceili(float(_cells) / WG)
	lengths[SCALARS] = 8
	_offsets.resize(lengths.size())
	_floats = 0
	for slot in lengths.size():
		_offsets[slot] = _floats
		_floats += lengths[slot]
	_mg_dims.clear()
	_mg_offsets.clear()
	var level_dims := d
	while true:
		_mg_dims.append(level_dims)
		var level_offsets := PackedInt32Array()
		level_offsets.resize(5)
		for field in 5:
			level_offsets[field] = _floats
			_floats += level_dims.x * level_dims.y * level_dims.z
		_mg_offsets.append(level_offsets)
		if mini(level_dims.x, mini(level_dims.y, level_dims.z)) <= 4 \
				or level_dims.x % 2 != 0 or level_dims.y % 2 != 0 \
				or level_dims.z % 2 != 0:
			break
		level_dims /= 2


func _upload(slot: int, axis: int, values: PackedFloat32Array) -> void:
	var d := config.grid_dims
	var face_offset := 0
	if axis >= 1:
		face_offset += (d.x + 1) * d.y * d.z
	if axis >= 2:
		face_offset += d.x * (d.y + 1) * d.z
	_rd.buffer_update(_data, (_offsets[slot] + face_offset) * 4,
		values.size() * 4, values.to_byte_array())


func _dispatch(cl: int, mode_id: int, count: int, src: int = 0, dst: int = 0,
		aux: int = 0, map_slot: int = 0, t_slot: int = 0, flags: int = 0,
		dt: float = 0.0, level: int = 0) -> void:
	var pc := PackedByteArray()
	pc.resize(48)
	for i in 8:
		pc.encode_s32(i * 4, [mode_id, level, src, dst, aux, map_slot, t_slot, flags][i])
	pc.encode_float(32, dt)
	pc.encode_float(36, config.cell_size_m())
	pc.encode_float(40, config.inlet_speed_mps * cos(deg_to_rad(config.inlet_angle_deg)))
	pc.encode_float(44, config.inlet_speed_mps * sin(deg_to_rad(config.inlet_angle_deg)))
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, maxi(1, ceili(float(count) / WG)), 1, 1)
	_rd.compute_list_add_barrier(cl)


func _dot(cl: int, left: int, right: int, scalar_index: int) -> void:
	_dispatch(cl, 7, _cells, left, right)
	_dispatch(cl, 8, 1, 0, 0, scalar_index)


func _project(cl: int, velocity_slot: int) -> void:
	_dispatch(cl, 3, _faces, 0, velocity_slot)
	_dispatch(cl, 4, _cells, velocity_slot)
	_dispatch(cl, 5, _cells)
	if _mg_enabled:
		_mg_precondition(cl)
		_dispatch(cl, 34, _cells)
	_dot(cl, RESIDUAL, Z_FIELD, 0)
	for iteration in (16 if _mg_enabled else 40):
		_dispatch(cl, 6, _cells, D_FIELD, AP)
		_dot(cl, D_FIELD, AP, 1)
		_dispatch(cl, 9, 1)
		_dispatch(cl, 10, _cells, 0, 0, 0, 0, 0, 1 if _mg_enabled else 0)
		if _mg_enabled:
			_mg_precondition(cl)
		_dot(cl, RESIDUAL, Z_FIELD, 3)
		_dispatch(cl, 11, 1)
		_dispatch(cl, 12, _cells)
	_dispatch(cl, 13, _faces, 0, velocity_slot)


func _mg_precondition(cl: int) -> void:
	for level in _mg_dims.size():
		_dispatch(cl, 27, _mg_count(level), 0, 0, 0, 0, 0, 0, 0.0, level)
	for level in _mg_dims.size() - 1:
		_mg_smooth(cl, level, 2)
		_dispatch(cl, 30, _mg_count(level), 0, 0, 0, 0, 0, 0, 0.0, level)
		_dispatch(cl, 31, _mg_count(level + 1), 0, 0, 0, 0, 0, 0, 0.0, level + 1)
	_mg_smooth(cl, _mg_dims.size() - 1, 16)
	for level in range(_mg_dims.size() - 2, -1, -1):
		_dispatch(cl, 32, _mg_count(level), 0, 0, 0, 0, 0, 0, 0.0, level)
		_mg_smooth(cl, level, 2)
	_dispatch(cl, 33, _cells)


func _mg_smooth(cl: int, level: int, passes: int) -> void:
	for i in passes:
		_dispatch(cl, 28, _mg_count(level), 4 + i % 2, 5 - i % 2,
			0, 0, 0, 0, 0.0, level)


func _mg_count(level: int) -> int:
	var d: Vector3i = _mg_dims[level]
	return d.x * d.y * d.z


func _set_method_render(next_method: int) -> void:
	method = next_method


func _set_inlet_render(speed_mps: float, angle_deg: float) -> void:
	if config == null:
		return
	config.inlet_speed_mps = speed_mps
	config.inlet_angle_deg = angle_deg
	if initialized:
		var cl := _rd.compute_list_begin()
		_dispatch(cl, 1, _faces, 0, 0, 0, 0, 0, config.scenario)
		_rd.compute_list_end()


func _set_bfecc_clamp_render(enabled: bool) -> void:
	if config != null:
		config.bfecc_clamp = enabled


func _set_multigrid_render(enabled: bool) -> void:
	_mg_enabled = enabled
