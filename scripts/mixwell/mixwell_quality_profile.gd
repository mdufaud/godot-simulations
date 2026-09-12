class_name MixwellQualityProfile
extends SimQualityProfile
## Quality tiers of the mixwell path tracer. Samples per pixel is the raw cost
## lever; the render scales trade sharpness for fill rate (both preview and
## final buffers), and the GPU budget bounds the per-frame sample batches.

## Must stay inside MixwellConfig.SPP_TARGETS ([1, 4, 16, 64, 256]).
const TARGET_SPP := {Tier.LOW: 1, Tier.MEDIUM: 4, Tier.HIGH: 16, Tier.ULTRA: 256}
const PREVIEW_SCALE := {
	Tier.LOW: 0.3, Tier.MEDIUM: 0.35, Tier.HIGH: 0.5, Tier.ULTRA: 1.0,
}
const FINAL_SCALE := {
	Tier.LOW: 0.5, Tier.MEDIUM: 0.5, Tier.HIGH: 0.75, Tier.ULTRA: 1.0,
}
const GPU_BUDGET_MS := {
	Tier.LOW: 4.0, Tier.MEDIUM: 4.0, Tier.HIGH: 8.0, Tier.ULTRA: 16.0,
}


static func values(tier: int) -> Dictionary:
	return {
		target_spp = TARGET_SPP[tier],
		preview_scale = PREVIEW_SCALE[tier],
		final_scale = FINAL_SCALE[tier],
		gpu_budget_ms = GPU_BUDGET_MS[tier],
	}
