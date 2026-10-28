class_name FireGpuSolver
extends RefCounted
## GPU combustion solver implementing Fire-X (Wrede et al., SIGGRAPH Asia 2025,
## ACM TOG 44(6) art. 268), DOI 10.1145/3763338.
##
## Global one-step stoichiometric combustion in real units: mass fractions and
## molar concentrations, Arrhenius kinetics from the paper's Table 1, Boussinesq
## buoyancy, vorticity confinement, MacCormack advection and a pressure
## projection — block Gauss-Seidel over a tile-level coarse solve. Every physical
## constant below is traceable to the paper or to the reference it cites; anything
## that is not is marked NON-PAPER.
##
## All methods except [method push_event] and [method get_stats] must run on the
## rendering thread (RenderingDevice is not thread safe).

const SHADER_DIR := "res://shaders/fire/sparse/"
## Logical pool budgets the menu cycles through. The last rung asks for the large
## 4096-slot atlas; see [member atlas_slots] and [method atlas_slots_for_budget].
const POOL_BUDGETS := [1536, 1792, FireTilePool.NSLOTS, FireTilePool.NSLOTS_LARGE]
const STAGES: Array[String] = [
	"inject", "advect", "maccormack", "forces", "curl", "vorticity", "vortapply",
	"comb_strain", "diffusion", "evaporate", "evapapply", "divergence",
	"pressure", "project", "display",
]
## Resets tiles the pool allocated this frame to ambient air before anything
## reads them. Dispatched over the pool's new-tile list, not the
## active list, so it never appears in the substep loop.
const CLEAR_STAGE := "clear"
## The coarse level of the pressure solve, one unknown per tile.
## restrict and prolong run one workgroup per tile like everything else; the solve
## between them is the one dispatch of the whole solver that is a single
## workgroup, because the entire coarse system fits in its shared memory.
const COARSE_STAGES := ["press_restrict", "press_coarse", "press_prolong"]
const COARSE_SOLVE_STAGE := "press_coarse"
## Stages compiled with the shared-memory velocity apron. Both
## advection passes reconstruct the velocity at four staggered positions per cell,
## which is 33 face loads each and the largest single source of traffic in the
## stage; caching the tile's faces once is measurably cheaper (see
## fire_common.comp). Every other stage reads velocity too rarely to earn the
## 12 KB, and curl and strain reach two cells out, which the apron does not cover.
const VEL_CACHE_STAGES := ["advect", "maccormack"]
## Stages that are two stages compiled into one dispatch. The parts keep their own
## files and are concatenated ahead of the merged stage's main, which is what keeps
## one source of truth for the physics; the parts' standalone mains are compiled
## out by FIRE_MERGED.
const MERGED_PARTS := {"comb_strain": ["combustion", "strain"]}
## Wood emitters the campfire can hold. Each one costs a slot in the config tail
## and a distance test per cell in fire_display.
const MAX_LOGS := 12
## Stats buffer words, reduced by fire_display and fire_evaporate: 11 scalars, then
## one probed gas temperature per wood emitter, then the six words of the
## resident-set bounding box (cell-space min xyz, max xyz) the raymarcher clips to,
## then the sixteen-word diagnostic block (STAT_DIAG in fire_common.comp: three
## protection counters, three energy/mass ledgers, four Cp-probe words, one
## wood-cap clip proxy, two evaporation mass ledgers, three droplet-convection
## words).
## Fractional quantities are stored as fixed point at STAT_SCALE, diagnostic
## masses at STAT_MASS_SCALE.
const STAT_MAX_T := 0
const STAT_REACTION_SUM := 1
const STAT_REACTION_MAX := 2
const STAT_FUEL_SUM := 3
const STAT_O2_SUM := 4
const STAT_REGION_CELLS := 5
const STAT_MASS_SUM := 6
const STAT_COLUMN_CELLS := 7
const STAT_MAX_DIVERGENCE := 8
const STAT_ENERGY_RESIDUAL := 9
const STAT_ENERGY_BUDGET := 10
const STAT_WOOD := 11
const STAT_BOUNDS := STAT_WOOD + MAX_LOGS
const STAT_DIAG := STAT_BOUNDS + 6
const STATS_WORDS := STAT_DIAG + 16
const STAT_SCALE := 1000.0
const STAT_MASS_SCALE := 1e9
## std430 layout of fire_common.comp's Config buffer: [name, vec4 count] in order.
## The GLSL block body is generated from this list (FIRE_CONFIG_FIELDS) and
## [method _upload_config] writes by name, so the order lives only here.
##   kinetics   A (SI), Ea/R [K], a, b              Fire-X Eq. 5 / WD Tab. I
##   fuel       dcH [J/mol], M_f [kg/mol], Cp, k    Fire-X Tab. 1
##   stoich     q_f, q_o, q_CO2, q_H2O              Fire-X Tab. 1
##   coeffs     D_f, phi, residual_coeff, co2_coeff Fire-X Tab. 1 / Tab. 3
##   thermo     T_amb, radiation_coeff, p_amb, T_clamp
##   transport  buoyancy, vorticity_eps, drag, nu
##   vort       vel_lo, vel_hi, temp_lo, h2o_coeff  Fire-X Tab. 3
##   wind       wind.xyz, residual_dissipation
##   molar      M_O2, M_CO2, M_H2O, M_N2 [kg/mol]
##   misc       vorticity_dt_scale, display_temperature, reaction_reference, emitter_T
##   liquid     T_B [K], dvH [J/kg], Cp_l [J/(kg.K)], rho_d [kg/m^3]  NIST, Tab. 4
##   liquid2    d_d [m], h_conv [W/(m^2.K)], wet_suppression, wood_shelter_rate
##   wood       per log: pos.xyz, radius [m] (radius 0 = free slot)
##   wood_rate  per log: Y_fuel per simulated second, pilot temperature [K]
##   torch      pos.xyz, nozzle radius
##   torch2     direction * length, fuel rate
##   torch3     tip radius, temperature, speed, pilot fraction
##   diag       flags (bit0 counters, bit1 Cp probe), probe T [K],
##              Eq. 27 evaporation Cp A/B (0 gas [shipped], 1 liquid),
##              droplet h model (0 constant [shipped], 1 Ranz-Marshall)
## NON-PAPER wood tail: Fire-X only has the gas grid emitter of Tab. 3; the solid
## fuel bed lives on the CPU (wood_pile.gd). The release goes down through
## fire_inject (mode 5), the gas temperature that drives it comes back up through
## fire_display's probes.
const CONFIG_LAYOUT := [
	["kinetics", 1], ["fuel", 1], ["stoich", 1], ["coeffs", 1], ["thermo", 1],
	["transport", 1], ["vort", 1], ["wind", 1], ["molar", 1], ["misc", 1],
	["liquid", 1], ["liquid2", 1], ["wood", MAX_LOGS], ["wood_rate", MAX_LOGS],
	["torch", 1], ["torch2", 1], ["torch3", 1], ["diag", 1],
]

enum { EVENT_FUEL = 1, EVENT_IGNITE = 2, EVENT_WATER = 3, EVENT_SMOTHER = 4,
	EVENT_WOOD = 5, EVENT_TORCH = 6 }

## Concentration units the Arrhenius pre-exponential factor is expressed in.
## Westbrook & Dryer Tab. I states "Units are cm-sec-mole-kcal-Kelvins", so the
## published A values are CGS. Fire-X reproduces those numbers verbatim while
## its nomenclature gives concentrations in mol/m^3 without mentioning a
## conversion, so both readings are offered and compared.
enum { UNITS_CGS = 0, UNITS_SI_AS_PRINTED = 1 }
## ADVECTION_MACCORMACK_SCALARS transports the scalars with the limited
## second-order scheme and the velocity with plain semi-Lagrangian. The
## correction pass is the most expensive stage after the projection and half of it
## is spent on the three face components, where the extra order buys swirl that
## vorticity confinement is already there to supply; the smearing that MacCormack
## exists to prevent is visible on the temperature and species fields, which keep
## it. Appended rather than inserted so the stored preset indices keep meaning
## what they meant.
enum { ADVECTION_MACCORMACK = 0, ADVECTION_SEMI_LAGRANGIAN = 1,
	ADVECTION_MACCORMACK_SCALARS = 2 }
enum { VORTICITY_FULL = 0, VORTICITY_REDUCED = 1, VORTICITY_OFF = 2 }

## Every field texture is created with these bits; the fp16 probe below asks the
## device about the same set.
const TEX_USAGE := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
	| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
	| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

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
const SIGMA_SB := 5.67e-8 ## Stefan-Boltzmann [W/(m^2.K^4)]
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

## The fire itself roams the whole virtual domain (see [method sim_dims]); this is
## only the box the SPH droplets are given as their own neighbour-grid domain,
## 12.8 x 19.2 x 12.8 m at the default cell size.
var config: FireConfig = FireConfig.new()
var grid_dims := Vector3i(64, 96, 64)
var cell_size := 0.2 ## Grid length 12.8 x 19.2 x 12.8 m; Tab. 3 allows 0.1-10.0 m

var fuel_index := 0
var units_convention := UNITS_CGS

