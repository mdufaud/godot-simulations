class_name MixwellGallery
extends RefCounted

const Pattern := preload("res://scripts/mixwell/mixwell_pattern.gd")

const SINGLE_LINE := 0
const FINITE_SEGMENT := 1
const FREEHAND_LAB := 2
const NONPAREIL := 3
const GEL_GIT := 4
const FEATHER := 5
const BIRD_WING := 6
const PEACOCK := 7
const FROG_FOOT := 8
const TWIST := 9
const PINCH := 10
const THISTLE := 11
const TORNADO := 12
const SUPER_TORNADO := 13
const NONPAREIL_NOISY := 14
const CIRCLE_GRID := 15
const SINE_CURVE := 16
const PAINT_SPREAD := 17

const LINE := 0
const LINE_COMB := 1
const SEGMENT := 2

const PRESET_NAMES := [
	"Single Line", "Finite Segment", "Freehand Lab", "Nonpareil", "Gel-Git",
	"Feather", "BirdWing", "Peacock", "FrogFoot"
]
const COMPENSATION_NAMES := ["None", "Minimum", "Mean"]
const EXTENSION_NAMES := ["Twist", "Pinch"]
const EXTRA_NAMES := [
	"Thistle", "Tornado", "Super Tornado", "Nonpareil (noisy)", "Circle Grid",
	"Sine Curve", "Paint Spread"
]


static func preset_names() -> Array[String]:
	var result: Array[String] = []
	for name in PRESET_NAMES:
		result.append(name)
	return result


static func compensation_names() -> Array[String]:
	var result: Array[String] = []
	for name in COMPENSATION_NAMES:
		result.append(name)
	return result


static func all_preset_names() -> Array[String]:
	var result := preset_names()
	result.append_array(EXTENSION_NAMES)
	result.append_array(EXTRA_NAMES)
	return result


static func preset_name(id: int) -> String:
	if id >= 0 and id < PRESET_NAMES.size():
		return PRESET_NAMES[id]
	var extension_index := id - TWIST
	if extension_index >= 0 and extension_index < EXTENSION_NAMES.size():
		return EXTENSION_NAMES[extension_index]
	var extra_index := id - THISTLE
	if extra_index >= 0 and extra_index < EXTRA_NAMES.size():
		return EXTRA_NAMES[extra_index]
	return "Unknown"


static func is_affine(id: int) -> bool:
	return id == TWIST or id == PINCH


static func preset_pattern(id: int):
	var pattern = Pattern.new()
	pattern.id = id
	pattern.name = preset_name(id)
	pattern.source_metadata = {
		"family": "Mixwell RDF construction",
		"preset_id": id,
		"construction": "ordered operations; rendered in reverse physical order",
	}
	var operations := _pattern_operations(id)
	if is_affine(id):
		operations = [{"type": LINE, "kind": "AFFINE", "origin": Vector2.ZERO,
			"direction": Vector2.RIGHT, "period": Vector2.ZERO, "pitch": 0.0,
			"count": 1, "noise": 0.0}]
	pattern.set_operations(operations)
	return pattern


static func affine_matrix(id: int) -> Vector4:
	if id == TWIST:
		return Vector4(0.0, -1.0, 1.0, 0.0)
	if id == PINCH:
		return Vector4(-1.0, 0.0, 0.0, 1.0)
	return Vector4.ZERO


