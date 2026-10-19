class_name OceanSolver
extends RefCounted
## Tessendorf FFT ocean on RenderingDevice compute. Per cascade and per frame:
## [spectrum_init if dirty] -> spectrum_evolve -> Stockham row IFFT ->
## transpose -> row IFFT -> map_assemble (displacement + normals + Jacobian
## foam). Everything stays on the GPU; the surface material samples the two
## output texture arrays through Texture2DArrayRD.

const SHADER_DIR := "res://shaders/ocean/"
const SpectrumMetrics := preload("res://scripts/ocean/ocean_spectrum_metrics.gd")
const STAGES: Array[String] = [
	"spectrum_init", "spectrum_evolve", "fft_butterfly", "fft",
	"transpose", "map_assemble",
]
const NUM_SPECTRA := 4
const GRAVITY := 9.81
const WATER_DENSITY_KG_M3 := 1025.0
const MIN_WAVELENGTH_M := OceanConfig.MIN_WAVELENGTH_M
const FOAM_NOISE_TEXTURE := preload("res://resources/ocean/foam_detail.png")
## Chop stays full on the long/mid cascades: crests pinch and the Jacobian
## fold — which the foam feeds on — survives at the scales the eye reads.
## Only the fine cascade is damped: full choppiness there folds the surface
## into black back-faces faster than foam can cover them.
const CHOP_PER_CASCADE: PackedFloat32Array = [1.0, 1.0, 0.78]
const TILE_LENGTHS: PackedFloat32Array = [2039.0, 111.0, 25.0]
const JONSWAP_MAX_HEIGHT_GAIN := 3.0
const JONSWAP_BASE_HEIGHT_KNEE_M := 8.0
const JONSWAP_BASE_HEIGHT_LIMIT_M := 10.0
const JONSWAP_TOTAL_HEIGHT_KNEE_M := 8.0
const JONSWAP_TOTAL_HEIGHT_LIMIT_M := 15.0
const JONSWAP_MAX_CHOPPINESS := 1.8
const JONSWAP_CHOPPINESS_KNEE := 1.1
const JONSWAP_CHOPPINESS_LIMIT := 1.35
const JONSWAP_FINE_CHOPPINESS_LIMIT := 0.86
const SWELL_MAX_SIGNIFICANT_STEEPNESS := 0.08

## Wave generation model, driven by OceanPreset.wave_model (int: 0 = FFT, 1 =
## TUTORIAL_GERSTNER; kept as plain int so the two enum types stay assignable).
## FFT runs all three cascades through the spectrum pipeline; TUTORIAL_GERSTNER
## zeroes long/mid and displaces the short cascade with the five periodic
## tutorial waves.
enum WaveModel { FFT, TUTORIAL_GERSTNER }

var config: OceanConfig = OceanConfig.new()
var map_size := 512
## Pairwise non-commensurate lengths (2039/111 = 18.4, 111/25 = 4.44), so the
## super-period of the combined field exceeds any view. Sorted large ->
## small; k-space bands are cut between them. Cascade 0 must hold the spectral
## peak: storm winds put lambda_p near 500 m, so the big tile has to exceed
## that or storms lose their swell. The short 111/25 m tiles give the mid band
## (lambda 4-20 m, where chop reads) ~11 cm texels at 1024^2 — the density the
## reference GodotOceanWaves demo gets from its 57 m tile.
var tile_lengths: PackedFloat32Array = TILE_LENGTHS.duplicate()
var wave_model: int = WaveModel.FFT
var wind_speed := 11.0
var wind_direction := 0.0
var fetch_km := 120.0
var water_depth := 80.0
var swell := 0.8
var swell_height_m := 0.0
var swell_period_s := 12.0
var swell_direction_rad := 0.0
var swell_spread := 0.15
var current_velocity_m_s := Vector2.ZERO
var physical_features_enabled := true
var velocity_solver := OceanVelocitySolver.new()
var local_solver := OceanLocalSolver.new()
var shore_solver := OceanShoreSolver.new()
var shore_enabled := false
var shore_bathymetry := PackedFloat32Array()
var _wake_mutex := Mutex.new()
var _wake_impulses: Dictionary = {}
var _body_pressures: Dictionary = {}
var spread := 0.2
var detail := 1.0
var jonswap_gamma := 3.3
var choppiness := 1.15
var long_wave_height_m := 2.6
var long_wave_length_m := 48.0
var mid_wave_height_m := 0.0
var mid_wave_length_m := 24.0
var wind_wave_height_m := 0.8
var wind_wave_length_m := 7.5
var crest_bias := 0.08
var crest_gain := 2.4
## Master wave height multiplier, applied k-weighted in spectrum_init (swell
## boost, e-fold at 60 m): short wavelets keep physical steepness even at 5x.
## Changing it requires mark_spectrum_dirty().
var height_gain := 1.0
## Overall amplitude multiplier; 1.0 preserves the spectral energy.
## Requires mark_spectrum_dirty().
var amplitude_scale := 1.0
var whitecap := 0.82
var foam_amount := 3.5
var foam_persistence := 5.0
## Accumulated sim time, pushed by the controller every frame.
var sim_time := 0.0
## Update one cascade per frame round-robin instead of all of them.
var amortize := false
var quality_tier: int = OceanQualityProfile.default_tier()

var initialized := false
var profiling := false
var foam_feedback_enabled := true
## Update the finest cascade every other frame. Its wave periods (lambda <
## tile/6) are seconds long, and phases keep advancing with sim_time, so a
## 33 ms displacement hold is invisible; the foam decay compensates through
## foam_step_scale. Saves one spectrum+FFT+assemble chain in three.
var short_cascade_half_rate := false

## Camera-centred near-field foam feedback (shaders/ocean/ocean_foam_near.comp).
## The controller pushes the camera xz every frame; the window follows it and
## reprojects RG (residual, active) coverage so foam stays world-anchored. Its radius
## follows the active quality profile and can be overridden from the menu.
## Production (FFT) wave model only: the tutorial keeps its own per-cascade
## ping-pong.
var foam_near_enabled := true
var foam_near_size := 2048
var foam_near_domain := 256.0
## Update the near feedback every Nth frame (Performance profile: 2).
var foam_near_stride := 1
## Camera xz for the near feedback window; main-thread write, render-thread read.
var near_center := Vector2.ZERO

