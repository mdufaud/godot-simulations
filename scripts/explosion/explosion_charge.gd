class_name ExplosionCharge extends Resource
## One detonation: the source sphere the solver injects and the pulse that drives it.

@export_range(0.1, 1000.0, 0.05) var radius_m := 1.0
@export_range(300.0, 3000.0, 10.0) var temperature_k := 2400.0
@export_range(0.0, 1.0, 0.01) var fuel_fraction := 0.4
@export_range(0.0, 1.0, 0.01) var soot_fraction := 0.1
## Peak volumetric expansion rate; the pulse decays linearly to zero. Only for a continuous charge or one with growth_ratio 1; a growing charge must leave it 0.
@export_range(0.0, 500.0, 0.001) var divergence_per_s := 0.0
## Final source radius over radius_m. Above 1 the source sphere grows as radius_m + (growth_ratio - 1) * radius_m * (t / formation_s)^0.4 and the flow it drives is that growth; 1 keeps the radius fixed.
@export_range(1.0, 10.0, 0.05) var growth_ratio := 1.0
## Simulated seconds the radius takes to reach its final value; at most pulse_duration_s, 0 when growth_ratio is 1.
@export_range(0.0, 10.0, 0.01) var formation_s := 0.0
## Starts the growth law part way up its curve: the progress is ((t + o)^0.4 - o^0.4) / ((formation_s + o)^0.4 - o^0.4) with o this value, which bounds the speed of the first solver step; 0 is the plain t^0.4 law.
@export_range(0.0, 5.0, 0.01) var formation_offset_s := 0.0
@export_range(0.05, 120.0, 0.01) var pulse_duration_s := 0.4
@export_range(0.5, 6000.0, 0.1) var blast_radius_m := 4.0
@export_range(0.0, 400.0, 0.5) var blast_speed_mps := 12.0
@export_range(0.0, 100.0, 0.5) var flash_energy := 0.0
## Share of a thrown charge's horizontal velocity the source sphere keeps moving with, or, with growth_ratio 1, adds once to the flow in it (capped by the velocity clamp headroom); 0 for a charge that is not thrown.
@export_range(0.0, 1.0, 0.01) var carry_fraction := 0.0
## Re-injected every simulated frame of the pulse and never signalled: a dust or smoke source.
@export var continuous := false
## Depth of the centre below the ground when released as a companion: a flat disc, not a dome.
@export_range(0.0, 100.0, 0.5) var sink_m := 0.0
## Released on the ground under the charge, one frame after it; it may carry a companion of its own.
@export var companion: ExplosionCharge
## Simulated seconds over which a continuous charge's temperature excess and soot ramp up from nothing to full strength, with the cube of the time so that the soot it keeps adding stays faint early on; 0 starts at full strength.
@export_range(0.0, 60.0, 0.1) var onset_s := 0.0
## Companion only: dust thrown up at the shock front. Above 0 the charge is a ring on the ground instead of a sphere: its centre line rides the front outwards at the speed of the charge that released it, from that charge's radius up to this charge's radius_m, where the ring ends; the dust fades out this far either side of the line.
@export_range(0.0, 500.0, 0.5) var front_ring_width_m := 0.0
## Height above the ground over which the ring's dust fades out.
@export_range(0.0, 200.0, 0.5) var front_ring_height_m := 0.0
## Upward speed the front band gives the air it passes through.
@export_range(0.0, 200.0, 0.5) var front_ring_lift_mps := 0.0
## Simulated seconds after release before the afterwind starts to ramp in; its fade-out is timed against the rest of the pulse.
@export_range(0.0, 60.0, 0.1) var afterwind_delay_s := 0.0
## Peak inward ground wind while this charge runs, a return flow towards ground zero; 0 is off.
@export_range(0.0, 100.0, 0.5) var afterwind_mps := 0.0
## Radius of the full-strength afterwind about the charge; it fades out over a quarter of it beyond.
@export_range(0.0, 3000.0, 1.0) var afterwind_radius_m := 0.0
## Depth of the ground layer the afterwind blows in.
@export_range(0.0, 1000.0, 1.0) var afterwind_height_m := 0.0
## Time constant the flow relaxes towards the afterwind speed with.
@export_range(0.0, 20.0, 0.1) var afterwind_tau_s := 0.0


const MAX_COMPANIONS := 8


## False when the companion chain is longer than [constant MAX_COMPANIONS] or loops back on itself.
func chain_is_finite() -> bool:
	var link := self
	for i in MAX_COMPANIONS + 1:
		link = link.companion
		if link == null:
			return true
	return false


func grows() -> bool:
	return growth_ratio > 1.0


func has_front_ring() -> bool:
	return front_ring_width_m > 0.0


## Radius the source sphere ends at.
func final_radius_m() -> float:
	return radius_m * growth_ratio


func validate() -> String:
	if not chain_is_finite():
		return "the companion chain is longer than %d charges or loops" % MAX_COMPANIONS
	if radius_m <= 0.0:
		return "radius_m must be positive"
	if temperature_k <= 0.0:
		return "temperature_k must be positive"
	if fuel_fraction < 0.0 or fuel_fraction > 1.0 or soot_fraction < 0.0 or soot_fraction > 1.0:
		return "fuel_fraction and soot_fraction must be in [0, 1]"
	if pulse_duration_s <= 0.0:
		return "pulse_duration_s must be positive"
	if growth_ratio < 1.0:
		return "growth_ratio must be at least 1"
	if growth_ratio > 1.0:
		if continuous:
			return "growth_ratio must be 1 for a continuous charge"
		if divergence_per_s != 0.0:
			return "divergence_per_s must be 0 when growth_ratio drives the expansion"
		if formation_s <= 0.0 or formation_s > pulse_duration_s:
			return "formation_s must be positive and at most pulse_duration_s"
	elif divergence_per_s <= 0.0:
		return "divergence_per_s must be positive when growth_ratio is 1"
	elif formation_s != 0.0 or formation_offset_s != 0.0:
		return "formation_s and formation_offset_s must be 0 when growth_ratio is 1"
	if blast_radius_m <= 0.0 or blast_speed_mps < 0.0 or flash_energy < 0.0:
		return "blast_radius_m must be positive, blast_speed_mps and flash_energy not negative"
	if onset_s < 0.0 or (onset_s > 0.0 and not continuous):
		return "onset_s must not be negative and needs a continuous charge"
	if onset_s >= pulse_duration_s:
		return "onset_s must be shorter than pulse_duration_s"
	if front_ring_width_m < 0.0 or front_ring_height_m < 0.0 or afterwind_delay_s < 0.0:
		return "front_ring_width_m, front_ring_height_m and afterwind_delay_s must not be negative"
	if front_ring_lift_mps < 0.0:
		return "front_ring_lift_mps must not be negative"
	if has_front_ring() and (front_ring_height_m <= 0.0 or not continuous):
		return "a front ring needs a positive front_ring_height_m and a continuous charge"
	if has_front_ring() and sink_m > 0.0:
		return "a front ring lies on the ground: sink_m must be 0"
	if afterwind_mps > 0.0 and afterwind_delay_s >= pulse_duration_s:
		return "afterwind_delay_s must be shorter than pulse_duration_s"
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
