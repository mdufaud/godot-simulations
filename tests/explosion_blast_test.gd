extends "res://tests/test_case.gd"
## No GPU: the queue is driven through a solver that was never initialised.

const RANGE_CONFIG := preload("res://resources/explosion/presets/range.tres")
const FIREBALL_RANGE_CONFIG := preload("res://resources/explosion/presets/fireball_range.tres")
const BARREL_CHARGE := preload("res://resources/explosion/presets/barrel_charge.tres")
const FIREBALL_CHARGE := preload("res://resources/explosion/presets/fireball_charge.tres")
const TEST_COUNT := 17
const SMOKE_TARGET_S := [20.0, 30.0, 120.0]
const DILUTION_ALLOWANCE := 1.4

var _completed := 0


func _initialize() -> void:
	await process_frame
	_test_impulse_law()
	_test_barrel_fuse()
	_test_validation()
	_test_queue()
	_test_companion_chain()
	_test_click_and_clock()
	_test_barrel_routing()
	_test_charge_scale()
	_test_settings_rules()
	_test_framing()
	_test_dust_ring()
	_test_presets()
	_test_pace()
	_test_carry_and_smoke()
	_test_chain_reach()
	_test_nuke_front()
	_test_refusal_rules()
	_check(_completed == TEST_COUNT, "only %d of %d test groups ran to their end" % [_completed, TEST_COUNT])
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
	_completed += 1