## GPU point queries against the rendered surface (shaders/ocean/ocean_query.comp):
## the controller submits world xz positions each tick and reads the previous
## tick's results — max one frame of latency, never a blocking readback.
const MAX_QUERY_POINTS := 64

var _query_has_pending := false
var _query_submitted_count := 0
var _query_latest := PackedVector4Array()
var _query_results_valid := false
var _query_generation := 0
var _query_mutex := Mutex.new()
var _query_next_id := 1
var _query_pending_batch: OceanQueryBatch
var _query_completed_batch: OceanQueryBatch
var _query_replaced_ids := PackedInt64Array()
var _query_published_id := 0

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _spectrum_tex := RID()
var _displacement_tex := RID()
var _normal_tex := RID()
var _derivative_tex := RID()
var _foam_near_tex_a := RID()
var _foam_near_tex_b := RID()
var _foam_mip_views: Array[RID] = []
var _foam_mip_count := 1
var _spectral_references: Array[Dictionary] = []
var _moment_key := PackedFloat64Array()
var _physical_moments: Dictionary = {}
var _breaking_settings := Vector4.ZERO
var _render_time := 0.0
var _render_center := Vector2.ZERO
var _published_foam_state := {"center": Vector2.ZERO, "index": 0, "time": 0.0, "step": 0}
var _foam_state_mutex := Mutex.new()
var _spectral_mutex := Mutex.new()
var _foam_near_read_index := 0
var _foam_near_dt := 0.0
var _near_center_prev := Vector2.ZERO
var _foam_noise_rd := RID()
var _foam_sampler := RID()
var _foam_reset_pending := false
var _foam_near_reset_pending := false
var _cascade_dirty: Array[bool] = []
var _render_refresh_pending := false
var _frame := 0
var _timing_store := GpuTimingStore.new()


static func shader_header(map_n: int) -> String:
	return "#version 450\n#define MAP_SIZE %du\n#define MAP_SIZE_I %d\n#define MIN_WAVELENGTH_M %.8f\n#define NUM_SPECTRA %du\n\n" % [
		map_n, map_n, MIN_WAVELENGTH_M, NUM_SPECTRA,
	]


func num_cascades() -> int:
	return tile_lengths.size()


func get_displacement_tex_rid() -> RID:
	return _displacement_tex


func get_normal_tex_rid() -> RID:
	return _normal_tex


func get_derivative_tex_rid() -> RID:
	return _derivative_tex


func get_breaking_settings_rid() -> RID:
	return _buffers.get("breaking_settings", RID())


func get_foam_near_read_tex_rid() -> RID:
	return _foam_near_tex_a if _foam_near_read_index == 0 else _foam_near_tex_b


func get_foam_near_tex_rid(index: int) -> RID:
	return _foam_near_tex_a if index == 0 else _foam_near_tex_b


func get_foam_near_read_index() -> int:
	return _foam_near_read_index


func foam_field_domains() -> Vector3:
	return Vector3(foam_near_domain, foam_near_domain * 4.0, foam_near_domain * 16.0)


func foam_state() -> Dictionary:
	_foam_state_mutex.lock()
	var snapshot := _published_foam_state.duplicate()
	_foam_state_mutex.unlock()
	return snapshot


func spectral_references() -> Array[Dictionary]:
	_spectral_mutex.lock()
	if _spectral_references.is_empty():
		_spectral_references = SpectrumMetrics.compute(self)
		_update_breaking_settings()
	var snapshot: Array[Dictionary] = _spectral_references
	_spectral_mutex.unlock()
	return snapshot


func foam_near_active() -> bool:
	return foam_near_enabled \
			and _foam_near_tex_a.is_valid()


## VRAM actually allocated by the current map/near-foam sizes.
func estimate_vram_bytes() -> int:
	return OceanQualityProfile.estimate_vram_bytes_for(map_size, foam_near_size) \
		+ velocity_solver.estimate_vram_bytes() + local_solver.estimate_vram_bytes() \
		+ shore_solver.estimate_vram_bytes()


func get_shore_texture_rid() -> RID:
	return shore_solver.get_texture_rid() if shore_enabled else local_solver.get_coast_texture_rid()


func get_shore_foam_texture_rid() -> RID:
	return shore_solver.get_foam_texture_rid() if shore_enabled else local_solver.get_coast_texture_rid()


func get_shore_derivative_texture_rid() -> RID:
	return shore_solver.get_derivative_texture_rid() if shore_enabled else local_solver.get_coast_texture_rid()


func get_shore_breaker_texture_rid() -> RID:
	return shore_solver.get_breaker_texture_rid() if shore_enabled else local_solver.get_coast_texture_rid()


func get_shore_contact_texture_rid() -> RID:
	return shore_solver.get_contact_texture_rid() if shore_enabled else local_solver.get_coast_texture_rid()


## Queue world-space query points for the next step. Results land one frame
## later; read them with latest_results(). At most MAX_QUERY_POINTS are kept.
func submit_queries(points: PackedVector2Array) -> int:
	var batch := OceanQueryBatch.new()
	_query_mutex.lock()
	batch.id = _query_next_id
	_query_next_id += 1
	batch.revision = _query_generation
	batch.points = points.slice(0, mini(points.size(), MAX_QUERY_POINTS))
	if _query_pending_batch != null:
		_query_replaced_ids.append(_query_pending_batch.id)
	_query_pending_batch = batch
	_query_has_pending = true
	_query_mutex.unlock()
	return batch.id


func take_query_batch() -> OceanQueryBatch:
	_query_mutex.lock()
	var batch := _query_completed_batch
	_query_completed_batch = null
	_query_mutex.unlock()
	return batch


