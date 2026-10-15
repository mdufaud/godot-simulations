class_name RiverConfig extends Resource

@export var display_name: String = "Natural Flow"
@export_range(0.0, 4.0, 0.01) var speed_m_s: float = 0.85
@export_range(-0.2, 0.65, 0.01) var water_level_m: float = 0.06
@export_range(0.0, 1.0, 0.01) var clarity: float = 0.82
@export_range(0.0, 2.0, 0.01) var foam_amount: float = 0.65
@export_range(0.0, 1.0, 0.01) var mist_density: float = 0.6
@export_range(0.0, 0.18, 0.001) var ripple_height_m: float = 0.035
@export_range(0.02, 0.5, 0.01) var roughness: float = 0.085
@export_range(0.0, 1.0, 0.01) var whitewater_strength: float = 0.12
@export var deep_color: Color = Color(0.035, 0.19, 0.17)


func validate() -> String:
	if not is_finite(speed_m_s) or speed_m_s < 0.0 or speed_m_s > 4.0:
		return "River speed must be between 0 and 4 m/s"
	if not is_finite(water_level_m) or water_level_m < -0.2 or water_level_m > 0.65:
		return "River level must be between -0.2 and 0.65 m"
	if not is_finite(clarity) or clarity < 0.0 or clarity > 1.0:
		return "River clarity must be between 0 and 1"
	if not is_finite(foam_amount) or foam_amount < 0.0 or foam_amount > 2.0:
		return "River foam amount must be between 0 and 2"
	if not is_finite(mist_density) or mist_density < 0.0 or mist_density > 1.0:
		return "Waterfall mist density must be between 0 and 1"
	if not is_finite(ripple_height_m) or ripple_height_m < 0.0 or ripple_height_m > 0.18:
		return "River ripple height must be between 0 and 0.18 m"
	if not is_finite(roughness) or roughness < 0.02 or roughness > 0.5:
		return "River roughness must be between 0.02 and 0.5"
	if not is_finite(whitewater_strength) or whitewater_strength < 0.0 or whitewater_strength > 1.0:
		return "River whitewater strength must be between 0 and 1"
	return ""
