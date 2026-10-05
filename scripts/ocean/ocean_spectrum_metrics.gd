extends RefCounted

const GRAVITY := 9.81
const PI := 3.141592653589793
const TAU := PI * 2.0
const K_SAMPLES := 128
const ANGLE_SAMPLES := 64
const MIN_WAVELENGTH_M := OceanConfig.MIN_WAVELENGTH_M
static var _swell_grid_mutex := Mutex.new()
static var _swell_grid_key := PackedFloat64Array()
static var _swell_grid := {}


static func compute(solver) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var swell_alpha: float = _swell_alpha_scale(solver)
	for cascade in int(solver.num_cascades()):
		result.append(_compute_cascade(solver, cascade, swell_alpha))
	return result


static func unscaled_moments(solver, height_gain: float = 1.0) -> Dictionary:
	var swell_alpha: float = _swell_alpha_scale(solver)
	var total_variance := 0.0
	var wind_variance := 0.0
	var swell_variance := 0.0
	var stokes := Vector2.ZERO
	var slope_variance := 0.0
	var moment_0 := 0.0
	var moment_1 := 0.0
	var moment_2 := 0.0
	var strain_covariance := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for cascade in int(solver.num_cascades()):
		var band: Dictionary = _compute_cascade(solver, cascade, swell_alpha, height_gain, false)
		total_variance += float(band.height_variance_m2)
		wind_variance += float(band.wind_variance_m2)
		swell_variance += float(band.swell_variance_m2)
		stokes += band.stokes_m_s
		slope_variance += float(band.slope_variance)
		moment_0 += float(band.m0)
		moment_1 += float(band.m1)
		moment_2 += float(band.m2)
		var band_covariance: PackedFloat64Array = band.strain_covariance
		for index in 6:
			strain_covariance[index] += band_covariance[index]
	return {
		"height_variance_m2": total_variance,
		"wind_variance_m2": wind_variance,
		"swell_variance_m2": swell_variance,
		"significant_height_m": 4.0 * sqrt(maxf(total_variance, 0.0)),
		"stokes_m_s": stokes,
		"slope_variance": slope_variance,
		"strain_covariance": strain_covariance,
		"m0": moment_0,
		"m1": moment_1,
		"m2": moment_2,
	}


static func compute_unscaled_moments(solver, height_gain: float = 1.0) -> Dictionary:
	return unscaled_moments(solver, height_gain)


static func _swell_alpha_scale(solver) -> float:
	var target_height: float = maxf(float(solver.swell_height_m), 0.0)
	if target_height <= 0.0:
		return 0.0
	var unit_variance: float = _swell_modes(solver).variance
	if unit_variance <= 1.0e-12:
		return 0.0
	return target_height * target_height / (16.0 * unit_variance)


static func compute_swell_alpha_scale(solver) -> float:
	return _swell_alpha_scale(solver)


static func _compute_cascade(solver, cascade: int, swell_alpha: float,
		height_gain: float = -1.0, apply_master_scale: bool = true) -> Dictionary:
	if height_gain < 0.0:
		height_gain = maxf(float(solver.effective_height_gain()), 0.0)
	var wind: Dictionary = _integrate_component(solver, cascade, true,
		height_gain, 1.0, apply_master_scale)
	var swell: Dictionary = _integrate_component(solver, cascade, false,
		height_gain, swell_alpha, apply_master_scale)
	var variance: float = float(wind.variance) + float(swell.variance)
	var slope: float = float(wind.slope) + float(swell.slope)
	var stokes: Vector2 = wind.stokes + swell.stokes
	var strain_covariance := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for index in 6:
		strain_covariance[index] = wind.strain_covariance[index] + swell.strain_covariance[index]
	var wavelength_sum: float = float(wind.wavelength_sum) + float(swell.wavelength_sum)
	var moment_0: float = float(wind.m0) + float(swell.m0)
	var moment_1: float = float(wind.m1) + float(swell.m1)
	var moment_2: float = float(wind.m2) + float(swell.m2)
	return {
		"wavelength_m": wavelength_sum / variance if variance > 1.0e-12 else 0.0,
		"height_rms_m": sqrt(maxf(variance, 0.0)),
		"height_variance_m2": variance,
		"wind_variance_m2": float(wind.variance),
		"swell_variance_m2": float(swell.variance),
		"significant_height_m": 4.0 * sqrt(maxf(variance, 0.0)),
		"slope_variance": maxf(slope, 0.0),
		"stokes_m_s": stokes,
		"strain_covariance": strain_covariance,
		"m0": moment_0,
		"m1": moment_1,
		"m2": moment_2,
	}