func take_replaced_query_ids() -> PackedInt64Array:
	_query_mutex.lock()
	var ids := _query_replaced_ids
	_query_replaced_ids = PackedInt64Array()
	_query_mutex.unlock()
	return ids


## Last completed query results, one vec4 per submitted slot:
## (height_m, slope_x, slope_z, valid). Empty until the first readback lands.
func latest_results() -> PackedVector4Array:
	return _query_latest


func query_results_valid() -> bool:
	return _query_results_valid


func set_foam_distance(distance: float) -> void:
	var domain := clampf(distance, 16.0, 512.0) * 2.0
	if is_equal_approx(foam_near_domain, domain):
		return
	foam_near_domain = domain
	_near_center_prev = near_center
	_foam_near_reset_pending = true
	_render_refresh_pending = true


## Sea-state params changed: regenerate the initial spectra (cheap, one 256²
## dispatch per cascade; phases stay stable thanks to the fixed seeds).
func mark_spectrum_dirty() -> void:
	local_solver.request_reset()
	shore_solver.reset(false)
	_spectral_mutex.lock()
	_spectral_references = SpectrumMetrics.compute(self)
	_update_breaking_settings()
	_spectral_mutex.unlock()
	_query_mutex.lock()
	_query_generation += 1
	_query_results_valid = false
	if _query_completed_batch != null:
		_query_replaced_ids.append(_query_completed_batch.id)
	_query_completed_batch = null
	if _query_pending_batch != null:
		_query_replaced_ids.append(_query_pending_batch.id)
	_query_pending_batch = null
	_query_has_pending = false
	_query_mutex.unlock()
	for i in _cascade_dirty.size():
		_cascade_dirty[i] = true
	_foam_reset_pending = true
	_render_refresh_pending = true


func request_render_refresh() -> void:
	_spectral_mutex.lock()
	_spectral_references.clear()
	_spectral_mutex.unlock()
	_render_refresh_pending = true


func take_render_refresh_request() -> bool:
	var pending := _render_refresh_pending
	_render_refresh_pending = false
	return pending


func init_render() -> void:
	config.map_size = map_size
	config.clipmap_tile_lengths_m = tile_lengths
	var config_error := config.validate()
	if config_error != "":
		push_error("Ocean config: %s" % config_error)
		return
	_rd = GpuPreflight.device("OceanSolver")
	if _rd == null:
		return
	var texture_limit := _rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)
	if map_size > texture_limit or foam_near_size > texture_limit \
			or not OceanQualityProfile.fft_size_supported(map_size, _rd):
		push_error("Ocean GPU resources exceed texture or compute limits")
		return

	var defines := shader_header(map_size)
	var common := FileAccess.get_file_as_string(SHADER_DIR + "ocean_common.comp")
	var deformation := FileAccess.get_file_as_string(SHADER_DIR + "ocean_deformation.gdshaderinc")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "ocean_" + stage + ".comp")
		if not _compile_stage_render(stage, defines + deformation + common + "\n" + stage_src):
			return

	var n := map_size
	var cascades := num_cascades()
	var log2n := int(log(float(n)) / log(2.0) + 0.5)

	var butterfly_bytes := PackedByteArray()
	butterfly_bytes.resize(log2n * n * 16)
	_buffers["butterfly"] = _rd.storage_buffer_create(butterfly_bytes.size(), butterfly_bytes)

	var fft_bytes := PackedByteArray()
	fft_bytes.resize(cascades * 2 * NUM_SPECTRA * n * n * 8)
	_buffers["fft_data"] = _rd.storage_buffer_create(fft_bytes.size(), fft_bytes)
	_buffers["swell_settings"] = _rd.storage_buffer_create(16)
	_buffers["breaking_settings"] = _rd.storage_buffer_create(16)

	_spectrum_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_displacement_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_normal_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_derivative_tex = _create_tex_array(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_foam_noise_rd = RenderingServer.texture_get_rd_texture(FOAM_NOISE_TEXTURE.get_rid())
	_foam_sampler = _create_foam_sampler()
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _derivative_tex]:
		_rd.texture_clear(tex, Color(0, 0, 0, 0), 0, 1, 0, cascades)

	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		uniforms.append(_image_uniform(0, _spectrum_tex))
		uniforms.append(_buffer_uniform(1, _buffers["butterfly"]))
		uniforms.append(_buffer_uniform(2, _buffers["fft_data"]))
		uniforms.append(_image_uniform(3, _displacement_tex))
		uniforms.append(_image_uniform(4, _normal_tex))
		if stage == "spectrum_init":
			uniforms.append(_buffer_uniform(5, _buffers["swell_settings"]))
		if stage == "map_assemble":
			uniforms.append(_sampled_texture_uniform(7, _foam_noise_rd))
			uniforms.append(_image_uniform(8, _derivative_tex))
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)
	if not velocity_solver.init_render(_spectrum_tex, map_size, tile_lengths, water_depth):
		free_render()
		return
	if not local_solver.init_render(_displacement_tex, velocity_solver.get_texture_rid(),
			map_size, tile_lengths, OceanQualityProfile.COAST_SIZE[quality_tier],
			OceanQualityProfile.WAKE_SIZE[quality_tier], water_depth):
		free_render()
		return
	if shore_enabled:
		shore_solver.source_depth_m = OceanShoreSolver.RING_DEPTH_M
		shore_solver.spectrum_depth_m = water_depth
		if not shore_solver.init_render(_spectrum_tex, map_size, tile_lengths,
				quality_tier, shore_bathymetry, _derivative_tex, _displacement_tex,
				velocity_solver.get_texture_rid()):
			free_render()
			return

	if not _compile_stage_render("foam_near", defines + deformation
			+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_foam_near.comp")):
		return
	_foam_mip_count = int(log(float(foam_near_size)) / log(2.0)) + 1
	_foam_near_tex_a = _create_foam_array()
	_foam_near_tex_b = _create_foam_array()
	# Vulkan image memory is undefined until cleared, and the first near
	# dispatch reads the input half.
	_clear_foam_fields()
	if not _compile_stage_render("foam_mipmap", defines
			+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_foam_mipmap.comp")):
		return
	for index in 2:
		var output := get_foam_near_tex_rid(index)
		for layer in 3:
			var previous_view := RID()
			for mip in _foam_mip_count:
				var view := _rd.texture_create_shared_from_slice(RDTextureView.new(), output, layer, mip)
				_foam_mip_views.append(view)
				if mip == 0:
					var stage := ("foam_near_ab" if index == 1 else "foam_near_ba")
					if layer > 0:
						stage += "_%d" % layer
					var uniforms: Array[RDUniform] = [
						_sampled_texture_uniform(0, _derivative_tex),
						_sampled_texture_uniform(1, get_foam_near_tex_rid(1 - index)),
						_image_uniform(2, view),
						_sampled_texture_uniform(3, local_solver.get_coast_texture_rid()),
						_sampled_texture_uniform(4, local_solver.get_wake_texture_rid()),
						_sampled_texture_uniform(5, _displacement_tex),
					]
					_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders["foam_near"], 0)
					_pipelines[stage] = _rd.compute_pipeline_create(_shaders["foam_near"])
				else:
					var key := "foam_mip_%d_%d_%d" % [index, layer, mip]
					var uniforms: Array[RDUniform] = [_image_uniform(0, previous_view), _image_uniform(1, view)]
					_uniform_sets[key] = _rd.uniform_set_create(uniforms, _shaders["foam_mipmap"], 0)
				previous_view = view
	_foam_near_read_index = 0
	_foam_near_dt = 0.0

	# GPU point queries: two tiny buffers plus one dispatch per submitted
	# batch; results come back through buffer_get_data_async.
	if not _compile_stage_render("query", defines + deformation
			+ FileAccess.get_file_as_string(SHADER_DIR + "ocean_query.comp")):
		return
	_buffers["query_in"] = _rd.storage_buffer_create(MAX_QUERY_POINTS * 8)
	_buffers["query_out"] = _rd.storage_buffer_create(MAX_QUERY_POINTS * 32)
	var query_uniforms: Array[RDUniform] = [
		_buffer_uniform(0, _buffers["query_in"]),
		_buffer_uniform(1, _buffers["query_out"]),
		_image_uniform(2, _displacement_tex),
		_image_uniform(3, _derivative_tex),
		_sampled_texture_uniform(4, velocity_solver.get_texture_rid()),
		_sampled_texture_uniform(5, local_solver.get_coast_texture_rid()),
		_sampled_texture_uniform(6, local_solver.get_wake_texture_rid()),
		_sampled_texture_uniform(7, get_shore_texture_rid()),
		_sampled_texture_uniform(8, get_shore_derivative_texture_rid()),
	]
	_uniform_sets["query"] = _rd.uniform_set_create(
		query_uniforms, _shaders["query"], 0)
	_query_has_pending = false
	_query_results_valid = false
	_query_submitted_count = 0

	_cascade_dirty.resize(cascades)
	mark_spectrum_dirty()
	_foam_reset_pending = false
	_foam_near_reset_pending = false

	# Butterfly factors depend only on MAP_SIZE: dispatch once.
	var pc := _pack_push_constant(0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "fft_butterfly", pc, maxi(n / 128, 1), log2n, 1)
	_rd.compute_list_end()

	_frame = 0
	initialized = true


func _compile_stage_render(stage: String, source: String) -> bool:
	var spirv := ShaderCache.compile(_rd, "ocean_" + stage, source)
	if not spirv.compile_error_compute.is_empty():
		push_error("Ocean stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
		free_render()
		return false
	_shaders[stage] = _rd.shader_create_from_spirv(spirv)
	_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])
	return true


