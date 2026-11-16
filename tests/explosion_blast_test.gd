extends "res://tests/test_case.gd"
## No GPU: the queue is driven through a solver that was never initialised.

const RANGE_CONFIG := preload("res://resources/explosion/presets/range.tres")
const FIREBALL_RANGE_CONFIG := preload("res://resources/explosion/presets/fireball_range.tres")
const BARREL_CHARGE := preload("res://resources/explosion/presets/barrel_charge.tres")
const FIREBALL_CHARGE := preload("res://resources/explosion/presets/fireball_charge.tres")


func _initialize() -> void:
	await process_frame
	_test_impulse_law()
	_test_barrel_fuse()
	_test_validation()
	_test_queue()
	_finish("explosion_blast")


func _test_impulse_law() -> void:
	var radius := 6.0
	var speed := 14.0
	var mass := 40.0
	var at_zero := ExplosiveBarrel.blast_speed_share(Vector3.ZERO, radius, speed)
	_check(is_equal_approx(at_zero, speed), "share at the centre is the full speed")
	var half := ExplosiveBarrel.blast_speed_share(Vector3(3.0, 0.0, 0.0), radius, speed)
	_check(is_equal_approx(half, speed * 0.5), "share halves at half the radius")
	_check(ExplosiveBarrel.blast_speed_share(Vector3(6.0, 0.0, 0.0), radius, speed) == 0.0,
		"share is 0 at the radius")
	_check(ExplosiveBarrel.blast_speed_share(Vector3(9.0, 0.0, 0.0), radius, speed) == 0.0,
		"share stays 0 beyond the radius")
	_check(ExplosiveBarrel.blast_impulse(Vector3(7.0, 0.0, 0.0), radius, speed, mass) == Vector3.ZERO,
		"no impulse beyond the radius")
	var offset := Vector3(2.0, 0.0, 0.0)
	var impulse := ExplosiveBarrel.blast_impulse(offset, radius, speed, mass)
	_check(is_equal_approx(impulse.length(), mass * speed * (1.0 - 2.0 / radius)),
		"impulse magnitude is mass x speed x (1 - d/R)")
	_check(impulse.x > 0.0 and is_zero_approx(impulse.z), "impulse points away from the origin")
	_check(impulse.y > 0.0 and impulse.y < impulse.x, "upward bias is positive and small")
	var double_mass := ExplosiveBarrel.blast_impulse(offset, radius, speed, mass * 2.0)
	_check(double_mass.is_equal_approx(impulse * 2.0), "impulse scales with mass")
	var behind := ExplosiveBarrel.blast_impulse(-offset, radius, speed, mass)
	_check(behind.x < 0.0, "impulse follows the direction from the origin")
	var on_top := ExplosiveBarrel.blast_impulse(Vector3.ZERO, radius, speed, mass)
	_check(is_equal_approx(on_top.length(), mass * speed), "centred blast still has a finite impulse")


func _test_barrel_fuse() -> void:
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	var released: Array[Dictionary] = []
	system.detonated.connect(func(origin: Vector3, charge: ExplosionCharge) -> void:
		released.append({origin = origin, charge = charge}))
	var barrel := _make_barrel(system, 7)
	root.add_child(system)
	root.add_child(barrel)
	barrel.global_position = Vector3(10.0, 1.0, 0.0)
	barrel.apply_blast(Vector3(10.0, 1.0, 8.0), 6.0, 14.0)
	_check(not barrel.armed, "a blast out of range does not arm")
	barrel.apply_blast(Vector3(10.0, 1.0, 5.5), 6.0, 14.0)
	_check(not barrel.armed, "a share below the threshold does not arm")
	barrel.apply_blast(Vector3(10.0, 1.0, 2.5), 6.0, 14.0)
	_check(barrel.armed, "a share above the threshold arms")
	var expected := RandomNumberGenerator.new()
	expected.seed = 7
	var fuse := expected.randf_range(ExplosiveBarrel.FUSE_MIN_S, ExplosiveBarrel.FUSE_MAX_S)
	_check(fuse >= ExplosiveBarrel.FUSE_MIN_S and fuse <= ExplosiveBarrel.FUSE_MAX_S,
		"fuse stays in its range")
	barrel._physics_process(fuse - 0.01)
	_check(system.pending_count() == 0, "no detonation before the fuse runs out")
	barrel._physics_process(0.02)
	_check(system.pending_count() == 1, "detonation once the fuse ran out")
	_check(barrel.detonated and barrel.is_queued_for_deletion(), "barrel is removed")
	system.advance(0.0)
	_check(released.size() == 1, "the queued detonation is released")
	_check(is_equal_approx(released[0].origin.y, BARREL_CHARGE.radius_m), "origin lifted to the charge radius")
	_check(released[0].charge == BARREL_CHARGE, "barrel detonates with its own charge")
	barrel._physics_process(5.0)
	barrel.detonate()
	barrel.apply_blast(Vector3(10.0, 1.0, 2.5), 6.0, 14.0)
	system.advance(0.0)
	_check(system.pending_count() == 0 and released.size() == 1, "a barrel detonates at most once")
	var twin := _make_barrel(system, 7)
	root.add_child(twin)
	twin.global_position = Vector3(10.0, 1.0, 0.0)
	twin.apply_blast(Vector3(10.0, 1.0, 2.5), 6.0, 14.0)
	_check(is_equal_approx(twin._fuse_left_s, fuse), "same seed gives the same fuse")
	system.free()
	barrel.free()
	twin.free()


