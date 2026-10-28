class_name MixwellMath
extends RefCounted

const SERIES_DELTA := 0.002
const SERIES_NEAR := 0.8220844420096408
const SERIES_FAR := 6.50416858646776
const POINT_EPSILON := 1.0e-30


static func point(x: float, y: float) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	result.resize(2)
	result[0] = x
	result[1] = y
	return result


static func zero_point() -> PackedFloat64Array:
	return point(0.0, 0.0)


static func copy_point(value: PackedFloat64Array) -> PackedFloat64Array:
	if value.size() != 2:
		return PackedFloat64Array()
	return point(value[0], value[1])


static func add_point(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != 2 or b.size() != 2:
		return PackedFloat64Array()
	return point(a[0] + b[0], a[1] + b[1])


static func subtract_point(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != 2 or b.size() != 2:
		return PackedFloat64Array()
	return point(a[0] - b[0], a[1] - b[1])


static func scale_point(value: PackedFloat64Array, scale: float) -> PackedFloat64Array:
	if value.size() != 2:
		return PackedFloat64Array()
	return point(value[0] * scale, value[1] * scale)


static func dot_point(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	if a.size() != 2 or b.size() != 2:
		return NAN
	return a[0] * b[0] + a[1] * b[1]


static func length_point(value: PackedFloat64Array) -> float:
	if value.size() != 2:
		return NAN
	return sqrt(dot_point(value, value))


static func normalized_point(value: PackedFloat64Array) -> PackedFloat64Array:
	var length := length_point(value)
	if not is_finite(length) or length <= POINT_EPSILON:
		return zero_point()
	return scale_point(value, 1.0 / length)


static func kernel_mul(relative: PackedFloat64Array, displacement: PackedFloat64Array,
		epsilon: float) -> PackedFloat64Array:
	if relative.size() != 2 or displacement.size() != 2 or not is_finite(epsilon) \
			or epsilon <= 0.0:
		return PackedFloat64Array()
	var radius_squared := dot_point(relative, relative)
	if radius_squared <= POINT_EPSILON:
		return copy_point(displacement)
	var radius := sqrt(radius_squared)
	var epsilon_squared := epsilon * epsilon
	var radius_epsilon := sqrt(radius_squared + epsilon_squared)
	var radius_epsilon_cubed := radius_epsilon * radius_epsilon * radius_epsilon
	var a := 1.0 - radius * (radius_squared + 2.0 * epsilon_squared) / radius_epsilon_cubed
	var b := epsilon_squared / (radius * radius_epsilon_cubed)
	var radial_projection := dot_point(relative, displacement)
	return point(
		a * displacement[0] + b * relative[0] * radial_projection,
		a * displacement[1] + b * relative[1] * radial_projection)


static func body_kernel_mul(relative: PackedFloat64Array, displacement: PackedFloat64Array,
		epsilon: float) -> PackedFloat64Array:
	var world_value := kernel_mul(relative, displacement, epsilon)
	if world_value.size() != 2:
		return PackedFloat64Array()
	return point(world_value[0] - displacement[0], world_value[1] - displacement[1])


static func xi_series(eta: float) -> float:
	if not is_finite(eta):
		return NAN
	var y := sqrt(eta * eta + SERIES_DELTA * SERIES_DELTA)
	var value: float
	if y < SERIES_NEAR:
		var y2 := y * y
		var y4 := y2 * y2
		var y6 := y4 * y2
		var y8 := y4 * y4
		value = -0.039720771 - 0.16369764 * y2 + 0.0076619254 * y4 \
				- 0.00096477622 * y6 + 0.00015811568 * y8
		value += (0.5 + 0.09375 * y2 - 0.0073242188 * y4 \
				+ 0.0010681152 * y6 - 0.00018775463 * y8) * log(y)
	elif y <= SERIES_FAR:
		var g := y - 2.3
		var numerator := -0.0413839 - 0.0937878 * g - 0.043355 * g * g \
				- 0.0068946 * g * g * g + 1.77539e-6 * pow(g, 4.0) \
				- 1.01973e-7 * pow(g, 5.0)
		var denominator := 1.0 + 3.26035 * g + 3.66495 * g * g \
				+ 2.08615 * pow(g, 3.0) + 0.665761 * pow(g, 4.0) \
				+ 0.115772 * pow(g, 5.0) + 0.00875686 * pow(g, 6.0)
		value = numerator / denominator
	else:
		value = -PI / 256.0 * (64.0 / pow(y, 3.0) - 192.0 / pow(y, 5.0) \
				+ 600.0 / pow(y, 7.0) - 1960.0 / pow(y, 9.0) \
				+ 6615.0 / pow(y, 11.0))
	return 2.0 * value


static func xi_quadrature(eta: float, slices := 4096) -> float:
	if not is_finite(eta) or eta <= 0.0:
		return NAN
	var n := maxi(2, slices)
	if n % 2 != 0:
		n += 1
	var step := (PI * 0.5) / float(n)
	var sum := 0.0
	for i in n + 1:
		var theta := float(i) * step
		var cosine := cos(theta)
		var integrand := cos(2.0 * theta) / sqrt(eta * eta + 4.0 * cosine * cosine)
		var weight := 1.0 if i == 0 or i == n else (4.0 if i % 2 == 1 else 2.0)
		sum += weight * integrand
	return 2.0 * step * sum / 3.0


static func rd_line(point_value: PackedFloat64Array, epsilon: float,
		direction: PackedFloat64Array, origin_x := 0.0, origin_y := 0.0) -> PackedFloat64Array:
	if point_value.size() != 2 or not is_finite(epsilon) or epsilon <= 0.0:
		return PackedFloat64Array()
	var direction_unit := normalized_point(direction)
	if length_point(direction_unit) <= POINT_EPSILON:
		return zero_point()
	var relative := point(point_value[0] - origin_x, point_value[1] - origin_y)
	var perpendicular := point(-direction_unit[1], direction_unit[0])
	var eta := dot_point(relative, perpendicular) / epsilon
	return scale_point(direction_unit, epsilon * xi_series(eta))


static func _segment_derivative(relative: PackedFloat64Array, direction: PackedFloat64Array,
		epsilon: float) -> PackedFloat64Array:
	return body_kernel_mul(relative, direction, epsilon)


static func rd_segment(point_value: PackedFloat64Array, epsilon: float,
		start: PackedFloat64Array, end: PackedFloat64Array, alpha := 0.1) -> PackedFloat64Array:
	if point_value.size() != 2 or start.size() != 2 or end.size() != 2 \
			or not is_finite(epsilon) or epsilon <= 0.0 or not is_finite(alpha) or alpha <= 0.0:
		return PackedFloat64Array()
	var displacement := subtract_point(start, end)
	var remaining := length_point(displacement)
	if remaining <= POINT_EPSILON:
		return zero_point()
	var direction := scale_point(displacement, 1.0 / remaining)
	var position := copy_point(end)
	var relative := subtract_point(point_value, position)
	var guard := 0
	while remaining > maxf(1.0e-12, length_point(displacement) * 1.0e-14):
		guard += 1
		if guard > 1000000:
			return PackedFloat64Array()
		var relative_length := length_point(relative)
		var delta_length := minf(remaining, alpha * maxf(epsilon, relative_length))
		var delta_position := scale_point(direction, delta_length)
		var midpoint_relative := add_point(relative,
				scale_point(_segment_derivative(relative, direction, epsilon), delta_length * 0.5))
		var delta_relative := _segment_derivative(midpoint_relative, direction, epsilon)
		delta_relative = scale_point(delta_relative, delta_length)
		relative = add_point(relative, delta_relative)
		position = add_point(position, delta_position)
		remaining -= delta_length
	return subtract_point(add_point(position, relative), point_value)


static func rd_segment_reference(point_value: PackedFloat64Array, epsilon: float,
		start: PackedFloat64Array, end: PackedFloat64Array,
		max_step_length := 0.0001) -> PackedFloat64Array:
	if point_value.size() != 2 or start.size() != 2 or end.size() != 2 \
			or not is_finite(epsilon) or epsilon <= 0.0 or max_step_length <= 0.0:
		return PackedFloat64Array()
	var displacement := subtract_point(start, end)
	var length := length_point(displacement)
	if length <= POINT_EPSILON:
		return zero_point()
	var direction := scale_point(displacement, 1.0 / length)
	var steps := maxi(1, int(ceil(length / max_step_length)))
	var step := length / float(steps)
	var relative := subtract_point(point_value, end)
	var position := copy_point(end)
	for _i in steps:
		var k1 := _segment_derivative(relative, direction, epsilon)
		var k2 := _segment_derivative(add_point(relative, scale_point(k1, step * 0.5)), direction, epsilon)
		var k3 := _segment_derivative(add_point(relative, scale_point(k2, step * 0.5)), direction, epsilon)
		var k4 := _segment_derivative(add_point(relative, scale_point(k3, step)), direction, epsilon)
		var weighted := add_point(add_point(k1, scale_point(k2, 2.0)),
				add_point(scale_point(k3, 2.0), k4))
		relative = add_point(relative, scale_point(weighted, step / 6.0))
		position = add_point(position, scale_point(direction, step))
	return subtract_point(add_point(position, relative), point_value)


# --- Reference pattern reverse-drift functions --------------------------------
# CPU twin of the GLSL port in mixwell_common.comp, from the authors' Mixwell.glsl
# (MIT, (c) 2026 Doug L. James and Ethan James). Points are Vector2 in, Vector2
# out; the arithmetic runs in 64-bit floats.

## PCG integer hash of tine k in [0, 1), bit-identical to reference_hash in
## mixwell_common.comp (32-bit unsigned arithmetic, kept below 2^63 here).
static func reference_hash(k: int) -> float:
	var state := (_mul32(k & 0xFFFFFFFF, 747796405) + 2891336453) & 0xFFFFFFFF
	var word := _mul32(((state >> ((state >> 28) + 4)) ^ state) & 0xFFFFFFFF, 277803737)
	return float(((word >> 22) ^ word) & 0xFFFFFFFF) / 4294967296.0


static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


## rdLine1DS: reverse drift of a line at this height above it.
static func rd_line_height(height: float, epsilon: float) -> float:
	return epsilon * xi_series(height / epsilon)


static func min_comb_dist(y: float, pitch: float) -> float:
	return pitch * absf(fposmod(y / pitch - 0.5, 1.0) - 0.5)


## rdNonpareilNoisy.
static func rd_nonpareil(p: Vector2, epsilon: float, direction: Vector2, gap: float,
		noise: float, cutoff_gamma: float) -> Vector2:
	if gap <= POINT_EPSILON or direction.length() <= POINT_EPSILON:
		return Vector2.ZERO
	var unit := direction.normalized()
	var y := p.x * -unit.y + p.y * unit.x
	var reach := mini(ceili((epsilon * cutoff_gamma + gap) / gap), 128)
	var nearest := roundi(y / gap)
	var drift := 0.0
	for k in range(nearest - reach, nearest + reach + 1):
		var tine := gap * float(k) + noise * (2.0 * reference_hash(k) - 1.0)
		drift += rd_line_height(absf(y - tine), epsilon)
	return unit * drift


## rdGelGit with the two passes the authors' app runs.
static func rd_gel_git(p: Vector2, epsilon: float, direction: Vector2, gap: float) -> Vector2:
	const PASSES := 2
	if gap <= POINT_EPSILON or direction.length() <= POINT_EPSILON:
		return Vector2.ZERO
	var unit := direction.normalized()
	var y := p.x * -unit.y + p.y * unit.x
	var pass_gap := float(PASSES) * gap * 2.0
	var drift := 0.0
	for k in PASSES:
		drift -= rd_line_height(min_comb_dist(y + (0.5 + float(k)) * gap * 2.0, pass_gap), epsilon)
		drift += rd_line_height(min_comb_dist(y + float(k) * gap * 2.0, pass_gap), epsilon)
	return unit * drift


## rdSegment: the Mixwell brush moving a -> b (rd_segment above), under the
## reference's local mask.
static func rd_segment_masked(p: Vector2, epsilon: float, a: Vector2, b: Vector2,
		cutoff_gamma: float, alpha: float) -> Vector2:
	var edge := b - a
	var along := clampf((p - a).dot(edge) / maxf(edge.length_squared(), 1.0e-30), 0.0, 1.0)
	var cutoff := maxf(epsilon * cutoff_gamma, epsilon)
	var distance := p.distance_to(a + edge * along)
	var t := clampf((distance - 0.5 * cutoff) / (0.5 * cutoff), 0.0, 1.0)
	var mask := 1.0 - t * t * (3.0 - 2.0 * t)
	if mask <= 0.0:
		return Vector2.ZERO
	var drift := rd_segment(point(p.x, p.y), epsilon, point(a.x, a.y), point(b.x, b.y), alpha)
	return Vector2(drift[0], drift[1]) * mask if drift.size() == 2 else Vector2.ZERO


## rdTriWave: one segment per half wave, every segment within the mask reach
## composed in reverse order; broken flips the sweep and reverses each segment.
static func rd_tri_wave(p: Vector2, epsilon: float, direction: Vector2, wavelength: float,
		amplitude: float, broken: bool, cutoff_gamma: float, alpha: float) -> Vector2:
	if direction.length() <= POINT_EPSILON:
		return Vector2.ZERO
	var start := p
	var unit := (-direction if broken else direction).normalized()
	var x := p.dot(unit)
	var y := (p - unit * x).length()
	var half_wave := 0.5 * wavelength
	var reach := epsilon * cutoff_gamma + sqrt(amplitude * amplitude + wavelength * wavelength / 16.0)
	var disc := reach * reach - y * y
	if disc <= 0.0 or half_wave <= 0.0:
		return Vector2.ZERO
	var reach_x := sqrt(disc)
	var last := ceili((x + reach_x) / half_wave)
	var first := maxi(floori((x - reach_x) / half_wave), last - 256)
	var along := unit * half_wave * 0.5
	var across := Vector2(-unit.y, unit.x) * amplitude
	var moved := p
	for i in range(last, first - 1, -1):
		var side := -1.0 if absi(i) % 2 == 0 else 1.0
		var centre := unit * half_wave * float(i)
		var a := centre - along + across * side
		var b := centre + along - across * side
		moved += rd_segment_masked(moved, epsilon, b, a, cutoff_gamma, alpha) if broken \
				else rd_segment_masked(moved, epsilon, a, b, cutoff_gamma, alpha)
	return moved - start


## rdTriWaveComb: parallel waves gap apart (gap 0 = the single wave).
static func rd_tri_wave_comb(p: Vector2, epsilon: float, direction: Vector2,
		wavelength: float, amplitude: float, broken: bool, gap: float, cutoff_gamma: float,
		alpha: float) -> Vector2:
	if gap <= POINT_EPSILON:
		return rd_tri_wave(p, epsilon, direction, wavelength, amplitude, broken,
				cutoff_gamma, alpha)
	var unit := direction.normalized()
	var normal := Vector2(-unit.y, unit.x)
	var reach := mini(ceili((absf(amplitude) + epsilon * cutoff_gamma) / gap), 64)
	var nearest := roundi(p.dot(normal) / gap)
	var drift := Vector2.ZERO
	for k in range(nearest - reach, nearest + reach + 1):
		drift += rd_tri_wave(p - normal * gap * float(k), epsilon, direction, wavelength,
				amplitude, broken, cutoff_gamma, alpha)
	return drift