func step_render(delta: float, step_time: float = -1.0, step_center: Vector2 = Vector2(INF, INF)) -> void:
	if not initialized:
		return
	_render_time = sim_time if step_time < 0.0 else step_time
	_render_center = near_center if not step_center.is_finite() else step_center
	if profiling:
		_read_timings()
	if _foam_reset_pending:
		_clear_foam_fields()
		_foam_near_read_index = 0
		_foam_near_dt = 0.0
		_foam_reset_pending = false
		_foam_near_reset_pending = false
	elif _foam_near_reset_pending:
		_clear_foam_fields()
		_foam_near_read_index = 0
		_foam_near_dt = 0.0
		_foam_near_reset_pending = false

	var g16 := map_size / 16
	var g32 := map_size / 32
	var cascade_list: Array = []
	if amortize:
		for i in num_cascades():
			if i == _frame % num_cascades() or _cascade_dirty[i]:
				cascade_list.append(i)
	else:
		for i in num_cascades():
			# The fine cascade skips odd frames once short_cascade_half_rate is
			# set; a dirty spectrum (preset edit) always runs immediately.
			if i < num_cascades() - 1 or not short_cascade_half_rate \
					or _frame % 2 == 0 or _cascade_dirty[i]:
				cascade_list.append(i)

	if profiling:
		_rd.capture_timestamp("ocean/start")
	if true in _cascade_dirty:
		var swell_settings := PackedByteArray()
		swell_settings.resize(16)
		swell_settings.encode_float(0, TAU / effective_swell_period())
		swell_settings.encode_float(4, SpectrumMetrics.compute_swell_alpha_scale(self)
			* pow(effective_amplitude_scale(), 2.0))
		swell_settings.encode_float(8, swell_direction_rad)
		swell_settings.encode_float(12, swell_spread)
		_rd.buffer_update(_buffers["swell_settings"], 0, 16, swell_settings)
		_spectral_mutex.lock()
		var breaking: Vector4 = _breaking_settings
		_spectral_mutex.unlock()
		var breaking_bytes := PackedFloat32Array([breaking.x, breaking.y, breaking.z, breaking.w]).to_byte_array()
		_rd.buffer_update(_buffers["breaking_settings"], 0, breaking_bytes.size(), breaking_bytes)
	var cl := _rd.compute_list_begin()
	for i in cascade_list:
		var pc := _pack_push_constant(i, _render_time)
		if _cascade_dirty[i]:
			_dispatch(cl, "spectrum_init", pc, g16, g16, 1)
			_cascade_dirty[i] = false
		_dispatch(cl, "spectrum_evolve", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/spectrum")
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		_dispatch(cl, "transpose", pc, g32, g32, NUM_SPECTRA)
		_dispatch(cl, "fft", pc, 1, map_size, NUM_SPECTRA)
		cl = _mark(cl, "ocean/fft")
		_dispatch(cl, "map_assemble", pc, g16, g16, 1)
		cl = _mark(cl, "ocean/assemble")
	_rd.compute_list_end()
	if physical_features_enabled:
		velocity_solver.set_water_depth(water_depth)
		local_solver.set_water_depth(water_depth)
		velocity_solver.step_render(_render_time, current_velocity_m_s)
		if profiling:
			_rd.capture_timestamp("ocean/velocity")
		_wake_mutex.lock()
		var impulses := PackedVector4Array(_wake_impulses.values())
		var pressures := PackedVector4Array(_body_pressures.values())
		_wake_impulses.clear()
		_wake_mutex.unlock()
		if shore_enabled:
			shore_solver.source_depth_m = OceanShoreSolver.RING_DEPTH_M
			shore_solver.spectrum_depth_m = water_depth
			shore_solver.whitecap_threshold = whitecap
			shore_solver.profiling = profiling
			var incident_angle := swell_direction_rad if _breaking_settings.w > 0.5 else wind_direction
			shore_solver.incident_direction = Vector2(cos(incident_angle), sin(incident_angle))
			shore_solver.step_render(delta, _render_time, current_velocity_m_s,
				foam_amount if foam_feedback_enabled else 0.0,
				0.693 / maxf(foam_persistence, 0.05),
				impulses, pressures)
		else:
			local_solver.step_render(delta, _render_time, _render_center,
				current_velocity_m_s, impulses, pressures)
		if profiling:
			_rd.capture_timestamp("ocean/coast" if shore_enabled else "ocean/local")
	cl = _rd.compute_list_begin()
	# Near-field feedback once per (stride) frames, on the accumulated dt.
	_foam_near_dt += delta
	if foam_near_enabled:
		if _frame % maxi(foam_near_stride, 1) == 0:
			var near_stage := "foam_near_ab" if _foam_near_read_index == 0 \
				else "foam_near_ba"
			for layer in 3:
				var stage := near_stage if layer == 0 else near_stage + "_%d" % layer
				_dispatch(cl, stage, _pack_near_push_constant(_foam_near_dt, layer),
					foam_near_size / 16, foam_near_size / 16, 1)
			_foam_near_read_index = 1 - _foam_near_read_index
			_generate_foam_mips(cl, _foam_near_read_index)
			_near_center_prev = _render_center
			_foam_near_dt = 0.0
			cl = _mark(cl, "ocean/foam_near")
	else:
		# Keep the accumulator pinned while the field is off, so re-enabling
		# never replays the whole off period as one giant decay/injection step.
		_foam_near_dt = 0.0
	_rd.compute_list_end()
	_dispatch_pending_queries()
	if profiling:
		_rd.capture_timestamp("ocean/end")
	_frame += 1
	_foam_state_mutex.lock()
	_published_foam_state = {"center": _near_center_prev, "index": _foam_near_read_index,
		"time": _render_time, "step": _frame, "local_centers": Vector4(
			local_solver.coast_center().x, local_solver.coast_center().y,
			local_solver.wake_center().x, local_solver.wake_center().y)}
	_foam_state_mutex.unlock()


## Render thread. Uploads the pending points, dispatches one query pass and
## kicks the async readback. buffer_update must run between compute lists.
func _dispatch_pending_queries() -> void:
	_query_mutex.lock()
	var batch := _query_pending_batch
	_query_pending_batch = null
	_query_has_pending = false
	_query_mutex.unlock()
	if batch == null:
		return
	var points := batch.points
	if points.is_empty():
		return
	batch.simulation_time_s = _render_time
	_query_submitted_count = points.size()
	var in_bytes := PackedByteArray()
	in_bytes.resize(MAX_QUERY_POINTS * 8)
	for i in points.size():
		in_bytes.encode_float(i * 8, points[i].x)
		in_bytes.encode_float(i * 8 + 4, points[i].y)
	_rd.buffer_update(_buffers["query_in"], 0, in_bytes.size(), in_bytes)
	var pc := PackedByteArray()
	pc.resize(96)
	pc.encode_float(0, tile_lengths[0])
	pc.encode_float(4, tile_lengths[1])
	pc.encode_float(8, tile_lengths[2])
	pc.encode_float(12, float(map_size))
	pc.encode_s32(16, num_cascades())
	pc.encode_s32(20, points.size())
	pc.encode_s32(24, 1 if physical_features_enabled else 0)
	var coast_center: Vector2 = local_solver.coast_center()
	var wake_center: Vector2 = local_solver.wake_center()
	pc.encode_float(32, coast_center.x)
	pc.encode_float(36, coast_center.y)
	pc.encode_float(40, wake_center.x)
	pc.encode_float(44, wake_center.y)
	pc.encode_float(48, OceanLocalSolver.COAST_DOMAIN_M)
	pc.encode_float(52, OceanLocalSolver.WAKE_DOMAIN_M)
	pc.encode_float(64, current_velocity_m_s.x)
	pc.encode_float(68, current_velocity_m_s.y)
	var shore_depth_blend := shore_solver.config.surface_depth_blend_m()
	pc.encode_float(72, shore_depth_blend.x)
	pc.encode_float(76, shore_depth_blend.y)
	pc.encode_float(80, 1.0 if shore_enabled else 0.0)
	pc.encode_float(84, shore_solver.config.domain_m)
	pc.encode_float(88, shore_solver.config.surface_blend_width_m())
	pc.encode_float(92, 1.0 if shore_solver.config.visual_breakers_enabled else 0.0)
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "query", pc, 1, 1, 1)
	_rd.compute_list_end()
	# Timestamped as its own segment: everything after the last stage mark and
	# before "ocean/end" is the query dispatch.
	if profiling:
		_rd.capture_timestamp("ocean/query")
	var payload := {"id": batch.id, "revision": batch.revision,
		"time": batch.simulation_time_s, "points": batch.points}
	_rd.buffer_get_data_async(_buffers["query_out"],
		_store_query_results.bind(payload),
		0, MAX_QUERY_POINTS * 32)


