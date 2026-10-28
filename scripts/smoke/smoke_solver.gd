class_name SmokeSolver
extends RefCounted
## GPU stable-fluids smoke (Stam 1999) on a dense MAC grid (velocity on cell
## faces): RK2 semi-Lagrangian or MacCormack advection, buoyancy, vorticity
## confinement, multigrid pressure projection, plus a per-frame
## transmittance volume toward the sun and the zenith for self-shadowing.
##
## Owns every RenderingDevice resource of the grid. The host assigns [member config],
## feeds emitters and obstacles each frame, and binds [method density_texture_rid]
## and [method light_texture_rid] to a renderer once [method is_ready].
##
## [codeblock]
## var solver := SmokeSolver.new()
## solver.config = preset.config.duplicate()
## solver.start()
## # each frame:
## solver.set_sources(packed_emitters)
## solver.set_obstacles(packed_bodies)
## solver.light_direction = sun.global_basis.z
## solver.advance(clock.advance(delta))
## # teardown:
## solver.stop()
## [/codeblock]

const SHADER_DIR := "res://shaders/smoke/"
const STAGES: Array[String] = ["obstacles", "advect", "maccormack", "forces", "curl",
	"vorticity", "divergence", "project", "light", "mg_smooth", "mg_restrict", "mg_prolong"]
## Binding of the per-level parameters (smoke_mg_common.comp) in each multigrid stage.
const MG_LEVELS_BINDING := {"mg_smooth": 2, "mg_restrict": 4, "mg_prolong": 4}
const WG := Vector3i(8, 8, 4)
const MAX_SOURCES := 16
const MAX_OBSTACLES := 32
const SOURCE_VEC4S := 4
const OBSTACLE_VEC4S := 7
const OBSTACLE_SPHERE := 0
const OBSTACLE_BOX := 1
const PUSH_CONSTANT_BYTES := 112
## Multigrid V-cycle: red-black sweeps before and after each coarse correction,
## sweeps on the coarsest level, and the size below which no level is added.
const MG_PRE_SWEEPS := 2
const MG_POST_SWEEPS := 2
const MG_COARSE_SWEEPS := 16
const MG_MIN_DIM := 4
## Coarse levels' pressure (R32F) and right-hand side (RG32F): 12 B per cell,
## an eighth per level, rounded up per fine cell.
const MG_BYTES_PER_CELL := 2
## Full-resolution fields and their float32 channels; "light" is the downsampled extra.
## A velocity field is one texture per axis and binds as an array of the three.
const GRID_FIELDS := {"velocity_x": 1, "velocity_y": 1, "velocity_z": 1, "velocity_tmp_x": 1,
	"velocity_tmp_y": 1, "velocity_tmp_z": 1, "velocity_hat_x": 1, "velocity_hat_y": 1,
	"velocity_hat_z": 1, "walls": 1, "scalar": 2, "scalar_tmp": 2, "scalar_hat": 2, "pressure": 1,
	"divergence": 2, "curl": 4, "obstacle": 4, "occupancy": 1, "dye": 4, "dye_tmp": 4, "dye_hat": 4}
const MACCORMACK_FIELDS: Array[String] = ["velocity_hat_x", "velocity_hat_y", "velocity_hat_z",
	"scalar_hat", "dye_hat"]
## Face fields (smoke_common.comp), one texel larger than the grid on every axis.
const FACE_FIELDS: Array[String] = ["velocity_x", "velocity_y", "velocity_z", "velocity_tmp_x",
	"velocity_tmp_y", "velocity_tmp_z", "velocity_hat_x", "velocity_hat_y", "velocity_hat_z", "walls"]
const CHANNEL_FORMATS := {
	1: RenderingDevice.DATA_FORMAT_R32_SFLOAT,
	2: RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
	4: RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
}

var config: SmokeConfig = SmokeConfig.new()
## Direction toward the sun, world space.
var light_direction := Vector3.UP
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _textures := {}
var _buffers := {}
var _sampler := RID()
var _dims := Vector3i.ZERO
var _light_dims := Vector3i.ZERO
var _running := false
var _running_mutex := Mutex.new()
var _sources := PackedFloat32Array()
var _obstacles := PackedFloat32Array()
var _static_occupancy := PackedFloat32Array()
var _timing_store := GpuTimingStore.new()


