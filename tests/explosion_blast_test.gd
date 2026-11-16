extends "res://tests/test_case.gd"
## No GPU: the queue is driven through a solver that was never initialised.

const RANGE_CONFIG := preload("res://resources/explosion/presets/range.tres")
const FIREBALL_RANGE_CONFIG := preload("res://resources/explosion/presets/fireball_range.tres")
const BARREL_CHARGE := preload("res://resources/explosion/presets/barrel_charge.tres")
const FIREBALL_CHARGE := preload("res://resources/explosion/presets/fireball_charge.tres")
const TEST_COUNT := 12

var _completed := 0


func _initialize() -> void:
	await process_frame
	_test_impulse_law()
	_test_barrel_fuse()
	_test_validation()
	_test_queue()
	_test_click_and_clock()
	_test_barrel_routing()
	_test_charge_scale()
	_test_settings_rules()
	_test_framing()
	_test_dust_ring()
	_test_presets()
	_test_pace()
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
	strong.divergence_per_s = 500.0
	strong.radius_m = 5.0
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
	_completed += 1


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
	_check(is_equal_approx(Engine.time_scale, base) and Engine.physics_ticks_per_second == ticks * 2,
		"the demo starts at the base pace with the physics tick rate raised to match")
	_check(is_equal_approx(actions.cycle_slow(), 0.5) and is_equal_approx(Engine.time_scale, 1.0)
		and Engine.physics_ticks_per_second == ticks, "slow 0.5x runs the engine clock at 1, the pace before the base was raised")
	actions.set_paused(true)
	_check(Engine.time_scale == 0.0, "pause stops the engine clock")
	actions.set_paused(false)
	_check(is_equal_approx(Engine.time_scale, 1.0), "resume returns to the chosen slow scale")
	_check(is_equal_approx(actions.cycle_slow(), 0.25) and is_equal_approx(Engine.time_scale, 0.5)
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
	for i in ExplosionDustRing.MAX_RINGS + 4:
		system.detonated.emit(Vector3(float(i), 1.0, 0.0), BARREL_CHARGE)
	_check(ring._rings.size() == ExplosionDustRing.MAX_RINGS, "concurrent rings are capped")
	var speed_before: float = ring._rings[-1].speed_mps
	system.blast_force_scale = 1.5
	system.detonated.emit(Vector3.ZERO, BARREL_CHARGE)
	_check(is_equal_approx(ring._rings[-1].speed_mps, BARREL_CHARGE.blast_speed_mps * 1.5)
		and is_equal_approx(speed_before, BARREL_CHARGE.blast_speed_mps), "the ring travels at the force-scaled blast speed")
	ring.clear()
	_check(ring._rings.is_empty(), "clear drops every ring")
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
			"%d Hz runs %d steps in 120 frames at %.0fx with nothing dropped" % [config.simulation_hz, steps, base])
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
