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
