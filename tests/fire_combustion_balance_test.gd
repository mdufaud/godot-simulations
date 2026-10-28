extends "res://tests/test_case.gd"
## Live-path combustion ledger check: with the diagnostic counters on, the
## chemical heat the combustion stage books must equal phi * |dcH|/M_f times the
## fuel mass it consumed, sampled over a burning gas flame on the real pipeline
## (fixed dt, one substep per frame so each readback is exactly one substep).
## Also publishes the protection activation counts the audit asked for.

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

const SAMPLES := 60


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var demo = load("res://scenes/fire_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.set_frozen(true)
	demo.apply_preset(4) # Performance: fastest substep, full chemistry untouched
	for frame in 360:
		await process_frame
		if demo.capture_ready():
			break
	_check(demo.capture_ready(), "fire demo did not initialize")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("fire_combustion_balance")
		return

	var solver = demo.solver
	# The demo boots in wood mode by design (set_fuel_mode(false) in _ready);
	# the ledger then measures the methane-surrogate bed, pilot included.
	solver.diagnostic_counters = true
	solver.max_catchup_steps = 1
	demo.set_capture_fixed_delta(1.0 / 30.0)
	demo.set_frozen(false)

	# Burn-in past the ignition transient, then sample.
	for frame in 90:
		await process_frame
	var ratios: Array = []
	var clamps: Array = []
	var t_clamps: Array = []
	var renorms: Array = []
	var pilot_heat := 0.0
	var cap_clipped := 0.0
	var mass_fraction_max := 0.0
	var heat_total := 0.0
	var fuel_total := 0.0
	for frame in SAMPLES:
		await process_frame
		var stats: Dictionary = solver.get_stats()
		var heat: float = stats["diag_chemical_heat_j"]
		var mass: float = stats["diag_fuel_burned_kg"]
		heat_total += heat
		fuel_total += mass
		mass_fraction_max = maxf(mass_fraction_max, stats["mass_fraction_sum"])
		clamps.append(stats["diag_reactant_clamps"])
		t_clamps.append(stats["diag_temperature_clamps"])
		renorms.append(stats["diag_renormalisations"])
		pilot_heat += stats["diag_pilot_heat_j"]
		cap_clipped += stats["diag_wood_cap_clipped"]
		# The identity is phi * heat = |dcH| * (mass / M_f); per-frame values are
		# only meaningful where the flame actually burned this substep.
		if mass > 1e-9:
			var expected: float = absf(solver.current_fuel()["dch"]) \
				* (mass / solver.current_fuel()["m_f"])
			ratios.append(heat / (solver.heat_efficiency * expected))

	_check(ratios.size() >= SAMPLES / 4,
		"flame burned in only %d of %d sampled substeps" % [ratios.size(), SAMPLES])
	var median_ratio := _median(ratios)
	_check(absf(median_ratio - 1.0) <= 0.015,
		"heat ledger off the fuel ledger: median ratio %s over %d burning substeps" % [
			str(median_ratio), ratios.size()])
	_check(mass_fraction_max <= 1.001,
		"mass-fraction closure reached %s (renormalisation should hold the simplex)"
			% str(mass_fraction_max))

	# Same identity on a q_f = -2 fuel, where each reaction burns two moles of butane.
	# The ledger books the species update's |q_f| moles, so this pins the heat to
	# the fuel actually consumed. It cannot catch a factor missing from both sides:
	# heat and ledger used to count one mole per reaction and still balanced.
	var butane := -1
	for index in FireSolver.FUELS.size():
		if str(FireSolver.FUELS[index]["name"]).begins_with("Butane"):
			butane = index
	_check(butane >= 0 and absf(FireSolver.FUELS[butane]["q"][0]) == 2.0,
		"fuel table has no q_f = -2 butane row")
	demo.set_gas_fuel(butane)
	demo.set_fuel_mode(true)
	for frame in 90:
		await process_frame
	var gas_ratios: Array = []
	for frame in SAMPLES:
		await process_frame
		var stats: Dictionary = solver.get_stats()
		var mass: float = stats["diag_fuel_burned_kg"]
		if mass > 1e-9:
			var expected: float = absf(solver.current_fuel()["dch"]) \
				* (mass / solver.current_fuel()["m_f"])
			gas_ratios.append(stats["diag_chemical_heat_j"] / (solver.heat_efficiency * expected))
	_check(gas_ratios.size() >= SAMPLES / 4,
		"butane flame burned in only %d of %d sampled substeps" % [gas_ratios.size(), SAMPLES])
	var gas_ratio := _median(gas_ratios) if not gas_ratios.is_empty() else 0.0
	_check(absf(gas_ratio - 1.0) <= 0.015,
		"butane heat ledger off the fuel ledger: median ratio %s over %d burning substeps" % [
			str(gas_ratio), gas_ratios.size()])

	demo.queue_free()
	await process_frame
	print("BALANCE butane ratio=%s over %d substeps" % [str(gas_ratio), gas_ratios.size()])
	print(("BALANCE heat=%s J fuel=%s kg ratio=%s | activations/substep:"
		+ " reactant_clamp med=%s temp_clamp med=%s renorm med=%s"
		+ " | wood: pilot_heat=%s J cap_clipped=%s kg") % [
		str(heat_total), str(fuel_total), str(median_ratio),
		str(_median(clamps)), str(_median(t_clamps)), str(_median(renorms)),
		str(pilot_heat), str(cap_clipped)])
	_finish("fire_combustion_balance")