## Gates the per-substep diagnostic atomics (fire_common.comp STAT_DIAG): the
## protection counters and the chemical-heat/fuel/pilot ledgers. Off by default;
## each gated site is one uniform test per cell when off.
var diagnostic_counters := false
## Enables the pure-species molar Cp probe at [member diagnostic_probe_temperature]
## (one cell of fire_display writes four words per substep).
var diagnostic_cp_probe := false
var diagnostic_probe_temperature := 300.0
## Diagnostic A/B on the Eq. 27 evaporation Cp (cfg.diag.z): false charges the
## gas mixture Cp (the shipped convention), true the liquid Cp the paper's
## symbol table arguably names. Tests/fire_water_balance_test.gd measures the
## difference; flip nothing without that measurement in hand.
var diagnostic_evap_liquid_cp := false

var ambient_temperature := 300.0 ## Fire-X Tab. 3
var simulation_hz := 30
var timestep := 1.0 / 30.0
var max_catchup_steps := 4
## Game policy: the clock's debt never exceeds what the catchup can clear in one
## frame, and wall time beyond that is counted in dropped_time instead of
## queueing an invisible catch-up sprint the frame rate pays for later.
## Validation runs that must reconcile wall == sim + accumulator + dropped
## across a recovery set this false to keep the old unbounded debt.
var clock_debt_capped := true
var pressure_iterations := 64 ## Fire-X Tab. 3, range 64-128
## Relaxation sweeps run inside one pressure dispatch, against the
## halo the workgroup cached on entry (block-Jacobi / additive Schwarz). They ride
## along inside a pass rather than replacing passes: pressure_iterations still
## counts dispatches.
var pressure_inner_sweeps := 4
## Over-relaxation of the red-black sweep. 1.0 is plain Gauss-Seidel,
## and measured, it is the best value: 1.3 was slightly worse, 1.6 clearly worse
## and 1.7 diverged (max_divergence 37). Over-relaxing inside a block amplifies
## the mismatch against a halo that is frozen for the pass, which is the opposite
## of what SOR does on a globally consistent sweep. Kept as a knob because it is
## the falsifiable part of that claim.
var pressure_sor_omega := 1.0
## Coarse-grid corrections per projection, each followed by an equal
## share of the fine sweeps. 0 disables the two-level solve. A second cycle was
## measured inside the run-to-run noise, so one is what ships.
var pressure_coarse_cycles := 1
## Over-relaxation of the coarse solve (see fire_press_coarse.comp).
var pressure_coarse_omega := 1.8
var advection_mode := ADVECTION_MACCORMACK

var radiation_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-6.0
var heat_efficiency := 1.0 ## phi in Eq. 6; Fire-X Tab. 3, range 0.0-1.0
var co2_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var h2o_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var residual_coefficient := 1.0 ## Fire-X Tab. 3, range 0.0-10.0
var temperature_clamp := 3000.0 ## Tab. 3 "Density temperature coupling limit"
var emitter_temperature := 1500.0 ## Tab. 3 grid emitter, range 300-1500 K

var vorticity_strength := 8.0 ## Fire-X Tab. 3, range 0.0-50.0
var vorticity_mode := VORTICITY_FULL
var vorticity_interval := 1
var vorticity_velocity_lo := 0.0 ## Fire-X Tab. 3, range 0.0-0.1
## Tab. 3 lists 0.0-5.0 without units; 5 m/s cut confinement out of the plume
## core, so the gate sits at the 50 m/s velocity clamp, i.e. no upper gate.
var vorticity_velocity_hi := 50.0
var vorticity_temperature_lo := 301.0 ## Fire-X Tab. 3

var wind := Vector3.ZERO ## NON-PAPER: inflow boundary condition for the demo
var gravity := 9.81 ## Buoyancy magnitude in Eq. 1
var kinematic_viscosity := 1.5e-5 ## NON-PAPER: air at ambient, Eq. 1 nu
var smagorinsky_cs := 0.17 ## NON-PAPER: sub-grid turbulence constant, 0 = disabled
var drag := 0.0 ## NON-PAPER: stability aid, 0 = disabled
## NON-PAPER: how fast the wood bed damps horizontal flow in its own wind shadow
## [1/s], so a breeze leans the plume instead of tearing the flame off the bed.
## Only acts inside the wood emitter spheres (see wood_shelter in fire_common),
## so it is a no-op in gas mode. 0 disables it.
var wood_shelter_rate := 8.0
var residual_dissipation := 0.03 ## NON-PAPER: soot settling in cold cells
## Evaporation (Eq. 9-11, 26-32). Water at 1 atm, from the NIST Chemistry
## WebBook [Linstrom & Mallard], which is the source Fire-X Tab. 4 names for the
## liquid properties ("Water or Ethanol").
var boiling_temperature := 373.15 ## T_B [K]
var latent_heat := 2.257e6 ## Delta_vH0 [J/kg]
var liquid_heat_capacity := 4182.0 ## Cp,l [J/(kg.K)]
## INFERRED: the paper defines rho_d as "the amount of liquid in the form of
## droplets", which is circular with Eq. 28. Read as the bulk liquid density, so
## rho_l/rho_d is the liquid volume fraction of the cell.
var droplet_density := 998.0
var droplet_diameter := 0.001 ## d_d, Fire-X Tab. 3 range 0.0005-0.005 m
## UNDEFINED IN PAPER: Eq. 10 writes this as a conductivity k in W/(m.K), which
## does not balance dimensionally. Taken as a convective heat transfer
## coefficient against the droplet surface; 50 W/(m^2.K) is Nu = 2 conduction on
## a 1 mm droplet. See the header of fire_evaporate.comp.
var droplet_heat_transfer := 50.0
## NON-PAPER A/B (cfg.diag.w): replaces [member droplet_heat_transfer] by the
## Ranz-Marshall droplet convection, Nu = 2 + 0.6 Re^1/2 Pr^1/3, evaluated per
## cell from the gas/droplet slip and the air properties at the film temperature.
var droplet_ranz_marshall := false
## NON-PAPER: how strongly liquid in a cell suppresses combustion there, as
## v_c /= (1 + k.rho_l). The paper's spray extinguishes a flame by disrupting the
## flow and cutting the oxygen supply (Sec. 6.1.3); this grid's pinned emitter and
## steady oxygen inflow give it no way to blow out, so cooling alone makes a wet
## flame spread rather than die. This restores the sign. See fire_combustion.comp.
## At the default, spray on the flame base drops the reaction below its dry level
## (measured); below ~20 the density boost wins and water makes the fire worse.
var water_suppression := 40.0
## NON-PAPER: slow loss of pooled liquid to the ground per second, as
## m_p *= (1 - rate.dt), applied on top of Eq. 26-28 evaporation. A cold puddle
## cannot heat itself back to its boiling point, so real evaporation stalls and the
## grid stays wet and suppressed forever; this drains the droplets (runs off / soaks
## in) so a rekindled fire can recover, and is the only way one ever leaves.
##
## Owned here so one slider drives it, but applied by water_return.comp through
## FireWater.drain_rate: it has to run on frames where the evaporation stage is
## skipped, which is where it is the only cleanup left.
var liquid_drain_rate := 0.2
var evaporation_enabled := true

var display_temperature := 2600.0 ## Renderer normalisation only
var reaction_reference := 50.0 ## Renderer normalisation only [mol/(m^3.s)]
var torch_length := 5.0
var torch_nozzle_radius := 0.3
var torch_tip_radius := 0.9
var torch_rate := 1.5
var torch_temperature := 1500.0
var torch_speed := 9.0
var torch_ignite_fraction := 0.3

## The fire roams a 409.6 x 102.4 x 409.6 m virtual domain at a cost set by how
## much of it is burning, rather than a fixed box at a cost set by the box.
var pool_budget := FireTilePool.NSLOTS
## Atlas capacity the solver was compiled for: 2048 slots (16x8x16 tiles) by
## default, 4096 (16x16x16) when asked. The larger atlas doubles every field
## texture and needs 16 KB of compute shared memory for the coarse pressure
## solve; init_render validates the device limit and falls back to the base
## atlas, so this can be set freely before init and read after it.
var atlas_slots := FireTilePool.NSLOTS

# Tile pool policy. The dilation band has to exceed the distance the fire can
# travel between topology updates: velocity is clamped to 50 m/s, so at the
# lowest supported 30 Hz and 0.2 m cells the worst case is ~8.4 cells.
const TILE_ACTIVITY_THRESHOLD := 1.0 ## fire_display normalises every term to this
const TILE_HOLD_FRAMES := 8 ## hysteresis, so a flickering front does not thrash
## Multiplies every keep cut-off in fire_display; above 1 the faint plume tail
## is released sooner and the resident set (and every stage's cost) shrinks.
var tile_keep_scale := 1.0
## Soft cap on resident tiles inside the allocated pool, 0 = the whole pool. Cost
## is linear in resident tiles, and unlike pool_budget it changes without a rebuild.
var tile_budget := 0
## The FORWARD radius: up and downwind. The other four directions get one tile
## less, which is still above that bound (see tile_dilate.comp).
const TILE_DILATE_RADIUS := 2
## Pool-pressure relief (see keep_threshold in tile_common.comp). Below this
## fraction of the budget still free, the keep threshold ramps up to
## TILE_RELIEF_MAX times its nominal value, so a pool that is running out spends
## what is left on the tiles with the strongest signal instead of on whichever
## ones asked first. A flame clears the raised bar by two orders of magnitude, so
## what it drops is the cold smoke and entrained air at the margin.
const TILE_RELIEF_FRACTION := 0.25
const TILE_RELIEF_MAX := 8.0
## Virtual tiles inside this world-space box around the emitter are pinned
## resident. Without it a fire that walks away frees its own burner and the next
## injection lands in an inactive tile and is dropped.
const PIN_HALF_XZ := 3.2
const PIN_HEIGHT := 6.4
const CLOCK_EPSILON := 1e-6

