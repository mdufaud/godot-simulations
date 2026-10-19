class_name OceanShoreSolver
extends RefCounted

const SHADER_DIR := "res://shaders/ocean/"
const CoastalConfig := preload("res://scripts/ocean/ocean_coastal_config.gd")
const DOMAIN_M := CoastalConfig.DEFAULT_DOMAIN_M
const GRID_SIZES := CoastalConfig.DEFAULT_GRID_SIZES_CELLS
const MACRO_DT := CoastalConfig.DEFAULT_MACRO_STEP_S
const MAX_SUBSTEPS_PER_RENDER := CoastalConfig.DEFAULT_MAX_SUBSTEPS_PER_RENDER
const MIN_SUBSTEPS_PER_RENDER := CoastalConfig.DEFAULT_MIN_SUBSTEPS_PER_RENDER
const MAX_FORCES := 32
const NUM_SPECTRA := 3
const BOUNDARY_LOG2 := 9
const BOUNDARY_SIZE := 1 << BOUNDARY_LOG2
const MIN_SOURCE_SIZE := 128
const OUTER_DEPTH_M := CoastalConfig.DEFAULT_BOUNDARY_DEPTH_M
const RING_DEPTH_M := CoastalConfig.DEFAULT_OFFSHORE_DEPTH_M
const DRY_DEPTH_M := CoastalConfig.DEFAULT_DRY_DEPTH_M
const ABSORB_WIDTH_M := CoastalConfig.DEFAULT_SPONGE_WIDTH_M
const MIN_WAVELENGTH_M := CoastalConfig.DEFAULT_MINIMUM_WAVELENGTH_M
const GRAVITY := CoastalConfig.DEFAULT_GRAVITY_M_S2
const FOAM_RETENTION_S := CoastalConfig.DEFAULT_FOAM_RETENTION_S
const SAND_DRYING_S := 3.0
const DISP_B := CoastalConfig.DISPERSIVE_COEFFICIENT_B
const DISP_CD := CoastalConfig.DISPERSIVE_COEFFICIENT_C
const DISP_ITERATIONS := CoastalConfig.DEFAULT_DISPERSIVE_ITERATIONS
const BREAK_FR_START := CoastalConfig.DEFAULT_BREAK_FROUDE_START
const BREAK_FR_END := CoastalConfig.DEFAULT_BREAK_FROUDE_END
const EDDY := CoastalConfig.DEFAULT_EDDY_COEFFICIENT
const MAX_GRID := CoastalConfig.DEFAULT_MAX_SUPPORTED_GRID
const CONTROL_BYTES := 128
const STAGES := ["init", "schedule", "cfl", "reconstruct", "update", "output", "pack", "fft", "transpose", "assemble", "butterfly",
	"init_wave", "foam_source", "disp_grad", "disp_rhs", "disp_solve_x", "disp_solve_z", "disp_residual", "disp_apply", "visc_x", "visc_z"]

var enabled := false
var profiling := false
var config: CoastalConfig = CoastalConfig.new()
var source_depth_m: float:
	get:
		return config.boundary_depth_m
	set(value):
		config.boundary_depth_m = value
var spectrum_depth_m: float:
	get:
		return config.offshore_depth_m
	set(value):
		config.offshore_depth_m = value
var grid_size := 0
var _rd: RenderingDevice
var _spectrum_rid := RID()
var _breaking_rid := RID()
var _displacement_rid := RID()
var _velocity_rid := RID()
var _visual_history_index := 0
var _breaking_fallback := RID()
var _surface_rid := RID()
var _foam_rid := RID()
var _derivative_rid := RID()
var _breaker_rid := RID()
var _contact_rid := RID()
var incident_direction := Vector2.RIGHT
var _boundary_rid := RID()
var _source_n := 0
var _tiles := PackedFloat32Array()
var _bed := PackedFloat32Array()
var _buffers: Dictionary = {}
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _sets: Dictionary = {}
var _initialized := false
var _reset_pending := false
var _reset_visual_history_pending := true
var _initial_wave_pending := false
var _progress_mutex := Mutex.new()
var _progress_pending := false
var _progress_backlog_s := 0.0
var _progress_signal_m_s := 0.0
var _progress_generation := 0
var _progress_interval_s := 0.0


var whitecap_threshold := 0.82


