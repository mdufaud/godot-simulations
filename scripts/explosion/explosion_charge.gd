class_name ExplosionCharge extends Resource
## One detonation: the source sphere the solver injects and the pulse that drives it.

@export_range(0.1, 1000.0, 0.05) var radius_m := 1.0
@export_range(300.0, 3000.0, 10.0) var temperature_k := 2400.0
@export_range(0.0, 1.0, 0.01) var fuel_fraction := 0.4
@export_range(0.0, 1.0, 0.01) var soot_fraction := 0.1
## Peak volumetric expansion rate; the pulse decays linearly to zero.
@export_range(0.001, 500.0, 0.001) var divergence_per_s := 80.0
@export_range(0.05, 120.0, 0.01) var pulse_duration_s := 0.4
@export_range(0.5, 6000.0, 0.1) var blast_radius_m := 4.0
@export_range(0.0, 400.0, 0.5) var blast_speed_mps := 12.0
@export_range(0.0, 100.0, 0.5) var flash_energy := 0.0
## Share of a thrown charge's horizontal velocity added once to the flow in the source sphere, capped by the velocity clamp headroom; 0 for a charge that is not thrown.
@export_range(0.0, 1.0, 0.01) var carry_fraction := 0.0
## Re-injected every simulated frame of the pulse and never signalled: a dust or smoke source.
@export var continuous := false
## Depth of the centre below the ground when released as a companion: a flat disc, not a dome.
@export_range(0.0, 100.0, 0.5) var sink_m := 0.0
## Released on the ground under the charge, one frame after it, or [member delay_s] of simulated time after it.
@export var companion: ExplosionCharge
## Simulated seconds a companion waits after its parent before it is released; 0 releases it with the next frame.
@export_range(0.0, 60.0, 0.1) var delay_s := 0.0
## Peak inward ground wind while this charge runs, a return flow towards ground zero; 0 is off.
@export_range(0.0, 100.0, 0.5) var afterwind_mps := 0.0
## Radius of the full-strength afterwind about the charge; it fades out over a quarter of it beyond.
@export_range(0.0, 3000.0, 1.0) var afterwind_radius_m := 0.0
## Depth of the ground layer the afterwind blows in.
@export_range(0.0, 1000.0, 1.0) var afterwind_height_m := 0.0
## Time constant the flow relaxes towards the afterwind speed with.
@export_range(0.0, 20.0, 0.1) var afterwind_tau_s := 0.0


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
	if delay_s < 0.0:
		return "delay_s must not be negative"
	if carry_fraction < 0.0 or carry_fraction > 1.0:
		return "carry_fraction must be in [0, 1]"
	if carry_fraction > 0.0 and continuous:
		return "carry_fraction must be 0 for a continuous charge"
	if afterwind_mps < 0.0 or afterwind_radius_m < 0.0 or afterwind_height_m < 0.0 or afterwind_tau_s < 0.0:
		return "afterwind values must not be negative"
	if afterwind_mps > 0.0 and (afterwind_radius_m <= 0.0 or afterwind_height_m <= 0.0 or afterwind_tau_s <= 0.0):
		return "afterwind_radius_m, afterwind_height_m and afterwind_tau_s must be positive when afterwind_mps is"
	if companion != null:
		return companion.validate()
	return ""