func _test_validation() -> void:
	_check(RANGE_CONFIG.validate() == "", "range config validates")
	_check(BARREL_CHARGE.validate() == "", "barrel charge validates")
	_check(FIREBALL_CHARGE.validate() == "", "fireball charge validates")
	var range_system := ExplosionSystem.new()
	range_system.config = RANGE_CONFIG
	for charge: ExplosionCharge in [BARREL_CHARGE, FIREBALL_CHARGE]:
		_check(range_system.refusal(charge) == "", "charge stays inside the residency band")
	range_system.free()
	_check(FIREBALL_RANGE_CONFIG.validate() == "", "fireball range config validates")
	_check(is_equal_approx(FIREBALL_RANGE_CONFIG.cell_size_m, 0.15), "fireball range runs at 0.15 m cells")
	var fireball_system := ExplosionSystem.new()
	fireball_system.config = FIREBALL_RANGE_CONFIG
	_check(fireball_system.refusal(FIREBALL_CHARGE) == "", "fireball charge fits the 0.15 m config")
	fireball_system.free()
	var config := RANGE_CONFIG.duplicate() as ExplosionConfig
	config.velocity_clamp_mps = 200.0
	_check(config.validate() != "", "a clamp beyond the tile band is refused")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.cell_size_m = 0.0
	_check(config.validate() != "", "zero cell size is refused")
	_check(RANGE_CONFIG.turbulence_strength > 0.0 and FIREBALL_RANGE_CONFIG.turbulence_strength > 0.0,
		"both range presets enable the curl-noise disturbance")
	for wavelength_cells in [4.0, 7.6, 8.0, 16.5, 24.0]:
		config = RANGE_CONFIG.duplicate() as ExplosionConfig
		config.turbulence_wavelength_m = wavelength_cells * config.cell_size_m
		_check(config.validate() != "", "turbulence wavelength of %.1f cells is refused" % wavelength_cells)
	for wavelength_cells in [5.0, 6.0, 10.0, 12.0, 20.0]:
		config = RANGE_CONFIG.duplicate() as ExplosionConfig
		config.turbulence_wavelength_m = wavelength_cells * config.cell_size_m
		_check(config.validate() == "", "turbulence wavelength of %.1f cells is accepted" % wavelength_cells)
	_check(RANGE_CONFIG.turbulence_octaves() == 2, "range preset keeps the half-wavelength octave (5 cells)")
	_check(FIREBALL_RANGE_CONFIG.turbulence_octaves() == 2, "fireball range keeps the half-wavelength octave (5 cells)")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.turbulence_wavelength_m = 9.9 * config.cell_size_m
	_check(config.turbulence_octaves() == 1, "a 9.9-cell wavelength has no octave at 4.95 cells")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.turbulence_band_hi_k = config.turbulence_band_lo_k
	_check(config.validate() != "", "an empty turbulence band is refused")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.turbulence_strength = 0.0
	config.turbulence_wavelength_m = config.cell_size_m
	_check(config.validate() == "", "a disabled disturbance skips its wavelength check")
	_test_billow_config()
	var charge := BARREL_CHARGE.duplicate() as ExplosionCharge
	charge.radius_m = 0.0
	_check(charge.validate() != "", "zero radius is refused")
	charge = BARREL_CHARGE.duplicate() as ExplosionCharge
	charge.fuel_fraction = 1.5
	_check(charge.validate() != "", "fuel fraction above 1 is refused")
	charge = BARREL_CHARGE.duplicate() as ExplosionCharge
	charge.pulse_duration_s = 0.0
	_check(charge.validate() != "", "zero pulse duration is refused")
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	var strong := BARREL_CHARGE.duplicate() as ExplosionCharge
	strong.divergence_per_s = 500.0
	strong.radius_m = 5.0
	system.detonate(Vector3.ZERO, strong)
	_check(system.pending_count() == 0, "a charge past the residency bound is refused")
	system.free()


