class_name MixwellPeriodicity
extends RefCounted

const FIXED_SCALE := 10000
const R2_STEP := Vector2(0.7548776662466927, 0.5698402909980532)


static func r2_sample(index: int) -> Vector2:
	var n: int = maxi(index, 0)
	return Vector2(
		fposmod(0.5 + float(n) * R2_STEP.x, 1.0),
		fposmod(0.5 + float(n) * R2_STEP.y, 1.0))


static func canonical_period(reference_size: Vector2i) -> Vector2:
	var width := maxi(reference_size.x, 1)
	var height := maxi(reference_size.y, 1)
	return Vector2(2.0 * float(width) / float(height), 2.0)


static func quantize_period(period: Vector2) -> Vector2i:
	if not is_finite(period.x) or not is_finite(period.y) \
			or period.x <= 0.0 or period.y <= 0.0:
		return Vector2i.ZERO
	return Vector2i(
		maxi(1, int(round(period.x * FIXED_SCALE))),
		maxi(1, int(round(period.y * FIXED_SCALE))))


static func quantize_period_components(period: Vector2) -> Vector2i:
	return Vector2i(
		0 if period.x <= 0.0 or not is_finite(period.x) else maxi(1, int(round(period.x * FIXED_SCALE))),
		0 if period.y <= 0.0 or not is_finite(period.y) else maxi(1, int(round(period.y * FIXED_SCALE))))


static func dequantize_period(period_fixed: Vector2i) -> Vector2:
	return Vector2(period_fixed) / float(FIXED_SCALE)


static func composite_period(periods: Array[Vector2]) -> Vector2:
	return dequantize_period(composite_period_fixed(periods))


static func composite_period_fixed(periods: Array[Vector2]) -> Vector2i:
	var result := Vector2i.ZERO
	for period in periods:
		var fixed := quantize_period(period)
		if fixed == Vector2i.ZERO:
			continue
		result.x = _lcm(result.x, fixed.x)
		result.y = _lcm(result.y, fixed.y)
	return result


static func composite_period_components_fixed(periods: Array[Vector2i]) -> Vector2i:
	var result := Vector2i.ZERO
	for period in periods:
		result.x = _lcm(result.x, period.x)
		result.y = _lcm(result.y, period.y)
	return result


static func wrap_coordinate(value: Vector2, period: Vector2) -> Vector2:
	if period.x <= 0.0 or period.y <= 0.0:
		return value
	return Vector2(
		fposmod(value.x + period.x * 0.5, period.x) - period.x * 0.5,
		fposmod(value.y + period.y * 0.5, period.y) - period.y * 0.5)


static func shortest_delta(a: Vector2, b: Vector2, period: Vector2) -> Vector2:
	var delta := a - b
	if period.x > 0.0:
		delta.x -= period.x * round(delta.x / period.x)
	if period.y > 0.0:
		delta.y -= period.y * round(delta.y / period.y)
	return delta


static func compare_paths(periodic_displacement: PackedFloat32Array,
		fullscreen_displacement: PackedFloat32Array,
		period := Vector2.ZERO, periodic_colour := PackedFloat32Array(),
		fullscreen_colour := PackedFloat32Array()) -> Dictionary:
	var displacement_count := int(mini(periodic_displacement.size(), fullscreen_displacement.size()) / 2)
	var max_displacement := 0.0
	var mean_displacement := 0.0
	for index in displacement_count:
		var a := Vector2(periodic_displacement[index * 2], periodic_displacement[index * 2 + 1])
		var b := Vector2(fullscreen_displacement[index * 2],
				fullscreen_displacement[index * 2 + 1])
		var error := shortest_delta(a, b, period).length() if period != Vector2.ZERO \
				else a.distance_to(b)
		max_displacement = maxf(max_displacement, error)
		mean_displacement += error
	if displacement_count > 0:
		mean_displacement /= float(displacement_count)

	var colour_count := int(mini(periodic_colour.size(), fullscreen_colour.size()) / 4)
	var mean_colour := 0.0
	for index in colour_count:
		var offset := index * 4
		mean_colour += Vector3(
			periodic_colour[offset], periodic_colour[offset + 1], periodic_colour[offset + 2]).distance_to(
				Vector3(fullscreen_colour[offset], fullscreen_colour[offset + 1],
					fullscreen_colour[offset + 2]))
	if colour_count > 0:
		mean_colour /= float(colour_count)

	return {
		"samples": displacement_count,
		"max_displacement": max_displacement,
		"mean_displacement": mean_displacement,
		"mean_colour": mean_colour,
		"passes": max_displacement <= 5.0e-4 and mean_colour <= 1.0 / 255.0,
	}


static func _gcd(a: int, b: int) -> int:
	var left := absi(a)
	var right := absi(b)
	while right != 0:
		var remainder := left % right
		left = right
		right = remainder
	return left


static func _lcm(a: int, b: int) -> int:
	if a == 0:
		return b
	if b == 0:
		return a
	var divisor := _gcd(a, b)
	return absi(int(a / divisor) * b)
