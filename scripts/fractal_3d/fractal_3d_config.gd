class_name Fractal3DConfig extends Resource

@export_range(1, 128, 1) var iterations: int = 12
@export_range(1, 4096, 1) var max_steps: int = 480
@export_range(0.001, 1000.0, 0.001) var max_distance_m: float = 60.0
@export_range(0.000001, 1.0, 0.000001) var epsilon_m: float = 0.0001
@export_range(0.1, 10.0, 0.001) var render_scale: float = 0.75
@export_range(0, 2, 1) var quality_profile: int = 0
## Fraction of the free distance in view flown per second.
@export_range(0.1, 15.0, 0.1) var flight_speed_per_s: float = 1.0
## Free distance under which the camera counts as touching a surface.
@export_range(1e-13, 1.0, 1e-13) var min_flight_distance_m: float = 1e-10
## Relative size of the smallest feature the float64 camera orbit places:
## iterations stop adding detail under it.
@export_range(1e-15, 1e-6, 1e-15) var orbit_precision: float = 1e-12


func validate() -> String:
	if iterations <= 0 or max_steps <= 0 or max_distance_m <= 0.0 or epsilon_m <= 0.0:
		return "fractal_3d numeric parameters must be positive"
	if render_scale <= 0.0 or render_scale > 1.0:
		return "render_scale must be within (0, 1]"
	if quality_profile < 0 or quality_profile > 2:
		return "quality_profile is invalid"
	if min_flight_distance_m <= 0.0 or orbit_precision <= 0.0:
		return "fractal_3d precision bounds must be positive"
	if flight_speed_per_s <= 0.0:
		return "flight_speed_per_s must be positive"
	return ""
