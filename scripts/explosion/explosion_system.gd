class_name ExplosionSystem extends Node3D
## Owns a gas-only FireGpuSolver with the detonation term and runs charges through it.
##
## detonate() queues; each frame at most one charge is released into a free slot of
## the solver's blast table. A slot drives the solver for pulse_duration_s of
## simulated time with a linearly decaying rate, then frees. The host must assign
## [member config] before [method start] and draws the solver with its own presentation.
##
##     var system := ExplosionSystem.new()
##     system.config = preload("res://resources/explosion/presets/range.tres")
##     add_child(system)
##     system.start()
##     system.detonate(Vector3(0, 1, 0), preload("res://resources/explosion/presets/fireball_charge.tres"))

signal detonated(origin: Vector3, charge: ExplosionCharge, carry_velocity: Vector3)
signal blast(origin: Vector3, radius_m: float, speed_mps: float)

var config: ExplosionConfig
var solver: FireGpuSolver
## Negative follows the frame delta; a capture harness sets a fixed step of simulated seconds, which bypasses Engine.time_scale (bodies still follow it).
var fixed_delta_s := -1.0
## Curl-noise strength the solver ramps in after each pulse; starts at the config value, a capture harness may override it.
var turbulence_strength := 0.0
## Multiplies the shock speed handed to rigid bodies by [signal blast]; read when a charge is released.
var blast_force_scale := 1.0

const AFTERWIND_RAMP_IN_S := 1.5
const AFTERWIND_CORE_M := 40.0

var _pending: Array[Dictionary] = []
var _delayed: Array[Dictionary] = []
var _slots: Array[Dictionary] = []
var _started := false
var _vorticity_ramp := 0.0
var _exhaust_warned := false


func _init() -> void:
	_slots.resize(FireGpuSolver.MAX_BLASTS)


func start() -> void:
	assert(config != null, "ExplosionSystem: config required")
	var error := config.validate()
	if error != "":
		push_error("Explosion config: %s" % error)
		return
	solver = FireGpuSolver.new()
	solver.blast_enabled = true
	solver.atlas_slots = config.pool_slots
	solver.pool_budget = config.pool_slots
	solver.tile_keep_scale = config.tile_keep_scale
	solver.cell_size = config.cell_size_m
	solver.set_simulation_hz(config.simulation_hz)
	solver.max_catchup_steps = config.max_substeps_per_frame
	solver.topology_interval_steps = config.topology_interval_steps
	solver.blast_velocity_clamp_mps = config.velocity_clamp_mps
	solver.blast_keep_speed_mps = config.keep_speed_mps
	solver.vorticity_strength = 0.0
	if config.vorticity_strength <= 0.0:
		solver.vorticity_mode = FireGpuSolver.VORTICITY_OFF
	turbulence_strength = config.turbulence_strength
	solver.blast_turbulence_wavelength_m = config.turbulence_wavelength_m
	solver.blast_turbulence_band_k = Vector2(config.turbulence_band_lo_k, config.turbulence_band_hi_k)
	solver.blast_turbulence_evolution_s = config.turbulence_evolution_s
	solver.blast_turbulence_octaves = config.turbulence_octaves()
	solver.blast_rest_period_s = config.billow.reset_s if config.billow.rest_active() else 0.0
	solver.radiation_coefficient = config.radiation_coefficient
	solver.blast_soot_half_life_s = config.soot_half_life_s
	solver.blast_soot_keep = config.soot_keep_fraction
	solver.blast_lid_base_m = config.lid_base_m
	solver.blast_lid_thickness_m = config.lid_thickness_m
	solver.blast_lid_damping_per_s = config.lid_damping_per_s
	_started = true
	RenderingServer.call_on_render_thread(solver.init_render)


func stop() -> void:
	if not _started:
		return
	_started = false
	_pending.clear()
	_delayed.clear()
	_slots.fill({})
	solver.set_afterwind(Vector4.ZERO, Vector4.ZERO)
	RenderingServer.call_on_render_thread(solver.free_render)


## Peak speed of the flow the source sphere injects, which the solver's velocity clamp must not cut.
func peak_source_mps(charge: ExplosionCharge) -> float:
	return charge.divergence_per_s * charge.radius_m / 3.0


## Speed the clamp leaves above the source flow of [param charge] for a carried impulse.
func carry_headroom_mps(charge: ExplosionCharge) -> float:
	return maxf(config.velocity_clamp_mps - peak_source_mps(charge), 0.0)


