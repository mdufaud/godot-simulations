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
const BAKED_MAP := 3
const GEL_GIT_PASS := 4
const TRI_WAVE := 5
## Every user stroke segment, evaluated exactly per sample (mixwell_rd_strokes).
const USER_STROKES := 6

## Tine pitch of each of Gel-Git's two combs.
const GEL_GIT_PITCH := 0.23703704

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


## Reverse drift of the affine brush (an extension: Twist and Pinch are not in
## the reference): the brush moves the fluid with u for unit time, so a point is
## carried back by the flow of -u, in midpoint steps no longer than
## alpha * max(radius, distance) of travel, as in mixwell_affine.comp.
static func affine_advect(id: int, point: Vector2, centre: Vector2,
		strength: float, radius: float, cutoff_gamma: float, alpha := 0.1,
		sign := -1.0) -> Vector2:
	var mapped := point
	var remaining := 1.0
	for _step in 4096:
		if remaining <= 0.0:
			break
		var first := sign * affine_drift(id, mapped, centre, strength, radius, cutoff_gamma)
		var reach := alpha * maxf(radius, mapped.distance_to(centre))
		var speed := first.length()
		var dt := reach / speed if speed * remaining > reach else remaining
		var midpoint := mapped + first * (0.5 * dt)
		mapped += sign * affine_drift(id, midpoint, centre, strength, radius, cutoff_gamma) * dt
		remaining -= dt
	return mapped


static func _pattern_operations(id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	match id:
		SINGLE_LINE:
			result.append(_line(Vector2.ZERO, Vector2.RIGHT, Vector2.ZERO))
		FINITE_SEGMENT:
			result.append(_segment(Vector4(-0.82, 0.0, 0.82, 0.0), Vector2i.ZERO))
		NONPAREIL:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.17777778, 0.0))
		GEL_GIT:
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
		FEATHER:
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.13333333, 0.0))
			result.append(_tri_wave(Vector2(-0.82, 0.0), Vector2(0.82, 0.0), 0.10, 0.13333333,
					false))
		BIRD_WING:
			result.append_array(_pattern_operations(FEATHER))
			result.append(_tri_wave(Vector2(0.82, 0.0), Vector2(-0.82, 0.0), -0.10, 0.13333333,
					true))
		PEACOCK, FROG_FOOT:
			var frog := id == FROG_FOOT
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
			result.append(_comb(Vector2.ZERO, Vector2.DOWN if not frog else Vector2.UP,
					0.16666667, 0.0))
			result.append(_tri_wave(Vector2(-0.82, -0.35), Vector2(0.82, -0.35), 0.10,
					0.16666667, false))
			result.append(_tri_wave(Vector2(0.82, 0.35), Vector2(-0.82, 0.35), -0.10,
					0.16666667, true))
		THISTLE:
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.17777778, 0.0))
			result.append(_tri_wave(Vector2(-0.78, 0.0), Vector2(0.78, 0.0), 0.09, 0.16666667,
					false))
			result.append(_tri_wave(Vector2(-0.78, 0.0), Vector2(0.78, 0.0), -0.09, 0.16666667,
					true))
		TORNADO:
			result.append(_gel_git(Vector2(-0.42, 0.0), Vector2.UP))
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
			result.append(_tri_wave(Vector2(-0.78, 0.0), Vector2(0.78, 0.0), 0.09, 0.16666667,
					false))
			result.append(_tri_wave(Vector2(-0.78, 0.0), Vector2(0.78, 0.0), -0.09, 0.16666667,
					true))
		SUPER_TORNADO:
			result.append(_gel_git(Vector2(-0.42, 0.0), Vector2.UP))
			result.append(_gel_git(Vector2(0.0, -0.42), Vector2.RIGHT))
			result.append(_comb(Vector2.ZERO, Vector2.UP, 0.14814815, 0.0))
			result.append(_tri_wave(Vector2(-0.86, 0.0), Vector2(0.86, 0.0), 0.12, 0.14814815,
					false))
			result.append(_tri_wave(Vector2(-0.86, 0.0), Vector2(0.86, 0.0), -0.12, 0.14814815,
					true))
		NONPAREIL_NOISY:
			result.append(_comb(Vector2.ZERO, Vector2.RIGHT, 0.18, 0.035, 0.0175))
		CIRCLE_GRID:
			result.append_array(_pattern_circle_grid())
		SINE_CURVE:
			result.append(_pattern_sine_curve())
		PAINT_SPREAD:
			result.append_array(_pattern_operations(PEACOCK))
			result.append(_tri_wave(Vector2(-0.82, 0.0), Vector2(0.82, 0.0), 0.10, 0.13333333,
					false))
			result.append(_tri_wave(Vector2(-0.82, 0.0), Vector2(0.82, 0.0), -0.10, 0.13333333,
					true))
	return result


