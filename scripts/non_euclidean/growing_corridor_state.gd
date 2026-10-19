class_name GrowingCorridorState extends RefCounted
## Pure math of the Antichamber-style growing corridor: segment scales in a
## bounded geometric progression and the virtual travel distance.
##
## Nothing here touches the scene tree, so every rule is testable headless. The
## exhibit (scripts/demos/non_euclidean/exhibit_growing_corridor.gd) owns the
## geometry; these functions own the numbers.
##
##     var s := GrowingCorridorState.segment_scale(index, 1.7, 8.0)
##     virtual_distance = GrowingCorridorState.advance(virtual_distance, step, s)


## Segment [param index] scale: [code]s_0 = 1.0[/code], geometric growth clamped
## to [param max_scale] so late segments stay buildable.
static func segment_scale(index: int, growth: float, max_scale: float) -> float:
	return minf(pow(growth, float(index)), max_scale)


## Adds one real step to the virtual distance: a metre walked counts for
## [param local_scale] metres of perceived progression. Callers pass a
## non-negative step, keeping the total monotone.
static func advance(virtual_distance: float, real_step: float, local_scale: float) -> float:
	return virtual_distance + real_step * local_scale