## "" when [param charge] and its companions may run on this config, else the reason they may not.
func refusal(charge: ExplosionCharge) -> String:
	var error := charge.validate()
	if error != "":
		return error
	if peak_source_mps(charge) > config.velocity_clamp_mps:
		return "peak source speed %.1f m/s exceeds the %.1f m/s velocity clamp" % [
			peak_source_mps(charge), config.velocity_clamp_mps]
	if charge.carry_fraction > 0.0 and carry_headroom_mps(charge) <= 0.0:
		return "carry_fraction needs headroom under the %.1f m/s velocity clamp" % config.velocity_clamp_mps
	if charge.companion != null:
		return refusal(charge.companion)
	return ""


## Largest factor that can multiply the radius of [param charge] and its companions and still pass [method refusal].
func max_charge_scale(charge: ExplosionCharge) -> float:
	var limit := config.velocity_clamp_mps / peak_source_mps(charge)
	if charge.companion != null:
		limit = minf(limit, max_charge_scale(charge.companion))
	return limit


func detonate(origin: Vector3, charge: ExplosionCharge, carry_velocity := Vector3.ZERO) -> void:
	var error := refusal(charge)
	if error != "":
		push_error("Explosion charge refused: %s" % error)
		return
	_pending.append({origin = origin, charge = charge, carry_velocity = carry_velocity})


func reset() -> void:
	_pending.clear()
	_delayed.clear()
	_slots.fill({})
	if solver != null:
		solver.set_afterwind(Vector4.ZERO, Vector4.ZERO)
	if not _started:
		return
	solver.reset_clock()
	_vorticity_ramp = 0.0
	clear_smoke()


## Empties the gas fields only: queued detonations and running pulses carry on.
func clear_smoke() -> void:
	if _started:
		RenderingServer.call_on_render_thread(solver.clear_fields)


## Seconds of simulation this frame advances: the capture's fixed step when set, else [param delta].
func step_s(delta: float) -> float:
	return fixed_delta_s if fixed_delta_s >= 0.0 else delta


## Shock speed of [param charge] as the bodies and the visible rings feel it.
func blast_speed_mps(charge: ExplosionCharge) -> float:
	return charge.blast_speed_mps * blast_force_scale


func _process(delta: float) -> void:
	if not _started or not solver.initialized:
		return
	var steps := solver.schedule_steps(step_s(delta))
	advance(float(steps) * solver.timestep)
	_warn_on_exhaustion()
	RenderingServer.call_on_render_thread(ExplosionSystem._step_render.bind(solver, steps))


## The solver's cached pool counters lag a frame or two; the tile pool drops requests silently when full.
func _warn_on_exhaustion() -> void:
	if _exhaust_warned:
		return
	var exhausted := int(solver.get_debug_pool_stats().get("exhausted", 0))
	if exhausted > 0:
		_exhaust_warned = true
		push_warning("Explosion tile pool exhausted (%d requests dropped): the fireball is clipped" % exhausted)


func advance(sim_dt: float) -> void:
	_tick_delayed(sim_dt)
	_release_next()
	_upload_blasts(sim_dt)


func pending_count() -> int:
	return _pending.size()


func delayed_count() -> int:
	return _delayed.size()


func _tick_delayed(sim_dt: float) -> void:
	for i in range(_delayed.size() - 1, -1, -1):
		_delayed[i].wait_s -= sim_dt
		if _delayed[i].wait_s <= 0.0:
			_pending.push_front({origin = _delayed[i].origin, charge = _delayed[i].charge})
			_delayed.remove_at(i)


func _release_next() -> void:
	if _pending.is_empty():
		return
	var slot := _slots.find({})
	if slot < 0:
		return
	var entry: Dictionary = _pending.pop_front()
	var charge: ExplosionCharge = entry.charge
	var origin: Vector3 = entry.origin
	_slots[slot] = {origin = origin, charge = charge, age = 0.0, carry = carry_impulse(charge, entry.get("carry_velocity", Vector3.ZERO))}
	solver.push_event(FireGpuSolver.EVENT_BLAST, origin, charge.radius_m, float(slot))
	if charge.companion != null:
		var companion_origin := Vector3(origin.x, -charge.companion.sink_m, origin.z)
		if charge.companion.delay_s > 0.0:
			_delayed.append({origin = companion_origin, charge = charge.companion, wait_s = charge.companion.delay_s})
		else:
			_pending.push_front({origin = companion_origin, charge = charge.companion})
	if charge.continuous:
		return
	detonated.emit(origin, charge, _slots[slot].carry)
	blast.emit(origin, charge.blast_radius_m, blast_speed_mps(charge))


## Horizontal share of [param velocity] the flow receives, within the clamp headroom; zero for a continuous charge.
func carry_impulse(charge: ExplosionCharge, velocity: Vector3) -> Vector3:
	if charge.continuous:
		return Vector3.ZERO
	var impulse := Vector3(velocity.x, 0.0, velocity.z) * charge.carry_fraction
	return impulse.limit_length(carry_headroom_mps(charge))