static func _integrate_component(solver, cascade: int, is_wind: bool,
		height_gain: float, alpha_scale: float, apply_master_scale: bool) -> Dictionary:
	if not is_wind:
		return _integrate_swell(solver, cascade, height_gain, alpha_scale, apply_master_scale)
	var tile_length: float = float(solver.tile_lengths[cascade])
	var map_size: int = maxi(int(solver.map_size), 8)
	var nyquist: float = PI * float(map_size) / maxf(tile_length, 1.0e-4)
	var k_min: float = TAU / maxf(tile_length, 1.0e-4) \
		if cascade == 0 else _band_max(solver, cascade - 1)
	var k_max: float = minf(_band_max(solver, cascade), TAU / MIN_WAVELENGTH_M)
	if cascade == int(solver.num_cascades()) - 1:
		k_max = minf(sqrt(2.0) * nyquist, TAU / MIN_WAVELENGTH_M)
	k_min = maxf(k_min, TAU / maxf(tile_length, 1.0e-4) if cascade == 0 else 1.0e-5)
	if k_max <= k_min:
		return _empty_component()

	var wind_speed: float = maxf(float(solver.wind_speed), 0.01)
	var fetch_m: float = maxf(float(solver.fetch_km) * 1000.0, 1.0)
	var wind_peak: float = 22.0 * pow(GRAVITY * GRAVITY / (wind_speed * fetch_m), 1.0 / 3.0)
	var wind_alpha: float = 0.076 * pow(wind_speed * wind_speed / (fetch_m * GRAVITY), 0.22)
	var amplitude_scale: float = float(solver.effective_amplitude_scale()) \
		if apply_master_scale else 1.0
	var master_scale: float = pow(maxf(amplitude_scale, 0.0), 2.0) \
		if apply_master_scale else 1.0
	wind_alpha *= master_scale
	var depth: float = maxf(float(solver.water_depth), 0.0)
	var gamma: float = clampf(float(solver.jonswap_gamma), 1.0, 7.0)
	var wind_legacy_swell: float = float(solver.swell)
	var spread: float = float(solver.spread)
	var detail: float = float(solver.detail)
	var wind_direction: float = float(solver.wind_direction)
	var log_step: float = log(k_max / k_min) / float(K_SAMPLES)
	var angle_step: float = TAU / float(ANGLE_SAMPLES)
	var variance := 0.0
	var wavelength_sum := 0.0
	var slope_variance := 0.0
	var stokes := Vector2.ZERO
	var moment_0 := 0.0
	var moment_1 := 0.0
	var moment_2 := 0.0
	var strain_covariance := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var choppiness: float = maxf(float(solver.effective_choppiness(cascade)), 0.0)
	for radial_index in K_SAMPLES:
		var k: float = exp(log(k_min) + (float(radial_index) + 0.5) * log_step)
		var radial_width: float = k * log_step
		for angle_index in ANGLE_SAMPLES:
			var theta: float = (float(angle_index) + 0.5) * angle_step
			var kx: float = k * sin(theta)
			var kz: float = k * cos(theta)
			if absf(kx) > nyquist or absf(kz) > nyquist:
				continue
			var dispersion: Vector2 = _dispersion_and_derivative(k, depth)
			var density := _wind_density(k, theta, dispersion.x, wind_peak, wind_speed,
				wind_legacy_swell, spread, detail, wind_direction, wind_alpha, depth, gamma)
			var gain: float = 1.0 + (height_gain - 1.0) * exp(-k * 9.549)
			var energy: float = density * dispersion.y * radial_width * angle_step \
				* maxf(gain * gain, 0.0)
			var long_weight: float = exp(-k * 9.549)
			var raw_energy: float = density * dispersion.y * radial_width * angle_step
			var horizontal_gain: float = 1.0 / lerpf(1.0,
				maxf(amplitude_scale * gain, 1.0), long_weight)
			var strain_weight: float = energy * k * k * choppiness * choppiness \
				* horizontal_gain * horizontal_gain
			var xx: float = cos(theta) * cos(theta)
			var zz: float = sin(theta) * sin(theta)
			var xz: float = sin(theta) * cos(theta)
			variance += energy
			moment_0 += raw_energy
			moment_1 += raw_energy * long_weight
			moment_2 += raw_energy * long_weight * long_weight
			wavelength_sum += energy * TAU / k
			slope_variance += energy * k * k
			var exp_depth: float = exp(-2.0 * k * depth)
			var finite_depth_stokes: float = 1.0 + 2.0 * exp_depth \
				/ pow(maxf(1.0 - exp_depth, 1.0e-6), 2.0)
			stokes += Vector2(cos(theta), sin(theta)) \
				* (2.0 * dispersion.x * k * energy * finite_depth_stokes)
			strain_covariance[0] += strain_weight * xx * xx
			strain_covariance[1] += strain_weight * zz * zz
			strain_covariance[2] += strain_weight * xz * xz
			strain_covariance[3] += strain_weight * xx * zz
			strain_covariance[4] += strain_weight * xx * xz
			strain_covariance[5] += strain_weight * zz * xz
	return {
		"variance": variance,
		"slope": slope_variance,
		"stokes": stokes,
		"wavelength_sum": wavelength_sum,
		"strain_covariance": strain_covariance,
		"m0": moment_0,
		"m1": moment_1,
		"m2": moment_2,
	}


