class_name PlanetConfig extends Resource

enum TerrainStyle { CONTINENTAL = 0, ASTEROID = 1 }
enum OpeningStyle { CAVITIES = 0, SHATTERED_SHELL = 1 }

const VOLCANO_FLOOR_FRACTION := 0.38
const VOLCANO_CRATER_BOTTOM_RATIO := 0.16
const VOLCANO_CRATER_TOP_RATIO := 0.30
const SHATTERED_BELT_AXIS := Vector3(0.12, 1.0, 0.18)

@export_range(16, 512, 1) var resolution: int = 128
@export_range(4.0, 120.0, 0.1) var radius_m: float = 23.0
@export_range(0.1, 20.0, 0.1) var triangle_budget_per_cell: float = 20.0
@export_range(1, 64, 1) var max_layers: int = 8
@export_range(4.0, 120.0, 0.1) var reference_radius_m: float = 23.0
@export_range(0, 999999, 1) var seed: int = 0
@export_range(0.0, 1.0, 0.01) var continent_strength: float = 0.0
@export_range(0.0, 2.0, 0.01) var mountain_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var warp_strength: float = 0.0
@export_enum("Continental", "Asteroid") var terrain_style: int = TerrainStyle.CONTINENTAL
@export_enum("Cavities", "Shattered shell") var opening_style: int = OpeningStyle.CAVITIES
@export_range(0.0, 1.0, 0.01) var opening_strength: float = 0.0
@export_range(1, 8, 1) var opening_count: int = 3
@export_range(0.0, 0.3, 0.01) var fragment_separation_ratio: float = 0.14
@export_range(0.15, 0.55, 0.01) var core_fraction: float = 0.32
@export_range(0.65, 0.95, 0.01) var crust_fraction: float = 0.82

@export_group("Rings")
@export var ring_enabled: bool = false
@export_range(1.5, 2.6, 0.01) var ring_inner_ratio: float = 1.7
@export_range(2.8, 5.0, 0.01) var ring_outer_ratio: float = 2.9
@export_range(-75.0, 75.0, 1.0) var ring_tilt_deg: float = 25.0
@export_range(0.0, 1.0, 0.01) var ring_density: float = 0.7
@export_range(0.0, 1.0, 0.01) var ring_rocks: float = 0.7

@export_group("Satellites")
@export_range(0, 3, 1) var moon_count: int = 0
@export_range(3.0, 8.0, 0.01) var moon_distance_ratio: float = 4.6
@export_range(0.06, 0.3, 0.01) var moon_size_ratio: float = 0.16
@export_range(0.0, 0.25, 0.01) var moon_eccentricity: float = 0.1
@export_range(0.0, 3.0, 0.01) var orbit_speed: float = 1.0

@export_group("Volcanoes")
@export_range(0, 8, 1) var volcano_count: int = 0
@export_range(0.12, 0.4, 0.01) var volcano_size_ratio: float = 0.22
@export_range(0.05, 0.35, 0.01) var volcano_height_ratio: float = 0.22
@export_range(0.0, 1.0, 0.01) var volcano_activity: float = 1.0
@export_range(0.0, 8.0, 0.01) var lava_glow: float = 4.0
@export_range(0.0, 8.0, 0.1) var eruption_rate_hz: float = 4.0


func validate() -> String:
	if resolution < 8 or resolution > 512 or radius_m < 4.0 or radius_m > 120.0:
		return "resolution and radius_m are invalid"
	if reference_radius_m < 4.0 or reference_radius_m > 120.0:
		return "reference_radius_m is invalid"
	if triangle_budget_per_cell <= 0.0 or triangle_budget_per_cell > 20.0 or max_layers <= 0 or max_layers > 64:
		return "planet generation budgets must be positive"
	if seed < 0 or seed > 999999 or opening_count < 1 or opening_count > 8:
		return "planet seed or opening_count is invalid"
	if (terrain_style < TerrainStyle.CONTINENTAL or terrain_style > TerrainStyle.ASTEROID
			or opening_style < OpeningStyle.CAVITIES or opening_style > OpeningStyle.SHATTERED_SHELL
			or fragment_separation_ratio < 0.0 or fragment_separation_ratio > 0.3):
		return "planet style parameters are invalid"
	if opening_style == OpeningStyle.SHATTERED_SHELL and opening_count < 3:
		return "shattered shell requires at least three regions"
	if (continent_strength < 0.0 or continent_strength > 1.0
			or mountain_strength < 0.0 or mountain_strength > 2.0
			or warp_strength < 0.0 or warp_strength > 1.0
			or opening_strength < 0.0 or opening_strength > 1.0):
		return "planet shape strengths are invalid"
	if (core_fraction < 0.15 or core_fraction > 0.55
			or crust_fraction < 0.65 or crust_fraction > 0.95
			or core_fraction >= crust_fraction):
		return "planet core and crust fractions are invalid"
	if (ring_inner_ratio < 1.5 or ring_inner_ratio > 2.6
			or ring_outer_ratio < 2.8 or ring_outer_ratio > 5.0
			or absf(ring_tilt_deg) > 75.0
			or ring_density < 0.0 or ring_density > 1.0
			or ring_rocks < 0.0 or ring_rocks > 1.0):
		return "planet ring parameters are invalid"
	if (moon_count < 0 or moon_count > 3
			or moon_distance_ratio < 3.0 or moon_distance_ratio > 8.0
			or moon_size_ratio < 0.06 or moon_size_ratio > 0.3
			or moon_eccentricity < 0.0 or moon_eccentricity > 0.25
			or orbit_speed < 0.0 or orbit_speed > 3.0):
		return "planet satellite parameters are invalid"
	if (volcano_count < 0 or volcano_count > 8
			or volcano_size_ratio < 0.12 or volcano_size_ratio > 0.4
			or volcano_height_ratio < 0.05 or volcano_height_ratio > 0.35
			or volcano_activity < 0.0 or volcano_activity > 1.0
			or lava_glow < 0.0 or lava_glow > 8.0
			or eruption_rate_hz < 0.0 or eruption_rate_hz > 8.0):
		return "planet volcano parameters are invalid"
	return ""
