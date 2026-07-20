class_name FireGpuSolver
extends RefCounted
## GPU combustion solver implementing Fire-X (Wrede et al., SIGGRAPH Asia 2025,
## ACM TOG 44(6) art. 268), DOI 10.1145/3763338.
##
## Global one-step stoichiometric combustion in real units: mass fractions and
## molar concentrations, Arrhenius kinetics from the paper's Table 1, Boussinesq
## buoyancy, vorticity confinement, MacCormack advection and a Jacobi pressure
## projection. Every physical constant below is traceable to the paper or to the
## reference it cites; anything that is not is marked NON-PAPER.
##
## All methods except [method push_event] and [method get_stats] must run on the
## rendering thread (RenderingDevice is not thread safe).

const SHADER_DIR := "res://shaders/fire/"
const STAGES: Array[String] = [
	"inject", "advect", "maccormack", "forces", "curl", "vorticity",
	"combustion", "diffusion", "divergence", "pressure", "project", "display",
]
## Workgroup is 8x8x4; grid dimensions must stay multiples of these.
const WG := Vector3i(8, 8, 4)
const STATS_WORDS := 8
const CONFIG_VEC4S := 10

enum { EVENT_FUEL = 1, EVENT_IGNITE = 2, EVENT_WATER = 3, EVENT_SMOTHER = 4 }

## Concentration units the Arrhenius pre-exponential factor is expressed in.
## Westbrook & Dryer Tab. I states "Units are cm-sec-mole-kcal-Kelvins", so the
## published A values are CGS. Fire-X reproduces those numbers verbatim while
## its nomenclature gives concentrations in mol/m^3 without mentioning a
## conversion, so both readings are offered and compared.
enum { UNITS_CGS = 0, UNITS_SI_AS_PRINTED = 1 }

# =========================================================================
#  FUEL TABLE — Fire-X Tab. 1, activation energy from Westbrook & Dryer Tab. I
# =========================================================================
# Columns: D_f [m^2/s], A (as printed, CGS), a, b, dcH [J/mol],
#          q_f, q_o, q_CO2, q_H2O, M_f [kg/mol], Cp [J/(kg.K)], k [W/(m.K)]
#
# Every dcH equals -417 kJ/mol x (moles of O2), i.e. Fire-X Eq. 4
# dcH = -417(c + 0.25h - 0.5o), verified against all six rows.
#
# Ea = 30.0 kcal/mol for all six: Westbrook & Dryer Tab. I, corroborated in
# their text ("All of the previous calculations were carried out with
# Ea = 30 kcal/mole"). Their (A, a, b) rows match Fire-X Tab. 1 exactly, so the
# provenance of the Fire-X values is certain.
#
# Cp for acetylene (63) and cyclopropane (114) are printed as such in Fire-X
# Tab. 1 but match neither the mass-specific nor the molar value for those gases
# (the other four rows are correct mass-specific figures). Reproduced verbatim;
# they are only weighted by the fuel mass fraction in the mixture average.
const FUELS: Array[Dictionary] = [
	{"name": "Propane (C3H8)", "d_f": 1.14e-5, "a_factor": 8.60e11, "a": 0.10, "b": 1.65,
		"dch": -2.0850e6, "q": [-1.0, -5.0, 3.0, 4.0], "m_f": 4.410e-2, "cp": 1670.0, "k": 0.016},
	{"name": "Methane (CH4)", "d_f": 2.10e-5, "a_factor": 8.30e5, "a": -0.30, "b": 1.30,
		"dch": -0.8340e6, "q": [-1.0, -2.0, 1.0, 2.0], "m_f": 1.604e-2, "cp": 2230.0, "k": 0.034},
	{"name": "Acetylene (C2H2)", "d_f": 1.46e-5, "a_factor": 6.50e12, "a": 0.50, "b": 1.25,
		"dch": -1.0425e6, "q": [-2.0, -5.0, 4.0, 2.0], "m_f": 2.600e-2, "cp": 63.0, "k": 0.024},
	{"name": "Butane (C4H10)", "d_f": 1.00e-5, "a_factor": 7.40e11, "a": 0.15, "b": 1.60,
		"dch": -2.7105e6, "q": [-2.0, -13.0, 8.0, 10.0], "m_f": 5.812e-2, "cp": 1720.0, "k": 0.015},
	{"name": "Cyclopropane (C3H6)", "d_f": 1.14e-5, "a_factor": 4.20e11, "a": -0.10, "b": 1.85,
		"dch": -1.8765e6, "q": [-2.0, -9.0, 6.0, 6.0], "m_f": 4.200e-2, "cp": 114.0, "k": 0.015},
	{"name": "Ethylene (C2H4)", "d_f": 1.63e-5, "a_factor": 2.00e12, "a": 0.10, "b": 1.65,
		"dch": -1.2510e6, "q": [-1.0, -3.0, 2.0, 2.0], "m_f": 2.805e-2, "cp": 1550.0, "k": 0.019},
]

