class_name FluidQualityProfile
extends SimQualityProfile
## Quality tiers for the screen-space fluid demo. The budget splits between
## particles (solver + impostor texture) and the water pipeline (five
## sub-viewports whose cost scales with the square of the water render scale).
## Ultra is the only tier past the impostor texture's default 256²: 131k
## particles need a 512² position texture, or INSTANCE_ID texel lookups wrap.

## Counts the menu proposes, smallest first.
const PARTICLE_COUNTS := [16384, 32768, 65536, 131072]

const PARTICLE_COUNT := {
	Tier.LOW: 16384,
	Tier.MEDIUM: 32768,
	Tier.HIGH: 65536,
	Tier.ULTRA: 131072,
}

## Position texture side; must cover particle_count (count <= width²).
const TEXTURE_WIDTH := {
	Tier.LOW: 256,
	Tier.MEDIUM: 256,
	Tier.HIGH: 256,
	Tier.ULTRA: 512,
}

## Screen-space water pipeline scale (depth/thickness/foam sub-viewports).
const WATER_SCALE := {
	Tier.LOW: 0.35,
	Tier.MEDIUM: 0.5,
	Tier.HIGH: 0.75,
	Tier.ULTRA: 0.9,
}

## Root viewport scale (FSR), on top of the water pipeline.
const RENDER_SCALE := {
	Tier.LOW: 0.75,
	Tier.MEDIUM: 0.85,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		particle_count = PARTICLE_COUNT[tier],
		texture_width = TEXTURE_WIDTH[tier],
		water_scale = WATER_SCALE[tier],
		render_scale = RENDER_SCALE[tier],
	}