func _test_billow_config() -> void:
	for path in ["res://resources/explosion/presets/billow_explosion.tres", "res://resources/fire/billow_campfire.tres"]:
		var preset := load(path) as FireBillowConfig
		_check(preset != null and preset.validate() == "", "%s validates" % path)
	var billow := FireBillowConfig.new()
	_check(billow.validate() == "" and not billow.rest_active(), "a default billow config is off and valid")
	var cases := {"mode": 4, "strength": 1.5, "crevice_cooling_fraction": 0.95, "crevice_soot_gain": -1.0,
		"wavelength_cells": 0.0, "vertical_stretch": 0.0, "rise_m": -1.0, "rise_base": 2.0,
		"reset_s": -0.1, "anchor": 1.5, "fade_start_k": -5.0}
	for field: String in cases:
		billow = FireBillowConfig.new()
		billow.set(field, cases[field])
		_check(billow.validate() != "", "billow %s out of range is refused" % field)
	billow = FireBillowConfig.new()
	billow.fade_start_k = 700.0
	billow.fade_full_k = 700.0
	_check(billow.validate() != "", "a fade window with full <= start is refused")
	billow.fade_full_k = 1000.0
	_check(billow.validate() == "", "a fade window with full > start is accepted")
	billow.fade_start_k = 0.0
	billow.fade_full_k = 0.0
	_check(billow.validate() == "", "0/0 disables the fade")
	billow = FireBillowConfig.new()
	billow.mode = 3
	billow.reset_s = 0.15
	_check(billow.rest_active(), "an enabled billow with a period rides the flow")
	var unknown := billow.apply_overrides({"billow_mode": "2", "billow_reset_s": "0", "billow_x": 1})
	_check(billow.mode == 2 and not billow.rest_active() and unknown == ["billow_x"],
		"capture overrides are cast to the field types and unknown keys are returned")
	var config := RANGE_CONFIG.duplicate() as ExplosionConfig
	config.billow = FireBillowConfig.new()
	config.billow.reset_s = -1.0
	_check(config.validate() != "", "an invalid billow refuses the explosion config")
	var solver := FireGpuSolver.new()
	solver.timestep = 1.0 / 60.0
	solver.blast_rest_period_s = 0.15
	_check(solver._rest_period_steps() == 10, "0.15 s at 60 Hz quantises to 10 substeps")
	solver.blast_rest_period_s = 0.03
	_check(solver._rest_period_steps() == 2, "a period under two substeps is clamped to 2")
	solver.blast_rest_period_s = 0.0
	_check(solver._rest_period_steps() == 0, "period 0 turns the lattices off")
	solver.blast_rest_period_s = 0.15
	solver.timestep = 1.0 / 30.0
	_check(solver._rest_period_steps() % 2 == 0 and solver._rest_period_steps() > 0, "the quantised period is even")
	solver.timestep = 1.0 / 60.0
	solver._rest_built = true
	solver.blast_rest_period_s = 0.15
	var steps := solver._rest_period_steps()
	var pc := PackedByteArray()
	pc.resize(64)
	var run := _run_rest(solver, pc, 0, 3 * steps)
	_check(run.worst_reset_weight == 0.0, "a lattice resets only where its triangle weight is exactly 0")
	_check(run.worst_weight_sum < 1e-5, "the two triangle weights sum to 1 on every substep")
	_check(run.step0_flags == 3, "the first substep resets both lattices")
	_check(run.resets == [2, 3], "each lattice resets once per period, half a period apart (%s)" % [run.resets])
	solver._rest_steps = 0
	run = _run_rest(solver, pc, 0, 3 * steps)
	_check(run.resets == [2, 3] and run.step0_flags == 3,
		"the schedule depends on the substep counter only, so two substeps per frame follow it too")
	var step := 3 * steps
	solver.blast_rest_period_s = 0.0
	_check(solver._rest_display_constant(pc).is_empty(), "period 0 leaves the display push constant alone")
	solver.blast_rest_period_s = 0.15
	run = _run_rest(solver, pc, step, 1)
	_check(run.step0_flags == 3, "re-enabling the same period resets both lattices")
	solver.blast_rest_period_s = 0.3
	run = _run_rest(solver, pc, step + 1, 1)
	_check(run.step0_flags == 3, "a new period resets both lattices")
	run = _run_rest(solver, pc, step + 2, 2 * solver._rest_period_steps())
	_check(run.worst_reset_weight == 0.0 and run.worst_weight_sum < 1e-5, "the new period keeps weight 0 at its resets")


