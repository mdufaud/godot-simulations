extends "res://tests/test_case.gd"
## GPU contracts for the multi-material heightfield: mass conservation across
## every pass, repose-angle behaviour (dry vs water-saturated), snow cohesion
## on slopes, PACK compaction, melt balance, deterministic reseeding, and the
## physics-sync contract of the point-query pass (GPU bilinear vs a CPU
## replica on the same readback).

const WORLD := 4.0
const DT := 1.0 / 60.0
const TextureReadback := preload("res://scripts/core/texture_readback.gd")

## Active solver grid: the suite runs on the Low tier (256²) to keep the
## GDScript-side field scans fast; every contract is grid-independent.
var _n := 256


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var demo = load("res://scenes/terrain_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.apply_preset(1)  # Dunes: dry sand, no auto pours.
	await _wait_init(demo)
	_check(demo.solver.initialized and demo.texture_bound, "terrain did not initialize")
	if not demo.solver.initialized or not demo.texture_bound:
		demo.queue_free()
		await process_frame
		_finish("terrain")
		return
	# Deterministic stepping: the demo's own _process drives brushes and the
	# per-frame step; the suite drives step_render itself.
	demo.set_process(false)
	demo.set_physics_process(false)
	demo.quality.set_tier(SimQualityProfile.Tier.LOW)
	await _wait_init(demo, false)
	_check(demo.solver.initialized, "Low tier re-init failed")
	_n = demo.solver.grid_n

	await _check_conservation(demo)
	await _check_dry_repose(demo)
	await _check_wet_repose(demo)
	await _check_snow_cohesion(demo)
	await _check_pack(demo)
	await _check_melt_balance(demo)
	await _check_freeze_balance(demo)
	await _check_snowfall_source(demo)
	await _check_hydrology(demo)
	await _check_scene_reset(demo)
	await _check_determinism(demo)
	await _check_query_sync(demo)
	await _check_quality_tiers(demo)

	RenderingServer.call_on_render_thread(demo.solver.free_render)
	await _frames(2)
	_check(not demo.solver.get_height_tex_rid().is_valid()
		and not demo.solver.get_flux_tex_rid().is_valid()
		and not demo.solver.get_velocity_tex_rid().is_valid(),
		"terrain teardown left field, flux or velocity resources valid")
	demo.queue_free()
	await process_frame
	_finish("terrain")


## Freeze the demo, reseed and step manually. Mirrors the controller's
## restart contract: teardown (free_render) before the next init_render.
func _reseed(demo: Node, sand: PackedFloat32Array, water: PackedFloat32Array,
		snow: PackedFloat32Array, sediment: PackedFloat32Array = PackedFloat32Array()) -> void:
	demo.solver.brush.clear()
	demo.solver.contact_brush.clear()
	demo.solver.set_seed_channels(sand, water, snow, sediment)
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)


func _flat(value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_n * _n)
	out.fill(value)
	return out


func _bump(base: float, height: float, radius_cells: float) -> PackedFloat32Array:
	var out := _flat(base)
	var n := _n
	var c := n / 2
	for y in n:
		for x in n:
			var d := Vector2(x - c, y - c).length()
			if d < radius_cells:
				out[y * n + x] = base + height * (1.0 - d / radius_cells)
	return out


## Render-thread readback of the full rgba32f field as floats (RGBA/cell).
func _field(demo: Node) -> PackedFloat32Array:
	var data: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_height_tex_rid(), 0)
	if data.is_empty():
		_check(false, "terrain texture readback timed out")
	return data.to_float32_array()


func _channel_sums(field: PackedFloat32Array) -> Vector4:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var a := 0.0
	for i in field.size() / 4:
		r += field[i * 4]
		g += field[i * 4 + 1]
		b += field[i * 4 + 2]
		a += field[i * 4 + 3]
	return Vector4(r, g, b, a)


func _step(demo: Node, steps: int, dt: float = DT) -> void:
	for i in steps:
		RenderingServer.call_on_render_thread(demo.solver.step_render.bind(dt))
		await _frames(1)


## Every pass conserves Σ(R+G+B+A) when melt and evaporation are off: tool is
## idle, water/snow/sand fluxes only move mass between cells, and the climate
## in-place pass reduces to the (conserving) dry-sediment deposition branch.
func _check_conservation(demo: Node) -> void:
	demo.apply_preset(1)  # reseed through the demo path, then override
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	await _reseed(demo, _bump(0.3, 0.2, 40.0), _flat(0.005), _flat(0.08))
	demo.solver.repose_deg = 45.0
	demo.solver.snow_repose_deg = 2.0  # force snow creep
	demo.solver.stochasticity = 0.2
	var before := _channel_sums(await _field(demo))
	await _step(demo, 120)
	var after := _channel_sums(await _field(demo))
	var total_before: float = before.x + before.y + before.z + before.w
	var total_after: float = after.x + after.y + after.z + after.w
	var drift: float = absf(total_after - total_before) / total_before
	_check(drift < 1e-4,
		"mass drifted %.4f%% across 120 steps (%.4f -> %.4f)" % [drift * 100.0,
			total_before, total_after])
	_check(after.y > 0.001, "water vanished without evaporation")
	_check(after.z > 0.001, "snow vanished without melt")


