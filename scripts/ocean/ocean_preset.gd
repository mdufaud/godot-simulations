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
## Weight of the long, low-frequency swell relative to the wind sea.
@export_range(0.0, 2.0, 0.01) var swell := 0.8
## Directional spreading: 0 is a narrow, aligned sea, 1 is confused.
@export_range(0.0, 1.0, 0.01) var spread := 0.2
@export_range(0.5, 1.0, 0.01) var detail := 1.0
@export_range(1.0, 7.0, 0.1) var jonswap_gamma := 3.3

@export_group("Waves")
@export_range(0.0, 1.8, 0.01) var choppiness := 1.15
## Overall sea amplitude. 1.0 = the physical JONSWAP amplitude for the wind
## and fetch (the GodotOceanWaves reference look, waves near breaking
## steepness); 0.25 = the old quarter-height calibration. Applied through the
## spectrum alpha, so it scales every band and its derivatives together.
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
	if wind_speed_mps <= 0.0:
		return "wind_speed_mps must be positive"
	if fetch_km <= 0.0:
		return "fetch_km must be positive"
	if detail < 0.5 or detail > 1.0:
		return "detail must be in 0.5..1"
	if jonswap_gamma < 1.0 or jonswap_gamma > 7.0:
		return "jonswap_gamma must be in 1..7"
	if height_gain < 0.0:
		return "height_gain cannot be negative"
	if long_wave_height_m < 0.0 or mid_wave_height_m < 0.0 \
		or wind_wave_height_m < 0.0:
		return "wave-band strengths cannot be negative"
	if long_wave_length_m <= 0.0 or mid_wave_length_m <= 0.0 \
		or wind_wave_length_m <= 0.0:
		return "wave-band lengths must be positive"
	if foam_persistence <= 0.0:
		return "foam_persistence must be positive"
	return ""


## The spectrum stays stale until the caller marks it dirty.
func apply_to(solver: OceanSolver) -> void:
	solver.wave_model = wave_model
	solver.wind_speed = wind_speed_mps
	solver.fetch_km = fetch_km
	solver.swell = swell
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