## Rates are uploaded at the slot's current age, then the age advances.
func _upload_blasts(sim_dt: float) -> void:
	var table := PackedVector4Array()
	var rate := PackedVector4Array()
	var carry := PackedVector4Array()
	table.resize(_slots.size())
	rate.resize(_slots.size())
	carry.resize(_slots.size())
	for i in _slots.size():
		if _slots[i].is_empty():
			continue
		var charge: ExplosionCharge = _slots[i].charge
		var origin: Vector3 = _slots[i].origin
		var age: float = _slots[i].age
		table[i] = Vector4(origin.x, origin.y, origin.z, charge.radius_m)
		var impulse: Vector3 = _slots[i].carry
		carry[i] = Vector4(impulse.x, impulse.y, impulse.z, 0.0)
		rate[i] = Vector4(charge.divergence_per_s * (1.0 - age / charge.pulse_duration_s),
			charge.temperature_k, charge.fuel_fraction, charge.soot_fraction)
		if charge.continuous and age > 0.0 and sim_dt > 0.0:
			solver.push_event(FireGpuSolver.EVENT_BLAST, origin, charge.radius_m, float(i))
		_slots[i].age = age + sim_dt
		if age + sim_dt >= charge.pulse_duration_s:
			_slots[i] = {}
	solver.set_blasts(table, rate, carry)
	_push_afterwind()
	_ramp_vorticity(sim_dt)


## The afterwind envelope of a charge [param age_s] into its pulse: ramps in, holds, ramps out; 0 outside the pulse.
static func afterwind_envelope(age_s: float, pulse_s: float) -> float:
	if age_s < 0.0 or age_s >= pulse_s:
		return 0.0
	var ramp_out_s := 0.75 * pulse_s
	return smoothstep(0.0, AFTERWIND_RAMP_IN_S, age_s) * (1.0 - smoothstep(pulse_s - ramp_out_s, pulse_s, age_s))


## CPU mirror of afterwind_dv in fire_forces.comp: the change of a horizontal face speed [param face_speed] at [param p] over [param dt].
static func afterwind_dv(a: Vector4, b: Vector4, p: Vector3, axis: int, face_speed: float, dt: float) -> float:
	var d := Vector2(p.x - a.x, p.z - a.y)
	var r := d.length()
	if r < 1e-3:
		return 0.0
	var mask := (1.0 - smoothstep(b.x, b.x + b.y, r)) * (1.0 - smoothstep(0.5 * b.z, b.z, p.y))
	var target := -a.z * (d.x if axis == 0 else d.y) / r * smoothstep(0.0, b.w, r)
	if target == 0.0:
		return 0.0
	var dv := (target - face_speed) * (1.0 - exp(-dt / a.w)) * mask
	return minf(dv, 0.0) if target < 0.0 else maxf(dv, 0.0)


## One afterwind at a time: the first running slot whose charge has one; speed 0 otherwise.
func _push_afterwind() -> void:
	for slot in _slots:
		if slot.is_empty():
			continue
		var charge: ExplosionCharge = slot.charge
		if charge.afterwind_mps <= 0.0:
			continue
		var speed := charge.afterwind_mps * afterwind_envelope(slot.age, charge.pulse_duration_s)
		solver.set_afterwind(
			Vector4(slot.origin.x, slot.origin.z, speed, charge.afterwind_tau_s),
			Vector4(charge.afterwind_radius_m, 0.25 * charge.afterwind_radius_m, charge.afterwind_height_m, AFTERWIND_CORE_M))
		return
	solver.set_afterwind(Vector4.ZERO, Vector4.ZERO)


## Confinement stays off while a pulse drives the flow, then ramps to the configured strength.
func _ramp_vorticity(sim_dt: float) -> void:
	var pulsing := not _pending.is_empty() or not _delayed.is_empty()
	for slot in _slots:
		if not slot.is_empty() and not slot.charge.continuous:
			pulsing = true
	if pulsing:
		_vorticity_ramp = 0.0
	else:
		_vorticity_ramp = minf(_vorticity_ramp + sim_dt / ExplosionConfig.VORTICITY_RAMP_S, 1.0)
	solver.vorticity_strength = config.vorticity_strength * _vorticity_ramp
	solver.blast_turbulence_strength = turbulence_strength * _vorticity_ramp


static func _step_render(target: FireGpuSolver, steps: int) -> void:
	if steps > 0:
		target.prepare_topology_render()
	else:
		target.poll_render()
	target.step_render(steps)


func _exit_tree() -> void:
	stop()
