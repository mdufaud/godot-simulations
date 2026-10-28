class_name ClothQualityProfile
extends SimQualityProfile
## Quality tiers for the VBD cloth demo. Six sheets simulate in parallel; VBD
## converges faster with substeps than with iterations, so the tiers spend the
## budget on substeps. Each tier stretches less than the XPBD tier it replaced
## at about the same GPU time (Low +6 %, the others below).

const ITERATIONS := {
	Tier.LOW: 1,
	Tier.MEDIUM: 2,
	Tier.HIGH: 2,
	Tier.ULTRA: 3,
}

const SUBSTEPS := {
	Tier.LOW: 3,
	Tier.MEDIUM: 5,
	Tier.HIGH: 7,
	Tier.ULTRA: 7,
}

static func values(tier: int) -> Dictionary:
	return {
		iterations = ITERATIONS[tier],
		substeps = SUBSTEPS[tier],
	}
