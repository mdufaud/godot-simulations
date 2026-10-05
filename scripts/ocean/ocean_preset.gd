class_name OceanPreset extends Resource
## A named sea state: wind, wave shape, foam and spray.
##
## Presets live in [code]resources/ocean/presets/[/code].
##
## [codeblock]
## var preset: OceanPreset = preload("res://resources/ocean/presets/swell.tres")
## preset.apply_to(solver)
## solver.mark_spectrum_dirty()
## [/codeblock]

## Wave generation model. FFT runs all three FFT cascades; TUTORIAL_GERSTNER
## replaces the short cascade with the five periodic tutorial waves and zeroes
## the long/mid ones.
enum WaveModel { FFT, TUTORIAL_GERSTNER }

@export var display_name := "Breeze"

@export var wave_model: WaveModel = WaveModel.FFT

@export_group("Wind")
@export_range(0.5, 35.0, 0.1) var wind_speed_mps := 11.0
## Distance the wind has blown over open water; JONSWAP peaks lower and higher
## as it grows.
@export_range(5.0, 1000.0, 1.0) var fetch_km := 120.0
## Legacy swell factor used in wind-sea directional spreading.
@export_range(0.0, 2.0, 0.01) var swell := 0.8
## Directional spreading: 0 is a narrow, aligned sea, 1 is confused.
@export_range(0.0, 1.0, 0.01) var spread := 0.2
@export_range(0.5, 1.0, 0.01) var detail := 1.0
@export_range(1.0, 7.0, 0.1) var jonswap_gamma := 3.3

@export_group("Independent Swell")
@export_range(0.0, 12.0, 0.05) var swell_height_m := 0.6
@export_range(2.0, 30.0, 0.1) var swell_period_s := 10.0
@export_range(-3.14159, 3.14159, 0.01) var swell_direction_rad := 0.35
@export_range(0.01, 1.0, 0.01) var swell_spread := 0.15
@export var current_velocity_m_s := Vector2.ZERO

@export_group("Waves")
@export_range(0.0, 1.8, 0.01) var choppiness := 1.15
## Overall amplitude multiplier for the combined wind sea and independent swell.
@export_range(0.1, 2.0, 0.05) var amplitude_scale := 1.0
@export_range(0.0, 5.0, 0.01) var height_gain := 1.0
@export_range(0.0, 10.0, 0.01) var long_wave_height_m := 2.6
@export_range(5.0, 200.0, 0.5) var long_wave_length_m := 48.0
@export_range(0.0, 5.0, 0.01) var mid_wave_height_m := 0.0
@export_range(5.0, 100.0, 0.5) var mid_wave_length_m := 24.0
@export_range(0.0, 5.0, 0.01) var wind_wave_height_m := 0.8
@export_range(1.0, 30.0, 0.1) var wind_wave_length_m := 7.5
@export_range(0.0, 0.8, 0.01) var crest_bias := 0.08
@export_range(0.1, 8.0, 0.05) var crest_gain := 2.4

@export_group("Foam")
## Jacobian threshold under which a folding wave face turns to foam.
@export_range(0.0, 2.0, 0.01) var whitecap := 0.82
@export_range(0.0, 10.0, 0.01) var foam_amount := 3.5
@export_range(0.1, 15.0, 0.1) var foam_persistence := 5.0
@export_range(0.0, 2.0, 0.01) var spray_amount := 0.1

@export_group("Mood")
## Storm mood the host drives on apply: 0 is clear sky, 1 is full storm
## (overcast, rain, lightning). Solver state it is not; the controller reads it.
@export_range(0.0, 1.0, 0.01) var storm_mood := 0.0

func validate() -> String:
	for property: Dictionary in get_property_list():
		var usage: int = property.usage
		if not usage & PROPERTY_USAGE_SCRIPT_VARIABLE or not usage & PROPERTY_USAGE_STORAGE:
			continue
		var field: String = property.name
		if property.type == TYPE_FLOAT:
			var value: float = get(field)
			if not is_finite(value):
				return "%s must be finite" % field
			if property.hint == PROPERTY_HINT_RANGE:
				var limits: PackedStringArray = String(property.hint_string).split(",")
				if limits.size() >= 2:
					var minimum: float = float(limits[0])
					var maximum: float = float(limits[1])
					if value < minimum or value > maximum:
						return "%s must be in %s..%s" % [field, minimum, maximum]
		elif field == "current_velocity_m_s" and not current_velocity_m_s.is_finite():
			return "current_velocity_m_s must be finite"
		elif field == "wave_model":
			var enum_values: PackedStringArray = String(property.hint_string).split(",")
			if wave_model < 0 or wave_model >= enum_values.size():
				return "wave_model is invalid"
	return ""


## The spectrum stays stale until the caller marks it dirty.
func apply_to(solver: OceanSolver) -> void:
	solver.wave_model = wave_model
	solver.wind_speed = wind_speed_mps
	solver.fetch_km = fetch_km
	solver.swell = swell
	solver.swell_height_m = swell_height_m
	solver.swell_period_s = swell_period_s
	solver.swell_direction_rad = swell_direction_rad
	solver.swell_spread = swell_spread
	solver.current_velocity_m_s = current_velocity_m_s
	solver.spread = spread
	solver.detail = detail
	solver.jonswap_gamma = jonswap_gamma
	solver.choppiness = choppiness
	solver.amplitude_scale = amplitude_scale
	solver.height_gain = height_gain
	solver.long_wave_height_m = long_wave_height_m
	solver.long_wave_length_m = long_wave_length_m
	solver.mid_wave_height_m = mid_wave_height_m
	solver.mid_wave_length_m = mid_wave_length_m
	solver.wind_wave_height_m = wind_wave_height_m
	solver.wind_wave_length_m = wind_wave_length_m
	solver.crest_bias = crest_bias
	solver.crest_gain = crest_gain
	solver.whitecap = whitecap
	solver.foam_amount = foam_amount
	solver.foam_persistence = foam_persistence