# Render thread: decode the readback, then hop to the main thread. Only the
# submitted slots are meaningful; the rest of the buffer stays stale.
func _store_query_results(data: PackedByteArray, payload: Dictionary) -> void:
	_query_mutex.lock()
	var current: bool = payload.revision == _query_generation
	if not current:
		_query_replaced_ids.append(payload.id)
	_query_mutex.unlock()
	if not current:
		return
	var batch := OceanQueryBatch.new()
	batch.id = payload.id
	batch.revision = payload.revision
	batch.simulation_time_s = payload.time
	batch.points = payload.points
	var floats := data.to_float32_array()
	var results := PackedVector4Array()
	var count := mini(batch.points.size(), MAX_QUERY_POINTS)
	results.resize(count)
	batch.velocities.resize(count)
	for i in count:
		results[i] = Vector4(floats[i * 8], floats[i * 8 + 1],
			floats[i * 8 + 2], floats[i * 8 + 3])
		batch.velocities[i] = Vector3(floats[i * 8 + 4], floats[i * 8 + 5], floats[i * 8 + 6])
	batch.results = results
	_apply_query_results.call_deferred(batch)


# Main thread.
func _apply_query_results(batch: OceanQueryBatch) -> void:
	_query_mutex.lock()
	if batch.revision != _query_generation or batch.id <= _query_published_id:
		_query_replaced_ids.append(batch.id)
		_query_mutex.unlock()
		return
	if _query_completed_batch != null:
		_query_replaced_ids.append(_query_completed_batch.id)
	_query_completed_batch = batch
	_query_published_id = batch.id
	_query_latest = batch.results
	_query_results_valid = true
	_query_mutex.unlock()


