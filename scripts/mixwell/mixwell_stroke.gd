class_name MixwellStroke
extends Resource

const POINT_EPSILON := 1.0e-6

@export var points_px := PackedVector2Array()
@export_range(1.0, 256.0, 1.0) var radius_px := 18.0


func validate() -> String:
	if points_px.size() < 2:
		return "a stroke needs at least two points"
	if not is_finite(radius_px) or radius_px <= 0.0:
		return "radius_px must be positive and finite"
	for point in points_px:
		if not is_finite(point.x) or not is_finite(point.y):
			return "stroke points must be finite"
	return ""


func segment_count() -> int:
	return maxi(points_px.size() - 1, 0)


func append_drag_point(point: Vector2, spacing_px: float, max_segments := -1,
		force := false) -> int:
	if not is_finite(point.x) or not is_finite(point.y):
		return 0
	if points_px.is_empty():
		points_px.append(point)
		return 1
	var spacing := maxf(spacing_px, POINT_EPSILON)
	var last := points_px[points_px.size() - 1]
	var delta := point - last
	var distance := delta.length()
	if distance <= POINT_EPSILON:
		return 0
	var added := 0
	while distance >= spacing:
		if max_segments >= 0 and segment_count() >= max_segments:
			return added
		last += delta * (spacing / distance)
		points_px.append(last)
		added += 1
		delta = point - last
		distance = delta.length()
	if force and distance > POINT_EPSILON:
		if max_segments < 0 or segment_count() < max_segments:
			points_px.append(point)
			added += 1
	return added


func to_segments(max_segments := -1) -> Array[Vector4]:
	var result: Array[Vector4] = []
	if points_px.size() < 2:
		return result
	var count := points_px.size() - 1
	if max_segments >= 0:
		count = mini(count, max_segments)
	for index in range(count):
		var start := points_px[index]
		var end := points_px[index + 1]
		result.append(Vector4(start.x, start.y, end.x, end.y))
	return result
