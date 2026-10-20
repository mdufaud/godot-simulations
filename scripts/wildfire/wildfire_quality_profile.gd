class_name WildfireQualityProfile
extends SimQualityProfile
## Quality tiers for the wildfire demo. Medium is the shipped look. Higher
## tiers add lighting rather than particle counts: smoke lit by the fires'
## own lights, firelight scattering in a volumetric cloud around each fire,
## and shadows from more fire lights. Low drops the heat haze and every fire
## shadow.

const FLAME_DENSITY := {
	Tier.LOW: 0.7,
	Tier.MEDIUM: 1.0,
	Tier.HIGH: 1.2,
	Tier.ULTRA: 1.4,
}

## WildfirePreset.shadow_rank threshold: 1 campfire, 2 log piles, 3 torches.
const SHADOW_LEVEL := {
	Tier.LOW: 0,
	Tier.MEDIUM: 1,
	Tier.HIGH: 2,
	Tier.ULTRA: 3,
}

const HEAT_HAZE := {
	Tier.LOW: false,
	Tier.MEDIUM: true,
	Tier.HIGH: true,
	Tier.ULTRA: true,
}

const LIT_SMOKE := {
	Tier.LOW: false,
	Tier.MEDIUM: false,
	Tier.HIGH: true,
	Tier.ULTRA: true,
}

const FIRE_FOG := {
	Tier.LOW: false,
	Tier.MEDIUM: false,
	Tier.HIGH: false,
	Tier.ULTRA: true,
}


static func values(tier: int) -> Dictionary:
	return {
		flame_density = FLAME_DENSITY[tier],
		shadow_level = SHADOW_LEVEL[tier],
		heat_haze = HEAT_HAZE[tier],
		lit_smoke = LIT_SMOKE[tier],
		fire_fog = FIRE_FOG[tier],
	}
