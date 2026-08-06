class_name TornadoConfig extends Resource

@export var model: int = TornadoWindField.Model.BURGERS_ROTT
@export_range(1.0, 300.0, 0.1) var maximum_wind_mps: float = 85.0
@export_range(0.1, 200.0, 0.1) var core_radius_m: float = 45.0
@export_range(1.0, 2000.0, 1.0) var height_m: float = 550.0
@export_range(0.0, 8.0, 0.01) var flare: float = 2.5
@export_range(0.001, 2.0, 0.001) var radial_inflow: float = 0.15
@export_range(0.0, 2.0, 0.01) var centerline_s_curve: float = 0.15
@export_range(0.0, 2.0, 0.01) var wander_speed_hz: float = 0.3
@export_range(0.0, 1000.0, 1.0) var wander_radius_m: float = 120.0


func validate() -> String:
	if maximum_wind_mps <= 0.0 or core_radius_m <= 0.0 or height_m <= 0.0:
		return "tornado size and wind must be positive"
	if radial_inflow <= 0.0:
		return "radial_inflow must be positive"
	return ""