static func affine_drift(id: int, point: Vector2, centre: Vector2,
		strength: float, radius: float, _cutoff_gamma: float) -> Vector2:
	if not is_affine(id) or not is_finite(strength) or not is_finite(radius) \
			or radius <= 0.0:
		return Vector2.ZERO
	var relative := point - centre
	var distance := relative.length()
	if distance <= 1.0e-12:
		return Vector2.ZERO
	var epsilon_squared := radius * radius
	var radius_epsilon := sqrt(distance * distance + epsilon_squared)
	var radius_epsilon_3 := radius_epsilon * radius_epsilon * radius_epsilon
	var radius_epsilon_5 := radius_epsilon_3 * radius_epsilon * radius_epsilon
	var a_prime := epsilon_squared * (distance * distance - 2.0 * epsilon_squared) \
			/ radius_epsilon_5
	var b_prime := -epsilon_squared * (4.0 * distance * distance + epsilon_squared) \
			/ (distance * distance * radius_epsilon_5)
	var b := epsilon_squared / (distance * radius_epsilon_3)
	var matrix := affine_matrix(id)
	var f_relative := Vector2(
		matrix.x * relative.x + matrix.y * relative.y,
		matrix.z * relative.x + matrix.w * relative.y)
	var f_transpose_relative := Vector2(
		matrix.x * relative.x + matrix.z * relative.y,
		matrix.y * relative.x + matrix.w * relative.y)
	var trace := matrix.x + matrix.w
	return strength * radius * (a_prime / distance * f_relative
			+ b_prime / distance * relative.dot(f_relative) * relative
			+ b * f_transpose_relative + b * trace * relative)


static func affine_advect(id: int, point: Vector2, centre: Vector2,
		strength: float, radius: float, cutoff_gamma: float) -> Vector2:
	const SUBSTEPS := 8
	var mapped := point
	var dt := 1.0 / float(SUBSTEPS)
	for _step in SUBSTEPS:
		var first := affine_drift(id, mapped, centre, strength, radius, cutoff_gamma)
		var midpoint := mapped + first * (0.5 * dt)
		mapped += affine_drift(id, midpoint, centre, strength, radius, cutoff_gamma) * dt
	return mapped


static func preset_operations(id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	match id:
		SINGLE_LINE:
			result.append(_line(Vector2.ZERO, Vector2.RIGHT, Vector2.ZERO))
		FINITE_SEGMENT:
			result.append(_segment(Vector4(-0.82, 0.0, 0.82, 0.0), Vector2i.ZERO))
		NONPAREIL:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.17777778, 11, 0.0))
		GEL_GIT:
			result.append_array(_gel_git())
		FEATHER:
			result.append_array(_feather())
		BIRD_WING:
			result.append_array(_bird_wing())
		PEACOCK:
			result.append_array(_peacock(false))
		FROG_FOOT:
			result.append_array(_peacock(true))
		THISTLE:
			result.append_array(_gel_git())
			result.append_array(_line_comb(Vector2.ZERO, Vector2.UP, 0.18, 11, 0.0))
			result.append_array(_triangle_pass(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
				0.09, 9, false))
			result.append_array(_triangle_pass(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
				-0.09, 9, true))
		TORNADO:
			result.append_array(_gel_git_vertical())
			result.append_array(_gel_git())
			result.append_array(_triangle_pass(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
				0.09, 9, false))
			result.append_array(_triangle_pass(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
				-0.09, 9, true))
		SUPER_TORNADO:
			result.append_array(_gel_git_vertical())
			result.append_array(_gel_git())
			result.append_array(_line_comb(Vector2.ZERO, Vector2.UP, 0.14, 13, 0.018))
			result.append_array(_triangle_pass(Vector2(-0.86, 0.0), Vector2(0.86, 0.0),
				0.12, 12, false))
			result.append_array(_triangle_pass(Vector2(-0.86, 0.0), Vector2(0.86, 0.0),
				-0.12, 12, true))
		NONPAREIL_NOISY:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.18, 11, 0.035))
		CIRCLE_GRID:
			result.append_array(_circle_grid())
		SINE_CURVE:
			result.append_array(_sine_curve())
		PAINT_SPREAD:
			result.append_array(_peacock(false))
			result.append_array(_triangle_pass(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
				0.10, 10, false))
			result.append_array(_triangle_pass(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
				-0.10, 10, true))
	return result