## Activation energy, Westbrook & Dryer Tab. I (kcal/mol -> J/mol).
const ACTIVATION_ENERGY := 30.0 * 4184.0
const R_GAS := 8.314 ## Fire-X nomenclature
const P_AMBIENT := 101325.0 ## Standard atmosphere

# Molar masses [kg/mol] of the non-fuel species. Their specific heats are
# temperature dependent and live in the shader as NIST-JANAF Shomate fits
# (see fire_common.comp), matching Fire-X Tab. 4's "mixture temperature
# averaged" specification.
const M_O2 := 0.032
const M_CO2 := 0.044
const M_H2O := 0.018
const M_N2 := 0.028

## Air composition by mass, from Fire-X Tab. 4 (21 % O2 / 79 % N2 by volume).
const Y_O2_AIR := 0.233

# =========================================================================
#  CONFIGURABLE PARAMETERS — ranges from Fire-X Tab. 3
# =========================================================================

## 64x96x64. Fire-X Tab. 3 runs 64^3 up to 200x300x400.
var grid_dims := Vector3i(64, 96, 64)
var cell_size := 0.1 ## Grid length 6.4 x 9.6 x 6.4 m; Tab. 3 allows 0.1-10.0 m

var fuel_index := 0
var units_convention := UNITS_CGS

var ambient_temperature := 300.0 ## Fire-X Tab. 3
var timestep := 1.0 / 120.0 ## Fire-X Tab. 3 "Delta Time"
var substeps := 1 ## Fire-X Tab. 3 "Update Multiplier", range 1-4
var pressure_iterations := 64 ## Fire-X Tab. 3, range 64-128

var radiation_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-6.0
var heat_efficiency := 1.0 ## phi in Eq. 6; Fire-X Tab. 3, range 0.0-1.0
var co2_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var h2o_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var residual_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var temperature_clamp := 3000.0 ## Tab. 3 "Density temperature coupling limit"
var emitter_temperature := 1500.0 ## Tab. 3 grid emitter, range 300-1500 K

var vorticity_strength := 8.0 ## Fire-X Tab. 3, range 0.0-50.0
var vorticity_velocity_lo := 0.0 ## Fire-X Tab. 3, range 0.0-0.1
var vorticity_velocity_hi := 5.0 ## Fire-X Tab. 3, range 0.0-5.0
var vorticity_temperature_lo := 301.0 ## Fire-X Tab. 3

var wind := Vector3.ZERO ## NON-PAPER: inflow boundary condition for the demo
var gravity := 9.81 ## Buoyancy magnitude in Eq. 1
var kinematic_viscosity := 1.5e-5 ## NON-PAPER: air at ambient, Eq. 1 nu
var drag := 0.0 ## NON-PAPER: stability aid, 0 = disabled
var oxygen_replenish := 6.0 ## NON-PAPER: open-boundary inflow rate [1/s]
var residual_dissipation := 0.03 ## NON-PAPER: soot settling in cold cells
var display_temperature := 2600.0 ## Renderer normalisation only
var reaction_reference := 50.0 ## Renderer normalisation only [mol/(m^3.s)]

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := {}
var _stats_buf := RID()
var _config_buf := RID()
var _parity := 0
var _groups := Vector3i.ZERO

var _events: Array[Dictionary] = []
var _events_mutex := Mutex.new()
var _stats := PackedInt64Array()
var _stats_mutex := Mutex.new()
var _stats_pending := false
var _timings := {}
var _timings_mutex := Mutex.new()


func _init() -> void:
	_stats.resize(STATS_WORDS)


func get_display_tex_rid() -> RID:
	return _tex.get("display", RID())


func current_fuel() -> Dictionary:
	return FUELS[clampi(fuel_index, 0, FUELS.size() - 1)]


## Arrhenius pre-exponential factor in the units the shader works in.
##
## Westbrook & Dryer publish A in CGS (mol/cm^3). Converting to SI with
## v_si = 1e6.v_cgs and c_cgs = 1e-6.c_si gives A_si = A_cgs.10^(6(1-a-b)).
## Methane has a+b = 1.0 exactly, so it is unaffected; the other five all have
## a+b = 1.75, a factor of 10^-4.5.
func effective_pre_exponential() -> float:
	var f := current_fuel()
	if units_convention == UNITS_SI_AS_PRINTED:
		return f["a_factor"]
	return f["a_factor"] * pow(10.0, 6.0 * (1.0 - f["a"] - f["b"]))


