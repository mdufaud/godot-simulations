class_name RiverWaterfallConfig extends Resource

const LANE_COUNT := 48
const FILM_CELLS := 63
const PACKET_CAPACITY := 256
const EMISSION_RATE_HZ := 120.0

@export_range(20.0, 90.0, 0.1) var angle_degrees := 90.0
@export var height_m := 6.0
@export var width_m := 6.0
@export var crest_z_m := 4.0
@export var lane_count := LANE_COUNT
@export var film_cells := FILM_CELLS
@export var packet_capacity := PACKET_CAPACITY
@export var emission_rate_hz := EMISSION_RATE_HZ


func validate() -> String:
	if not is_finite(angle_degrees) or angle_degrees < 20.0 or angle_degrees > 90.0:
		return "Waterfall angle must be between 20 and 90 degrees."
	if not is_finite(height_m) or not is_finite(width_m) or not is_finite(crest_z_m) \
			or height_m <= 0.0 or width_m <= 0.0:
		return "Waterfall height and width must be finite and positive."
	if lane_count != LANE_COUNT or film_cells != FILM_CELLS or packet_capacity != PACKET_CAPACITY \
			or not is_equal_approx(emission_rate_hz, EMISSION_RATE_HZ):
		return "Waterfall simulation dimensions must match the compiled flow kernel."
	return ""


func is_vertical() -> bool:
	return angle_degrees >= 90.0


func run_m() -> float:
	if is_vertical():
		return 0.0
	return height_m / maxf(tan(deg_to_rad(angle_degrees)), 0.0001)


func length_m() -> float:
	return height_m / maxf(sin(deg_to_rad(angle_degrees)), 0.0001)


func normal() -> Vector3:
	var angle := deg_to_rad(angle_degrees)
	return Vector3(0.0, cos(angle), -sin(angle))


func tangent() -> Vector3:
	var angle := deg_to_rad(angle_degrees)
	return Vector3(0.0, -sin(angle), -cos(angle))
