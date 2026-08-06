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

@export_group("Foam")
## Jacobian threshold under which a folding wave face turns to foam.
@export_range(0.0, 2.0, 0.01) var whitecap := 0.82
@export_range(0.0, 10.0, 0.01) var foam_amount := 3.5

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
	solver.whitecap = whitecap
	solver.foam_amount = foam_amount
