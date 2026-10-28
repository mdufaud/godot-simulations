class_name SmokeQualityProfile
extends SimQualityProfile
## Quality tiers for the smoke demo. The grid cell budget drives every solver
## pass; the march step and the shadow-volume resolution drive the raymarch,
## the frame's other big cost. Low also halves the simulation rate. Every tier
## keeps MacCormack: first-order advection blurs rings and fog away at Low's cells.

const GRID_CELL_BUDGETS := [150000, 400000, 1300000, 3100000]
const SIM_RATES_HZ := [30.0, 60.0]
const LIGHT_DOWNSAMPLES := [4, 2, 1]

const GRID_CELL_BUDGET := {
	Tier.LOW: 150000,
	Tier.MEDIUM: 400000,
	Tier.HIGH: 1300000,
	Tier.ULTRA: 3100000,
}
const SIM_RATE_HZ := {Tier.LOW: 30.0, Tier.MEDIUM: 60.0, Tier.HIGH: 60.0, Tier.ULTRA: 60.0}
const PRESSURE_VCYCLES := {Tier.LOW: 1, Tier.MEDIUM: 1, Tier.HIGH: 1, Tier.ULTRA: 2}
const MARCH_STEP_CELLS := {Tier.LOW: 1.0, Tier.MEDIUM: 0.75, Tier.HIGH: 0.6, Tier.ULTRA: 0.5}
const LIGHT_DOWNSAMPLE := {Tier.LOW: 4, Tier.MEDIUM: 2, Tier.HIGH: 2, Tier.ULTRA: 1}
const LIGHT_STEP_CELLS := {Tier.LOW: 2.0, Tier.MEDIUM: 1.5, Tier.HIGH: 1.0, Tier.ULTRA: 0.75}
const MACCORMACK := {Tier.LOW: true, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const SCENE_SHADOWS := {Tier.LOW: false, Tier.MEDIUM: true, Tier.HIGH: true, Tier.ULTRA: true}
const MSAA := {
	Tier.LOW: Viewport.MSAA_DISABLED,
	Tier.MEDIUM: Viewport.MSAA_DISABLED,
	Tier.HIGH: Viewport.MSAA_2X,
	Tier.ULTRA: Viewport.MSAA_4X,
}


static func values(tier: int) -> Dictionary:
	return {
		grid_cell_budget = GRID_CELL_BUDGET[tier],
		sim_rate_hz = SIM_RATE_HZ[tier],
		pressure_vcycles = PRESSURE_VCYCLES[tier],
		march_step_cells = MARCH_STEP_CELLS[tier],
		light_downsample = LIGHT_DOWNSAMPLE[tier],
		light_step_cells = LIGHT_STEP_CELLS[tier],
		maccormack = MACCORMACK[tier],
		scene_shadows = SCENE_SHADOWS[tier],
		msaa = MSAA[tier],
	}
