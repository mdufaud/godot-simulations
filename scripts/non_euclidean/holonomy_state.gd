class_name HolonomyState extends RefCounted
## Pure math of the holonomy square: four portal pairs chained in a cycle, and
## the quarter turn their composition leaves behind.
##
## Every pair mapping is rigid ([code]PortalMath.mapping[/code]), so the loop is
## rigid too — the curvature lives in the connectivity, never in a transform.
## With every portal mounted at the same local pose in its vault the four
## mappings telescope to the identity. Mounting the return vault's portal one
## quarter turn off that coherent orientation leaves a pure 90° rotation about
## the vertical through the first portal: walk the loop, come back turned.
##
##     var loop := HolonomyState.loop_mapping(m12, m23, m34, m41)
##     var quarter_turns := HolonomyState.turn_angle(loop) / (PI * 0.5)


## Composition of the four pair mappings along the walk 1→2→3→4→1: crossing
## P12, then P23, then P34, then P41 applies [code]m41·m34·m23·m12[/code] to
## the traveller — the last crossing maps first.
static func loop_mapping(m12: Transform3D, m23: Transform3D, m34: Transform3D,
		m41: Transform3D) -> Transform3D:
	return m41 * m34 * m23 * m12


## Angle in radians of a loop mapping that is a pure turn about Y — the
## holonomy readout. Positive follows [code]Basis(Vector3.UP, angle)[/code].
static func turn_angle(loop: Transform3D) -> float:
	return atan2(loop.basis.z.x, loop.basis.z.z)
