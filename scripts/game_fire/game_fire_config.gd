class_name GameFireConfig extends Resource
## Budgets and rendering knobs for the cheap "game fire" stack
## (see docs/game_fire_rdr2_model.md). Per-fire looks live in GameFirePreset.

@export_group("Particle pools")
@export_range(64, 8192, 64) var flame_pool: int = 1024
@export_range(32, 4096, 32) var smoke_pool: int = 384
@export_range(1, 16, 1) var atlas_cols: int = 8
@export_range(1, 16, 1) var atlas_rows: int = 8

@export_group("Layer LOD (distances in m)")
@export_range(5.0, 200.0, 5.0) var ember_cutoff_m: float = 50.0
@export_range(5.0, 300.0, 5.0) var flame_cutoff_m: float = 80.0
@export_range(5.0, 300.0, 5.0) var smoke_cutoff_m: float = 90.0
@export_range(5.0, 120.0, 5.0) var haze_cutoff_m: float = 35.0
@export_range(5.0, 120.0, 5.0) var light_cutoff_m: float = 30.0

@export_group("Heat haze")
@export_range(0.0, 0.2, 0.005) var haze_strength: float = 0.024
@export_range(0.5, 8.0, 0.1) var haze_height_m: float = 3.0

@export_group("Intensity envelope")
@export_range(0.2, 10.0, 0.1) var ignite_rate_per_s: float = 2.5
@export_range(0.2, 10.0, 0.1) var extinguish_rate_per_s: float = 1.5


func validate() -> String:
	if flame_pool < 1 or smoke_pool < 1:
		return "particle pools must be positive"
	if atlas_cols < 1 or atlas_rows < 1:
		return "atlas_frames must be positive"
	if haze_height_m <= 0.0:
		return "haze_height_m must be positive"
	return ""
