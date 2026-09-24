class_name OceanConfig extends Resource

## Measurement thresholds (fix plan 0.7, trap M2): ONE definition of "this texel
## counts as foam" shared by the capture readbacks and the test suite. They sit
## at the bottom of the render ramps on purpose; render smoothsteps stay
## independent (docs/ocean_fix_plan.md annexe C). measure_version=4 in reports.
const MEASURE_FOAM_THRESHOLD := 0.02
const MEASURE_FRESH_THRESHOLD := 0.005
const MEASURE_CREST_THRESHOLD := 0.15
const MEASURE_BREAKING_THRESHOLD := 0.15
const MEASURE_VERSION := 5

@export_range(32, 1024, 1) var map_size: int = 512
@export var clipmap_tile_lengths_m: PackedFloat32Array = PackedFloat32Array([2039.0, 111.0, 25.0])
@export_range(1, 32, 1) var clipmap_levels: int = 8
@export_range(0.001, 100.0, 0.001) var finest_cell_m: float = 0.125


func validate() -> String:
	if map_size < 32 or map_size > 1024 or (map_size & (map_size - 1)) != 0:
		return "map_size must be a power of two from 32 to 1024"
	# The whole pipeline is 3-cascade: CHOP_PER_CASCADE, MAX_CASCADES uniform
	# arrays, the query/near push constants and the 3-layer foam field.
	if clipmap_levels < 1 or clipmap_tile_lengths_m.size() != 3:
		return "clipmap requires exactly 3 cascade tile lengths"
	for i in range(clipmap_tile_lengths_m.size() - 1):
		if clipmap_tile_lengths_m[i] <= clipmap_tile_lengths_m[i + 1]:
			return "clipmap tile lengths must descend"
		if clipmap_tile_lengths_m[i] / clipmap_tile_lengths_m[i + 1] < 2.0:
			return "clipmap tile lengths must leave a coherent band"
	if finest_cell_m <= 0.0:
		return "finest_cell_m must be positive"
	return ""
