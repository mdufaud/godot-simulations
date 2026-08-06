class_name Fractal3DConfig extends Resource

@export_range(1, 128, 1) var iterations: int = 12
@export_range(1, 4096, 1) var max_steps: int = 480
@export_range(0.001, 1000.0, 0.001) var max_distance_m: float = 60.0
@export_range(0.000001, 1.0, 0.000001) var epsilon_m: float = 0.0001
@export_range(0.1, 10.0, 0.001) var render_scale: float = 0.75
@export_range(0, 2, 1) var quality_profile: int = 0


func validate() -> String:
	if iterations <= 0 or max_steps <= 0 or max_distance_m <= 0.0 or epsilon_m <= 0.0:
		return "fractal_3d numeric parameters must be positive"
	if render_scale <= 0.0 or render_scale > 1.0:
		return "render_scale must be within (0, 1]"
	if quality_profile < 0 or quality_profile > 2:
		return "quality_profile is invalid"
	return ""
