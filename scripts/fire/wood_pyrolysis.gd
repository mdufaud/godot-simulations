class_name WoodPyrolysis extends RefCounted

const FIRE_GPU_SOLVER := preload("res://scripts/fire/fire_gpu_solver.gd")
const FUEL_INDEX_METHANE := 1
const RHO_WOOD := 500.0
const C_WOOD := 1600.0
const THERMAL_DEPTH := 0.006
const VIEW_FACTOR := 0.15
const EMISSIVITY := 0.9
const SIGMA_SB := 5.67e-8
const H_CONV := 15.0
const MAX_FLUX := 4.0e4
const DH_GAS := 4.5e6
const HC_VOLATILES := 16.0e6
const T_PYROLYSIS := 600.0
const CHAR_FLUX := 0.004
const T_GLOW := 1150.0
const TAU_CHAR_HEAT := 5.0
const TAU_CHAR_COOL := 15.0
const T_CHAR_OUT := 700.0
const RHO_EMIT := 0.6
const FLAME_BOOST := 80.0


func step(entry: Dictionary, delta: float, t_gas: float, ambient: float,
		emit_radius: float) -> void:
	var t_s: float = entry["t_solid"]
	var area: float = entry["area"]
	var q := VIEW_FACTOR * EMISSIVITY * SIGMA_SB * (pow(t_gas, 4.0) - pow(t_s, 4.0)) \
		+ H_CONV * (t_gas - t_s)
	q = minf(q, MAX_FLUX)
	var capacity := RHO_WOOD * area * THERMAL_DEPTH * C_WOOD
	entry["rate"] = 0.0
	var alight := false
	if entry["m_volatile"] > 0.0:
		if t_s < T_PYROLYSIS:
			t_s = minf(t_s + q * area / capacity * delta, T_PYROLYSIS)
		else:
			t_s = T_PYROLYSIS
			var mdot := area * maxf(q, 0.0) / DH_GAS
			if mdot > 0.0:
				entry["m_volatile"] = maxf(entry["m_volatile"] - mdot * delta, 0.0)
				entry["rate"] = mass_flow_to_fraction(mdot, emit_radius)
				alight = true
			else:
				t_s += q * area / capacity * delta
	elif entry["m_char"] > 0.0:
		if float(entry["t_char"]) > T_CHAR_OUT:
			entry["m_char"] = maxf(entry["m_char"] - area * CHAR_FLUX * delta, 0.0)
			alight = true
		t_s += q * area / capacity * delta
	else:
		entry["m_ash"] = 1.0
		t_s += q * area / capacity * delta

	var t_char: float = entry["t_char"]
	if alight:
		t_char = lerpf(t_char, T_GLOW, 1.0 - exp(-delta / TAU_CHAR_HEAT))
	else:
		t_char = lerpf(t_char, minf(t_gas, T_GLOW), 1.0 - exp(-delta / TAU_CHAR_COOL))
	entry["t_char"] = t_char
	entry["pilot"] = t_char if t_char > T_CHAR_OUT else 0.0
	entry["t_solid"] = clampf(t_s, ambient, 2000.0)


func mass_flow_to_fraction(mdot: float, emit_radius: float) -> float:
	var fuel: Dictionary = FIRE_GPU_SOLVER.FUELS[FUEL_INDEX_METHANE]
	var hc_methane: float = -float(fuel["dch"]) / float(fuel["m_f"])
	var volume := 4.0 / 3.0 * PI * pow(emit_radius, 3.0)
	return FLAME_BOOST * mdot * HC_VOLATILES / hc_methane \
		/ maxf(RHO_EMIT * volume, 1e-4)