## Validates the config and queues GPU allocation; [method is_ready] turns true
## once the render thread is done. Restarts from a clean grid when running.
func start() -> String:
	var error := config.validate()
	if error != "":
		return error
	stop()
	_dims = config.grid_dims()
	_light_dims = config.light_dims()
	var occupancy := _static_occupancy
	if occupancy.size() != _cell_count():
		occupancy = PackedFloat32Array()
		occupancy.resize(_cell_count())
	RenderingServer.call_on_render_thread(
		_init_render.bind(_dims, _light_dims, occupancy.to_byte_array(), config.maccormack))
	return ""


## Frees every GPU resource; blocks until the render thread has done it.
func stop() -> void:
	var done := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		_free_render()
		done.post())
	done.wait()


func is_ready() -> bool:
	_running_mutex.lock()
	var running := _running
	_running_mutex.unlock()
	return running


func grid_dims() -> Vector3i:
	return _dims


## Zeroes smoke, heat, velocity and pressure; obstacles stay.
func clear() -> void:
	RenderingServer.call_on_render_thread(_clear_render)


func set_sources(packed: PackedFloat32Array) -> void:
	_sources = packed.slice(0, MAX_SOURCES * SOURCE_VEC4S * 4)


func set_obstacles(packed: PackedFloat32Array) -> void:
	_obstacles = packed.slice(0, MAX_OBSTACLES * OBSTACLE_VEC4S * 4)


## Per-cell solid fraction in x-fastest order, for the next [method start] and,
## when running, uploaded at once.
func set_static_occupancy(occupancy: PackedFloat32Array) -> void:
	_static_occupancy = occupancy
	if is_ready() and occupancy.size() == _cell_count():
		RenderingServer.call_on_render_thread(
			_upload_occupancy_render.bind(occupancy.to_byte_array()))


func source_count() -> int:
	return _sources.size() / (SOURCE_VEC4S * 4)


## Runs [param substeps] fixed steps of 1 / sim_rate_hz, then refreshes the light
## volume (also when paused, so a moving sun still updates the shadows).
func advance(substeps: int) -> void:
	if not is_ready():
		return
	var pc := make_push_constants(source_count(), _obstacles.size() / (OBSTACLE_VEC4S * 4), 0)
	RenderingServer.call_on_render_thread(_advance_render.bind(maxi(substeps, 0),
		config.pressure_vcycles, pc, _sources.to_byte_array(), _obstacles.to_byte_array()))


func density_texture_rid() -> RID:
	return _textures.get("scalar", RID())


func light_texture_rid() -> RID:
	return _textures.get("light", RID())


func dye_texture_rid() -> RID:
	return _textures.get("dye", RID())


## GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	return _timing_store.snapshot()


## Blocking readback of one field (GRID_FIELDS or "light"), as floats in x-fastest order.
func read_field(field: String) -> PackedFloat32Array:
	var result := []
	var done := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		if _rd != null and _textures.has(field):
			result.append(_rd.texture_get_data(_textures[field], 0).to_float32_array())
		done.post())
	done.wait()
	return result[0] if not result.is_empty() else PackedFloat32Array()


func world_to_cell(position_m: Vector3) -> Vector3:
	return (position_m - config.domain_origin_m) / config.cell_size_m()


func make_push_constants(sources: int, obstacles: int, parity: int) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(PUSH_CONSTANT_BYTES)
	var dims := config.grid_dims()
	var origin := config.domain_origin_m
	var wind := config.wind_mps()
	var light := light_direction.normalized()
	pc.encode_s32(0, dims.x)
	pc.encode_s32(4, dims.y)
	pc.encode_s32(8, dims.z)
	pc.encode_s32(12, config.light_downsample)
	pc.encode_float(16, origin.x)
	pc.encode_float(20, origin.y)
	pc.encode_float(24, origin.z)
	pc.encode_float(28, config.cell_size_m())
	pc.encode_float(32, 1.0 / config.sim_rate_hz)
	pc.encode_float(36, config.buoyancy_mps2_per_k)
	pc.encode_float(40, config.smoke_weight_mps2)
	pc.encode_float(44, config.vorticity_confinement)
	pc.encode_float(48, config.density_decay_hz)
	pc.encode_float(52, config.temperature_decay_hz)
	pc.encode_float(56, config.velocity_decay_hz)
	pc.encode_float(60, config.wind_relax_hz)
	pc.encode_float(64, wind.x)
	pc.encode_float(68, wind.y)
	pc.encode_float(72, config.extinction_per_m)
	pc.encode_float(80, light.x)
	pc.encode_float(84, light.y)
	pc.encode_float(88, light.z)
	pc.encode_float(92, config.light_step_cells)
	pc.encode_s32(96, sources)
	pc.encode_s32(100, obstacles)
	pc.encode_s32(104, parity)
	return pc


