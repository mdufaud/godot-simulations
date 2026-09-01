class_name WrapWorldState extends RefCounted
## Pure math of the Manifold-Garden wrap world: periodic coordinates per axis,
## the offset that brings a stray position back into the cell, and the boundary
## crossing detector.
##
## Nothing here touches the scene tree, so every rule is testable headless. The
## exhibit (scripts/demos/non_euclidean/exhibit_wrap_world.gd) owns the geometry
## and the transports; these functions own the numbers.
##
##     var offset := WrapWorldState.wrap_offset(body.position, PERIODS)
##     position = WrapWorldState.wrap_axis(position.z, PERIODS.z)


## Wraps one coordinate into the cell [code][-period / 2, period / 2)[/code].
## Coordinates stay bounded by construction, so no floating origin is needed.
static func wrap_axis(value: float, period: float) -> float:
	return wrapf(value, -period * 0.5, period * 0.5)


## Translation that brings [param position] back into the periodic cell: zero
## while inside, one full period per axis that crossed a boundary. Adding it to
## the position is the whole wrap.
static func wrap_offset(position: Vector3, periods: Vector3) -> Vector3:
	return Vector3(
		wrap_axis(position.x, periods.x) - position.x,
		wrap_axis(position.y, periods.y) - position.y,
		wrap_axis(position.z, periods.z) - position.z)


## Reads two consecutive wrapped coordinates: [code]+1[/code] when the point
## left through the high boundary ([code]+period / 2[/code], re-entering at the
## low one), [code]-1[/code] through the low boundary, [code]0[/code] on plain
## motion. A genuine crossing always jumps by nearly a full period, which no
## per-frame motion does.
static func crossing(previous: float, current: float, period: float) -> int:
	var delta := current - previous
	if delta < -period * 0.5:
		return 1
	if delta > period * 0.5:
		return -1
	return 0
