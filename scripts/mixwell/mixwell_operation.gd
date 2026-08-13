class_name MixwellOperation
extends RefCounted

const TYPE_LINE := "LINE"
const TYPE_SEGMENT_CHAIN := "SEGMENT_CHAIN"
const TYPE_CURVE := "CURVE"
const TYPE_AFFINE := "AFFINE"

var kind := TYPE_LINE
var render_type := 0
var origin := Vector2.ZERO
var direction := Vector2.RIGHT
var segment := Vector4.ZERO
var transform := Transform2D.IDENTITY
var period := Vector2.ZERO
var period_pixels := Vector2i.ZERO
var pitch := 0.0
var phase := 0.0
var count := 1
var noise := 0.0
var radius_px := -1.0
var extent := Vector2.ZERO
var points: Array[Vector2] = []
var curve_mode := ""
var curve_group := -1
var periodic_segment_count := 0
var smooth := true
var broken := false
var localized := true
var metadata := {}


func set_from_dictionary(value: Dictionary) -> void:
	var default_kind := TYPE_SEGMENT_CHAIN if int(value.get("type", 0)) == 2 \
			or int(value.get("type", 0)) == 1 else TYPE_LINE
	kind = str(value.get("kind", default_kind))
	render_type = int(value.get("type", render_type))
	origin = value.get("origin", origin)
	direction = value.get("direction", direction)
	segment = value.get("segment", segment)
	transform = value.get("transform", transform)
	period = value.get("period", period)
	period_pixels = value.get("period_pixels", period_pixels)
	pitch = float(value.get("pitch", pitch))
	phase = float(value.get("phase", phase))
	count = int(value.get("count", count))
	noise = float(value.get("noise", noise))
	radius_px = float(value.get("radius_px", radius_px))
	extent = value.get("extent", extent)
	points.clear()
	for point in value.get("points", []):
		if point is Vector2:
			points.append(point)
	curve_mode = str(value.get("curve_mode", curve_mode))
	curve_group = int(value.get("curve_group", curve_group))
	periodic_segment_count = int(value.get("periodic_segment_count", periodic_segment_count))
	smooth = bool(value.get("smooth", smooth))
	broken = bool(value.get("broken", broken))
	localized = bool(value.get("localized", localized))
	metadata = value.get("metadata", {}).duplicate(true)


func to_dictionary() -> Dictionary:
	return {
		"type": render_type,
		"kind": kind,
		"origin": origin,
		"direction": direction,
		"segment": segment,
		"transform": transform,
		"period": period,
		"period_pixels": period_pixels,
		"pitch": pitch,
		"phase": phase,
		"count": count,
		"noise": noise,
		"radius_px": radius_px,
		"extent": extent,
		"points": points.duplicate(true),
		"curve_mode": curve_mode,
		"curve_group": curve_group,
		"periodic_segment_count": periodic_segment_count,
		"smooth": smooth,
		"broken": broken,
		"localized": localized,
		"metadata": metadata.duplicate(true),
	}


func to_transformed_dictionary() -> Dictionary:
	var result := to_dictionary()
	result["origin"] = transform * origin
	result["direction"] = transform.basis_xform(direction)
	var transformed_segment := segment
	var segment_start := transform * Vector2(segment.x, segment.y)
	var segment_end := transform * Vector2(segment.z, segment.w)
	transformed_segment = Vector4(segment_start.x, segment_start.y,
			segment_end.x, segment_end.y)
	result["segment"] = transformed_segment
	var transformed_points: Array[Vector2] = []
	for point in points:
		transformed_points.append(transform * point)
	result["points"] = transformed_points
	return result


func duplicate_operation():
	var result = get_script().new()
	result.set_from_dictionary(to_dictionary())
	return result
