class_name TerrainPreset extends Resource
## A terrain scene: the multi-material field it starts from (sand height,
## water depth, snow depth), where the camera looks, which brush is armed,
## the ambience it is lit with and whether balls share the sandbox.
##
## Presets live in [code]resources/terrain/presets/[/code].
##
## [codeblock]
## var preset: TerrainPreset = preload("res://resources/terrain/presets/dunes.tres")
## var state := preset.build_state(solver.grid_n, solver.world_size)
## solver.set_seed_channels(state.sand, state.water, state.snow)
## [/codeblock]

enum Terrain { FLAT, DUNES }
## What a rolling ball drags through the surface: a dug furrow in sand, a
## packed trail in snow.
enum BallTrack { NONE, DIG, PACK }

@export var display_name := "Sandbox dig"
@export_enum("None", "Dig", "Pour", "Smooth", "Water", "Pack") var default_tool: int = TerrainBrush.DIG
@export var walls_visible := true

@export_group("Terrain")
@export var terrain: Terrain = Terrain.FLAT
## Starting column height, and the floor the dunes rise from.
@export_range(0.0, 2.0, 0.001) var base_height_m := 0.35
@export_range(0.0, 2.0, 0.001) var dune_amplitude_m := 0.45
@export_range(0.05, 4.0, 0.01) var dune_frequency := 0.55
@export_range(1, 8, 1) var dune_octaves := 4
@export var dune_seed := 7
## Constant tilt of the whole field: downhill runs toward
## [member slope_direction_deg] (0 = downhill toward +x). Drives rivers and
## avalanches.
@export_range(0.0, 30.0, 0.1) var slope_deg := 0.0
@export_range(0.0, 360.0, 1.0) var slope_direction_deg := 0.0

@export_group("Materials")
## Uniform water depth at start (a filled pool or a soaked field).
@export_range(0.0, 1.0, 0.001) var water_level_m := 0.0
## Uniform snow blanket at start.
@export_range(0.0, 1.0, 0.001) var snow_depth_m := 0.0

@export_group("Camera")
@export var camera_target_m := Vector3(0.0, 0.3, 0.0)
@export_range(0.5, 40.0, 0.1) var camera_distance_m := 4.5

@export_group("Auto pour")
## Radius of the slow pouring orbit that runs when the user is not sculpting.
## 0 disables it: the scene only moves under the brush.
@export_range(0.0, 4.0, 0.01) var auto_pour_radius_m := 0.0
@export_range(0.0, 4.0, 0.01) var auto_pour_rate_rad_s := 0.5
@export_range(0.0, 4.0, 0.01) var auto_pour_strength := 1.8
## The auto orbit pours snow instead of sand (avalanche scenes: the heap
## overloads the slab past its cohesion and lets go on its own).
@export var auto_pour_snow := false
## A second orbit that pours water instead of sand (rivers, rain on snow).
@export_range(0.0, 4.0, 0.01) var auto_water_radius_m := 0.0
@export_range(0.0, 4.0, 0.01) var auto_water_rate_rad_s := 0.7
@export_range(0.0, 4.0, 0.01) var auto_water_strength := 2.5

@export_group("Climate overrides")
## Negative leaves the config value untouched.
@export_range(-1.0, 1.0, 0.0001) var melt_rate_m_s := -1.0
@export_range(-1.0, 1.0, 0.0001) var evap_rate_m_s := -1.0
@export_range(-1.0, 1.0, 0.0001) var snowfall_rate_m_s := -1.0
@export_range(-1.0, 1.0, 0.0001) var freeze_rate_m_s := -1.0
## Snow cohesion override in degrees; negative keeps the config value. Below
## the field's tilt the snow releases on its own (an avalanche on load).
@export_range(-1.0, 89.0, 0.1) var snow_cohesion_deg := -1.0
## Snow creep rate override; negative keeps the config value. The avalanche
## scene raises it so the release reads as a flow, not a shiver.
@export_range(-1.0, 1.0, 0.001) var snow_creep_rate := -1.0
## Per-pair shed cap override (0.05..0.9); negative keeps the config value.
## Higher caps make the release wave faster.
@export_range(-1.0, 1.0, 0.01) var snow_creep_cap := -1.0
## Snow pass iterations override; negative keeps the solver value (2). More
## passes make the release wave cross the field faster (stability caps bound
## each pass, so wave speed is iterations x cap).
@export_range(-1.0, 16.0, 1.0) var snow_pass_iterations := -1.0