func init_render(spectrum: RID, map_n: int, tiles: PackedFloat32Array,
		tier: int, bed: PackedFloat32Array, breaking: RID = RID(), displacement: RID = RID(),
		velocity: RID = RID()) -> bool:
	free_render()
	if not spectrum.is_valid() or map_n < MIN_SOURCE_SIZE or tiles.size() != 3 \
			or tier < 0 or tier >= config.grid_sizes_cells.size():
		push_error("OceanShoreSolver requires a spectrum, three tiles, and a supported tier")
		return false
	grid_size = config.resolution_cells(tier)
	config.selected_resolution_cells = grid_size
	config.bathymetry_elevation_m = bed.duplicate()
	var config_error := config.validate()
	if config_error != "":
		push_error("OceanCoastalConfig: " + config_error)
		grid_size = 0
		return false
	_rd = GpuPreflight.device("OceanShoreSolver")
	if _rd == null:
		return false
	_spectrum_rid = spectrum
	_source_n = map_n
	_tiles = tiles.duplicate()
	_bed = bed.duplicate()
	_breaking_rid = breaking
	_displacement_rid = displacement
	_velocity_rid = velocity
	if not _create_resources():
		free_render()
		return false
	_initialized = true
	enabled = true
	_reset_render()
	return true


func step_render(delta_s: float, time_s: float, current_m_s: Vector2,
		foam_amount: float, foam_decay: float, impulses: PackedVector4Array,
		pressures: PackedVector4Array = PackedVector4Array()) -> void:
	if not _initialized or not enabled:
		return
	if _reset_pending:
		_reset_render()
	var events := _inside_forces(impulses, false)
	var supports := _inside_forces(pressures, true)
	if not events.is_empty():
		var bytes := events.to_byte_array()
		_rd.buffer_update(_buffers.events, 0, bytes.size(), bytes)
	if not supports.is_empty():
		var bytes := supports.to_byte_array()
		_rd.buffer_update(_buffers.pressures, 0, bytes.size(), bytes)
	var threshold := PackedByteArray()
	threshold.resize(4)
	threshold.encode_float(0, clampf(whitecap_threshold, 0.05, 0.95))
	_rd.buffer_update(_buffers.control, 44, 4, threshold)
	var pc := _push_constants(maxf(delta_s, 0.0), time_s, current_m_s,
		maxf(foam_amount, 0.0), maxf(foam_decay, 0.0), events.size(), supports.size())
	if _initial_wave_pending:
		var forcing := PackedFloat32Array([time_s - maxf(delta_s, 0.0), current_m_s.x,
			current_m_s.y, clampf(whitecap_threshold, 0.05, 0.95)]).to_byte_array()
		_rd.buffer_update(_buffers.control, 32, 16, forcing)
	if profiling:
		_rd.capture_timestamp("shore/start")
	var cl := _rd.compute_list_begin()
	if _initial_wave_pending:
		for cascade in _tiles.size():
			if _tiles[cascade] < config.minimum_wavelength_m:
				continue
			pc.encode_s32(84, cascade)
			_dispatch(cl, "pack", pc, BOUNDARY_SIZE / 16, BOUNDARY_SIZE / 16, 1)
			_dispatch(cl, "fft", pc, 1, BOUNDARY_SIZE, NUM_SPECTRA)
			_dispatch(cl, "transpose", pc, BOUNDARY_SIZE / 32, BOUNDARY_SIZE / 32, NUM_SPECTRA)
			_dispatch(cl, "fft", pc, 1, BOUNDARY_SIZE, NUM_SPECTRA)
			_dispatch(cl, "assemble", pc, BOUNDARY_SIZE / 16, BOUNDARY_SIZE / 16, 1)
		_dispatch(cl, "init_wave", pc, grid_size / 8, grid_size / 8, 1)
		_initial_wave_pending = false
	pc.encode_s32(80, 0)
	_dispatch(cl, "schedule", pc, 1, 1, 1)
	_dispatch(cl, "foam_source", pc, grid_size / 8, grid_size / 8, 1)
	_progress_mutex.lock()
	var pending_s := _progress_backlog_s
	var signal_m_s := _progress_signal_m_s
	_progress_mutex.unlock()
	var budget := clampi(int(ceil((maxf(delta_s, 0.0) + pending_s)
			* signal_m_s / (0.40 * config.domain_m / float(grid_size)))) + 2,
			config.min_substeps_per_render, config.max_substeps_per_render)
	for substep in budget:
		pc.encode_s32(80, 1)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		for cascade in _tiles.size():
			if _tiles[cascade] < config.minimum_wavelength_m:
				continue
			pc.encode_s32(84, cascade)
			_dispatch_indirect(cl, "pack", pc, 80)
			_dispatch_indirect(cl, "fft", pc, 96)
			_dispatch_indirect(cl, "transpose", pc, 112)
			_dispatch_indirect(cl, "fft", pc, 96)
			_dispatch_indirect(cl, "assemble", pc, 80)
		cl = _mark(cl, "shore/boundary")
		_dispatch_indirect(cl, "cfl", pc, 64)
		pc.encode_s32(80, 2)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		pc.encode_s32(88, 0)
		_dispatch_indirect(cl, "reconstruct", pc, 64)
		_dispatch_indirect(cl, "update", pc, 64)
		cl = _mark(cl, "shore/finite_volume")
		cl = _dispatch_dispersive(cl, pc)
		pc.encode_s32(80, 4)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
		pc.encode_s32(88, 1)
		_dispatch_indirect(cl, "reconstruct", pc, 64)
		_dispatch_indirect(cl, "update", pc, 64)
		cl = _mark(cl, "shore/finite_volume")
		cl = _dispatch_dispersive(cl, pc)
		pc.encode_s32(80, 3)
		_dispatch(cl, "schedule", pc, 1, 1, 1)
	pc.encode_s32(84, _visual_history_index)
	_dispatch(cl, "output", pc, grid_size / 8, grid_size / 8, 1)
	_visual_history_index = 1 - _visual_history_index
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("shore/output")
		_rd.capture_timestamp("shore/end")
	_progress_interval_s += maxf(delta_s, 0.0)
	if _progress_interval_s >= 0.25:
		_read_progress_render()


