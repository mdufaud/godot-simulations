extends "res://tests/test_case.gd"

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const LOOP_PERIOD := 200.0
const PRESETS := [0, 1, 2, 3]
const JONSWAP_BASELINE_WRITE_PREFIX := "--jonswap-baseline-write="
const JONSWAP_BASELINE_COMPARE_PREFIX := "--jonswap-baseline-compare="
static var JONSWAP_PROBE_POINTS: PackedVector2Array = PackedVector2Array([
	Vector2(-22.0, -18.0), Vector2(-13.7, -9.1), Vector2(-5.4, -0.2),
	Vector2(2.9, 8.7), Vector2(11.2, 17.6), Vector2(19.5, -10.5),
	Vector2(-17.8, -1.6), Vector2(-9.5, 7.3), Vector2(-1.2, 16.2),
	Vector2(7.1, -11.9), Vector2(15.4, -3.0), Vector2(-20.3, 5.9),
])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# SimMenu restores persisted slider values when its widgets are built. A
	# previous run (or the real app) leaves a sim.ocean_demo section behind, and
	# re-setting an already-restored value fires no value_changed, which desyncs
	# the solver from the sliders the checks assert on. Start from defaults.
	var settings := root.get_node_or_null("/root/UserSettings")
	if settings != null:
		settings.clear_sim("ocean_demo")
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.set_frozen(true)
	demo.apply_preset(0)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.initialized and demo.texture_bound, "ocean did not initialize")
	if not demo.solver.initialized or not demo.texture_bound:
		demo.queue_free()
		_finish("ocean_fft")
		return
	if OS.get_cmdline_user_args().has("--jonswap-controls-only"):
		demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
		for frame in 360:
			await process_frame
			if demo.solver.initialized and demo.texture_bound:
				break
		await _check_jonswap_slider_controls(demo)
		await _check_tall_crests(demo)
		await _check_jonswap_extreme_envelope(demo)
		demo.queue_free()
		_finish("ocean_fft")
		return
	if OS.get_cmdline_user_args().has("--coherence-only"):
		await _check_coherence_contracts(demo)
		demo.queue_free()
		await process_frame
		_finish("ocean_coherence")
		return
	await _check_foam_phases(demo)
	if OS.get_cmdline_user_args().has("--foam-phases-only"):
		demo.queue_free()
		await process_frame
		_finish("ocean_foam_phases")
		return

	# The demo defaults to High; the suite's numeric contracts are pinned on
	# Medium (same pipeline, 512²) so runs stay fast, with dedicated Low and
	# Ultra sections below.
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	demo._menu_builder._foam_distance_override = false
	demo.set_foam_distance(OceanQualityProfile.FOAM_NEAR_DISTANCE[OceanQualityProfile.Tier.MEDIUM])
	_check(demo.solver.quality_tier == OceanQualityProfile.Tier.MEDIUM
		and demo.solver.map_size == 512
		and demo.solver.foam_near_size == 1024
		and demo.solver.foam_near_domain
			== OceanQualityProfile.FOAM_NEAR_DISTANCE[OceanQualityProfile.Tier.MEDIUM] * 2.0
		and not demo.solver.amortize,
		"Medium profile mismatch: tier=%d map=%d near=%d domain=%.1f amortize=%s" % [
			demo.solver.quality_tier, demo.solver.map_size, demo.solver.foam_near_size,
			demo.solver.foam_near_domain, demo.solver.amortize])
	_check(demo._menu_builder._foam_distance != null
		and demo._menu_builder._foam_distance.max_value == 512.0,
		"ocean menu does not expose the foam distance")
	demo.set_foam_distance(123.0)
	_check(demo.solver.foam_near_domain == 246.0
		and demo.surface_mat.get_shader_parameter("foam_domains") == Vector3(246.0, 984.0, 3936.0)
		and demo.solver._foam_near_reset_pending,
		"foam distance control did not update and reset the near field")
	demo.set_foam_distance(72.0)
	_check(demo.solver.estimate_vram_bytes()
		== OceanQualityProfile.estimate_vram_bytes(OceanQualityProfile.Tier.MEDIUM),
		"VRAM estimate does not match the live allocation sizes")
	await _check_nyquist_derivatives(demo.solver)
	await _check_combined_foam(demo.solver)
	await _check_nested_foam(demo.solver)
	await _check_jonswap_slider_controls(demo)
	await _check_tall_crests(demo)
	await _check_jonswap_extreme_envelope(demo)
	await _check_single_wave(demo.solver)
	var dirty_before: Array = demo.solver._cascade_dirty.duplicate()
	demo.apply_look(1)
	_check(demo.current_look_index == 1, "Tropical Day look was not applied")
	_check(demo.solver._cascade_dirty == dirty_before,
		"changing OceanLookPreset dirtied FFT spectra")
	var cloud_signature := OceanCloudscape.noise_signature()
	_check(cloud_signature.seed == OceanCloudscape.CLOUD_SEED
		and cloud_signature.width == 96
		and cloud_signature.height == 96
		and cloud_signature.depth == 48,
		"cloud noise configuration is not deterministic")
	_check((demo.LOOKS[0] as OceanLookPreset).cloud_coverage > 0.7
		and (demo.LOOKS[1] as OceanLookPreset).cloud_coverage < 0.7
		and (demo.LOOKS[2] as OceanLookPreset).cloud_coverage > 0.9,
		"cloud looks do not expose distinct coverage")
	_check((demo.LOOKS[2] as OceanLookPreset).display_name == "Storm Overcast",
		"Storm Overcast look is not registered")
	_check(demo.cloudscape.reflection_texture() != null,
		"cloud reflection texture is not bound")
	demo.apply_look(0)
	var states: Array[Dictionary] = []
	for preset_index in PRESETS:
		demo.apply_preset(preset_index)
		demo._sim_time = 12.0
		demo.solver.sim_time = 12.0
		demo.set_frozen(false)
		await _frames(45)
		demo.set_frozen(true)
		states.append(await _state_metrics(demo, preset_index == 0))

	for state in states:
		_check(state.non_finite == 0, "ocean produced NaN or Inf")
		for energy in state.band_rms:
			_check(energy > 0.001, "one FFT band has no measurable energy")
		# Calm's 40 m band legitimately lives on cascade 1 (257 m tile) — the
		# layer-0 spectrum alone is allowed to look thin for it.
		_check(state.active_band_count >= 2 or state.height_rms < 0.2,
			"spectrum collapsed into one dominant artificial band")
		_check(state.crest_mean >= 0.0 and state.crest_mean < 0.25,
			"crest ridge is too broad or outside normalized range")
	_check(states[0].height_rms < states[1].height_rms
		and states[1].height_rms < states[2].height_rms
		and states[2].height_rms < states[3].height_rms,
		"wave height is not monotonic from Calm to Storm")
	_check(states[0].slope_rms < states[1].slope_rms
		and states[1].slope_rms < states[2].slope_rms
		and states[2].slope_rms < states[3].slope_rms,
		"wave slope is not monotonic from Calm to Storm")
	_check(states[0].foam_mean < 0.0001 and states[0].fresh_mean < 0.0001,
		"Calm produced open-water foam")
	# Refonte contract: Calm foam coverage stays under 0.5% of the tiles.
	_check(states[0].foam_coverage < 0.005,
		"Calm foam coverage exceeds 0.5%% (%.2f%%)" % (states[0].foam_coverage * 100.0))
	# P0-A/P0-B absolute guard: no cascade may foam spontaneously in calm.
	_check(states[0].foam_coverage_by_layer[0] < 0.001
		and states[0].foam_coverage_by_layer[1] < 0.001,
		"Calm produced foam on a simulated cascade")
	_check(states[0].breaking_coverage < 0.01
		and states[1].breaking_coverage <= states[2].breaking_coverage
		and states[1].breaking_coverage <= states[3].breaking_coverage
		and states[3].breaking_coverage < 0.25,
		"breaking coverage does not separate calm, breeze and rough seas")
	var swell_state: Dictionary = states[2]
	var storm_state: Dictionary = states[3]
	_check(swell_state.dominant_wavelength_m >= 180.0
		and swell_state.dominant_wavelength_m <= 340.0,
		"Swell dominant wavelength is %.1f m, expected 180..340 m"
		% swell_state.dominant_wavelength_m)
	_check(storm_state.dominant_wavelength_m >= 170.0
		and storm_state.dominant_wavelength_m <= 300.0,
		"Storm dominant wavelength is %.1f m, expected 170..300 m"
		% storm_state.dominant_wavelength_m)
	_check(swell_state.groupiness > 0.30 and storm_state.groupiness > 0.30,
		"wave groups are too uniform (Swell %.3f, Storm %.3f)"
		% [swell_state.groupiness, storm_state.groupiness])
	_check(storm_state.long_max_rms > 3.4 and storm_state.long_max_abs < 40.0,
		"Storm extremes are weak or saturated (max/RMS %.2f, max %.2f m)"
		% [storm_state.long_max_rms, storm_state.long_max_abs])
	_check(demo.PRESETS[0].foam_amount == 0.0
		and demo.PRESETS[0].spray_amount == 0.0
		and demo.PRESETS[0].foam_amount < demo.PRESETS[1].foam_amount
		and demo.PRESETS[1].foam_amount < demo.PRESETS[3].foam_amount,
		"foam presets do not progress from Calm to Storm")
	_check(storm_state.crosswind_energy > swell_state.crosswind_energy,
		"Storm crosswind energy is not above Swell (%.4f <= %.4f)"
		% [storm_state.crosswind_energy, swell_state.crosswind_energy])
	var breeze: OceanPreset = demo.PRESETS[1]
	demo.apply_preset(1)
	demo.solver.crest_gain = 1.0
	demo.solver.mark_spectrum_dirty()
	demo.set_frozen(false)
	await _frames(45)
	demo.set_frozen(true)
	var unshaped_breeze := await _state_metrics(demo, false, false, false, false)
	demo.solver.crest_gain = breeze.crest_gain
	demo.solver.mark_spectrum_dirty()
	demo.set_frozen(false)
	await _frames(45)
	demo.set_frozen(true)
	var shaped_breeze := await _state_metrics(demo, false, false, false, false)
	_check(shaped_breeze.primary_crest_coverage
		>= unshaped_breeze.primary_crest_coverage * 0.98,
		"crest_gain reduced the crest mask (%.3f < %.3f)"
		% [shaped_breeze.primary_crest_coverage,
			unshaped_breeze.primary_crest_coverage * 0.98])
	_check(absf(shaped_breeze.band_rms[0] / maxf(unshaped_breeze.band_rms[0], 0.001) - 1.0)
		<= 0.10, "crest_gain changed Breeze RMS by more than 10%%")
	demo.apply_preset(3)

	demo.set_frozen(false)
	await _frames(240)
	demo.set_frozen(true)
	var settled_storm := await _state_metrics(demo, true, true)
	var storm_short_displacement := await _read_texture(
		demo.solver.get_displacement_tex_rid(), 2)
	var storm_short_normal := await _read_texture(demo.solver.get_normal_tex_rid(), 2)
	var storm_short_normal_metrics := _normal_metrics(storm_short_normal)
	var storm_short_breaking_coverage: float = float(storm_short_normal_metrics.breaking_active) \
		/ maxf(float(storm_short_normal_metrics.count), 1.0)
	var storm_short_shape := _shape_coherence(
		storm_short_displacement, storm_short_normal, demo.solver.map_size)
	_check(settled_storm.primary_crest_coverage >= 0.08
		and settled_storm.primary_crest_coverage <= 0.30,
		"Storm crest coverage is outside 8..30%% (%.1f%%)"
		% (settled_storm.primary_crest_coverage * 100.0))
	# Any dominant short-range repetition means a periodic wave snuck back in.
	var storm_periodicity := _max_lag_correlation(storm_short_displacement,
		demo.solver.map_size, demo.solver.tile_lengths[2], 4.0, 60.0)
	_check(storm_periodicity < 0.45,
		"Storm shows dominant wave repetition below 60 m (%.2f)" % storm_periodicity)
	# Storm spectral peaks live in the three JONSWAP cascade bands.
	var peak_windows: Array = [[180.0, 320.0], [12.0, 24.0], [3.0, 8.0]]
	for cascade in 3:
		var spectrum_layer := await _read_texture(demo.solver._spectrum_tex, cascade)
		var peak := _cascade_peak_wavelength(spectrum_layer, demo.solver.map_size,
			demo.solver.tile_lengths[cascade])
		var window: Array = peak_windows[cascade]
		_check(peak >= window[0] and peak <= window[1],
			"Storm cascade %d spectral peak at %.1f m, expected %.0f..%.0f m"
			% [cascade, peak, window[0], window[1]])
	for layer in 3:
		_check(settled_storm.foam_coverage_by_layer[layer] > 0.005,
			"Storm has no persistent foam in nested field %d" % layer)
	_check(settled_storm.foam_mean > 0.001 and settled_storm.foam_mean < 0.25,
		"Storm persistent coverage mean is outside 0.1..25 percent")
	for seam_ratio in settled_storm.seam_ratios:
		_check(seam_ratio < 2.5, "cascade seam differs from local wave continuity")
	var combined_bytes := await _read_texture(demo.solver.get_foam_near_read_tex_rid(), 0)
	combined_bytes = _foam_base(combined_bytes, demo.solver.foam_near_size)
	var combined_image := Image.create_from_data(demo.solver.foam_near_size,
		demo.solver.foam_near_size, false, Image.FORMAT_RGF, combined_bytes)
	combined_image.convert(Image.FORMAT_RGH)
	var combined_topology := _foam_morphology(combined_image.get_data())
	_check(combined_topology.persistent.small_pixel_fraction <= 0.16
		and combined_topology.fresh.small_pixel_fraction <= 0.16,
		"small isolated foam components exceed 16%% of foam pixels")
	_check(settled_storm.fresh_persistent_iou < 0.90,
		"fresh and persistent foam have indistinguishable morphology")
	# The physical coverage texture tracks the active quality tier.
	_check(demo.solver.foam_near_size
		== OceanQualityProfile.FOAM_NEAR_SIZE[demo.solver.quality_tier],
		"near foam size does not match the active profile")
	var foam_before_decay: float = settled_storm.foam_mean
	var fresh_before_decay: float = settled_storm.fresh_mean
	demo.solver.foam_amount = 0.0
	demo.set_frozen(false)
	await _frames(60)
	demo.set_frozen(true)
	var decayed_storm := await _state_metrics(demo, true, false, false, false)
	var foam_drop: float = (foam_before_decay - decayed_storm.foam_mean) \
		/ maxf(foam_before_decay, 1e-5)
	var fresh_drop: float = (fresh_before_decay - decayed_storm.fresh_mean) \
		/ maxf(fresh_before_decay, 1e-5)
	_check(fresh_drop > foam_drop,
		"fresh foam does not decay faster than persistent (%.3f <= %.3f)"
		% [fresh_drop, foam_drop])
	_check(foam_drop > 0.0 and fresh_drop > 0.0,
		"foam did not decay after injection stopped")
	demo.apply_preset(3)

	# Near feedback follows the camera: shift the view 2 m sideways; the foam
	# field must advect with the world (matches the shifted previous frame)
	# instead of staying texture-locked, and without a discontinuity column.
	# The near field starts empty and takes a few seconds to fill, so settle
	# it as long as the far histories above.
	demo.set_frozen(false)
	await _frames(240)
	demo.set_frozen(true)
	var near_size: int = demo.solver.foam_near_size
	var near_domain: float = demo.solver.foam_near_domain
	var near_before := _near_rg(await _read_texture(
		demo.solver.get_foam_near_read_tex_rid(), 0), near_size)
	var near_before_std := _near_channel_std(near_before)
	demo.orbit_cam.target += Vector3(2.0, 0.0, 0.0)
	demo.set_frozen(false)
	await _frames(2)
	demo.set_frozen(true)
	demo.orbit_cam.target -= Vector3(2.0, 0.0, 0.0)
	var near_after := _near_rg(await _read_texture(
		demo.solver.get_foam_near_read_tex_rid(), 0), near_size)
	var shift_texels := int(round(2.0 / near_domain * near_size))
	var moved := _near_shift_stats(near_after, near_before, near_size, shift_texels, 4)
	var static_cmp := _near_shift_stats(near_after, near_before, near_size, 0, 4)
	if near_before_std > 0.01:
		_check(moved.rms < static_cmp.rms * 0.7,
			"near foam did not advect with the camera (shifted %.4f vs texture-locked %.4f)"
			% [moved.rms, static_cmp.rms])
		_check(moved.p99_col < maxf(moved.median_col * 20.0, 0.004),
			"near foam shows a seam column after camera motion (p99 %.4f vs median %.4f)"
			% [moved.p99_col, moved.median_col])
	else:
		print("  note: near field too flat for reprojection metrics (std %.4f)"
			% near_before_std)

	# 180 simulated seconds in 0.5 s steps: persistence must stay finite and
	# bounded (no runaway growth, no washout). Fresh foam legitimately sits
	# above persistent (it is the bright transient layer), so only the
	# persistent band and the logistic bounds are asserted.
	demo._capture_fixed_delta = 0.5
	demo.set_frozen(false)
	await _frames(360)
	demo.set_frozen(true)
	demo._capture_fixed_delta = -1.0
	var near_settled := _near_rg(await _read_texture(
		demo.solver.get_foam_near_read_tex_rid(), 0), near_size)
	var persistent_mean := 0.0
	var fresh_mean := 0.0
	var max_value := 0.0
	var texels := near_size * near_size
	for i in range(0, texels, 4):
		var r: float = near_settled[i * 2]
		var g: float = near_settled[i * 2 + 1]
		persistent_mean += r
		fresh_mean += g
		max_value = maxf(max_value, maxf(r, g))
	persistent_mean /= float(ceil(texels / 4.0))
	fresh_mean /= float(ceil(texels / 4.0))
	_check(max_value <= 1.5,
		"near foam overflowed its logistic bounds after 180 s (max %.3f)" % max_value)
	_check(persistent_mean > 0.0 and persistent_mean < 0.8,
		"near persistent foam unstable after 180 s (mean %.3f)" % persistent_mean)
	_check(fresh_mean > 0.0 and fresh_mean <= 1.0,
		"near fresh foam unstable after 180 s (mean %.3f)" % fresh_mean)

	var loop_start: float = demo._sim_time
	var at_start := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	demo.solver.mark_spectrum_dirty()
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var regenerated := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(at_start == regenerated, "fixed seeds are not deterministic")
	demo._sim_time = loop_start + LOOP_PERIOD
	demo.solver.sim_time = loop_start + LOOP_PERIOD
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var looped := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	var loop_error := _texture_difference_rms(at_start, looped)
	# Continuous physical dispersion: the FFT field must NOT repeat after the
	# old 200 s quantization loop.
	_check(loop_error > 0.05,
		"FFT waves still loop after 200 s (RMS error %f — dispersion got requantized)" % loop_error)

	demo.apply_preset(3)
	demo._sim_time = 37.0
	demo.solver.sim_time = 37.0
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var jonswap_guard_before := await _capture_jonswap_guard(demo)
	for cascade in 3:
		_check(jonswap_guard_before.displacements[cascade].size() > 0,
			"JONSWAP cascade %d displacement readback is empty" % cascade)
		_check(jonswap_guard_before.displacement_metrics[cascade].rms > 0.001,
			"JONSWAP cascade %d lost all energy" % cascade)
	_compare_or_write_jonswap_baseline(jonswap_guard_before)
	# Storm runs live long enough to seed the far histories with real foam;
	# the quality switch below only proves anything if there is foam to clear.
	demo.set_frozen(false)
	await _frames(240)
	demo.set_frozen(true)
	# Low tier: cascades rotate, near feedback every other frame, and
	# every GPU resource is recreated (which also clears the foam history).
	var pre_switch := await _state_metrics(demo, true, false, false, false)
	demo.set_quality_profile(OceanQualityProfile.Tier.LOW)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.quality_tier == OceanQualityProfile.Tier.LOW
		and demo.solver.map_size == 256
		and demo.solver.foam_near_size == 512
		and demo.solver.foam_near_domain
			== OceanQualityProfile.FOAM_NEAR_DISTANCE[OceanQualityProfile.Tier.LOW] * 2.0
		and demo.solver.amortize
		and demo.solver.foam_near_stride == 2,
		"256 performance mode did not reinitialize")
	_check(demo.solver.get_foam_near_read_index() == 0
		and demo.solver._foam_near_dt == 0.0,
		"performance profile switch kept stale near-foam state")
	demo.set_frozen(false)
	await _frames(24)
	demo.set_frozen(true)
	var reduced_map := await _state_metrics(demo, false, false, false, false, true)
	_check(reduced_map.foam_mean < pre_switch.foam_mean * 0.5,
		"profile switch did not clear the foam history (%.4f -> %.4f)" % [
			pre_switch.foam_mean, reduced_map.foam_mean])
	for seam_ratio in reduced_map.seam_ratios:
		_check(seam_ratio < 2.5,
			"reduced-map cascade seam differs from local continuity (ratio %.3f)" % seam_ratio)

	# --- Physics sync: GPU point queries vs CPU ground truth read from the
	# same maps. Exact-math replica of ocean_query.comp (bilinear torus sample,
	# 4-iteration choppy inversion) — any gap is a marshalling/shader bug.
	demo.set_frozen(true)
	var query_points := PackedVector2Array()
	for i in 33:
		query_points.append(Vector2(
			fposmod(float(i) * 12.7, 44.0) - 22.0,
			fposmod(float(i) * 8.9, 36.0) - 18.0))
	RenderingServer.call_on_render_thread(func():
		demo.solver.submit_queries(query_points))
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var query_results: PackedVector4Array = demo.solver.latest_results()
	_check(demo.solver.query_results_valid() and query_results.size() == 33,
		"point query readback lost or truncated (%d results)" % query_results.size())
	var map_n: int = demo.solver.map_size
	var tiles: PackedFloat32Array = demo.solver.tile_lengths
	var query_disp: Array[PackedFloat32Array] = []
	var query_norms: Array[PackedFloat32Array] = []
	for cascade in 3:
		query_disp.append(_decode_rgba16f(await _read_texture(
			demo.solver.get_displacement_tex_rid(), cascade), map_n))
		query_norms.append(_decode_rgba16f(await _read_texture(
			demo.solver.get_normal_tex_rid(), cascade), map_n))
	var height_errors: Array[float] = []
	var normal_errors: Array[float] = []
	var cascade_contribution: Array[float] = [0.0, 0.0, 0.0]
	for i in query_points.size():
		var truth := _query_ground_truth(query_disp, query_norms, map_n, tiles,
			query_points[i], cascade_contribution)
		var got := query_results[i]
		if got.w < 0.5:
			_check(false, "query result %d marked invalid" % i)
			continue
		height_errors.append(absf(got.x - truth.height))
		var got_grad := Vector2(got.y, got.z)
		var truth_grad := Vector2(truth.normal.x, truth.normal.z)
		# In wave lulls both gradients are ~zero and the angle between two
		# near-zero vectors is noise, so only steep points get the angle test;
		# flat points must simply both be flat.
		if truth.gradient_len > 0.02:
			var dot := clampf(got_grad.normalized().dot(truth_grad.normalized()),
				-1.0, 1.0)
			normal_errors.append(rad_to_deg(acos(dot)))
		elif got_grad.length() > 0.05:
			normal_errors.append(90.0)
		else:
			normal_errors.append(0.0)
	height_errors.sort()
	normal_errors.sort()
	var height_rms := 0.0
	for e in height_errors:
		height_rms += e * e
	height_rms = sqrt(height_rms / maxf(height_errors.size(), 1))
	if height_errors.is_empty():
		_check(false, "no valid query results to compare against ground truth")
		return
	var height_p95: float = height_errors[int(height_errors.size() * 0.95) - 1]
	var normal_max: float = normal_errors[normal_errors.size() - 1]
	_check(height_rms <= 0.02,
		"query height RMS %.3f cm exceeds 2 cm" % (height_rms * 100.0))
	_check(height_p95 <= 0.05,
		"query height P95 %.3f cm exceeds 5 cm" % (height_p95 * 100.0))
	_check(normal_max <= 3.0,
		"query normal deviates up to %.2f degrees from ground truth" % normal_max)
	for cascade in 3:
		var cascade_rms := sqrt(cascade_contribution[cascade]
			/ float(query_points.size()))
		_check(cascade_rms > 0.002,
			"cascade %d does not measurably contribute to point queries (RMS %.4f m)"
			% [cascade, cascade_rms])

	# Ultra smoke: the 1024² pipeline initializes, runs and answers queries,
	# and the VRAM estimates rank in the right order.
	demo.set_quality_profile(OceanQualityProfile.Tier.ULTRA)
	for frame in 720:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.quality_tier == OceanQualityProfile.Tier.ULTRA
		and demo.solver.map_size == 1024
		and demo.solver.foam_near_size == 2048
		and demo.solver.foam_near_domain == 256.0,
		"Ultra profile did not configure the solver (tier %d, map %d)" % [
			demo.solver.quality_tier, demo.solver.map_size])
	_check(demo.solver.foam_near_domain / demo.solver.foam_near_size <= 0.125,
		"Ultra combined foam texels exceed 12.5 cm")
	_check(OceanQualityProfile.estimate_vram_bytes(OceanQualityProfile.Tier.LOW)
		< OceanQualityProfile.estimate_vram_bytes(OceanQualityProfile.Tier.MEDIUM)
		and OceanQualityProfile.estimate_vram_bytes(OceanQualityProfile.Tier.MEDIUM)
		< OceanQualityProfile.estimate_vram_bytes(OceanQualityProfile.Tier.ULTRA),
		"VRAM estimates do not increase with quality")
	demo.set_frozen(false)
	await _frames(12)
	demo.set_frozen(true)
	var ultra_short := await _read_texture(demo.solver.get_displacement_tex_rid(), 2)
	_check(_height_rms(ultra_short).rms > 0.01, "Ultra 1024 pipeline produced no waves")
	var ultra_points := PackedVector2Array([Vector2(3.0, -5.0), Vector2(11.0, 7.0)])
	RenderingServer.call_on_render_thread(func():
		demo.solver.submit_queries(ultra_points))
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var ultra_results: PackedVector4Array = demo.solver.latest_results()
	_check(ultra_results.size() == 2 and ultra_results[0].w > 0.5
		and ultra_results[1].w > 0.5,
		"Ultra query pass returned invalid results")
	demo.apply_preset(3)
	demo.set_capture_view("overhead")
	demo.orbit_cam._update_transform()
	demo.set_capture_foam(true)
	await demo.warmup_foam(3.0)
	var rendered_foam_rings: Array[Dictionary] = await demo._capture_foam_rings()
	var near_rendered_foam: float = rendered_foam_rings[0].mean_coverage
	_check(near_rendered_foam >= 0.035 and near_rendered_foam <= 0.20,
		"Storm rendered foam coverage is outside 3.5..20 percent (%.1f%%)"
		% (near_rendered_foam * 100.0))

	demo.queue_free()
	await process_frame
	_finish("ocean_fft")


