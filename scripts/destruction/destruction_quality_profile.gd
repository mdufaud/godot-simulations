class_name DestructionQualityProfile
extends SimQualityProfile
## Quality tiers for the Voronoi destruction demo. Chunk count is the whole
## cost model: four walls each shatter into chunk_count cells, every cell is a
## Jolt rigid body with contact monitoring, and the rebuild refactures every
## hull — so the tiers step the chunk count and little else.

const CHUNK_COUNT := {
	Tier.LOW: 50,
	Tier.MEDIUM: 100,
	Tier.HIGH: 150,
	Tier.ULTRA: 220,
}

const RENDER_SCALE := {
	Tier.LOW: 0.75,
	Tier.MEDIUM: 0.85,
	Tier.HIGH: 1.0,
	Tier.ULTRA: 1.0,
}


static func values(tier: int) -> Dictionary:
	return {
		chunk_count = CHUNK_COUNT[tier],
		render_scale = RENDER_SCALE[tier],
	}