static func pack_source(position_m: Vector3, extent_m: Vector3, density_per_s: float,
		heat_k_per_s: float, velocity_mps: Vector3, relax_hz: float,
		color: Color = Color.WHITE) -> PackedFloat32Array:
	return PackedFloat32Array([
		position_m.x, position_m.y, position_m.z, density_per_s,
		extent_m.x, extent_m.y, extent_m.z, heat_k_per_s,
		velocity_mps.x, velocity_mps.y, velocity_mps.z, relax_hz,
		color.r, color.g, color.b, 0.0,
	])


static func pack_sphere(center_m: Vector3, radius_m: float, linear_mps: Vector3,
		angular_rad_s: Vector3) -> PackedFloat32Array:
	return _pack_obstacle(OBSTACLE_SPHERE, center_m, Vector3(radius_m, 0.0, 0.0),
		Basis.IDENTITY, linear_mps, angular_rad_s)


static func pack_box(xform: Transform3D, half_extents_m: Vector3, linear_mps: Vector3,
		angular_rad_s: Vector3) -> PackedFloat32Array:
	return _pack_obstacle(OBSTACLE_BOX, xform.origin, half_extents_m,
		xform.basis.orthonormalized(), linear_mps, angular_rad_s)


## GRID_FIELDS a solver allocates; the MacCormack pair only when it runs.
static func grid_fields(maccormack: bool) -> Array[String]:
	var fields: Array[String] = []
	for field in GRID_FIELDS:
		if maccormack or not MACCORMACK_FIELDS.has(field):
			fields.append(field)
	return fields


## GPU bytes per grid cell, light volume excluded.
static func bytes_per_cell(maccormack: bool) -> int:
	var total := MG_BYTES_PER_CELL
	for field in grid_fields(maccormack):
		total += 4 * int(GRID_FIELDS[field])
	return total


## Per level, 8 floats for smoke_mg_common.comp: unknown cells per axis, the low-side
## open weight, the high-side open weights. A coarse cell is unknown while its centre
## lies inside the fine grid's p = 0 ghost centres (-0.5 and n + 0.5 fine cells);
## the weight H / d is that boundary's distance to the outermost unknown centre.
static func mg_level_params(dims: Vector3i) -> PackedFloat32Array:
	var params := PackedFloat32Array()
	var levels := mg_level_dims(dims)
	for level in levels.size():
		if level == 0:
			params.append_array(PackedFloat32Array([dims.x, dims.y, dims.z, 0.0, 0.0, 0.0, 0.0, 0.0]))
			continue
		var size := float(1 << level)
		var unknowns := PackedFloat32Array()
		var high := PackedFloat32Array()
		for axis in 3:
			var boundary := float(dims[axis]) + 0.5
			var count := 0
			while count < levels[level][axis] and (count + 0.5) * size < boundary:
				count += 1
			unknowns.append(count)
			high.append(size / (boundary - (count - 0.5) * size))
		params.append_array(unknowns)
		params.append(size / (0.5 * size + 0.5))
		params.append_array(high)
		params.append(0.0)
	return params


## Grid of every multigrid level, finest first: halved (rounded up) while every
## axis stays above MG_MIN_DIM.
static func mg_level_dims(dims: Vector3i) -> Array[Vector3i]:
	var levels: Array[Vector3i] = [dims]
	while mini(dims.x, mini(dims.y, dims.z)) > MG_MIN_DIM:
		dims = (dims + Vector3i.ONE) / 2
		levels.append(dims)
	return levels