## A POUR cone stops at the repose angle: pour gently, let the flow relax to
## its fixpoint, then the steepest neighbour slope must sit at tan(repose).
func _check_dry_repose(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.15
	demo.solver.repose_deg = 33.0
	var n := _n
	var sand := _flat(0.05)
	demo.solver.set_seed_channels(sand, _flat(0.0), _flat(0.0))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	demo.solver.brush.mode = TerrainBrush.POUR
	demo.solver.brush.pos_m = Vector2.ZERO
	demo.solver.brush.radius_m = 0.25
	demo.solver.brush.strength = 0.4
	await _step(demo, 60)
	demo.solver.brush.clear()
	await _step(demo, 200)
	var field := await _field(demo)
	var cell := WORLD / float(n)
	var max_slope := 0.0
	var at_repose := 0
	var tan33 := tan(deg_to_rad(33.0))
	for y in range(1, n - 1, 2):
		for x in range(1, n - 1, 2):
			var h: float = field[(y * n + x) * 4]
			var slope: float = maxf(
				absf(field[(y * n + x + 1) * 4] - h),
				absf(field[((y + 1) * n + x) * 4] - h)) / cell
			if slope > max_slope:
				max_slope = slope
			if slope > tan33 * 0.5:
				at_repose += 1
	_check(max_slope <= tan33 * 1.12 + 1e-3,
		"repose slope %.3f exceeds tan(33°)=%.3f by more than 12%%" % [max_slope, tan33])
	_check(at_repose > 50, "pour cone never reached the repose angle (flat?)")
	demo.solver.repose_deg = 30.0  # config default for later sections


## Compare dry and saturated repose on the same cone while holding all hydraulic
## transfers still; only the wet-cohesion gain changes between the two runs.
func _check_wet_repose(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.repose_deg = 33.0
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.infiltration_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	demo.solver.water_sat_m = 0.04
	var n := _n
	var cell := WORLD / float(n)
	var centre := n / 2
	var radius_cells := 12.0
	var sand := _flat(0.05)
	var slope_height := tan(deg_to_rad(40.0)) * cell
	for y in n:
		for x in n:
			var distance := Vector2(x - centre, y - centre).length()
			if distance <= radius_cells:
				sand[y * n + x] += maxf(radius_cells - distance, 0.0) * slope_height
	var water := _flat(0.05)
	demo.solver.wet_gain = 0.0
	await _reseed(demo, sand, water, _flat(0.0), _flat(0.0))
	await _step(demo, 180, 0.0)
	var dry_field := await _field(demo)
	var dry_slope := _max_sand_slope(dry_field, n, cell)
	demo.solver.wet_gain = 0.6
	await _reseed(demo, sand, water, _flat(0.0), _flat(0.0))
	await _step(demo, 180, 0.0)
	var wet_field := await _field(demo)
	var wet_slope := _max_sand_slope(wet_field, n, cell)
	var dry := tan(deg_to_rad(33.0))
	var wet_target := dry * (1.0 + 0.6)
	_check(dry_slope <= dry * 1.2 + 0.02,
		"dry cone slope %.3f exceeds dry repose %.3f" % [dry_slope, dry])
	_check(wet_slope > dry_slope + 0.08,
		"saturated cone slope %.3f did not exceed dry control %.3f" % [wet_slope, dry_slope])
	_check(wet_slope <= wet_target * 1.2 + 0.02,
		"saturated cone slope %.3f exceeds wet repose %.3f" % [wet_slope, wet_target])
	demo.solver.wet_gain = 0.6


func _max_sand_slope(field: PackedFloat32Array, n: int, cell: float) -> float:
	var max_slope := 0.0
	for y in range(1, n - 1):
		for x in range(1, n - 1):
			var i := (y * n + x) * 4
			var slope := maxf(
				absf(field[i + 4] - field[i]),
				absf(field[i + n * 4] - field[i])) / cell
			max_slope = maxf(max_slope, slope)
	return max_slope


## Snow cohesion: a sharp snow spike (strong curvature) holds above its
## cohesion angle and spreads below it. A uniform over-angle plane stays
## metastable by design — the flux is curvature-driven (crests erode).
func _check_snow_cohesion(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.snow_repose_deg = 50.0
	demo.solver.snow_flow_rate = 0.15
	var n := _n
	var sand := _flat(0.3)
	# Linear cone with a ~16° flank: safely between the release (5°) and
	# cohesion (50°) thresholds (thresholds are per-cell height steps:
	# tan(angle)·cell_size). The curvature-driven flux needs a slope that is
	# everywhere above the release angle, not just at a kink.
	var snow := _flat(0.02)
	var c := n / 2
	var flank := tan(deg_to_rad(16.0)) * WORLD / float(n)
	for y in n:
		for x in n:
			var d := Vector2(x - c, y - c).length()
			snow[y * n + x] += maxf(0.5 - d * flank, 0.0)
	demo.solver.set_seed_channels(sand, _flat(0.0), snow)
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	await _step(demo, 150)
	var held := await _field(demo)
	var peak_held := 0.0
	for i in held.size() / 4:
		peak_held = maxf(peak_held, held[i * 4 + 2])
	_check(peak_held > 0.45,
		"cohesive snow spike collapsed under 50° cohesion (peak %.3f)" % peak_held)
	demo.solver.snow_repose_deg = 5.0
	await _step(demo, 600)
	var released := _channel_sums(await _field(demo))
	var field := await _field(demo)
	var peak := 0.0
	for i in field.size() / 4:
		peak = maxf(peak, field[i * 4 + 2])
	_check(peak < peak_held * 0.85,
		"low-cohesion snow did not spread the spike (peak %.3f -> %.3f)"
			% [peak_held, peak])
	# Cone volume: radius height/flank cells → π·r²·h/3.
	var cone_radius := 0.5 / (tan(deg_to_rad(16.0)) * WORLD / float(n))
	var seeded_snow: float = 0.02 * float(n * n) \
		+ PI * cone_radius * cone_radius * 0.5 / 3.0
	_check(absf(seeded_snow - released.z) < 0.05 * released.z,
		"snow flux lost mass (%.3f vs seeded %.3f)" % [released.z, seeded_snow])


## PACK under a resting contact brush compacts: snow volume shrinks inside the
## disc, part returns as water (pressure melt), and the surface settles.
func _check_pack(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	var snow := _flat(0.12)
	demo.solver.set_seed_channels(_flat(0.3), _flat(0.0), snow)
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	var n := _n
	var brush_centre := Vector2.ZERO
	var brush_radius := 0.4
	var before := _disk_sums(await _field(demo), n, brush_centre, brush_radius)
	demo.solver.contact_brush.mode = TerrainBrush.PACK
	demo.solver.contact_brush.pos_m = brush_centre
	demo.solver.contact_brush.radius_m = brush_radius
	demo.solver.contact_brush.strength = 2.0
	await _step(demo, 90)
	demo.solver.contact_brush.clear()
	var after := _disk_sums(await _field(demo), n, brush_centre, brush_radius)
	_check(after.z < before.z * 0.5,
		"PACK did not compact snow in the disc (%.3f -> %.3f)" % [before.z, after.z])
	_check(after.y > before.y, "PACK pressure melt produced no water")
	var field := await _field(demo)
	var centre_height: float = field[(n / 2 * n + n / 2) * 4] + field[(n / 2 * n + n / 2) * 4 + 2]
	_check(centre_height < 0.3 + 0.12 - 0.03,
		"packed surface did not settle below the fresh-snow surface (%.3f)" % centre_height)


## Channel sums over a world-space disc — the brush-local mass contracts.
func _disk_sums(field: PackedFloat32Array, n: int, centre: Vector2, radius: float) -> Vector4:
	var sums := Vector4()
	var c := Vector2i(int((centre.x / WORLD + 0.5) * float(n)), int((centre.y / WORLD + 0.5) * float(n)))
	var r_cells := int(radius / WORLD * float(n))
	for y in range(maxi(c.y - r_cells, 0), mini(c.y + r_cells + 1, n)):
		for x in range(maxi(c.x - r_cells, 0), mini(c.x + r_cells + 1, n)):
			if Vector2(x - c.x, y - c.y).length() > float(r_cells):
				continue
			var i := (y * n + x) * 4
			sums += Vector4(field[i], field[i + 1], field[i + 2], field[i + 3])
	return sums


## Melt moves snow into water 1:1 with no other losses (evap off).
func _check_melt_balance(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.05
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.set_seed_channels(_flat(0.3), _flat(0.0), _flat(0.1))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	var before := _channel_sums(await _field(demo))
	await _step(demo, 120)
	var after := _channel_sums(await _field(demo))
	var snow_loss: float = before.z - after.z
	var water_gain: float = after.y - before.y
	_check(snow_loss > 0.0, "melt consumed no snow")
	_check(absf(snow_loss - water_gain) < 0.01 * before.z,
		"melt balance off: snow lost %.4f, water gained %.4f" % [snow_loss, water_gain])
	_check(after.z < before.z * 0.5, "snow survived 2 s of 0.05 m/s melt")


## Freeze converts standing water into snow inside each cell: G drops, B
## rises by the same amount, total unchanged.
func _check_freeze_balance(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.01
	await _reseed(demo, _flat(0.25), _flat(0.05), _flat(0.0))
	var before := _channel_sums(await _field(demo))
	await _step(demo, 120)  # 2 s at 0.01 m/s freezes 0.02 m of the 0.05 m
	var after := _channel_sums(await _field(demo))
	var frozen: float = after.z - before.z
	var dried: float = before.y - after.y
	_check(frozen > 0.005 * float(_n * _n), "freeze moved no water (%.1f)" % frozen)
	_check(absf(frozen - dried) < 0.01 * dried,
		"freeze balance off: snow +%.1f vs water -%.1f" % [frozen, dried])
	var total_before: float = before.x + before.y + before.z + before.w
	var total_after: float = after.x + after.y + after.z + after.w
	_check(absf(total_after - total_before) < 1e-4 * total_before,
		"freeze changed total mass")
	demo.solver.freeze_rate_m_s = 0.0


## Snowfall is the sky's source term: exactly rate·dt·cells lands per step.
func _check_snowfall_source(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.002
	await _reseed(demo, _flat(0.25), _flat(0.0), _flat(0.0))
	var before := _channel_sums(await _field(demo))
	await _step(demo, 60)  # 1 s -> 2 mm everywhere
	var after := _channel_sums(await _field(demo))
	var expected := 0.002 * float(_n * _n)
	var gained: float = after.z - before.z
	_check(absf(gained - expected) < 0.02 * expected,
		"snowfall deposited %.1f, expected %.1f" % [gained, expected])
	demo.solver.snowfall_rate_m_s = 0.0


func _check_hydrology(demo: Node) -> void:
	var suite_n := _n
	_n = 64
	demo.solver.grid_n = _n
	demo.apply_preset(1)
	await _wait_init(demo, false)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.0
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.snowline_m = -1.0
	demo.solver.stochasticity = 0.0
	demo.solver.deposition_gain = 0.6
	demo.solver.infiltration_rate_m_s = 0.0
	await _check_hydro_conservation(demo)
	await _check_hydro_sources(demo)
	await _check_infiltration(demo)
	await _check_sediment_transport(demo)
	await _check_inertial_flow(demo)
	await _check_closed_basin(demo)
	await _check_hydro_stability(demo)
	await _check_summit_source_budget(demo)
	await _check_sculpt_tools(demo)
	_n = suite_n
	demo.solver.grid_n = suite_n
	demo.apply_preset(1)
	await _wait_init(demo, false)


func _check_hydro_conservation(demo: Node) -> void:
	var sand := _bump(0.3, 0.12, 18.0)
	var water := _flat(0.008)
	var snow := _flat(0.004)
	var sediment := _flat(0.001)
	demo.solver.set_seed_channels(sand, water, snow, sediment)
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	var before := _channel_sums(await _field(demo))
	await _step(demo, 60)
	var after := _channel_sums(await _field(demo))
	var gb_before := before.y + before.z
	var gb_after := after.y + after.z
	var ra_before := before.x + before.w
	var ra_after := after.x + after.w
	_check(absf(gb_after - gb_before) <= 1e-4 * maxf(gb_before, 1.0),
		"hydraulic G+B drifted %.6f -> %.6f" % [gb_before, gb_after])
	_check(absf(ra_after - ra_before) <= 1e-4 * maxf(ra_before, 1.0),
		"solid R+A drifted %.6f -> %.6f" % [ra_before, ra_after])


func _check_hydro_sources(demo: Node) -> void:
	var cells := float(_n * _n)
	var dt := 0.5
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.rain_rate_m_s = 0.002
	demo.solver.uplift_rate_m_s = 0.0
	await _reseed(demo, _flat(0.2), _flat(0.0), _flat(0.0), _flat(0.0))
	var before := _channel_sums(await _field(demo))
	await _step(demo, 1, dt)
	var after := _channel_sums(await _field(demo))
	_check(absf(after.y - before.y - 0.002 * dt * cells) < 0.01,
		"rain budget differs from rate·dt·cells")
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.DOME
	demo.solver.uplift_radius_fraction = 0.3
	demo.solver.uplift_rate_m_s = 0.003
	await _reseed(demo, _flat(0.2), _flat(0.0), _flat(0.0), _flat(0.0))
	before = _channel_sums(await _field(demo))
	await _step(demo, 1, dt)
	after = _channel_sums(await _field(demo))
	var uplift_expected := 0.0
	for y in _n:
		for x in _n:
			var p := (Vector2(x, y) + Vector2(0.5, 0.5)) / float(_n) - Vector2(0.5, 0.5)
			uplift_expected += 0.003 * dt * exp(-3.0 * p.length_squared() / (0.3 * 0.3))
	_check(absf(after.x - before.x - uplift_expected) < 1e-3,
		"dome uplift budget differs from its configured rate (%.6f vs %.6f)"
			% [after.x - before.x, uplift_expected])
	_check(absf(after.y - before.y) < 0.01, "uplift changed water budget")
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.snowline_m = 0.0
	demo.solver.snowfall_rate_m_s = 0.002
	var snowline_sand := _flat(0.1)
	for y in _n:
		for x in range(_n / 2, _n):
			snowline_sand[y * _n + x] = 0.3
	demo.solver.snowline_m = 0.2
	await _reseed(demo, snowline_sand, _flat(0.0), _flat(0.0), _flat(0.0))
	before = _channel_sums(await _field(demo))
	await _step(demo, 1, dt)
	after = _channel_sums(await _field(demo))
	var snow_expected := 0.002 * dt * cells * 0.5
	_check(absf(after.z - before.z - snow_expected) < 0.01,
		"snowline snowfall budget differs from eligible cells")
	_check(absf(after.y - before.y) < 0.01, "snowline snowfall changed water budget")
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.snowline_m = -1.0


func _check_infiltration(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	demo.solver.infiltration_rate_m_s = 0.01
	var cells := float(_n * _n)
	var rate: float = demo.solver.infiltration_rate_m_s
	var dt := 0.25
	await _reseed(demo, _flat(0.2), _flat(0.05), _flat(0.0), _flat(0.002))
	var before := _channel_sums(await _field(demo))
	await _step(demo, 1, dt)
	var after := _channel_sums(await _field(demo))
	var removed := before.y - after.y
	var expected := minf(rate * dt, 0.05) * cells
	_check(absf(removed - expected) < 1e-4 * maxf(expected, 1.0),
		"infiltration water budget differs (%.6f vs %.6f)" % [removed, expected])
	_check(absf(after.x + after.w - before.x - before.w)
		<= 1e-4 * maxf(before.x + before.w, 1.0),
		"infiltration changed R+A mass")

	await _reseed(demo, _flat(0.2), _flat(0.0), _flat(0.0), _flat(0.01))
	before = _channel_sums(await _field(demo))
	await _step(demo, 1, DT)
	after = _channel_sums(await _field(demo))
	_check(after.w < 1e-6 and after.x > before.x,
		"dry suspended sediment did not settle onto the sand")
	_check(absf(after.x + after.w - before.x - before.w)
		<= 1e-4 * maxf(before.x + before.w, 1.0),
		"dry sediment settling changed R+A mass")

	demo.solver.infiltration_rate_m_s = 10.0
	await _reseed(demo, _flat(0.2), _flat(0.005), _flat(0.0), _flat(0.0))
	await _step(demo, 1, 1.0)
	var field := await _field(demo)
	var valid := true
	for i in field.size() / 4:
		if is_nan(field[i]) or is_inf(field[i]) or field[i] < -1e-7:
			valid = false
			break
	_check(valid, "high infiltration rate produced invalid or negative channels")
	demo.solver.infiltration_rate_m_s = 0.0


func _check_sediment_transport(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	demo.solver.sediment_capacity = 0.8
	var sand := _flat(0.2)
	var water := _flat(0.012)
	var sediment := _flat(0.0)
	var c := _n / 2
	sediment[c * _n + c] = 0.08
	await _reseed(demo, sand, water, _flat(0.0), sediment)
	var flux := PackedFloat32Array()
	flux.resize(_n * _n * 4)
	flux[(c * _n + c) * 4] = 0.001
	RenderingServer.call_on_render_thread(_seed_hydro_flux.bind(
		demo.solver.get_flux_tex_rid(), flux.to_byte_array()))
	await _frames(1)
	var before := await _field(demo)
	await _step(demo, 40)
	var after := await _field(demo)
	var destination := (c * _n + c + 1) * 4 + 3
	_check(after[destination] > 1e-4,
		"sediment did not arrive in the downstream cell with erosion/deposition disabled")
	var before_sums := _channel_sums(before)
	var after_sums := _channel_sums(after)
	var before_ra := before_sums.x + before_sums.w
	var after_ra := after_sums.x + after_sums.w
	_check(absf(after_ra - before_ra) <= 1e-4 * maxf(before_ra, 1.0),
		"sediment transport changed R+A mass")
	_check(absf(after_sums.w - before_sums.w) <= 1e-4 * before_sums.w,
		"transport lost suspended sediment with erosion/deposition disabled")


func _check_inertial_flow(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.stochasticity = 0.0
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	await _reseed(demo, _flat(0.2), _flat(0.02), _flat(0.0), _flat(0.0))
	var flux := PackedFloat32Array()
	flux.resize(_n * _n * 4)
	flux[((_n / 2) * _n + _n / 2) * 4] = 0.001
	var flux_bytes := flux.to_byte_array()
	RenderingServer.call_on_render_thread(_seed_hydro_flux.bind(demo.solver.get_flux_tex_rid(), flux_bytes))
	await _frames(1)
	var seeded_flux := await _hydro_flux(demo)
	var centre_flux := ((_n / 2) * _n + _n / 2) * 4
	_check(absf(seeded_flux[centre_flux] - 0.001) < 1e-6,
		"inertial flux fixture did not upload to the center cell")
	await _step(demo, 1)
	var flowed := await _hydro_flux(demo)
	var velocity := await _hydro_velocity(demo)
	var centre_velocity := ((_n / 2) * _n + _n / 2) * 2
	_check(seeded_flux.size() == flowed.size() and flowed[centre_flux] > 0.0
		and velocity.size() == _n * _n * 2
		and absf(velocity[centre_velocity]) + absf(velocity[centre_velocity + 1]) > 0.0,
		"inertial flux did not produce a persistent outflow and velocity")


func _check_closed_basin(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	demo.solver.repose_deg = 89.0
	var c := _n / 2
	var basin := _flat(0.05)
	var water := _flat(0.0)
	for y in _n:
		for x in _n:
			var dx := absi(x - c)
			var dy := absi(y - c)
			if dx < 12 and dy < 12:
				basin[y * _n + x] = 0.15
				water[y * _n + x] = 0.05
				if x == c and y == c:
					water[y * _n + x] += 0.005
			elif dx == 12 and dy <= 12 or dy == 12 and dx <= 12:
				basin[y * _n + x] = 0.4
				if x == c + 12 and dy <= 3:
					basin[y * _n + x] = 0.23
	await _reseed(demo, basin, water, _flat(0.0), _flat(0.0))
	await _step(demo, 1, 0.0)
	await _step(demo, 240)
	var levelled := await _field(demo)
	var level_min := INF
	var level_max := -INF
	for y in range(c - 11, c + 12):
		for x in range(c - 11, c + 12):
			var i := (y * _n + x) * 4
			var level: float = levelled[i] + levelled[i + 1]
			level_min = minf(level_min, level)
			level_max = maxf(level_max, level)
	_check(level_max - level_min < 0.003,
		"closed basin failed to level before spilling (spread %.5f m)" % (level_max - level_min))
	demo.solver.rain_rate_m_s = 0.04
	var rain_steps := 180
	await _step(demo, rain_steps)
	var spilled := await _field(demo)
	var outside_water := 0.0
	var outside_cells := 0
	var high_rim_water := 0.0
	var high_rim_cells := 0
	for y in _n:
		for x in _n:
			var dx := absi(x - c)
			var dy := absi(y - c)
			var idx := (y * _n + x) * 4
			if (dx == 12 and dy <= 12 or dy == 12 and dx <= 12) \
					and not (x == c + 12 and dy <= 3):
				high_rim_water += spilled[idx + 1]
				high_rim_cells += 1
			elif dx > 12 or dy > 12:
				outside_water += spilled[idx + 1]
				outside_cells += 1
	var expected_rain := 0.04 * float(rain_steps) * DT
	var total_before_rain := _channel_sums(levelled).y
	var total_after_rain := _channel_sums(spilled).y
	var outside_rain := expected_rain * float(outside_cells)
	var rim_rain := expected_rain * float(high_rim_cells)
	_check(outside_water > outside_rain + 1.0,
		"water did not discharge through the notch (outside %.3f, uniform rain %.3f)"
			% [outside_water, outside_rain])
	_check(high_rim_water <= rim_rain + 0.01,
		"water crossed the high rim (rim %.3f, uniform rain %.3f)"
			% [high_rim_water, rim_rain])
	_check(absf(total_after_rain - total_before_rain
		- expected_rain * float(_n * _n)) < 0.01,
		"closed basin water budget differs (%.3f vs expected gain %.3f)"
			% [total_after_rain - total_before_rain, expected_rain * float(_n * _n)])
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.repose_deg = 33.0


func _check_hydro_stability(demo: Node) -> void:
	demo.solver.erosion_rate = 0.15
	demo.solver.deposition_gain = 0.6
	demo.solver.rain_rate_m_s = 0.001
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NOISE
	demo.solver.uplift_rate_m_s = 0.001
	demo.solver.snowline_m = 0.15
	demo.solver.snowfall_rate_m_s = 0.0005
	await _reseed(demo, _bump(0.2, 0.08, 12.0), _flat(0.005), _flat(0.0), _flat(0.0))
	var before := _channel_sums(await _field(demo))
	await _step(demo, 300)
	var field := await _field(demo)
	var after := _channel_sums(field)
	var valid := true
	for value in field:
		if is_nan(value) or is_inf(value) or value < -1e-6:
			valid = false
			break
	_check(valid, "300 hydro steps produced invalid or negative channel values")
	var expected_hydro_gain := (0.001 + 0.0005) * 300.0 * DT * float(_n * _n)
	var actual_hydro_gain := after.y + after.z - before.y - before.z
	_check(absf(actual_hydro_gain - expected_hydro_gain)
		<= 1e-4 * maxf(expected_hydro_gain, 1.0),
		"300-step rain/snow budget differs: %.6f vs %.6f"
			% [actual_hydro_gain, expected_hydro_gain])
	var expected_uplift_cap := 0.001 * 300.0 * DT * float(_n * _n)
	var actual_solid_gain := after.x + after.w - before.x - before.w
	_check(actual_solid_gain >= -1e-4 * maxf(expected_uplift_cap, 1.0)
		and actual_solid_gain <= expected_uplift_cap * 1.001 + 1e-4,
		"300-step R+A gain %.6f outside uplift budget [0, %.6f]"
			% [actual_solid_gain, expected_uplift_cap])
	var velocity := await _hydro_velocity(demo)
	var velocity_valid := velocity.size() == _n * _n * 2
	var max_speed := 0.0
	for i in velocity.size() / 2:
		var vx: float = velocity[i * 2]
		var vy: float = velocity[i * 2 + 1]
		if is_nan(vx) or is_inf(vx) or is_nan(vy) or is_inf(vy):
			velocity_valid = false
			break
		max_speed = maxf(max_speed, Vector2(vx, vy).length())
	var max_velocity := (WORLD / float(_n)) / (DT / float(HeightfieldTerrain.RIVER_ITERATIONS))
	_check(velocity_valid and max_speed <= max_velocity + 1e-4,
		"300-step velocity invalid or exceeded substep cap (%.6f / %.6f)"
			% [max_speed, max_velocity])
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.snowline_m = -1.0


func _check_summit_source_budget(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.set_summit_sources(PackedVector2Array(), 1.0, 0.0)
	await _reseed(demo, _flat(0.25), _flat(0.0), _flat(0.0), _flat(0.0))
	var point := Vector2.ZERO
	var radius := 0.75
	var rate := 0.004
	var dt := 0.25
	demo.solver.set_summit_sources(PackedVector2Array([point]), radius, rate)
	var before := _channel_sums(await _field(demo))
	await _step(demo, 1, dt)
	var after := _channel_sums(await _field(demo))
	var cell := WORLD / float(_n)
	var expected := 0.0
	for y in _n:
		for x in _n:
			var position := Vector2((float(x) + 0.5) * cell - WORLD * 0.5,
				(float(y) + 0.5) * cell - WORLD * 0.5)
			var d := (position - point) / maxf(radius, cell)
			expected += rate * dt * exp(-3.0 * d.length_squared())
	_check(absf(after.y - before.y - expected) < 1e-4 * maxf(expected, 1.0),
		"summit source water budget differs (%.7f vs %.7f)"
			% [after.y - before.y, expected])
	demo.solver.set_summit_sources(PackedVector2Array(), 1.0, 0.0)


func _check_sculpt_tools(demo: Node) -> void:
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.infiltration_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.erosion_rate = 0.0
	demo.solver.deposition_gain = 0.0
	demo.solver.repose_deg = 89.0
	demo.solver.brush.pos_m = Vector2.ZERO
	demo.solver.brush.radius_m = 0.9
	demo.solver.brush.strength = 3.0
	await _reseed(demo, _flat(0.25), _flat(0.0), _flat(0.0), _flat(0.0))
	demo.solver.brush.mode = TerrainBrush.MOUNTAIN
	await _step(demo, 1)
	var raised := await _field(demo)
	var centre := (_n / 2 * _n + _n / 2) * 4
	_check(raised[centre] > 0.3,
		"Raise mountain brush did not lift the centre from its flat starting height")
	demo.solver.brush.clear()

	var bump := _bump(0.25, 0.8, 18.0)
	await _reseed(demo, bump, _flat(0.0), _flat(0.0), _flat(0.0))
	var before := await _field(demo)
	demo.solver.brush.mode = TerrainBrush.SMOOTH
	await _step(demo, 12)
	var flattened := await _field(demo)
	var before_variance := _disk_variance(before, _n, 0.2)
	var after_variance := _disk_variance(flattened, _n, 0.2)
	_check(after_variance < before_variance * 0.1,
		"Flatten brush did not reduce center variance by 90%% (%.6f -> %.6f)"
			% [before_variance, after_variance])
	demo.solver.brush.clear()
	demo.solver.repose_deg = 33.0


func _disk_variance(field: PackedFloat32Array, n: int, radius_m: float) -> float:
	var values: Array[float] = []
	var centre := Vector2i(n / 2, n / 2)
	var radius_cells := int(radius_m / WORLD * float(n))
	for y in range(centre.y - radius_cells, centre.y + radius_cells + 1):
		for x in range(centre.x - radius_cells, centre.x + radius_cells + 1):
			if Vector2(x - centre.x, y - centre.y).length() > float(radius_cells):
				continue
			values.append(field[(y * n + x) * 4])
	var mean := 0.0
	for value in values:
		mean += value
	mean /= float(values.size())
	var variance := 0.0
	for value in values:
		variance += (value - mean) * (value - mean)
	return variance / float(values.size())


func _hydro_flux(demo: Node) -> PackedFloat32Array:
	var data: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_flux_tex_rid(), 0)
	if data.is_empty():
		_check(false, "hydraulic flux readback timed out")
	return data.to_float32_array()


func _hydro_velocity(demo: Node) -> PackedFloat32Array:
	var data: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_velocity_tex_rid(), 0)
	if data.is_empty():
		_check(false, "hydraulic velocity readback timed out")
	return data.to_float32_array()


func _seed_hydro_flux(rid: RID, bytes: PackedByteArray) -> void:
	RenderingServer.get_rendering_device().texture_update(rid, 0, bytes)


## The user-reported leak: entering avalanche after thaw must not carry melt
## (or any dragged slider) across. The slab then avalanches (cohesion 13° is
## below the 24° tilt) but conserves snow up to the accounted snowfall.
func _check_scene_reset(demo: Node) -> void:
	demo.apply_preset(7)  # thaw: melt 0.06, evap 0.005
	await _frames(4)
	demo.apply_preset(6)  # avalanche: melt/evap fall back to config defaults
	# The demo's _process is disabled here, so texture_bound never rebinds;
	# wait on the solver flag only.
	await _wait_init(demo, false)
	_check(demo.solver.melt_rate_m_s == 0.0,
		"avalanche inherited melt %.4f from thaw" % demo.solver.melt_rate_m_s)
	_check(demo.solver.evap_rate_m_s == 0.02,
		"avalanche inherited evaporation %.4f" % demo.solver.evap_rate_m_s)
	_check(absf(demo.solver.snow_repose_deg - 22.0) < 0.01,
		"avalanche cohesion override not applied (%.1f — reset or override lost)"
			% demo.solver.snow_repose_deg)
	_check(absf(demo.solver.snowfall_rate_m_s - 0.001) < 1e-6,
		"avalanche snowfall override not applied (%.4f)" % demo.solver.snowfall_rate_m_s)
	var seeded := 0.3 * float(_n * _n)
	await _step(demo, 240)  # 4 s of release; snowfall adds 0.002·4 m
	var field := await _field(demo)
	var snow_sum := 0.0
	for i in field.size() / 4:
		snow_sum += field[i * 4 + 2]
	var expected := seeded + 0.002 * 4.0 * float(_n * _n)
	_check(absf(snow_sum - expected) < 0.02 * expected,
		"avalanche slab mass drifted: %.1f vs expected %.1f (melt leaked?)" % [snow_sum, expected])
	demo.apply_preset(9)
	await _wait_init(demo, false)
	_check(demo.solver.world_size == 64.0
		and demo.mountain_world_size_m == 64.0
		and demo.mountain_height_m == 12.0
		and demo._preset.mountain_height_m == 12.0
		and demo._preset.landscape_materials
		and demo.solver.rain_rate_m_s == 0.0
		and demo.solver.uplift_rate_m_s == 0.0
		and demo.solver.uplift_mode == TerrainConfig.UpliftMode.NONE
		and demo.solver.snowfall_rate_m_s == 0.0
		and demo.solver.freeze_rate_m_s == 0.0
		and demo.solver.melt_rate_m_s == 0.0
		and demo.solver.infiltration_rate_m_s == 0.0
		and not demo.view.sand_mat.get_shader_parameter("snow_enabled")
		and not demo.drying_enabled,
		"Mountain preset did not select its dry 64 m alpine defaults")
	var mountain_boot := await _field(demo)
	_check(_snow_mass(mountain_boot) == 0.0,
		"Mountain terrain initialized with snow")
	demo.solver.rain_rate_m_s = 0.04
	await _step(demo, 60)
	var mountain_rained := await _field(demo)
	_check(_snow_mass(mountain_rained) == 0.0,
		"Mountain climate or rain created snow")
	demo.solver.rain_rate_m_s = 0.04
	demo.solver.uplift_rate_m_s = 0.02
	demo.solver.snowline_m = 0.5
	demo.solver.deposition_gain = 0.1
	demo.set_drying(true)
	demo.set_drying_rate(0.4)
	demo.apply_preset(1)
	await _wait_init(demo, false)
	_check(demo.preset_idx == 1 and demo.solver.world_size == 4.0,
		"legacy preset did not restore its 4 m domain after Mountain")
	_check(demo.solver.rain_rate_m_s == 0.0
		and demo.solver.uplift_rate_m_s == 0.0
		and demo.solver.uplift_mode == TerrainConfig.UpliftMode.NONE
		and demo.solver.snowline_m == -1.0
		and demo.solver.deposition_gain == 0.6
		and demo.solver.infiltration_rate_m_s == 0.0
		and not demo.drying_enabled
		and not demo._preset.landscape_materials,
		"legacy preset inherited hydraulic parameters from Mountain")
	demo.apply_preset(6)
	await _wait_init(demo, false)
	var avalanche := await _field(demo)
	_check(demo.solver.snowfall_rate_m_s == 0.001
		and demo.view.sand_mat.get_shader_parameter("snow_enabled")
		and _snow_mass(avalanche) > 0.0,
		"legacy avalanche did not restore its snow source and material")
	demo.apply_preset(1)
	await _wait_init(demo, false)


func _snow_mass(field: PackedFloat32Array) -> float:
	var total := 0.0
	for i in field.size() / 4:
		total += field[i * 4 + 2]
	return total


## Same seed twice → bit-identical fields after the same step count: transfers
## are pure functions of both endpoint cells and the pair-hash is symmetric.
func _check_determinism(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.005
	demo.solver.stochasticity = 0.25
	demo.solver.rain_rate_m_s = 0.001
	demo.solver.uplift_rate_m_s = 0.001
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NOISE
	var sand := _bump(0.3, 0.2, 40.0)
	var water := _flat(0.006)
	demo.solver.set_seed_channels(sand, water, _flat(0.02), _flat(0.001))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	var initial_flux := await _hydro_flux(demo)
	var initial_velocity := await _hydro_velocity(demo)
	var initial_transport_zero := initial_flux.size() == _n * _n * 4 \
		and initial_velocity.size() == _n * _n * 2
	for value in initial_flux:
		if value != 0.0:
			initial_transport_zero = false
			break
	for value in initial_velocity:
		if value != 0.0:
			initial_transport_zero = false
			break
	_check(initial_transport_zero,
		"reseed initialization retained old hydraulic flux or velocity")
	await _step(demo, 90)
	var run_a := await _field(demo)
	var flux_a := await _hydro_flux(demo)
	demo.solver.set_seed_channels(sand, water, _flat(0.02), _flat(0.001))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	await _step(demo, 90)
	var run_b := await _field(demo)
	var flux_b := await _hydro_flux(demo)
	_check(run_a == run_b, "reseeded run diverged bit-for-bit (stochastic flux not deterministic)")
	_check(flux_a == flux_b, "reseeded rain/uplift run changed hydraulic flux bits")
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE


## Physics sync: GPU point queries vs the same bilinear on the CPU readback.
func _check_query_sync(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0
	var n := _n
	var sand := _bump(0.3, 0.2, 40.0)
	var snow := _flat(0.0)
	for y in n:
		for x in n:
			if Vector2(x - n * 0.7, y - n * 0.35).length() < 50.0:
				snow[y * n + x] = 0.07
	demo.solver.set_seed_channels(sand, _flat(0.004), snow)
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	var points := PackedVector2Array()
	for i in 12:
		points.append(Vector2(
			fposmod(float(i) * 0.73, 1.0) * (WORLD - 0.4) - WORLD * 0.5 + 0.2,
			fposmod(float(i) * 0.41, 1.0) * (WORLD - 0.4) - WORLD * 0.5 + 0.2))
	RenderingServer.call_on_render_thread(func():
		demo.solver.submit_queries(points))
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(0.0))
	await _frames(2)
	var results: PackedVector4Array = demo.solver.latest_results()
	_check(demo.solver.query_results_valid() and results.size() == points.size(),
		"point query readback lost or truncated (%d results)" % results.size())
	var field := await _field(demo)
	var cell := WORLD / float(n)
	var max_error := 0.0
	for i in points.size():
		var got := results[i]
		if got.w < 0.5:
			_check(false, "query result %d marked invalid" % i)
			continue
		var truth := _bilinear_total(field, n, cell, points[i])
		max_error = maxf(max_error, absf(got.x - truth))
	_check(max_error < 1e-4,
		"query heights deviate from CPU bilinear by up to %.6f m" % max_error)


func _bilinear_total(field: PackedFloat32Array, n: int, cell: float, world: Vector2) -> float:
	var g: Vector2 = (world / WORLD + Vector2(0.5, 0.5)) * float(n) - Vector2(0.5, 0.5)
	var fx: float = clampf(floorf(g.x), 0.0, float(n - 1))
	var fy: float = clampf(floorf(g.y), 0.0, float(n - 1))
	var i0 := Vector2i(int(fx), int(fy))
	var i1 := Vector2i(int(clampf(fx + 1.0, 0.0, float(n - 1))), int(clampf(fy + 1.0, 0.0, float(n - 1))))
	var tx: float = clampf(g.x - floorf(g.x), 0.0, 1.0)
	var ty: float = clampf(g.y - floorf(g.y), 0.0, 1.0)
	var c00: float = _total_at(field, n, i0)
	var c10: float = _total_at(field, n, Vector2i(i1.x, i0.y))
	var c01: float = _total_at(field, n, Vector2i(i0.x, i1.y))
	var c11: float = _total_at(field, n, i1)
	return lerpf(lerpf(c00, c10, tx), lerpf(c01, c11, tx), ty)


func _total_at(field: PackedFloat32Array, n: int, idx: Vector2i) -> float:
	var base := (idx.y * n + idx.x) * 4
	return field[base] + field[base + 2]  # sand + snow


## The shared tier framework must drive grid size and reinitialize cleanly.
func _check_quality_tiers(demo: Node) -> void:
	demo.quality.set_tier(SimQualityProfile.Tier.LOW)
	await _wait_init(demo)
	_check(demo.solver.grid_n == TerrainQualityProfile.GRID_SIZES[SimQualityProfile.Tier.LOW],
		"Low tier did not resize the solver grid (%d)" % demo.solver.grid_n)
	_check(demo.solver.iterations == TerrainQualityProfile.ITERATIONS[SimQualityProfile.Tier.LOW],
		"Low tier did not set the settle iterations (%d)" % demo.solver.iterations)
	var low_flux := await _hydro_flux(demo)
	var low_velocity := await _hydro_velocity(demo)
	_check(low_flux.size() == demo.solver.grid_n * demo.solver.grid_n * 4
		and low_velocity.size() == demo.solver.grid_n * demo.solver.grid_n * 2,
		"Low tier did not rebuild flux and velocity textures to its grid")
	demo.quality.set_tier(SimQualityProfile.Tier.MEDIUM)
	await _wait_init(demo)
	_check(demo.solver.grid_n == TerrainQualityProfile.GRID_SIZES[SimQualityProfile.Tier.MEDIUM],
		"Medium tier did not restore the solver grid (%d)" % demo.solver.grid_n)
	var medium_flux := await _hydro_flux(demo)
	var medium_velocity := await _hydro_velocity(demo)
	_check(medium_flux.size() == demo.solver.grid_n * demo.solver.grid_n * 4
		and medium_velocity.size() == demo.solver.grid_n * demo.solver.grid_n * 2,
		"Medium tier did not rebuild flux and velocity textures to its grid")
	await _step(demo, 10)


## Wait for the solver to (re)initialize with a wall-clock deadline instead of
## a fixed frame budget. [param require_bound] also waits for the height
## texture to be bound, which the reset path does not rebind.
func _wait_init(demo: Node, require_bound: bool = true, timeout_ms: int = 10000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if demo.solver.initialized and (demo.texture_bound or not require_bound):
			return


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
