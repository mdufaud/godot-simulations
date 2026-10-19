class_name OceanConfig extends Resource

const MIN_WAVELENGTH_M := 0.25
const CASCADE_COUNT := 3

## Measurement thresholds shared by the capture readbacks and the test suite.
const MEASURE_FOAM_THRESHOLD := 0.02
const MEASURE_FRESH_THRESHOLD := 0.005
const MEASURE_CREST_THRESHOLD := 0.15
const MEASURE_BREAKING_THRESHOLD := 0.15
const MEASURE_VERSION := 6

@export_range(256, 1024, 1) var map_size: int = 512
@export var clipmap_tile_lengths_m: PackedFloat32Array = PackedFloat32Array([2039.0, 111.0, 25.0])
@export_range(1, 32, 1) var clipmap_levels: int = 8
@export_range(0.001, 100.0, 0.001) var finest_cell_m: float = 0.125


func validate() -> String:
	for property: Dictionary in get_property_list():
		if property.hint != PROPERTY_HINT_RANGE:
			continue
		var value := float(get(property.name))
		var limits := String(property.hint_string).split(",")
		if not is_finite(value) or value < float(limits[0]) or value > float(limits[1]):
			return "%s must be finite and in %s..%s" % [property.name, limits[0], limits[1]]
	if map_size < 256 or map_size > 1024 or (map_size & (map_size - 1)) != 0:
		return "map_size must be a power of two from 256 to 1024"
	# The whole pipeline is 3-cascade: CHOP_PER_CASCADE, MAX_CASCADES uniform
	# arrays, the query/near push constants and the 3-layer foam field.
	if clipmap_tile_lengths_m.size() != CASCADE_COUNT:
		return "clipmap requires exactly 3 cascade tile lengths"
	for tile in clipmap_tile_lengths_m:
		if not is_finite(tile) or tile <= 0.0:
			return "clipmap tile lengths must be finite and positive"
	for i in range(clipmap_tile_lengths_m.size() - 1):
		if clipmap_tile_lengths_m[i] <= clipmap_tile_lengths_m[i + 1]:
			return "clipmap tile lengths must descend"
		if clipmap_tile_lengths_m[i] / clipmap_tile_lengths_m[i + 1] < 2.0:
			return "clipmap tile lengths must leave a coherent band"
		if PI * map_size / clipmap_tile_lengths_m[i] < TAU * 6.0 / clipmap_tile_lengths_m[i + 1]:
			return "clipmap resolution leaves a spectral band gap"
	return ""
