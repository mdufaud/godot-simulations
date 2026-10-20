extends "res://tests/test_case.gd"
## CPU checks of the wood bed's mass/energy contract: the last-step stock clamp,
## the discrete-kernel normalization of the injection rate (resolution
## independence), and the no-pilot-from-ash rule.

const WoodPyrolysis = preload("res://scripts/fire/wood_pyrolysis.gd")
const WoodPileScript = preload("res://scripts/fire/wood_pile.gd")


func _make_entry() -> Dictionary:
	return {"t_solid": 700.0, "area": 0.5, "m_volatile": 1.0, "m_char": 0.25,
		"m_ash": 0.0, "t_char": 1100.0, "rate": 0.0, "pilot": 0.0}


func _initialize() -> void:
	var pyro = WoodPyrolysis.new()

	# Last step: the flux asks for far more than the log holds (raw flow is
	# ~2.4e-3 kg/s at this area and gas temperature), so the released flow is
	# exactly the stock over the step and the emission follows it.
	var entry := _make_entry()
	entry["m_volatile"] = 1e-5
	var dt := 1.0 / 30.0
	pyro.step(entry, dt, 1200.0, 300.0, 40.0, 0.008)
	_check(absf(float(entry["m_volatile"])) < 1e-12,
		"last step left volatile mass behind: %s" % str(entry["m_volatile"]))
	var stock_mdot := 1e-5 / dt
	var expected_rate: float = pyro.mass_flow_to_fraction(stock_mdot, 40.0, 0.008)
	_check(absf(float(entry["rate"]) - expected_rate) <= 1e-6 * expected_rate,
		"last-step emission not derived from the released stock")

	# Normalization: the fraction the conversion returns, multiplied back by the
	# reference density, cell volume and discrete kernel weight the shader
	# applies, must reproduce the boosted volatile-equivalent mass flow.
	var weight := 287.0
	var h := 0.2
	var cell_volume := h * h * h
	var mdot := 2.5e-4
	var rate: float = pyro.mass_flow_to_fraction(mdot, weight, cell_volume)
	var hc_methane := 0.834e6 / 0.01604
	var expected_equiv: float = pyro.flame_boost * mdot * 16.0e6 / hc_methane
	var injected_equiv: float = rate * pyro.RHO_EMIT * cell_volume * weight
	_check(absf(injected_equiv - expected_equiv) <= 1e-9 * expected_equiv,
		"kernel normalization lost the prescribed flow: %s vs %s" % [
			str(injected_equiv), str(expected_equiv)])

	# Resolution independence: rate * cell_volume * kernel_weight is invariant
	# across cell sizes because kernel_weight grows as h^-3. The kernel weight
	# itself must track the continuous integral of the linear falloff,
	# pi.R^3/3, at both resolutions.
	var pile = WoodPileScript.new()
	pile.emit_radius = 1.3
	var continuous := PI * pow(1.3, 3.0) / 3.0
	var proxies: Array = []
	for cell in [0.2, 0.1]:
		pile.cell_size = cell
		var w: float = pile.kernel_weight()
		_check(absf(w - continuous / (cell * cell * cell)) <= 0.15 * continuous
			/ (cell * cell * cell),
			"kernel weight at h=%s off the continuous falloff integral: %s" % [
				str(cell), str(w)])
		proxies.append(pyro.mass_flow_to_fraction(mdot, w, cell * cell * cell)
			* w * cell * cell * cell)
	_check(absf(proxies[0] - proxies[1]) <= 1e-6 * proxies[0],
		"prescribed flow changed with resolution: %s vs %s" % [
			str(proxies[0]), str(proxies[1])])

	# Ash never pilots: a burnt-out log keeps a hot char temperature only as a
	# ghost of the neighbouring flame, and must not hold the bed lit.
	var ash := _make_entry()
	ash["m_volatile"] = 0.0
	ash["m_char"] = 0.0
	ash["m_ash"] = 1.0
	ash["t_char"] = 1200.0
	pyro.step(ash, dt, 1400.0, 300.0, 40.0, 0.008)
	_check(float(ash["pilot"]) == 0.0,
		"ash log still pilots at char temperature %s" % str(ash["t_char"]))

	# A live log still pilots from its glowing char.
	var live := _make_entry()
	live["t_char"] = 1100.0
	pyro.step(live, dt, 310.0, 300.0, 40.0, 0.008)
	_check(float(live["pilot"]) > WoodPyrolysis.T_CHAR_OUT,
		"glowing char lost its pilot")

	_finish("wood_pyrolysis")
