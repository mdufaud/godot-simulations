extends "res://tests/test_case.gd"

const MOUNTAIN := preload("res://resources/terrain/presets/montagne.tres")
const N := 96
const WORLD := 64.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var preset: TerrainPreset = MOUNTAIN.duplicate(true)
	preset.alpine_seed = 104729
	var seed_a := preset.build_seed(N, WORLD)
	var same_seed := preset.build_seed(N, WORLD)
	_check(seed_a == same_seed, "alpine generation changed for a repeated seed")
	preset.alpine_seed = 104759
	var other_seed := preset.build_seed(N, WORLD)
	_check(seed_a != other_seed, "different alpine seeds produced identical terrain")
	_check(_valid_heights(seed_a), "alpine terrain contains invalid or negative heights")
	_check(_range(seed_a) > 1.0, "alpine terrain has insufficient relief")
	var defaults := preset.duplicate(true)
	var profile_changes := {
		"alpine_density": 3.1,
		"alpine_ruggedness": 0.62,
		"alpine_valley_width_fraction": 0.27,
		"alpine_valley_depth_fraction": 0.31,
		"alpine_ridge_irregularity": 0.24,
		"alpine_surface_detail": 1.7,
	}
	for property in profile_changes:
		var variant: TerrainPreset = defaults.duplicate(true)
		variant.set(property, profile_changes[property])
		var varied: PackedFloat32Array = variant.build_seed(N, WORLD)
		_check(_valid_heights(varied), "Alpine %s produced invalid heights" % property)
		_check(varied != other_seed, "Alpine %s did not affect the generated terrain" % property)
	var custom: TerrainPreset = defaults.duplicate(true)
	custom.alpine_seed = 391
	custom.alpine_density = 3.1
	custom.alpine_ruggedness = 0.62
	custom.alpine_valley_width_fraction = 0.27
	custom.alpine_valley_depth_fraction = 0.31
	custom.alpine_ridge_irregularity = 0.24
	custom.alpine_surface_detail = 1.7
	var custom_a: PackedFloat32Array = custom.build_seed(N, WORLD)
	_check(custom_a == custom.build_seed(N, WORLD),
		"custom Alpine generation changed for a repeated seed and profile")
	_check(_valid_heights(custom_a) and _range(custom_a) > 1.0,
		"custom Alpine profile produced invalid or insufficiently rugged terrain")

	var alpine_peaks := preset.find_summits(seed_a, N, WORLD)
	_check(alpine_peaks.size() >= 2, "alpine terrain did not produce multiple summit placements")
	_check(_separated(alpine_peaks, WORLD * 0.13),
		"alpine summit placements are not separated")

	preset.alpine_seed = 104729
	var state := preset.build_state(N, WORLD)
	var snow: PackedFloat32Array = state.snow
	var has_snow := false
	for i in seed_a.size():
		if snow[i] > 0.0:
			has_snow = true
	_check(not has_snow, "Mountain terrain seed initialized snow")

	var flat := TerrainPreset.new()
	var flat_heights := flat.build_seed(N, WORLD)
	_check(flat.find_summits(flat_heights, N, WORLD).is_empty(),
		"summit finder returned peaks for a flat field")

	var synthetic_n := 64
	var synthetic_world := 32.0
	var synthetic := PackedFloat32Array()
	synthetic.resize(synthetic_n * synthetic_n)
	synthetic.fill(0.25)
	var centres := [Vector2i(14, 16), Vector2i(48, 46)]
	for y in synthetic_n:
		for x in synthetic_n:
			for centre in centres:
				var distance := Vector2(x - centre.x, y - centre.y).length()
				synthetic[y * synthetic_n + x] = maxf(synthetic[y * synthetic_n + x],
					0.25 + maxf(0.0, 1.2 * (1.0 - distance / 8.0)))
	var found := flat.find_summits(synthetic, synthetic_n, synthetic_world)
	_check(found.size() == 2, "summit finder missed one of two separated synthetic peaks")
	var cell := synthetic_world / float(synthetic_n)
	for centre in centres:
		var target := Vector2((float(centre.x) + 0.5) * cell - synthetic_world * 0.5,
			(float(centre.y) + 0.5) * cell - synthetic_world * 0.5)
		var nearest := INF
		for point in found:
			nearest = minf(nearest, point.distance_to(target))
		_check(nearest <= cell,
			"summit finder did not locate synthetic summit near %s (%.3f m)" % [target, nearest])
	_check(_separated(found, synthetic_world * 0.13),
		"synthetic summit placements are not separated")
	var solver := HeightfieldTerrain.new()
	solver.submit_queries(found)
	var generation: int = solver._query_generation
	var stale := PackedVector4Array([Vector4(3.0, 0.0, 0.0, 1.0)])
	solver.free_render()
	solver._apply_query_results(stale, generation)
	_check(not solver._query_has_pending and solver.latest_results().is_empty(),
		"terrain reset retained pending points or accepted a stale height query")
	_finish("alpine_terrain")


func _valid_heights(heights: PackedFloat32Array) -> bool:
	if heights.size() != N * N:
		return false
	for height in heights:
		if is_nan(height) or is_inf(height) or height < 0.0:
			return false
	return true


func _range(heights: PackedFloat32Array) -> float:
	var low := INF
	var high := -INF
	for height in heights:
		low = minf(low, height)
		high = maxf(high, height)
	return high - low


func _separated(points: PackedVector2Array, distance: float) -> bool:
	for i in points.size():
		for j in range(i + 1, points.size()):
			if points[i].distance_to(points[j]) < distance:
				return false
	return true
