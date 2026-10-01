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

enum Terrain { FLAT, DUNES, ALPINE }
## What a rolling ball drags through the surface: a dug furrow in sand, a
## packed trail in snow.
enum BallTrack { NONE, DIG, PACK }

@export var display_name := "Sandbox dig"
@export var default_tool: int = TerrainBrush.DIG
@export var walls_visible := true

@export_group("Terrain")
@export var terrain: Terrain = Terrain.FLAT
@export_range(1.0, 2000.0, 0.1) var world_size_m := 4.0
@export var alpine_seed := 7
@export_range(0.5, 8.0, 0.01) var alpine_density := 2.4
@export_range(0.1, 0.7, 0.01) var alpine_ruggedness := 0.46
@export_range(0.04, 0.35, 0.01) var alpine_valley_width_fraction := 0.16
@export_range(0.0, 0.95, 0.01) var alpine_valley_depth_fraction := 0.72
@export_range(0.0, 0.3, 0.01) var alpine_ridge_irregularity := 0.12
@export_range(0.0, 2.0, 0.01) var alpine_surface_detail := 1.0
@export_range(0.1, 1000.0, 0.1) var mountain_height_m := 5.5
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
@export var snow_enabled := true

@export_group("Camera")
@export var camera_target_m := Vector3(0.0, 0.3, 0.0)
@export_range(0.5, 4000.0, 0.1) var camera_distance_m := 4.5

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
@export_range(-1.0, 89.0, 0.1) var repose_angle_deg := -1.0
@export_range(-1.0, 2.0, 0.01) var erosion_rate := -1.0
@export_range(-1.0, 10.0, 0.01) var sediment_capacity := -1.0
@export_range(-1.0, 1.0, 0.0001) var rain_rate_m_s := -1.0
@export_range(-1.0, 2.0, 0.01) var deposition_gain := -1.0
@export_range(-1.0, 2.0, 0.0001) var uplift_rate_m_s := -1.0
@export_range(-1, 2, 1) var uplift_mode := -1
@export_range(-1.0, 1.0, 0.001) var uplift_radius_fraction := -1.0
@export_range(-1.0, 10.0, 0.01) var snowline_m := -1.0
@export var landscape_materials := false
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
	if not is_finite(alpine_density) or alpine_density < 0.5 or alpine_density > 8.0 \
			or not is_finite(alpine_ruggedness) or alpine_ruggedness < 0.1 or alpine_ruggedness > 0.7 \
			or not is_finite(alpine_valley_width_fraction) or alpine_valley_width_fraction < 0.04 \
			or alpine_valley_width_fraction > 0.35 \
			or not is_finite(alpine_valley_depth_fraction) or alpine_valley_depth_fraction < 0.0 \
			or alpine_valley_depth_fraction > 0.95 \
			or not is_finite(alpine_ridge_irregularity) or alpine_ridge_irregularity < 0.0 \
			or alpine_ridge_irregularity > 0.3 \
			or not is_finite(alpine_surface_detail) or alpine_surface_detail < 0.0 or alpine_surface_detail > 2.0:
		return "alpine generation settings are out of range"
	if not is_finite(world_size_m) or world_size_m <= 0.0 \
			or not is_finite(mountain_height_m) or mountain_height_m <= 0.0:
		return "world_size_m and mountain_height_m must be finite and positive"
	if not is_finite(repose_angle_deg) or repose_angle_deg == 0.0 or repose_angle_deg >= 90.0 \
			or not is_finite(erosion_rate) or not is_finite(sediment_capacity):
		return "repose/erosion overrides are invalid"
	if base_height_m < 0.0:
		return "base_height_m cannot be negative"
	if camera_distance_m <= 0.0:
		return "camera_distance_m must be positive"
	if auto_pour_radius_m < 0.0 or auto_water_radius_m < 0.0:
		return "auto pour radii cannot be negative"
	if water_level_m < 0.0 or snow_depth_m < 0.0:
		return "water_level_m and snow_depth_m cannot be negative"
	if not is_finite(rain_rate_m_s) or not is_finite(deposition_gain) \
			or not is_finite(uplift_rate_m_s):
		return "climate overrides must be finite"
	if uplift_mode < -1 or uplift_mode > TerrainConfig.UpliftMode.NOISE:
		return "uplift_mode is invalid"
	if not is_finite(uplift_radius_fraction) \
			or (uplift_radius_fraction >= 0.0 and (uplift_radius_fraction <= 0.0 \
				or uplift_radius_fraction > 1.0)):
		return "uplift_radius_fraction must be negative or in (0, 1]"
	if not is_finite(snowline_m):
		return "snowline_m must be finite"
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
	if snow_enabled and snow_depth_m > 0.0:
		if terrain == Terrain.ALPINE:
			for i in sand.size():
				snow[i] = snow_depth_m * smoothstep(snowline_m, snowline_m + 0.5, sand[i])
		else:
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
	if terrain == Terrain.ALPINE:
		return _build_alpine(grid_n, world_size)
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


