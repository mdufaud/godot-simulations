extends RefCounted

const GRAVITY := 9.81
const PI := 3.141592653589793
const TAU := PI * 2.0
const K_SAMPLES := 128
const ANGLE_SAMPLES := 32
const HEIGHT_VARIANCE_SCALE := 0.5


static func compute(solver) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var cascade_count: int = int(solver.num_cascades())
	for cascade in cascade_count:
		result.append(_compute_cascade(solver, cascade))
	return result


static func _compute_cascade(solver, cascade: int) -> Dictionary:
	var tile_length: float = float(solver.tile_lengths[cascade])
	var map_size: int = maxi(int(solver.map_size), 8)
	var nyquist: float = PI * float(map_size) / maxf(tile_length, 1.0e-4)
	var k_min: float = 1.0e-4 if cascade == 0 else _band_max(solver, cascade - 1)
	var k_max: float = _band_max(solver, cascade)
	if cascade == int(solver.num_cascades()) - 1:
		k_max = sqrt(2.0) * nyquist
	k_min = maxf(k_min, 1.0e-5)
	if k_max <= k_min:
		return {"wavelength_m": 0.0, "height_rms_m": 0.0, "slope_variance": 0.0}

	var wind_speed: float = maxf(float(solver.wind_speed), 0.01)
	var fetch_m: float = maxf(float(solver.fetch_km) * 1000.0, 1.0)
	var peak_frequency: float = 22.0 * pow(GRAVITY * GRAVITY / (wind_speed * fetch_m), 1.0 / 3.0)
	var alpha: float = 0.076 * pow(wind_speed * wind_speed / (fetch_m * GRAVITY), 0.22)
	var amplitude_scale: float = maxf(float(solver.effective_amplitude_scale()), 0.0)
	alpha *= pow(amplitude_scale / 0.25, 2.0)
	var depth: float = maxf(float(solver.water_depth), 0.0)
	var gamma: float = clampf(float(solver.jonswap_gamma), 1.0, 7.0)
	var swell: float = float(solver.swell)
	var spread: float = float(solver.spread)
	var detail: float = float(solver.detail)
	var wind_direction: float = float(solver.wind_direction)
	var height_gain: float = maxf(float(solver.effective_height_gain()), 0.0)
	var log_step: float = log(k_max / k_min) / float(K_SAMPLES)
	var angle_step: float = TAU / float(ANGLE_SAMPLES)
	var energy_sum := 0.0
	var wavelength_sum := 0.0
	var slope_variance := 0.0

	for radial_index in K_SAMPLES:
		var log_k: float = log(k_min) + (float(radial_index) + 0.5) * log_step
		var k: float = exp(log_k)
		var radial_width: float = k * log_step
		for angle_index in ANGLE_SAMPLES:
			var theta: float = (float(angle_index) + 0.5) * angle_step
			var kx: float = k * sin(theta)
			var ky: float = k * cos(theta)
			if absf(kx) > nyquist or absf(ky) > nyquist:
				continue
			var density: float = _directional_density(
				k, theta, peak_frequency, wind_speed, swell, spread, detail,
				wind_direction, alpha, depth, gamma)
			var dispersion: Vector2 = _dispersion_and_derivative(k, depth)
			var weighted_energy: float = density * dispersion.y * radial_width * angle_step
			var gain: float = 1.0 + (height_gain - 1.0) \
				* exp(-k * 9.549)
			weighted_energy *= maxf(gain * gain, 0.0) * 0.0625
			energy_sum += weighted_energy
			wavelength_sum += weighted_energy * TAU / k
			slope_variance += weighted_energy * k * k

	var height_variance: float = maxf(energy_sum * HEIGHT_VARIANCE_SCALE, 0.0)
	return {
		"wavelength_m": wavelength_sum / energy_sum if energy_sum > 1.0e-12 else 0.0,
		"height_rms_m": sqrt(height_variance),
		"slope_variance": maxf(slope_variance * HEIGHT_VARIANCE_SCALE, 0.0),
	}


static func _band_max(solver, cascade: int) -> float:
	if cascade >= int(solver.num_cascades()) - 1:
		return 1.0e9
	return TAU / maxf(float(solver.tile_lengths[cascade + 1]), 1.0e-4) * 6.0


static func _dispersion_and_derivative(k: float, depth: float) -> Vector2:
	var a: float = k * depth
	var b: float = tanh(a)
	var omega: float = sqrt(GRAVITY * k * b)
	var derivative: float = 0.5 * GRAVITY \
		* (b + a * (1.0 - b * b)) / maxf(omega, 1.0e-8)
	return Vector2(omega, derivative)


static func _directional_density(k: float, theta: float, peak_frequency: float,
		wind_speed: float, swell: float, spread: float, detail: float,
		wind_direction: float, alpha: float, depth: float, gamma: float) -> float:
	var dispersion: Vector2 = _dispersion_and_derivative(k, depth)
	var spectrum: float = _tma_spectrum(dispersion.x, peak_frequency, alpha,
		depth, gamma)
	var directional: float = _hasselmann_directional_spread(
		dispersion.x, peak_frequency, wind_speed, swell, theta - wind_direction)
	var direction: float = lerpf(0.5 / PI, directional, 1.0 - spread * 0.9)
	var detail_factor: float = exp(-(1.0 - detail) * (1.0 - detail) \
		* k * k)
	return spectrum * direction * detail_factor


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
