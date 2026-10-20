class_name WoodPyrolysis extends RefCounted

const FIRE_GPU_SOLVER := preload("res://scripts/fire/fire_gpu_solver.gd")
const FUEL_INDEX_METHANE := 1
const RHO_WOOD := 500.0
const C_WOOD := 1600.0
const THERMAL_DEPTH := 0.006
const VIEW_FACTOR := 0.15
const EMISSIVITY := 0.9
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

## Look multiplier on the energy the bed hands to the gas. 1.0 pays the flame
## strictly from the volatiles the solid has gasified — measured, that never
## reaches stoichiometric fuel at 0.2 m cells and the bed smolders without a
## flame. 8 barely holds; the default 16 reproduces the pre-fix flame (the old
## hard-coded 80 rode an unnormalized kernel worth roughly 5x). Anything above
## the physical budget is a game-look choice; the menu slider mirrors it.
var flame_boost := 16.0


func step(entry: Dictionary, delta: float, t_gas: float, ambient: float,
		kernel_weight: float, cell_volume: float) -> void:
	var t_s: float = entry["t_solid"]
	var area: float = entry["area"]
	var q := VIEW_FACTOR * EMISSIVITY * FIRE_GPU_SOLVER.SIGMA_SB \
		* (pow(t_gas, 4.0) - pow(t_s, 4.0)) \
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
			# The final step of a log must never gasify more than it still
			# holds: the emission below is derived from what is actually
			# released, not from the uncapped flux.
			mdot = minf(mdot, entry["m_volatile"] / delta)
			if mdot > 0.0:
				entry["m_volatile"] = maxf(entry["m_volatile"] - mdot * delta, 0.0)
				entry["rate"] = mass_flow_to_fraction(mdot, kernel_weight, cell_volume)
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
	# Ash holds no pilot: with no volatiles and no char there is no reservoir to
	# glow, so a burnt-out log cannot re-light its surroundings even while the
	# neighbouring flame keeps its ghost of a char temperature up.
	if entry["m_volatile"] <= 0.0 and entry["m_char"] <= 0.0:
		entry["pilot"] = 0.0
	else:
		entry["pilot"] = t_char if t_char > T_CHAR_OUT else 0.0
	entry["t_solid"] = clampf(t_s, ambient, 2000.0)


## Converts a gasified volatile mass flow into the per-cell fuel-fraction rate
## fire_inject mode 5 applies (rate * dt * falloff per cell). Normalized on the
## DISCRETE sum of falloff weights the shader evaluates across the sphere, so
## the injected total tracks the prescribed flow at any cell size — the old
## sphere-volume formula ignored the kernel's shape, whose continuous mean is
## only 1/4 of the peak the denominator assumed.
func mass_flow_to_fraction(mdot: float, kernel_weight: float,
		cell_volume: float) -> float:
	var fuel: Dictionary = FIRE_GPU_SOLVER.FUELS[FUEL_INDEX_METHANE]
	var hc_methane: float = -float(fuel["dch"]) / float(fuel["m_f"])
	var mdot_equiv := flame_boost * mdot * HC_VOLATILES / hc_methane
	return mdot_equiv / maxf(RHO_EMIT * cell_volume * kernel_weight, 1e-9)