## Queue a grid interaction; consumed by the next [method step_render].
## Safe to call from the main thread.
func push_event(mode: int, position: Vector3, radius: float, amount: float) -> void:
	_events_mutex.lock()
	# Bounded: the caller queues one emitter event per frame, so an unconsumed
	# queue means the solver never came up and events would pile up forever.
	if _events.size() < 64:
		_events.append({"mode": mode, "pos": position, "radius": radius, "amount": amount})
	_events_mutex.unlock()


## Last reduced frame. Safe to call from the main thread.
func get_stats() -> Dictionary:
	_stats_mutex.lock()
	var s := _stats.duplicate()
	_stats_mutex.unlock()
	var region := maxf(float(s[5]), 1.0)
	var column := maxf(float(s[7]), 1.0)
	return {
		"max_temperature": float(s[0]),
		"total_reaction": float(s[1]) * 0.001,
		"max_reaction": float(s[2]) * 0.001,
		"avg_fuel": float(s[3]) * 0.001 / region,
		"avg_oxygen": float(s[4]) * 0.001 / region,
		"mass_fraction_sum": float(s[6]) * 0.001 / column,
	}


func get_timings() -> Dictionary:
	_timings_mutex.lock()
	var copy := _timings.duplicate()
	_timings_mutex.unlock()
	return copy


# =========================================================================
#  SETUP
# =========================================================================

func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Fire solver needs a RenderingDevice (Forward+ or Mobile renderer).")
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "fire_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "fire_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "fire_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Fire stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	_create_textures()

	var stats_bytes := PackedByteArray()
	stats_bytes.resize(STATS_WORDS * 4)
	_stats_buf = _rd.storage_buffer_create(stats_bytes.size(), stats_bytes)

	var config_bytes := PackedByteArray()
	config_bytes.resize(CONFIG_VEC4S * 16)
	_config_buf = _rd.storage_buffer_create(config_bytes.size(), config_bytes)

	_build_uniform_sets()

	_groups = Vector3i(
		ceili(float(grid_dims.x) / WG.x),
		ceili(float(grid_dims.y) / WG.y),
		ceili(float(grid_dims.z) / WG.z))
	_parity = 0
	initialized = true


func _create_textures() -> void:
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	var keys_rgba := ["vel_a", "vel_b", "scal_a", "scal_b", "scal2_a", "scal2_b",
		"vel_fwd", "scal_fwd", "scal2_fwd", "curl"]
	for key in keys_rgba:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, usage),
			RDTextureView.new(), [])

	for key in ["press_a", "press_b", "diverg"]:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage),
			RDTextureView.new(), [])

	_tex["display"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, usage),
		RDTextureView.new(), [])

	clear_fields()


func _make_format(format: int, usage: int) -> RDTextureFormat:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = grid_dims.x
	fmt.height = grid_dims.y
	fmt.depth = grid_dims.z
	fmt.format = format
	fmt.usage_bits = usage
	return fmt


