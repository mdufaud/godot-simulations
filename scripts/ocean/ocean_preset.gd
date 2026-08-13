class_name OceanPreset extends Resource
## A named sea state: the wind that raises it, the shape of the resulting waves,
## how much foam they carry, and how dark the sky over them gets.
##
## Presets live in [code]resources/ocean/presets/[/code].
##
## [codeblock]
## var preset: OceanPreset = preload("res://resources/ocean/presets/swell.tres")
## preset.apply_to(solver)
## solver.mark_spectrum_dirty()
## [/codeblock]

@export var display_name := "Breeze"

@export_group("Wind")
@export_range(0.5, 35.0, 0.1) var wind_speed_mps := 11.0
## Distance the wind has blown over open water; JONSWAP peaks lower and higher
## as it grows.
@export_range(5.0, 1000.0, 1.0) var fetch_km := 120.0
## Weight of the long, low-frequency swell relative to the wind sea.
@export_range(0.0, 2.0, 0.01) var swell := 0.8
## Directional spreading: 0 is a narrow, aligned sea, 1 is confused.
@export_range(0.0, 1.0, 0.01) var spread := 0.2

@export_group("Waves")
@export_range(0.0, 1.8, 0.01) var choppiness := 1.15
@export_range(0.0, 5.0, 0.01) var height_gain := 1.0
@export_range(0.0, 10.0, 0.01) var long_wave_height_m := 2.6
@export_range(5.0, 200.0, 0.5) var long_wave_length_m := 48.0
@export_range(0.0, 5.0, 0.01) var wind_wave_height_m := 0.8
@export_range(1.0, 30.0, 0.1) var wind_wave_length_m := 7.5
@export_range(0.0, 3.0, 0.01) var ripple_strength := 0.9
@export_range(0.0, 0.65, 0.01) var crosswind_ratio := 0.14
@export_range(0.0, 0.8, 0.01) var crest_bias := 0.08
@export_range(0.1, 8.0, 0.05) var crest_gain := 2.4

@export_group("Foam")
## Jacobian threshold under which a folding wave face turns to foam.
@export_range(0.0, 2.0, 0.01) var whitecap := 0.82
@export_range(0.0, 10.0, 0.01) var foam_amount := 3.5
@export_range(0.1, 15.0, 0.1) var foam_persistence := 5.0
@export_range(0.0, 2.0, 0.01) var spray_amount := 0.1

@export_group("Surface")
@export var deep_color := Color(0.018, 0.105, 0.14)
@export var subsurface_color := Color(0.055, 0.39, 0.34)
@export var foam_color := Color(0.78, 0.84, 0.81)
@export_range(0.02, 0.8, 0.01) var roughness := 0.16
@export_range(0.002, 0.06, 0.001) var sun_glitter_size := 0.018
@export_range(0.0, 2.0, 0.01) var sun_glitter_intensity := 0.7

@export_group("Sky")
## 0 is a clear sky, 1 a black storm with lightning. Drives the demo's dressing
## only; the solver never reads it.
@export_range(0.0, 1.0, 0.01) var storm_mood := 0.15


func validate() -> String:
	if wind_speed_mps <= 0.0:
		return "wind_speed_mps must be positive"
	if fetch_km <= 0.0:
		return "fetch_km must be positive"
	if height_gain < 0.0:
		return "height_gain cannot be negative"
	if long_wave_height_m < 0.0 or wind_wave_height_m < 0.0 or ripple_strength < 0.0:
		return "wave-band strengths cannot be negative"
	if long_wave_length_m <= 0.0 or wind_wave_length_m <= 0.0:
		return "wave-band lengths must be positive"
	if foam_persistence <= 0.0:
		return "foam_persistence must be positive"
	if storm_mood < 0.0 or storm_mood > 1.0:
		return "storm_mood (%f) must be within 0..1" % storm_mood
	return ""


## Sea state only. [member storm_mood] is the host's business, and the spectrum
## stays stale until the caller marks it dirty.
func apply_to(solver: OceanSolver) -> void:
	solver.wind_speed = wind_speed_mps
	solver.fetch_km = fetch_km
	solver.swell = swell
	solver.spread = spread
	solver.choppiness = choppiness
	solver.height_gain = height_gain
	solver.long_wave_height_m = long_wave_height_m
	solver.long_wave_length_m = long_wave_length_m
	solver.wind_wave_height_m = wind_wave_height_m
	solver.wind_wave_length_m = wind_wave_length_m
	solver.ripple_strength = ripple_strength
	solver.crosswind_ratio = crosswind_ratio
	solver.crest_bias = crest_bias
	solver.crest_gain = crest_gain
	solver.whitecap = whitecap
	solver.foam_amount = foam_amount
	solver.foam_persistence = foam_persistence