var initialized := false
var profiling := false
var last_substeps := 0
var wall_time := 0.0
var simulation_time := 0.0
var dropped_time := 0.0

var _rd: RenderingDevice
var _pool: FireTilePool
var _display_format := RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
var _stages: Array[String] = []
var _frame := 0
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := {}
var _stats_buf := RID()
var _config_buf := RID()
var _coarse_val_buf := RID()
var _coarse_idx_buf := RID()
var _config_cache := PackedByteArray()
var _parity := 0
var _simulation_step := 0
var _topology_prepared := false

var _events: Array[Dictionary] = []
var _events_mutex := Mutex.new()
## Wood emitters, flattened as the config tail expects: eight floats per slot,
## (pos.xyz, radius) then (rate, 0, 0, 0). A zero radius marks a free slot.
var _wood := PackedFloat32Array()
var _wood_mutex := Mutex.new()
var _wood_any := false
var _torch_position := Vector3.ZERO
var _torch_direction := Vector3.FORWARD
var _torch_axis_length := 0.0
var _torch_seed_p0 := Vector3.ZERO
var _torch_seed_p1 := Vector3.ZERO
var _torch_seed_radius := 0.0
var _torch_any := false
var _torch_seed_any := false
var _torch_mutex := Mutex.new()
var _stats := PackedInt64Array()
var _stats_mutex := Mutex.new()
var _stats_pending := false
var _pool_stats_cache := {}
var _pool_stats_mutex := Mutex.new()
var _pool_counts_pending := false
var _bootstrap_bounds := AABB()
var _display_bounds_ready := false
var _display_hyst := DisplayBoxHysteresis.new()
var _timing_store := GpuTimingStore.new()
var _time_accumulator := 0.0


func _init() -> void:
	liquid_drain_rate = config.liquid_drain_rate_per_s
	_stats.resize(STATS_WORDS)
	_wood.resize(MAX_LOGS * 8)


func get_display_tex_rid() -> RID:
	return _tex.get("display", RID())


func get_previous_display_tex_rid() -> RID:
	return _tex.get("display_prev", RID())


func get_previous_visual_activity_tex_rid() -> RID:
	return _tex.get("visual_activity_prev", RID())


func get_visual_activity_tex_rid() -> RID:
	return _tex.get("visual_activity", RID())


func get_liquid_scal_tex_rid() -> RID:
	return _tex.get("liquid_scal", RID())


func get_liquid_velocity_tex_rid() -> RID:
	return _tex.get("liquid_vel", RID())


func previous_indirection_bytes_rid() -> RID:
	return _tex.get("indir_prev", RID())


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


func set_simulation_hz(value: int) -> void:
	simulation_hz = clampi(value, 5, 120)
	timestep = 1.0 / float(simulation_hz)
	reset_clock()


func reset_clock() -> void:
	_time_accumulator = 0.0
	wall_time = 0.0
	simulation_time = 0.0
	dropped_time = 0.0
	last_substeps = 0


func schedule_steps(delta: float) -> int:
	var frame_delta := maxf(delta, 0.0)
	wall_time += frame_delta
	if frame_delta > 0.1:
		dropped_time += frame_delta - 0.1
		frame_delta = 0.1
	_time_accumulator += frame_delta
	var available := int(floor(_time_accumulator / timestep + CLOCK_EPSILON))
	var count := mini(available, max_catchup_steps)
	_time_accumulator -= float(count) * timestep
	# Capped after stepping: capping before dropped the sub-step fraction, so
	# catchup 1 ran the simulation at 58-92 % of real time between 35 and 55 fps.
	if clock_debt_capped and _time_accumulator > timestep:
		dropped_time += _time_accumulator - timestep
		_time_accumulator = timestep
	last_substeps = count
	simulation_time += float(count) * timestep
	return count


func interpolation_alpha() -> float:
	return clampf(_time_accumulator / timestep, 0.0, 1.0)


func get_clock_stats() -> Dictionary:
	return {
		"simulation_hz": simulation_hz,
		"timestep": timestep,
		"wall_time": wall_time,
		"simulation_time": simulation_time,
		"accumulator": _time_accumulator,
		"interpolation_alpha": interpolation_alpha(),
		"dropped_time": dropped_time,
		"ratio": simulation_time / maxf(wall_time, 1e-6),
	}


## Queue a grid interaction; consumed by the next [method step_render].
## Safe to call from the main thread.
##
func push_event(mode: int, position_m: Vector3, radius_m: float,
		amount_per_step: float) -> void:
	_events_mutex.lock()
	# Bounded: the caller queues one emitter event per frame, so an unconsumed
	# queue means the solver never came up and events would pile up forever.
	if _events.size() < 64:
		_events.append({"mode": mode, "pos": position_m, "radius": radius_m,
			"amount": amount_per_step})
	_events_mutex.unlock()


## Replace the whole set of wood emitters, as
## [code]{pos, radius, rate, pilot}[/code] dictionaries. Rates are fuel mass
## fraction per simulated second, the same unit the gas emitter's amount is in;
## [code]pilot[/code] is the glowing char surface temperature in kelvins, 0 for a
## log that is not burning.
##
## They are uploaded with the config rather than queued as events, so the entire
## pile costs ONE inject dispatch instead of one per log — and the same table
## doubles as the probe list fire_display reduces the local gas temperature into,
## which is what drives the pyrolysis on the CPU side. A log with a zero rate
## still needs its slot: that is how a cold log gets a temperature to heat up by.
##
## Safe to call from the main thread.
func set_wood_emitters(emitters: Array) -> void:
	var flat := PackedFloat32Array()
	flat.resize(MAX_LOGS * 8)
	var count := mini(emitters.size(), MAX_LOGS)
	for i in count:
		var e: Dictionary = emitters[i]
		var p: Vector3 = e["pos"]
		flat[i * 4 + 0] = p.x
		flat[i * 4 + 1] = p.y
		flat[i * 4 + 2] = p.z
		flat[i * 4 + 3] = e["radius"]
		flat[MAX_LOGS * 4 + i * 4] = e["rate"]
		flat[MAX_LOGS * 4 + i * 4 + 1] = e["pilot"]
	_wood_mutex.lock()
	_wood = flat
	_wood_any = count > 0
	_wood_mutex.unlock()


func set_torch(position: Vector3, direction: Vector3, length: float) -> void:
	_torch_mutex.lock()
	_torch_position = position
	_torch_direction = direction.normalized()
	_torch_axis_length = maxf(length, 0.0)
	_torch_any = _torch_axis_length > 0.0 and not _torch_direction.is_zero_approx()
	_torch_mutex.unlock()


func set_torch_seed(p0: Vector3, p1: Vector3, radius: float) -> void:
	_torch_mutex.lock()
	_torch_seed_p0 = p0
	_torch_seed_p1 = p1
	_torch_seed_radius = maxf(radius, 0.0)
	_torch_seed_any = _torch_seed_radius > 0.0
	_torch_mutex.unlock()


func clear_torch() -> void:
	_torch_mutex.lock()
	_torch_any = false
	_torch_seed_any = false
	_torch_mutex.unlock()


## Last reduced frame. Safe to call from the main thread.
func get_stats() -> Dictionary:
	_stats_mutex.lock()
	var s := _stats.duplicate()
	_stats_mutex.unlock()
	var region := maxf(float(s[STAT_REGION_CELLS]), 1.0)
	var column := maxf(float(s[STAT_COLUMN_CELLS]), 1.0)
	# Peak gas temperature inside each wood emitter's sphere over the last
	# substep, in kelvins. This is what couples the pyrolysis to the flame the
	# solver actually produced rather than to a global scalar.
	var wood_temps := PackedFloat32Array()
	wood_temps.resize(MAX_LOGS)
	for i in MAX_LOGS:
		wood_temps[i] = float(s[STAT_WOOD + i])
	return {
		"wood_temperatures": wood_temps,
		"max_temperature": float(s[STAT_MAX_T]),
		"total_reaction": float(s[STAT_REACTION_SUM]) / STAT_SCALE,
		"max_reaction": float(s[STAT_REACTION_MAX]) / STAT_SCALE,
		"avg_fuel": float(s[STAT_FUEL_SUM]) / STAT_SCALE / region,
		"avg_oxygen": float(s[STAT_O2_SUM]) / STAT_SCALE / region,
		"mass_fraction_sum": float(s[STAT_MASS_SUM]) / STAT_SCALE / column,
		# Peak |div u| left over after the projection, in 1/s. The falsifiable
		# check on the staggered discretisation: with the gradient the exact
		# adjoint of the divergence this is the Jacobi residual and nothing else,
		# so it must fall when pressure_iterations rises. A collocated grid leaves
		# a checkerboard the projection cannot see, and the value stalls instead.
		"max_divergence": float(s[STAT_MAX_DIVERGENCE]) / STAT_SCALE,
		# The P4 criterion: |dE_gas + dE_liq + latent| summed over the wet cells,
		# against the sum of the three magnitudes. Zero by construction of the
		# evaporation update, so what it actually reports is what breaks that —
		# the temperature clamp above all. Per-cell magnitudes are summed, so
		# opposite-signed errors in different cells cannot cancel into a pass.
		"energy_residual": float(s[STAT_ENERGY_RESIDUAL]) / maxf(float(s[STAT_ENERGY_BUDGET]), 1.0),
		"energy_budget": float(s[STAT_ENERGY_BUDGET]) / STAT_SCALE, # millijoules -> J
		# Diagnostic block, one substep's worth (fire_advect clears it each step).
		# The counters are events per substep; the ledgers are J and kg.
		"diag_reactant_clamps": float(s[STAT_DIAG + 0]),
		"diag_temperature_clamps": float(s[STAT_DIAG + 1]),
		"diag_renormalisations": float(s[STAT_DIAG + 2]),
		"diag_chemical_heat_j": float(s[STAT_DIAG + 3]) / STAT_SCALE,
		"diag_fuel_burned_kg": float(s[STAT_DIAG + 4]) / STAT_MASS_SCALE,
		"diag_pilot_heat_j": float(s[STAT_DIAG + 5]) / STAT_SCALE,
		"diag_cp_n2": float(s[STAT_DIAG + 6]) / STAT_SCALE,
		"diag_cp_o2": float(s[STAT_DIAG + 7]) / STAT_SCALE,
		"diag_cp_co2": float(s[STAT_DIAG + 8]) / STAT_SCALE,
		"diag_cp_h2o": float(s[STAT_DIAG + 9]) / STAT_SCALE,
		# Unit-density mass proxy for the fuel Y_WOOD_MAX refused, per substep.
		"diag_wood_cap_clipped": float(s[STAT_DIAG + 10]) / STAT_MASS_SCALE,
		"diag_evaporated_kg": float(s[STAT_DIAG + 11]) / STAT_MASS_SCALE,
		"diag_h2o_gained_kg": float(s[STAT_DIAG + 12]) / STAT_MASS_SCALE,
		# Droplet convection over the wet cells: mean h [W/(m^2.K)] and mean
		# gas/droplet slip [m/s].
		"diag_wet_cells": float(s[STAT_DIAG + 14]),
		"diag_h_mean": float(s[STAT_DIAG + 13]) / maxf(float(s[STAT_DIAG + 14]), 1.0),
		"diag_slip_mean": float(s[STAT_DIAG + 15]) / STAT_SCALE
			/ maxf(float(s[STAT_DIAG + 14]), 1.0),
	}


