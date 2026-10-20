extends "res://tests/test_case.gd"
## Westbrook & Dryer / Fire-X fuel-table checks, no GPU: the CGS->SI conversion
## the solver applies to the published pre-exponential factors, the rate
## equivalence of both readings, the stoichiometric mass balance of every row,
## and the Eq. 4 heat of combustion.

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

## (c, h, o) atom counts per FUELS row, for the Eq. 4 identity.
const FORMULAS := [[3, 8, 0], [1, 4, 0], [2, 2, 0], [4, 10, 0], [3, 6, 0], [2, 4, 0]]

const EA_KCAL := 30.0
const R_CAL := 1.987 ## cal/(mol.K), Westbrook & Dryer's unit convention


func _near(actual: float, expected: float, rel: float) -> bool:
	return absf(actual - expected) <= rel * maxf(absf(expected), 1e-30)


func _initialize() -> void:
	var solver = FireSolver.new()

	_check(_near(FireSolver.ACTIVATION_ENERGY, EA_KCAL * 4184.0, 1e-12),
		"ACTIVATION_ENERGY is not 30 kcal/mol in joules")
	_check(_near(FireSolver.ACTIVATION_ENERGY / FireSolver.R_GAS,
		EA_KCAL * 4184.0 / 8.314, 1e-12),
		"Ea/R does not match Ea = 30 kcal/mol over R = 8.314")

	for index in FireSolver.FUELS.size():
		var fuel: Dictionary = FireSolver.FUELS[index]
		var name: String = fuel["name"]
		var a: float = fuel["a"]
		var b: float = fuel["b"]

		# Westbrook & Dryer, right after their Tab. I: "the often-employed choice
		# of simultaneous first order fuel and oxidizer dependence ... should not
		# be used".
		_check(not (is_equal_approx(a, 1.0) and is_equal_approx(b, 1.0)),
			"%s: a = b = 1 is the forbidden simultaneous-first-order choice" % name)

		# The solver's conversion of the published CGS A into SI:
		# mol^(1-a-b).m^(3(a+b-1)).s^-1 = cm units scaled by 10^(6(1-a-b)).
		solver.fuel_index = index
		var expected_si: float = float(fuel["a_factor"]) \
			* pow(10.0, 6.0 * (1.0 - a - b))
		_check(_near(solver.effective_pre_exponential(), expected_si, 1e-9),
			"%s: effective_pre_exponential does not match the 10^(6(1-a-b)) scaling" % name)

		# Both readings of the rate must agree: evaluate Eq. 5 natively in CGS
		# (mol/cm^3, kcal, cal) and in SI (mol/m^3, J), the CGS result scaled by
		# 1e6 (cm^3 -> m^3). The residual difference is the cal/J rounding of R.
		var t := 1500.0
		var c_f_si := 0.5
		var c_o_si := 2.0
		var rate_cgs_m3: float = float(fuel["a_factor"]) \
			* exp(-EA_KCAL * 1000.0 / (R_CAL * t)) \
			* pow(c_f_si * 1e-6, a) * pow(c_o_si * 1e-6, b) * 1e6
		var rate_si: float = expected_si \
			* exp(-FireSolver.ACTIVATION_ENERGY / (FireSolver.R_GAS * t)) \
			* pow(c_f_si, a) * pow(c_o_si, b)
		_check(_near(rate_si, rate_cgs_m3, 0.01),
			"%s: SI and CGS rate readings disagree beyond the R rounding" % name)

		# Stoichiometric mass balance: sum of q_i.M_i over the four tracked
		# species must vanish (fuel + O2 on one side, CO2 + H2O on the other).
		var q: Array = fuel["q"]
		var m_f: float = fuel["m_f"]
		var imbalance: float = q[0] * m_f + q[1] * FireSolver.M_O2 \
			+ q[2] * FireSolver.M_CO2 + q[3] * FireSolver.M_H2O
		_check(absf(imbalance) <= 0.03 * absf(q[0] * m_f),
			"%s: stoichiometric mass balance off by %s kg/mol" % [name, str(imbalance)])

		# Fire-X Eq. 4: dcH = -417.(c + 0.25h - 0.5o) kJ/mol.
		var formula: Array = FORMULAS[index]
		var expected_dch := -417000.0 * (float(formula[0]) + 0.25 * float(formula[1])
			- 0.5 * float(formula[2]))
		_check(_near(fuel["dch"], expected_dch, 0.01),
			"%s: dcH %s does not match Eq. 4's %s" % [name, str(fuel["dch"]), str(expected_dch)])

	_finish("fire_fuels")