static func _pattern_operations(id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	match id:
		SINGLE_LINE:
			result.append(_line(Vector2.ZERO, Vector2.RIGHT, Vector2.ZERO))
		FINITE_SEGMENT:
			result.append(_segment(Vector4(-0.82, 0.0, 0.82, 0.0), Vector2i.ZERO))
		NONPAREIL:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.17777778, 11, 0.0))
		GEL_GIT:
			result.append_array(_gel_git())
		FEATHER:
			result.append_array(_gel_git())
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.13333333, 15, 0.0))
			result.append(_triangle_curve(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
					0.10, 10, false))
		BIRD_WING:
			result.append_array(_pattern_operations(FEATHER))
			result.append(_triangle_curve(Vector2(0.82, 0.0), Vector2(-0.82, 0.0),
					-0.10, 10, true))
		PEACOCK, FROG_FOOT:
			var frog := id == FROG_FOOT
			result.append_array(_gel_git())
			result.append(_comb(Vector2.ZERO, Vector2.DOWN if not frog else Vector2.UP,
					0.16666667, 12, 0.0))
			result.append(_triangle_curve(Vector2(-0.82, -0.35), Vector2(0.82, -0.35),
					0.10, 9, false))
			result.append(_triangle_curve(Vector2(0.82, 0.35), Vector2(-0.82, 0.35),
					-0.10, 9, true))
		THISTLE:
			result.append_array(_gel_git())
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.17777778, 11, 0.0))
			result.append(_triangle_curve(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
					0.09, 9, false))
			result.append(_triangle_curve(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
					-0.09, 9, true))
		TORNADO:
			result.append_array(_gel_git_vertical())
			result.append_array(_gel_git())
			result.append(_triangle_curve(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
					0.09, 9, false))
			result.append(_triangle_curve(Vector2(-0.78, 0.0), Vector2(0.78, 0.0),
					-0.09, 9, true))
		SUPER_TORNADO:
			result.append_array(_gel_git_vertical())
			result.append_array(_gel_git())
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.14814815, 13, 0.0))
			result.append(_triangle_curve(Vector2(-0.86, 0.0), Vector2(0.86, 0.0),
					0.12, 12, false))
			result.append(_triangle_curve(Vector2(-0.86, 0.0), Vector2(0.86, 0.0),
					-0.12, 12, true))
		NONPAREIL_NOISY:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.18, 11, 0.035,
					0.0175))
		CIRCLE_GRID:
			result.append_array(_pattern_circle_grid())
		SINE_CURVE:
			result.append(_pattern_sine_curve())
		PAINT_SPREAD:
			result.append_array(_pattern_operations(PEACOCK))
			result.append(_triangle_curve(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
					0.10, 10, false))
			result.append(_triangle_curve(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
					-0.10, 10, true))
	return result


static func preset_segments(id: int) -> Array[Vector4]:
	var result: Array[Vector4] = []
	for operation in preset_operations(id):
		if int(operation.type) == SEGMENT:
			result.append(operation.segment)
	return result


static func tri_wave(start: Vector2, end: Vector2, amplitude: float,
		cycles: int) -> Array[Vector4]:
	var result: Array[Vector4] = []
	for operation in _triangle_pass(start, end, amplitude, cycles, false):
		result.append(operation.segment)
	return result


static func compensation_value(mode: int, epsilon: float, pitch: float) -> float:
	if not is_finite(epsilon) or epsilon <= 0.0 or not is_finite(pitch) or pitch <= 0.0:
		return NAN
	if mode == 2:
		return -PI * epsilon * epsilon / pitch
	if mode == 1:
		var h := pitch / epsilon
		return epsilon * (-37.7829 + 1.01689 * h) \
				/ (1.09635 + h * (12.2129 + h * (1.59101 + h)))
	return 0.0


static func compensation_vector(mode: int, epsilon: float, pitch: float,
		direction: Vector2) -> Vector2:
	var length := direction.length()
	if length <= 1.0e-12:
		return Vector2.ZERO
	return direction / length * compensation_value(mode, epsilon, pitch)


static func _line(origin: Vector2, direction: Vector2, period: Vector2,
		phase := 0.0, radius_px := -1.0, extent := Vector2.ZERO) -> Dictionary:
	return {"type": LINE, "origin": origin, "direction": direction, "period": period,
		"pitch": 0.0, "phase": phase, "count": 1, "noise": 0.0,
		"radius_px": radius_px, "extent": extent}