## Simulation-space box for the volume proxy. Safe to call from the main thread.
##
## The readback bounds are the raw resident set, which flickers: a tile drops
## out for one frame and the proxy — and every shader keyed to it — pumps. The
## hysteresis (lot I) grows the published box the instant the bounds demand it,
## but only shrinks after a quiet delay and then at a bounded speed, so cuts
## are still impossible while the box bleeds off slowly instead of jumping.
func display_clip_box(margin := 1.6) -> AABB:
	var box := Vector3(sim_dims()) * cell_size
	var origin := Vector3(-box.x * 0.5, 0.0, -box.z * 0.5)
	var full := AABB(origin, box)
	_stats_mutex.lock()
	var ready := _display_bounds_ready
	var lo := Vector3(float(_stats[STAT_BOUNDS]), float(_stats[STAT_BOUNDS + 1]),
		float(_stats[STAT_BOUNDS + 2]))
	var hi := Vector3(float(_stats[STAT_BOUNDS + 3]), float(_stats[STAT_BOUNDS + 4]),
		float(_stats[STAT_BOUNDS + 5]))
	_stats_mutex.unlock()
	if not ready:
		var initial := _bootstrap_bounds
		if initial.size == Vector3.ZERO:
			initial = _compute_bootstrap_bounds()
		var initial_p0 := (initial.position - Vector3.ONE * margin).clamp(full.position, full.end)
		var initial_p1 := (initial.end + Vector3.ONE * margin).clamp(full.position, full.end)
		return AABB(initial_p0, initial_p1 - initial_p0)
	var p0 := (origin + lo * cell_size - Vector3.ONE * margin).clamp(full.position, full.end)
	var p1 := (origin + hi * cell_size + Vector3.ONE * margin).clamp(full.position, full.end)
	return _display_hyst.update(AABB(p0, p1 - p0), Time.get_ticks_msec())


## Grow-now, shrink-late-and-slow hysteresis for the display proxy box.
## Deliberately dumb and time-explicit so it is unit-testable headless: update()
## is the whole policy.
class DisplayBoxHysteresis:
	## Quiet time since the last grow before any face may move in.
	const SHRINK_DELAY := 2.0
	## Per-face speed limit while shrinking, m/s.
	const SHRINK_SPEED := 2.0

	var box := AABB()
	var _last_grow_msec := -1
	var _last_update_msec := -1

	func update(target: AABB, now_msec: int) -> AABB:
		var dt := 1.0 / 60.0
		if _last_update_msec >= 0:
			dt = clampf(float(now_msec - _last_update_msec) * 0.001, 0.001, 0.25)
		_last_update_msec = now_msec
		if box.size == Vector3.ZERO:
			box = target
			_last_grow_msec = now_msec
			return box
		if not box.encloses(target):
			# Anything but a pure shrink — growth, translation, both — is
			# adopted at once: an uncovered sample is a visible cut, a stale
			# margin is nothing at all.
			box = target
			_last_grow_msec = now_msec
			return box
		if float(now_msec - _last_grow_msec) * 0.001 < SHRINK_DELAY:
			return box
		var step := SHRINK_SPEED * dt
		var lo := Vector3(
			_box_axis(box.position.x, target.position.x, step),
			_box_axis(box.position.y, target.position.y, step),
			_box_axis(box.position.z, target.position.z, step))
		var hi := Vector3(
			_box_axis(box.end.x, target.end.x, step),
			_box_axis(box.end.y, target.end.y, step),
			_box_axis(box.end.z, target.end.z, step))
		box = AABB(lo, hi - lo)
		return box

	## One face moved toward its target by at most [param step].
	func _box_axis(current: float, target: float, step: float) -> float:
		return current + clampf(target - current, -step, step)


func _compute_bootstrap_bounds() -> AABB:
	var dims := sim_dims()
	var half := Vector3(dims.x, 0.0, dims.z) * cell_size * 0.5
	var lo := Vector3i((Vector3(-PIN_HALF_XZ, 0.0, -PIN_HALF_XZ) + half) / cell_size) \
		/ FireTilePool.TILE
	var hi := Vector3i((Vector3(PIN_HALF_XZ, PIN_HEIGHT, PIN_HALF_XZ) + half) / cell_size) \
		/ FireTilePool.TILE
	var cell_lo := lo * FireTilePool.TILE
	var cell_hi := (hi + Vector3i.ONE) * FireTilePool.TILE
	var origin := Vector3(-float(dims.x) * cell_size * 0.5, 0.0,
		-float(dims.z) * cell_size * 0.5)
	return AABB(origin + Vector3(cell_lo) * cell_size,
		Vector3(cell_hi - cell_lo) * cell_size)


func get_timings() -> Dictionary:
	return _timing_store.snapshot()


## The atlas a pool budget implies: only the 4096-tile rung asks for the large
## atlas. Coarse pressure at 4096 slots is a 16 KB shared array, twice the
## guaranteed minimum — callers that want it must go through init's device check.
static func atlas_slots_for_budget(budget: int) -> int:
	return FireTilePool.NSLOTS_LARGE if budget > FireTilePool.NSLOTS \
		else FireTilePool.NSLOTS


## Diagnostic A/B for the display soot channel (lot K): when the environment
## asks for it, display/display_prev are RGBA16F instead of RGBA8, which keeps
## the finely visible smoke band from quantising into ~5-7 levels. Off by
## default; adoption is pending the baseline's memory/cost/fumée-fine comparison.
static func display_fp16_requested() -> bool:
	return OS.get_environment("FIRE_DISPLAY_F16") == "1"


# =========================================================================
#  SETUP
# =========================================================================

