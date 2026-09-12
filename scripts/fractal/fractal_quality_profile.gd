class_name FractalQualityProfile
extends SimQualityProfile
## Quality tiers of the 2D fractal explorer. The iteration cap bounds the
## cheap interactive pass (drag responsiveness), the refine band sizes the
## high-iteration passes that sweep the settled frame, and anti-alias is the
## per-pixel sample multiplier on the final image.

const AA_QUALITY := {Tier.LOW: 1, Tier.MEDIUM: 2, Tier.HIGH: 3, Tier.ULTRA: 3}
const INTERACTION_CAP := {
	Tier.LOW: 400, Tier.MEDIUM: 1200, Tier.HIGH: 3000, Tier.ULTRA: 8000,
}
const REFINE_BAND_ROWS := {
	Tier.LOW: 128, Tier.MEDIUM: 256, Tier.HIGH: 512, Tier.ULTRA: 1024,
}


static func values(tier: int) -> Dictionary:
	return {
		aa_quality = AA_QUALITY[tier],
		interaction_cap = INTERACTION_CAP[tier],
		refine_band_rows = REFINE_BAND_ROWS[tier],
	}