func reset(clear_visual_history: bool = true) -> void:
	_reset_pending = true
	_reset_visual_history_pending = _reset_visual_history_pending or clear_visual_history


func request_reset() -> void:
	reset()


func set_bathymetry(bed: PackedFloat32Array) -> void:
	var selected_size := grid_size if grid_size > 0 else config.selected_resolution_cells
	config.selected_resolution_cells = selected_size
	if bed.size() != selected_size * selected_size:
		return
	for height in bed:
		if not is_finite(height):
			return
	var previous_bathymetry := config.bathymetry_elevation_m
	config.bathymetry_elevation_m = bed.duplicate()
	var config_error := config.validate()
	if config_error != "":
		config.bathymetry_elevation_m = previous_bathymetry
		return
	_bed = config.bathymetry_elevation_m.duplicate()
	if _initialized:
		var bytes := _bed.to_byte_array()
		_rd.buffer_update(_buffers.bed, 0, bytes.size(), bytes)
		reset()


func get_texture_rid() -> RID:
	return _surface_rid


func get_foam_texture_rid() -> RID:
	return _foam_rid


func get_derivative_texture_rid() -> RID:
	return _derivative_rid


func get_breaker_texture_rid() -> RID:
	return _breaker_rid


func get_contact_texture_rid() -> RID:
	return _contact_rid


func estimate_vram_bytes() -> int:
	if not _initialized:
		return 0
	var pixels := grid_size * grid_size
	var boundary_pixels := BOUNDARY_SIZE * BOUNDARY_SIZE
	return pixels * (128 + 48 + 4 + 16 + 64 + 48 + 16 + 64) + boundary_pixels * (96 + 48) \
		+ BOUNDARY_SIZE * BOUNDARY_LOG2 * 16 + CONTROL_BYTES + MAX_FORCES * 48 \
		+ (pixels * 64 if config.visual_breakers_enabled and _displacement_rid.is_valid() else 64)


func free_render() -> void:
	enabled = false
	_initialized = false
	if _rd != null:
		for uniform_set: RID in _sets.values():
			if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
				_rd.free_rid(uniform_set)
		for buffer: RID in _buffers.values():
			if buffer.is_valid():
				_rd.free_rid(buffer)
		for texture: RID in [_surface_rid, _foam_rid, _derivative_rid, _breaker_rid, _contact_rid, _boundary_rid,
				_breaking_fallback]:
			if texture.is_valid():
				_rd.free_rid(texture)
		for pipeline: RID in _pipelines.values():
			if pipeline.is_valid():
				_rd.free_rid(pipeline)
		for shader: RID in _shaders.values():
			if shader.is_valid():
				_rd.free_rid(shader)
	_sets.clear()
	_buffers.clear()
	_pipelines.clear()
	_shaders.clear()
	_surface_rid = RID()
	_foam_rid = RID()
	_derivative_rid = RID()
	_breaker_rid = RID()
	_contact_rid = RID()
	_boundary_rid = RID()
	_spectrum_rid = RID()
	_breaking_rid = RID()
	_displacement_rid = RID()
	_velocity_rid = RID()
	_visual_history_index = 0
	_breaking_fallback = RID()
	_source_n = 0
	grid_size = 0
	_tiles.clear()
	_bed.clear()
	_reset_pending = false
	_reset_visual_history_pending = true
	_initial_wave_pending = false
	_progress_mutex.lock()
	_progress_generation += 1
	_progress_pending = false
	_progress_backlog_s = 0.0
	_progress_signal_m_s = 0.0
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd = null


static func shader_header() -> String:
	return "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n#define NUM_SPECTRA %du\n" % [
		BOUNDARY_SIZE, BOUNDARY_SIZE, NUM_SPECTRA]


