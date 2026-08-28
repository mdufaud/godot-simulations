extends "res://tests/test_case.gd"

const LOOP_PERIOD := 200.0
const PRESETS := [0, 1, 2, 3]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
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

	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
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
		_check(state.active_band_count >= 2,
			"spectrum collapsed into one dominant artificial band")
		_check(state.crest_mean >= 0.0 and state.crest_mean < 0.16,
			"crest ridge is too broad or outside normalized range")
	_check(states[0].height_rms < states[1].height_rms
		and states[1].height_rms < states[2].height_rms
		and states[2].height_rms < states[3].height_rms,
		"wave height is not monotonic from Calm to Storm")
	_check(states[0].slope_rms < states[1].slope_rms
		and states[1].slope_rms < states[2].slope_rms
		and states[2].slope_rms < states[3].slope_rms,
		"wave slope is not monotonic from Calm to Storm")
	_check(states[0].crest_mean < states[1].crest_mean
		and states[1].crest_mean < states[2].crest_mean
		and states[2].crest_mean < states[3].crest_mean,
		"crest compression is not monotonic from Calm to Storm")
	_check(states[0].foam_mean < 0.0001 and states[0].fresh_mean < 0.0001,
		"Calm produced open-water foam")
	_check(states[0].breaking_coverage < 0.01
		and states[1].breaking_coverage <= states[2].breaking_coverage
		and states[2].breaking_coverage <= states[3].breaking_coverage
		and states[3].breaking_coverage < 0.25,
		"breaking coverage does not progress from Calm to Storm")
	var swell_state: Dictionary = states[2]
	var storm_state: Dictionary = states[3]
	_check(swell_state.dominant_wavelength_m >= 100.0
		and swell_state.dominant_wavelength_m <= 140.0,
		"Swell dominant wavelength is %.1f m, expected 100..140 m"
		% swell_state.dominant_wavelength_m)
	_check(storm_state.dominant_wavelength_m >= 120.0
		and storm_state.dominant_wavelength_m <= 170.0,
		"Storm dominant wavelength is %.1f m, expected 120..170 m"
		% storm_state.dominant_wavelength_m)
	_check(swell_state.groupiness > 0.30 and storm_state.groupiness > 0.25,
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
	_check(settled_storm.primary_crest_coverage >= 0.08
		and settled_storm.primary_crest_coverage <= 0.22,
		"Storm crest coverage is outside 8..22%% (%.1f%%)"
		% (settled_storm.primary_crest_coverage * 100.0))
	_check(settled_storm.primary_breaking_coverage >= 0.03
		and settled_storm.primary_breaking_coverage <= 0.12,
		"Storm breaking coverage is outside 3..12%% (%.1f%%)"
		% (settled_storm.primary_breaking_coverage * 100.0))
	_check(settled_storm.foam_coverage_by_layer[0] < 0.0001,
		"long-wave cascade still generates visible foam (%.3f%%)"
		% (settled_storm.foam_coverage_by_layer[0] * 100.0))
	_check(settled_storm.foam_coverage_by_layer[1] > 0.001
		and settled_storm.foam_coverage_by_layer[1] < 0.35,
		"mid-wave ribbon foam is absent or saturated (%.1f%%)"
		% (settled_storm.foam_coverage_by_layer[1] * 100.0))
	_check(settled_storm.fresh_coverage_by_layer[1] > 0.001,
		"mid-wave fresh foam is absent")
	_check(settled_storm.foam_coverage < 0.40,
		"storm foam history saturated %.1f%% of the long-wave tile"
		% (settled_storm.foam_coverage * 100.0))
	_check(settled_storm.fresh_breaking_overlap >= 0.8,
		"fresh foam is outside the two-texel breaking band (%.1f%% overlap)"
		% (settled_storm.fresh_breaking_overlap * 100.0))
	_check(settled_storm.fresh_breaking_false_positive <= 0.20,
		"fresh foam false positives exceed 20%% (%.1f%%)"
		% (settled_storm.fresh_breaking_false_positive * 100.0))
	var primary_shape: Dictionary = settled_storm.primary_shape
	_check(primary_shape.breaking_count > 0
		and primary_shape.breaking_height_mean > primary_shape.quiet_height_mean
		and primary_shape.breaking_slope_mean > primary_shape.quiet_slope_mean
		and primary_shape.breaking_curvature_mean > primary_shape.quiet_curvature_mean
		and primary_shape.breaking_crest_mean > primary_shape.quiet_crest_mean,
		"Jacobian breaking lost height, slope, curvature or crest coherence")
	for seam_ratio in settled_storm.seam_ratios:
		_check(seam_ratio < 2.5,
			"cascade seam differs from local wave continuity (ratio %.3f)" % seam_ratio)
	var persistent_ribbon: Dictionary = settled_storm.persistent_ribbon
	var fresh_ribbon: Dictionary = settled_storm.fresh_ribbon
	_check(persistent_ribbon.component_count > 0 and fresh_ribbon.component_count > 0,
		"storm foam has no measurable ribbon components")
	_check(persistent_ribbon.mean_width > 0.0
		and persistent_ribbon.p95_width >= persistent_ribbon.mean_width
		and fresh_ribbon.mean_width > 0.0
		and fresh_ribbon.p95_width >= fresh_ribbon.mean_width,
		"foam ribbon width metrics are invalid")
	_check(persistent_ribbon.small_pixel_fraction <= 0.10
		and fresh_ribbon.small_pixel_fraction <= 0.10,
		"small isolated foam components exceed 10%% of foam pixels")
	_check(settled_storm.fresh_persistent_iou < 0.90,
		"fresh and persistent foam have indistinguishable morphology")
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

	var loop_start: float = demo._sim_time
	var at_start := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	demo.solver.mark_spectrum_dirty()
	await _frames(8)
	var regenerated := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(at_start == regenerated, "fixed seeds are not deterministic")
	demo._sim_time = loop_start + LOOP_PERIOD
	demo.solver.sim_time = loop_start + LOOP_PERIOD
	await _frames(8)
	var looped := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	var loop_error := _texture_difference_rms(at_start, looped)
	_check(loop_error < 0.001, "ocean 200-second loop RMS error is %f" % loop_error)

	demo.set_backend(OceanSolver.Backend.JONSWAP_TMA)
	demo._sim_time = 37.0
	demo.solver.sim_time = 37.0
	await _frames(12)
	var jonswap := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(_height_rms(jonswap).rms > 0.001, "JONSWAP backend lost all energy")
	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	await _frames(12)
	demo.set_backend(OceanSolver.Backend.JONSWAP_TMA)
	demo._sim_time = 37.0
	demo.solver.sim_time = 37.0
	await _frames(12)
	var jonswap_restored := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(jonswap == jonswap_restored,
		"JONSWAP/TMA changed after Sea of Thieves backend switch")
	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	demo.set_map_size(256)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.initialized and demo.texture_bound and demo.solver.map_size == 256,
		"256 performance mode did not reinitialize")
	demo.set_frozen(false)
	await _frames(24)
	demo.set_frozen(true)
	var reduced_map := await _state_metrics(demo, false, false, false, false, true)
	for seam_ratio in reduced_map.seam_ratios:
		_check(seam_ratio < 2.5,
			"reduced-map cascade seam differs from local continuity (ratio %.3f)" % seam_ratio)

	demo.queue_free()
	await process_frame
	_finish("ocean_fft")


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
	var fresh_breaking_overlap := 0
	var fresh_breaking_outside := 0
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
			var foam := await _read_texture(demo.solver.get_foam_read_tex_rid(layer), layer)
			var foam_metrics := _foam_metrics(foam)
			var foam_overlap: Dictionary = {"fresh_active": 0, "overlap": 0, "outside": 0}
			if layer == 1:
				var mid_normal := await _read_texture(demo.solver.get_normal_tex_rid(), 1)
				foam_overlap = _fresh_breaking_overlap(mid_normal, foam)
				if include_topology:
					var foam_morphology := _foam_morphology(foam)
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
			fresh_active += foam_overlap.fresh_active
			fresh_breaking_overlap += foam_overlap.overlap
			fresh_breaking_outside += foam_overlap.outside
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
		float(primary_foam_active) / maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
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
			/ maxf(float(demo.solver.map_size * demo.solver.map_size), 1.0),
		"foam_coverage_by_layer": foam_coverage_by_layer,
		"fresh_coverage_by_layer": fresh_coverage_by_layer,
		"primary_crest_asymmetry": primary_crest_asymmetry,
		"fresh_breaking_overlap": float(fresh_breaking_overlap)
			/ maxf(float(fresh_active), 1.0),
		"fresh_breaking_false_positive": float(fresh_breaking_outside)
			/ maxf(float(fresh_active), 1.0),
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
			if wavelength < 30.0 or wavelength > 220.0:
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
		if crest.value > 0.15:
			crest_active += 1
		if breaking.value > 0.15:
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
		if foam.value > 0.02:
			active += 1
		if fresh.value > 0.005:
			fresh_active += 1
		count += 1
	return {"sum": sum, "fresh_sum": fresh_sum, "active": active,
		"fresh_active": fresh_active,
		"count": count, "non_finite": non_finite}


