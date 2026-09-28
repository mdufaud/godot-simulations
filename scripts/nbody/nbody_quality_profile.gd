class_name NBodyQualityProfile
extends SimQualityProfile
## Quality tiers for the GPU N-body gallery. Low to High use massless test
## particles; Ultra uses direct particle self-gravity on the black-hole disk,
## capped at 32k particles because the pairwise force pass is O(N²).

## Counts the menu proposes, smallest first; 32k is the direct-gravity tier.
const PARTICLE_COUNTS := [16384, 32768, 65536, 262144, 1048576]

const PARTICLE_COUNT := {
	Tier.LOW: 65536,
	Tier.MEDIUM: 262144,
	Tier.HIGH: 1048576,
	Tier.ULTRA: 32768,
}

const SELF_GRAVITY := {
	Tier.LOW: false,
	Tier.MEDIUM: false,
	Tier.HIGH: false,
	Tier.ULTRA: true,
}

## Ceiling the O(N²) pass supports; config.validate refuses larger counts.
const SELF_GRAVITY_MAX := {
	Tier.LOW: 16384,
	Tier.MEDIUM: 16384,
	Tier.HIGH: 16384,
	Tier.ULTRA: 32768,
}

static func values(tier: int) -> Dictionary:
	return {
		particle_count = PARTICLE_COUNT[tier],
		self_gravity = SELF_GRAVITY[tier],
		self_gravity_max = SELF_GRAVITY_MAX[tier],
	}
