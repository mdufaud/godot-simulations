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
	await _check_scene_reset(demo)
	await _check_determinism(demo)
	await _check_query_sync(demo)
	await _check_quality_tiers(demo)

	demo.queue_free()
	await process_frame
	_finish("terrain")


## Freeze the demo, reseed and step manually. Mirrors the controller's
## restart contract: teardown (free_render) before the next init_render.
func _reseed(demo: Node, sand: PackedFloat32Array, water: PackedFloat32Array,
		snow: PackedFloat32Array) -> void:
	demo.solver.brush.clear()
	demo.solver.contact_brush.clear()
	demo.solver.set_seed_channels(sand, water, snow)
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
	var sums := Vector4()
	for i in field.size() / 4:
		sums += Vector4(field[i * 4], field[i * 4 + 1], field[i * 4 + 2], field[i * 4 + 3])
	return sums


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


## The wet-threshold formula, end to end: alternate water and pour stamps on
## the cone top so material is added while the summit sits at full saturation
## (5 cm of standing water ≥ the 4 cm saturation point). The steepened top can
## only be held by the wet cohesion term tan(33°)·(1+0.6); measure right after
## the last pour, before drainage dries the flank back to the dry angle.
func _check_wet_repose(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.0  # keep the soak
	demo.solver.wet_gain = 0.6
	demo.solver.water_sat_m = 0.04
	demo.solver.water_flow_rate = 0.05  # slow drainage to the minimum
	var sand := _flat(0.05)
	demo.solver.set_seed_channels(sand, _flat(0.0), _flat(0.0))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	demo.solver.brush.pos_m = Vector2.ZERO
	demo.solver.brush.radius_m = 0.25
	demo.solver.brush.strength = 0.5
	for round_index in 5:
		demo.solver.brush.mode = TerrainBrush.WATER
		await _step(demo, 4)
		demo.solver.brush.mode = TerrainBrush.POUR
		await _step(demo, 12)
	demo.solver.brush.clear()
	# A short settle relaxes the last pour's transient pile while the summit
	# is still wet; drainage cannot dry the flank back in this window.
	await _step(demo, 20)
	var field := await _field(demo)
	var n := _n
	var cell := WORLD / float(n)
	var max_slope := 0.0
	for y in range(1, n - 1, 2):
		for x in range(1, n - 1, 2):
			var i := (y * n + x) * 4
			var slope: float = maxf(
				absf(field[(y * n + x + 1) * 4] - field[i]),
				absf(field[((y + 1) * n + x) * 4] - field[i])) / cell
			max_slope = maxf(max_slope, slope)
	var dry := tan(deg_to_rad(33.0))
	var wet_target := dry * (1.0 + 0.6)
	_check(max_slope > dry * 1.2,
		"soaked cone slope %.3f stayed at the dry repose %.3f (wet term inactive)"
			% [max_slope, dry])
	_check(max_slope < wet_target * 1.25 + 1e-3,
		"soaked cone slope %.3f exceeds the fully-wet repose %.3f" % [max_slope, wet_target])
	demo.solver.water_flow_rate = 0.55


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


## Same seed twice → bit-identical fields after the same step count: transfers
## are pure functions of both endpoint cells and the pair-hash is symmetric.
func _check_determinism(demo: Node) -> void:
	demo.apply_preset(1)
	demo.solver.melt_rate_m_s = 0.0
	demo.solver.evap_rate_m_s = 0.005
	demo.solver.stochasticity = 0.25
	var sand := _bump(0.3, 0.2, 40.0)
	var water := _flat(0.006)
	demo.solver.set_seed_channels(sand, water, _flat(0.02))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	await _step(demo, 90)
	var run_a := await _field(demo)
	demo.solver.set_seed_channels(sand, water, _flat(0.02))
	RenderingServer.call_on_render_thread(demo.solver.free_render)
	RenderingServer.call_on_render_thread(demo.solver.init_render)
	await _frames(2)
	await _step(demo, 90)
	var run_b := await _field(demo)
	_check(run_a == run_b, "reseeded run diverged bit-for-bit (stochastic flux not deterministic)")


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
	demo.quality.set_tier(SimQualityProfile.Tier.MEDIUM)
	await _wait_init(demo)
	_check(demo.solver.grid_n == TerrainQualityProfile.GRID_SIZES[SimQualityProfile.Tier.MEDIUM],
		"Medium tier did not restore the solver grid (%d)" % demo.solver.grid_n)
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
