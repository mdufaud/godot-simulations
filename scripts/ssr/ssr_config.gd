class_name SsrConfig extends Resource

@export_range(1, 512, 1) var max_objects: int = 200
@export_range(0.01, 30.0, 0.01) var spawn_interval_s: float = 0.25
@export_range(0.0, 100.0, 0.1) var spawn_height_m: float = 12.0
@export_range(0.0, 100.0, 0.1) var spawn_radius_m: float = 10.0
@export_range(-100.0, 0.0, 0.1) var kill_height_m: float = -12.0


func validate() -> String:
	if max_objects <= 0 or spawn_interval_s <= 0.0:
		return "SSR object budget and spawn interval must be positive"
	if spawn_height_m <= 0.0 or spawn_radius_m < 0.0 or kill_height_m >= 0.0:
		return "SSR spawn and kill bounds are invalid"
	return ""