## Defines every smoke stage shares with this script.
static func glsl_defines() -> String:
	return "\n".join(PackedStringArray([
		"#define WG_X %d" % WG.x,
		"#define WG_Y %d" % WG.y,
		"#define WG_Z %d" % WG.z,
		"#define SOURCE_VEC4S %d" % SOURCE_VEC4S,
		"#define OBSTACLE_VEC4S %d" % OBSTACLE_VEC4S,
		"#define OBSTACLE_SPHERE %d" % OBSTACLE_SPHERE,
	])) + "\n"


# Rows of the world-to-local rotation are the basis columns.
static func _pack_obstacle(kind: int, center_m: Vector3, size_m: Vector3, basis: Basis,
		linear_mps: Vector3, angular_rad_s: Vector3) -> PackedFloat32Array:
	return PackedFloat32Array([
		center_m.x, center_m.y, center_m.z, float(kind),
		size_m.x, size_m.y, size_m.z, 0.0,
		basis.x.x, basis.x.y, basis.x.z, 0.0,
		basis.y.x, basis.y.y, basis.y.z, 0.0,
		basis.z.x, basis.z.y, basis.z.z, 0.0,
		linear_mps.x, linear_mps.y, linear_mps.z, 0.0,
		angular_rad_s.x, angular_rad_s.y, angular_rad_s.z, 0.0,
	])


func _cell_count() -> int:
	return _dims.x * _dims.y * _dims.z


func _set_ready(value: bool) -> void:
	_running_mutex.lock()
	_running = value
	_running_mutex.unlock()


func _init_render(dims: Vector3i, light_dims: Vector3i, occupancy: PackedByteArray,
		maccormack: bool) -> void:
	_free_render()
	_rd = GpuPreflight.device("SmokeSolver")
	if _rd == null:
		return
	var header := "#version 450\n\n" + glsl_defines() \
		+ FileAccess.get_file_as_string(SHADER_DIR + "smoke_common.comp") + "\n"
	for stage in STAGES:
		var source := FileAccess.get_file_as_string(SHADER_DIR + "smoke_%s.comp" % stage)
		if MG_LEVELS_BINDING.has(stage):
			source = "#define MG_LEVELS_BINDING %d\n" % MG_LEVELS_BINDING[stage] \
				+ FileAccess.get_file_as_string(SHADER_DIR + "smoke_mg_common.comp") + "\n" + source
		var spirv := ShaderCache.compile(_rd, "smoke_" + stage, header + source)
		if not spirv.compile_error_compute.is_empty():
			push_error("Smoke stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			_free_render()
			return
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])
	for field in grid_fields(maccormack):
		_textures[field] = _create_texture(dims + Vector3i.ONE if FACE_FIELDS.has(field) else dims,
			CHANNEL_FORMATS[GRID_FIELDS[field]],
			occupancy if field == "occupancy" else PackedByteArray())
	var levels := mg_level_dims(dims)
	for level in range(1, levels.size()):
		_textures["mg_b%d" % level] = _create_texture(levels[level], CHANNEL_FORMATS[2])
		_textures["mg_p%d" % level] = _create_texture(levels[level], CHANNEL_FORMATS[1])
	_textures["light"] = _create_texture(light_dims, CHANNEL_FORMATS[2])
	_buffers["sources"] = _rd.storage_buffer_create(MAX_SOURCES * SOURCE_VEC4S * 16)
	_buffers["obstacles"] = _rd.storage_buffer_create(MAX_OBSTACLES * OBSTACLE_VEC4S * 16)
	var level_params := mg_level_params(dims).to_byte_array()
	_buffers["mg_levels"] = _rd.storage_buffer_create(level_params.size(), level_params)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)

	_make_set("obstacles", [_image("occupancy"), _image("obstacle"), _storage("obstacles")])
	_make_set("advect", [_sampled("velocity"), _sampled("scalar"), _image("velocity_tmp"),
		_image("scalar_tmp"), _sampled("dye"), _image("dye_tmp")])
	if maccormack:
		_make_set("advect", [_sampled("velocity"), _sampled("scalar"), _image("velocity_hat"),
			_image("scalar_hat"), _sampled("dye"), _image("dye_hat")], "advect_hat")
		_make_set("maccormack", [_sampled("velocity"), _sampled("scalar"), _sampled("velocity_hat"),
			_sampled("scalar_hat"), _image("velocity_tmp"), _image("scalar_tmp"), _sampled("dye"),
			_sampled("dye_hat"), _image("dye_tmp")])
	_make_set("forces", [_image("velocity_tmp"), _image("scalar_tmp"), _image("obstacle"),
		_image("velocity"), _image("scalar"), _storage("sources"), _image("walls"),
		_image("dye_tmp"), _image("dye")])
	_make_set("curl", [_image("velocity"), _image("curl")])
	_make_set("vorticity", [_image("curl"), _image("walls"), _image("velocity")])
	_make_set("divergence", [_image("velocity"), _image("obstacle"), _image("divergence")])
	for level in levels.size():
		_make_set("mg_smooth", [_image(_mg_b(level)), _image(_mg_p(level)), _storage("mg_levels")],
			"mg_smooth%d" % level)
	for level in levels.size() - 1:
		var fields: Array[RDUniform] = [_image(_mg_b(level)), _image(_mg_p(level)),
			_image(_mg_b(level + 1)), _image(_mg_p(level + 1)), _storage("mg_levels")]
		_make_set("mg_restrict", fields, "mg_restrict%d" % level)
		_make_set("mg_prolong", fields.duplicate(), "mg_prolong%d" % level)
	_make_set("project", [_image("pressure"), _image("walls"), _image("velocity")])
	_make_set("light", [_sampled("scalar"), _image("light")])
	_set_ready(true)


