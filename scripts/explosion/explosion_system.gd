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

signal detonated(origin: Vector3, charge: ExplosionCharge)
signal blast(origin: Vector3, radius_m: float, speed_mps: float)

var config: ExplosionConfig
var solver: FireGpuSolver
## Negative follows the frame delta; a capture harness sets a fixed step of simulated seconds, which bypasses Engine.time_scale (bodies still follow it).
var fixed_delta_s := -1.0
## Curl-noise strength the solver ramps in after each pulse; starts at the config value, a capture harness may override it.
var turbulence_strength := 0.0
## Multiplies the shock speed handed to rigid bodies by [signal blast]; read when a charge is released.
var blast_force_scale := 1.0

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
	solver.residual_dissipation = config.residual_dissipation
	_started = true
	RenderingServer.call_on_render_thread(solver.init_render)


func stop() -> void:
	if not _started:
		return
	_started = false
	_pending.clear()
	_slots.fill({})
	RenderingServer.call_on_render_thread(solver.free_render)


## Peak speed of the flow the source sphere injects, which the solver's velocity clamp must not cut.
func peak_source_mps(charge: ExplosionCharge) -> float:
	return charge.divergence_per_s * charge.radius_m / 3.0


## "" when [param charge] and its companions may run on this config, else the reason they may not.
func refusal(charge: ExplosionCharge) -> String:
	var error := charge.validate()
	if error != "":
		return error
	if peak_source_mps(charge) > config.velocity_clamp_mps:
		return "peak source speed %.1f m/s exceeds the %.1f m/s velocity clamp" % [
			peak_source_mps(charge), config.velocity_clamp_mps]
	if charge.companion != null:
		return refusal(charge.companion)
	return ""


## Largest factor that can multiply the radius of [param charge] and its companions and still pass [method refusal].
func max_charge_scale(charge: ExplosionCharge) -> float:
	var limit := config.velocity_clamp_mps / peak_source_mps(charge)
	if charge.companion != null:
		limit = minf(limit, max_charge_scale(charge.companion))
	return limit


func detonate(origin: Vector3, charge: ExplosionCharge) -> void:
	var error := refusal(charge)
	if error != "":
		push_error("Explosion charge refused: %s" % error)
		return
	_pending.append({origin = origin, charge = charge})


func reset() -> void:
	_pending.clear()
	_slots.fill({})
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
	_slots[slot] = {origin = origin, charge = charge, age = 0.0}
	solver.push_event(FireGpuSolver.EVENT_BLAST, origin, charge.radius_m, float(slot))
	if charge.companion != null:
		_pending.push_front({origin = Vector3(origin.x, -charge.companion.sink_m, origin.z), charge = charge.companion})
	if charge.continuous:
		return
	detonated.emit(origin, charge)
	blast.emit(origin, charge.blast_radius_m, blast_speed_mps(charge))


## Rates are uploaded at the slot's current age, then the age advances.
func _upload_blasts(sim_dt: float) -> void:
	var table := PackedVector4Array()
	var rate := PackedVector4Array()
	table.resize(_slots.size())
	rate.resize(_slots.size())
	for i in _slots.size():
		if _slots[i].is_empty():
			continue
		var charge: ExplosionCharge = _slots[i].charge
		var origin: Vector3 = _slots[i].origin
		var age: float = _slots[i].age
		table[i] = Vector4(origin.x, origin.y, origin.z, charge.radius_m)
		rate[i] = Vector4(charge.divergence_per_s * (1.0 - age / charge.pulse_duration_s),
			charge.temperature_k, charge.fuel_fraction, charge.soot_fraction)
		if charge.continuous and age > 0.0 and sim_dt > 0.0:
			solver.push_event(FireGpuSolver.EVENT_BLAST, origin, charge.radius_m, float(i))
		_slots[i].age = age + sim_dt
		if age + sim_dt >= charge.pulse_duration_s:
			_slots[i] = {}
	solver.set_blasts(table, rate)
	_ramp_vorticity(sim_dt)


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