## Runs [param count] substeps from [param first] and reports the reset weights, the weight sum
## error, the first substep's flags and the reset count per lattice (the first substep excluded).
func _run_rest(solver: FireGpuSolver, pc: PackedByteArray, first: int, count: int) -> Dictionary:
	var result := {"worst_reset_weight": 0.0, "worst_weight_sum": 0.0, "step0_flags": 0, "resets": [0, 0]}
	for i in count:
		solver._simulation_step = first + i
		var out := solver._rest_display_constant(pc)
		var flags := int(out.decode_float(32))
		var weights := [0.0, 0.0]
		for k in 2:
			var phase := out.decode_float(36 + 4 * k)
			weights[k] = 1.0 - absf(2.0 * phase - 1.0)
			if i > 0 and (flags >> k) & 1 == 1:
				result.worst_reset_weight = maxf(result.worst_reset_weight, weights[k])
				result.resets[k] += 1
		if i == 0:
			result.step0_flags = flags & 3
		result.worst_weight_sum = maxf(result.worst_weight_sum, absf(weights[0] + weights[1] - 1.0))
	return result


func _test_queue() -> void:
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	var released: Array[Vector3] = []
	system.detonated.connect(func(origin: Vector3, _charge: ExplosionCharge) -> void: released.append(origin))
	var total := FireGpuSolver.MAX_BLASTS + 3
	for i in total:
		system.detonate(Vector3(float(i), 1.0, 0.0), BARREL_CHARGE)
	_check(system.pending_count() == total, "detonations queue up")
	system.advance(0.0)
	_check(released.size() == 1, "one release per frame")
	for i in FireGpuSolver.MAX_BLASTS - 1:
		system.advance(0.0)
	_check(released.size() == FireGpuSolver.MAX_BLASTS, "every slot gets used")
	system.advance(0.0)
	_check(released.size() == FireGpuSolver.MAX_BLASTS, "a full table releases nothing")
	_check(system.pending_count() == 3, "waiting detonations are kept, not dropped")
	for i in released.size():
		_check(released[i].x == float(i), "queue releases in order")
	system.advance(BARREL_CHARGE.pulse_duration_s * 0.5)
	system.advance(0.0)
	_check(released.size() == FireGpuSolver.MAX_BLASTS, "slots stay busy during the pulse")
	system.advance(BARREL_CHARGE.pulse_duration_s * 0.5 + 0.001)
	system.advance(0.0)
	_check(released.size() == FireGpuSolver.MAX_BLASTS + 1, "a slot freed after pulse_duration_s takes the next one")
	_check(system.pending_count() == 2, "one waiting detonation left the queue")
	system.free()


func _make_barrel(system: ExplosionSystem, seed_value: int) -> ExplosiveBarrel:
	var barrel := ExplosiveBarrel.new()
	barrel.system = system
	barrel.charge = BARREL_CHARGE
	barrel.rng.seed = seed_value
	return barrel