## Reset every field to still ambient air. Rendering thread only.
func clear_fields() -> void:
	# texture_clear takes a Color, so a cell's four floats go straight in:
	# scal = (T, Y_fuel, Y_O2, Y_CO2). Nitrogen is implied by the remainder.
	var air := Color(ambient_temperature, 0.0, Y_O2_AIR, 0.0)
	for key in ["scal_a", "scal_b"]:
		_rd.texture_clear(_tex[key], air, 0, 1, 0, 1)
	for key in ["vel_a", "vel_b", "scal2_a", "scal2_b", "vel_fwd", "scal_fwd",
			"scal2_fwd", "curl", "press_a", "press_b", "diverg", "display"]:
		_rd.texture_clear(_tex[key], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_parity = 0


## Fill the domain with a premixed fuel/air charge at [param equivalence_ratio]
## (1.0 = stoichiometric), as in the mixture study of Fire-X Fig. 9.
## Rendering thread only.
func seed_premixed(equivalence_ratio: float, temperature: float) -> void:
	var f := current_fuel()
	# Mass of O2 required per unit mass of fuel, from the reaction coefficients.
	var o2_per_fuel: float = absf(f["q"][1]) * M_O2 / (absf(f["q"][0]) * f["m_f"])
	var air_per_fuel := o2_per_fuel / Y_O2_AIR / maxf(equivalence_ratio, 1e-3)
	var y_fuel := 1.0 / (1.0 + air_per_fuel)
	var y_o2 := y_fuel * air_per_fuel * Y_O2_AIR

	for key in ["scal_a", "scal_b"]:
		_rd.texture_clear(_tex[key], Color(temperature, y_fuel, y_o2, 0.0), 0, 1, 0, 1)
	for key in ["vel_a", "vel_b", "scal2_a", "scal2_b", "vel_fwd", "scal_fwd",
			"scal2_fwd", "curl", "press_a", "press_b", "diverg", "display"]:
		_rd.texture_clear(_tex[key], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_parity = 0


func _build_uniform_sets() -> void:
	# One binding layout for every stage (glslang keeps declared-but-unused
	# resources, so the shared header can declare them all). Variant 0/1 swaps
	# whichever pair the stage ping-pongs: the field textures for most stages,
	# the pressure pair for the Jacobi sweep.
	var fields := ["vel_a", "vel_b", "scal_a", "scal_b", "vel_fwd", "scal_fwd",
		"curl", "press_a", "press_b", "diverg", "display", "",
		"scal2_a", "scal2_b", "scal2_fwd"]
	var fields_flipped := fields.duplicate()
	fields_flipped[0] = "vel_b"
	fields_flipped[1] = "vel_a"
	fields_flipped[2] = "scal_b"
	fields_flipped[3] = "scal_a"
	fields_flipped[12] = "scal2_b"
	fields_flipped[13] = "scal2_a"

	var pressure_flipped := fields.duplicate()
	pressure_flipped[7] = "press_b"
	pressure_flipped[8] = "press_a"

	for stage in STAGES:
		var variants := [fields, pressure_flipped] if stage == "pressure" \
			else [fields, fields_flipped]
		var sets := []
		for variant in 2:
			var uniforms: Array[RDUniform] = []
			var order: Array = variants[variant]
			for bi in order.size():
				if bi == 11:
					continue # stats buffer, added below
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.binding = bi
				u.add_id(_tex[order[bi]])
				uniforms.append(u)
			for pair in [[11, _stats_buf], [15, _config_buf]]:
				var b := RDUniform.new()
				b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				b.binding = pair[0]
				b.add_id(pair[1])
				uniforms.append(b)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_sets[stage] = sets


# =========================================================================
#  STEP — Fire-X Algorithm 1, lines 16-22
# =========================================================================

func step_render(delta: float) -> void:
	if not initialized:
		return
	_read_timings()
	_fetch_stats()
	_upload_config()

	# The paper fixes dt at 1/120 s with an update multiplier of 1-4; run as
	# many whole steps as the frame covers rather than stretching dt, which
	# would change the physics with the frame rate.
	var count := clampi(int(delta / timestep), 1, substeps)

	_events_mutex.lock()
	var events := _events.duplicate()
	_events.clear()
	_events_mutex.unlock()

	if profiling:
		_rd.capture_timestamp("fire/start")
	var cl := _rd.compute_list_begin()

	for i in count:
		# Events are injected once, on the first substep of the frame.
		if i == 0:
			for e in events:
				_dispatch(cl, "inject", _parity,
					_push_constant(e["mode"], e["pos"], e["radius"], e["amount"]))
		_substep(cl)

	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("fire/end")


func _substep(cl: int) -> void:
	var pc := _push_constant(0, Vector3.ZERO, 1.0, 0.0)
	var p := _parity

	# 16. Advection (MacCormack): src -> dst, then the fields swap roles.
	_dispatch(cl, "advect", p, pc)
	_dispatch(cl, "maccormack", p, pc)
	p = 1 - p

	# 17. Buoyancy (+ vorticity confinement, Tab. 3).
	_dispatch(cl, "forces", p, pc)
	if vorticity_strength > 0.0:
		_dispatch(cl, "curl", p, pc)
		_dispatch(cl, "vorticity", p, pc)

	# 18. Combustion, in place.
	_dispatch(cl, "combustion", p, pc)

	# 19-20. Diffusion + thermal radiation: also a stencil, so it swaps again.
	_dispatch(cl, "diffusion", p, pc)
	p = 1 - p

	# 21 is evaporation (not implemented: needs the SPH liquid phase).
	# 22. Pressure projection.
	_dispatch(cl, "divergence", p, pc)
	var iters := pressure_iterations + (pressure_iterations & 1)
	for i in iters:
		_dispatch(cl, "pressure", i & 1, pc)
	_dispatch(cl, "project", p, pc)
	_dispatch(cl, "display", p, pc)

	_parity = p


func _dispatch(cl: int, stage: String, variant: int, pc: PackedByteArray) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage][variant], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, _groups.x, _groups.y, _groups.z)
	_rd.compute_list_add_barrier(cl)


