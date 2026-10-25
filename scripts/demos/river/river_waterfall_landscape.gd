extends RiverField

const DOMAIN_M := Vector2(24.0, 48.0)
const ZONE_DRY := 0
const ZONE_LOWER_POOL := 1
const ZONE_UPPER_POOL := 2
const ZONE_RAMP := 3
const HEIGHT_M := 6.0
const WIDTH_M := 6.0
const CREST_Z_M := 4.0
const BED_DEPTH_M := 0.65
const RAMP_ROUND_M := 0.35
const BANK_WALL_M := 1.45
const BANK_TOP_M := 2.6
const GORGE_LENGTH_M := 16.0
const PLUNGE_DEPTH_M := 0.7
const PLUNGE_RADIUS_M := 2.2
const PLUNGE_OFFSET_M := 1.8

var angle_degrees := 90.0


func _init(angle: float = 90.0) -> void:
	angle_degrees = clampf(angle, 20.0, 90.0)
	domain_m = DOMAIN_M
	spills = true
	reflection_pools = true
	reflection_anchors_m = Vector4(CREST_Z_M - run_m() - 8.0, CREST_Z_M + 8.0, 0.0, 0.0)
	terrace_heights_m = Vector4.ZERO


func is_vertical() -> bool:
	return angle_degrees >= 90.0


func run_m() -> float:
	if is_vertical():
		return 0.0
	return HEIGHT_M / maxf(tan(deg_to_rad(angle_degrees)), 0.0001)


func channel_center_x(_z: float) -> float:
	return 0.0


func channel_half_width(_z: float) -> float:
	return WIDTH_M * 0.5


func water_zone(point: Vector2) -> int:
	if absf(point.x) > channel_half_width(point.y):
		return ZONE_DRY
	var lower_end := CREST_Z_M - run_m()
	if point.y >= CREST_Z_M:
		return ZONE_UPPER_POOL
	if point.y < lower_end or is_vertical():
		return ZONE_LOWER_POOL
	return ZONE_RAMP


func water_height(point: Vector2, level_m: float) -> float:
	if is_vertical():
		return level_m + (HEIGHT_M if point.y >= CREST_Z_M else 0.0)
	var lower_end := CREST_Z_M - run_m()
	var slope := tan(deg_to_rad(angle_degrees))
	# Parabolic fillets centred on both corners: the bed never gets steeper than the ramp itself.
	var round_m := minf(RAMP_ROUND_M, run_m() * 0.2)
	if point.y <= lower_end - round_m:
		return level_m
	if point.y >= CREST_Z_M + round_m:
		return level_m + HEIGHT_M
	if point.y < lower_end + round_m:
		return level_m + slope * pow(point.y - lower_end + round_m, 2.0) / (4.0 * round_m)
	if point.y > CREST_Z_M - round_m:
		return level_m + HEIGHT_M - slope * pow(CREST_Z_M + round_m - point.y, 2.0) / (4.0 * round_m)
	return level_m + slope * (point.y - lower_end)


func sample_bed(point: Vector2) -> float:
	var edge := absf(point.x) - WIDTH_M * 0.5
	var floor_m := water_height(point, 0.0) - BED_DEPTH_M - plunge_depth(point) * (1.0 - smoothstep(-1.2, -0.2, edge))
	var bank := floor_m + smoothstep(-1.1, 0.15, edge) * BANK_WALL_M
	var outer := smoothstep(0.0, 3.5, edge) * (BANK_TOP_M - BANK_WALL_M) + maxf(edge - 3.0, 0.0) * 0.28
	if point.y >= CREST_Z_M:
		return bank + outer + relief(point) * smoothstep(-0.2, 2.0, edge) * 0.45
	var below := CREST_Z_M - point.y
	var opening := maxf(below - GORGE_LENGTH_M * 0.4, 0.0) * 0.35
	var scarp := below + (3.0 * sin(point.x * 0.31 + 0.7) + 1.4 * sin(point.x * 0.83 - 0.4)) * smoothstep(3.0, 8.0, edge)
	var rim := lerpf(HEIGHT_M - BED_DEPTH_M + BANK_TOP_M, BANK_TOP_M - BED_DEPTH_M, smoothstep(GORGE_LENGTH_M * 0.5, GORGE_LENGTH_M, scarp))
	var wall := smoothstep(0.25 + opening, 2.4 + opening * 1.6, edge)
	var gorge := lerpf(bank, rim + maxf(edge - 3.0, 0.0) * 0.28, wall) + relief(point) * wall * (1.0 - wall) * 1.6
	var plateau := bank + outer
	var blend := 1.2 * smoothstep(0.5, 2.0, edge)
	if blend <= 0.0:
		return maxf(plateau, gorge)
	var h := clampf(0.5 + 0.5 * (plateau - gorge) / blend, 0.0, 1.0)
	return lerpf(gorge, plateau, h) + blend * h * (1.0 - h)


func plunge_depth(point: Vector2) -> float:
	var foot := CREST_Z_M - run_m()
	var center := foot - PLUNGE_OFFSET_M
	var lateral := point.x / (WIDTH_M * 0.42)
	var along := (point.y - center) / PLUNGE_RADIUS_M
	return PLUNGE_DEPTH_M * smoothstep(60.0, 85.0, angle_degrees) * exp(-(lateral * lateral + along * along)) \
		* (1.0 - smoothstep(foot - 0.6, foot + 0.1, point.y))


static func relief(point: Vector2) -> float:
	return 0.5 * sin(point.x * 1.1 + point.y * 0.63) + 0.3 * sin(point.y * 1.87 - point.x * 0.71) + 0.15 * sin((point.x - point.y) * 2.9)


func sample_height(point: Vector2, level_m: float) -> float:
	return water_height(point, level_m)


func sample(point: Vector2, level_m: float) -> Color:
	var zone := water_zone(point)
	if zone == ZONE_DRY:
		return Color(0.0, 0.0, 0.0, 0.0)
	var depth := water_height(point, level_m) - sample_bed(point)
	if depth <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var lateral := absf(point.x) / maxf(channel_half_width(point.y), 0.001)
	var wet := smoothstep(0.0, 0.12, depth) * (1.0 - smoothstep(0.92, 1.0, lateral))
	var velocity_z := -1.0
	if zone == ZONE_RAMP:
		velocity_z *= cos(deg_to_rad(angle_degrees))
	return Color(0.0, velocity_z * wet, 0.0, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	var zone := water_zone(point)
	if zone == ZONE_DRY:
		return Color(0.0, 0.0, 0.0, 0.0)
	var velocity_z := -1.0
	if zone == ZONE_RAMP:
		velocity_z *= cos(deg_to_rad(angle_degrees))
	return Color(0.0, velocity_z, 0.0, 1.0)
