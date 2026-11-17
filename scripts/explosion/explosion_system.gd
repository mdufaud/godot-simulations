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
	solver.tile_budget = config.soft_budget_tiles
	solver.blast_relief_max = config.relief_max
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
	_slots.fill({})
	solver.set_afterwind(Vector4.ZERO, Vector4.ZERO)
	RenderingServer.call_on_render_thread(solver.free_render)


## Fraction of the source sphere's volume the divergence source of one unit rate produces (calibrated against hot_r, see tests/probe.gd explosion_expand).
const KERNEL_SOURCE_SHARE := 0.23
const KERNEL_EXPONENT := 0.4
## A zero rate marks a slot inactive to the tile seeding, so a finished kernel idles at a rate too small to move the flow.
const KERNEL_IDLE_RATE_PER_S := 1e-6


## Radius of the source sphere of [param charge] [param age_s] into its pulse.
static func kernel_radius_m(charge: ExplosionCharge, age_s: float) -> float:
	if not charge.grows():
		return charge.radius_m
	return charge.radius_m * (1.0 + (charge.growth_ratio - 1.0) * kernel_progress(charge, age_s))


## Fraction of the growth done [param age_s] into the pulse: fast at first, slow at the end.
static func kernel_progress(charge: ExplosionCharge, age_s: float) -> float:
	var age := clampf(age_s, 0.0, charge.formation_s)
	var offset_s := charge.formation_offset_s
	if offset_s <= 0.0:
		return pow(age / charge.formation_s, KERNEL_EXPONENT)
	var base := pow(offset_s, KERNEL_EXPONENT)
	return (pow(age + offset_s, KERNEL_EXPONENT) - base) / (pow(charge.formation_s + offset_s, KERNEL_EXPONENT) - base)


static func sphere_volume_m3(radius_m: float) -> float:
	return 4.0 / 3.0 * PI * radius_m * radius_m * radius_m


## Divergence rate [1/s] that grows the source sphere from its radius at [param age_s] to its radius [param dt_s] later.
static func kernel_rate_per_s(charge: ExplosionCharge, age_s: float, dt_s: float) -> float:
	var grown := sphere_volume_m3(kernel_radius_m(charge, age_s + dt_s)) - sphere_volume_m3(kernel_radius_m(charge, age_s))
	return grown / (KERNEL_SOURCE_SHARE * sphere_volume_m3(kernel_radius_m(charge, age_s)) * dt_s)


## Simulated seconds of dusting that deposit the soot_fraction of a front ring charge: it is per this much simulated time, not per frame.
const FRONT_RING_REFERENCE_DT_S := 1.0 / 15.0


## Radius of the centre line of the front ring of [param charge], [param age_s] after its release; [param front] is (speed [m/s], start radius [m]) of the charge that released it.
static func front_ring_radius_m(charge: ExplosionCharge, front: Vector2, age_s: float) -> float:
	return minf(front.y + front.x * age_s, charge.radius_m)


## Seconds the front ring of [param charge] rides the front before it reaches its cap.
static func front_ring_duration_s(charge: ExplosionCharge, front: Vector2) -> float:
	return maxf(charge.radius_m - front.y, 0.0) / maxf(front.x, 1e-3)


## Farthest distance from the ring's centre of a cell the ring can still reach.
static func front_ring_reach_m(charge: ExplosionCharge, front: Vector2, age_s: float) -> float:
	return front_ring_radius_m(charge, front, age_s) + charge.front_ring_width_m + charge.front_ring_height_m


## Where the centre of a growing charge released at [param origin] is [param age_s] into its pulse: it keeps [param carry] [m/s] and brakes with half the formation time.
static func kernel_centre(charge: ExplosionCharge, origin: Vector3, carry: Vector3, age_s: float) -> Vector3:
	var tau_s := 0.5 * charge.formation_s
	return origin + carry * tau_s * (1.0 - exp(-age_s / tau_s))


## Peak speed over shell speed of the flow the smoothstep-falloff source sphere drives: the flow peaks inside the sphere, where the velocity clamp cuts it into a box.
static func kernel_peak_over_shell() -> float:
	var best := 0.0
	for i in 1001:
		var x := float(i) / 1000.0
		best = maxf(best, x / 3.0 - 0.6 * x * x * x + x * x * x * x / 3.0)
	return best * 15.0


## Mean shell speed of the first solver step of a growing [param charge].
func kernel_shell_mps(charge: ExplosionCharge) -> float:
	var step_s := 1.0 / float(config.simulation_hz)
	return (kernel_radius_m(charge, step_s) - charge.radius_m) / step_s


## Peak speed of the flow the source sphere injects, which the solver's velocity clamp must not cut: for a growing charge the interior peak of its first solver step.
func peak_source_mps(charge: ExplosionCharge) -> float:
	if charge.grows():
		return kernel_shell_mps(charge) * kernel_peak_over_shell()
	return charge.divergence_per_s * charge.radius_m / 3.0