func _push_constant(mode: int, pos: Vector3, radius: float, amount: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(64)
	pc.encode_s32(0, grid_dims.x)
	pc.encode_s32(4, grid_dims.y)
	pc.encode_s32(8, grid_dims.z)
	pc.encode_s32(12, mode)
	pc.encode_float(16, cell_size)
	pc.encode_float(20, timestep)
	pc.encode_float(24, 1.0 / cell_size)
	pc.encode_float(28, 0.0)
	pc.encode_float(32, pos.x)
	pc.encode_float(36, pos.y)
	pc.encode_float(40, pos.z)
	pc.encode_float(44, radius)
	pc.encode_float(48, amount)
	pc.encode_float(52, 0.0)
	pc.encode_float(56, 0.0)
	pc.encode_float(60, 0.0)
	return pc


func _upload_config() -> void:
	var f := current_fuel()
	var q: Array = f["q"]
	var v := PackedFloat32Array()
	v.resize(CONFIG_VEC4S * 4)

	# kinetics: A (in shader units), Ea/R [K], a, b
	v[0] = effective_pre_exponential()
	v[1] = ACTIVATION_ENERGY / R_GAS
	v[2] = f["a"]
	v[3] = f["b"]
	# fuel: dcH [J/mol], M_f [kg/mol], Cp, k
	v[4] = f["dch"]
	v[5] = f["m_f"]
	v[6] = f["cp"]
	v[7] = f["k"]
	# stoich: q_f, q_o, q_CO2, q_H2O
	v[8] = q[0]
	v[9] = q[1]
	v[10] = q[2]
	v[11] = q[3]
	# coeffs: D_f, phi, residual, CO2
	v[12] = f["d_f"]
	v[13] = heat_efficiency
	v[14] = residual_coefficient
	v[15] = co2_coefficient
	# thermo: T_amb, radiation coeff, p_amb, T clamp
	v[16] = ambient_temperature
	v[17] = radiation_coefficient
	v[18] = P_AMBIENT
	v[19] = temperature_clamp
	# transport: buoyancy, vorticity, drag, nu
	v[20] = gravity
	v[21] = vorticity_strength
	v[22] = drag
	v[23] = kinematic_viscosity
	# vort thresholds + H2O coefficient
	v[24] = vorticity_velocity_lo
	v[25] = vorticity_velocity_hi
	v[26] = vorticity_temperature_lo
	v[27] = h2o_coefficient
	# wind + residual dissipation
	v[28] = wind.x
	v[29] = wind.y
	v[30] = wind.z
	v[31] = residual_dissipation
	# molar masses
	v[32] = M_O2
	v[33] = M_CO2
	v[34] = M_H2O
	v[35] = M_N2
	# misc: O2 replenish, display T, reaction reference, emitter T
	v[36] = oxygen_replenish
	v[37] = display_temperature
	v[38] = reaction_reference
	v[39] = emitter_temperature

	_rd.buffer_update(_config_buf, 0, v.size() * 4, v.to_byte_array())


# =========================================================================
#  READBACK
# =========================================================================

# Async so the reduction never stalls the render thread; the values lag a frame
# or two, which the light smoothing absorbs anyway.
func _fetch_stats() -> void:
	if _stats_pending or not _stats_buf.is_valid():
		return
	_stats_pending = true
	_rd.buffer_get_data_async(_stats_buf, _on_stats_ready, 0, STATS_WORDS * 4)


func _on_stats_ready(bytes: PackedByteArray) -> void:
	_stats_pending = false
	if bytes.size() < STATS_WORDS * 4:
		return
	_stats_mutex.lock()
	for i in STATS_WORDS:
		_stats[i] = bytes.decode_u32(i * 4)
	_stats_mutex.unlock()


func _read_timings() -> void:
	if not profiling:
		return
	var start_time := 0
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if nm == "fire/start":
			start_time = _rd.get_captured_timestamp_gpu_time(i)
		elif nm == "fire/end":
			_timings_mutex.lock()
			_timings["total"] = float(_rd.get_captured_timestamp_gpu_time(i) - start_time) / 1e6
			_timings_mutex.unlock()


func free_render() -> void:
	if _rd == null:
		return
	initialized = false
	for stage in _sets:
		for set_rid in _sets[stage]:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
	_sets.clear()
	for buf in [_stats_buf, _config_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_stats_buf = RID()
	_config_buf = RID()
	for key in _tex:
		if _tex[key].is_valid():
			_rd.free_rid(_tex[key])
	_tex.clear()
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	_pipelines.clear()
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_shaders.clear()
