class_name FractalConfig extends Resource

@export_range(1, 4096, 1) var refine_band_rows: int = 256
@export_range(0.01, 10.0, 0.01) var settle_time_s: float = 0.1
@export_range(0.001, 1000000.0, 0.001) var perturbation_zoom_threshold: float = 1000.0


func validate() -> String:
	if refine_band_rows <= 0:
		return "fractal band budget must be positive"
	if settle_time_s <= 0.0 or perturbation_zoom_threshold <= 0.0:
		return "fractal timing and zoom threshold must be positive"
	return ""
