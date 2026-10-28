class_name SoftBodyQualityProfile
extends SimQualityProfile
## Quality tiers for the soft body demo. The lattice cell sets the vertex count
## (cubic in its inverse), the solve costs substeps x iterations x 8 colour
## passes over it, and the pool caps how many bodies a scene can drop.

const LATTICE_CELL_M := {Tier.LOW: 0.1, Tier.MEDIUM: 0.08, Tier.HIGH: 0.065, Tier.ULTRA: 0.05}
const SUBSTEPS := {Tier.LOW: 2, Tier.MEDIUM: 2, Tier.HIGH: 3, Tier.ULTRA: 4}
const ITERATIONS := {Tier.LOW: 6, Tier.MEDIUM: 8, Tier.HIGH: 10, Tier.ULTRA: 12}
const MAX_BODIES := {Tier.LOW: 8, Tier.MEDIUM: 12, Tier.HIGH: 16, Tier.ULTRA: 24}
const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_2X,
	Tier.HIGH: Viewport.MSAA_4X,
	Tier.ULTRA: Viewport.MSAA_4X,
}


static func values(tier: int) -> Dictionary:
	return {
		lattice_cell_m = LATTICE_CELL_M[tier],
		substeps = SUBSTEPS[tier],
		iterations = ITERATIONS[tier],
		max_bodies = MAX_BODIES[tier],
		msaa = MSAA[tier],
	}