const FORMATION_OFFSET_MAX_S := 5.0


## [param charge], or a copy whose growth law starts far enough up its curve for the source flow to stay under the velocity clamp.
func settled_charge(charge: ExplosionCharge) -> ExplosionCharge:
	if not charge.grows() or peak_source_mps(charge) <= config.velocity_clamp_mps:
		return charge
	var settled := charge.duplicate() as ExplosionCharge
	settled.formation_offset_s = FORMATION_OFFSET_MAX_S
	if peak_source_mps(settled) > config.velocity_clamp_mps:
		return charge
	var lo := charge.formation_offset_s
	var hi := FORMATION_OFFSET_MAX_S
	for i in 40:
		settled.formation_offset_s = 0.5 * (lo + hi)
		if peak_source_mps(settled) > config.velocity_clamp_mps:
			lo = settled.formation_offset_s
		else:
			hi = settled.formation_offset_s
	settled.formation_offset_s = hi
	return settled


## Slowest source flow [param charge] can be settled to.
func slowest_peak_mps(charge: ExplosionCharge) -> float:
	if not charge.grows():
		return peak_source_mps(charge)
	var slow := charge.duplicate() as ExplosionCharge
	slow.formation_offset_s = FORMATION_OFFSET_MAX_S
	return peak_source_mps(slow)


## Speed the clamp leaves above the source flow of [param charge] for a carried impulse.
func carry_headroom_mps(charge: ExplosionCharge) -> float:
	return maxf(config.velocity_clamp_mps - peak_source_mps(charge), 0.0)


## "" when [param charge] and its companions may run on this config, else the reason they may not.
func refusal(charge: ExplosionCharge) -> String:
	return _refusal_link(charge, null)


func _refusal_link(charge: ExplosionCharge, parent: ExplosionCharge) -> String:
	var error := charge.validate()
	if error != "":
		return error
	if charge.has_front_ring():
		if parent == null:
			return "a front ring needs the charge that releases it: it has no front to ride"
		var front := Vector2(blast_speed_mps(parent), parent.final_radius_m())
		var ride_s := front_ring_duration_s(charge, front)
		if ride_s > charge.pulse_duration_s:
			return "the front ring needs %.1f s to reach its cap, longer than its %.1f s pulse" % [ride_s, charge.pulse_duration_s]
	var peak := peak_source_mps(settled_charge(charge))
	if peak > config.velocity_clamp_mps:
		return "peak source speed %.1f m/s exceeds the %.1f m/s velocity clamp" % [peak, config.velocity_clamp_mps]
	if charge.carry_fraction > 0.0 and not charge.grows() and carry_headroom_mps(charge) <= 0.0:
		return "carry_fraction needs headroom under the %.1f m/s velocity clamp" % config.velocity_clamp_mps
	if charge.companion != null:
		return _refusal_link(charge.companion, charge)
	return ""


## Largest factor that can multiply the radius of [param charge] and its companions and still pass [method refusal].
func max_charge_scale(charge: ExplosionCharge) -> float:
	var limit := INF
	var parent: ExplosionCharge = null
	var link := charge
	for i in ExplosionCharge.MAX_COMPANIONS + 1:
		if link == null:
			break
		limit = minf(limit, config.velocity_clamp_mps / slowest_peak_mps(link))
		if parent != null and link.has_front_ring():
			var span_m := link.radius_m - parent.final_radius_m()
			if span_m > 0.0:
				limit = minf(limit, link.pulse_duration_s * blast_speed_mps(parent) / span_m)
		parent = link
		link = link.companion
	return limit


func detonate(origin: Vector3, charge: ExplosionCharge, carry_velocity := Vector3.ZERO) -> void:
	var error := refusal(charge)
	if error != "":
		push_error("Explosion charge refused: %s" % error)
		return
	_pending.append({origin = origin, charge = charge, carry_velocity = carry_velocity})


func reset() -> void:
	_pending.clear()
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
	_release_next()
	_upload_blasts(sim_dt)


func pending_count() -> int:
	return _pending.size()


func _release_next() -> void:
	if _pending.is_empty():
		return
	var slot := _slots.find({})
	if slot < 0:
		return
	var entry: Dictionary = _pending.pop_front()
	var charge: ExplosionCharge = entry.charge
	var origin: Vector3 = entry.origin
	var front: Vector2 = entry.get("front", Vector2.ZERO)
	_slots[slot] = {origin = origin, charge = settled_charge(charge), age = 0.0, front = front, carry = carry_impulse(charge, entry.get("carry_velocity", Vector3.ZERO))}
	solver.push_event(FireGpuSolver.EVENT_BLAST, origin, front_ring_reach_m(charge, front, 0.0) if charge.has_front_ring() else charge.radius_m, float(slot))
	if charge.companion != null:
		var companion_origin := Vector3(origin.x, -charge.companion.sink_m, origin.z)
		var companion_front := Vector2(blast_speed_mps(charge), charge.final_radius_m())
		_pending.push_front({origin = companion_origin, charge = charge.companion, front = companion_front})
	if charge.continuous:
		return
	detonated.emit(origin, charge, _slots[slot].carry)
	blast.emit(origin, charge.blast_radius_m, blast_speed_mps(charge))