@export_group("Balls")
@export var balls_enabled := false
@export_range(1, 4, 1) var ball_count := 2
@export_enum("None", "Dig", "Pack") var ball_track: int = BallTrack.NONE

@export_group("Props")
## Seeds a wet-sand castle at the domain centre: a keep, four towers, walls
## and a dry moat, saturated with water so it holds past the dry repose.
@export var sand_castle := false
## One-line tell shown under the status label: what this scene is and what to
## do with it.
@export_multiline var hint := ""

@export_group("Ambience")
@export_range(2.0, 80.0, 0.1) var sun_elevation_deg := 38.0
@export_range(0.0, 360.0, 0.1) var sun_azimuth_deg := 145.0
@export var sun_color := Color(1.0, 0.93, 0.82)
@export_range(0.0, 4.0, 0.05) var sun_energy := 1.3
@export var sky_top := Color(0.36, 0.44, 0.56)
@export var sky_horizon := Color(0.68, 0.66, 0.62)
@export var fog_color := Color(0.68, 0.66, 0.62)
@export_range(0.0, 0.02, 0.0001) var fog_density := 0.0
@export_range(0.4, 2.0, 0.01) var exposure := 1.0
@export var snowfall := false
## Sand palette the surface shader blends between (dry tones).
@export var sand_light := Color(0.88, 0.75, 0.53)
@export var sand_dark := Color(0.62, 0.46, 0.29)


func validate() -> String:
	if base_height_m < 0.0:
		return "base_height_m cannot be negative"
	if camera_distance_m <= 0.0:
		return "camera_distance_m must be positive"
	if auto_pour_radius_m < 0.0 or auto_water_radius_m < 0.0:
		return "auto pour radii cannot be negative"
	if water_level_m < 0.0 or snow_depth_m < 0.0:
		return "water_level_m and snow_depth_m cannot be negative"
	return ""


func pours_by_itself() -> bool:
	return auto_pour_radius_m > 0.0


func waters_by_itself() -> bool:
	return auto_water_radius_m > 0.0


## Grid seed layout: grid_n * grid_n column heights in metres, row-major,
## x fastest -- the layout [method HeightfieldTerrain.set_seed_channels]
## expects. The tilt lifts columns along the downhill direction around the
## domain centre; columns never go below the base height.
func build_state(grid_n: int, world_size: float) -> Dictionary:
	var sand := build_seed(grid_n, world_size)
	var water := PackedFloat32Array()
	var snow := PackedFloat32Array()
	water.resize(grid_n * grid_n)
	snow.resize(grid_n * grid_n)
	if water_level_m > 0.0:
		water.fill(water_level_m)
	if snow_depth_m > 0.0:
		snow.fill(snow_depth_m)
	if sand_castle:
		_seed_castle(sand, water, grid_n, world_size)
	return {sand = sand, water = water, snow = snow}


