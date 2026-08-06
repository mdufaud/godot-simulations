class_name GrassConfig extends Resource

@export_range(1.0, 100.0, 0.1) var tile_size_m: float = 10.0
@export_range(1.0, 500.0, 1.0) var map_radius_m: float = 80.0
@export_range(0.0, 500.0, 0.1) var shadow_distance_m: float = 40.0
@export_range(0.0, 100.0, 0.01) var heightmap_scale_m: float = 5.0
@export_range(0.0, 1.0, 0.01) var density: float = 1.0
@export_range(0.0, 20.0, 0.01) var wind_speed_mps: float = 1.0


func validate() -> String:
	if tile_size_m <= 0.0 or map_radius_m <= 0.0:
		return "grass tile_size_m and map_radius_m must be positive"
	if shadow_distance_m < 0.0 or heightmap_scale_m < 0.0:
		return "grass distances cannot be negative"
	if density < 0.0 or wind_speed_mps < 0.0:
		return "grass density and wind_speed_mps cannot be negative"
	return ""