func _capture_jonswap_guard(demo: Node) -> Dictionary:
	var was_physics_processing: bool = demo.is_physics_processing()
	demo.set_physics_process(false)
	var displacements: Array[PackedByteArray] = []
	var displacement_metrics: Array[Dictionary] = []
	for cascade in 3:
		var data := await _read_texture(demo.solver.get_displacement_tex_rid(), cascade)
		displacements.append(data)
		displacement_metrics.append(_height_rms(data))
	var normal_maps := await _capture_texture_layers(
		demo.solver.get_normal_tex_rid(), 3)
	var derivative_maps := await _capture_texture_layers(
		demo.solver.get_derivative_tex_rid(), 3)
	var foam_pingpong := await _capture_foam_pingpong(demo.solver, 3)
	var foam_near_pingpong := await _capture_texture_pingpong(
		demo.solver.get_foam_near_tex_rid(0), demo.solver.get_foam_near_tex_rid(1), 3)
	demo.solver._query_results_valid = false
	RenderingServer.call_on_render_thread(func():
		demo.solver.submit_queries(JONSWAP_PROBE_POINTS))
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	var probes := PackedVector4Array()
	for frame in 360:
		await process_frame
		if demo.solver.query_results_valid():
			probes = demo.solver.latest_results()
			if probes.size() == JONSWAP_PROBE_POINTS.size():
				break
	_check(probes.size() == JONSWAP_PROBE_POINTS.size(),
		"JONSWAP GPU buoyancy probe readback is incomplete (%d/%d)"
		% [probes.size(), JONSWAP_PROBE_POINTS.size()])
	var material := _jonswap_material_state(demo)
	demo.set_physics_process(was_physics_processing)
	return {
		"displacements": displacements,
		"displacement_metrics": displacement_metrics,
		"normal_maps": normal_maps,
		"derivative_maps": derivative_maps,
		"foam_pingpong": foam_pingpong,
		"foam_near_pingpong": foam_near_pingpong,
		"foam_near_read_index": demo.solver.get_foam_near_read_index(),
		"probes": probes,
		"material": material,
	}


