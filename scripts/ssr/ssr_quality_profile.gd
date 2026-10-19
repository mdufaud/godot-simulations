class_name SsrQualityProfile
extends SimQualityProfile
## Quality tiers of the SSR demo. Screen-space effects are the render-load
## levers (SSIL especially), the ray-march step count bounds reflection cost,
## and the object population drives physics + draw calls; MSAA lives on the
## root viewport through ViewportGuard.

const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_2X,
	Tier.HIGH: Viewport.MSAA_2X,
	Tier.ULTRA: Viewport.MSAA_4X,
}
const SSR_STEPS := {Tier.LOW: 32, Tier.MEDIUM: 64, Tier.HIGH: 128, Tier.ULTRA: 256}
const MAX_OBJECTS := {Tier.LOW: 40, Tier.MEDIUM: 60, Tier.HIGH: 120, Tier.ULTRA: 200}
const SSAO := {Tier.LOW: true, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const SSIL := {Tier.LOW: false, Tier.MEDIUM: false, Tier.HIGH: true, Tier.ULTRA: true}
const GLOW := {Tier.LOW: false, Tier.MEDIUM: false, Tier.HIGH: true, Tier.ULTRA: true}


static func values(tier: int) -> Dictionary:
	return {
		msaa = MSAA[tier],
		ssr_steps = SSR_STEPS[tier],
		max_objects = MAX_OBJECTS[tier],
		ssao = SSAO[tier],
		ssil = SSIL[tier],
		glow = GLOW[tier],
	}
