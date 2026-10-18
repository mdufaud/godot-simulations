extends RiverField

const DEPTH_M := 0.3
const FLOOR_HALF_WIDTH_M := 1.2
const BANK_GRADE := 1.5
const BANK_HEIGHT_M := 1.2
const BEND_SHIFT_M := 4.0
const BEND_LENGTH_M := 8.0

var grade := 0.05
var downstream := Vector2(0.0, -1.0)


func _init(channel_grade: float, flow_direction: Vector2, size_m: Vector2) -> void:
	grade = channel_grade
	downstream = flow_direction.normalized()
	domain_m = size_m


func sample_bed(point: Vector2) -> float:
	var lateral := absf(_lateral_m(point))
	return _surface_m(point) - DEPTH_M + minf(maxf(lateral - FLOOR_HALF_WIDTH_M, 0.0) * BANK_GRADE, BANK_HEIGHT_M)


func sample_height(point: Vector2, level_m: float) -> float:
	return _surface_m(point) + level_m


func sample(point: Vector2, level_m: float) -> Color:
	var wet := smoothstep(0.0, 0.12, sample_height(point, level_m) - sample_bed(point))
	var flow := _tangent(point) * wet
	return Color(flow.x, flow.y, 0.0, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	var flow := _tangent(point)
	return Color(flow.x, flow.y, 0.0, 1.0)


func _along_m(point: Vector2) -> float:
	return point.dot(downstream)


func _surface_m(point: Vector2) -> float:
	return -grade * _along_m(point)


func _bend_slope(along_m: float) -> float:
	var t := clampf((along_m + BEND_LENGTH_M) / (2.0 * BEND_LENGTH_M), 0.0, 1.0)
	return BEND_SHIFT_M * 6.0 * t * (1.0 - t) / (2.0 * BEND_LENGTH_M)


func _lateral_m(point: Vector2) -> float:
	var along := _along_m(point)
	var offset := point.dot(downstream.orthogonal()) - BEND_SHIFT_M * smoothstep(-BEND_LENGTH_M, BEND_LENGTH_M, along)
	return offset * cos(atan(_bend_slope(along)))


func _tangent(point: Vector2) -> Vector2:
	return (downstream + downstream.orthogonal() * _bend_slope(_along_m(point))).normalized()
