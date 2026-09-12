class_name TornadoQualityProfile
extends SimQualityProfile
## Quality tiers for the tornado demo. The funnel is a raymarched volume, so
## the step count is the sharpest lever, then the dust particle systems and
## the debris pool (one Jolt rigid body per slot). Ultra raises the raymarch
## budget past the old UI ceiling — the shader loop is uniform-bound, so any
## step count is legal — and fills the debris pool.

## Dust particle amounts the menu proposes, smallest first.
const DUST_AMOUNTS := [4000, 14000, 28000, 56000]

const RENDER_SCALE := {
	Tier.LOW: 0.6,
	Tier.MEDIUM: 0.75,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}

const RAYMARCH_STEPS := {
	Tier.LOW: 24,
	Tier.MEDIUM: 48,
	Tier.HIGH: 96,
	Tier.ULTRA: 160,
}

const DUST_AMOUNT := {
	Tier.LOW: 4000,
	Tier.MEDIUM: 14000,
	Tier.HIGH: 28000,
	Tier.ULTRA: 56000,
}

const DEBRIS_CAP := {
	Tier.LOW: 80,
	Tier.MEDIUM: 150,
	Tier.HIGH: 250,
	Tier.ULTRA: 400,
}


static func values(tier: int) -> Dictionary:
	return {
		render_scale = RENDER_SCALE[tier],
		raymarch_steps = RAYMARCH_STEPS[tier],
		dust_amount = DUST_AMOUNT[tier],
		debris_cap = DEBRIS_CAP[tier],
	}