func query_render() -> void:
	if initialized:
		_dispatch_pending_queries()


func local_centers() -> Vector4:
	return foam_state().get("local_centers", Vector4(OceanLocalSolver.COAST_CENTER.x, OceanLocalSolver.COAST_CENTER.y, 0.0, 0.0))


func add_wake_impulse(body_id: int, position: Vector2, impulse: Vector2) -> void:
	_wake_mutex.lock()
	var previous: Vector4 = _wake_impulses.get(body_id, Vector4.ZERO)
	_wake_impulses[body_id] = Vector4(position.x, position.y,
		previous.z + impulse.x, previous.w + impulse.y)
	_wake_mutex.unlock()


func set_body_pressure(body_id: int, position: Vector2, force_n: float) -> void:
	_wake_mutex.lock()
	if force_n > 0.0:
		_body_pressures[body_id] = Vector4(position.x, position.y, force_n, 0.6)
	else:
		_body_pressures.erase(body_id)
	_wake_mutex.unlock()


func free_render() -> void:
	initialized = false
	_wake_mutex.lock()
	_wake_impulses.clear()
	_body_pressures.clear()
	_wake_mutex.unlock()
	_query_mutex.lock()
	_query_generation += 1
	if _query_pending_batch != null:
		_query_replaced_ids.append(_query_pending_batch.id)
	if _query_completed_batch != null:
		_query_replaced_ids.append(_query_completed_batch.id)
	_query_pending_batch = null
	_query_completed_batch = null
	_query_results_valid = false
	_query_mutex.unlock()
	if _rd == null:
		return
	for stage in _uniform_sets:
		if _uniform_sets[stage].is_valid():
			_rd.free_rid(_uniform_sets[stage])
	shore_solver.free_render()
	local_solver.free_render()
	velocity_solver.free_render()
	for key in _buffers:
		if _buffers[key].is_valid():
			_rd.free_rid(_buffers[key])
	for view in _foam_mip_views:
		if view.is_valid():
			_rd.free_rid(view)
	_foam_mip_views.clear()
	for tex in [_spectrum_tex, _displacement_tex, _normal_tex, _derivative_tex,
			_foam_near_tex_a, _foam_near_tex_b]:
		if tex.is_valid():
			_rd.free_rid(tex)
	if _foam_sampler.is_valid():
		_rd.free_rid(_foam_sampler)
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
	_spectrum_tex = RID()
	_displacement_tex = RID()
	_normal_tex = RID()
	_derivative_tex = RID()
	_foam_near_tex_a = RID()
	_foam_near_tex_b = RID()
	_foam_noise_rd = RID()
	_foam_sampler = RID()
	_cascade_dirty.clear()


func _create_tex_array(format: RenderingDevice.DataFormat) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = map_size
	fmt.height = map_size
	fmt.array_layers = num_cascades()
	fmt.format = format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _create_foam_array() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = foam_near_size
	fmt.height = foam_near_size
	fmt.array_layers = 3
	fmt.mipmaps = _foam_mip_count
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _clear_foam_fields() -> void:
	for texture in [_foam_near_tex_a, _foam_near_tex_b]:
		_rd.texture_clear(texture, Color(0, 0, 0, 0), 0, _foam_mip_count, 0, 3)


func _generate_foam_mips(cl: int, index: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["foam_mipmap"])
	for mip in range(1, _foam_mip_count):
		var size := maxi(foam_near_size >> mip, 1)
		var pc := PackedByteArray()
		pc.resize(16)
		pc.encode_s32(0, size)
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		for layer in 3:
			var key := "foam_mip_%d_%d_%d" % [index, layer, mip]
			_rd.compute_list_bind_uniform_set(cl, _uniform_sets[key], 0)
			_rd.compute_list_dispatch(cl, maxi((size + 15) / 16, 1), maxi((size + 15) / 16, 1), 1)
		_rd.compute_list_add_barrier(cl)


