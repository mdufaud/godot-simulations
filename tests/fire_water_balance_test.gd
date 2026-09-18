extends "res://tests/test_case.gd"
## Water-phase balances on the live pipeline: droplet round-trip conservation
## (evaporation and drain off), the evaporation mass ledger (boiled-off vs H2O
## gained, equal by Eq. 31), the h-convection and Eq. 27 Cp sensitivity table,
## the wet-suppression ablation, and the sim-clock vs wall-clock separation.

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")
const DROPLET_MASS := 0.025 ## FireWater.DROPLET_MASS

var _demo = null


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _frames(n: int) -> void:
	for frame in n:
		await process_frame


func _reset_water() -> void:
	_demo.water.reset_droplets()
	RenderingServer.call_on_render_thread(_demo.water.clear_droplets)
	await _frames(2)


func _sum_stat(key: String, frames: int) -> float:
	var total := 0.0
	for frame in frames:
		await process_frame
		total += _demo.solver.get_stats()[key]
	return total


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_demo = load("res://scenes/fire_demo.tscn").instantiate()
	root.add_child(_demo)
	await process_frame
	_demo.set_frozen(true)
	_demo.apply_preset(4)
	for frame in 360:
		await process_frame
		if _demo.capture_ready():
			break
	_check(_demo.capture_ready(), "fire demo did not initialize")
	if not _demo.capture_ready():
		_demo.queue_free()
		_finish("fire_water_balance")
		return

	var solver = _demo.solver
	var water = _demo.water
	_demo.set_frozen(false)
	solver.diagnostic_counters = true
	solver.max_catchup_steps = 1
	_demo.set_capture_fixed_delta(1.0 / 30.0)

	# --- Phase 1: round-trip mass, evaporation and drain off ------------------
	solver.evaporation_enabled = false
	water.evaporation_active = false
	water.drain_rate = 0.0
	await _reset_water()
	_demo.interaction.jet_enabled = true
	await _frames(120)
	_demo.interaction.jet_enabled = false
	await _frames(30)
	var counts: Array = []
	for frame in 40:
		await process_frame
		counts.append(float(water.particles_active))
	_check(counts.size() > 0 and counts.max() > 0.0, "no droplets in flight")
	var median_count := _median(counts)
	var drift: float = (counts.max() - counts.min()) / maxf(median_count, 1.0)
	_check(drift <= 0.01,
		"round-trip droplet count drift %.3f%% over 40 frames (evap/drain off)"
			% [drift * 100.0])
	var round_trip_mass: float = median_count * DROPLET_MASS
	await _reset_water()

	# --- Phase 2: evaporation mass ledger -------------------------------------
	solver.evaporation_enabled = true
	water.evaporation_active = true
	_demo.interaction.jet_enabled = true
	await _frames(90)
	var evaporated := 0.0
	var gained := 0.0
	var residuals: Array = []
	for frame in 60:
		await process_frame
		var stats: Dictionary = solver.get_stats()
		evaporated += stats["diag_evaporated_kg"]
		gained += stats["diag_h2o_gained_kg"]
		residuals.append(stats["energy_residual"])
	_demo.interaction.jet_enabled = false
	var evap_ratio := evaporated / maxf(gained, 1e-12)
	_check(absf(evap_ratio - 1.0) <= 0.02,
		"evaporation ledger: boiled-off %s kg vs H2O gained %s kg (ratio %s)" % [
			str(evaporated), str(gained), str(evap_ratio)])
	var median_residual := _median(residuals)
	_check(median_residual <= 0.05, "evaporation energy residual median %s" % str(median_residual))
	await _reset_water()

	# --- Phase 3: h-convection sensitivity ------------------------------------
	var evap_rates: Dictionary = {}
	for h_conv in [25.0, 50.0, 100.0]:
		solver.droplet_heat_transfer = h_conv
		await _reset_water()
		_demo.interaction.jet_enabled = true
		var total := 0.0
		for frame in 120:
			await process_frame
			total += solver.get_stats()["diag_evaporated_kg"]
		_demo.interaction.jet_enabled = false
		evap_rates[h_conv] = total
	_check(evap_rates[100.0] > evap_rates[25.0],
		"evaporation not increasing with h_conv: %s vs %s" % [
			str(evap_rates[100.0]), str(evap_rates[25.0])])
	await _reset_water()

	# --- Phase 4: Eq. 27 Cp A/B (gas Cp shipped vs liquid Cp) ------------------
	solver.droplet_heat_transfer = 50.0
	solver.diagnostic_evap_liquid_cp = true
	_demo.interaction.jet_enabled = true
	var liquid_cp_total := 0.0
	for frame in 120:
		await process_frame
		liquid_cp_total += solver.get_stats()["diag_evaporated_kg"]
	_demo.interaction.jet_enabled = false
	solver.diagnostic_evap_liquid_cp = false
	var cp_percent := 100.0 * (1.0 - liquid_cp_total / maxf(evap_rates[50.0], 1e-12))
	_check(liquid_cp_total < evap_rates[50.0],
		"liquid-Cp convention did not evaporate less than gas-Cp: %s vs %s" % [
			str(liquid_cp_total), str(evap_rates[50.0])])
	await _reset_water()

	# --- Phase 5: wet-suppression ablation on the gas burner -------------------
	_demo.set_fuel_mode(true)
	await _frames(30)
	var reaction_by_supp: Dictionary = {}
	for suppression in [0.0, 20.0, 40.0]:
		solver.water_suppression = suppression
		await _reset_water()
		_demo.interaction.jet_enabled = true
		await _frames(180)
		var reactions: Array = []
		for frame in 60:
			await process_frame
			reactions.append(solver.get_stats()["total_reaction"])
		_demo.interaction.jet_enabled = false
		reaction_by_supp[suppression] = _median(reactions)
	# No direction asserted on purpose: the 2026-09 ablation measured total
	# reaction INCREASING with the suppression term on the gas burner (0 -> 2.6,
	# 40 -> 17.5), i.e. the manual term cancels part of what cooling and steam
	# already do. That is a default-policy decision, not something a single
	# scenario should flip; the medians are published every run instead.
	solver.water_suppression = 40.0

	# --- Phase 6: the drain curve (NON-PAPER cleanup, published) ---------------
	solver.evaporation_enabled = false
	water.evaporation_active = false
	water.drain_rate = 0.2
	await _reset_water()
	_demo.interaction.jet_enabled = true
	await _frames(90)
	_demo.interaction.jet_enabled = false
	var drain_curve: Array = [water.particles_active]
	for sample in 3:
		await _frames(60)
		drain_curve.append(water.particles_active)
	water.drain_rate = 0.0
	solver.evaporation_enabled = true
	water.evaporation_active = true
	await _reset_water()

	# --- Phase 7: sim clock vs wall clock --------------------------------------
	_demo.interaction.jet_enabled = true
	var base_rate := 0.0
	for frame in 120:
		await process_frame
		base_rate += solver.get_stats()["diag_evaporated_kg"]
	_demo.interaction.jet_enabled = false
	# At fixed dt 1/60 the SPH steps every frame while the 30 Hz grid steps every
	# other; the ledger is per substep, so the summed rate should land near half
	# the dt=1/30 run for the same wall time.
	_demo.set_capture_fixed_delta(1.0 / 60.0)
	await _reset_water()
	_demo.interaction.jet_enabled = true
	var slow_rate := 0.0
	for frame in 240:
		await process_frame
		slow_rate += solver.get_stats()["diag_evaporated_kg"]
	_demo.interaction.jet_enabled = false
	_demo.set_capture_fixed_delta(1.0 / 30.0)

	_demo.queue_free()
	await process_frame
	print("WATER round_trip_mass=%s kg | evap=%s h2o=%s kg"
		% [str(round_trip_mass), str(evaporated), str(gained)])
	print("WATER h_sweep 25=%s 50=%s 100=%s kg | liquid_cp=%s kg (%.1f%% less)"
		% [str(evap_rates[25.0]), str(evap_rates[50.0]), str(evap_rates[100.0]),
		str(liquid_cp_total), cp_percent])
	print("WATER suppression medians 0=%s 20=%s 40=%s" % [
		str(reaction_by_supp[0.0]), str(reaction_by_supp[20.0]),
		str(reaction_by_supp[40.0])])
	print("WATER drain_curve active=%s" % str(drain_curve))
	print("WATER clock evap dt30=%s dt60=%s (expect ~2x)" % [str(base_rate), str(slow_rate)])
	_finish("fire_water_balance")