func _create_resources() -> bool:
	var defines := shader_header() + "#define SHORE_FOAM_RETENTION_S %.3f\n#define SHORE_DISP_B %.9f\n#define SHORE_DISP_CD %.9f\n#define SHORE_BREAK_FR_START %.4f\n#define SHORE_BREAK_FR_END %.4f\n#define SHORE_EDDY %.4f\n#define SHORE_MAX_GRID %d\n" % [
		config.foam_retention_s,
		CoastalConfig.DISPERSIVE_COEFFICIENT_B, CoastalConfig.DISPERSIVE_COEFFICIENT_C,
		config.break_froude_start, config.break_froude_end, config.eddy_coefficient,
		config.max_supported_grid]
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_shore_common.comp")
	defines += "#define SHORE_DISP_TOLERANCE %.9f\n" % config.dispersive_tolerance
	defines += "#define SHORE_DISP_RELATIVE_DEPTH %.9f\n" % config.dispersive_relative_depth
	defines += "#define SHORE_LINE_SIZE %d\n" % grid_size
	defines += "#define SHORE_VISUAL_BREAKERS %d\n" % int(config.visual_breakers_enabled)
	defines += "#define SHORE_FFT_SURFACE %d\n" % int(config.visual_breakers_enabled and _displacement_rid.is_valid())
	defines += "#define SHORE_SAND_DRYING_S %.3f\n" % SAND_DRYING_S
	defines += "#define SHORE_CONTACT_RETENTION_S %.6f\n" % config.contact_retention_s
	defines += "#define SHORE_BREAKER_MIN_PROFILE_CELLS %.6f\n" % CoastalConfig.BREAKER_MIN_PROFILE_CELLS
	for stage: String in STAGES:
		var file := "ocean_shore_" + stage + ".comp"
		if stage in ["fft", "transpose", "butterfly"]:
			file = "ocean_" + ("fft_butterfly" if stage == "butterfly" else stage) + ".comp"
		var stage_defines := ""
		if stage in ["visc_x", "visc_z"]:
			file = "ocean_shore_visc.comp"
			stage_defines = "#define SHORE_VISC_AXIS %d\n" % (0 if stage == "visc_x" else 1)
		var source := FileAccess.get_file_as_string(SHADER_DIR + file)
		var spirv := ShaderCache.compile(_rd, "ocean_shore_" + stage, defines + stage_defines + common + "\n" + source)
		if not spirv.compile_error_compute.is_empty():
			push_error("Ocean shore stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return false
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])
	var pixels := grid_size * grid_size
	_buffers.bed = _rd.storage_buffer_create(pixels * 4, _bed.to_byte_array())
	_buffers.balance = _rd.storage_buffer_create(pixels * 16)
	_buffers.slopes = _rd.storage_buffer_create(pixels * 64)
	_buffers.disp = _rd.storage_buffer_create(pixels * 16)
	_buffers.brk = _rd.storage_buffer_create(pixels * 16)
	_buffers.accel = _rd.storage_buffer_create(pixels * 16)
	_buffers.disp_diagnostic = _rd.storage_buffer_create(pixels * 16)
	_buffers.contact = _rd.storage_buffer_create(pixels * 16)
	_buffers.completed_contact = _rd.storage_buffer_create(pixels * 32)
	_buffers.visual_history = _rd.storage_buffer_create(
		pixels * 64 if config.visual_breakers_enabled and _displacement_rid.is_valid() else 64)
	for name: String in ["state", "foam", "completed_state", "completed_foam"]:
		_buffers[name] = _rd.storage_buffer_create(pixels * 32)
	_buffers.control = _rd.storage_buffer_create(CONTROL_BYTES, PackedByteArray(),
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_buffers.fft = _rd.storage_buffer_create(BOUNDARY_SIZE * BOUNDARY_SIZE * 2 * NUM_SPECTRA * 8)
	_buffers.butterfly = _rd.storage_buffer_create(BOUNDARY_LOG2 * BOUNDARY_SIZE * 16)
	_buffers.events = _rd.storage_buffer_create(MAX_FORCES * 32)
	_buffers.pressures = _rd.storage_buffer_create(MAX_FORCES * 16)
	_surface_rid = _texture(grid_size, 1)
	_foam_rid = _texture(grid_size, 1)
	_derivative_rid = _texture(grid_size, 1)
	_breaker_rid = _texture(grid_size, 1, true)
	_contact_rid = _texture(grid_size, 1, true)
	_boundary_rid = _texture(BOUNDARY_SIZE, 6)
	_rd.texture_clear(_boundary_rid, Color(0, 0, 0, 0), 0, 1, 0, 6)
	if _breaking_rid.is_valid():
		if _breaking_fallback.is_valid():
			_rd.free_rid(_breaking_fallback)
		_breaking_fallback = RID()
	else:
		# Probe and lab sessions drive the solver without the FFT scene: bind
		# a cleared stand-in so every stage set still satisfies binding 19.
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		format.width = 4
		format.height = 4
		format.array_layers = 3
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		_breaking_fallback = _rd.texture_create(format, RDTextureView.new(), [])
		_rd.texture_clear(_breaking_fallback, Color(0, 0, 0, 0), 0, 1, 0, 3)
		_breaking_rid = _breaking_fallback
	for stage: String in STAGES:
		var uniforms: Array[RDUniform] = [
			_uniform(0, _spectrum_rid, true), _uniform(1, _buffers.bed),
			_uniform(2, _buffers.state), _uniform(3, _buffers.foam),
			_uniform(4, _buffers.completed_state), _uniform(5, _buffers.completed_foam),
			_uniform(6, _buffers.control), _uniform(7, _buffers.fft),
			_uniform(8, _buffers.butterfly), _uniform(9, _boundary_rid, true),
			_uniform(10, _surface_rid, true), _uniform(11, _foam_rid, true),
			_uniform(12, _buffers.events), _uniform(13, _buffers.pressures),
			_uniform(14, _derivative_rid, true),
			_uniform(15, _buffers.balance),
			_uniform(16, _buffers.slopes),
			_uniform(17, _buffers.disp),
			_uniform(18, _buffers.brk),
			_uniform(19, _breaking_rid, true),
			_uniform(20, _buffers.accel),
			_uniform(21, _buffers.disp_diagnostic),
			_uniform(22, _buffers.contact),
			_uniform(23, _buffers.completed_contact),
			_uniform(24, _breaker_rid, true),
			_uniform(25, _contact_rid, true),
			_uniform(26, _displacement_rid if _displacement_rid.is_valid() else _breaking_rid, true),
			_uniform(27, _buffers.visual_history),
			_uniform(28, _velocity_rid if _velocity_rid.is_valid() else _breaking_rid, true),
		]
		_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)
	var pc := _push_constants(0.0, 0.0, Vector2.ZERO, 0.0, 0.0, 0, 0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "butterfly", pc, BOUNDARY_SIZE / 128, BOUNDARY_LOG2, 1)
	_rd.compute_list_end()
	return true