func _advance_render(substeps: int, vcycles: int, pc: PackedByteArray,
		sources: PackedByteArray, obstacles: PackedByteArray) -> void:
	if _rd == null or _pipelines.is_empty():
		return
	_read_timings()
	if not sources.is_empty():
		_rd.buffer_update(_buffers["sources"], 0, sources.size(), sources)
	if not obstacles.is_empty():
		_rd.buffer_update(_buffers["obstacles"], 0, obstacles.size(), obstacles)
	var dims := _dims_of("scalar")
	var groups := _groups(dims)
	var face_groups := _groups(dims + Vector3i.ONE)
	var maccormack := _uniform_sets.has("maccormack")
	_rd.capture_timestamp("smoke/start")
	var cl := _rd.compute_list_begin()
	# The obstacle image depends only on the static occupancy and this call's
	# obstacle list (same pc every substep), and no later stage writes it: one
	# rasterisation serves every substep.
	if substeps > 0:
		_dispatch(cl, "obstacles", pc, groups)
	for substep in substeps:
		if maccormack:
			_dispatch(cl, "advect", pc, face_groups, "advect_hat")
			_dispatch(cl, "maccormack", pc, face_groups)
		else:
			_dispatch(cl, "advect", pc, face_groups)
		_dispatch(cl, "forces", pc, face_groups)
		cl = _mark(cl, "smoke/advect")
		_dispatch(cl, "curl", pc, groups)
		_dispatch(cl, "vorticity", pc, face_groups)
		_dispatch(cl, "divergence", pc, groups)
		cl = _mark(cl, "smoke/vorticity")
		for cycle in vcycles:
			_vcycle(cl, pc)
		cl = _mark(cl, "smoke/pressure")
		_dispatch(cl, "project", pc, face_groups)
		cl = _mark(cl, "smoke/project")
	_dispatch(cl, "light", pc, _groups(_dims_of("light")))
	cl = _mark(cl, "smoke/light")
	_rd.compute_list_end()
	_rd.capture_timestamp("smoke/end")


# Level 0 is the divergence / pressure pair; restriction zeroes each coarse guess.
func _vcycle(cl: int, pc: PackedByteArray) -> void:
	var levels := mg_level_dims(_dims)
	var pcs: Array[PackedByteArray] = []
	for level in levels.size():
		var level_pc := pc.duplicate()
		level_pc.encode_s32(0, levels[level].x)
		level_pc.encode_s32(4, levels[level].y)
		level_pc.encode_s32(8, levels[level].z)
		level_pc.encode_float(28, pc.decode_float(28) * float(1 << level))
		level_pc.encode_s32(108, level)
		pcs.append(level_pc)
	var last := levels.size() - 1
	for level in last:
		_smooth(cl, level, levels[level], pcs[level], MG_PRE_SWEEPS)
		_dispatch(cl, "mg_restrict", pcs[level], _groups(levels[level + 1]),
			"mg_restrict%d" % level)
	_smooth(cl, last, levels[last], pcs[last], MG_COARSE_SWEEPS)
	for level in range(last - 1, -1, -1):
		_dispatch(cl, "mg_prolong", pcs[level], _groups(levels[level]), "mg_prolong%d" % level)
		_smooth(cl, level, levels[level], pcs[level], MG_POST_SWEEPS)