func _capture_texture_layers(rid: RID, layer_count: int) -> Dictionary:
	var layers: Array[PackedByteArray] = []
	var result := {"available": rid.is_valid(), "layers": layers}
	if not rid.is_valid():
		return result
	for layer in layer_count:
		layers.append(await _read_texture(rid, layer))
	result.layers = layers
	return result


func _capture_texture_pingpong(a: RID, b: RID, layer_count: int) -> Dictionary:
	return {
		"a": await _capture_texture_layers(a, layer_count),
		"b": await _capture_texture_layers(b, layer_count),
	}


func _capture_foam_pingpong(solver: OceanSolver, layer_count: int) -> Dictionary:
	return await _capture_texture_pingpong(
		solver.get_foam_near_tex_rid(0), solver.get_foam_near_tex_rid(1), layer_count)


func _exact_texture_guard_equal(a: Dictionary, b: Dictionary, label: String) -> void:
	if a.has("a") or b.has("a"):
		_check(a.has("a") and b.has("a") and a.has("b") and b.has("b"),
			"JONSWAP %s ping-pong availability changed" % label)
		if a.has("a") and b.has("a"):
			_exact_texture_guard_equal(a.a, b.a, "%s A" % label)
		if a.has("b") and b.has("b"):
			_exact_texture_guard_equal(a.b, b.b, "%s B" % label)
		return
	_check(a.get("available", false) == b.get("available", false),
		"JONSWAP %s availability changed" % label)
	if not a.get("available", false) or not b.get("available", false):
		return
	var a_layers: Array = a.get("layers", [])
	var b_layers: Array = b.get("layers", [])
	_check(a_layers.size() == b_layers.size(),
		"JONSWAP %s layer count changed" % label)
	if a_layers.size() != b_layers.size():
		return
	for layer in a_layers.size():
		_check(a_layers[layer] == b_layers[layer],
			"JONSWAP %s layer %d changed" % [label, layer])


func _jonswap_material_state(demo: Node) -> Dictionary:
	var material: ShaderMaterial = demo.surface_mat
	var state := {}
	for name: StringName in [&"fft_surface", &"map_scales",
		&"cascade_wavelengths", &"num_cascades",
		&"foam_domains", &"foam_near_enabled", &"foam_feedback_enabled",
		&"interaction_size"]:
		var value: Variant = material.get_shader_parameter(name)
		if value == null:
			value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
		_check(value != null, "JONSWAP material parameter missing: %s" % name)
		state[name] = value
	return state


func _material_state_equal(a: Dictionary, b: Dictionary) -> bool:
	return a == b


func _probe_array_max_error(a: PackedVector4Array, b: PackedVector4Array) -> float:
	if a.size() != b.size():
		return INF
	var max_error := 0.0
	for i in a.size():
		max_error = maxf(max_error, a[i].distance_to(b[i]))
	return max_error


func _compare_or_write_jonswap_baseline(guard: Dictionary) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(JONSWAP_BASELINE_WRITE_PREFIX):
			var path := arg.substr(JONSWAP_BASELINE_WRITE_PREFIX.length())
			var file := FileAccess.open(path, FileAccess.WRITE)
			_check(file != null, "could not write JONSWAP baseline: %s" % path)
			if file != null:
				file.store_var(guard)
				file.close()
				print("JONSWAP BASELINE WRITE %s" % path)
		elif arg.begins_with(JONSWAP_BASELINE_COMPARE_PREFIX):
			var path := arg.substr(JONSWAP_BASELINE_COMPARE_PREFIX.length())
			var file := FileAccess.open(path, FileAccess.READ)
			_check(file != null, "could not read JONSWAP baseline: %s" % path)
			if file == null:
				continue
			var baseline: Variant = file.get_var()
			_check(baseline is Dictionary, "invalid JONSWAP baseline")
			if not baseline is Dictionary:
				continue
			_check(guard.displacements == baseline.get("displacements"),
				"JONSWAP displacement cascades changed from baseline")
			var baseline_probes: PackedVector4Array = baseline.get(
				"probes", PackedVector4Array())
			_check(guard.probes == baseline_probes
				and _probe_array_max_error(guard.probes, baseline_probes) == 0.0,
				"JONSWAP buoyancy probes changed from baseline")
			_exact_texture_guard_equal(guard.normal_maps,
				baseline.get("normal_maps", {"available": false, "layers": []}),
				"normal maps vs baseline")
			_exact_texture_guard_equal(guard.derivative_maps,
				baseline.get("derivative_maps", {"available": false, "layers": []}),
				"derivative maps vs baseline")
			_exact_texture_guard_equal(guard.foam_pingpong,
				baseline.get("foam_pingpong", {}), "foam ping-pong vs baseline")
			_exact_texture_guard_equal(guard.foam_near_pingpong,
				baseline.get("foam_near_pingpong", {}), "near foam ping-pong vs baseline")
			_check(guard.foam_near_read_index
				== baseline.get("foam_near_read_index", -1),
				"JONSWAP near foam read index changed from baseline")
			_check(guard.material == baseline.get("material"),
				"JONSWAP surface material changed from baseline")
			print("JONSWAP BASELINE COMPARED %s" % path)


func _state_metrics(demo, include_foam: bool = false, include_topology: bool = false,
		include_normal: bool = true, include_spectrum: bool = true,
		include_seams: bool = false) -> Dictionary:
	var height_sq := 0.0
	var height_count := 0
	var slope_sq := 0.0
	var slope_count := 0
	var crest_sum := 0.0
	var crest_count := 0
	var crest_active := 0
	var breaking_active := 0
	var primary_crest_active := 0
	var primary_breaking_active := 0
	var breaking_sum := 0.0
	var foam_sum := 0.0
	var fresh_sum := 0.0
	var foam_count := 0
	var foam_active := 0
	var primary_foam_active := 0
	var foam_coverage_by_layer: Array[float] = []
	var fresh_coverage_by_layer: Array[float] = []
	var non_finite := 0
	var band_rms: Array[float] = []
	var slope_bands: Array[float] = []
	var band_energy: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var long_max_abs := 0.0
	var long_max_rms := 0.0
	var groupiness := 0.0
	var dominant_wavelength := 0.0
	var crosswind_energy := 0.0
	var peak_chop_correlation := 0.0
	var primary_crest_asymmetry := 1.0
	var fresh_active := 0
	var primary_shape: Dictionary = {}
	var seam_ratios: Array[float] = []
	var persistent_ribbon: Dictionary = {}
	var fresh_ribbon: Dictionary = {}
	var fresh_persistent_iou := 1.0
	var primary_data := PackedByteArray()
	for layer in 3:
		var data := await _read_texture(demo.solver.get_displacement_tex_rid(), layer)
		var metrics := _height_rms(data)
		band_rms.append(metrics.rms)
		if layer == 0:
			primary_data = data
			long_max_abs = metrics.max_abs
			long_max_rms = metrics.max_abs / maxf(metrics.rms, 0.0001)
			primary_crest_asymmetry = metrics.max_height / maxf(absf(metrics.min_height), 0.0001)
			groupiness = _groupiness(data, demo.solver.map_size,
				demo.solver.tile_lengths[0], demo.solver.long_wave_length_m)
		height_sq += metrics.sum_sq
		height_count += metrics.count
		non_finite += metrics.non_finite
		if include_topology or include_seams:
			seam_ratios.append(_seam_ratio(data, demo.solver.map_size))
	var primary_normal := PackedByteArray()
	if include_normal or include_topology:
		primary_normal = await _read_texture(demo.solver.get_normal_tex_rid(), 0)
		var normal_metrics := _normal_metrics(primary_normal)
		slope_sq = normal_metrics.slope_sq
		slope_count = normal_metrics.count
		slope_bands.append(sqrt(normal_metrics.slope_sq
			/ maxf(float(normal_metrics.count), 1.0)))
		crest_sum = normal_metrics.crest_sum
		crest_count = normal_metrics.count
		crest_active = normal_metrics.crest_active
		breaking_active = normal_metrics.breaking_active
		primary_crest_active = normal_metrics.crest_active
		primary_breaking_active = normal_metrics.breaking_active
		breaking_sum = normal_metrics.breaking_sum
		non_finite += normal_metrics.non_finite
		peak_chop_correlation = _peak_chop_correlation(primary_data, primary_normal)
		if include_topology:
			primary_shape = _shape_coherence(primary_data, primary_normal, demo.solver.map_size)
	if include_foam:
		for layer in 3:
			var base := _foam_base(await _read_texture(demo.solver.get_foam_near_read_tex_rid(), layer), demo.solver.foam_near_size)
			var image := Image.create_from_data(demo.solver.foam_near_size, demo.solver.foam_near_size, false, Image.FORMAT_RGF, base)
			image.convert(Image.FORMAT_RGH)
			var foam := image.get_data()
			var foam_metrics := _foam_metrics(foam)
			if layer == 2 and include_topology:
				var foam_morphology := _foam_morphology(foam, 1)
				persistent_ribbon = foam_morphology.persistent
				fresh_ribbon = foam_morphology.fresh
				fresh_persistent_iou = foam_morphology.iou
			foam_sum += foam_metrics.sum
			fresh_sum += foam_metrics.fresh_sum
			foam_count += foam_metrics.count
			foam_active += foam_metrics.active
			foam_coverage_by_layer.append(float(foam_metrics.active)
				/ maxf(float(foam_metrics.count), 1.0))
			fresh_coverage_by_layer.append(float(foam_metrics.fresh_active)
				/ maxf(float(foam_metrics.count), 1.0))
			if layer == 0:
				primary_foam_active = foam_metrics.active
			non_finite += foam_metrics.non_finite
	if include_spectrum:
		var spectrum := await _read_texture(demo.solver._spectrum_tex, 0)
		band_energy = _spectrum_band_energy(spectrum,
			demo.solver.map_size, demo.solver.tile_lengths[0])
		dominant_wavelength = _dominant_wavelength(spectrum,
			demo.solver.map_size, demo.solver.tile_lengths[0])
		crosswind_energy = _crosswind_energy(spectrum, demo.solver.map_size,
			demo.solver.wind_direction)
	var band_total := 0.0
	var band_max := 0.0
	var active_band_count := 0
	for energy in band_energy:
		band_total += energy
		band_max = maxf(band_max, energy)
	if band_total > 0.0:
		for energy in band_energy:
			if energy > band_total * 0.01:
				active_band_count += 1
	var height_rms := sqrt(height_sq / maxf(float(height_count), 1.0))
	var slope_rms := sqrt(slope_sq / maxf(float(slope_count), 1.0))
	var crest_mean := crest_sum / maxf(float(crest_count), 1.0)
	var breaking_mean := breaking_sum / maxf(float(crest_count), 1.0)
	var foam_mean := foam_sum / maxf(float(foam_count), 1.0)
	var fresh_mean := fresh_sum / maxf(float(foam_count), 1.0)
	print("OCEAN METRICS height=%.4f slope=%.4f slopes=%s crest=%.4f crest_cov=%.4f breaking=%.4f foam=%.4f foam_cov=%.4f primary_cov=[%.4f,%.4f,%.4f] foam_layers=%s fresh_layers=%s bands=%s peak=%.3f corr=%.3f seams=%s" % [
		height_rms, slope_rms, slope_bands, crest_mean,
		float(crest_active) / maxf(float(crest_count), 1.0), breaking_mean, foam_mean,
		float(foam_active) / maxf(float(foam_count), 1.0),
		float(primary_crest_active) / maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
		float(primary_breaking_active) / maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
		float(primary_foam_active) / maxf(float(demo.solver.foam_near_size * demo.solver.foam_near_size), 1.0),
		foam_coverage_by_layer, fresh_coverage_by_layer,
		band_energy,
		band_max / maxf(band_total, 1e-6), peak_chop_correlation, seam_ratios])
	if include_topology:
		print("OCEAN TOPOLOGY shape=%s persistent=%s fresh=%s iou=%.3f" % [
			primary_shape, persistent_ribbon, fresh_ribbon, fresh_persistent_iou])
	return {
		"height_rms": height_rms,
		"slope_rms": slope_rms,
		"crest_mean": crest_mean,
		"crest_coverage": float(crest_active) / maxf(float(crest_count), 1.0),
		"breaking_coverage": float(breaking_active) / maxf(float(crest_count), 1.0),
		"primary_crest_coverage": float(primary_crest_active)
			/ maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
		"primary_breaking_coverage": float(primary_breaking_active)
			/ maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
		"foam_mean": foam_mean,
		"fresh_mean": fresh_mean,
		"foam_coverage": float(foam_active) / maxf(float(foam_count), 1.0),
		"primary_foam_coverage": float(primary_foam_active)
			/ maxf(float(demo.solver.foam_near_size * demo.solver.foam_near_size), 1.0),
		"foam_coverage_by_layer": foam_coverage_by_layer,
		"fresh_coverage_by_layer": fresh_coverage_by_layer,
		"primary_crest_asymmetry": primary_crest_asymmetry,
		"primary_shape": primary_shape,
		"seam_ratios": seam_ratios,
		"persistent_ribbon": persistent_ribbon,
		"fresh_ribbon": fresh_ribbon,
		"fresh_persistent_iou": fresh_persistent_iou,
		"dominant_wavelength_m": dominant_wavelength,
		"crosswind_energy": crosswind_energy,
		"groupiness": groupiness,
		"long_max_abs": long_max_abs,
		"long_max_rms": long_max_rms,
		"band_rms": band_rms,
		"band_energy": band_energy,
		"band_peak_fraction": band_max / maxf(band_total, 1e-6),
		"active_band_count": active_band_count,
		"peak_chop_correlation": peak_chop_correlation,
		"non_finite": non_finite,
	}


func _height_rms(data: PackedByteArray) -> Dictionary:
	var sum_sq := 0.0
	var count := 0
	var non_finite := 0
	var max_abs := 0.0
	var max_height := -INF
	var min_height := INF
	for i in data.size() / 8:
		var decoded := _half(data.decode_u16(i * 8 + 2))
		if not decoded.finite:
			non_finite += 1
			continue
		sum_sq += decoded.value * decoded.value
		max_abs = maxf(max_abs, absf(decoded.value))
		max_height = maxf(max_height, decoded.value)
		min_height = minf(min_height, decoded.value)
		count += 1
	return {"rms": sqrt(sum_sq / maxf(count, 1)), "max_abs": max_abs, "max_height": max_height,
		"min_height": min_height, "sum_sq": sum_sq, "count": count, "non_finite": non_finite}


func _groupiness(data: PackedByteArray, n: int, tile_length: float,
		wavelength: float) -> float:
	var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBAH, data)
	image.convert(Image.FORMAT_RGBAF)
	var values := image.get_data().to_float32_array()
	var grad_x := 0.0
	var grad_y := 0.0
	for y in range(0, n, 4):
		for x in range(0, n, 4):
			var h := values[(y * n + x) * 4 + 1]
			grad_x += absf(values[(y * n + (x + 1) % n) * 4 + 1] - h)
			grad_y += absf(values[(((y + 1) % n) * n + x) * 4 + 1] - h)
	var along_x := grad_x >= grad_y
	var window := clampi(roundi(wavelength / tile_length * n), 8, n / 3)
	var envelopes: Array[float] = []
	for line in range(0, n, 8):
		for start in range(0, n, 4):
			var local_sq := 0.0
			for offset in window:
				var x := (start + offset) % n if along_x else line
				var y := line if along_x else (start + offset) % n
				var h := values[(y * n + x) * 4 + 1]
				local_sq += h * h
			envelopes.append(sqrt(local_sq / float(window)))
	var mean := 0.0
	for value in envelopes:
		mean += value
	mean /= maxf(envelopes.size(), 1)
	var variance := 0.0
	for value in envelopes:
		variance += (value - mean) * (value - mean)
	return sqrt(variance / maxf(envelopes.size(), 1)) / maxf(mean, 0.0001)


func _dominant_wavelength(data: PackedByteArray, n: int, tile_length: float) -> float:
	var values := data.to_float32_array()
	var bins: Dictionary = {}
	for y in n:
		for x in n:
			var radius := Vector2(float(x) - n * 0.5, float(y) - n * 0.5).length()
			if radius < 1.0:
				continue
			var wavelength := tile_length / radius
			if wavelength < 30.0 or wavelength > 400.0:
				continue
			var i := (y * n + x) * 4
			var energy := values[i] * values[i] + values[i + 1] * values[i + 1]
			var bin := roundi(wavelength / 5.0) * 5
			bins[bin] = bins.get(bin, 0.0) + energy
	var dominant := 0
	var max_energy := -1.0
	for bin in bins:
		if bins[bin] > max_energy:
			max_energy = bins[bin]
			dominant = bin
	return float(dominant)


## Peak wavelength of a cascade spectrum inside that cascade's band window.
func _cascade_peak_wavelength(data: PackedByteArray, n: int, tile_length: float) -> float:
	var values := data.to_float32_array()
	var bins: Dictionary = {}
	for y in n:
		for x in n:
			var radius := Vector2(float(x) - n * 0.5, float(y) - n * 0.5).length()
			if radius < 1.0:
				continue
			var wavelength := tile_length / radius
			if wavelength < 2.0 or wavelength > tile_length * 0.9:
				continue
			var i := (y * n + x) * 4
			var energy := values[i] * values[i] + values[i + 1] * values[i + 1]
			var bin := roundi(wavelength / 2.0) * 2
			bins[bin] = bins.get(bin, 0.0) + energy
	var dominant := 0
	var max_energy := -1.0
	for bin in bins:
		if bins[bin] > max_energy:
			max_energy = bins[bin]
			dominant = bin
	return float(dominant)


## Highest normalized lag correlation of the height field for lags between
## min_lag_m and max_lag_m. Periodic wave trains (tiled spectra) spike to ~1;
## organic FFT interference stays low.
func _max_lag_correlation(data: PackedByteArray, map_size: int, tile_length: float,
		min_lag_m: float, max_lag_m: float) -> float:
	var values := _rgba_half_values(data, map_size)
	var texel_m := tile_length / float(map_size)
	var min_lag := maxi(int(min_lag_m / texel_m), 1)
	var max_lag := mini(int(max_lag_m / texel_m), map_size / 2)
	var best := -1.0
	var lag := min_lag
	while lag <= max_lag:
		var count := 0
		var sum_sq := 0.0
		var sum_lag_sq := 0.0
		var sum_cross := 0.0
		for y in range(0, map_size, 2):
			var row := y * map_size
			for x in range(0, map_size, 2):
				var h := values[(row + x) * 4 + 1]
				var h_lag := values[(row + (x + lag) % map_size) * 4 + 1]
				sum_sq += h * h
				sum_lag_sq += h_lag * h_lag
				sum_cross += h * h_lag
				count += 1
		var correlation := (sum_cross / count) \
			/ maxf(sqrt((sum_sq / count) * (sum_lag_sq / count)), 1e-9)
		best = maxf(best, correlation)
		lag += maxi((max_lag - min_lag) / 24, 1)
	return best


func _normal_metrics(data: PackedByteArray) -> Dictionary:
	var slope_sq := 0.0
	var crest_sum := 0.0
	var breaking_sum := 0.0
	var crest_active := 0
	var breaking_active := 0
	var count := 0
	var non_finite := 0
	for i in data.size() / 8:
		var x := _half(data.decode_u16(i * 8))
		var y := _half(data.decode_u16(i * 8 + 2))
		var crest := _half(data.decode_u16(i * 8 + 4))
		var breaking := _half(data.decode_u16(i * 8 + 6))
		if not x.finite or not y.finite or not crest.finite or not breaking.finite:
			non_finite += 1
			continue
		slope_sq += x.value * x.value + y.value * y.value
		crest_sum += crest.value
		breaking_sum += breaking.value
		if crest.value > OceanConfig.MEASURE_CREST_THRESHOLD:
			crest_active += 1
		if breaking.value > OceanConfig.MEASURE_BREAKING_THRESHOLD:
			breaking_active += 1
		count += 1
	return {"slope_sq": slope_sq, "crest_sum": crest_sum,
		"breaking_sum": breaking_sum,
		"crest_active": crest_active, "breaking_active": breaking_active,
		"count": count, "non_finite": non_finite}


func _foam_metrics(data: PackedByteArray) -> Dictionary:
	var sum := 0.0
	var fresh_sum := 0.0
	var active := 0
	var fresh_active := 0
	var count := 0
	var non_finite := 0
	for i in data.size() / 4:
		var foam := _half(data.decode_u16(i * 4))
		var fresh := _half(data.decode_u16(i * 4 + 2))
		if not foam.finite or not fresh.finite:
			non_finite += 1
			continue
		sum += foam.value
		fresh_sum += fresh.value
		if foam.value > OceanConfig.MEASURE_FOAM_THRESHOLD:
			active += 1
		if fresh.value > OceanConfig.MEASURE_FRESH_THRESHOLD:
			fresh_active += 1
		count += 1
	return {"sum": sum, "fresh_sum": fresh_sum, "active": active,
		"fresh_active": fresh_active,
		"count": count, "non_finite": non_finite}


func _seam_ratio(data: PackedByteArray, map_size: int) -> float:
	var values := _rgba_half_values(data, map_size)
	var seam_sum := 0.0
	var seam_count := 0
	for y in map_size:
		var row := y * map_size
		seam_sum += absf(values[row * 4 + 1] - values[(row + map_size - 1) * 4 + 1])
		seam_count += 1
	for x in map_size:
		seam_sum += absf(values[x * 4 + 1] - values[((map_size - 1) * map_size + x) * 4 + 1])
		seam_count += 1
	var local_sum := 0.0
	var local_count := 0
	for y in range(0, map_size - 1, 4):
		for x in range(0, map_size - 1, 4):
			var index := (y * map_size + x) * 4 + 1
			local_sum += absf(values[index] - values[index + 4])
			local_sum += absf(values[index] - values[index + map_size * 4])
			local_count += 2
	return seam_sum / float(seam_count) / maxf(local_sum / float(local_count), 0.000001)


func _shape_coherence(displacement: PackedByteArray, normal: PackedByteArray, map_size: int) -> Dictionary:
	var heights := _rgba_half_values(displacement, map_size)
	var normals := _rgba_half_values(normal, map_size)
	var breaking_count := 0
	var quiet_count := 0
	var breaking_height_sum := 0.0
	var quiet_height_sum := 0.0
	var breaking_slope_sum := 0.0
	var quiet_slope_sum := 0.0
	var breaking_curvature_sum := 0.0
	var quiet_curvature_sum := 0.0
	var breaking_crest_sum := 0.0
	var quiet_crest_sum := 0.0
	const STEP := 16
	for y in range(0, map_size, STEP):
		var row := y * map_size
		var north_row := (y - STEP + map_size) % map_size * map_size
		var south_row := (y + STEP) % map_size * map_size
		for x in range(0, map_size, STEP):
			var west := (x - STEP + map_size) % map_size
			var east := (x + STEP) % map_size
			var index := (row + x) * 4
			var height := heights[index + 1]
			var curvature := maxf(height * 4.0 - heights[(row + west) * 4 + 1] - heights[(row + east) * 4 + 1] - heights[(north_row + x) * 4 + 1] - heights[(south_row + x) * 4 + 1], 0.0)
			var slope := sqrt(normals[index] * normals[index] + normals[index + 1] * normals[index + 1])
			var crest := normals[index + 2]
			if normals[index + 3] > 0.15:
				breaking_count += 1
				breaking_height_sum += height
				breaking_slope_sum += slope
				breaking_curvature_sum += curvature
				breaking_crest_sum += crest
			else:
				quiet_count += 1
				quiet_height_sum += height
				quiet_slope_sum += slope
				quiet_curvature_sum += curvature
				quiet_crest_sum += crest
	return {
		"breaking_count": breaking_count,
		"breaking_height_mean": breaking_height_sum / maxf(float(breaking_count), 1.0),
		"quiet_height_mean": quiet_height_sum / maxf(float(quiet_count), 1.0),
		"breaking_slope_mean": breaking_slope_sum / maxf(float(breaking_count), 1.0),
		"quiet_slope_mean": quiet_slope_sum / maxf(float(quiet_count), 1.0),
		"breaking_curvature_mean": breaking_curvature_sum / maxf(float(breaking_count), 1.0),
		"quiet_curvature_mean": quiet_curvature_sum / maxf(float(quiet_count), 1.0),
		"breaking_crest_mean": breaking_crest_sum / maxf(float(breaking_count), 1.0),
		"quiet_crest_mean": quiet_crest_sum / maxf(float(quiet_count), 1.0),
	}


func _foam_morphology(data: PackedByteArray, sample_step: int = 4,
		fresh_threshold: float = OceanConfig.MEASURE_FRESH_THRESHOLD) -> Dictionary:
	var map_size := int(sqrt(data.size() / 4.0))
	var sampled_size := map_size / sample_step
	var persistent := PackedByteArray()
	var fresh := PackedByteArray()
	persistent.resize(sampled_size * sampled_size)
	fresh.resize(sampled_size * sampled_size)
	var intersection := 0
	var union := 0
	for y in sampled_size:
		for x in sampled_size:
			var texel := y * sampled_size + x
			var source_texel := (y * sample_step * map_size + x * sample_step)
			var foam := _half(data.decode_u16(source_texel * 4))
			var fresh_foam := _half(data.decode_u16(source_texel * 4 + 2))
			persistent[texel] = int(foam.finite and foam.value > OceanConfig.MEASURE_FOAM_THRESHOLD)
			fresh[texel] = int(fresh_foam.finite
				and fresh_foam.value > fresh_threshold)
			if persistent[texel] != 0 and fresh[texel] != 0:
				intersection += 1
			if persistent[texel] != 0 or fresh[texel] != 0:
				union += 1
	return {
		"persistent": _ribbon_metrics(persistent, sampled_size, sample_step),
		"fresh": _ribbon_metrics(fresh, sampled_size, sample_step),
		"coverage": float(union) / float(sampled_size * sampled_size),
		"iou": float(intersection) / maxf(float(union), 1.0),
	}


func _ribbon_metrics(mask: PackedByteArray, map_size: int, sample_step: int) -> Dictionary:
	var active_pixels := 0
	var isolated_pixels := 0
	var dense_pixels := 0
	var widths: Array[float] = []
	for y in map_size:
		var x := 0
		while x < map_size:
			var texel := y * map_size + x
			if mask[texel] == 0:
				x += 1
				continue
			var run_length := 0
			while x < map_size and mask[y * map_size + x] != 0:
				run_length += 1
				x += 1
			if run_length * sample_step >= 8:
				widths.append(float(run_length * sample_step))
	for texel in map_size * map_size:
		if mask[texel] == 0:
			continue
		active_pixels += 1
		var x := texel % map_size
		var y := texel / map_size
		var left := y * map_size + (x - 1 + map_size) % map_size
		var right := y * map_size + (x + 1) % map_size
		var up := ((y - 1 + map_size) % map_size) * map_size + x
		var down := ((y + 1) % map_size) * map_size + x
		if mask[left] == 0 and mask[right] == 0 and mask[up] == 0 and mask[down] == 0:
			isolated_pixels += 1
		var up_left := ((y - 1 + map_size) % map_size) * map_size + (x - 1 + map_size) % map_size
		var up_right := ((y - 1 + map_size) % map_size) * map_size + (x + 1) % map_size
		var down_left := ((y + 1) % map_size) * map_size + (x - 1 + map_size) % map_size
		var down_right := ((y + 1) % map_size) * map_size + (x + 1) % map_size
		if mask[left] != 0 and mask[right] != 0 and mask[up] != 0 and mask[down] != 0 \
			and mask[up_left] != 0 and mask[up_right] != 0 \
			and mask[down_left] != 0 and mask[down_right] != 0:
			dense_pixels += 1
	widths.sort()
	var mean_width := 0.0
	for width in widths:
		mean_width += width
	mean_width /= maxf(float(widths.size()), 1.0)
	var p95_index := int(ceil(float(widths.size()) * 0.95)) - 1
	var p95_width := 0.0 if widths.is_empty() else widths[maxi(p95_index, 0)]
	return {
		"area": float(active_pixels) / float(map_size * map_size),
		"component_count": widths.size(),
		"mean_width": mean_width,
		"p95_width": p95_width,
		"small_pixel_fraction": float(isolated_pixels) / maxf(float(active_pixels), 1.0),
		"dense_pixel_fraction": float(dense_pixels) / maxf(float(active_pixels), 1.0),
	}


func _check_foam_phases(demo: Node) -> void:
	var camera_state: Array = [demo.orbit_cam.target, demo.orbit_cam.distance,
		demo.orbit_cam.pitch, demo.orbit_cam.yaw, demo.orbit_cam.is_processing(),
		demo._capture_view_name, demo.rocks.visible, demo._capture_interaction_foam]
	_check(OceanQualityProfile.TIER_NAMES == ["Low", "Medium", "High", "Ultra"]
		and OceanQualityProfile.Tier.LOW == 0
		and OceanQualityProfile.Tier.MEDIUM == 1 and OceanQualityProfile.Tier.HIGH == 2
		and OceanQualityProfile.Tier.ULTRA == 3,
		"quality names or saved tier identifiers changed")
	var coverages: Array[float] = []
	for tier in [OceanQualityProfile.Tier.LOW, OceanQualityProfile.Tier.MEDIUM,
			OceanQualityProfile.Tier.HIGH, OceanQualityProfile.Tier.ULTRA]:
		demo.set_quality_profile(tier)
		if not await _wait_ocean_ready(demo, 20000):
			_check(false, "foam phase profile did not initialize")
			return
		demo.apply_preset(2)
		demo.set_capture_view("low_crest")
		demo.set_capture_time(20.0)
		demo.set_capture_wind_direction(0.0)
		RenderingServer.call_on_render_thread(demo.solver._clear_foam_fields)
		await demo.warmup_foam(5.0)
		_check(demo.solver.estimate_vram_bytes() == OceanQualityProfile.estimate_vram_bytes(tier),
			"foam profile VRAM allocation mismatch")
		for layer in 3:
			var size: int = demo.solver.foam_near_size
			var bytes := _foam_base(await _read_texture(demo.solver.get_foam_near_read_tex_rid(), layer), size)
			var image := Image.create_from_data(size, size, false, Image.FORMAT_RGF, bytes)
			image.convert(Image.FORMAT_RGH)
			var morphology := _foam_morphology(image.get_data(), 1, OceanConfig.MEASURE_FOAM_THRESHOLD)
			print("FOAM PHASE tier=%s layer=%d %s" % [OceanQualityProfile.TIER_NAMES[tier], layer, morphology])
			# The long-crest swell breaks into finer ribbons than the old steep
			# wind sea, so Low resolves ~2 pp less foam than Medium: the window
			# keeps the 0 % / blow-up guards with room for that texture shift.
			_check(morphology.coverage >= 0.065 and morphology.coverage <= 0.145,
				"Swell coverage outside 6.5..14.5 percent on tier %d layer %d" % [tier, layer])
			if tier == OceanQualityProfile.Tier.MEDIUM and layer == 0:
				_check(morphology.fresh.area < morphology.persistent.area,
					"Swell active area is not narrower than residual on layer %d" % layer)
				_check(morphology.fresh.p95_width < morphology.persistent.p95_width,
					"Swell active P95 width is not narrower than residual on layer %d" % layer)
			var common_size := roundi(size * 96.0 / demo.solver.foam_near_domain)
			var common := image.get_region(Rect2i((size - common_size) / 2,
				(size - common_size) / 2, common_size, common_size))
			var common_morphology := _foam_morphology(common.get_data(), 1, OceanConfig.MEASURE_FOAM_THRESHOLD)
			coverages.append(common_morphology.coverage)
			print("FOAM COMMON tier=%s layer=%d coverage=%.6f" % [OceanQualityProfile.TIER_NAMES[tier], layer, common_morphology.coverage])
	for layer in 3:
		for tier in [OceanQualityProfile.Tier.LOW, OceanQualityProfile.Tier.HIGH,
				OceanQualityProfile.Tier.ULTRA]:
			_check(absf(coverages[tier * 3 + layer]
					- coverages[OceanQualityProfile.Tier.MEDIUM * 3 + layer]) <= 0.025,
				"Swell profile coverage differs from Medium by over 2.5 percentage points on tier %d layer %d" % [tier, layer])
	demo.orbit_cam.target = camera_state[0]
	demo.orbit_cam.distance = camera_state[1]
	demo.orbit_cam.pitch = camera_state[2]
	demo.orbit_cam.yaw = camera_state[3]
	demo.orbit_cam.set_enabled(camera_state[4])
	demo.orbit_cam._update_transform()
	demo._capture_view_name = camera_state[5]
	demo.rocks.visible = camera_state[6]
	demo.set_capture_interaction(camera_state[7])


func _check_nyquist_derivatives(solver: OceanSolver) -> void:
	RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
	var data := await _read_texture(solver.get_derivative_tex_rid(), 2)
	var n := solver.map_size
	var field := _rgba_half_values(data, n)
	var nyquist_energy := 0.0
	var total_energy := 0.0
	for x in n:
		var alternating := 0.0
		for y in n:
			var value := field[(y * n + x) * 4 + 1]
			alternating += value if y % 2 == 0 else -value
			total_energy += value * value
		nyquist_energy += alternating * alternating / n
	_check(total_energy > 0.0001, "Nyquist check needs a nonzero short-wave field")
	_check(nyquist_energy / maxf(total_energy, 1e-10) < 0.000001,
		"odd spectral derivative retained a Nyquist mode")


func _check_coherence_contracts(demo: Node) -> void:
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	if not await _wait_ocean_ready(demo, 20000):
		_check(false, "coherence mode timed out waiting for Medium profile")
		return
	demo.apply_preset(3)
	demo.set_frozen(true)
	demo.set_capture_time(20.0)
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0, 20.0))
	await process_frame
	await _check_single_wave(demo.solver)
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0, 20.0))
	await process_frame
	await _check_parseval(demo.solver, 20.0)
	await _check_centered_mode_coherence(demo)
	await _check_composite_derivatives(demo.solver)
	await _check_nested_foam(demo.solver)
	await _check_foam_mip_coverage(demo)
	for preset in [2, 3]:
		for gain in [1.0, 2.0, 3.0]:
			demo.apply_preset(preset)
			demo.solver.height_gain = gain
			demo.solver.mark_spectrum_dirty()
			RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0, 20.0))
			await process_frame
			await _check_composite_derivatives(demo.solver)


func _check_foam_mip_coverage(demo: Node) -> void:
	var solver: OceanSolver = demo.solver
	demo.set_process(false)
	var mip_size := solver.foam_near_size
	var float_count := 0
	while mip_size > 0:
		float_count += mip_size * mip_size * 2
		mip_size /= 2
	var pattern := PackedFloat32Array()
	pattern.resize(float_count)
	for i in solver.foam_near_size * solver.foam_near_size:
		pattern[i * 2] = 0.1 if i % 64 < 32 else 0.7
		pattern[i * 2 + 1] = 0.5 if i % 64 < 32 else 0.1
	var bytes := pattern.to_byte_array()
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		for layer in 3:
			rd.texture_update(solver.get_foam_near_read_tex_rid(), layer, bytes)
		var cl := rd.compute_list_begin()
		solver._generate_foam_mips(cl, solver.get_foam_near_read_index())
		rd.compute_list_end()
	)
	await RenderingServer.frame_post_draw
	for layer in 3:
		var data := await _read_texture(solver.get_foam_near_read_tex_rid(), layer)
		var base := _foam_base(data, solver.foam_near_size).to_float32_array()
		var persistent := 0.0
		var fresh := 0.0
		for i in range(0, base.size(), 2):
			_check(is_finite(base[i]) and is_finite(base[i + 1]), "non-finite foam mip input")
			persistent += base[i]
			fresh += base[i + 1]
		var mean := Vector2(persistent / (base.size() / 2), fresh / (base.size() / 2))
		var filtered := Vector2(data.decode_float(data.size() - 8), data.decode_float(data.size() - 4))
		_check(mean.distance_to(filtered) < 0.000001, "foam mip chain lost mean coverage")
		_check(filtered.distance_to(Vector2(0.4, 0.3)) < 0.000001, "foam mip pattern was not evaluated")
		print("COHERENCE foam mip layer=%d mean=%s filtered=%s" % [layer, mean, filtered])
	demo.set_process(true)


func _wait_ocean_ready(demo: Node, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if demo.solver.initialized and demo.texture_bound:
			return true
		await process_frame
	return demo.solver.initialized and demo.texture_bound


func _check_parseval(solver: OceanSolver, time: float) -> void:
	var n: int = solver.map_size
	var spectrum := _rgba_float_values(await _read_texture(solver._spectrum_tex, 0), n)
	var displacement := _rgba_half_values(
		await _read_texture(solver.get_displacement_tex_rid(), 0), n)
	var spectral_energy := 0.0
	var spatial_energy := 0.0
	for y in n:
		for x in n:
			var offset := (y * n + x) * 4
			var a := Vector2(spectrum[offset], spectrum[offset + 1])
			var b := Vector2(spectrum[offset + 2], spectrum[offset + 3])
			var k := Vector2(float(x) - n * 0.5, float(y) - n * 0.5) \
				* TAU / solver.tile_lengths[0]
			var magnitude := k.length() + 1e-6
			var omega := sqrt(9.81 * magnitude * tanh(magnitude * solver.water_depth))
			var c := cos(omega * time)
			var s := sin(omega * time)
			var h := Vector2(a.x * c - a.y * s + b.x * c + b.y * s,
				 a.x * s + a.y * c - b.x * s + b.y * c)
			spectral_energy += h.length_squared()
			spatial_energy += displacement[offset + 1] * displacement[offset + 1]
	var expected := spectral_energy * float(n * n)
	var ratio := spatial_energy / maxf(expected, 1e-8)
	_check(absf(ratio - 1.0) < 0.005,
		"height Parseval ratio is %.5f (expected 1)" % ratio)
	print("COHERENCE Parseval ratio=%.6f" % ratio)


func _check_centered_mode_coherence(demo: Node) -> void:
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	if not await _wait_ocean_ready(demo, 20000):
		_check(false, "coherence mode timed out reinitializing Medium profile")
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0, 20.0))
	await process_frame
	var high_n: int = demo.solver.map_size
	var high := _rgba_float_values(await _read_texture(demo.solver._spectrum_tex, 0), high_n)
	demo.set_quality_profile(OceanQualityProfile.Tier.ULTRA)
	if not await _wait_ocean_ready(demo, 30000):
		_check(false, "coherence mode timed out reinitializing Ultra profile")
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0, 20.0))
	await process_frame
	var ultra_n: int = demo.solver.map_size
	var ultra := _rgba_float_values(await _read_texture(demo.solver._spectrum_tex, 0), ultra_n)
	var max_error := 0.0
	for mode in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(3, 2),
			Vector2i(16, -11), Vector2i(64, 37), Vector2i(128, -96), Vector2i(200, 120)]:
		var hi := _spectrum_mode(high, high_n, mode)
		var ultra_mode := _spectrum_mode(ultra, ultra_n, mode)
		max_error = maxf(max_error, hi.distance_to(ultra_mode))
	_check(max_error < 1e-6,
		"centered common-mode h0 differs across High/Ultra (max %.7f)" % max_error)
	print("COHERENCE shared modes max_error=%.7f" % max_error)


func _spectrum_mode(values: PackedFloat32Array, n: int, mode: Vector2i) -> Vector4:
	var x := n / 2 + mode.x
	var y := n / 2 + mode.y
	var offset := (y * n + x) * 4
	return Vector4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3])


func _check_composite_derivatives(solver: OceanSolver) -> void:
	var n: int = solver.map_size
	var displacement: Array[PackedFloat32Array] = []
	var derivatives: Array[PackedFloat32Array] = []
	for layer in 3:
		displacement.append(_rgba_half_values(
			await _read_texture(solver.get_displacement_tex_rid(), layer), n))
		derivatives.append(_rgba_half_values(
			await _read_texture(solver.get_derivative_tex_rid(), layer), n))
	var epsilon := solver.tile_lengths[2] / float(n) * 0.5
	for point in [Vector2(0.37, -0.22), Vector2(7.13, 4.81), Vector2(-12.4, 9.7)]:
		var plus_x := _composite_sample(displacement, n, solver.tile_lengths,
			point + Vector2(epsilon, 0.0))
		var minus_x := _composite_sample(displacement, n, solver.tile_lengths,
			point - Vector2(epsilon, 0.0))
		var plus_z := _composite_sample(displacement, n, solver.tile_lengths,
			point + Vector2(0.0, epsilon))
		var minus_z := _composite_sample(displacement, n, solver.tile_lengths,
			point - Vector2(0.0, epsilon))
		var finite := Vector4(
			(plus_x.x - minus_x.x) / (2.0 * epsilon),
			(plus_z.z - minus_z.z) / (2.0 * epsilon),
			(plus_x.z - minus_x.z) / (2.0 * epsilon),
			(plus_x.y - minus_x.y) / (2.0 * epsilon))
		var analytic := _composite_derivative(derivatives, n, solver.tile_lengths, point)
		_check(analytic.distance_to(finite) < 0.30,
			"composite derivative mismatch at %s: analytic=%s finite=%s" \
			% [point, analytic, finite])


func _composite_sample(fields: Array[PackedFloat32Array], n: int,
		tiles: PackedFloat32Array, point: Vector2) -> Vector4:
	var result := Vector4.ZERO
	for layer in fields.size():
		result += _sample_map_vec4(fields[layer], n, tiles[layer], point)
	return result


func _composite_derivative(fields: Array[PackedFloat32Array], n: int,
		tiles: PackedFloat32Array, point: Vector2) -> Vector4:
	var result := Vector4.ZERO
	for layer in fields.size():
		result += _sample_map_vec4(fields[layer], n, tiles[layer], point)
	return result


func _check_nested_foam(solver: OceanSolver) -> void:
	var saved := Vector3(solver.foam_amount, solver.foam_persistence, solver.whitecap)
	solver.foam_amount = 5.6
	solver.foam_persistence = 4.2
	solver.whitecap = 0.84
	var flat := await _constant_foam_layers(solver, Color(0, 0, 0, 0), 30, 1.0)
	var compressed30 := await _constant_foam_layers(solver, Color(-0.8, 0, 0, 0), 30, 1.0)
	var compressed60 := await _constant_foam_layers(solver, Color(-0.8, 0, 0, 0), 60, 1.0)
	var compressed120 := await _constant_foam_layers(solver, Color(-0.8, 0, 0, 0), 120, 1.0)
	for layer in 3:
		_check(flat[layer].length() < 1e-4,
			"flat nested foam generated coverage on layer %d" % layer)
		_check(compressed30[layer].x > 0.0 and compressed30[layer].y > compressed30[layer].x,
			"nested foam source missing or fresh channel collapsed on layer %d" % layer)
		_check(compressed30[layer].distance_to(compressed60[layer]) < 0.0001
			and compressed60[layer].distance_to(compressed120[layer]) < 0.0001,
			"nested foam depends on frame count on layer %d" % layer)
	var onset := clampf(solver.whitecap, 0.05, 0.95)
	var source := smoothstep(0.0, 0.2, onset - 0.2)
	var decay := 0.693 / solver.foam_persistence
	var active_rate := source * 6.0 + 0.693 / (solver.foam_persistence * 0.167)
	var expected := 0.68 * source * 6.0 / active_rate * (1.0 - exp(-decay)
		- decay * (exp(-decay) - exp(-active_rate)) / (active_rate - decay))
	_check(absf(compressed30[0].x - expected) < 0.02,
		"nested foam source integration mismatch: %.5f vs %.5f" % [compressed30[0].x, expected])
	print("COHERENCE foam dt30=%s dt60=%s dt120=%s" % [compressed30, compressed60, compressed120])
	var stable := await _constant_foam_layers(solver, Color(-0.8, 0, 0, 0), 120, 120.0)
	for layer in stable.size():
		_check(stable[layer].x <= 1.0 and stable[layer].y <= 1.0
			and Vector2(stable[layer].x, stable[layer].y).is_finite(),
			"nested foam became non-finite or exceeded bounds")
	var clear := await _constant_foam_layers(solver, Color(0, 0, 0, 0), 30, 1.0, false)
	for layer in clear.size():
		_check(clear[layer].x < stable[layer].x and clear[layer].y < stable[layer].y,
			"nested foam did not decay after source reset on layer %d" % layer)
		_check(clear[layer].y / stable[layer].y < clear[layer].x / stable[layer].x,
			"active foam did not extinguish faster than residual on layer %d" % layer)
	var pulse := await _constant_foam_layers(solver, Color(-0.8, 0, 0, 0), 12, 0.1)
	var tail := await _constant_foam_layers(solver, Color(0, 0, 0, 0), 120, 4.2, false)
	for layer in pulse.size():
		_check(pulse[layer].y > pulse[layer].x * 10.0,
			"active foam attack is not faster than residual on layer %d" % layer)
		_check(tail[layer].x > tail[layer].y and tail[layer].x > pulse[layer].x,
			"active foam did not feed a persistent residual tail on layer %d" % layer)
	RenderingServer.call_on_render_thread(func():
		RenderingServer.get_rendering_device().texture_clear(
			solver.get_foam_near_read_tex_rid(), Color(0.5, 0, 0, 0), 0, 1, 0, 3)
	)
	await RenderingServer.frame_post_draw
	var half_life := await _constant_foam_layers(solver, Color(0, 0, 0, 0), 120, 4.2, false)
	for layer in half_life.size():
		_check(absf(half_life[layer].x - 0.25) < 0.0001 and half_life[layer].y < 0.0001,
			"residual half-life does not match foam_persistence on layer %d" % layer)
	solver.foam_amount = saved.x
	solver.foam_persistence = saved.y
	solver.whitecap = saved.z
	solver.mark_spectrum_dirty()


func _check_combined_foam(solver: OceanSolver) -> void:
	var saved := Vector3(solver.foam_amount, solver.foam_persistence, solver.whitecap)
	solver.foam_amount = 5.6
	solver.foam_persistence = 4.2
	solver.whitecap = 0.84
	var flat := await _constant_foam(solver, Color(0, 0, 0, 0), 30)
	var compressed := await _constant_foam(solver, Color(-0.8, 0, 0, 0), 30)
	var fine_step := await _constant_foam(solver, Color(-0.8, 0, 0, 0), 120)
	var rotated := await _constant_foam(solver, Color(-0.4, -0.4, 0.4, 0), 30)
	_check(flat.length() < 0.0001, "flat combined surface generated foam")
	var source := smoothstep(0.0, 0.2, clampf(solver.whitecap, 0.05, 0.95) - 0.2)
	var decay := 0.693 / solver.foam_persistence
	var active_rate := source * 6.0 + 0.693 / (solver.foam_persistence * 0.167)
	var expected_persistent := 0.68 * source * 6.0 / active_rate * (1.0 - exp(-decay)
		- decay * (exp(-decay) - exp(-active_rate)) / (active_rate - decay))
	_check(absf(compressed.x - expected_persistent) < 0.0001 and compressed.y > compressed.x,
		"combined compression did not generate distinct fresh and persistent coverage")
	_check(compressed.distance_to(fine_step) < 0.0001,
		"foam integration depends on frame rate")
	_check(compressed.distance_to(rotated) < 0.0001,
		"foam compression is not rotation invariant")
	print("FOAM CHECK flat=%s compressed=%s dt120=%s rotated=%s" % [flat, compressed, fine_step, rotated])
	solver.foam_amount = saved.x
	solver.foam_persistence = saved.y
	solver.whitecap = saved.z
	solver.mark_spectrum_dirty()


func _check_single_wave(solver: OceanSolver) -> void:
	var n := solver.map_size
	var spectrum := PackedByteArray()
	spectrum.resize(n * n * 16)
	var mode := Vector2i(3, 4)
	var positive := Vector2i(n / 2, n / 2) + mode
	var negative := Vector2i(n / 2, n / 2) - mode
	spectrum.encode_float((positive.y * n + positive.x) * 16, 0.5)
	spectrum.encode_float((negative.y * n + negative.x) * 16 + 8, 0.5)
	solver.take_render_refresh_request()
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_update(solver._spectrum_tex, 0, spectrum)
		var pc := solver._pack_push_constant(0, 0.0, 0.0)
		pc.encode_float(60, 0.0)
		var cl := rd.compute_list_begin()
		solver._dispatch(cl, "spectrum_evolve", pc, n / 16, n / 16, 1)
		solver._dispatch(cl, "fft", pc, 1, n, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "transpose", pc, n / 32, n / 32, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "fft", pc, 1, n, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "map_assemble", pc, n / 16, n / 16, 1)
		rd.compute_list_end()
	)
	var disp := _rgba_half_values(await _read_texture(solver.get_displacement_tex_rid(), 0), n)
	var deriv := _rgba_half_values(await _read_texture(solver.get_derivative_tex_rid(), 0), n)
	var error := 0.0
	var energy := 0.0
	var cell := solver.tile_lengths[0] / n
	for y in range(1, n - 1, 3):
		for x in range(1, n - 1, 3):
			var offset := (y * n + x) * 4
			var dx := (disp[offset + 4] - disp[offset - 4]) / (2.0 * cell)
			var dz := (disp[offset + n * 4 + 2] - disp[offset - n * 4 + 2]) / (2.0 * cell)
			var hx := (disp[offset + 5] - disp[offset - 3]) / (2.0 * cell)
			var hz := (disp[offset + n * 4 + 1] - disp[offset - n * 4 + 1]) / (2.0 * cell)
			error += pow(dx - deriv[offset], 2) + pow(dz - deriv[offset + 1], 2) \
				+ pow(hx - deriv[offset + 3], 2) + pow(hz - disp[offset + 3], 2)
			energy += dx * dx + dz * dz + hx * hx + hz * hz
	_check(energy > 0.000001 and error / maxf(energy, 1e-12) < 0.002,
		"single-wave derivatives disagree with displacement: %.6f" % (error / maxf(energy, 1e-12)))
	var vertical_error := 0.0
	for y in range(0, n, 3):
		for x in range(0, n, 3):
			var expected := cos(TAU * float(mode.y * x + mode.x * y) / n)
			vertical_error = maxf(vertical_error, absf(disp[(y * n + x) * 4 + 1] - expected))
	_check(vertical_error < 0.001, "horizontal correction changed the analytic wave height")
	var crest_divergence := deriv[0] + deriv[1]
	var trough_offset := (n / 8) * 4
	var trough_divergence := deriv[trough_offset] + deriv[trough_offset + 1]
	_check(crest_divergence < -0.001 and trough_divergence > 0.001,
		"single-wave chop must compress crests and expand troughs: %.5f / %.5f" % [
			crest_divergence, trough_divergence])
	solver.mark_spectrum_dirty()


