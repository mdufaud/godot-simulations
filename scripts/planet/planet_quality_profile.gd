class_name PlanetQualityProfile
extends SimQualityProfile
## Quality tiers for the procedural planet. The marching-cubes density grid
## drives both the generation cost (dispatch + readback) and the mesh triangle
## count, so the resolution is the main lever; surface detail octaves and the
## root render scale carry the rest. Shape — layers, noise — stays with the
## content presets; tiers never touch it.

## Density grid sides the menu proposes, smallest first.
const RESOLUTIONS: Array[int] = [64, 96, 128, 160, 256]

const RESOLUTION := {
	Tier.LOW: 64,
	Tier.MEDIUM: 96,
	Tier.HIGH: 160,
	Tier.ULTRA: 256,
}

const DETAIL_OCTAVES := {
	Tier.LOW: 3.0,
	Tier.MEDIUM: 5.0,
	Tier.HIGH: 6.0,
	Tier.ULTRA: 8.0,
}

const RENDER_SCALE := {
	Tier.LOW: 0.66,
	Tier.MEDIUM: 0.8,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		resolution = RESOLUTION[tier],
		detail_octaves = DETAIL_OCTAVES[tier],
		render_scale = RENDER_SCALE[tier],
	}