func _reset_render() -> void:
	_reset_pending = false
	_initial_wave_pending = config.open_boundaries_enabled
	_progress_mutex.lock()
	_progress_generation += 1
	_progress_pending = false
	_progress_backlog_s = 0.0
	_progress_signal_m_s = 2.0 * sqrt(config.gravity_m_s2
		* maxf(config.boundary_depth_m, config.offshore_depth_m))
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd.buffer_clear(_buffers.control, 0, CONTROL_BYTES)
	if _reset_visual_history_pending:
		_rd.buffer_clear(_buffers.visual_history, 0,
			grid_size * grid_size * 64 if config.visual_breakers_enabled and _displacement_rid.is_valid() else 64)
		_visual_history_index = 0
	_reset_visual_history_pending = false
	var pc := _push_constants(0.0, 0.0, Vector2.ZERO, 0.0, 0.0, 0, 0)
	pc.encode_s32(84, _visual_history_index)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "init", pc, grid_size / 8, grid_size / 8, 1)
	_dispatch(cl, "output", pc, grid_size / 8, grid_size / 8, 1)
	_visual_history_index = 1 - _visual_history_index
	_rd.compute_list_end()


func _read_progress_render() -> void:
	_progress_mutex.lock()
	if _progress_pending:
		_progress_mutex.unlock()
		return
	_progress_pending = true
	var generation := _progress_generation
	_progress_mutex.unlock()
	_progress_interval_s = 0.0
	_rd.buffer_get_data_async(_buffers.control, _store_progress.bind(generation), 0, 64)


func _store_progress(data: PackedByteArray, generation: int) -> void:
	_progress_mutex.lock()
	if generation == _progress_generation:
		_progress_pending = false
		if data.size() == 64:
			_progress_backlog_s = data.decode_float(4) + data.decode_float(8)
			_progress_signal_m_s = data.decode_float(52)
	_progress_mutex.unlock()


func _inside_forces(forces: PackedVector4Array, pressure: bool) -> PackedVector4Array:
	var inside := PackedVector4Array()
	for force in forces:
		if not is_finite(force.x) or not is_finite(force.y) \
				or not is_finite(force.z) or not is_finite(force.w) \
			or absf(force.x) >= config.domain_m * 0.5 or absf(force.y) >= config.domain_m * 0.5:
			continue
		if pressure and force.z <= 0.0:
			continue
		inside.append(Vector4(force.x, force.y, force.z, maxf(force.w, 0.6)) if pressure else force)
		if inside.size() == MAX_FORCES:
			break
	return inside