func _image_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _sampled_texture_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_foam_sampler)
	u.add_id(rid)
	return u


func _create_foam_sampler() -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	return _rd.sampler_create(state)


func _dispatch(cl: int, stage: String, pc: PackedByteArray, gx: int, gy: int, gz: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, gz)
	_rd.compute_list_add_barrier(cl)


func _jonswap_significant_height(scale: float) -> float:
	return 4.0 * sqrt(maxf(physical_moments().get("m0", 0.0), 0.0)) * maxf(scale, 0.0)


func physical_moments() -> Dictionary:
	var key := PackedFloat64Array([wind_speed, fetch_km, water_depth, jonswap_gamma,
		swell, spread, detail, wind_direction, swell_height_m, effective_swell_period(),
		swell_direction_rad, swell_spread, map_size,
		tile_lengths[0], tile_lengths[1], tile_lengths[2]])
	if key != _moment_key:
		_physical_moments = SpectrumMetrics.unscaled_moments(self)
		_moment_key = key
	return _physical_moments


func _soft_limit(value: float, knee: float, limit: float) -> float:
	if value <= knee:
		return value
	var span := limit - knee
	return knee + span * (1.0 - exp(-(value - knee) / span))


func effective_swell_period() -> float:
	var requested := maxf(swell_period_s, 0.1)
	if swell_height_m <= 0.0:
		return requested
	var boosted_height := swell_height_m * maxf(amplitude_scale, 1.0) \
		* maxf(clampf(height_gain, 0.0, JONSWAP_MAX_HEIGHT_GAIN), 1.0)
	var bounded_height := minf(boosted_height, JONSWAP_TOTAL_HEIGHT_LIMIT_M)
	var minimum_wavelength := bounded_height / SWELL_MAX_SIGNIFICANT_STEEPNESS
	var k := TAU / minimum_wavelength
	var omega := sqrt(GRAVITY * k * tanh(k * maxf(water_depth, 0.01)))
	return maxf(requested, TAU / omega)


func effective_amplitude_scale() -> float:
	var raw_height := _jonswap_significant_height(amplitude_scale)
	if raw_height <= 0.0:
		return maxf(amplitude_scale, 0.0)
	var safe_height := _soft_limit(raw_height,
		JONSWAP_BASE_HEIGHT_KNEE_M, JONSWAP_BASE_HEIGHT_LIMIT_M)
	return amplitude_scale * safe_height / raw_height


func effective_height_gain() -> float:
	var input_gain := clampf(height_gain, 0.0, JONSWAP_MAX_HEIGHT_GAIN)
	if input_gain <= 1.0:
		return input_gain
	var moments := physical_moments()
	var m0: float = maxf(moments.get("m0", 0.0), 0.0)
	var m1: float = maxf(moments.get("m1", 0.0), 0.0)
	var m2: float = maxf(moments.get("m2", 0.0), 0.0)
	var scale := effective_amplitude_scale()
	var gain_delta := input_gain - 1.0
	var raw_height := 4.0 * scale * sqrt(m0 + 2.0 * gain_delta * m1 + gain_delta * gain_delta * m2)
	if m2 <= 1e-15 or scale <= 1e-10:
		return input_gain
	var safe_height := _soft_limit(raw_height,
		JONSWAP_TOTAL_HEIGHT_KNEE_M, JONSWAP_TOTAL_HEIGHT_LIMIT_M)
	var target_variance := pow(safe_height / (4.0 * scale), 2.0)
	return minf(input_gain, 1.0 + (sqrt(maxf(m1 * m1 + m2 * (target_variance - m0), 0.0)) - m1) / m2)


func effective_choppiness(cascade: int = 0) -> float:
	var raw := clampf(choppiness, 0.0, JONSWAP_MAX_CHOPPINESS)
	var compressed := raw
	if raw > JONSWAP_CHOPPINESS_KNEE:
		compressed = remap(raw, JONSWAP_CHOPPINESS_KNEE, JONSWAP_MAX_CHOPPINESS,
			JONSWAP_CHOPPINESS_KNEE, JONSWAP_CHOPPINESS_LIMIT)
	if cascade == 2:
		if raw <= JONSWAP_CHOPPINESS_KNEE:
			return raw * CHOP_PER_CASCADE[cascade]
		return remap(raw, JONSWAP_CHOPPINESS_KNEE, JONSWAP_MAX_CHOPPINESS,
			JONSWAP_CHOPPINESS_KNEE * CHOP_PER_CASCADE[cascade],
			JONSWAP_FINE_CHOPPINESS_LIMIT)
	return compressed * CHOP_PER_CASCADE[cascade]


func _pack_near_push_constant(dt: float, layer: int = 0) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	var texel := foam_field_domains()[layer] / foam_near_size
	var center := (_render_center / texel).floor() * texel
	var previous_center := (_near_center_prev / texel).floor() * texel
	pc.encode_float(0, center.x)
	pc.encode_float(4, center.y)
	pc.encode_float(8, previous_center.x)
	pc.encode_float(12, previous_center.y)
	var foam_growth := maxf(foam_amount, 0.0) * 7.5 \
		if foam_feedback_enabled else 0.0
	pc.encode_float(16, dt * 0.693 / maxf(foam_persistence, 0.05))
	pc.encode_float(20, dt * maxf(0.693 / maxf(foam_persistence * 0.5, 0.02),
		1.15 * maxf(0.5, 10.0 - foam_amount)))
	pc.encode_float(24, dt * 0.693 / maxf(foam_persistence, 0.05) * 0.35)
	pc.encode_float(28, dt * foam_growth)
	pc.encode_float(32, foam_field_domains()[layer])
	pc.encode_float(36, dt)
	pc.encode_float(40, 1.0)
	pc.encode_float(44, float(foam_near_size))
	var enabled_mask := 0
	for i in num_cascades():
		enabled_mask |= 1 << i
	pc.encode_s32(48, layer)
	pc.encode_s32(52, enabled_mask)
	pc.encode_float(56, current_velocity_m_s.x)
	pc.encode_float(60, current_velocity_m_s.y)
	pc.encode_float(64, tile_lengths[0])
	pc.encode_float(68, tile_lengths[1])
	pc.encode_float(72, tile_lengths[2])
	pc.encode_float(76, clampf(whitecap, 0.05, 0.95))
	pc.encode_float(80, _render_time)
	pc.encode_float(84, 0.0)
	# Waves travel world (cos θ, sin θ): the FFT texture axes swap into world
	# axes, the same convention the rain and spray layers already follow.
	var drift := foam_drift_velocity()
	pc.encode_float(88, drift.x)
	pc.encode_float(92, drift.y)
	var coast_center: Vector2 = local_solver.coast_center()
	var wake_center: Vector2 = local_solver.wake_center()
	pc.encode_float(96, coast_center.x)
	pc.encode_float(100, coast_center.y)
	pc.encode_float(104, wake_center.x)
	pc.encode_float(108, wake_center.y)
	pc.encode_float(112, OceanLocalSolver.COAST_DOMAIN_M)
	pc.encode_float(116, OceanLocalSolver.WAKE_DOMAIN_M)
	pc.encode_float(120, 1.0 if physical_features_enabled else 0.0)
	return pc


