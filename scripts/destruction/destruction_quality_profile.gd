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

static func values(tier: int) -> Dictionary:
	return {
		chunk_count = CHUNK_COUNT[tier],
	}