func _push_constants(delta_s: float, time_s: float, current_m_s: Vector2,
		foam_amount: float, foam_decay: float, impulses: int, pressures: int) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, config.domain_m)
	pc.encode_float(4, config.domain_m / float(grid_size))
	pc.encode_float(8, config.gravity_m_s2)
	pc.encode_float(12, config.dry_depth_m)
	pc.encode_float(16, delta_s)
	pc.encode_float(20, time_s)
	pc.encode_float(24, foam_amount)
	pc.encode_float(28, foam_decay)
	for cascade in 3:
		pc.encode_float(32 + cascade * 4, _tiles[cascade])
	pc.encode_float(44, maxf(source_depth_m, 0.01))
	pc.encode_float(48, current_m_s.x)
	pc.encode_float(52, current_m_s.y)
	pc.encode_float(56, config.macro_step_s)
	pc.encode_float(60, config.minimum_wavelength_m)
	pc.encode_s32(64, grid_size)
	pc.encode_s32(68, _source_n)
	pc.encode_s32(72, impulses)
	pc.encode_s32(76, pressures)
	pc.encode_s32(92, MAX_FORCES)
	pc.encode_float(96, maxf(source_depth_m, 0.01))
	pc.encode_float(100, config.sponge_width_m)
	pc.encode_float(104, maxf(spectrum_depth_m, 0.01))
	pc.encode_float(108, 1000.0)
	pc.encode_float(112, 1.0 if config.open_boundaries_enabled else 0.0)
	pc.encode_float(116, incident_direction.x)
	pc.encode_float(120, incident_direction.y)
	pc.encode_float(124, config.breaker_max_radius_m)
	return pc


func _dispatch(cl: int, stage: String, pc: PackedByteArray, x: int, y: int, z: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, x, y, z)
	_rd.compute_list_add_barrier(cl)