func _smooth(cl: int, level: int, dims: Vector3i, pc: PackedByteArray, sweeps: int) -> void:
	var groups := _groups(Vector3i((dims.x + 1) / 2, dims.y, dims.z))
	var pc_odd := pc.duplicate()
	pc_odd.encode_s32(104, 1)
	for sweep in sweeps:
		_dispatch(cl, "mg_smooth", pc, groups, "mg_smooth%d" % level)
		_dispatch(cl, "mg_smooth", pc_odd, groups, "mg_smooth%d" % level)


func _mg_b(level: int) -> String:
	return "divergence" if level == 0 else "mg_b%d" % level


func _mg_p(level: int) -> String:
	return "pressure" if level == 0 else "mg_p%d" % level


func _clear_render() -> void:
	if _rd == null:
		return
	for field in ["velocity", "velocity_tmp", "scalar", "scalar_tmp", "dye", "dye_tmp", "pressure",
			"divergence",
			"curl", "light"]:
		for rid in _texture_ids(field):
			_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)


func _upload_occupancy_render(occupancy: PackedByteArray) -> void:
	if _rd != null and _textures.has("occupancy"):
		_rd.texture_update(_textures["occupancy"], 0, occupancy)


func _free_render() -> void:
	_set_ready(false)
	if _rd == null:
		return
	for stage in _uniform_sets:
		if _uniform_sets[stage].is_valid():
			_rd.free_rid(_uniform_sets[stage])
	for key in _buffers:
		if _buffers[key].is_valid():
			_rd.free_rid(_buffers[key])
	for key in _textures:
		if _textures[key].is_valid():
			_rd.free_rid(_textures[key])
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_uniform_sets.clear()
	_buffers.clear()
	_textures.clear()
	_pipelines.clear()
	_shaders.clear()
	_sampler = RID()


func _create_texture(dims: Vector3i, format: RenderingDevice.DataFormat,
		data: PackedByteArray = PackedByteArray()) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = dims.x
	fmt.height = dims.y
	fmt.depth = dims.z
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	if not data.is_empty():
		return _rd.texture_create(fmt, RDTextureView.new(), [data])
	var rid := _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid


func _dims_of(field: String) -> Vector3i:
	var fmt := _rd.texture_get_format(_textures[field])
	return Vector3i(fmt.width, fmt.height, fmt.depth)


func _groups(dims: Vector3i) -> Vector3i:
	return Vector3i(ceili(float(dims.x) / WG.x), ceili(float(dims.y) / WG.y),
		ceili(float(dims.z) / WG.z))


## One texture, or the three axes of a velocity field.
func _texture_ids(field: String) -> Array[RID]:
	var ids: Array[RID] = []
	for name in [field] if _textures.has(field) else [field + "_x", field + "_y", field + "_z"]:
		if _textures.has(name):
			ids.append(_textures[name])
	return ids


func _image(field: String) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	for rid in _texture_ids(field):
		u.add_id(rid)
	return u


func _sampled(field: String) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	for rid in _texture_ids(field):
		u.add_id(_sampler)
		u.add_id(rid)
	return u


func _storage(buffer: String) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.add_id(_buffers[buffer])
	return u


## [param set_name] defaults to the stage; a stage bound to other fields needs its own.
func _make_set(stage: String, uniforms: Array[RDUniform], set_name: String = "") -> void:
	for binding in uniforms.size():
		uniforms[binding].binding = binding
	_uniform_sets[stage if set_name.is_empty() else set_name] = \
		_rd.uniform_set_create(uniforms, _shaders[stage], 0)


func _dispatch(cl: int, stage: String, pc: PackedByteArray, groups: Vector3i,
		set_name: String = "") -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage if set_name.is_empty() else set_name], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	_rd.compute_list_add_barrier(cl)


# Timestamps cannot be captured inside an open compute list; split it at stage
# boundaries only while profiling.
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


func _read_timings() -> void:
	var out := GpuTimings.read(_rd, "smoke/")
	if not out.is_empty():
		_timing_store.publish(out)