func _fresh_breaking_overlap(normal: PackedByteArray, foam: PackedByteArray) -> Dictionary:
	var texels := mini(normal.size() / 8, foam.size() / 4)
	var map_size := int(sqrt(float(texels)))
	var breaking_band := PackedByteArray()
	breaking_band.resize(texels)
	for y in map_size:
		for x in map_size:
			var breaking := _half(normal.decode_u16((y * map_size + x) * 8 + 6))
			if not breaking.finite or breaking.value <= 0.035:
				continue
			for offset_y in range(-2, 3):
				for offset_x in range(-2, 3):
					var sample_x := (x + offset_x + map_size) % map_size
					var sample_y := (y + offset_y + map_size) % map_size
					breaking_band[sample_y * map_size + sample_x] = 1
	var fresh_active := 0
	var overlap := 0
	for i in texels:
		var fresh := _half(foam.decode_u16(i * 4 + 2))
		if not fresh.finite or fresh.value <= 0.005:
			continue
		fresh_active += 1
		if breaking_band[i] != 0:
			overlap += 1
	return {"fresh_active": fresh_active, "overlap": overlap, "outside": fresh_active - overlap}


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


func _foam_morphology(data: PackedByteArray) -> Dictionary:
	var map_size := int(sqrt(data.size() / 4.0))
	const STEP := 4
	var sampled_size := map_size / STEP
	var persistent := PackedByteArray()
	var fresh := PackedByteArray()
	persistent.resize(sampled_size * sampled_size)
	fresh.resize(sampled_size * sampled_size)
	var intersection := 0
	var union := 0
	for y in sampled_size:
		for x in sampled_size:
			var texel := y * sampled_size + x
			var source_texel := (y * STEP * map_size + x * STEP)
			var foam := _half(data.decode_u16(source_texel * 4))
			var fresh_foam := _half(data.decode_u16(source_texel * 4 + 2))
			persistent[texel] = int(foam.finite and foam.value > 0.02)
			fresh[texel] = int(fresh_foam.finite and fresh_foam.value > 0.005)
			if persistent[texel] != 0 and fresh[texel] != 0:
				intersection += 1
			if persistent[texel] != 0 or fresh[texel] != 0:
				union += 1
	return {
		"persistent": _ribbon_metrics(persistent, sampled_size, STEP),
		"fresh": _ribbon_metrics(fresh, sampled_size, STEP),
		"iou": float(intersection) / maxf(float(union), 1.0),
	}