func diagnose_dispersive_budgets_render(budgets: Array[int], anderson_depth: int = 0) -> Dictionary:
	if not _initialized or budgets.is_empty() or anderson_depth < 0 or anderson_depth > 3:
		return {}
	for budget: int in budgets:
		if budget <= 0:
			return {}
	var saved_disp: PackedByteArray = _rd.buffer_get_data(_buffers.disp)
	var saved_brk: PackedByteArray = _rd.buffer_get_data(_buffers.brk)
	var saved_diagnostic: PackedByteArray = _rd.buffer_get_data(_buffers.disp_diagnostic)
	var saved_control: PackedByteArray = _rd.buffer_get_data(_buffers.control)
	var active_control := saved_control.duplicate()
	active_control.encode_u32(64, grid_size / 8)
	active_control.encode_u32(68, grid_size / 8)
	active_control.encode_u32(72, 1)
	active_control.encode_u32(76, 0)
	active_control.encode_u32(96, grid_size)
	active_control.encode_u32(100, 1)
	active_control.encode_u32(104, 1)
	active_control.encode_u32(108, 0)
	var pc := _push_constants(0.0, saved_control.decode_float(0),
		Vector2(saved_control.decode_float(36), saved_control.decode_float(40)), 0.0, 0.0, 0, 0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "disp_grad", pc, grid_size / 8, grid_size / 8, 1)
	_dispatch(cl, "disp_rhs", pc, grid_size / 8, grid_size / 8, 1)
	_rd.compute_list_end()
	var fixed_rhs: PackedByteArray = _rd.buffer_get_data(_buffers.disp)
	var initial_brk: PackedByteArray = _rd.buffer_get_data(_buffers.brk)
	_rd.buffer_update(_buffers.control, 0, active_control.size(), active_control)
	pc.encode_s32(80, 5)
	cl = _rd.compute_list_begin()
	_dispatch(cl, "schedule", pc, 1, 1, 1)
	_dispatch(cl, "disp_residual", pc, grid_size / 8, grid_size / 8, 1)
	_rd.compute_list_end()
	var initial_residual := _rd.buffer_get_data(_buffers.control, 76, 4).decode_float(0)
	var histories: Array[Dictionary] = []
	for budget: int in budgets:
		_rd.buffer_update(_buffers.disp, 0, fixed_rhs.size(), fixed_rhs)
		_rd.buffer_update(_buffers.brk, 0, initial_brk.size(), initial_brk)
		_rd.buffer_update(_buffers.control, 0, active_control.size(), active_control)
		var history := PackedFloat32Array()
		var previous_xhat: Array[PackedFloat32Array] = []
		var previous_residual: Array[PackedFloat32Array] = []
		var anderson_updates := 0
		var rank_rejections := 0
		for iteration in budget:
			if anderson_depth == 0:
				cl = _rd.compute_list_begin()
				_dispatch(cl, "disp_solve_x", pc, grid_size, 1, 1)
				_dispatch(cl, "disp_solve_z", pc, grid_size, 1, 1)
				_dispatch(cl, "schedule", pc, 1, 1, 1)
				_dispatch(cl, "disp_residual", pc, grid_size / 8, grid_size / 8, 1)
				_rd.compute_list_end()
				history.append(_rd.buffer_get_data(_buffers.control, 76, 4).decode_float(0))
			else:
				var current := _read_brk_acceleration_render()
				cl = _rd.compute_list_begin()
				_dispatch(cl, "disp_solve_x", pc, grid_size, 1, 1)
				_dispatch(cl, "disp_solve_z", pc, grid_size, 1, 1)
				_rd.compute_list_end()
				var brk_bytes: PackedByteArray = _rd.buffer_get_data(_buffers.brk)
				var brk_values := brk_bytes.to_float32_array()
				var xhat := _extract_brk_acceleration(brk_values)
				var fixed_residual := PackedFloat32Array()
				fixed_residual.resize(xhat.size())
				for component in xhat.size():
					fixed_residual[component] = xhat[component] - current[component]
				var coefficients := _anderson_coefficients(fixed_residual, previous_residual, anderson_depth)
				if not coefficients.is_empty():
					var accelerated := xhat.duplicate()
					for component in accelerated.size():
						var value := float(xhat[component])
						for history_index in coefficients.size():
							var prior_index := previous_xhat.size() - coefficients.size() + history_index
							value -= coefficients[history_index] \
								* (float(xhat[component]) - float(previous_xhat[prior_index][component]))
						accelerated[component] = value
					if _is_finite_acceleration(accelerated):
						var accelerated_bytes := brk_bytes.duplicate()
						for cell in grid_size * grid_size:
							accelerated_bytes.encode_float(cell * 16 + 4, accelerated[cell * 2])
							accelerated_bytes.encode_float(cell * 16 + 8, accelerated[cell * 2 + 1])
						_rd.buffer_update(_buffers.brk, 0, accelerated_bytes.size(), accelerated_bytes)
						anderson_updates += 1
					else:
						rank_rejections += 1
				elif not previous_residual.is_empty():
					rank_rejections += 1
				previous_xhat.append(xhat)
				previous_residual.append(fixed_residual)
				if previous_xhat.size() > anderson_depth:
					previous_xhat.remove_at(0)
					previous_residual.remove_at(0)
				cl = _rd.compute_list_begin()
				_dispatch(cl, "schedule", pc, 1, 1, 1)
				_dispatch(cl, "disp_residual", pc, grid_size / 8, grid_size / 8, 1)
				_rd.compute_list_end()
				history.append(_rd.buffer_get_data(_buffers.control, 76, 4).decode_float(0))
		histories.append({"budget": budget, "residuals": history,
			"final_residual": history[history.size() - 1],
			"contraction": history[history.size() - 1] / maxf(initial_residual, 1.0e-12),
			"anderson_updates": anderson_updates, "rank_rejections": rank_rejections})
	_rd.buffer_update(_buffers.disp, 0, saved_disp.size(), saved_disp)
	_rd.buffer_update(_buffers.brk, 0, saved_brk.size(), saved_brk)
	_rd.buffer_update(_buffers.disp_diagnostic, 0, saved_diagnostic.size(), saved_diagnostic)
	_rd.buffer_update(_buffers.control, 0, saved_control.size(), saved_control)
	return {"physical_time_s": saved_control.decode_float(0), "grid_size": grid_size,
		"rhs_source": "frozen_state_last_FV_tendency",
		"initial_guess": "previous_acceleration",
		"method": "gauss_seidel" if anderson_depth == 0 else "cpu_readback_anderson",
		"anderson_depth": anderson_depth, "memory": "unavailable", "gpu_timing": "unavailable",
		"initial_residual": initial_residual, "histories": histories}


func _read_brk_acceleration_render() -> PackedFloat32Array:
	var brk_values: PackedFloat32Array = _rd.buffer_get_data(_buffers.brk).to_float32_array()
	return _extract_brk_acceleration(brk_values)


func _extract_brk_acceleration(brk_values: PackedFloat32Array) -> PackedFloat32Array:
	var acceleration := PackedFloat32Array()
	acceleration.resize(grid_size * grid_size * 2)
	for cell in grid_size * grid_size:
		acceleration[cell * 2] = brk_values[cell * 4 + 1]
		acceleration[cell * 2 + 1] = brk_values[cell * 4 + 2]
	return acceleration


