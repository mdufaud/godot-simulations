class_name ClothQualityProfile
extends SimQualityProfile
## Quality tiers for the XPBD cloth demo. Six sheets simulate in parallel, so
## the XPBD budget is substeps × iterations over every vertex; the tiers spend
## it from a light solve up to Ultra's stiff, wrinkle-dense cloth. Ultra sits
## at the solver sliders' ceiling — the cost is purely linear.

const ITERATIONS := {
	Tier.LOW: 8,
	Tier.MEDIUM: 14,
	Tier.HIGH: 18,
	Tier.ULTRA: 24,
}

const SUBSTEPS := {
	Tier.LOW: 2,
	Tier.MEDIUM: 4,
	Tier.HIGH: 5,
	Tier.ULTRA: 6,
}

const RENDER_SCALE := {
	Tier.LOW: 0.75,
	Tier.MEDIUM: 0.85,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		iterations = ITERATIONS[tier],
		substeps = SUBSTEPS[tier],
		render_scale = RENDER_SCALE[tier],
	}