func _ribbon_metrics(mask: PackedByteArray, map_size: int, sample_step: int) -> Dictionary:
	var active_pixels := 0
	var isolated_pixels := 0
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
			if run_length >= 2:
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
	widths.sort()
	var mean_width := 0.0
	for width in widths:
		mean_width += width
	mean_width /= maxf(float(widths.size()), 1.0)
	var p95_index := int(ceil(float(widths.size()) * 0.95)) - 1
	var p95_width := 0.0 if widths.is_empty() else widths[maxi(p95_index, 0)]
	return {
		"component_count": widths.size(),
		"mean_width": mean_width,
		"p95_width": p95_width,
		"small_pixel_fraction": float(isolated_pixels) / maxf(float(active_pixels), 1.0),
	}


func _rgba_half_values(data: PackedByteArray, map_size: int) -> PackedFloat32Array:
	var image := Image.create_from_data(map_size, map_size, false, Image.FORMAT_RGBAH, data)
	image.convert(Image.FORMAT_RGBAF)
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


func _read_texture(rid: RID, layer: int) -> PackedByteArray:
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store_readback", state, data)
		)
	)
	for frame in 360:
		await process_frame
		if state.done:
			return state.data
	_check(false, "ocean texture readback timed out")
	return PackedByteArray()


func _store_readback(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