## Horizontal share of [param velocity] a charge keeps: the speed its growing sphere moves with, else an impulse the flow receives within the clamp headroom; zero for a continuous charge.
func carry_impulse(charge: ExplosionCharge, velocity: Vector3) -> Vector3:
	if charge.continuous:
		return Vector3.ZERO
	var impulse := Vector3(velocity.x, 0.0, velocity.z) * charge.carry_fraction
	if charge.grows():
		return impulse.limit_length(config.velocity_clamp_mps)
	return impulse.limit_length(carry_headroom_mps(charge))


## Rates are uploaded at the slot's current age, then the age advances.
func _upload_blasts(sim_dt: float) -> void:
	var table := PackedVector4Array()
	var rate := PackedVector4Array()
	var carry := PackedVector4Array()
	var ring := PackedVector4Array()
	table.resize(_slots.size())
	rate.resize(_slots.size())
	carry.resize(_slots.size())
	ring.resize(_slots.size())
	for i in _slots.size():
		if _slots[i].is_empty():
			continue
		var charge: ExplosionCharge = _slots[i].charge
		var origin: Vector3 = _slots[i].origin
		var age: float = _slots[i].age
		var impulse: Vector3 = _slots[i].carry
		var source_rate := charge.divergence_per_s * (1.0 - age / charge.pulse_duration_s)
		if charge.grows():
			origin = kernel_centre(charge, origin, impulse, age)
			impulse = Vector3.ZERO
			source_rate = maxf(kernel_rate_per_s(charge, age, maxf(sim_dt, 1.0 / float(config.simulation_hz))), KERNEL_IDLE_RATE_PER_S)
		var radius_m := kernel_radius_m(charge, age)
		var soot_fraction := charge.soot_fraction
		var ring_reach_m := 0.0
		if charge.has_front_ring():
			var front: Vector2 = _slots[i].front
			var ring_m := front_ring_radius_m(charge, front, age)
			ring[i] = Vector4(ring_m, charge.front_ring_width_m, charge.front_ring_height_m, 0.0)
			radius_m = ring_m + charge.front_ring_width_m
			if age < front_ring_duration_s(charge, front):
				ring_reach_m = front_ring_reach_m(charge, front, age)
				soot_fraction *= minf(sim_dt / FRONT_RING_REFERENCE_DT_S, 1.0)
				impulse = Vector3(0.0, charge.front_ring_lift_mps * minf(front.x * sim_dt / charge.front_ring_width_m, 1.0), 0.0)
			else:
				source_rate = 0.0
		table[i] = Vector4(origin.x, origin.y, origin.z, radius_m)
		carry[i] = Vector4(impulse.x, impulse.y, impulse.z, 0.0)
		var temperature_k := charge.temperature_k
		if charge.onset_s > 0.0:
			var onset := pow(clampf(age / charge.onset_s, 0.0, 1.0), 3.0)
			temperature_k = solver.ambient_temperature + (temperature_k - solver.ambient_temperature) * onset
			soot_fraction *= onset
		rate[i] = Vector4(source_rate, temperature_k, charge.fuel_fraction, soot_fraction)
		if charge.grows() and _slots[i].carry != Vector3.ZERO and age > 0.0 and age < charge.formation_s and sim_dt > 0.0:
			solver.push_event(FireGpuSolver.EVENT_BLAST, origin, radius_m, float(i) + FireGpuSolver.BLAST_REPAINT_FLAG)
		if charge.continuous and age > 0.0 and sim_dt > 0.0 and (not charge.has_front_ring() or ring_reach_m > 0.0):
			solver.push_event(FireGpuSolver.EVENT_BLAST, origin, ring_reach_m if charge.has_front_ring() else charge.radius_m, float(i))
		_slots[i].age = age + sim_dt
		if age + sim_dt >= charge.pulse_duration_s:
			_slots[i] = {}
	solver.set_blasts(table, rate, carry, ring)
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
		var speed := charge.afterwind_mps * afterwind_envelope(slot.age - charge.afterwind_delay_s, charge.pulse_duration_s - charge.afterwind_delay_s)
		solver.set_afterwind(
			Vector4(slot.origin.x, slot.origin.z, speed, charge.afterwind_tau_s),
			Vector4(charge.afterwind_radius_m, 0.25 * charge.afterwind_radius_m, charge.afterwind_height_m, AFTERWIND_CORE_M))
		return
	solver.set_afterwind(Vector4.ZERO, Vector4.ZERO)


## Confinement stays off while a pulse drives the flow, then ramps to the configured strength.
func _ramp_vorticity(sim_dt: float) -> void:
	var pulsing := not _pending.is_empty()
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
