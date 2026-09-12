class_name NBodyQualityProfile
extends SimQualityProfile
## Quality tiers for the GPU N-body galaxy. The count and the physics mode are
## one decision: self-gravity is the O(N²) tiled pass and its particle ceiling
## (32k costs ~24 ms on the 760M iGPU), so Low to High spend the budget on
## density — bigger attractor-driven galaxies — and Ultra is the only tier
## that gives up nothing: full direct gravity at its largest supported count.

## Counts the menu proposes, smallest first; 32k exists so the gravity tiers
## and manual gravity toggles have a label to land on.
const PARTICLE_COUNTS := [32768, 65536, 262144, 1048576]

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

## Ceiling the O(N²) pass supports; config.validate refuses counts above it
## while self-gravity is on.
const SELF_GRAVITY_MAX := {
	Tier.LOW: 16384,
	Tier.MEDIUM: 16384,
	Tier.HIGH: 16384,
	Tier.ULTRA: 32768,
}

const RENDER_SCALE := {
	Tier.LOW: 0.75,
	Tier.MEDIUM: 0.85,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		particle_count = PARTICLE_COUNT[tier],
		self_gravity = SELF_GRAVITY[tier],
		self_gravity_max = SELF_GRAVITY_MAX[tier],
		render_scale = RENDER_SCALE[tier],
	}
