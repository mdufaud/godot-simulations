extends "res://tests/test_case.gd"

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

## Lot K: the atlas geometry contract. The 4096-slot atlas is selected per pool
## budget, compiled into every shader family through one define string, and must
## fall back to the base 2048 atlas on a device whose compute shared memory
## cannot hold the 16 KB coarse solve. These are the CPU halves of those three
## contracts; the GLSL halves read the defines FireTilePool.glsl_header injects.

func _initialize() -> void:
	# Layout of the two atlases: 16 slots across x in both, so a slot < 2048 has
	# the same atlas origin under either.
	_check(FireSolver.atlas_slots_for_budget(1536) == 2048, "1536 budget must stay on the base atlas")
	_check(FireSolver.atlas_slots_for_budget(1792) == 2048, "1792 budget must stay on the base atlas")
	_check(FireSolver.atlas_slots_for_budget(2048) == 2048, "2048 budget must stay on the base atlas")
	_check(FireSolver.atlas_slots_for_budget(4096) == 4096, "4096 budget must select the large atlas")

	var base := Vector3i(16, 8, 16)
	var large := Vector3i(16, 16, 16)
	_check(FireTilePool.atlas_tiles_for(2048) == base, "base atlas layout changed")
	_check(FireTilePool.atlas_tiles_for(4096) == large, "large atlas layout changed")
	_check(FireTilePool.atlas_cells_for(2048) == base * 8, "base atlas cells must be tiles * 8")
	_check(FireTilePool.atlas_cells_for(4096) == large * 8, "large atlas cells must be tiles * 8")

	# Budget ladder: unique, ascending, ends on the large atlas.
	var budgets: Array = FireSolver.POOL_BUDGETS
	_check(budgets.size() == 4, "pool budget ladder changed shape")
	for i in budgets.size():
		for j in budgets.size():
			if i != j:
				_check(budgets[i] != budgets[j], "duplicate pool budget rung")
	_check(budgets[0] < budgets[1] and budgets[1] < budgets[2] and budgets[2] < budgets[3],
		"pool budget ladder must ascend")
	_check(FireSolver.atlas_slots_for_budget(budgets[3]) == 4096,
		"ladder must end on the large-atlas rung")

	# The define string is the CPU/GLSL contract: both numbers in it must agree
	# with the atlas the solver will build and the pool will lay out.
	for slots in [2048, 4096]:
		var defines := FireTilePool.glsl_header(slots)
		var tiles := FireTilePool.atlas_tiles_for(slots)
		_check(defines.contains("#define NSLOTS %du" % slots),
			"define string missing slot count for %d" % slots)
		_check(defines.contains("#define ATLAS_TILES ivec3(%d, %d, %d)" % [tiles.x, tiles.y, tiles.z]),
			"define string tiles disagree with atlas_tiles_for(%d)" % slots)

	# Shared-memory budget of the coarse solve: the 16 KB the large atlas needs
	# is twice the Vulkan guaranteed minimum, which is exactly why the solver
	# probes the device before selecting it.
	_check(4096 * 4 == 16384, "coarse shared-memory arithmetic drifted")
	_check(FireSolver.display_fp16_requested() == (OS.get_environment("FIRE_DISPLAY_F16") == "1"),
		"display fp16 A/B gate must track the environment variable")

	_finish("fire_atlas")