func init_render() -> void:
	config.dense_grid_dims = grid_dims
	config.cell_size_m = cell_size
	var config_error := config.validate()
	if config_error != "":
		push_error("Fire config: %s" % config_error)
		return
	_rd = GpuPreflight.device("FireGpuSolver")
	if _rd == null:
		return

	# The large atlas lives or dies on the coarse solve: fire_press_coarse holds
	# the whole tile-level system in one shared array, 4096 floats = 16 KB.
	# Anything below that is a fallback to the base atlas, which needs 8 KB.
	if atlas_slots > FireTilePool.NSLOTS:
		var shared_limit := _rd.limit_get(
			RenderingDevice.LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE)
		if shared_limit < atlas_slots * 4:
			push_warning(
				"Fire atlas %d needs %d B of shared memory for the coarse solve (device limit %d B); falling back to %d slots."
				% [atlas_slots, atlas_slots * 4, shared_limit, FireTilePool.NSLOTS])
			atlas_slots = FireTilePool.NSLOTS
	var slots := atlas_slots

	# Soot channel A/B: shader qualifier and texture format must agree, so the
	# decision is taken once here and both sides read it.
	_display_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	var display_fmt_name := "rgba8"
	if display_fp16_requested():
		var f16 := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		if _rd.texture_is_format_supported_for_usage(f16, TEX_USAGE):
			_display_format = f16
			display_fmt_name = "rgba16f"
		else:
			push_warning("rgba16f storage unsupported; display stays rgba8.")

	var preamble: String = "#version 450\n" + str(scratch_formats(_rd)["preamble"]) \
		+ glsl_defines() + FireTilePool.glsl_header(slots) \
		+ "#define FMT_DISPLAY %s\n" % display_fmt_name
	_stages = STAGES.duplicate()
	_stages.append(CLEAR_STAGE)
	_stages.append_array(COARSE_STAGES)

	var common := FileAccess.get_file_as_string(SHADER_DIR + "fire_common.comp")
	for stage in _stages:
		var stage_src := ""
		# The 10^3 velocity apron costs 12 KB of shared memory, so only the two
		# stages that reconstruct velocity at every cell of their tile get it.
		var defines := preamble
		if stage in VEL_CACHE_STAGES:
			defines += "#define FIRE_VEL_CACHE\n"
		if stage in MERGED_PARTS:
			defines += "#define FIRE_MERGED\n"
			for part in MERGED_PARTS[stage]:
				stage_src += FileAccess.get_file_as_string(
					SHADER_DIR + "fire_" + part + ".comp") + "\n"
		stage_src += FileAccess.get_file_as_string(SHADER_DIR + "fire_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "fire_" + stage, defines + "\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Fire stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	_create_textures()

	# The pool shares the solver's device and borrows the activity texture, which
	# fire_display writes and tile_mark reduces. It has to come up before the
	# uniform sets, which bind its indirection volume and tile lists.
	_pool = FireTilePool.new()
	if not _pool.init_render(_rd, _tex["activity"], mini(pool_budget, slots), slots):
		push_error("Fire solver could not bring up the tile pool.")
		_pool = null
		return

	var stats_bytes := PackedByteArray()
	stats_bytes.resize(STATS_WORDS * 4)
	_stats_buf = _rd.storage_buffer_create(stats_bytes.size(), stats_bytes)

	var config_bytes := PackedByteArray()
	config_bytes.resize(config_vec4s() * 16)
	_config_buf = _rd.storage_buffer_create(config_bytes.size(), config_bytes)

	# The coarse level of the pressure solve. One unknown per atlas slot, so both
	# buffers are fixed size: the right-hand side and the correction, then the face
	# mask, the slot -> unknown map and the six coarse neighbours.
	var coarse_val_bytes := PackedByteArray()
	coarse_val_bytes.resize(2 * slots * 4)
	_coarse_val_buf = _rd.storage_buffer_create(coarse_val_bytes.size(), coarse_val_bytes)
	var coarse_idx_bytes := PackedByteArray()
	coarse_idx_bytes.resize(8 * slots * 4)
	_coarse_idx_buf = _rd.storage_buffer_create(coarse_idx_bytes.size(), coarse_idx_bytes)

	_build_uniform_sets()
	_bootstrap_pool()
	_parity = 0
	_simulation_step = 0
	_topology_prepared = false
	initialized = true


## Cell dimensions of the simulated domain: the whole virtual tile grid, of which
## only the resident tiles are ever touched. This is what goes in the push
## constant, so cell_to_world and every boundary test in the shaders are expressed
## against it — and it is the coordinate system anything coupling into the grid
## from outside has to bin into (FireWater).
func sim_dims() -> Vector3i:
	return config.sim_dims_cells()


func domain_size_m() -> Vector3:
	return config.sparse_domain_size_m()


func dense_domain_size_m() -> Vector3:
	return config.dense_domain_size_m()


## Atlas geometry this instance was built with; the presentation and the water
## side size their own resources against these instead of the class constants.
func atlas_tiles() -> Vector3i:
	return FireTilePool.atlas_tiles_for(atlas_slots)


func atlas_cells() -> Vector3i:
	return FireTilePool.atlas_cells_for(atlas_slots)


## The tile pool's indirection volume, for a coupled stage that lives outside this
## class and has to resolve a virtual cell to its atlas texel.
func indirection_rid() -> RID:
	return _pool.indir_rid() if _pool != null else RID()


## The same volume as a sampled RGBA8 view, for the raymarcher; see
## [method FireTilePool.indir_bytes_rid].
func indirection_bytes_rid() -> RID:
	return _pool.indir_bytes_rid() if _pool != null else RID()


## Extent of the field textures: a tile atlas, not the domain — sized by the
## atlas this instance was built with (2048 or 4096 slots).
func _field_dims() -> Vector3i:
	return FireTilePool.atlas_cells_for(atlas_slots)


## Seed the pool with the tiles around the emitter and pin them resident.
func _bootstrap_pool() -> void:
	var dims := sim_dims()
	# Inverse of cell_to_world: x/z are centred on the origin, y runs up from the
	# ground, so world zero sits at the middle of the virtual grid in x and z.
	var half := Vector3(dims.x, 0.0, dims.z) * cell_size * 0.5
	var lo := Vector3i((Vector3(-PIN_HALF_XZ, 0.0, -PIN_HALF_XZ) + half) / cell_size) \
		/ FireTilePool.TILE
	var hi := Vector3i((Vector3(PIN_HALF_XZ, PIN_HEIGHT, PIN_HALF_XZ) + half) / cell_size) \
		/ FireTilePool.TILE
	var vtis := PackedInt32Array()
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				vtis.append(FireTilePool.vti_of(Vector3i(x, y, z)))
	_pool.bootstrap(vtis, lo, hi)
	var cell_lo := lo * FireTilePool.TILE
	var cell_hi := (hi + Vector3i.ONE) * FireTilePool.TILE
	var origin := Vector3(-float(dims.x) * cell_size * 0.5, 0.0,
		-float(dims.z) * cell_size * 0.5)
	_bootstrap_bounds = AABB(origin + Vector3(cell_lo) * cell_size,
		Vector3(cell_hi - cell_lo) * cell_size)
	_stats_mutex.lock()
	_display_bounds_ready = false
	_stats_mutex.unlock()
	# The hysteresis box belongs to the old resident set; the next ready readback
	# adopts its target outright rather than shrinking toward it for seconds.
	_display_hyst = DisplayBoxHysteresis.new()
	_frame = 0


## Rebuild the tile pool at a new logical slot budget. Rendering thread only.
##
## Shaders, pipelines and the stats/config buffers are budget independent and
## survive; the fields are cleared, since resampling a reacting mixture onto a
## different topology has no meaning that would survive the mass-fraction closure
## check.
##
## Callers must stop stepping, detach render-side references and release external
## indirection uniform sets before queueing this.
func set_pool_budget(budget: int) -> void:
	if _rd == null:
		return
	initialized = false
	for stage in _sets:
		for set_rid in _sets[stage]:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
	_sets.clear()
	if _pool != null:
		_pool.free_render()
	_pool_counts_pending = false
	pool_budget = clampi(budget if budget > 0 else pool_budget, 1, atlas_slots)
	_pool = FireTilePool.new()
	# Same slot layout as init_render: without it a 4096-slot atlas got a pool
	# laid out for the default 2048 slots.
	if not _pool.init_render(_rd, _tex["activity"], pool_budget, atlas_slots):
		push_error("Fire solver could not rebuild the tile pool.")
		_pool = null
		return
	_build_uniform_sets()
	clear_fields()
	_parity = 0
	initialized = true


func _create_textures() -> void:
	var usage := TEX_USAGE
	var scratch: Dictionary = scratch_formats(_rd)

	var dims := _field_dims()

	# The advection scratch (scal_fwd, scal2_fwd) keeps the state's precision: fp16
	# measured slower there and moved the physics, see scratch_formats.
	for key in ["scal_a", "scal_b", "scal2_a", "scal2_b", "scal_fwd", "scal2_fwd"]:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, usage, dims),
			RDTextureView.new(), [])
	_tex["curl"] = _rd.texture_create(
		_make_format(scratch["four"], usage, dims), RDTextureView.new(), [])

	# Staggered MAC velocity (Fire-X Sec. 5.1, Bridson 2015): one scalar per face
	# centre instead of a vector per cell centre. One LOW face per cell, so the face
	# textures have exactly the cell extent and a tile's high faces belong to its
	# neighbour (see the face-grid note in fire_common.comp).
	for axis in 3:
		for suffix in ["_a", "_b", "_fwd"]:
			_tex["uvw"[axis] + suffix] = _rd.texture_create(
				_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, dims),
				RDTextureView.new(), [])

	# diverg is the pressure right-hand side, and fp16 there sets a floor under the
	# residual the solve can reach, so it stays fp32 with the pressure pair.
	for key in ["press_a", "press_b", "diverg"]:
		_tex[key] = _rd.texture_create(
			_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, dims),
			RDTextureView.new(), [])
	_tex["nu_t"] = _rd.texture_create(
		_make_format(scratch["one"], usage, dims), RDTextureView.new(), [])

	# P3: Liquid phase coupling (SPH ↔ fire grid). Eq. 18-25. liquid_vel is a
	# per-frame gather from the particles, so it is scratch like the rest;
	# liquid_scal carries the mass water_return has to give back exactly.
	_tex["liquid_scal"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, usage, dims),
		RDTextureView.new(), [])
	_tex["liquid_vel"] = _rd.texture_create(
		_make_format(scratch["four"], usage, dims), RDTextureView.new(), [])

	_tex["display"] = _rd.texture_create(
		_make_format(_display_format, usage, dims),
		RDTextureView.new(), [])
	_tex["display_prev"] = _rd.texture_create(
		_make_format(_display_format, usage, dims),
		RDTextureView.new(), [])
	_tex["visual_activity"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, dims),
		RDTextureView.new(), [])
	_tex["visual_activity_prev"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, dims),
		RDTextureView.new(), [])
	_tex["indir_prev"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, usage,
			FireTilePool.VTILES), RDTextureView.new(), [])

	# Tile keep signal: written by fire_display, reduced per tile by tile_mark.
	# A field like any other, so clear_fields and the atlas layout cover it.
	_tex["activity"] = _rd.texture_create(
		_make_format(RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, dims),
		RDTextureView.new(), [])

	clear_fields()