static func _swell_modes(solver) -> Dictionary:
	var key := PackedFloat64Array([solver.map_size, solver.water_depth,
		solver.effective_swell_period(), solver.swell_direction_rad, solver.swell_spread,
		solver.jonswap_gamma, solver.num_cascades()])
	for tile in solver.tile_lengths:
		key.append(tile)
	_swell_grid_mutex.lock()
	if key != _swell_grid_key:
		_swell_grid = _build_swell_grid(key)
		_swell_grid_key = key
	var result := _swell_grid
	_swell_grid_mutex.unlock()
	return result


static func _build_swell_grid(key: PackedFloat64Array) -> Dictionary:
	var n := int(key[0])
	var depth := maxf(key[1], 0.01)
	var peak := TAU / maxf(key[2], 0.1)
	var direction := key[3]
	var spread := clampf(key[4], 0.001, PI)
	var gamma := clampf(key[5], 1.0, 7.0)
	var count := int(key[6])
	var bands: Array[PackedFloat64Array] = []
	var variance := 0.0
	for cascade in count:
		var tile := key[7 + cascade]
		var dk := TAU / tile
		var k_min := dk if cascade == 0 else TAU / tile * 6.0
		var k_max := minf(TAU / MIN_WAVELENGTH_M,
			TAU / key[8 + cascade] * 6.0) if cascade < count - 1 else TAU / MIN_WAVELENGTH_M
		var radius := mini(ceili(k_max / dk), n / 2)
		var modes := PackedFloat64Array()
		for y in range(-radius, mini(radius, n / 2 - 1) + 1):
			for x in range(-radius, mini(radius, n / 2 - 1) + 1):
				var k := Vector2(x, y).length() * dk + 1e-6
				if k < k_min or k >= k_max:
					continue
				var theta := atan2(float(x), float(y))
				var dispersion := _dispersion_and_derivative(k, depth)
				var energy := _swell_density(k, theta, dispersion.x, peak,
					direction, spread, 1.0, depth, gamma) * dispersion.y / k * dk * dk
				if energy <= 0.0:
					continue
				var exp_depth := exp(-2.0 * k * depth)
				var stokes := 2.0 * dispersion.x * k * (1.0 + 2.0 * exp_depth
					/ pow(maxf(1.0 - exp_depth, 1e-6), 2.0))
				modes.append_array(PackedFloat64Array([k, exp(-k * 9.549),
					cos(theta), sin(theta), energy, stokes]))
				variance += energy
		bands.append(modes)
	return {"bands": bands, "variance": variance}


static func _integrate_swell(solver, cascade: int, height_gain: float,
		alpha_scale: float, apply_master_scale: bool) -> Dictionary:
	if alpha_scale <= 0.0:
		return _empty_component()
	var modes: PackedFloat64Array = _swell_modes(solver).bands[cascade]
	var amplitude: float = solver.effective_amplitude_scale() if apply_master_scale else 1.0
	var alpha := alpha_scale * amplitude * amplitude
	var chop: float = solver.effective_choppiness(cascade)
	var variance := 0.0
	var slope := 0.0
	var stokes := Vector2.ZERO
	var wavelength_sum := 0.0
	var moment_0 := 0.0
	var moment_1 := 0.0
	var moment_2 := 0.0
	var covariance := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for offset in range(0, modes.size(), 6):
		var k := modes[offset]
		var long_weight := modes[offset + 1]
		var direction := Vector2(modes[offset + 2], modes[offset + 3])
		var raw := modes[offset + 4] * alpha
		var gain := 1.0 + (height_gain - 1.0) * long_weight
		var energy := raw * gain * gain
		var horizontal_gain := 1.0 / lerpf(1.0, maxf(amplitude * gain, 1.0), long_weight)
		var strain := energy * k * k * chop * chop * horizontal_gain * horizontal_gain
		var xx := direction.x * direction.x
		var zz := direction.y * direction.y
		var xz := direction.x * direction.y
		variance += energy
		slope += energy * k * k
		stokes += direction * (modes[offset + 5] * energy)
		wavelength_sum += energy * TAU / k
		moment_0 += raw
		moment_1 += raw * long_weight
		moment_2 += raw * long_weight * long_weight
		covariance[0] += strain * xx * xx
		covariance[1] += strain * zz * zz
		covariance[2] += strain * xz * xz
		covariance[3] += strain * xx * zz
		covariance[4] += strain * xx * xz
		covariance[5] += strain * zz * xz
	return {"variance": variance, "slope": slope, "stokes": stokes,
		"wavelength_sum": wavelength_sum, "strain_covariance": covariance,
		"m0": moment_0, "m1": moment_1, "m2": moment_2}


