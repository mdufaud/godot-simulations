class_name GrowingCorridorState extends RefCounted
## Pure math of the accordion corridor: where a point of the real, straight
## corridor is drawn, seen from the player's depth.
##
## Within [param rigid] metres of the player nothing moves, so walking and
## collision stay euclidean. Beyond, real depth folds onto a finite span: the
## offset saturates at [code]rigid + stretch[/code], packing the far arches
## tighter and tighter like a closed bellows. [method stretch] widens that span
## as the player advances, so the far end recedes while the folds open ahead —
## the corridor grows without a single seam.
##
## Nothing here touches the scene tree, so every rule is testable headless. The
## corridor shader (shaders/non_euclidean/corridor_stretch.gdshader) mirrors
## [method apparent_offset] per vertex.
##
##     var a := GrowingCorridorState.stretch(depth, 12.0, 0.45, 70.0)
##     var drawn := GrowingCorridorState.apparent_offset(real - depth, 6.0, a)


## Bellows length for a player [param depth] metres into the corridor: [param
## base] at the start, widened by [param rate] per metre walked, capped at
## [param max_stretch].
static func stretch(depth: float, base: float, rate: float, max_stretch: float) -> float:
	return clampf(base + rate * maxf(depth, 0.0), base, max_stretch)


## Drawn offset of a point [param offset] metres ahead of the player (negative
## behind). Identity inside the rigid span, then an exponential fold with unit
## slope at the joint, odd and bounded by [code]rigid + stretch_length[/code].
static func apparent_offset(offset: float, rigid: float, stretch_length: float) -> float:
	var distance := absf(offset)
	if distance <= rigid:
		return offset
	return signf(offset) * (rigid + stretch_length * (1.0 - exp(-(distance - rigid) / stretch_length)))


## Local compression of the drawing: 1 inside the rigid span, then
## [code]exp(-(|offset| - rigid) / stretch_length)[/code].
static func apparent_slope(offset: float, rigid: float, stretch_length: float) -> float:
	var distance := absf(offset)
	if distance <= rigid:
		return 1.0
	return exp(-(distance - rigid) / stretch_length)
