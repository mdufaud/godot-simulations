class_name TerrainQualityProfile
extends SimQualityProfile
## Quality tiers for the heightfield sand. The solver grid drives the
## relaxation cost and the cell resolution; the visual sheet has its own
## vertex grid, whose GDScript fill stalls for seconds at 2048² — so Ultra
## pairs the 2048² simulation with a 1024² sheet — and settle iterations plus
## the root render scale carry the rest.

## Solver grids the menu proposes, smallest first.
const GRID_SIZES: Array[int] = [256, 512, 1024, 2048]

## Sheet vertex grids the menu proposes. The mesh only samples the height
## field, so it stops where the fill stall starts.
const MESH_SIZES: Array[int] = [256, 512, 1024]

const GRID_N := {
	Tier.LOW: 256,
	Tier.MEDIUM: 512,
	Tier.HIGH: 1024,
	Tier.ULTRA: 2048,
}

const MESH_N := {
	Tier.LOW: 256,
	Tier.MEDIUM: 512,
	Tier.HIGH: 1024,
	Tier.ULTRA: 1024,
}

const ITERATIONS := {
	Tier.LOW: 6,
	Tier.MEDIUM: 10,
	Tier.HIGH: 12,
	Tier.ULTRA: 16,
}

const RENDER_SCALE := {
	Tier.LOW: 0.75,
	Tier.MEDIUM: 0.85,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		grid_n = GRID_N[tier],
		mesh_n = MESH_N[tier],
		iterations = ITERATIONS[tier],
		render_scale = RENDER_SCALE[tier],
	}