func _test_barrel_fuse() -> void:
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	var released: Array[Dictionary] = []
	system.detonated.connect(func(origin: Vector3, charge: ExplosionCharge, _carry: Vector3) -> void:
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
	barrel.free()
	twin.free()
	system.free()
	_completed += 1


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
	config.lid_base_m = -1.0
	_check(config.validate() != "", "a negative lid base is refused")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.lid_damping_per_s = -1.0
	_check(config.validate() != "", "a negative lid damping is refused")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.lid_damping_per_s = 1.0
	config.lid_thickness_m = 0.0
	_check(config.validate() != "", "a lid with no thickness is refused")
	config.lid_damping_per_s = 0.0
	_check(config.validate() == "", "a zero thickness is fine while the lid is off")
	config = RANGE_CONFIG.duplicate() as ExplosionConfig
	config.turbulence_strength = 0.0
	config.turbulence_wavelength_m = config.cell_size_m
	_check(config.validate() == "", "a disabled disturbance skips its wavelength check")
	_test_billow_config()
	_test_glow_window()
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
	strong.radius_m = 8.0
	system.detonate(Vector3.ZERO, strong)
	_check(system.pending_count() == 0, "a charge past the residency bound is refused")
	system.free()
	_completed += 1


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
	system.detonated.connect(func(origin: Vector3, _charge: ExplosionCharge, _carry: Vector3) -> void: released.append(origin))
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
	_completed += 1


func _test_companion_chain() -> void:
	var leaf := ExplosionCharge.new()
	leaf.divergence_per_s = 1.0
	leaf.continuous = true
	leaf.pulse_duration_s = 5.0
	var mid := ExplosionCharge.new()
	mid.divergence_per_s = 1.0
	mid.continuous = true
	mid.pulse_duration_s = 5.0
	mid.companion = leaf
	var parent := ExplosionCharge.new()
	parent.divergence_per_s = 1.0
	parent.companion = mid
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	system.detonate(Vector3.ZERO, parent)
	system.advance(0.0)
	_check(system.pending_count() == 1 and _slot_runs(system, parent) and not _slot_runs(system, mid), "a companion is released one frame after its parent")
	system.advance(0.0)
	_check(system.pending_count() == 1 and _slot_runs(system, mid) and not _slot_runs(system, leaf), "a companion's companion follows one frame later")
	system.advance(0.0)
	_check(system.pending_count() == 0 and _slot_runs(system, leaf), "the whole chain runs")
	system.reset()
	system.detonate(Vector3.ZERO, parent)
	system.advance(0.0)
	system.reset()
	system.advance(0.0)
	system.advance(0.0)
	_check(system.pending_count() == 0 and not _slot_runs(system, mid) and not _slot_runs(system, leaf), "reset drops the rest of a chain")
	var scaled := ExplosionActions.scaled_charge(parent, 0.5)
	_check(is_equal_approx(scaled.companion.radius_m, mid.radius_m * 0.5) and is_equal_approx(scaled.companion.companion.radius_m, leaf.radius_m * 0.5)
		and scaled.companion.companion != leaf, "the charge scale reaches every companion of the chain")
	var late := mid.duplicate() as ExplosionCharge
	late.continuous = false
	late.onset_s = 3.0
	_check(late.validate() != "", "an onset needs a continuous charge")
	late.continuous = true
	late.onset_s = -1.0
	_check(late.validate() != "", "a negative onset is refused")
	system.free()
	_test_afterwind()
	_completed += 1


func _test_afterwind() -> void:
	var dust := ExplosionCharge.new()
	dust.divergence_per_s = 1.0
	dust.continuous = true
	dust.afterwind_delay_s = 2.0
	dust.pulse_duration_s = 20.0
	dust.afterwind_mps = 30.0
	dust.afterwind_radius_m = 700.0
	dust.afterwind_height_m = 90.0
	dust.afterwind_tau_s = 2.0
	_check(dust.validate() == "", "a complete afterwind validates")
	for field: String in ["afterwind_mps", "afterwind_radius_m", "afterwind_height_m", "afterwind_tau_s"]:
		var bad := dust.duplicate() as ExplosionCharge
		bad.set(field, -1.0)
		_check(bad.validate() != "", "a negative %s is refused" % field)
	var open := dust.duplicate() as ExplosionCharge
	open.afterwind_tau_s = 0.0
	_check(open.validate() != "", "an afterwind with no time constant is refused")
	open.afterwind_mps = 0.0
	_check(open.validate() == "", "a zero afterwind skips the shape checks")
	_check(ExplosionSystem.afterwind_envelope(-1.0, 20.0) == 0.0 and ExplosionSystem.afterwind_envelope(0.0, 20.0) == 0.0, "the envelope is 0 before the pulse")
	_check(is_equal_approx(ExplosionSystem.afterwind_envelope(2.0, 20.0), 1.0), "the envelope holds mid pulse")
	_check(ExplosionSystem.afterwind_envelope(20.0, 20.0) == 0.0 and ExplosionSystem.afterwind_envelope(25.0, 20.0) == 0.0, "the envelope is 0 once the pulse ends")
	var parent := ExplosionCharge.new()
	parent.divergence_per_s = 1.0
	parent.companion = dust
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	system.detonate(Vector3(5.0, 0.0, 7.0), parent)
	system.advance(0.0)
	_check(system.solver._afterwind[0].z == 0.0, "no afterwind before the companion starts")
	system.advance(0.0)
	system.advance(1.0)
	system.advance(0.0)
	_check(system.solver._afterwind[0].z == 0.0, "no afterwind during afterwind_delay_s")
	system.advance(2.0)
	system.advance(2.0)
	system.advance(0.0)
	_check(system.solver._afterwind[0].z > 29.0 and system.solver._afterwind[0].x == 5.0 and system.solver._afterwind[0].y == 7.0, "the afterwind runs at the companion's centre while it pulses")
	system.reset()
	_check(system.solver._afterwind[0].z == 0.0 and system.solver._afterwind[1] == Vector4.ZERO, "reset mid pulse pushes a zero afterwind")
	system.advance(20.0)
	_check(system.solver._afterwind[0].z == 0.0, "no afterwind after the companion ends")
	system.free()
	_test_afterwind_relaxation()


func _test_afterwind_relaxation() -> void:
	var a := Vector4(10.0, -5.0, 30.0, 2.0)
	var b := Vector4(700.0, 175.0, 90.0, 40.0)
	var points: Array[Vector3] = [Vector3(210.0, 5.0, -5.0), Vector3(-190.0, 5.0, -5.0), Vector3(10.0, 5.0, 195.0), Vector3(10.0, 5.0, -205.0),
		Vector3(110.0, 5.0, 95.0), Vector3(-90.0, 5.0, 95.0), Vector3(-90.0, 5.0, -105.0), Vector3(110.0, 5.0, -105.0), Vector3(15.0, 5.0, 30.0)]
	var bad := 0
	var pushed := 0
	for p in points:
		for axis in 2:
			var radial := Vector2(p.x - a.x, p.z - a.y).normalized()
			var inward := -(radial.x if axis == 0 else radial.y)
			for face_speed in [-40.0, -10.0, -1.0, 0.0, 1.0, 10.0, 40.0]:
				var dv := ExplosionSystem.afterwind_dv(a, b, p, axis, face_speed, 0.05)
				if is_zero_approx(inward):
					bad += int(dv != 0.0)
					continue
				pushed += int(dv != 0.0)
				var after: float = face_speed + dv
				bad += int(dv * inward < 0.0)
				bad += int(inward < 0.0 and after > face_speed or inward > 0.0 and after < face_speed)
				bad += int(inward > 0.0 and face_speed > 0.0 and dv < 0.0 or inward < 0.0 and face_speed < 0.0 and dv > 0.0)
	_check(bad == 0 and pushed > 40, "the afterwind relaxation never pushes outward, never cuts inflow (bad %d, pushed %d)" % [bad, pushed])
	_check(ExplosionSystem.afterwind_dv(a, b, Vector3(10.0, 5.0, 195.0), 0, 7.0, 0.05) == 0.0, "a face on the axis keeps its flow: target 0 returns 0")
	_check(ExplosionSystem.afterwind_dv(a, b, Vector3(10.0, 5.0, 195.0), 0, -7.0, 0.05) == 0.0, "a face on the axis keeps its inflow")
	_check(ExplosionSystem.afterwind_dv(a, b, Vector3(10.0, 5.0, -5.0), 0, 3.0, 0.05) == 0.0, "the centre column is left alone")
	_check(ExplosionSystem.afterwind_dv(a, b, Vector3(210.0, 5.0, -5.0), 0, 0.0, 0.05) < 0.0, "an at-rest face off the axis is pulled inwards")
	_check(ExplosionSystem.afterwind_dv(a, b, Vector3(210.0, 200.0, -5.0), 0, 0.0, 0.05) == 0.0, "the height cap masks the flow")


func _slot_runs(system: ExplosionSystem, charge: ExplosionCharge) -> bool:
	for slot in system._slots:
		if not slot.is_empty() and slot.charge == charge:
			return true
	return false


func _make_barrel(system: ExplosionSystem, seed_value: int) -> ExplosiveBarrel:
	var barrel := ExplosiveBarrel.new()
	barrel.system = system
	barrel.charge = BARREL_CHARGE
	barrel.rng.seed = seed_value
	return barrel


func _test_click_and_clock() -> void:
	_check(ExplosionActions.is_click(Vector2(100, 100), Vector2(103, 104)), "a 5 px press-release is a click")
	_check(not ExplosionActions.is_click(Vector2(100, 100), Vector2(107, 100)), "a 7 px press-release is a drag")
	var actions := ExplosionActions.new()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(50, 50)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	release.position = Vector2(52, 50)
	_check(not actions.left_click(press) and actions.left_click(release), "press then near release fires one click")
	_check(not actions.left_click(release), "a release without a press is not a click")
	actions.left_click(press)
	release.position = Vector2(90, 50)
	_check(not actions.left_click(release), "a dragged release is not a click")
	var base := ExplosionActions.BASE_PACE
	_check(ExplosionActions.clamp_time_scale(9.0) == base and ExplosionActions.clamp_time_scale(-1.0) == 0.0
		and ExplosionActions.clamp_time_scale(0.5) == 0.5, "time scale clamps to [0, base pace]")
	var ticks := int(ExplosionActions.default_tick_rate())
	actions = ExplosionActions.started()
	_check(is_equal_approx(Engine.time_scale, base) and Engine.physics_ticks_per_second == int(roundf(ticks * base)),
		"the demo starts at the base pace with the physics tick rate raised to match")
	_check(is_equal_approx(actions.cycle_slow(), 0.5) and is_equal_approx(Engine.time_scale, base * 0.5)
		and Engine.physics_ticks_per_second == ticks, "slow 0.5x runs the engine clock at 0.7, 0.7 times the original pace")
	actions.set_paused(true)
	_check(Engine.time_scale == 0.0, "pause stops the engine clock")
	actions.set_paused(false)
	_check(is_equal_approx(Engine.time_scale, base * 0.5), "resume returns to the chosen slow scale")
	_check(is_equal_approx(actions.cycle_slow(), 0.25) and is_equal_approx(Engine.time_scale, base * 0.25)
		and Engine.physics_ticks_per_second == ticks, "slow 0.25x halves it again without lowering the tick rate")
	_check(is_equal_approx(actions.cycle_slow(), 1.0) and Engine.time_scale == base, "the slow cycle wraps back to 1x")
	ExplosionActions.restore_clock()
	_check(Engine.time_scale == 1.0 and Engine.physics_ticks_per_second == ticks, "restore_clock returns the engine clock and tick rate")
	_completed += 1


func _test_barrel_routing() -> void:
	var reach := 0.12 + ExplosionActions.BARREL_HIT_TOLERANCE_M
	var at := Vector3(2.0, 0.45, 0.0)
	_check(ExplosionActions.barrel_touched(at, Vector3.UP, at + Vector3(ExplosiveBarrel.RADIUS_M + 0.1, 0.0, 0.0), reach),
		"a ball at the barrel wall touches it")
	_check(not ExplosionActions.barrel_touched(at, Vector3.UP, at + Vector3(1.5, 0.0, 0.0), reach), "a ball 1.5 m away misses")
	_check(not ExplosionActions.barrel_touched(at, Vector3.UP, at + Vector3(0.0, 1.5, 0.0), reach), "a ball above the lid misses")
	_check(ExplosionActions.barrel_touched(at, Vector3.RIGHT, at + Vector3(0.4, 0.2, 0.0), reach), "a tipped barrel is hit along its axis")
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	root.add_child(system)
	var scenery := ExplosionScenery.new()
	var env_node := WorldEnvironment.new()
	env_node.environment = Environment.new()
	scenery.bind(env_node, DirectionalLight3D.new(), Node3D.new())
	var parent := Node3D.new()
	root.add_child(parent)
	scenery.build(parent, ExplosionMenu.SCENE_BARRELS, system)
	var first := scenery._barrels[0]
	_check(not scenery.detonate_touching(Vector3(0.0, 30.0, 0.0), reach) and system.pending_count() == 0,
		"a ball that hits the ground detonates nothing")
	_check(scenery.detonate_touching(first.global_position + Vector3(ExplosiveBarrel.RADIUS_M, 0.0, 0.0), reach)
		and first.detonated and system.pending_count() == 1, "a ball that touches a barrel detonates that barrel only")
	_check(not scenery._barrels[1].detonated, "the neighbours stay intact")
	var scaled := ExplosionActions.scaled_charge(BARREL_CHARGE, 1.4)
	scenery.set_barrel_charge(scaled)
	_check(scenery._barrels[1].charge == scaled and scenery.barrel_charge == scaled, "live barrels take the scaled charge")
	scenery.clear_effects()
	_free_stub_host(scenery)
	parent.free()
	system.free()
	_completed += 1


func _free_stub_host_nodes(nodes: Array) -> void:
	for node: Node in nodes:
		node.free()


func _free_stub_host(scenery: ExplosionScenery) -> void:
	for node: Node in [scenery.world_env, scenery.sun, scenery.ground]:
		node.free()


func _test_framing() -> void:
	var orbit := OrbitCamera.new()
	var camera := Camera3D.new()
	_check(ExplosionMenu.THROW_ENABLED.size() == ExplosionMenu.SCENES.size() and ExplosionScenery.FRAMING.size() == ExplosionMenu.SCENES.size(),
		"one framing and one throw flag per scene")
	_check(not ExplosionMenu.THROW_ENABLED[ExplosionMenu.SCENE_MUSHROOM] and ExplosionMenu.THROW_ENABLED[0],
		"the mushroom has no throw")
	for index in ExplosionMenu.SCENES.size():
		var framing: Dictionary = ExplosionScenery.FRAMING[index]
		orbit.target = Vector3(99.0, 99.0, 99.0)
		orbit.distance = 1.0
		orbit.yaw = 33.0
		ExplosionScenery.apply_framing(orbit, camera, index)
		_check(orbit.target == framing.target and orbit.distance == framing.distance and orbit.min_distance == framing.min_distance
			and orbit.max_distance == framing.max_distance and orbit.zoom_speed == framing.zoom_speed
			and orbit.move_speed == framing.move_speed and camera.fov == framing.fov and camera.far == framing.far,
			"scene %d applies its framing" % index)
		_check(orbit.yaw == 33.0, "a scene change keeps the yaw")
		_check(framing.distance >= framing.min_distance and framing.distance <= framing.max_distance
			and framing.zoom_speed <= framing.distance * 0.1, "scene %d: the start distance is in range and a wheel notch is a small step" % index)
	var nuke: Dictionary = ExplosionScenery.FRAMING[ExplosionMenu.SCENE_MUSHROOM]
	var lens_y: float = nuke.target.y - nuke.distance * sin(deg_to_rad(nuke.pitch))
	_check(nuke.pitch >= 5.0 and nuke.pitch <= 20.0 and nuke.fov >= 15.0 and nuke.fov <= 45.0 and lens_y >= 0.0 and lens_y <= 30.0,
		"the mushroom camera starts low and looks up, got y=%.1f pitch=%.1f fov=%.1f" % [lens_y, nuke.pitch, nuke.fov])
	_check(nuke.max_distance <= nuke.target.y / sin(deg_to_rad(nuke.pitch)), "zooming out never puts the mushroom camera underground")
	var lid: ExplosionConfig = ExplosionScenery.MUSHROOM_CONFIG
	var lid_top_m := lid.lid_base_m + lid.lid_thickness_m
	var lens_to_top := rad_to_deg(atan2(lid_top_m - lens_y, nuke.distance * cos(deg_to_rad(nuke.pitch))))
	_check(lid.lid_damping_per_s > 0.0 and lens_to_top < nuke.pitch + nuke.fov * 0.5 and lens_to_top > nuke.pitch - nuke.fov * 0.5,
		"the mushroom lid is on and its top is inside the default vertical view, got %.1f deg" % lens_to_top)
	orbit.free()
	camera.free()
	_completed += 1


func _test_dust_ring() -> void:
	var system := ExplosionSystem.new()
	system.fixed_delta_s = 0.1
	var ring := ExplosionDustRing.new()
	ring.system = system
	root.add_child(ring)
	ring.start()
	var mid := BARREL_CHARGE.duplicate()
	mid.radius_m = 100.0
	mid.blast_radius_m = ExplosionDustRing.INFLOW_MIN_BLAST_M
	for i in ExplosionDustRing.MAX_RINGS + 4:
		system.detonated.emit(Vector3(float(i), 1.0, 0.0), mid, Vector3.ZERO)
	_check(ring._rings.size() == ExplosionDustRing.MAX_RINGS, "concurrent rings are capped")
	var speed_before: float = ring._rings[-1].speed_mps
	system.blast_force_scale = 1.5
	system.detonated.emit(Vector3.ZERO, mid, Vector3.ZERO)
	_check(is_equal_approx(ring._rings[-1].speed_mps, mid.blast_speed_mps * 1.5)
		and is_equal_approx(speed_before, mid.blast_speed_mps), "the ring travels at the force-scaled blast speed")
	var rings_before := ring._rings.size()
	system.detonated.emit(Vector3.ZERO, BARREL_CHARGE, Vector3.ZERO)
	_check(ring._rings.size() == rings_before and ring.get_child_count() > 0 and ring.get_children().any(func(n: Node) -> bool: return n is GPUParticles3D),
		"a small blast throws puffs instead of a ring")
	_check(ExplosionFx.decelerating_front(0.0, 3.0, 300.0) == 0.0 and ExplosionFx.decelerating_front(0.05, 3.0, 300.0) > 0.99
		and ExplosionFx.decelerating_front(0.005, 3.0, 300.0) > 0.3, "the shock front starts fast and flattens at the blast radius")
	ring.clear()
	_check(ring._rings.is_empty(), "clear drops every ring")
	var window := ExplosionDustRing.inflow_window_s(100.0, 2000.0, 100.0)
	_check(is_equal_approx(window.x, 0.6 * 19.0) and is_equal_approx(window.y, 900.0 / 60.0), "the inflow runs from 0.6 of the front's travel for the closing time")
	_check(ExplosionDustRing.inflow_window_s(1000.0, 2000.0, 100.0).y == 0.0 and ExplosionDustRing.inflow_window_s(1500.0, 2000.0, 100.0).y == 0.0, "no inflow when the charge reaches the inflow start radius")
	_check(ExplosionDustRing.inflow_window_s(100.0, 2000.0, 0.0).y == 0.0, "no inflow at zero speed")
	var big := BARREL_CHARGE.duplicate()
	big.radius_m = 1000.0
	big.growth_ratio = 1.0
	big.formation_s = 0.0
	big.blast_radius_m = 1500.0
	system.detonated.emit(Vector3.ZERO, big, Vector3.ZERO)
	_check(not ring._rings.is_empty() and not ring._rings[-1].inflow, "a huge charge gets no inflow ring")
	ring.clear()
	var cap_charge := BARREL_CHARGE.duplicate()
	cap_charge.radius_m = 5.0
	cap_charge.blast_radius_m = ExplosionCameraShake.REACH_MAX_BLAST_M
	var at_cap := ExplosionCameraShake.trauma_for(cap_charge, 3000.0)
	cap_charge.blast_radius_m = 5.0 * ExplosionCameraShake.REACH_MAX_BLAST_M
	_check(is_equal_approx(ExplosionCameraShake.trauma_for(cap_charge, 3000.0), at_cap), "shake reach stops growing above REACH_MAX_BLAST_M")
	cap_charge.blast_radius_m = 0.5 * ExplosionCameraShake.REACH_MAX_BLAST_M
	_check(ExplosionCameraShake.trauma_for(cap_charge, 3000.0) < at_cap, "a smaller blast below the cap reaches less far")
	ring.free()
	system.free()
	_completed += 1


func _test_presets() -> void:
	var nuke := ExplosionScenery.NUKE_CHARGE
	var dust := nuke.companion
	_check(nuke.validate() == "" and dust != null and dust.validate() == "", "the nuke charge and its dust companion validate")
	var mushroom := ExplosionSystem.new()
	mushroom.config = ExplosionScenery.MUSHROOM_CONFIG
	_check(ExplosionScenery.MUSHROOM_CONFIG.validate() == "" and mushroom.refusal(nuke) == "", "the nuke charge runs on the mushroom config")
	for scene in ExplosionMenu.SCENES.size():
		var system := ExplosionSystem.new()
		system.config = ExplosionScenery.config_for(scene)
		var base := ExplosionScenery.base_charge(scene)
		var top := ExplosionActions.scaled_charge(base, ExplosionMenu.charge_scale_max(scene))
		_check(system.refusal(top) == "", "the largest slider charge of scene %d is accepted" % scene)
		system.free()
	mushroom.free()
	_completed += 1


func _test_glow_window() -> void:
	for config: ExplosionConfig in [RANGE_CONFIG, FIREBALL_RANGE_CONFIG, ExplosionScenery.MUSHROOM_CONFIG]:
		_check(config.validate() == "", "preset glow window validates")
	var config := RANGE_CONFIG.duplicate() as ExplosionConfig
	config.glow_visible_full_k = config.glow_visible_from_k
	_check(config.validate() != "", "a glow window with full <= from is refused")
	config.glow_visible_from_k = 0.0
	config.glow_visible_full_k = 0.0
	_check(config.validate() == "", "0/0 disables the glow window")
	config.glow_visible_full_k = 1200.0
	_check(config.validate() == "", "a window starting at 0 K is accepted")


func _test_charge_scale() -> void:
	var radius := BARREL_CHARGE.radius_m
	var scaled := ExplosionActions.scaled_charge(BARREL_CHARGE, 1.4, 0.2)
	_check(scaled != BARREL_CHARGE and is_equal_approx(scaled.radius_m, radius * 1.4), "the scaled charge is a duplicate with the new radius")
	_check(BARREL_CHARGE.radius_m == radius, "the preloaded preset stays untouched")
	_check(is_equal_approx(scaled.soot_fraction, 0.2), "an explicit soot fraction overrides the copy only")
	var nuke := ExplosionScenery.NUKE_CHARGE
	var companion_radius := nuke.companion.radius_m
	var big := ExplosionActions.scaled_charge(nuke, 0.5)
	_check(big.companion != nuke.companion and nuke.companion.radius_m == companion_radius
		and is_equal_approx(big.companion.radius_m, companion_radius * 0.5), "a companion is duplicated before it is scaled")
	_completed += 1


func _test_settings_rules() -> void:
	_check(ExplosionSettings.albedo_for(0.0).is_equal_approx(ExplosionSettings.ALBEDO_LIGHT)
		and ExplosionSettings.albedo_for(1.0).is_equal_approx(ExplosionSettings.ALBEDO_BLACK), "darkness spans light grey to black")
	_check(ExplosionSettings.albedo_for(2.0).is_equal_approx(ExplosionSettings.ALBEDO_BLACK), "darkness is clamped")
	_check(ExplosionSettings.wind_vector(4.0, 90.0).is_equal_approx(Vector3(0.0, 0.0, 4.0)), "wind points along the chosen heading")
	_check(ExplosionSettings.force_acts(ExplosionMenu.SCENE_BARRELS) and not ExplosionSettings.force_acts(0)
		and not ExplosionSettings.force_acts(ExplosionMenu.SCENE_MUSHROOM), "blast force only acts where bodies feel the blast")
	var base := FireBillowConfig.new()
	base.mode = 3
	base.strength = 1.0
	var half := ExplosionSettings.billow_for(base, 0.5)
	_check(half != base and is_equal_approx(half.strength, 0.5) and half.mode == 3 and base.strength == 1.0,
		"surface detail changes a duplicate, never the preset")
	_check(ExplosionSettings.billow_for(base, 0.0).mode == 0, "surface detail 0 switches the billow off")
	var system := ExplosionSystem.new()
	system.config = RANGE_CONFIG
	system.solver = FireGpuSolver.new()
	var settings := ExplosionSettings.new()
	settings._explosion = system
	settings.wind_mps = 9.0
	for scene in [0, 2]:
		settings._scene_index = scene
		settings.apply_wind()
		_check(is_equal_approx(system.solver.wind.length(), ExplosionSettings.wind_max(scene)) and settings.wind_mps == 9.0,
			"scene %d caps the applied wind and keeps the requested speed" % scene)
	settings.wind_mps = 1.0
	settings.apply_wind()
	_check(is_equal_approx(system.solver.wind.length(), 1.0), "a raised cap lets the requested wind through")
	system.free()
	var scenery := ExplosionScenery.new()
	var env_node := WorldEnvironment.new()
	env_node.environment = Environment.new()
	env_node.environment.ambient_light_color = Color(0.6, 0.7, 0.85)
	scenery.bind(env_node, DirectionalLight3D.new(), Node3D.new())
	root.add_child(scenery.sun)
	var gas := ExplosionSystem.new()
	for scene in [0, ExplosionMenu.SCENE_MUSHROOM]:
		gas.config = ExplosionScenery.config_for(scene)
		scenery._index = scene
		scenery._metric_scale = ExplosionScenery.metric_scale(gas.config)
		var dark := scenery.smoke_lighting(ExplosionSettings.albedo_for(0.5))
		var light := scenery.smoke_lighting(ExplosionSettings.albedo_for(0.0))
		var ratio := ExplosionSettings.albedo_for(0.5) / ExplosionSettings.albedo_for(0.0)
		_check(dark.smoke_albedo == ExplosionSettings.albedo_for(0.5)
			and (dark.smoke_ambient_rgb / light.smoke_ambient_rgb).is_equal_approx(ratio),
			"scene %d: the albedo and the ambient fill follow the same darkness" % scene)
	var host := ExplosionSettings.new()
	host.scenery = scenery
	var presentation := FirePresentation.new()
	presentation.solver = FireGpuSolver.new()
	presentation.volume_material = ShaderMaterial.new()
	presentation.volume_material.set_shader_parameter("march_step", 0.75)
	presentation.volume_material.set_shader_parameter("march_budget", 320)
	var guard := ViewportGuard.new()
	var host_system := ExplosionSystem.new()
	host_system.solver = FireGpuSolver.new()
	host_system.config = ExplosionScenery.config_for(ExplosionMenu.SCENE_MUSHROOM)
	for scene in [ExplosionMenu.SCENE_MUSHROOM, 0]:
		host.attach(host_system, presentation, guard, scene)
		scenery._index = scene
		_check(is_equal_approx(host.darkness, ExplosionSettings.DARKNESS_DEFAULTS[scene]), "attach takes the scene %d default darkness" % scene)
	host.attach(host_system, presentation, guard, ExplosionMenu.SCENE_MUSHROOM)
	scenery._index = ExplosionMenu.SCENE_MUSHROOM
	host.apply_lighting()
	_check(is_zero_approx(host.darkness) and presentation.volume_material.get_shader_parameter("smoke_albedo") == ExplosionSettings.ALBEDO_LIGHT,
		"the mushroom starts at the light albedo through attach and lighting")
	host.set_darkness(0.9)
	host.attach(host_system, presentation, guard, 0)
	_check(is_equal_approx(host.darkness, 0.9), "a chosen darkness survives a scene switch")
	host_system.free()
	presentation.free()
	guard.free()
	_free_stub_host_nodes([env_node, scenery.sun, scenery.ground])
	gas.free()
	_completed += 1


func _test_pace() -> void:
	var base := ExplosionActions.BASE_PACE
	for config: ExplosionConfig in [RANGE_CONFIG, FIREBALL_RANGE_CONFIG, ExplosionScenery.MUSHROOM_CONFIG]:
		_check(config.validate() == "", "preset validates at the base pace: band %.1f cells" % config.band_cells(config.velocity_clamp_mps))
		var solver := FireGpuSolver.new()
		solver.set_simulation_hz(config.simulation_hz)
		solver.max_catchup_steps = config.max_substeps_per_frame
		var steps := 0
		for frame in 120:
			steps += solver.schedule_steps(base / 60.0)
		_check(solver.dropped_time == 0.0 and absf(float(steps) * solver.timestep - base * 2.0) <= solver.timestep,
			"%d Hz runs %d steps in 120 frames at %.1fx with nothing dropped" % [config.simulation_hz, steps, base])
	var wide := RANGE_CONFIG.duplicate() as ExplosionConfig
	wide.topology_interval_steps = 0
	wide.max_substeps_per_frame = 4
	var per_frame_band := wide.band_cells(wide.velocity_clamp_mps)
	_check(wide.validate() != "", "four substeps per refresh overrun the tile band")
	wide.topology_interval_steps = 2
	_check(wide.validate() == "" and is_equal_approx(wide.band_cells(wide.velocity_clamp_mps) * 2.0, per_frame_band),
		"a refresh every two substeps keeps the band inside the limit")
	wide.topology_interval_steps = 1
	_check(wide.band_cells(45.0) < 4.0, "a refresh every substep halves the band again")
	_completed += 1


func _test_kernel() -> void:
	for pair in [[FIREBALL_CHARGE, FIREBALL_RANGE_CONFIG], [BARREL_CHARGE, RANGE_CONFIG]]:
		var charge: ExplosionCharge = pair[0]
		var config: ExplosionConfig = pair[1]
		var system := ExplosionSystem.new()
		system.config = config
		var form := charge.formation_s
		var r0 := charge.radius_m
		var r_max := r0 * charge.growth_ratio
		_check(charge.grows() and charge.validate() == "" and system.refusal(charge) == "", "a growing preset validates and is accepted")
		_check(ExplosionSystem.kernel_radius_m(charge, 0.0) == r0 and is_equal_approx(ExplosionSystem.kernel_radius_m(charge, form), r_max), "the kernel runs from radius_m to growth_ratio x radius_m")
		_check(ExplosionSystem.kernel_radius_m(charge, form * 3.0) == ExplosionSystem.kernel_radius_m(charge, form), "the kernel holds its final radius")
		_check(is_equal_approx(ExplosionSystem.kernel_radius_m(charge, 0.25 * form), r0 + (r_max - r0) * pow(0.25, 0.4)), "the kernel follows (t / T)^0.4")
		var quarter := ExplosionSystem.kernel_radius_m(charge, 0.25 * form) - r0
		_check(quarter > 0.5 * (r_max - r0), "more than half of the growth happens in the first quarter")
		var dt := 1.0 / 60.0
		var volume := 0.0
		var age := 0.0
		while age < form:
			var rate := ExplosionSystem.kernel_rate_per_s(charge, age, dt)
			volume += rate * ExplosionSystem.KERNEL_SOURCE_SHARE * ExplosionSystem.sphere_volume_m3(ExplosionSystem.kernel_radius_m(charge, age)) * dt
			age += dt
		var want := ExplosionSystem.sphere_volume_m3(ExplosionSystem.kernel_radius_m(charge, age)) - ExplosionSystem.sphere_volume_m3(r0)
		_check(absf(volume - want) < 1e-6 * want, "the source rates add up to the volume the sphere grows by")
		_check(ExplosionSystem.kernel_rate_per_s(charge, form, dt) == 0.0, "the source stops once the sphere is formed")
		var first_step := (ExplosionSystem.kernel_radius_m(charge, dt) - r0) / dt
		var peak := first_step * ExplosionSystem.kernel_peak_over_shell()
		_check(is_equal_approx(system.peak_source_mps(charge), peak) and ExplosionSystem.kernel_peak_over_shell() > 1.5, "the peak source is the interior peak of the first step, above its shell speed")
		var settled := system.settled_charge(charge)
		_check(system.refusal(charge) == "" and system.peak_source_mps(settled) <= config.velocity_clamp_mps * (1.0 + 1e-6), "the settled charge keeps its source flow under the clamp, so the clamp never cuts it into a box")
		_check((peak > config.velocity_clamp_mps) == (settled != charge) and settled.formation_offset_s >= charge.formation_offset_s, "a preset whose interior peak passes the clamp starts further up its growth law")
		system.free()
	var throw := Vector3(10.0, 0.0, -4.0)
	var origin := Vector3(1.0, 2.0, 3.0)
	var tau := 0.5 * FIREBALL_CHARGE.formation_s
	_check(ExplosionSystem.kernel_centre(FIREBALL_CHARGE, origin, throw, 0.0) == origin, "the centre starts at the release point")
	var late := ExplosionSystem.kernel_centre(FIREBALL_CHARGE, origin, throw, 100.0)
	_check(late.is_equal_approx(origin + throw * tau), "the centre settles carry x tau ahead")
	_check(ExplosionSystem.kernel_centre(FIREBALL_CHARGE, origin, Vector3.ZERO, 0.2) == origin, "no carry leaves the centre in place")
	var bad := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.divergence_per_s = 10.0
	_check(bad.validate() != "", "a growing charge refuses divergence_per_s")
	bad = FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.formation_s = bad.pulse_duration_s + 0.1
	_check(bad.validate() != "", "a formation longer than the pulse is refused")
	bad = FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.formation_s = 0.0
	_check(bad.validate() != "", "a growing charge needs a formation time")
	bad = FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.continuous = true
	bad.carry_fraction = 0.0
	_check(bad.validate() != "", "a continuous charge cannot grow")
	bad = FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.growth_ratio = 0.5
	_check(bad.validate() != "", "a growth ratio below 1 is refused")


func _test_kernel_upload() -> void:
	var charge := FIREBALL_CHARGE
	var r0 := charge.radius_m
	var want := ExplosionSystem.sphere_volume_m3(r0 * charge.growth_ratio) - ExplosionSystem.sphere_volume_m3(r0)
	for hz in [30, 60, 144]:
		var dt := 1.0 / float(hz)
		var system := ExplosionSystem.new()
		system.config = FIREBALL_RANGE_CONFIG
		system.solver = FireGpuSolver.new()
		system.solver.timestep = 1.0 / float(system.config.simulation_hz)
		system.detonate(Vector3.ZERO, charge)
		var volume := 0.0
		var frames := 0
		while frames < 4 * int(charge.formation_s * float(hz)) + 8:
			var sim_dt := float(system.solver.schedule_steps(dt)) * system.solver.timestep
			system.advance(sim_dt)
			frames += 1
			if sim_dt > 0.0:
				var blast_rate: Vector4 = system.solver._blast_rate[0]
				var radius_m: float = system.solver._blast[0].w
				volume += blast_rate.x * ExplosionSystem.KERNEL_SOURCE_SHARE * ExplosionSystem.sphere_volume_m3(radius_m) * sim_dt
			if system._slots[0].is_empty() or system._slots[0].age >= charge.formation_s + 2.0 * system.solver.timestep:
				break
		_check(absf(volume - want) < 0.02 * want, "the uploaded source rates grow the sphere by its volume at %d Hz (%.3f of %.3f m3)" % [hz, volume, want])
		system.free()
	var carried := ExplosionSystem.new()
	carried.config = FIREBALL_RANGE_CONFIG
	carried.solver = FireGpuSolver.new()
	var throw := Vector3(10.0, 0.0, 0.0)
	carried.detonate(Vector3.ZERO, charge, throw)
	carried.detonate(Vector3(30.0, 0.0, 0.0), charge, throw)
	carried.advance(1.0 / 60.0)
	_check(carried.solver._blast_carry[0] == Vector4.ZERO, "a growing charge's centre moves, so the flow gets no carry impulse")
	carried.advance(1.0 / 60.0)
	carried.advance(1.0 / 60.0)
	var amounts: Array[float] = []
	for event in carried.solver._events:
		amounts.append(event.amount)
	_check(amounts.has(0.5) and amounts.has(1.5), "a carried growing charge repaints its slot at slot + 0.5")
	carried.free()
	var bad := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.continuous = false
	bad.divergence_per_s = 10.0
	_check(bad.grows() and bad.validate() != "", "a non-continuous growing charge with divergence_per_s is refused")


func _test_carry_and_smoke() -> void:
	var system := ExplosionSystem.new()
	system.config = FIREBALL_RANGE_CONFIG
	var throw := Vector3(20.0, 7.0, -10.0)
	var impulse := system.carry_impulse(FIREBALL_CHARGE, throw)
	_check(FIREBALL_CHARGE.carry_fraction > 0.0 and impulse.y == 0.0, "a thrown fireball carries a horizontal impulse only")
	_check(impulse.is_equal_approx(Vector3(throw.x, 0.0, throw.z) * FIREBALL_CHARGE.carry_fraction), "the carry is the charge's share of the horizontal velocity")
	_check(system.carry_impulse(FIREBALL_CHARGE, Vector3.ZERO) == Vector3.ZERO, "no velocity means no carry")
	var fast := system.carry_impulse(FIREBALL_CHARGE, Vector3(500.0, 0.0, 0.0))
	_check(is_equal_approx(fast.length(), FIREBALL_RANGE_CONFIG.velocity_clamp_mps), "the speed a growing sphere moves with is cut to the clamp")
	var legacy := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	legacy.growth_ratio = 1.0
	legacy.formation_s = 0.0
	legacy.divergence_per_s = 80.0
	var pushed := system.carry_impulse(legacy, Vector3(500.0, 0.0, 0.0))
	_check(is_equal_approx(pushed.length(), system.carry_headroom_mps(legacy)), "a carry beyond the clamp is cut to the headroom")
	_check(system.peak_source_mps(legacy) + pushed.length() <= FIREBALL_RANGE_CONFIG.velocity_clamp_mps + 1e-3, "source flow plus carry stays under the velocity clamp")
	_check(system.carry_impulse(BARREL_CHARGE, throw) == Vector3.ZERO, "a charge with no carry fraction gets none")
	var continuous := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	continuous.continuous = true
	_check(continuous.validate() != "", "a continuous charge with a carry fraction is refused")
	continuous.carry_fraction = 0.0
	_check(system.carry_impulse(continuous, throw) == Vector3.ZERO, "a continuous charge never carries")
	var over := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	over.carry_fraction = 1.5
	_check(over.validate() != "", "a carry fraction above 1 is refused")
	var tight := legacy.duplicate() as ExplosionCharge
	tight.divergence_per_s = FIREBALL_RANGE_CONFIG.velocity_clamp_mps * 3.0 / tight.radius_m
	_check(system.refusal(tight) != "", "a carry with no headroom under the clamp is refused")
	system.free()
	_test_kernel()
	_test_kernel_upload()
	for scene in SMOKE_TARGET_S.size():
		var config := ExplosionScenery.config_for(scene)
		var soot := ExplosionScenery.base_charge(scene).soot_fraction
		var floor_soot := config.soot_keep_fraction * FireGpuSolver.TILE_ACTIVITY_THRESHOLD * config.tile_keep_scale
		var decay_s := config.soot_half_life_s * log(soot / floor_soot) / log(2.0)
		_check(config.validate() == "" and decay_s <= SMOKE_TARGET_S[scene] * DILUTION_ALLOWANCE,
			"scene %d: the soot half-life takes %.1f s to bring %.2f of soot to the floor %.4f, target %.0f s (x%.1f for dilution)" % [scene, decay_s, soot, floor_soot, SMOKE_TARGET_S[scene], DILUTION_ALLOWANCE])
	var bad := RANGE_CONFIG.duplicate() as ExplosionConfig
	bad.soot_half_life_s = 0.0
	_check(bad.validate() != "", "a zero soot half-life is refused")
	_completed += 1


func _test_chain_reach() -> void:
	var arm := ExplosiveBarrel.arm_distance_m(BARREL_CHARGE.blast_radius_m, BARREL_CHARGE.blast_speed_mps)
	var share := ExplosiveBarrel.blast_speed_share(Vector3(arm, 0.0, 0.0), BARREL_CHARGE.blast_radius_m, BARREL_CHARGE.blast_speed_mps)
	_check(arm > 0.0 and is_equal_approx(share, ExplosiveBarrel.ARM_SPEED_MPS), "the arm distance is where the shock speed share equals the arm speed")
	_check(ExplosiveBarrel.arm_distance_m(6.0, ExplosiveBarrel.ARM_SPEED_MPS - 0.1) < 0.0, "a shock slower than the arm speed never arms")
	var reach := ExplosiveBarrel.chain_reach_m(BARREL_CHARGE.blast_radius_m, BARREL_CHARGE.blast_speed_mps, BARREL_CHARGE.radius_m)
	var rise := BARREL_CHARGE.radius_m - ExplosiveBarrel.HEIGHT_M * 0.5
	_check(is_equal_approx(reach * reach + rise * rise, arm * arm), "the ground reach and the burst rise make up the arm distance")
	_check(ExplosiveBarrel.chain_reach_m(6.0, 1.0, 1.2) == 0.0, "no reach when the shock is too slow")
	_check(ExplosiveBarrel.chain_reach_m(6.0, 9.0, 1.2) > ExplosiveBarrel.chain_reach_m(6.0, 7.0, 1.2), "a stronger shock reaches further")
	var pairs := ExplosionBarrelYard.cluster_points(Vector2.ZERO)
	_check(pairs.size() == ExplosionBarrelYard.CLUSTER_SIZE and pairs[0].distance_to(pairs[1]) >= ExplosiveBarrel.RADIUS_M * 2.0 + ExplosionBarrelYard.BARREL_GAP_M,
		"cluster barrels do not overlap")
	var gap := ExplosionBarrelYard.DEFAULT_CLUSTERS_M[0].distance_to(ExplosionBarrelYard.DEFAULT_CLUSTERS_M[1]) \
		- ExplosionBarrelYard.CLUSTER_SPACING_M * sqrt(2.0)
	_check(gap < reach, "default clusters sit inside each other's chain reach")
	_completed += 1


func _test_nuke_front() -> void:
	var nuke := ExplosionScenery.NUKE_CHARGE
	var dust := nuke.companion
	var dome := dust.companion
	var config := ExplosionScenery.MUSHROOM_CONFIG
	var system := ExplosionSystem.new()
	system.config = config
	var form := nuke.formation_s
	var r0 := nuke.radius_m
	_check(nuke.grows() and nuke.formation_offset_s > 0.0 and nuke.validate() == "" and system.refusal(nuke) == "", "the nuke grows with an offset law and is accepted")
	_check(ExplosionSystem.kernel_radius_m(nuke, 0.0) == r0 and is_equal_approx(ExplosionSystem.kernel_radius_m(nuke, form), nuke.final_radius_m()), "the offset law runs from radius_m to the final radius")
	_check(nuke.final_radius_m() >= 120.0 and r0 >= 2.0 * config.cell_size_m and form >= 0.5 and form <= 1.0, "the nuke starts at 2+ cells, ends at 120 m or more, and forms in 0.5 to 1 s")
	var step_s := 1.0 / float(config.simulation_hz)
	var first := (ExplosionSystem.kernel_radius_m(nuke, step_s) - r0) / step_s
	var plain := nuke.duplicate() as ExplosionCharge
	plain.formation_offset_s = 0.0
	var plain_first := (ExplosionSystem.kernel_radius_m(plain, step_s) - r0) / step_s
	_check(first <= config.velocity_clamp_mps and plain_first > config.velocity_clamp_mps, "the offset keeps the first step under the clamp where the plain law blows past it")
	var previous := r0
	var fast_then_slow := true
	var last_gain := INF
	for i in range(1, int(form / step_s) + 2):
		var radius := ExplosionSystem.kernel_radius_m(nuke, float(i) * step_s)
		var gain := radius - previous
		fast_then_slow = fast_then_slow and gain >= -1e-9 and gain <= last_gain + 1e-9
		previous = radius
		last_gain = gain
	_check(fast_then_slow, "every step grows the sphere by no more than the one before")
	for charge: ExplosionCharge in [FIREBALL_CHARGE, BARREL_CHARGE]:
		var same := true
		for i in 41:
			var age := float(i) * charge.formation_s * 0.03
			var progress := clampf(age / charge.formation_s, 0.0, 1.0)
			var old := charge.radius_m * (1.0 + (charge.growth_ratio - 1.0) * pow(progress, 0.4))
			same = same and ExplosionSystem.kernel_radius_m(charge, age) == old
		_check(same, "a charge without an offset keeps the plain t^0.4 law to the last bit")
	var bad := FIREBALL_CHARGE.duplicate() as ExplosionCharge
	bad.growth_ratio = 1.0
	bad.formation_s = 0.0
	bad.divergence_per_s = 1.0
	bad.formation_offset_s = 0.1
	_check(bad.validate() != "", "an offset without growth is refused")
	var front := Vector2(343.0, 120.0)
	_check(dust.has_front_ring() and dust.front_ring_lift_mps > 0.0 and dust.continuous and dome != null and not dome.has_front_ring() and dome.onset_s > 0.0 and dust.validate() == "", "the nuke's companion is a front ring that releases an onset dome")
	_check(ExplosionSystem.front_ring_radius_m(dust, front, 0.0) == 120.0 and is_equal_approx(ExplosionSystem.front_ring_radius_m(dust, front, 1.0), 463.0), "the ring starts at the fireball and rides the front")
	_check(ExplosionSystem.front_ring_radius_m(dust, front, 100.0) == dust.radius_m, "the ring stops at its cap")
	_check(is_equal_approx(ExplosionSystem.front_ring_duration_s(dust, front), (dust.radius_m - 120.0) / 343.0), "the ring takes cap minus start over the front speed to arrive")
	var reach := ExplosionSystem.front_ring_reach_m(dust, front, 1.0)
	_check(is_equal_approx(reach, 463.0 + dust.front_ring_width_m + dust.front_ring_height_m), "the reach covers the band and its height")
	_check(dust.front_ring_width_m >= 3.0 * config.cell_size_m, "the ring is at least 3 cells wide")
	var open := dust.duplicate() as ExplosionCharge
	open.front_ring_height_m = 0.0
	_check(open.validate() != "", "a front ring needs a height")
	open = dust.duplicate() as ExplosionCharge
	open.continuous = false
	_check(open.validate() != "", "a front ring must be continuous")
	open = dome.duplicate() as ExplosionCharge
	open.afterwind_delay_s = open.pulse_duration_s
	_check(open.validate() != "", "an afterwind delay must be shorter than the pulse")
	var scaled := ExplosionActions.scaled_charge(nuke, 0.5)
	_check(is_equal_approx(scaled.companion.front_ring_width_m, dust.front_ring_width_m * 0.5) and is_equal_approx(scaled.companion.front_ring_height_m, dust.front_ring_height_m * 0.5), "the charge scale shrinks the ring band")
	system.solver = FireGpuSolver.new()
	var speed := system.blast_speed_mps(nuke)
	system.detonate(Vector3(0.0, 180.0, 0.0), nuke)
	system.advance(0.0)
	system.advance(0.0)
	var slot := 1
	_check(system.solver._blast_ring[slot] == Vector4(nuke.final_radius_m(), dust.front_ring_width_m, dust.front_ring_height_m, 0.0), "the companion's ring row starts at the fireball radius")
	_check(system.solver._blast_ring[0] == Vector4.ZERO, "the nuke itself uploads no ring")
	system.advance(0.1)
	system.advance(0.1)
	var ring: Vector4 = system.solver._blast_ring[slot]
	_check(is_equal_approx(ring.x, nuke.final_radius_m() + speed * 0.1) and is_equal_approx(system.solver._blast[slot].w, ring.x + dust.front_ring_width_m), "the ring rides the front speed of the charge that released it")
	_check(is_equal_approx(system.solver._blast_rate[slot].w, dust.soot_fraction), "a step of at least the reference time deposits the full soot fraction")
	system.advance(0.01)
	system.advance(0.01)
	_check(is_equal_approx(system.solver._blast_rate[slot].w, dust.soot_fraction * 0.01 / ExplosionSystem.FRONT_RING_REFERENCE_DT_S), "a shorter step deposits in proportion to the simulated time")
	_check(system.solver._afterwind[0].z == 0.0, "no afterwind while the front passes")
	system.advance(1.0)
	system.advance(1.0)
	system.advance(0.0)
	_check(system.solver._blast_rate[slot].x == 0.0 and system.solver._blast_ring[slot].x == dust.radius_m, "the ring stops dusting once it reaches its cap")
	var early: Vector4 = system.solver._blast_rate[2]
	_check(early.w > 0.0 and early.w < 0.5 * dome.soot_fraction and early.y > system.solver.ambient_temperature and early.y < dome.temperature_k, "the dome's soot and heat are part way up their onset ramp")
	system.advance(dome.onset_s)
	system.advance(0.0)
	var full: Vector4 = system.solver._blast_rate[2]
	_check(is_equal_approx(full.w, dome.soot_fraction) and is_equal_approx(full.y, dome.temperature_k), "the dome reaches full strength after onset_s")
	system.advance(4.0)
	system.advance(0.0)
	_check(system.solver._afterwind[0].z > 0.5 * dome.afterwind_mps, "the afterwind blows once its delay has passed")
	system.free()
	_completed += 1


func _test_refusal_rules() -> void:
	var nuke := ExplosionScenery.NUKE_CHARGE
	var ring := nuke.companion
	var system := ExplosionSystem.new()
	system.config = ExplosionScenery.MUSHROOM_CONFIG
	_check(system.refusal(nuke) == "", "the nuke and its ring are accepted")
	var slow := ring.duplicate() as ExplosionCharge
	slow.pulse_duration_s = 0.5 * system.front_ring_duration_s(ring, Vector2(system.blast_speed_mps(nuke), nuke.final_radius_m()))
	slow.onset_s = 0.0
	slow.companion = null
	var parent := nuke.duplicate() as ExplosionCharge
	parent.companion = slow
	_check(slow.validate() == "" and system.refusal(parent) != "", "a ring that cannot reach its cap within its pulse is refused")
	var head := ring.duplicate() as ExplosionCharge
	head.companion = null
	_check(head.validate() == "" and system.refusal(head) != "", "a front ring on a head charge has no front and is refused")
	var limit := system.max_charge_scale(nuke)
	var at_limit := ExplosionActions.scaled_charge(nuke, limit * 0.999)
	var past_limit := ExplosionActions.scaled_charge(nuke, limit * 1.05)
	_check(limit > 0.0 and limit < INF and system.refusal(at_limit) == "" and system.refusal(past_limit) != "", "max_charge_scale is the largest scale refusal still accepts")
	system.blast_force_scale = 0.85
	var slow_limit := system.max_charge_scale(nuke)
	_check(slow_limit < limit and system.refusal(ExplosionActions.scaled_charge(nuke, slow_limit * 0.999)) == "" and system.refusal(ExplosionActions.scaled_charge(nuke, slow_limit * 1.05)) != "", "a slower front lowers the largest accepted scale")
	system.blast_force_scale = 1.0
	var late := ring.duplicate() as ExplosionCharge
	late.onset_s = late.pulse_duration_s
	_check(late.validate() != "", "an onset that never ends before the pulse does is refused")
	var sunk := ring.duplicate() as ExplosionCharge
	sunk.sink_m = 10.0
	_check(sunk.validate() != "", "a front ring on the ground cannot sink")
	var loop := ring.duplicate() as ExplosionCharge
	loop.companion = null
	loop.front_ring_width_m = 0.0
	loop.companion = loop
	_check(not loop.chain_is_finite() and loop.validate() != "" and system.refusal(loop) != "", "a companion loop is refused instead of hanging refusal")
	_check(system.max_charge_scale(loop) > 0.0, "a companion loop does not hang max_charge_scale")
	_check(ExplosionActions.scaled_charge(loop, 0.5) != null, "a companion loop does not hang scaled_charge")
	loop.companion = null
	system.free()
	_completed += 1