func foam_drift_velocity() -> Vector2:
	var velocity := current_velocity_m_s
	for reference in spectral_references():
		velocity += reference.get("stokes_m_s", Vector2.ZERO)
	return velocity


func _update_breaking_settings() -> void:
	var total_variance := 0.0
	var swell_variance := 0.0
	for reference in _spectral_references:
		total_variance += float(reference.height_variance_m2)
		swell_variance += float(reference.swell_variance_m2)
	var dominance := clampf(swell_variance / maxf(total_variance, 1e-12), 0.0, 1.0) \
		if wave_model == WaveModel.FFT else 0.0
	var omega := TAU / effective_swell_period()
	var k := maxf(omega * omega / GRAVITY, 1e-6)
	for iteration in 8:
		var dispersion: Vector2 = SpectrumMetrics._dispersion_and_derivative(k, maxf(water_depth, 0.01))
		k = maxf(k - (dispersion.x - omega) / maxf(dispersion.y, 1e-8), 1e-6)
	_breaking_settings = Vector4(swell_direction_rad, omega / k, 0.0, dominance)


## k-space boundary between cascade i and i+1: the finer cascade takes over at
## 6 of its tile wavelengths, where it has ~9 texels per wavelength.
func _k_max(cascade: int) -> float:
	if cascade >= num_cascades() - 1:
		return TAU / MIN_WAVELENGTH_M
	return TAU / tile_lengths[cascade + 1] * 6.0


func _pack_push_constant(cascade: int, step_time: float = -1.0) -> PackedByteArray:
	var fetch_m := fetch_km * 1000.0
	var amplitude := effective_amplitude_scale()
	# amplitude_scale rides on alpha: the JONSWAP/TMA spectrum is linear in
	# alpha, so the height amplitude scales with its square root exactly.
	var alpha := SpectrumMetrics.jonswap_alpha(wind_speed, fetch_m) * pow(amplitude, 2.0)
	var omega_p := SpectrumMetrics.jonswap_peak_frequency(wind_speed, fetch_m)
	var k_min := TAU / tile_lengths[0] if cascade == 0 else _k_max(cascade - 1)
	var eff_chop := effective_choppiness(cascade)

	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, tile_lengths[cascade])
	pc.encode_float(4, alpha)
	pc.encode_float(8, omega_p)
	pc.encode_float(12, wind_speed)
	pc.encode_float(16, wind_direction)
	pc.encode_float(20, water_depth)
	pc.encode_float(24, swell)
	pc.encode_float(28, detail)
	pc.encode_float(32, spread)
	pc.encode_float(36, k_min)
	pc.encode_float(40, _k_max(cascade))
	pc.encode_float(44, eff_chop)
	pc.encode_float(48, whitecap)
	pc.encode_float(52, amplitude)
	pc.encode_float(60, sim_time if step_time < 0.0 else step_time)
	pc.encode_s32(64, cascade)
	pc.encode_s32(68, 1000 + cascade * 7919)
	pc.encode_s32(72, 31337 + cascade * 104729)
	pc.encode_s32(76, int(wave_model == WaveModel.TUTORIAL_GERSTNER))
	pc.encode_float(80, effective_height_gain())
	var reference: Dictionary = spectral_references()[cascade]
	pc.encode_float(84, reference.height_rms_m if wave_model == WaveModel.FFT else long_wave_height_m)
	pc.encode_float(88, reference.wavelength_m if wave_model == WaveModel.FFT else long_wave_length_m)
	pc.encode_float(92, wind_wave_height_m)
	pc.encode_float(96, wind_wave_length_m)
	pc.encode_float(100, current_velocity_m_s.x)
	pc.encode_float(104, jonswap_gamma)
	pc.encode_float(108, crest_gain)
	pc.encode_float(112, crest_bias)
	pc.encode_float(116, mid_wave_height_m)
	pc.encode_float(120, mid_wave_length_m)
	pc.encode_float(124, current_velocity_m_s.y)
	return pc


# Timestamps cannot be captured inside an open compute list; split the list
# at stage boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Reads last frame's timestamps; repeated names sum across cascades.
func _read_timings() -> void:
	var out := GpuTimings.read(_rd, "ocean/")
	if out.is_empty():
		return
	var spray_timings := GpuTimings.read(_rd, "ocean_spray/")
	var coast_timings := GpuTimings.read(_rd, "shore/")
	for stage: String in coast_timings:
		if stage != "total":
			out["coast_" + stage] = coast_timings[stage]
	out["spray"] = spray_timings.get("total", 0.0)
	out["total"] += out.spray
	out["frame"] = _rd.get_captured_timestamps_frame()
	_timing_store.publish(out)


# Main thread. GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	return _timing_store.snapshot()
