class_name OceanConfig extends Resource

@export_range(8, 2048, 1) var map_size: int = 512
@export var clipmap_tile_lengths_m: PackedFloat32Array = PackedFloat32Array([1013.0, 127.0, 17.0])
@export_range(1, 32, 1) var clipmap_levels: int = 8
@export_range(0.001, 100.0, 0.001) var finest_cell_m: float = 0.125


func validate() -> String:
	if map_size < 8 or (map_size & (map_size - 1)) != 0:
		return "map_size must be a power of two >= 8"
	if clipmap_levels < 1 or clipmap_tile_lengths_m.size() < 3:
		return "clipmap levels and tile lengths are incomplete"
	for i in range(clipmap_tile_lengths_m.size() - 1):
		if clipmap_tile_lengths_m[i] <= clipmap_tile_lengths_m[i + 1]:
			return "clipmap tile lengths must descend"
		if clipmap_tile_lengths_m[i] / clipmap_tile_lengths_m[i + 1] < 2.0:
			return "clipmap tile lengths must leave a coherent band"
	if finest_cell_m <= 0.0:
		return "finest_cell_m must be positive"
	return ""