static func _empty_component() -> Dictionary:
	return {"variance": 0.0, "slope": 0.0, "stokes": Vector2.ZERO,
		"wavelength_sum": 0.0, "m0": 0.0, "m1": 0.0, "m2": 0.0,
		"strain_covariance": PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])}


static func _band_max(solver, cascade: int) -> float:
	if cascade >= int(solver.num_cascades()) - 1:
		return TAU / MIN_WAVELENGTH_M
	return TAU / maxf(float(solver.tile_lengths[cascade + 1]), 1.0e-4) * 6.0


static func _dispersion_and_derivative(k: float, depth: float) -> Vector2:
	var a: float = k * depth
	var b: float = tanh(a)
	var omega: float = sqrt(GRAVITY * k * b)
	var derivative: float = 0.5 * GRAVITY \
		* (b + a * (1.0 - b * b)) / maxf(omega, 1.0e-8)
	return Vector2(omega, derivative)


static func _wind_density(k: float, theta: float, omega: float, peak_frequency: float,
		wind_speed: float, swell: float, spread: float, detail: float,
		wind_direction: float, alpha: float, depth: float, gamma: float) -> float:
	var spectrum: float = _tma_spectrum(omega, peak_frequency, alpha, depth, gamma)
	var directional: float = _hasselmann_directional_spread(
		omega, peak_frequency, wind_speed, swell, theta - wind_direction)
	var direction: float = lerpf(0.5 / PI, directional, 1.0 - spread * 0.9)
	var detail_factor: float = exp(-(1.0 - detail) * (1.0 - detail) * k * k)
	return spectrum * direction * detail_factor


static func _swell_density(k: float, theta: float, omega: float, peak_frequency: float,
		direction: float, spread: float, alpha: float, depth: float, gamma: float) -> float:
	var spectrum: float = _tma_spectrum(omega, peak_frequency, alpha, depth, gamma)
	var spread_power: float = 1.0 / maxf(spread * spread, 1.0e-6)
	return spectrum * _longuet_higgins_function(spread_power, theta - direction)


static func _longuet_higgins_normalization(spread_power: float) -> float:
	var root: float = sqrt(maxf(spread_power, 1.0e-12))
	if spread_power < 0.4:
		return 0.5 / PI + spread_power \
			* (0.220636 + spread_power * (-0.109 + spread_power * 0.090))
	return (root * 0.5 + (1.0 / root) * 0.0625) / sqrt(PI)


static func _longuet_higgins_function(spread_power: float, theta: float) -> float:
	return _longuet_higgins_normalization(spread_power) \
		* pow(absf(cos(theta * 0.5)), 2.0 * spread_power)


static func _hasselmann_directional_spread(omega: float, peak_frequency: float,
		wind_speed: float, swell: float, theta: float) -> float:
	var ratio: float = omega / maxf(peak_frequency, 1.0e-8)
	var spread_power: float = 6.97 * pow(absf(ratio), 4.06) \
		if omega <= peak_frequency else 9.77 * pow(absf(ratio), \
		-2.33 - 1.45 * (wind_speed * peak_frequency / GRAVITY - 1.17))
	var swell_power: float = 16.0 * tanh(peak_frequency / maxf(omega, 1.0e-8)) \
		* swell * swell
	return _longuet_higgins_function(spread_power + swell_power, theta)


static func _tma_spectrum(omega: float, peak_frequency: float, alpha: float,
		depth: float, gamma: float) -> float:
	var sigma: float = 0.07 if omega <= peak_frequency else 0.09
	var peak_delta: float = omega - peak_frequency
	var r: float = exp(-peak_delta * peak_delta \
		/ (2.0 * sigma * sigma * peak_frequency * peak_frequency))
	var reference_gamma: float = 3.3
	var peak_normalization: float = (
		0.06533 * pow(reference_gamma, 0.8015) + 0.13467) \
		/ (0.06533 * pow(gamma, 0.8015) + 0.13467)
	var safe_omega: float = maxf(omega, 1.0e-8)
	var jonswap: float = alpha * GRAVITY * GRAVITY / pow(safe_omega, 5.0) \
		* exp(-1.25 * pow(peak_frequency / safe_omega, 4.0)) \
		* pow(gamma, r) * peak_normalization
	var w_h: float = minf(omega * sqrt(depth / GRAVITY), 2.0)
	var depth_attenuation: float = 0.5 * w_h * w_h \
		if w_h <= 1.0 else 1.0 - 0.5 * (2.0 - w_h) * (2.0 - w_h)
	return jonswap * depth_attenuation