static func _comb(origin: Vector2, direction: Vector2, pitch: float, count: int,
		noise: float, phase := 0.0, radius_px := -1.0,
		extent := Vector2.ZERO) -> Dictionary:
	var perpendicular := Vector2(-direction.y, direction.x).normalized()
	var period := Vector2.ZERO
	if noise <= 0.0:
		period = Vector2(0.0, pitch) if absf(perpendicular.y) > absf(perpendicular.x) \
			else Vector2(pitch, 0.0)
	return {"type": LINE_COMB, "origin": origin, "direction": direction,
		"period": period, "pitch": pitch, "phase": phase, "count": count,
		"noise": noise, "radius_px": radius_px, "extent": extent}


static func _line_comb(origin: Vector2, direction: Vector2, pitch: float, count: int,
		noise: float) -> Array[Dictionary]:
	return [_comb(origin, direction, pitch, count, noise)]


static func _segment(segment: Vector4, period_pixels: Vector2i,
		radius_px := -1.0) -> Dictionary:
	return {"type": SEGMENT, "segment": segment, "period": Vector2.ZERO,
		"period_pixels": period_pixels, "pitch": 0.0, "count": 1, "noise": 0.0,
		"radius_px": radius_px}


static func _gel_git() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append(_comb(Vector2(0.0, -0.42), Vector2.RIGHT, 0.23703704, 7, 0.0))
	result.append(_comb(Vector2(0.0, 0.42), Vector2.LEFT, 0.23703704, 7, 0.0))
	return result


static func _gel_git_vertical() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.append(_comb(Vector2(-0.42, 0.0), Vector2.UP, 0.23703704, 7, 0.0))
	result.append(_comb(Vector2(0.42, 0.0), Vector2.DOWN, 0.23703704, 7, 0.0))
	return result


static func _feather() -> Array[Dictionary]:
	var result := _gel_git()
	result.append(_comb(Vector2.ZERO, Vector2.UP, 0.13, 15, 0.02))
	result.append_array(_triangle_pass(Vector2(-0.82, 0.0), Vector2(0.82, 0.0),
			0.10, 10, false))
	return result


static func _bird_wing() -> Array[Dictionary]:
	var result := _feather()
	result.append_array(_triangle_pass(Vector2(0.82, 0.0), Vector2(-0.82, 0.0),
			-0.10, 10, true))
	return result


static func _peacock(frog: bool) -> Array[Dictionary]:
	var result := _gel_git()
	result.append(_comb(Vector2.ZERO, Vector2.DOWN if not frog else Vector2.UP,
			0.16, 12, 0.018))
	result.append_array(_triangle_pass(Vector2(-0.82, -0.35), Vector2(0.82, -0.35),
			0.10, 9, false))
	result.append_array(_triangle_pass(Vector2(0.82, 0.35), Vector2(-0.82, 0.35),
			-0.10, 9, true))
	return result


