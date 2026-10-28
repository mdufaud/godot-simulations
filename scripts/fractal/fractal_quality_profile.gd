class_name FractalQualityProfile
extends SimQualityProfile
## Quality tiers of the 2D fractal explorer. Every sample is computed at full
## resolution and full iteration count; tiers only size the GPU time spent per
## frame (how fast the screen refreshes while moving) and how many jittered
## samples each pixel accumulates once the view is still.

const AA_SAMPLES := {Tier.LOW: 4, Tier.MEDIUM: 9, Tier.HIGH: 16, Tier.ULTRA: 32}
const SAMPLE_BUDGET_MS := {
	Tier.LOW: 6.0, Tier.MEDIUM: 10.0, Tier.HIGH: 12.0, Tier.ULTRA: 14.0,
}


static func values(tier: int) -> Dictionary:
	return {
		aa_samples = AA_SAMPLES[tier],
		sample_budget_ms = SAMPLE_BUDGET_MS[tier],
	}