## Half-precision storage for three of the scratch fields (Phase 5). Each one is
## streamed by a stage that does almost no arithmetic on it, which is the only
## shape where halving the bytes shows up: measured -21 % on `curl` and -15 % on
## `evapapply`, -1.6 % on the substep, -18.9 MB of atlas.
##
## Only these three. Measured and rejected, with the whole per-field sweep in
## docs/fire_frame_budget_plan.md:
##
##   scal_fwd / scal2_fwd  slower, not faster — advect and maccormack are ALU and
##     latency bound (Phase 3), so the pack/unpack is not paid for by the traffic.
##     The 2 K mantissa step at flame temperature also perturbs the MacCormack
##     correction, which is a difference of two nearly equal quantities.
##   diverg  caps the pressure solve: the residual floor goes 0.0043 -> 0.0249 at
##     96 iterations, which is the convergence Phase 2 was spent buying.
##
## A shader's format qualifier must match the texture it is bound to, so the
## choice has to reach both this class and FireWater (which writes liquid_vel) as
## a define. r16f is a Vulkan *extended* storage format, unlike rgba16f, so both
## are probed and each falls back to its fp32 form on a device that refuses it.
static func scratch_formats(rd: RenderingDevice) -> Dictionary:
	var four := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var four_name := "rgba16f"
	if not rd.texture_is_format_supported_for_usage(four, TEX_USAGE):
		four = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		four_name = "rgba32f"
	var one := RenderingDevice.DATA_FORMAT_R16_SFLOAT
	var one_name := "r16f"
	if not rd.texture_is_format_supported_for_usage(one, TEX_USAGE):
		one = RenderingDevice.DATA_FORMAT_R32_SFLOAT
		one_name = "r32f"
	return {
		"four": four,
		"one": one,
		"preamble": "#define FMT_CURL %s\n#define FMT_LIQ_VEL %s\n#define FMT_NU_T %s\n"
			% [four_name, four_name, one_name],
	}


func _make_format(format: int, usage: int, dims: Vector3i) -> RDTextureFormat:
	var fmt := RDTextureFormat.new()
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = dims.x
	fmt.height = dims.y
	fmt.depth = dims.z
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
	for key in _zeroed_keys():
		_rd.texture_clear(_tex[key], Color(0, 0, 0, 0), 0, 1, 0, 1)
	_parity = 0
	_simulation_step = 0
	_topology_prepared = false
	# The atlas now holds nothing, so the pool's topology must be reset to match:
	# leaving tiles resident over cleared fields would keep them alive on stale
	# metadata until the hysteresis expired.
	if _pool != null and _pool.initialized:
		_bootstrap_pool()


## Every field that starts at zero: still air, no pressure, nothing rendered.
func _zeroed_keys() -> Array:
	var keys := ["scal2_a", "scal2_b", "scal_fwd", "scal2_fwd", "curl",
		"press_a", "press_b", "diverg", "display", "display_prev", "liquid_scal",
		"liquid_vel", "nu_t", "visual_activity", "visual_activity_prev", "activity"]
	for axis in "uvw":
		for suffix in ["_a", "_b", "_fwd"]:
			keys.append(axis + suffix)
	return keys


## Preserve the last complete display sample for render interpolation. Physics
## fields are not copied or blended. Rendering thread only, before topology
## changes its virtual-tile mapping.
func capture_interpolation_state_render() -> void:
	if not initialized:
		return
	var dims := _field_dims()
	_rd.texture_copy(_tex["display"], _tex["display_prev"], Vector3.ZERO,
		Vector3.ZERO, Vector3(dims), 0, 0, 0, 0)
	_rd.texture_copy(_tex["visual_activity"], _tex["visual_activity_prev"],
		Vector3.ZERO, Vector3.ZERO, Vector3(dims), 0, 0, 0, 0)
	if _pool != null:
		_rd.texture_copy(_pool.indir_bytes_rid(), _tex["indir_prev"], Vector3.ZERO,
			Vector3.ZERO, Vector3(FireTilePool.VTILES), 0, 0, 0, 0)


func _build_uniform_sets() -> void:
	# One binding layout for every stage (glslang keeps declared-but-unused
	# resources, so the shared header can declare them all). Variant 0/1 swaps
	# whichever pair the stage ping-pongs: the field textures for most stages,
	# the pressure pair for the Jacobi sweep.
	# Keyed by binding rather than by position: bindings 11 and 15 are the storage
	# buffers, so the image bindings are not contiguous and a positional array
	# needs a hole in it.
	var fields := {
		0: "u_a", 1: "u_b", 4: "u_fwd",
		16: "v_a", 17: "v_b", 18: "v_fwd",
		19: "w_a", 20: "w_b", 21: "w_fwd",
		2: "scal_a", 3: "scal_b", 5: "scal_fwd",
		12: "scal2_a", 13: "scal2_b", 14: "scal2_fwd",
		6: "curl", 7: "press_a", 8: "press_b", 9: "diverg", 10: "display",
		22: "liquid_scal", 23: "liquid_vel", 24: "nu_t",
	}
	fields[27] = "activity"
	fields[29] = "visual_activity"
	var fields_flipped := fields.duplicate()
	for pair in [[0, 1], [16, 17], [19, 20], [2, 3], [12, 13]]:
		_swap_binding(fields_flipped, pair[0], pair[1])

	var pressure_flipped := fields.duplicate()
	_swap_binding(pressure_flipped, 7, 8)

	# The indirection volume and the tile lists are the same for every stage and
	# every variant: only the fields ping-pong.
	var extra_buffers := [
		[11, _stats_buf], [15, _config_buf],
		[26, _pool.active_list_rid()], [28, _pool.new_list_rid()],
		[30, _pool.active_slots_rid()], [31, _pool.counts_rid()],
		[32, _coarse_val_buf], [33, _coarse_idx_buf],
	]

	for stage in _stages:
		var variants := [fields, pressure_flipped] if stage == "pressure" \
			else [fields, fields_flipped]
		var sets := []
		for variant in 2:
			var uniforms: Array[RDUniform] = []
			var order: Dictionary = variants[variant]
			for binding in order:
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.binding = binding
				u.add_id(_tex[order[binding]])
				uniforms.append(u)
			var ind := RDUniform.new()
			ind.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			ind.binding = 25
			ind.add_id(_pool.indir_rid())
			uniforms.append(ind)
			for pair in extra_buffers:
				var b := RDUniform.new()
				b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				b.binding = pair[0]
				b.add_id(pair[1])
				uniforms.append(b)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_sets[stage] = sets


static func _swap_binding(table: Dictionary, a: int, b: int) -> void:
	var tmp: String = table[a]
	table[a] = table[b]
	table[b] = tmp


# =========================================================================
#  STEP — Fire-X Algorithm 1, lines 16-22
# =========================================================================

func step_render(step_count: int, liquid_active := false) -> void:
	if not initialized:
		return
	if step_count <= 0:
		return
	_read_timings()
	_fetch_stats()
	_upload_config()
	var count := mini(step_count, max_catchup_steps)
	last_substeps = count

	_events_mutex.lock()
	var events := _events.duplicate()
	_events.clear()
	_events_mutex.unlock()

	if profiling:
		_rd.capture_timestamp("fire/start")

	if not _topology_prepared:
		prepare_topology_render()
	_topology_prepared = false

	var cl := _rd.compute_list_begin()

	for i in count:
		# Events are injected once, on the first substep of the frame.
		if i == 0:
			for e in events:
				_dispatch(cl, "inject", _parity,
					_push_constant(e["mode"], e["pos"], e["radius"], e["amount"]))
		# The whole wood pile in one dispatch per substep, reading its table from
		# the config buffer. Amount is one timestep's worth, so the fuel budget over
		# the frame is unchanged; running it every substep instead of once re-asserts
		# the pilot temperature floor each step rather than letting it decay for the
		# 1-3 substeps between injections, which is what let a gust snuff the flame
		# before the next injection could hold it.
		if _wood_any:
			_dispatch(cl, "inject", _parity, _push_constant(EVENT_WOOD,
				Vector3.ZERO, 1.0, timestep))
		_torch_mutex.lock()
		var torch_active := _torch_any
		_torch_mutex.unlock()
		if torch_active:
			_dispatch(cl, "inject", _parity, _push_constant(EVENT_TORCH,
				Vector3.ZERO, 1.0, timestep))
		_substep(cl, liquid_active)

	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("fire/end")
	# The pool counters ride their own tiny async readback every 8 frames
	# regardless of profiling: the debug overlay and the capture harness both
	# report occupancy, and a stale zero reads as "empty pool" to both.
	if _frame % 8 == 0:
		_update_pool_stats_cache()


func poll_render() -> void:
	if not initialized:
		return
	_read_timings()
	_fetch_stats()


