class_name NonEuclideanQualityProfile
extends SimQualityProfile
## Quality tiers of the non-Euclidean demo. Every portal view is a full extra
## render of the world, so the pool size and per-view resolution are the cost
## levers.

const PORTAL_VIEWS := {Tier.LOW: 1, Tier.MEDIUM: 2, Tier.HIGH: 2, Tier.ULTRA: 4}
const PORTAL_VIEW_SCALE := {
	Tier.LOW: 0.5, Tier.MEDIUM: 0.75, Tier.HIGH: 1.0, Tier.ULTRA: 1.0,
}
static func values(tier: int) -> Dictionary:
	return {
		portal_views = PORTAL_VIEWS[tier],
		portal_view_scale = PORTAL_VIEW_SCALE[tier],
	}
