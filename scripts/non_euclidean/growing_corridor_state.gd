class_name GrowingCorridorState extends RefCounted
## Pure math of the Antichamber-style growing corridor: segment scales in a
## bounded geometric progression, the virtual travel distance, and the
## per-direction state table.
##
## Nothing here touches the scene tree, so every rule is testable headless. The
## exhibit (scripts/demos/non_euclidean/exhibit_growing_corridor.gd) owns the
## geometry; these functions own the numbers.
##
##     var s := GrowingCorridorState.segment_scale(index, 1.7, 8.0)
##     virtual_distance = GrowingCorridorState.advance(virtual_distance, step, s)
##     states = GrowingCorridorState.next_state(states, index, direction)


enum Entered { NONE, FORWARD, BACKWARD }


## Segment [param index] scale: [code]s_0 = 1.0[/code], geometric growth clamped
## to [param max_scale] so late segments stay buildable.
static func segment_scale(index: int, growth: float, max_scale: float) -> float:
	return minf(pow(growth, float(index)), max_scale)


## Adds one real step to the virtual distance: a metre walked counts for
## [param local_scale] metres of perceived progression. Callers pass a
## non-negative step, keeping the total monotone.
static func advance(virtual_distance: float, real_step: float, local_scale: float) -> float:
	return virtual_distance + real_step * local_scale


## Returns a copy of [param states] where the cell at [param cell_index] records
## the [param entered] direction — the hook for serving different content on the
## way back (v1). The input array and its entries are never mutated, and short
## arrays grow on demand so any reachable cell index is valid.
static func next_state(states: Array, cell_index: int, entered: int) -> Array:
	var updated := states.duplicate()
	if entered == Entered.NONE or cell_index < 0:
		return updated
	while updated.size() <= cell_index:
		updated.append({})
	var state: Dictionary = (updated[cell_index] as Dictionary).duplicate()
	if entered == Entered.FORWARD:
		state["forward"] = true
		state["revision"] = int(state.get("revision", 0)) + 1
	else:
		state["backward"] = true
	updated[cell_index] = state
	return updated