func _build_alpine(n: int, world_size: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = alpine_seed
	var angle := rng.randf_range(-PI, PI)
	var phase := rng.randf_range(-PI, PI)
	var warp := FastNoiseLite.new()
	warp.seed = alpine_seed
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp.frequency = 2.8 / world_size
	warp.fractal_octaves = 3
	var ridges := FastNoiseLite.new()
	ridges.seed = alpine_seed + 37
	ridges.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridges.frequency = alpine_density / world_size
	ridges.fractal_octaves = 5
	ridges.fractal_gain = alpine_ruggedness
	ridges.fractal_lacunarity = 2.1
	ridges.fractal_weighted_strength = 0.4
	var broad := FastNoiseLite.new()
	broad.seed = alpine_seed + 71
	broad.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	broad.frequency = 1.4 / world_size
	broad.fractal_octaves = 3
	var detail := FastNoiseLite.new()
	detail.seed = alpine_seed + 101
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 22.0 / world_size
	detail.fractal_octaves = 4
	var out := PackedFloat32Array()
	out.resize(n * n)
	var cell := world_size / float(n)
	for y in n:
		for x in n:
			var p := Vector2((float(x) + 0.5) * cell - world_size * 0.5,
				(float(y) + 0.5) * cell - world_size * 0.5)
			var q := p.rotated(angle)
			q += Vector2(warp.get_noise_2d(p.x, p.y),
				warp.get_noise_2d(p.x + world_size, p.y - world_size)) * world_size * alpine_ridge_irregularity
			var ridge := clampf(0.5 + 0.5 * ridges.get_noise_2d(q.x, q.y), 0.0, 1.0)
			var massif := 0.5 + 0.5 * broad.get_noise_2d(q.x, q.y)
			var crag := detail.get_noise_2d(q.x, q.y)
			var valley := absf(q.x / world_size
				- sin(q.y / world_size * TAU * 0.8 + phase) * 0.16)
			var valley_mask := smoothstep(alpine_valley_width_fraction * 0.15625,
				alpine_valley_width_fraction, valley)
			var relief: float = ((0.22 * massif + 0.78 * pow(ridge, 1.7))
				* (1.0 - alpine_valley_depth_fraction + alpine_valley_depth_fraction * valley_mask))
			relief += crag * (0.02 + 0.035 * valley_mask) * ridge * alpine_surface_detail
			relief += 0.025 * (q.y / world_size + 0.5)
			out[y * n + x] = base_height_m + mountain_height_m * maxf(0.02, relief)
	return out


func find_summits(heights: PackedFloat32Array, n: int, world_size: float,
		count: int = 8) -> PackedVector2Array:
	var points := PackedVector2Array()
	if heights.size() != n * n:
		return points
	var low := INF
	var high := -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	if high - low < 0.25:
		return points
	var stride := maxi(1, n / 64)
	var margin := maxi(stride, int(float(n) * 0.04))
	var candidates: Array[Vector3] = []
	for y in range(margin, n - margin, stride):
		for x in range(margin, n - margin, stride):
			var h := heights[y * n + x]
			if h < low + (high - low) * 0.35:
				continue
			var peak := true
			for dy in [-stride, 0, stride]:
				for dx in [-stride, 0, stride]:
					if heights[(y + dy) * n + x + dx] > h:
						peak = false
			if peak:
				candidates.append(Vector3((float(x) + 0.5) / float(n) * world_size - world_size * 0.5,
					h, (float(y) + 0.5) / float(n) * world_size - world_size * 0.5))
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.y > b.y if a.y != b.y else a.x < b.x)
	for candidate in candidates:
		var point := Vector2(candidate.x, candidate.z)
		var separate := true
		for selected in points:
			if selected.distance_to(point) < world_size * 0.13:
				separate = false
		if separate:
			points.append(point)
			if points.size() == count:
				break
	return points


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