func _is_finite_acceleration(values: PackedFloat32Array) -> bool:
	for value in values:
		if not is_finite(value):
			return false
	return true


func _anderson_coefficients(current_residual: PackedFloat32Array,
		residual_history: Array[PackedFloat32Array], depth: int) -> PackedFloat64Array:
	var count := mini(depth, residual_history.size())
	var coefficients := PackedFloat64Array()
	if count == 0:
		return coefficients
	var deltas: Array[PackedFloat32Array] = []
	for column in count:
		var previous := residual_history[residual_history.size() - count + column]
		var delta := PackedFloat32Array()
		delta.resize(current_residual.size())
		for component in current_residual.size():
			delta[component] = current_residual[component] - previous[component]
		deltas.append(delta)
	var gram := PackedFloat64Array()
	gram.resize(count * count)
	var projection := PackedFloat64Array()
	projection.resize(count)
	for i in count:
		for component in current_residual.size():
			projection[i] += float(deltas[i][component]) * float(current_residual[component])
			for j in count:
				gram[i * count + j] += float(deltas[i][component]) * float(deltas[j][component])
	var diagonal_scale := 0.0
	for i in count:
		diagonal_scale = maxf(diagonal_scale, absf(gram[i * count + i]))
	if not is_finite(diagonal_scale) or diagonal_scale <= 0.0:
		return PackedFloat64Array()
	var rank_threshold := diagonal_scale * 1.0e-10
	for column in count:
		var pivot_row := column
		var pivot_magnitude := absf(gram[column * count + column])
		for row in range(column + 1, count):
			var magnitude := absf(gram[row * count + column])
			if magnitude > pivot_magnitude:
				pivot_magnitude = magnitude
				pivot_row = row
		if not is_finite(pivot_magnitude) or pivot_magnitude <= rank_threshold:
			return PackedFloat64Array()
		if pivot_row != column:
			for j in count:
				var swap_value := gram[column * count + j]
				gram[column * count + j] = gram[pivot_row * count + j]
				gram[pivot_row * count + j] = swap_value
			var swap_projection := projection[column]
			projection[column] = projection[pivot_row]
			projection[pivot_row] = swap_projection
		for row in range(column + 1, count):
			var factor := gram[row * count + column] / gram[column * count + column]
			for j in range(column, count):
				gram[row * count + j] -= factor * gram[column * count + j]
			projection[row] -= factor * projection[column]
	coefficients.resize(count)
	for row in range(count - 1, -1, -1):
		var value := projection[row]
		for j in range(row + 1, count):
			value -= gram[row * count + j] * coefficients[j]
		if not is_finite(value) or absf(gram[row * count + row]) <= rank_threshold:
			return PackedFloat64Array()
		coefficients[row] = value / gram[row * count + row]
		if not is_finite(coefficients[row]):
			return PackedFloat64Array()
	return coefficients


func _dispatch_dispersive(cl: int, pc: PackedByteArray) -> int:
	if config.visual_breakers_enabled and pc.decode_s32(88) == 0:
		return cl
	var schedule_mode := pc.decode_s32(80)
	if not config.visual_breakers_enabled:
		_dispatch_indirect(cl, "disp_grad", pc, 64)
		_dispatch_indirect(cl, "disp_rhs", pc, 64)
		for iteration in config.dispersive_iterations:
			_dispatch_indirect(cl, "disp_solve_x", pc, 96)
			_dispatch_indirect(cl, "disp_solve_z", pc, 96)
			pc.encode_s32(80, 5)
			_dispatch(cl, "schedule", pc, 1, 1, 1)
			_dispatch_indirect(cl, "disp_residual", pc, 112)
			pc.encode_s32(80, 6)
			_dispatch(cl, "schedule", pc, 1, 1, 1)
		pc.encode_s32(80, schedule_mode)
		_dispatch_indirect(cl, "disp_apply", pc, 64)
		cl = _mark(cl, "shore/dispersion")
	pc.encode_s32(80, 7)
	_dispatch(cl, "schedule", pc, 1, 1, 1)
	_dispatch_indirect(cl, "visc_x", pc, 96)
	_dispatch_indirect(cl, "visc_z", pc, 96)
	pc.encode_s32(80, schedule_mode)
	return _mark(cl, "shore/viscosity")


func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


func _dispatch_indirect(cl: int, stage: String, pc: PackedByteArray, offset: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch_indirect(cl, _buffers.control, offset)
	_rd.compute_list_add_barrier(cl)


func _texture(size: int, layers: int, half_precision: bool = false) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY if layers > 1 else RenderingDevice.TEXTURE_TYPE_2D
	format.width = size
	format.height = size
	format.array_layers = layers
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT if half_precision \
		else RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])


func _uniform(binding: int, rid: RID, image: bool = false) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if image else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform
