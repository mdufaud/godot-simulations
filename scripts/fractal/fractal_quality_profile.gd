class_name FractalQualityProfile
extends SimQualityProfile
## Quality tiers of the 2D fractal explorer. Motion quality is not a tier
## knob — the live preview always runs at the full iteration count and lets
## its resolution adapt to the frame budget — so tiers size the settled
## image: the refine band sweep speed and the per-pixel anti-alias level.

const AA_QUALITY := {Tier.LOW: 1, Tier.MEDIUM: 2, Tier.HIGH: 3, Tier.ULTRA: 3}
const REFINE_BAND_ROWS := {
	Tier.LOW: 128, Tier.MEDIUM: 256, Tier.HIGH: 512, Tier.ULTRA: 1024,
}


static func values(tier: int) -> Dictionary:
	return {
		aa_quality = AA_QUALITY[tier],
		refine_band_rows = REFINE_BAND_ROWS[tier],
	}
