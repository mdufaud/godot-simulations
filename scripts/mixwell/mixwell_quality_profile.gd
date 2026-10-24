class_name MixwellQualityProfile
extends SimQualityProfile
## Quality tiers of the mixwell path tracer. Samples per pixel is the raw cost
## lever; the render scale (of the window's physical pixels) and its pixel cap
## trade sharpness for fill rate, and the GPU budget bounds the per-frame
## sample batches.

## Must stay inside MixwellConfig.SPP_TARGETS ([1, 4, 16, 64, 256]).
const TARGET_SPP := {Tier.LOW: 1, Tier.MEDIUM: 4, Tier.HIGH: 16, Tier.ULTRA: 256}
const FINAL_SCALE := {
	Tier.LOW: 0.75, Tier.MEDIUM: 1.0, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}
const MAX_RENDER_PIXELS := {
	Tier.LOW: 960 * 540, Tier.MEDIUM: 1920 * 1080, Tier.HIGH: 2560 * 1440,
	Tier.ULTRA: 3840 * 2160,
}
const GPU_BUDGET_MS := {
	Tier.LOW: 4.0, Tier.MEDIUM: 4.0, Tier.HIGH: 8.0, Tier.ULTRA: 16.0,
}


static func values(tier: int) -> Dictionary:
	return {
		target_spp = TARGET_SPP[tier],
		final_scale = FINAL_SCALE[tier],
		max_render_pixels = MAX_RENDER_PIXELS[tier],
		gpu_budget_ms = GPU_BUDGET_MS[tier],
	}
