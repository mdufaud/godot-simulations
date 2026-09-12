class_name AmbientFluidQualityProfile
extends SimQualityProfile
## Quality tiers of the ambient-fluid (buoyancy/BEM) demo. The body cap bounds
## both the physics population and the per-body BEM cost; MSAA and render
## scale live on the root viewport through ViewportGuard.

const MAX_OBJECTS := {Tier.LOW: 8, Tier.MEDIUM: 16, Tier.HIGH: 24, Tier.ULTRA: 40}
const RENDER_SCALE := {
	Tier.LOW: 0.75, Tier.MEDIUM: 0.85, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}
const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_2X,
	Tier.HIGH: Viewport.MSAA_2X,
	Tier.ULTRA: Viewport.MSAA_4X,
}


static func values(tier: int) -> Dictionary:
	return {
		max_objects = MAX_OBJECTS[tier],
		render_scale = RENDER_SCALE[tier],
		msaa = MSAA[tier],
	}
