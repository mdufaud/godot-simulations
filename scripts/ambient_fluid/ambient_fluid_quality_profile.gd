class_name AmbientFluidQualityProfile
extends SimQualityProfile
const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_2X,
	Tier.HIGH: Viewport.MSAA_2X,
	Tier.ULTRA: Viewport.MSAA_4X,
}


static func values(tier: int) -> Dictionary:
	return {
		msaa = MSAA[tier],
	}