func prepare_topology_render() -> void:
	if not initialized or _topology_prepared:
		return
	_torch_mutex.lock()
	var seed_active := _torch_seed_any
	var seed_p0 := _torch_seed_p0
	var seed_p1 := _torch_seed_p1
	var seed_radius := _torch_seed_radius
	_torch_mutex.unlock()
	if seed_active:
		var dims := sim_dims()
		var half := Vector3(dims.x, 0.0, dims.z) * cell_size * 0.5
		var tile_size := cell_size * float(FireTilePool.TILE)
		_pool.set_seed_capsule((seed_p0 + half) / tile_size,
			(seed_p1 + half) / tile_size, seed_radius / tile_size)
	else:
		_pool.clear_seed_capsule()
	_upload_config()
	_frame += 1
	_pool.reset_frame_counts(_frame)
	if profiling:
		_rd.capture_timestamp("fire/topology_start")
	var tcl := _rd.compute_list_begin()
	var budget := _pool.budget() if tile_budget <= 0 else mini(tile_budget, _pool.budget())
	_pool.record(tcl, _frame, TILE_ACTIVITY_THRESHOLD * tile_keep_scale, TILE_HOLD_FRAMES,
		TILE_DILATE_RADIUS, wind,
		float(budget) * TILE_RELIEF_FRACTION, TILE_RELIEF_MAX,
		float(_pool.budget() - budget))
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("fire/topology_end")
	var clear_list := _rd.compute_list_begin()
	_dispatch(clear_list, CLEAR_STAGE, 0,
		_push_constant(0, Vector3.ZERO, 1.0, 0.0), false)
	_rd.compute_list_end()
	_topology_prepared = true


func _substep(cl: int, liquid_active: bool) -> void:
	var pc := _push_constant(advection_mode, Vector3.ZERO, 1.0, 0.0)
	var p := _parity

	_dispatch(cl, "advect", p, pc)
	if advection_mode != ADVECTION_SEMI_LAGRANGIAN:
		_dispatch(cl, "maccormack", p, pc)
	p = 1 - p

	# 17. Buoyancy (+ vorticity confinement, Tab. 3).
	_dispatch(cl, "forces", p, pc)
	if vorticity_runs_on_step(_simulation_step):
		# Three passes now: the confinement force is a cell-centred quantity but
		# the velocity it corrects lives on faces. Computing it once per cell into
		# a scratch buffer and scattering costs one dispatch; evaluating it again
		# per face would repeat the curl-gradient stencil six times per cell.
		#
		# The boundary between vorticity and vortapply is load-bearing and these
		# two must not be merged, however cheap the recompute of the neighbouring
		# tile's force looks: the force's velocity band reads the field vortapply
		# writes, and vel_at_cell averages the faces at c and c + 1, so a workgroup
		# would read a neighbour's velocity while that neighbour updated it. The
		# merge was built and measured — it is 0.42 ms/substep faster and
		# nondeterministic, and it stops being either as soon as the race is fixed.
		# See docs/fire_frame_budget_plan.md, Phase 7.
		_dispatch(cl, "curl", p, pc)
		_dispatch(cl, "vorticity", p, pc)
		_dispatch(cl, "vortapply", p, pc)

	# 18-19. Combustion in place, then the sub-grid eddy viscosity (NON-PAPER), in
	# one dispatch: the two read and write disjoint fields, so merging them is the
	# same work with one launch and one barrier fewer. strain always runs (writes
	# ~0 when Cs = 0) so a live Cs change never leaves stale nu_t behind.
	_dispatch(cl, "comb_strain", p, pc)
	# 20. Diffusion + thermal radiation. A stencil, and it swaps parity.
	_dispatch(cl, "diffusion", p, pc)
	p = 1 - p

	# 21. Evaporation of the liquid sampled onto the grid by FireWater. Split in
	# two: the scalar budget in place on the cells, then Eq. 32 on the faces,
	# which has to be its own dispatch because it reads the mixing factor from
	# both cells either side of a face.
	if evaporation_enabled and liquid_active:
		_dispatch(cl, "evaporate", p, pc)
		_dispatch(cl, "evapapply", p, pc)

	# 22. Pressure projection.
	_dispatch(cl, "divergence", p, pc)
	# pressure_iterations is the number of dispatches, as it has always been: a
	# tile's inner sweeps ride along inside one and cost a fraction of it
	# (measured: a four-sweep pass costs 1.4 passes), so charging the budget for
	# them would trade the thing that is expensive — the halo exchange, which is
	# also the only thing that moves information between tiles — for the thing that
	# is nearly free.
	#
	# The coarse correction goes in front of each share of the passes. Smoothing
	# has to follow it, never precede it, because the correction is piecewise
	# constant and leaves a jump at every tile face.
	var cycles := maxi(pressure_coarse_cycles, 1) if _coarse_enabled() else 1
	var passes := maxi(ceili(float(pressure_iterations) / float(cycles)), 1)
	# Even, so the pressure pair ends every cycle on the same texture the coarse
	# passes and fire_project read.
	passes += passes & 1
	for cycle in cycles:
		if _coarse_enabled():
			for stage in COARSE_STAGES:
				_dispatch(cl, stage, 0, pc)
		for i in passes:
			_dispatch(cl, "pressure", i & 1, pc, i == 0)
	_dispatch(cl, "project", p, pc)
	_dispatch(cl, "display", p, pc)

	_parity = p
	_simulation_step += 1


## Relaxations per pressure dispatch, against the halo cache.
func _inner_sweeps() -> int:
	return clampi(pressure_inner_sweeps, 1, 16)


func _coarse_enabled() -> bool:
	return pressure_coarse_cycles > 0


func vorticity_runs_on_step(step: int) -> bool:
	return _effective_vorticity_strength() > 0.0 \
		and step % maxi(vorticity_interval, 1) == 0


## The confinement force is integrated over the whole interval it stands for, so
## the interval trades cost only: applied with a single dt it delivered 1/N of
## the impulse, and Reduced at interval 2 kept a quarter of the strength.
func vorticity_dt_scale() -> float:
	return float(maxi(vorticity_interval, 1))


func _effective_vorticity_strength() -> float:
	match vorticity_mode:
		VORTICITY_REDUCED:
			return vorticity_strength * 0.5
		VORTICITY_OFF:
			return 0.0
		_:
			return vorticity_strength


## Timestamps bracket stages: each mark closes the previous stage's interval, so
## a stage's cost is the gap to the next mark. The Jacobi sweep is marked only on
## its first iteration, which makes the whole loop one interval — 64 separate
## marks would blow past the driver's timestamp query pool.
func _mark(stage: String) -> void:
	if profiling:
		_rd.capture_timestamp("fire/" + stage)


func _dispatch(cl: int, stage: String, variant: int, pc: PackedByteArray, mark := true) -> void:
	if mark:
		_mark(stage)
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage][variant], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	if stage == COARSE_SOLVE_STAGE:
		# The whole coarse system lives in one workgroup's shared memory, and how
		# many of its unknowns are live is read from the pool's counter inside the
		# shader — so this is the one dispatch whose size is not the tile count.
		_rd.compute_list_dispatch(cl, 1, 1, 1)
	else:
		# One workgroup per tile, and the workgroup count lives on the GPU: the
		# pool's counters double as the dispatch args, so nothing about the fire's
		# extent ever has to come back to the CPU. The clear stage runs over the
		# tiles allocated this frame; everything else over the resident set.
		var offset := FireTilePool.NEW_ARGS_OFFSET if stage == CLEAR_STAGE \
			else FireTilePool.ACTIVE_ARGS_OFFSET
		_rd.compute_list_dispatch_indirect(cl, _pool.counts_rid(), offset)
	_rd.compute_list_add_barrier(cl)


func _push_constant(mode: int, pos: Vector3, radius: float, amount: float) -> PackedByteArray:
	var dims := sim_dims()
	var pc := PackedByteArray()
	pc.resize(64)
	pc.encode_s32(0, dims.x)
	pc.encode_s32(4, dims.y)
	pc.encode_s32(8, dims.z)
	pc.encode_s32(12, mode)
	pc.encode_float(16, cell_size)
	pc.encode_float(20, timestep)
	pc.encode_float(24, 1.0 / cell_size)
	pc.encode_float(28, smagorinsky_cs)
	pc.encode_float(32, pos.x)
	pc.encode_float(36, pos.y)
	pc.encode_float(40, pos.z)
	pc.encode_float(44, radius)
	pc.encode_float(48, amount)
	# Pressure relaxation, read by fire_pressure and fire_press_coarse only.
	pc.encode_float(52, pressure_sor_omega)
	pc.encode_float(56, float(_inner_sweeps()))
	pc.encode_float(60, pressure_coarse_omega)
	return pc


## Float index of [param block] in the Config buffer.
static func config_offset(block: String) -> int:
	var vec4s := 0
	for entry in CONFIG_LAYOUT:
		if entry[0] == block:
			return vec4s * 4
		vec4s += entry[1]
	push_error("FireGpuSolver: no config block '%s'" % block)
	return -1


static func config_vec4s() -> int:
	var vec4s := 0
	for entry in CONFIG_LAYOUT:
		vec4s += entry[1]
	return vec4s


## A float as a GLSL literal: always with a decimal point or an exponent.
static func glsl_float(x: float) -> String:
	var text := String.num_scientific(x)
	return text if text.contains(".") or text.contains("e") else text + ".0"