func _check_jonswap_slider_controls(demo: Node) -> void:
	demo.apply_preset(2)
	var swell_preset: OceanPreset = demo.PRESETS[2]
	var menu: OceanMenu = demo._menu_builder
	var solver: OceanSolver = demo.solver
	_check(is_equal_approx(swell_preset.swell, 2.0)
		and is_equal_approx(swell_preset.spread, 0.05)
		and is_equal_approx(swell_preset.detail, 0.8)
		and is_equal_approx(swell_preset.jonswap_gamma, 5.0)
		and is_equal_approx(swell_preset.choppiness, 1.05),
		"Swell preset does not expose the grouped-wave parameters")
	_check(is_equal_approx(solver.detail, swell_preset.detail)
		and is_equal_approx(solver.jonswap_gamma, swell_preset.jonswap_gamma)
		and is_equal_approx(menu._detail.value, swell_preset.detail)
		and is_equal_approx(menu._jonswap_gamma.value, swell_preset.jonswap_gamma),
		"Swell detail or peak enhancement is not synchronized")
	var packed := solver._pack_push_constant(0, 1.0, 1.0)
	_check(is_equal_approx(packed.decode_float(104), swell_preset.jonswap_gamma),
		"JONSWAP peak enhancement is not packed at byte 104")

	demo.apply_preset(1)
	menu._wind_direction.value = 1.25
	menu._wind_speed.value = 13.0
	menu._fetch.value = 180.0
	menu._swell.value = 1.2
	menu._spread.value = 0.7
	menu._detail.value = 0.65
	menu._jonswap_gamma.value = 5.4
	menu._choppiness.value = 1.6
	menu._height_gain.value = 2.4
	menu._crest_bias.value = 0.42
	menu._crest_gain.value = 5.5
	menu._whitecap.value = 1.2
	menu._foam_amount.value = 4.0
	menu._foam_persistence.value = 6.0
	menu._spray_amount.value = 0.8
	menu._foam_strength.value = 1.4
	menu._foam_distance.value = 97.0 if is_equal_approx(menu._foam_distance.value, 96.0) \
		else 96.0
	_check(is_equal_approx(solver.wind_direction, menu._wind_direction.value)
		and is_equal_approx(solver.wind_speed, menu._wind_speed.value)
		and is_equal_approx(solver.fetch_km, menu._fetch.value)
		and is_equal_approx(solver.swell, menu._swell.value)
		and is_equal_approx(solver.spread, menu._spread.value)
		and is_equal_approx(solver.detail, menu._detail.value)
		and is_equal_approx(solver.jonswap_gamma, menu._jonswap_gamma.value),
		"a JONSWAP sea-state slider is disconnected")
	_check(is_equal_approx(solver.choppiness, menu._choppiness.value)
		and is_equal_approx(solver.height_gain, menu._height_gain.value)
		and is_equal_approx(solver.crest_bias, menu._crest_bias.value)
		and is_equal_approx(solver.crest_gain, menu._crest_gain.value),
		"a JONSWAP wave slider is disconnected")
	_check(is_equal_approx(solver.whitecap, menu._whitecap.value)
		and is_equal_approx(solver.foam_amount, menu._foam_amount.value)
		and is_equal_approx(solver.foam_persistence, menu._foam_persistence.value)
		and is_equal_approx(demo.spray.amount, menu._spray_amount.value)
		and is_equal_approx(demo.surface_mat.get_shader_parameter("foam_strength"),
			menu._foam_strength.value)
		and is_equal_approx(solver.foam_near_domain, menu._foam_distance.value * 2.0),
		"a JONSWAP foam slider is disconnected")

	demo.apply_preset(1)
	solver.foam_feedback_enabled = false
	solver.sim_time = 12.0
	var previous_hash := await _render_texture_hash(solver, solver._spectrum_tex, 0)
	solver.wind_direction += 0.7
	solver.mark_spectrum_dirty()
	var next_hash := await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Wind direction does not change the JONSWAP spectrum")
	previous_hash = next_hash
	solver.wind_speed += 3.0
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Wind speed does not change the JONSWAP spectrum")
	previous_hash = next_hash
	solver.fetch_km += 80.0
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Fetch does not change the JONSWAP spectrum")
	previous_hash = next_hash
	solver.spread = 1.0
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Spread does not change the JONSWAP spectrum")
	previous_hash = next_hash
	solver.swell = 1.6
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash,
		"Swell is masked when JONSWAP spread is at its maximum")
	previous_hash = await _render_texture_hash(solver, solver._spectrum_tex, 2)
	solver.detail = 0.5
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 2)
	_check(next_hash != previous_hash, "Detail does not change the JONSWAP spectrum")
	previous_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	solver.jonswap_gamma = 5.0
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Peak enhancement does not change the JONSWAP spectrum")
	previous_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	solver.height_gain = 3.0
	solver.mark_spectrum_dirty()
	next_hash = await _render_texture_hash(solver, solver._spectrum_tex, 0)
	_check(next_hash != previous_hash, "Wave height does not change the JONSWAP spectrum")

	demo.apply_preset(1)
	solver.foam_feedback_enabled = false
	solver.sim_time = 12.0
	solver.jonswap_gamma = 3.3
	solver.mark_spectrum_dirty()
	var reference_rms := await _render_height_rms(solver)
	solver.jonswap_gamma = 5.0
	solver.mark_spectrum_dirty()
	var focused_rms := await _render_height_rms(solver)
	var energy_delta := absf(focused_rms - reference_rms) / maxf(reference_rms, 0.0001)
	_check(energy_delta <= 0.10,
		"peak enhancement changed total RMS by %.1f%%" % (energy_delta * 100.0))

	solver.choppiness = 1.1
	previous_hash = await _render_texture_hash(solver, solver.get_displacement_tex_rid(), 0)
	solver.choppiness = 1.8
	next_hash = await _render_texture_hash(solver, solver.get_displacement_tex_rid(), 0)
	_check(next_hash != previous_hash, "Choppiness does not change JONSWAP displacement")
	solver.crest_gain = 0.1
	previous_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	solver.crest_gain = 8.0
	next_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	_check(next_hash != previous_hash, "Crest gain does not change the JONSWAP crest map")
	solver.crest_bias = 0.0
	previous_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	solver.crest_bias = 0.8
	next_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	_check(next_hash != previous_hash, "Crest threshold does not change the JONSWAP crest map")
	solver.whitecap = 0.0
	previous_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	solver.whitecap = 2.0
	next_hash = await _render_texture_hash(solver, solver.get_normal_tex_rid(), 0)
	_check(next_hash != previous_hash, "Whitecap does not change the JONSWAP breaking map")

	solver.wind_speed = 11.0
	solver.fetch_km = 120.0
	solver.amplitude_scale = 1.0
	var breeze_heights: Array[float] = []
	for gain: float in [1.0, 2.0, 3.0]:
		solver.height_gain = gain
		breeze_heights.append(solver._jonswap_significant_height(
			solver.effective_amplitude_scale()) * solver.effective_height_gain())
	_check(breeze_heights[0] < breeze_heights[1]
		and breeze_heights[1] < breeze_heights[2],
		"Wave height stops responding on Breeze")
	solver.wind_speed = 33.0
	solver.fetch_km = 300.0
	solver.amplitude_scale = 0.75
	var storm_heights: Array[float] = []
	for gain: float in [1.0, 2.0, 3.0]:
		solver.height_gain = gain
		storm_heights.append(solver._jonswap_significant_height(
			solver.effective_amplitude_scale()) * solver.effective_height_gain())
	_check(storm_heights[0] < storm_heights[1]
		and storm_heights[1] < storm_heights[2],
		"Wave height stops responding on Storm")
	var chop_values: Array[float] = []
	for chop: float in [1.1, 1.4, 1.8]:
		solver.choppiness = chop
		chop_values.append(solver.effective_choppiness(0))
	_check(chop_values[0] < chop_values[1] and chop_values[1] < chop_values[2],
		"Choppiness stops responding above its safety knee")

	solver.take_render_refresh_request()
	menu._height_gain.value = 2.5
	var frame_before := solver._frame
	for frame in 5:
		await process_frame
		if solver._frame > frame_before:
			break
	_check(solver._frame > frame_before,
		"a JONSWAP slider does not refresh while the ocean is frozen")
	print("JONSWAP SLIDERS breeze=%s storm=%s chop=%s" % [
		breeze_heights, storm_heights, chop_values])
	menu._foam_strength_override = false
	menu._foam_distance_override = false
	demo.set_foam_distance(72.0)
	solver.foam_feedback_enabled = true
	demo.apply_preset(0)


func _render_texture_hash(solver: OceanSolver, texture: RID, layer: int) -> int:
	RenderingServer.call_on_render_thread(solver.step_render.bind(0.0))
	return hash(await _read_texture(texture, layer))


func _render_height_rms(solver: OceanSolver) -> float:
	RenderingServer.call_on_render_thread(solver.step_render.bind(0.0))
	var sum_sq := 0.0
	var count := 0
	for layer in 3:
		var metrics := _height_rms(await _read_texture(solver.get_displacement_tex_rid(), layer))
		sum_sq += metrics.sum_sq
		count += metrics.count
	return sqrt(sum_sq / maxf(float(count), 1.0))


func _check_tall_crests(demo: Node) -> void:
	for preset: int in [2, 3]:
		demo.apply_preset(preset)
		for gain: float in [1.0, 2.0, 3.0]:
			demo.set_capture_height_gain(gain)
			for time: float in [12.0, 20.0]:
				demo.set_capture_time(time)
				RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
				var n: int = demo.solver.map_size
				var field := _rgba_half_values(await _read_texture(demo.solver.get_derivative_tex_rid(), 0), n)
				var normal_values := _rgba_half_values(await _read_texture(demo.solver.get_normal_tex_rid(), 0), n)
				var minimum_stretch := 1.0
				for i in range(0, n * n, 4):
					var a := 1.0 + field[i * 4]
					var b := 1.0 + field[i * 4 + 1]
					var c := field[i * 4 + 2]
					var stretch := 0.5 * (a + b - sqrt((a - b) * (a - b) + 4.0 * c * c))
					minimum_stretch = minf(minimum_stretch, stretch)
					var expected_source := smoothstep(0.0, 0.2, clampf(demo.solver.whitecap, 0.05, 0.95) - stretch)
					_check(absf(normal_values[i * 4 + 3] - expected_source) < 0.005,
						"cascade diagnostic source disagrees with its deformation")
				print("CREST CHECK preset=%d gain=%.0f time=%.0f minimum_stretch=%.4f" % [preset, gain, time, minimum_stretch])
				_check(minimum_stretch > 0.0, "long-wave surface folds at height gain %.0f" % gain)
	demo.apply_preset(0)


func _check_jonswap_extreme_envelope(demo: Node) -> void:
	var solver: OceanSolver = demo.solver
	solver.wind_speed = 35.0
	solver.fetch_km = 1000.0
	solver.swell = 2.0
	solver.spread = 1.0
	solver.detail = 1.0
	solver.choppiness = 1.8
	solver.height_gain = OceanSolver.JONSWAP_MAX_HEIGHT_GAIN
	solver.amplitude_scale = 1.0
	solver.mark_spectrum_dirty()
	var pc := solver._pack_push_constant(0, 0.0, 0.0)
	var fine_pc := solver._pack_push_constant(2, 0.0, 0.0)
	var bounded_height := solver._jonswap_significant_height(
		solver.effective_amplitude_scale()) * solver.effective_height_gain()
	_check(pc.decode_float(44) <= OceanSolver.JONSWAP_CHOPPINESS_LIMIT + 0.0001
		and fine_pc.decode_float(44) <= OceanSolver.JONSWAP_FINE_CHOPPINESS_LIMIT + 0.0001
		and bounded_height <= OceanSolver.JONSWAP_TOTAL_HEIGHT_LIMIT_M + 0.0001,
		"JONSWAP extreme controls bypassed the safety envelope")
	solver.sim_time = 20.0
	RenderingServer.call_on_render_thread(solver.step_render.bind(0.0))
	var metrics := await _state_metrics(demo, false, false, true, false)
	_check(metrics.non_finite == 0, "JONSWAP extreme envelope produced NaN or Inf")
	_check(metrics.long_max_abs <= 32.0 and metrics.height_rms < 8.0,
		"JONSWAP extreme envelope remains mountainous (max %.2f m, RMS %.2f m)"
		% [metrics.long_max_abs, metrics.height_rms])
	for cascade in solver.num_cascades():
		var field := _rgba_half_values(await _read_texture(
			solver.get_derivative_tex_rid(), cascade), solver.map_size)
		var minimum_stretch := 1.0
		for i in range(0, solver.map_size * solver.map_size, 4):
			var a := 1.0 + field[i * 4]
			var b := 1.0 + field[i * 4 + 1]
			var c := field[i * 4 + 2]
			minimum_stretch = minf(minimum_stretch,
				0.5 * (a + b - sqrt((a - b) * (a - b) + 4.0 * c * c)))
		_check(minimum_stretch > 0.0,
			"JONSWAP extreme cascade %d folds (minimum stretch %.4f)"
			% [cascade, minimum_stretch])
	demo.apply_preset(0)


func _constant_foam(solver: OceanSolver, derivative: Color, steps: int) -> Vector2:
	var values: Array[Vector2] = await _constant_foam_layers(solver, derivative, steps, 1.0)
	return values[0] if not values.is_empty() else Vector2.ZERO