## Segments the preset itself uploads (its strokes and curves), in render order.
static func preset_segments(id: int) -> Array[Vector4]:
	var result: Array[Vector4] = []
	if is_affine(id):
		return result
	for operation in preset_pattern(id).render_operations():
		if int(operation.type) == SEGMENT:
			result.append(operation.segment)
	return result


static func compensation_value(mode: int, epsilon: float, pitch: float) -> float:
	if not is_finite(epsilon) or epsilon <= 0.0 or not is_finite(pitch) or pitch <= 0.0:
		return NAN
	if mode == 2:
		return PI * epsilon * epsilon / pitch
	if mode == 1:
		var h := pitch / epsilon
		return -epsilon * (-37.7829 + 1.01689 * h) \
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


## A period along one axis for an axis-aligned direction, none otherwise (the
## periodic planner tiles only axis-aligned periods). The other component is 0:
## the field of a family of parallel lines is constant along them.
static func _axis_period(direction: Vector2, length: float) -> Vector2:
	var unit := direction.normalized()
	if absf(unit.y) <= 1.0e-6:
		return Vector2(length, 0.0)
	if absf(unit.x) <= 1.0e-6:
		return Vector2(0.0, length)
	return Vector2.ZERO


## Nonpareil comb (rdNonpareilNoisy): tines gap apart, tine k shifted by up to
## +-noise; phase shifts every tine across.
static func _comb(origin: Vector2, direction: Vector2, gap: float, noise: float,
		phase := 0.0, radius_px := -1.0) -> Dictionary:
	var across := Vector2(-direction.y, direction.x)
	return {"type": LINE_COMB, "kind": "COMB", "origin": origin, "direction": direction,
		"period": _axis_period(across, gap) if noise <= 0.0 else Vector2.ZERO,
		"pitch": gap, "phase": phase, "count": 1, "noise": noise, "radius_px": radius_px,
		"extent": Vector2.ZERO}


## Gel-Git (rdGelGit): a comb moving along direction with tines GEL_GIT_PITCH
## apart, superposed on one moving against it offset by half that pitch.
static func _gel_git(origin: Vector2, direction: Vector2) -> Dictionary:
	var gap := GEL_GIT_PITCH * 0.5
	var across := Vector2(-direction.y, direction.x)
	return {"type": GEL_GIT_PASS, "kind": "GEL_GIT", "origin": origin, "direction": direction,
		"period": _axis_period(across, 2.0 * gap), "pitch": gap, "phase": 0.0, "count": 1,
		"noise": 0.0, "radius_px": -1.0, "extent": Vector2.ZERO}


## Triangle wave (rdTriWave) from start toward end, its half wave (one segment
## from trough to crest) half_wave long, its crests the signed amplitude from
## the centre line. Infinite along its line: start and end set its direction,
## and the centre falls on a trough, as the gallery drew it.
static func _tri_wave(start: Vector2, end: Vector2, amplitude: float, half_wave: float,
		broken: bool) -> Dictionary:
	var direction := (end - start).normalized()
	var origin := (start + end) * 0.5 + direction * half_wave * 0.5
	# Periodic along a horizontal wave, never across it (2 is the full canonical
	# height); a period of 0 would declare the field constant across.
	var period := Vector2(2.0 * half_wave, 2.0) if absf(direction.y) <= 1.0e-6 else Vector2.ZERO
	return {"type": TRI_WAVE, "kind": "TRI_WAVE", "origin": origin, "direction": direction,
		"period": period, "pitch": 0.0, "phase": 0.0,
		"count": 1, "noise": 0.0, "radius_px": -1.0, "extent": Vector2.ZERO,
		"wavelength": 2.0 * half_wave, "amplitude": amplitude, "broken": broken}


static func _segment(segment: Vector4, period_pixels: Vector2i,
		radius_px := -1.0) -> Dictionary:
	return {"type": SEGMENT, "segment": segment, "period": Vector2.ZERO,
		"period_pixels": period_pixels, "pitch": 0.0, "count": 1, "noise": 0.0,
		"radius_px": radius_px}


static func _curve(points: Array[Vector2], mode: String, smooth: bool,
		broken: bool, transform := Transform2D.IDENTITY,
		extent := Vector2.ZERO, period_pixels := Vector2i(300, 180)) -> Dictionary:
	return {"type": SEGMENT, "kind": "CURVE", "curve_mode": mode,
		"points": points, "smooth": smooth, "broken": broken,
		"transform": transform, "extent": extent, "period": Vector2.ZERO,
		"period_pixels": period_pixels, "pitch": 0.0, "phase": 0.0,
		"count": 1, "noise": 0.0}


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
	return _curve(points, "SINE", true, false, Transform2D.IDENTITY, Vector2.ZERO,
			Vector2i.ZERO)
