class_name WildfireConfig extends Resource
## Budgets and rendering knobs for the cheap "game fire" stack
## (see docs/game_fire_rdr2_model.md). Per-fire looks live in WildfirePreset.

@export_group("Layer LOD (distances in m)")
@export_range(5.0, 200.0, 5.0) var ember_cutoff_m: float = 50.0
@export_range(5.0, 300.0, 5.0) var flame_cutoff_m: float = 80.0
@export_range(5.0, 300.0, 5.0) var smoke_cutoff_m: float = 90.0
@export_range(5.0, 120.0, 5.0) var haze_cutoff_m: float = 35.0
@export_range(5.0, 120.0, 5.0) var light_cutoff_m: float = 30.0

@export_group("Heat haze")
@export_range(0.0, 0.2, 0.005) var haze_strength: float = 0.024
@export_range(0.5, 8.0, 0.1) var haze_height_m: float = 3.0

@export_group("Fire fog")
## Volumetric-fog density of the smoky air cloud the firelight scatters in.
@export_range(0.0, 1.0, 0.005) var fire_fog_density_per_m: float = 0.015

@export_group("Intensity envelope")
@export_range(0.2, 10.0, 0.1) var ignite_rate_per_s: float = 2.5
@export_range(0.2, 10.0, 0.1) var extinguish_rate_per_s: float = 1.5


func validate() -> String:
	if haze_height_m <= 0.0:
		return "haze_height_m must be positive"
	return ""