func _constant_foam_layers(solver: OceanSolver, derivative: Color,
		steps: int, duration: float, reset: bool = true) -> Array[Vector2]:
	solver.take_render_refresh_request()
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_clear(solver.get_derivative_tex_rid(), Color(0, 0, 0, 0), 0, 1, 0, 3)
		rd.texture_clear(solver.get_derivative_tex_rid(), derivative, 0, 1, 0, 1)
		if reset:
			solver._clear_foam_fields()
			solver._foam_near_read_index = 0
	)
	await RenderingServer.frame_post_draw
	for start in range(0, steps, 4):
		var count := mini(4, steps - start)
		RenderingServer.call_on_render_thread(func():
			var rd := RenderingServer.get_rendering_device()
			var cl := rd.compute_list_begin()
			for step in count:
				for layer in 3:
					var pc := solver._pack_near_push_constant(duration / float(steps), layer)
					for offset in [0, 4, 8, 12, 40]:
						pc.encode_float(offset, 0.0)
					var stage := "foam_near_ab" if solver._foam_near_read_index == 0 else "foam_near_ba"
					if layer > 0:
						stage += "_%d" % layer
					solver._dispatch(cl, stage, pc, solver.foam_near_size / 16, solver.foam_near_size / 16, 1)
				solver._foam_near_read_index = 1 - solver._foam_near_read_index
			rd.compute_list_end()
		)
		await RenderingServer.frame_post_draw
	var values: Array[Vector2] = []
	var rid := solver.get_foam_near_read_tex_rid()
	for layer in 3:
		var data := _foam_base(await _read_texture(rid, layer), solver.foam_near_size)
		if data.is_empty():
			values.append(Vector2.ZERO)
			continue
		var center := (solver.foam_near_size / 2 * solver.foam_near_size + solver.foam_near_size / 2) * 8
		values.append(Vector2(data.decode_float(center), data.decode_float(center + 4)))
	return values


func _foam_base(data: PackedByteArray, size: int) -> PackedByteArray:
	var base_size := size * size * 8
	var expected := 0
	var mip_size := size
	while mip_size > 0:
		expected += mip_size * mip_size * 8
		mip_size /= 2
	if data.size() != expected:
		_check(false, "near foam readback does not contain its complete mip chain")
		return PackedByteArray()
	return data.slice(0, base_size)


func _rgba_half_values(data: PackedByteArray, map_size: int) -> PackedFloat32Array:
	var image := Image.create_from_data(map_size, map_size, false, Image.FORMAT_RGBAH, data)
	image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array()


func _rgba_float_values(data: PackedByteArray, map_size: int) -> PackedFloat32Array:
	var expected := map_size * map_size * 16
	_check(data.size() >= expected, "RGBA32F readback is shorter than expected")
	if data.size() < expected:
		return PackedFloat32Array()
	var image := Image.create_from_data(map_size, map_size, false, Image.FORMAT_RGBAF,
		data.slice(0, expected))
	return image.get_data().to_float32_array()


func _peak_chop_correlation(displacement: PackedByteArray, normal: PackedByteArray) -> float:
	var count := 0
	var sum_chop := 0.0
	var sum_crest := 0.0
	var sum_chop_sq := 0.0
	var sum_crest_sq := 0.0
	var sum_cross := 0.0
	var texels := mini(displacement.size(), normal.size()) / 8
	for i in texels:
		var hx := _half(displacement.decode_u16(i * 8))
		var hz := _half(displacement.decode_u16(i * 8 + 4))
		var crest := _half(normal.decode_u16(i * 8 + 4))
		if not hx.finite or not hz.finite or not crest.finite:
			continue
		var chop := sqrt(hx.value * hx.value + hz.value * hz.value)
		sum_chop += chop
		sum_crest += crest.value
		sum_chop_sq += chop * chop
		sum_crest_sq += crest.value * crest.value
		sum_cross += chop * crest.value
		count += 1
	var denominator := sqrt(maxf(
		(count * sum_chop_sq - sum_chop * sum_chop)
		* (count * sum_crest_sq - sum_crest * sum_crest), 0.0))
	return (count * sum_cross - sum_chop * sum_crest) / denominator \
		if denominator > 1e-6 else 0.0


func _spectrum_band_energy(data: PackedByteArray, n: int, tile_length: float) -> Array[float]:
	var bands: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var values := data.to_float32_array()
	for y in n:
		for x in n:
			var radius := Vector2(float(x) - n * 0.5, float(y) - n * 0.5).length()
			if radius < 1.0:
				continue
			var wavelength := tile_length / radius
			var band := -1
			if wavelength >= 100.0:
				band = 0
			elif wavelength >= 25.0:
				band = 1
			elif wavelength >= 4.0:
				band = 2
			elif wavelength >= 0.5:
				band = 3
			if band < 0:
				continue
			var index := (y * n + x) * 4
			bands[band] += values[index] * values[index] \
				+ values[index + 1] * values[index + 1]
	return bands


func _crosswind_energy(data: PackedByteArray, n: int, wind_angle: float) -> float:
	var values := data.to_float32_array()
	var wind := Vector2(sin(wind_angle), cos(wind_angle)).normalized()
	var total := 0.0
	var crosswind := 0.0
	for y in range(0, n, 4):
		for x in range(0, n, 4):
			var k := Vector2(float(x) - n * 0.5, float(y) - n * 0.5)
			if k.length_squared() < 1.0:
				continue
			var direction := k.normalized()
			var index := (y * n + x) * 4
			var energy := values[index] * values[index] \
				+ values[index + 1] * values[index + 1]
			total += energy
			crosswind += energy * (1.0 - absf(direction.dot(wind)))
	return crosswind / maxf(total, 1e-6)


func _texture_difference_rms(a: PackedByteArray, b: PackedByteArray) -> float:
	if a.size() != b.size() or a.is_empty():
		return INF
	var sum_sq := 0.0
	var count := 0
	for i in range(0, a.size() / 8, 4):
		var av := _half(a.decode_u16(i * 8 + 2))
		var bv := _half(b.decode_u16(i * 8 + 2))
		if not av.finite or not bv.finite:
			return INF
		var difference: float = av.value - bv.value
		sum_sq += difference * difference
		count += 1
	return sqrt(sum_sq / maxf(count, 1))


func _half(bits: int) -> Dictionary:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return {"value": 0.0, "finite": false}
	var sign_value := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return {"value": sign_value * mantissa * pow(2.0, -24), "finite": true}
	return {"value": sign_value * (1.0 + mantissa / 1024.0)
		* pow(2.0, exponent - 15), "finite": true}


func _half_value(bits: int) -> float:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return 0.0
	var sign := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return sign * mantissa * 5.960464477539063e-08
	return sign * (1.0 + mantissa / 1024.0) * pow(2.0, exponent - 15)


func _decode_rgba16f(data: PackedByteArray, map_size: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(map_size * map_size * 4)
	for i in map_size * map_size:
		for c in 4:
			var offset := i * 8 + c * 2
			out[i * 4 + c] = _half(data[offset] | (data[offset + 1] << 8))["value"]
	return out


## Decode an RG32F near-feedback readback into interleaved R,G floats.
func _near_rg(data: PackedByteArray, size: int) -> PackedFloat32Array:
	var base := _foam_base(data, size)
	_check(base.size() == size * size * 8, "combined foam readback must contain RG32F base mip")
	return base.to_float32_array()


func _near_channel_std(data: PackedFloat32Array) -> float:
	var count := 0
	var mean := 0.0
	var sq := 0.0
	for i in range(0, data.size(), 32):
		mean += data[i]
		sq += data[i] * data[i]
		count += 1
	mean /= count
	return sqrt(maxf(sq / count - mean * mean, 0.0))


## RMS and per-column mean error between the near field B and the toroidal
## shift of A by `shift` texels in x. Columns within `shift` of the wrap edge
## have no overlapping world data and are excluded.
func _near_shift_stats(b: PackedFloat32Array, a: PackedFloat32Array, size: int,
		shift: int, stride: int) -> Dictionary:
	var margin := shift + 8
	var sq := 0.0
	var count := 0
	var col_err := PackedFloat32Array()
	col_err.resize(size)
	var col_count := PackedInt32Array()
	col_count.resize(size)
	for y in range(0, size, stride):
		var row := y * size
		for x in range(0, size - margin, stride):
			var d := b[(row + x) * 2] - a[(row + (x + shift) % size) * 2]
			sq += d * d
			count += 1
			col_err[x] += absf(d)
			col_count[x] += 1
	var col_means: Array[float] = []
	for x in size - margin:
		if col_count[x] > 0:
			col_means.append(col_err[x] / col_count[x])
	col_means.sort()
	return {
		"rms": sqrt(sq / maxf(count, 1)),
		"median_col": col_means[col_means.size() / 2],
		"p99_col": col_means[mini(col_means.size() - 1,
			int(col_means.size() * 0.99))],
	}


## Exact GDScript replica of ocean_query.comp for one point: bilinear torus
## samples of the decoded maps, 4-iteration choppy inversion. Returns the
## height, the normalized normal, the raw gradient length; accumulates each
## cascade's sum-of-squares height into contributions[cascade].
func _query_ground_truth(disps: Array[PackedFloat32Array],
		norms: Array[PackedFloat32Array], map_size: int,
		tiles: PackedFloat32Array, point: Vector2,
		contributions: Array[float]) -> Dictionary:
	var g := point
	for iteration in 4:
		var disp := Vector2.ZERO
		for cascade in 3:
			var sd := _sample_map_vec3(disps[cascade], map_size, tiles[cascade], g)
			disp += Vector2(sd.x, sd.z)
		g = point - disp
	var height := 0.0
	var gradient := Vector2.ZERO
	for cascade in 3:
		var s := _sample_map_vec3(disps[cascade], map_size, tiles[cascade], g)
		height += s.y
		contributions[cascade] += s.y * s.y
		gradient += _sample_map_vec2(norms[cascade], map_size, tiles[cascade], g)
	var normal := Vector3(-gradient.x, 1.0, -gradient.y).normalized()
	return {"height": height, "normal": normal, "gradient_len": gradient.length()}


func _sample_map_vec3(texels: PackedFloat32Array, map_size: int, tile: float,
		world: Vector2) -> Vector3:
	var uv := world / tile
	var grid := (uv - uv.floor()) * float(map_size) - Vector2(0.5, 0.5)
	var i0 := Vector2i(grid.floor())
	var t := grid - Vector2(i0)
	var c00 := _texel_vec3(texels, map_size, i0)
	var c10 := _texel_vec3(texels, map_size, i0 + Vector2i(1, 0))
	var c01 := _texel_vec3(texels, map_size, i0 + Vector2i(0, 1))
	var c11 := _texel_vec3(texels, map_size, i0 + Vector2i(1, 1))
	return c00.lerp(c10, t.x).lerp(c01.lerp(c11, t.x), t.y)


func _sample_map_vec4(texels: PackedFloat32Array, map_size: int, tile: float,
		world: Vector2) -> Vector4:
	var uv := world / tile
	var grid := (uv - uv.floor()) * float(map_size) - Vector2(0.5, 0.5)
	var i0 := Vector2i(grid.floor())
	var t := grid - Vector2(i0)
	var c00 := _texel_vec4(texels, map_size, i0)
	var c10 := _texel_vec4(texels, map_size, i0 + Vector2i(1, 0))
	var c01 := _texel_vec4(texels, map_size, i0 + Vector2i(0, 1))
	var c11 := _texel_vec4(texels, map_size, i0 + Vector2i(1, 1))
	return c00.lerp(c10, t.x).lerp(c01.lerp(c11, t.x), t.y)


func _sample_map_vec2(texels: PackedFloat32Array, map_size: int, tile: float,
		world: Vector2) -> Vector2:
	var uv := world / tile
	var grid := (uv - uv.floor()) * float(map_size) - Vector2(0.5, 0.5)
	var i0 := Vector2i(grid.floor())
	var t := grid - Vector2(i0)
	var c00 := _texel_vec2(texels, map_size, i0)
	var c10 := _texel_vec2(texels, map_size, i0 + Vector2i(1, 0))
	var c01 := _texel_vec2(texels, map_size, i0 + Vector2i(0, 1))
	var c11 := _texel_vec2(texels, map_size, i0 + Vector2i(1, 1))
	return c00.lerp(c10, t.x).lerp(c01.lerp(c11, t.x), t.y)


func _texel_vec3(texels: PackedFloat32Array, map_size: int, at: Vector2i) -> Vector3:
	var o := (posmod(at.y, map_size) * map_size + posmod(at.x, map_size)) * 4
	return Vector3(texels[o], texels[o + 1], texels[o + 2])


func _texel_vec4(texels: PackedFloat32Array, map_size: int, at: Vector2i) -> Vector4:
	var o := (posmod(at.y, map_size) * map_size + posmod(at.x, map_size)) * 4
	return Vector4(texels[o], texels[o + 1], texels[o + 2], texels[o + 3])


func _texel_vec2(texels: PackedFloat32Array, map_size: int, at: Vector2i) -> Vector2:
	var o := (posmod(at.y, map_size) * map_size + posmod(at.x, map_size)) * 4
	return Vector2(texels[o], texels[o + 1])


func _read_texture(rid: RID, layer: int) -> PackedByteArray:
	var data: PackedByteArray = await TextureReadback.new().read_layer(rid, layer)
	if data.is_empty():
		_check(false, "ocean texture readback timed out")
	return data


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
