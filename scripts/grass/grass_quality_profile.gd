class_name GrassQualityProfile
extends SimQualityProfile
## Quality tiers of the grass demo. Blade density multiplies the per-tile
## instance counts (the fill is a GDScript pass over the tile map, so Ultra's
## 1.5x buys a one-off hitch at generation time); the shadow casters are the
## near-field tiles inside [member GrassConfig.shadow_distance_m], so shrinking
## that radius is the cheap iGPU lever.

const DENSITY := {Tier.LOW: 0.4, Tier.MEDIUM: 0.7, Tier.HIGH: 1.0, Tier.ULTRA: 1.5}
const SHADOWS := {Tier.LOW: false, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const SHADOW_DISTANCE_M := {
	Tier.LOW: 20.0, Tier.MEDIUM: 30.0, Tier.HIGH: 40.0, Tier.ULTRA: 60.0,
}
const RENDER_SCALE := {
	Tier.LOW: 0.75, Tier.MEDIUM: 0.85, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		density = DENSITY[tier],
		shadows = SHADOWS[tier],
		shadow_distance_m = SHADOW_DISTANCE_M[tier],
		render_scale = RENDER_SCALE[tier],
	}