## Everything the solver stages share with this script as defines: the wood slot
## count, the stats word names, the Config block body and the physical constants.
static func glsl_defines() -> String:
	var lines := PackedStringArray([
		"#define MAX_LOGS %d" % MAX_LOGS,
		"#define STAT_BOUNDS %d" % STAT_BOUNDS,
		"#define STAT_DIAG %d" % STAT_DIAG,
		"#define STATS_WORDS %d" % STATS_WORDS,
		"#define STAT_SCALE %s" % glsl_float(STAT_SCALE),
		"#define STAT_MASS_SCALE %s" % glsl_float(STAT_MASS_SCALE),
		"#define R_GAS %s" % glsl_float(R_GAS),
		"#define SIGMA_SB %s" % glsl_float(SIGMA_SB),
	])
	var stats := {"STAT_MAX_T": STAT_MAX_T, "STAT_REACTION_SUM": STAT_REACTION_SUM,
		"STAT_REACTION_MAX": STAT_REACTION_MAX, "STAT_FUEL_SUM": STAT_FUEL_SUM,
		"STAT_O2_SUM": STAT_O2_SUM, "STAT_REGION_CELLS": STAT_REGION_CELLS,
		"STAT_MASS_SUM": STAT_MASS_SUM, "STAT_COLUMN_CELLS": STAT_COLUMN_CELLS,
		"STAT_MAX_DIVERGENCE": STAT_MAX_DIVERGENCE,
		"STAT_ENERGY_RESIDUAL": STAT_ENERGY_RESIDUAL,
		"STAT_ENERGY_BUDGET": STAT_ENERGY_BUDGET, "STAT_WOOD": STAT_WOOD}
	for name in stats:
		lines.append("#define %s %d" % [name, stats[name]])
	var fields := PackedStringArray()
	for entry in CONFIG_LAYOUT:
		fields.append("vec4 %s%s;" % [entry[0], "" if entry[1] == 1 else "[%d]" % entry[1]])
	lines.append("#define FIRE_CONFIG_FIELDS " + " ".join(fields))
	return "\n".join(lines) + "\n"


func _put_config(v: PackedFloat32Array, block: String, values: Array) -> void:
	var offset := config_offset(block)
	for i in values.size():
		v[offset + i] = values[i]


func _upload_config() -> void:
	var f := current_fuel()
	var q: Array = f["q"]
	var v := PackedFloat32Array()
	v.resize(config_vec4s() * 4)

	_put_config(v, "kinetics", [effective_pre_exponential(), ACTIVATION_ENERGY / R_GAS,
		f["a"], f["b"]])
	_put_config(v, "fuel", [f["dch"], f["m_f"], f["cp"], f["k"]])
	_put_config(v, "stoich", [q[0], q[1], q[2], q[3]])
	_put_config(v, "coeffs", [f["d_f"], heat_efficiency, residual_coefficient, co2_coefficient])
	_put_config(v, "thermo", [ambient_temperature, radiation_coefficient, P_AMBIENT,
		temperature_clamp])
	_put_config(v, "transport", [gravity, _effective_vorticity_strength(), drag,
		kinematic_viscosity])
	_put_config(v, "vort", [vorticity_velocity_lo, vorticity_velocity_hi,
		vorticity_temperature_lo, h2o_coefficient])
	_put_config(v, "wind", [wind.x, wind.y, wind.z, residual_dissipation])
	_put_config(v, "molar", [M_O2, M_CO2, M_H2O, M_N2])
	_put_config(v, "misc", [vorticity_dt_scale(), display_temperature, reaction_reference,
		emitter_temperature])
	_put_config(v, "liquid", [boiling_temperature, latent_heat, liquid_heat_capacity,
		droplet_density])
	# The drain moved to water_return.comp, which reads liquid_drain_rate through
	# FireWater's push constant instead — it has to run on frames where the
	# evaporation stage does not.
	_put_config(v, "liquid2", [droplet_diameter, droplet_heat_transfer, water_suppression,
		wood_shelter_rate])

	# Wood tail: the emitter/probe table, read by fire_inject (mode 5) and by
	# fire_display's temperature probes. _wood holds the positions, then the rates.
	_wood_mutex.lock()
	_put_config(v, "wood", Array(_wood.slice(0, MAX_LOGS * 4)))
	_put_config(v, "wood_rate", Array(_wood.slice(MAX_LOGS * 4)))
	_wood_mutex.unlock()
	_torch_mutex.lock()
	var torch_axis := _torch_direction * _torch_axis_length
	_put_config(v, "torch", [_torch_position.x, _torch_position.y, _torch_position.z,
		torch_nozzle_radius])
	_put_config(v, "torch2", [torch_axis.x, torch_axis.y, torch_axis.z, torch_rate])
	_put_config(v, "torch3", [torch_tip_radius, torch_temperature, torch_speed,
		torch_ignite_fraction])
	_torch_mutex.unlock()

	# Diagnostic block: flags in x, the Cp probe temperature in y.
	_put_config(v, "diag", [(1.0 if diagnostic_counters else 0.0)
		+ (2.0 if diagnostic_cp_probe else 0.0), diagnostic_probe_temperature,
		1.0 if diagnostic_evap_liquid_cp else 0.0, 1.0 if droplet_ranz_marshall else 0.0])

	var bytes := v.to_byte_array()
	if bytes == _config_cache:
		return
	_config_cache = bytes
	_rd.buffer_update(_config_buf, 0, bytes.size(), bytes)


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
	var lo := Vector3i(int(_stats[STAT_BOUNDS]), int(_stats[STAT_BOUNDS + 1]),
		int(_stats[STAT_BOUNDS + 2]))
	var hi := Vector3i(int(_stats[STAT_BOUNDS + 3]), int(_stats[STAT_BOUNDS + 4]),
		int(_stats[STAT_BOUNDS + 5]))
	_display_bounds_ready = lo.x <= hi.x and lo.y <= hi.y and lo.z <= hi.z
	_stats_mutex.unlock()


func _read_timings() -> void:
	if not profiling:
		# Stale numbers outlive the toggle otherwise: nothing else ever publishes,
		# so the last profiled frame would stay on screen forever.
		_timing_store.clear()
		return
	var count := _rd.get_captured_timestamps_count()
	if count < 2:
		return

	var acc := {}
	var start_time := 0
	var topology_start := 0
	var prev_name := ""
	var prev_time := 0
	for i in count:
		var nm := _rd.get_captured_timestamp_name(i)
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if nm == "fire/topology_start":
			topology_start = t
		elif nm == "fire/topology_end" and topology_start > 0:
			acc["topology"] = float(t - topology_start) / 1e6
		# A mark closes the interval opened by the previous one. "start" and "end"
		# only bracket the total, so they open no stage of their own.
		if prev_name.begins_with("fire/") and prev_name not in [
			"fire/start", "fire/end", "fire/topology_start", "fire/topology_end"]:
			var key: String = prev_name.substr(5)
			acc[key] = float(acc.get(key, 0.0)) + float(t - prev_time) / 1e6
		if nm == "fire/start":
			start_time = t
		elif nm == "fire/end":
			acc["total"] = float(t - start_time) / 1e6
		prev_name = nm
		prev_time = t

	if not acc.is_empty():
		_timing_store.publish(acc)


## Pool occupancy, for the verification harness and the debug overlay. Rendering
## thread only: it reads the counters back synchronously.
func read_pool_stats() -> Dictionary:
	if _pool == null or not _pool.initialized:
		return {}
	return _pool_stats_from_counts(_pool.read_counts())


func _pool_stats_from_counts(c: PackedInt32Array) -> Dictionary:
	return {
		"resident": c[FireTilePool.C_ACTIVE],
		"cores": c[FireTilePool.C_KEEP],
		"free": c[FireTilePool.C_FREE],
		"allocated_this_frame": c[FireTilePool.C_NEW],
		"exhausted": c[FireTilePool.C_EXHAUST],
		"budget": _pool.budget(),
	}


func get_debug_pool_stats() -> Dictionary:
	_pool_stats_mutex.lock()
	var copy := _pool_stats_cache.duplicate()
	_pool_stats_mutex.unlock()
	return copy


## Refreshes the overlay's pool snapshot without stalling: the synchronous
## read_counts() waited for the whole queued fire step every 8th frame. The
## snapshot lags a frame or two, like get_stats().
func _update_pool_stats_cache() -> void:
	if _pool_counts_pending or _pool == null or not _pool.initialized:
		return
	_pool_counts_pending = true
	_rd.buffer_get_data_async(_pool.counts_rid(), _on_pool_counts_ready, 0,
		FireTilePool.COUNTS_WORDS * 4)


func _on_pool_counts_ready(bytes: PackedByteArray) -> void:
	_pool_counts_pending = false
	if _pool == null or not _pool.initialized or bytes.size() < FireTilePool.COUNTS_WORDS * 4:
		return
	var c := PackedInt32Array()
	c.resize(FireTilePool.COUNTS_WORDS)
	for i in FireTilePool.COUNTS_WORDS:
		c[i] = bytes.decode_u32(i * 4)
	var snapshot := _pool_stats_from_counts(c)
	_pool_stats_mutex.lock()
	_pool_stats_cache = snapshot
	_pool_stats_mutex.unlock()


func free_render() -> void:
	if _rd == null:
		return
	initialized = false
	# A readback of a buffer about to be freed may never answer.
	_pool_counts_pending = false
	# The stage sets have to go first. They bind the pool's indirection volume and
	# tile lists, and freeing a resource in Godot also drops every uniform set that
	# references it — so tearing the pool down first would invalidate these behind
	# our back and every free below would report an invalid ID.
	for stage in _sets:
		for set_rid in _sets[stage]:
			if set_rid.is_valid():
				_rd.free_rid(set_rid)
	_sets.clear()
	if _pool != null:
		_pool.free_render()
		_pool = null
	for buf in [_stats_buf, _config_buf, _coarse_val_buf, _coarse_idx_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_stats_buf = RID()
	_config_buf = RID()
	_coarse_val_buf = RID()
	_coarse_idx_buf = RID()
	_config_cache.clear()
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