static func _triangle_pass(start: Vector2, end: Vector2, amplitude: float,
		cycles: int, broken: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var count := maxi(cycles * 2, 2)
	var edge := end - start
	if edge.length() <= 1.0e-6:
		return result
	var perpendicular := Vector2(-edge.y, edge.x).normalized()
	var points: Array[Vector2] = []
	for index in count + 1:
		var fraction := float(index) / float(count)
		var triangle := 0.0
		if index > 0 and index < count:
			triangle = 1.0 - absf(fposmod(fraction * float(cycles), 2.0) - 1.0)
			triangle = triangle * 2.0 - 1.0
		points.append(start.lerp(end, fraction) + perpendicular * amplitude * triangle)
	for index in range(points.size() - 1):
		var a := points[index]
		var b := points[index + 1]
		if broken and index % 2 == 1:
			var swap := a
			a = b
			b = swap
		result.append(_segment(Vector4(a.x, a.y, b.x, b.y), Vector2i(300, 180)))
	return result


static func _triangle_curve(start: Vector2, end: Vector2, amplitude: float,
		cycles: int, broken: bool) -> Dictionary:
	var repeat_scale := 4
	var expanded_cycles := maxi(cycles * repeat_scale, 1)
	var edge := end - start
	var points: Array[Vector2] = []
	if edge.length() <= 1.0e-6:
		return _curve(points, "TRIWAVE", not broken, broken)
	var edge_direction := edge.normalized()
	var centre := (start + end) * 0.5
	var period_x: float
	match cycles:
		9:
			period_x = 0.16666667
		10:
			period_x = 0.13333333
		12:
			period_x = 0.14814815
		_:
			period_x = round(absf(edge.x) / float(maxi(cycles, 1)) * 270.0) / 270.0
	period_x = maxf(period_x, 1.0 / 270.0)
	var expanded_length := period_x * float(maxi(cycles, 1)) * repeat_scale
	var expanded_start := centre - edge_direction * expanded_length * 0.5
	var expanded_end := centre + edge_direction * expanded_length * 0.5
	var expanded_edge := expanded_end - expanded_start
	var perpendicular := Vector2(-expanded_edge.y, expanded_edge.x).normalized()
	for index in expanded_cycles * 2 + 1:
		var fraction := float(index) / float(expanded_cycles * 2)
		var triangle := 0.0
		if index > 0 and index < expanded_cycles * 2:
			triangle = 1.0 - absf(fposmod(fraction * float(expanded_cycles), 2.0) - 1.0)
			triangle = triangle * 2.0 - 1.0
		points.append(expanded_start.lerp(expanded_end, fraction)
				+ perpendicular * amplitude * triangle)
	var period := Vector2(period_x, 2.0)
	return _curve(points, "TRIWAVE", not broken, broken, Transform2D.IDENTITY,
			Vector2.ZERO, Vector2i.ZERO, 2, period)


static func _curve(points: Array[Vector2], mode: String, smooth: bool,
		broken: bool, transform := Transform2D.IDENTITY,
		extent := Vector2.ZERO, period_pixels := Vector2i(300, 180),
		periodic_segment_count := 0, period := Vector2.ZERO) -> Dictionary:
	return {"type": SEGMENT, "kind": "CURVE", "curve_mode": mode,
		"points": points, "smooth": smooth, "broken": broken,
		"transform": transform, "extent": extent, "period": period,
		"period_pixels": period_pixels, "pitch": 0.0, "phase": 0.0,
		"count": 1, "noise": 0.0, "periodic_segment_count": periodic_segment_count}


static func _pattern_circle_grid() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in 4:
		for column in 5:
			var centre := Vector2(-0.68 + float(column) * 0.34, -0.54 + float(row) * 0.36)
			var points: Array[Vector2] = []
			for index in 13:
				var angle := TAU * float(index) / 12.0
				points.append(Vector2(cos(angle), sin(angle)) * 0.11)
			result.append(_curve(points, "CIRCLE", true, false,
					Transform2D(0.0, centre), Vector2.ZERO, Vector2i.ZERO))
	return result


static func _pattern_sine_curve() -> Dictionary:
	var points: Array[Vector2] = []
	for index in 33:
		var fraction := float(index) / 32.0
		points.append(Vector2(lerpf(-0.9, 0.9, fraction), sin(fraction * TAU * 2.0) * 0.42))
	return _curve(points, "SINE", true, false, Transform2D.IDENTITY,
			Vector2(-0.9, 0.9), Vector2.ZERO, 16, Vector2(0.9, 2.0))


static func _circle_grid() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in 4:
		for column in 5:
			var centre := Vector2(-0.68 + float(column) * 0.34, -0.54 + float(row) * 0.36)
			var points: Array[Vector2] = []
			for index in 13:
				var angle := TAU * float(index) / 12.0
				points.append(centre + Vector2(cos(angle), sin(angle)) * 0.11)
			for index in range(points.size() - 1):
				var a := points[index]
				var b := points[index + 1]
				result.append(_segment(Vector4(a.x, a.y, b.x, b.y), Vector2i(120, 120)))
	return result


static func _sine_curve() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var points: Array[Vector2] = []
	for index in 33:
		var fraction := float(index) / 32.0
		points.append(Vector2(lerpf(-0.9, 0.9, fraction), sin(fraction * TAU * 2.0) * 0.42))
	for index in range(points.size() - 1):
		var a := points[index]
		var b := points[index + 1]
		result.append(_segment(Vector4(a.x, a.y, b.x, b.y), Vector2i(300, 180)))
	return result
