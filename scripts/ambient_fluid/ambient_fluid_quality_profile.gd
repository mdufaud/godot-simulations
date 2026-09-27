class_name AmbientFluidQualityProfile
extends SimQualityProfile
const RENDER_SCALE := {
	Tier.LOW: 0.75, Tier.MEDIUM: 0.85, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}
const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_2X,
	Tier.HIGH: Viewport.MSAA_2X,
	Tier.ULTRA: Viewport.MSAA_4X,
}


static func values(tier: int) -> Dictionary:
	return {
		render_scale = RENDER_SCALE[tier],
		msaa = MSAA[tier],
	}