## grid_n * grid_n sand column heights in metres, row-major, x fastest.
##
## DUNES terrain is transverse ridges across the wind (+x): a smooth stoss
## rise into a sharp crest, then a straight slip face — the classic dune
## silhouette — with the crest line wandering in x (noise) and small
## superimposed lumps. The profile slopes stay under the dry repose angle at
## the shipped amplitudes, so the shapes hold instead of slumping on load.
func build_seed(grid_n: int, world_size: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(grid_n * grid_n)
	if terrain == Terrain.FLAT and slope_deg <= 0.0:
		out.fill(base_height_m)
		return out
	var cell := world_size / float(grid_n)
	var slope := tan(deg_to_rad(slope_deg))
	var slope_dir := Vector2.RIGHT.rotated(deg_to_rad(slope_direction_deg))
	var ridge_wl := 0.0
	var wander := FastNoiseLite.new()
	var detail := FastNoiseLite.new()
	if terrain == Terrain.DUNES:
		ridge_wl = world_size / clampf(dune_frequency * 5.0, 1.0, 20.0)
		wander.seed = dune_seed
		wander.noise_type = FastNoiseLite.TYPE_SIMPLEX
		wander.frequency = 0.9 / ridge_wl
		detail.seed = dune_seed + 101
		detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
		detail.frequency = 1.3 / ridge_wl
		detail.fractal_octaves = dune_octaves
	for j in grid_n:
		var z := (float(j) + 0.5) * cell - world_size * 0.5
		var row := j * grid_n
		for i in grid_n:
			var x := (float(i) + 0.5) * cell - world_size * 0.5
			var height := base_height_m
			if terrain == Terrain.DUNES:
				var u := fposmod(z / ridge_wl + wander.get_noise_2d(x, z) * 0.18, 1.0)
				height += dune_amplitude_m * (_dune_profile(u)
					+ 0.05 * detail.get_noise_2d(x, z))
			if slope_deg > 0.0:
				height -= slope * (Vector2(x, z).dot(slope_dir))
			out[row + i] = maxf(height, 0.0)
	return out


## Transverse dune cross-section on t in [0, 1): gentle stoss rise to the
## crest at 0.7, then a straight slip face back down. Max slopes at amplitude
## A and wavelength L: stoss 2.2·A/L, slip 3.3·A/L.
func _dune_profile(t: float) -> float:
	if t < 0.7:
		return 0.5 - 0.5 * cos(t / 0.7 * PI)
	return (1.0 - t) / 0.3


## Stamps a sand castle at the centre of [param sand] and soaks its footprint
## (the water is what lets it hold past the dry repose angle). A three-step
## ziggurat keep with a top block, four corner towers and low curtain walls
## with a gate gap on the +z side — every face seeded at or under the wet
## repose angle (~43° at full saturation), so the shape settles into itself
## instead of slumping into a mound.
func _seed_castle(sand: PackedFloat32Array, water: PackedFloat32Array,
		grid_n: int, world_size: float) -> void:
	var cell := world_size / float(grid_n)
	var tiers := [
		{half = 0.50, top = 0.105},
		{half = 0.39, top = 0.23},
		{half = 0.29, top = 0.34},
		{half = 0.21, top = 0.43},
	]
	# Corner bastions: smooth quadratic domes (rim slope ~43° at these
	# proportions), so they hold instead of slumping like a steep cone would.
	var bastion_r := 0.36
	var bastion_h := 0.20
	var bastion_ring := 0.58
	var wall_half := 0.50
	var wall_thickness := 0.035
	var wall_top := 0.17
	var soak_radius := 0.75
	var soak := 0.035
	for j in grid_n:
		var z := (float(j) + 0.5) * cell - world_size * 0.5
		var row := j * grid_n
		for i in grid_n:
			var x := (float(i) + 0.5) * cell - world_size * 0.5
			var d := Vector2(x, z)
			var add := 0.0
			for tier in tiers:
				if absf(x) <= tier.half and absf(z) <= tier.half:
					add = tier.top
			for tx in [-bastion_ring, bastion_ring]:
				for tz in [-bastion_ring, bastion_ring]:
					var r := d.distance_to(Vector2(tx, tz))
					if r < bastion_r:
						add = maxf(add, 0.105 + bastion_h * (1.0 - (r / bastion_r) * (r / bastion_r)))
			var inside_wall := absf(x) <= wall_half and absf(z) <= wall_half \
				and (absf(absf(x) - wall_half) <= wall_thickness
					or absf(absf(z) - wall_half) <= wall_thickness)
			# Gate: a gap in the +z curtain wall.
			if inside_wall and absf(z - wall_half) <= wall_thickness and absf(x) < 0.1:
				inside_wall = false
			if inside_wall:
				add = maxf(add, wall_top)
			if add == 0.0 and d.length() > soak_radius:
				continue
			var idx := row + i
			if add != 0.0:
				sand[idx] += add
			water[idx] = maxf(water[idx], soak)
