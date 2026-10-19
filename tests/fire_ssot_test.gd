extends "res://tests/test_case.gd"
## Single-source-of-truth gate for the fire pipeline. Tile-pool geometry, pool
## sentinels and counters, the stats/config layout, the water fixed-point scales
## and the physical constants the shaders share with GDScript are owned by
## GDScript and injected as defines; a shader that re-types one of them compiles
## fine and silently diverges the day the owner changes, so this fails instead.

const SHADER_DIRS: Array[String] = ["res://shaders/fire/", "res://shaders/fire/sparse/"]
const INJECTED_NAMES: Array[String] = [
	"NSLOTS", "VTILES", "ATLAS_TILES", "ATLAS_CELLS", "TILE", "SLOT_MAX", "TILE_SLOT_MAX",
	"INACTIVE", "RESERVED", "C_FREE", "C_REQUEST", "C_FRAME", "C_EXHAUST", "C_PEAK",
	"C_KEEP", "C_ACTIVE", "C_NEW", "C_ACTIVE_WORD", "MAX_LOGS", "STAT_BOUNDS",
	"STATS_WORDS", "STAT_SCALE", "SCALE_M", "SCALE_W", "SCALE_T", "SCALE_V", "SCALE_E",
	"R_GAS", "SIGMA_SB", "DRAIN_CUTOFF", "AMBIENT_T",
]
## Literals that only ever mean the pool layout or its sentinel.
const POOL_LITERALS: Array[String] = [
	"0xFFFFFFF0u", "ivec3(256, 64, 256)", "ivec3(16, 8, 16)", "ivec3(128, 64, 128)",
	"% 16u", "/ 128u", "const int TILE",
]


func _initialize() -> void:
	var redeclare := RegEx.create_from_string(
		"(?m)^\\s*(?:const\\s+\\w+|#define)\\s+(%s)\\b" % "|".join(INJECTED_NAMES))
	var stat_literal := RegEx.create_from_string("stats\\.data\\[\\s*\\d")
	var scanned := 0
	for dir_path in SHADER_DIRS:
		for file in DirAccess.get_files_at(dir_path):
			if not (file.ends_with(".comp") or file.ends_with(".gdshader")
					or file.ends_with(".gdshaderinc")):
				continue
			var path := dir_path + file
			var src := FileAccess.get_file_as_string(path)
			scanned += 1
			for m in redeclare.search_all(src):
				_check(false, "%s re-declares injected %s" % [path, m.get_string(1)])
			_check(stat_literal.search(src) == null,
				"%s indexes the stats buffer by literal" % path)
			for literal in POOL_LITERALS:
				_check(not src.contains(literal), "%s hard-codes pool layout '%s'" % [path, literal])
	_check(scanned > 20, "scanned only %d fire shaders" % scanned)

	var config := FireConfig.new()
	for prop in ["virtual_tile_dims", "atlas_tile_dims", "tile_cells", "max_logs", "pool_budget"]:
		_check(not prop in config, "FireConfig still exports %s" % prop)
	_check(config.sim_dims_cells() == FireTilePool.VTILES * FireTilePool.TILE,
		"FireConfig domain differs from the tile pool's")

	var solver_src := FileAccess.get_file_as_string("res://scripts/fire/fire_gpu_solver.gd")
	_check(RegEx.create_from_string("\\bv\\[\\d+\\]\\s*=").search(solver_src) == null,
		"fire_gpu_solver.gd writes the config buffer by magic index")
	_check(RegEx.create_from_string("\\bs\\[\\d+").search(solver_src) == null,
		"fire_gpu_solver.gd reads the stats buffer by magic index")

	_finish("fire_ssot")
