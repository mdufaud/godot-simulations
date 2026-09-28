class_name GrassQualityProfile
extends SimQualityProfile

const DENSITY := {Tier.LOW: 0.6, Tier.MEDIUM: 0.7, Tier.HIGH: 1.0, Tier.ULTRA: 1.1}
const NEAR_DETAIL := {Tier.LOW: false, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const SHADOWS := {Tier.LOW: false, Tier.MEDIUM: false, Tier.HIGH: true, Tier.ULTRA: true}
const SHADOW_DISTANCE_M := {
	Tier.LOW: 20.0, Tier.MEDIUM: 30.0, Tier.HIGH: 40.0, Tier.ULTRA: 60.0,
}

static func values(tier: int) -> Dictionary:
	return {
		near_detail = NEAR_DETAIL[tier],
		density = DENSITY[tier],
		shadows = SHADOWS[tier],
		shadow_distance_m = SHADOW_DISTANCE_M[tier],
	}
