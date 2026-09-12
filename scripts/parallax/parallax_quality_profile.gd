class_name ParallaxQualityProfile
extends SimQualityProfile
## Quality tiers of the parallax demo. Every surface preset carries its own
## raymarch step counts, so the tiers store factors around the preset's base
## values instead of stomping them (clamped to the shader's 128-step loop):
## Low halves the marching, Ultra doubles the head-on budget.

const MIN_LAYER_FACTOR := {
	Tier.LOW: 0.5, Tier.MEDIUM: 1.0, Tier.HIGH: 1.0, Tier.ULTRA: 1.5,
}
const MAX_LAYER_FACTOR := {
	Tier.LOW: 0.5, Tier.MEDIUM: 0.75, Tier.HIGH: 1.0, Tier.ULTRA: 2.0,
}
const SELF_SHADOW := {Tier.LOW: false, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const RENDER_SCALE := {
	Tier.LOW: 0.75, Tier.MEDIUM: 0.85, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		min_factor = MIN_LAYER_FACTOR[tier],
		max_factor = MAX_LAYER_FACTOR[tier],
		self_shadow = SELF_SHADOW[tier],
		render_scale = RENDER_SCALE[tier],
	}
