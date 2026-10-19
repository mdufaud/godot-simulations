class_name ApparentScale extends RefCounted
## Pure math of the Superliminal-style grip mechanic: forced perspective sizes,
## commit clamping and the cubic mass law.
##
## Nothing here touches the scene tree, so every rule is testable headless. The
## grab controller (scripts/non_euclidean/grab_controller_3d.gd) and the GripBall
## own the events; these functions own the numbers.
##
##     var r := ApparentScale.hold_radius(r_grab, d_grab, hold_distance)
##     mass = ApparentScale.mass_for(committed_radius, base_radius, base_mass)


## Radius the ball must have at [param distance] to keep the angular size it had
## when grabbed: [code]r / d[/code] stays constant while held.
static func hold_radius(r_grab: float, d_grab: float, distance: float) -> float:
	return r_grab / d_grab * distance


## Clamps a radius into the committed bounds. The only door to the bounds, so
## mesh, collision and mass never disagree on a size.
static func commit_radius(r_current: float, r_min: float, r_max: float) -> float:
	return clampf(r_current, r_min, r_max)


## Mass follows the volume: a ball twice as wide weighs eight times as much, so a
## giant block cannot be pushed around like a balloon.
static func mass_for(radius: float, base_radius: float, base_mass: float) -> float:
	return base_mass * pow(radius / base_radius, 3.0)
