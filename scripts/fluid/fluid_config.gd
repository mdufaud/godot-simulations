extends RefCounted

const DEFAULT_PARTICLE_COUNT := 65536
const PARTICLE_COUNTS := [16384, 32768, 65536]
const FLOW_MIN := 0.5
const FLOW_MAX := 10.0
const DEFAULT_FLOW := 1.0
const GRID_DIMS := Vector3i(64, 64, 64)
const GRID_ORIGIN := Vector3(-8.0, 0.0, -8.0)
const CELL_SIZE := 0.25
const TEX_WIDTH := 256
const DOMAIN_ORIGIN := Vector3(-8.0, 0.0, -8.0)
const DOMAIN_SIZE := Vector3(16.0, 16.0, 16.0)
const TIMING_KEYS := ["viscosity", "integration", "foam_prepare", "foam_update", "foam_compact"]

static func fill_timing_defaults(timings: Dictionary) -> void:
	for key in TIMING_KEYS:
		if not timings.has(key):
			timings[key] = 0.0

static func read_gpu_timings(rd, prefix: String, include_post: bool = false) -> Dictionary:
	var out := GpuTimings.read(rd, prefix, include_post)
	if not out.is_empty():
		fill_timing_defaults(out)
	return out
