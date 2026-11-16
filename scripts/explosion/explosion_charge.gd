class_name ExplosionCharge extends Resource
## One detonation: the source sphere the solver injects and the pulse that drives it.

@export_range(0.1, 100.0, 0.05) var radius_m := 1.0
@export_range(300.0, 3000.0, 10.0) var temperature_k := 2400.0
@export_range(0.0, 1.0, 0.01) var fuel_fraction := 0.4
@export_range(0.0, 1.0, 0.01) var soot_fraction := 0.1
## Peak volumetric expansion rate; the pulse decays linearly to zero.
@export_range(0.001, 500.0, 0.001) var divergence_per_s := 80.0
@export_range(0.05, 20.0, 0.01) var pulse_duration_s := 0.4
@export_range(0.5, 500.0, 0.1) var blast_radius_m := 4.0
@export_range(0.0, 100.0, 0.5) var blast_speed_mps := 12.0
@export_range(0.0, 100.0, 0.5) var flash_energy := 0.0
## Re-injected every simulated frame of the pulse and never signalled: a dust or smoke source.
@export var continuous := false
## Depth of the centre below the ground when released as a companion: a flat disc, not a dome.
@export_range(0.0, 100.0, 0.5) var sink_m := 0.0
## Released on the ground under the charge, one frame after it.
@export var companion: ExplosionCharge


func validate() -> String:
	if radius_m <= 0.0:
		return "radius_m must be positive"
	if temperature_k <= 0.0:
		return "temperature_k must be positive"
	if fuel_fraction < 0.0 or fuel_fraction > 1.0 or soot_fraction < 0.0 or soot_fraction > 1.0:
		return "fuel_fraction and soot_fraction must be in [0, 1]"
	if divergence_per_s <= 0.0 or pulse_duration_s <= 0.0:
		return "divergence_per_s and pulse_duration_s must be positive"
	if blast_radius_m <= 0.0 or blast_speed_mps < 0.0 or flash_energy < 0.0:
		return "blast_radius_m must be positive, blast_speed_mps and flash_energy not negative"
	if companion != null:
		return companion.validate()
	return ""
