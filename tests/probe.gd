extends "res://tests/test_case.gd"

## The project's single probe entry point: every probe is a `_run_<name>`
## method here, dispatched by tests/probe.sh (setsid + timeout + group kill on
## an isolated virtual Wayland display) or directly by the GPU phase of
## tests/run_tests.sh. `tests/probe.sh list` prints the names. Only
## tornado_boot_look (frame-driven) and fps (boots its scene here) dispatch
## outside the _run_<name> convention.

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const GRASS_HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")

# fluid_foam / fluid_tier frame guards: sim normally advances 60 steps per
# wall second; allow a 4x slowdown before the guard cuts the wait.
const GUARD_FRAMES_PER_SECOND := 240.0

# fluid_foam
const WARM_SIM := 2.0
const COHORT := 2000
const COHORT_LIFE := 1.0
const COHORT_RADIUS := 6.0
const INJECT_CHECK_SIM := 0.034 # ~2 frames: cohort must exist before aging kills it
const RESIDUE_SIM := 2.0
const INJECT_MIN_ALIVE := 1800
const PASS_MAX_ALIVE := 1000

# fluid_resize
const FLU3_OUT_DIR := "res://tmp/flu3"
const FLU3_SETTLE_FRAMES := 240

# fluid_tier
const TIER_DEMO := "res://scenes/fluid_demo.tscn"
const TIER_INIT_TIMEOUT_MS := 30000
const TIER_SOAK_SIM := 1.0

# fractal_policy
const POLICY_W := 1280
const POLICY_H := 720
const POLICY_LN10 := 2.302585092994046
const POLICY_OUT_DIR := "res://tmp/policy"
const POLICY_NOTCHES := 12
const POLICY_NOTCH_FRAMES := 12

# fractal_zoom
const VIEW_BASE := 1.75
const BAILOUT2 := 65536.0
const VIEW_W := 1280
const VIEW_H := 720
const SAMPLE_STEP := 12
const JULIA_RE := -0.7269
const JULIA_IM := 0.1889

# grass
const GRASS_SAMPLE_FRAMES := 120
const TIER_DENSITY := 0.7 # GrassQualityProfile MEDIUM, the tier the probe pins
const DENSITY_KEY := "🌿 Grass Properties/Density"

# mixopt
const CHURN_FRAMES := 120
const MAX_IDLE_BUILDS := 2

# tornado_boot_look
const GROUND_SHADER_PATH := "res://shaders/tornado/tornado_ground.gdshader"

# fps
const TIER_NAMES := ["low", "medium", "high", "ultra"]

# foam_convergence
const CONV_SAMPLE_FRAMES := [60, 180, 600, 1800, 3600]
const FIXED_DT := 1.0 / 30.0

var _probe := ""
var _extra: PackedStringArray = []

# tornado_boot_look (_process polling) and fps (_initialize boot)
var _frames := 0
var _demo: Node = null

# fps
var _scene_path := ""
var _tier := -1
var _seconds := 5.0
var _size := Vector2i(1920, 1080)
var _warmup := 90
var _fps_bodies := 0
var _fps_medium := -1
var _fps_settle_seconds := 0.0

# fractal_policy
var _fails := 0

# fractal_zoom
var _targets: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("probe: missing name; run tests/probe.sh list")
		quit(1)
		return
	_probe = args[0]
	_extra = args.slice(1)
	match _probe:
		"tornado_boot_look":
			_demo = (load("res://scenes/tornado_demo.tscn") as PackedScene).instantiate()
			root.add_child(_demo)
		"fps":
			if not _fps_parse_args():
				return
			var packed := load(_scene_path) as PackedScene
			if packed == null:
				push_error("FPS PROBE FAIL: cannot load %s" % _scene_path)
				quit(1)
				return
			root.size = _size
			_demo = packed.instantiate()
			root.add_child(_demo)
			call_deferred("_run_fps")
		_:
			var method := "_run_" + _probe
			if not has_method(method):
				push_error("probe: unknown name %s; run tests/probe.sh list" % _probe)
				quit(1)
				return
			call_deferred(method)


func _process(_delta: float) -> bool:
	if _probe != "tornado_boot_look":
		return false
	_frames += 1
	if _frames < 3:
		return false
	_check_boot_look()
	_finish("tornado_boot_look")
	return true


func _boot_frames(count: int) -> void:
	for i in count:
		await process_frame


func _run_nbody_numeric() -> void:
	await _boot_frames(2)
	var solver := NBodySolver.new()
	solver.particle_count = 1
	solver.tex_width = 1
	solver.substeps = 1
	solver.dt = 0.1
	solver.gravity_constant = 1.0
	solver.softening = 0.1
	solver.attractor_softening = 0.04
	solver.disk_mass = 0.0
	solver.escape_radius = 100.0
	solver.config.self_gravity_max_particles = 2
	solver.set_seed(PackedFloat32Array([2.0, 0.0, 0.0, 0.0]),
		PackedFloat32Array([0.0, 1.0, 0.0, 0.0]))
	solver.set_attractors([{
		pos = Vector3.ZERO, vel = Vector3.ZERO, mass = 0.5, radius = 0.2,
	}])
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: solver failed to initialize")
		await _nbody_free_render(solver)
		_finish("nbody_numeric")
		return
	var state := await _nbody_sample(solver)
	_check(state.has("texture") and state.texture.size() == 4
		and is_equal_approx(state.texture[0], 2.0),
		"nbody_numeric: init did not publish the seed position texture")
	if state.has("positions"):
		_check(is_equal_approx(state.positions[0], 2.0),
			"nbody_numeric: init changed the seeded x position")

	var static_source: Array = [{
		pos = Vector3.ZERO, vel = Vector3.ZERO, mass = 0.5, radius = 0.2,
	}]
	var expected_half := Vector3(2.0, 0.05, 0.0)
	var pull := -expected_half * (0.5 / pow(expected_half.length_squared()
		+ solver.attractor_softening * solver.attractor_softening, 1.5))
	var expected_velocity := Vector3(0.0, 1.0, 0.0) + pull * 0.1
	var expected_position := expected_half + expected_velocity * 0.05
	await _nbody_step(solver, 0.1, [static_source, static_source, static_source])
	state = await _nbody_sample(solver)
	if state.has("positions") and state.has("velocities"):
		var actual_position := Vector3(state.positions[0], state.positions[1],
			state.positions[2])
		var actual_velocity := Vector3(state.velocities[0], state.velocities[1],
			state.velocities[2])
		_check(actual_position.distance_to(expected_position) < 1e-5,
			"nbody_numeric: test-particle DKD position differs from midpoint-force result")
		_check(actual_velocity.distance_to(expected_velocity) < 1e-5,
			"nbody_numeric: test-particle DKD velocity differs from midpoint-force result")

	await _nbody_free_render(solver)
	solver.set_seed(PackedFloat32Array([0.0, 0.0, 0.0, 0.0]),
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: moving-source solver failed to initialize")
		await _nbody_free_render(solver)
		_finish("nbody_numeric")
		return
	var moving_source: Array = [
		{pos = Vector3(-2.0, 0.0, 0.0), vel = Vector3(4.0, 0.0, 0.0), mass = 0.0, radius = 0.5},
		{pos = Vector3.ZERO, vel = Vector3(4.0, 0.0, 0.0), mass = 0.0, radius = 0.5},
		{pos = Vector3(2.0, 0.0, 0.0), vel = Vector3(4.0, 0.0, 0.0), mass = 0.0, radius = 0.5},
	]
	solver.attractor_softening = 0.04
	var moving_timeline: Array = [[moving_source[0]], [moving_source[1]], [moving_source[2]]]
	await _nbody_step(solver, 1.0, moving_timeline)
	state = await _nbody_sample(solver)
	if state.has("positions"):
		var absorbed_position := Vector3(state.positions[0], state.positions[1],
			state.positions[2])
		_check(absorbed_position.length() > 1.0,
			"nbody_numeric: particle crossed a moving absorb sphere without respawning")

	await _nbody_free_render(solver)
	solver.particle_count = 2
	solver.tex_width = 2
	solver.dt = 0.01
	solver.self_gravity = true
	solver.set_attractors([])
	solver.set_seed(PackedFloat32Array([-1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0]),
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
	var pair_pull: float = 2.0 / pow(4.0 + solver.softening * solver.softening, 1.5)
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: self-gravity solver failed to initialize")
	else:
		var empty_source: Array = []
		await _nbody_step(solver, 0.01, [empty_source, empty_source, empty_source])
		state = await _nbody_sample(solver)
		if state.has("positions") and state.has("velocities"):
			var expected_vx := pair_pull * 0.01
			var expected_x := -1.0 + expected_vx * 0.005
			_check(absf(state.velocities[0] - expected_vx) < 1e-6
				and absf(state.positions[0] - expected_x) < 1e-6,
				"nbody_numeric: pair-force barrier/DKD result differs from two-body reference")
	await _nbody_free_render(solver)
	solver.gravity_constant = 2.0
	solver.set_seed(
		PackedFloat32Array([-1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0]),
		PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: scaled-G pair solver failed to initialize")
	else:
		await _nbody_step(solver, 0.01, [[], [], []])
		state = await _nbody_sample(solver)
		if state.has("positions") and state.has("velocities"):
			var expected_scaled_vx := pair_pull * 2.0 * 0.01
			var expected_scaled_x := -1.0 + expected_scaled_vx * 0.005
			_check(absf(state.velocities[0] - expected_scaled_vx) < 1e-6
				and absf(state.positions[0] - expected_scaled_x) < 1e-6,
				"nbody_numeric: pair-force integration did not scale with G")
	await _nbody_free_render(solver)

	# With Plummer softening the self term has r = 0, so it contributes no force.
	solver.particle_count = 1
	solver.tex_width = 1
	solver.substeps = 1
	solver.dt = 0.1
	solver.softening = 0.1
	solver.gravity_constant = 2.0
	solver.escape_radius = 100.0
	solver.disk_mass = 0.0
	solver.self_gravity = true
	solver.set_attractors([])
	solver.set_seed(PackedFloat32Array([5.0, 0.0, 0.0, 1.0]),
		PackedFloat32Array([1.0, 2.0, 0.0, 0.0]))
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: self-force solver failed to initialize")
	else:
		await _nbody_step(solver, 0.1, [[], [], []])
		state = await _nbody_sample(solver)
		if state.has("positions") and state.has("velocities"):
			_check(absf(state.positions[0] - 5.1) < 1e-6
				and absf(state.velocities[0] - 1.0) < 1e-6
				and absf(state.velocities[1] - 2.0) < 1e-6,
				"nbody_numeric: softened one-particle self-force must be zero")
	await _nbody_free_render(solver)

	# Pairwise re-emissions use the initial frame seed and the substep salt. Replays
	# from the same seed match, while the second swallowed substep gets a new sample.
	solver.substeps = 2
	solver.dt = 0.001
	solver.gravity_constant = 1.0
	solver.random_seed = 7
	solver.respawn_mode = 0
	solver.disk_r_min = 2.0
	solver.disk_r_max = 4.0
	solver.disk_thickness = 0.3
	solver.dispersion = 0.0
	solver.escape_radius = 1000.0
	var absorber: Dictionary = {
		pos = Vector3.ZERO, vel = Vector3.ZERO, mass = 0.0, radius = 100.0,
	}
	solver.set_attractors([absorber])
	var respawn_seed_pos := PackedFloat32Array([0.0, 0.0, 0.0, 1.0])
	var respawn_seed_vel := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	solver.set_seed(respawn_seed_pos, respawn_seed_vel)
	RenderingServer.call_on_render_thread(solver.init_render)
	var pair_respawn_two := PackedFloat32Array()
	var pair_respawn_replay := PackedFloat32Array()
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: pairwise respawn solver failed to initialize")
	else:
		await _nbody_step(solver, 0.001, [[absorber], [absorber], [absorber],
			[absorber], [absorber]])
		state = await _nbody_sample(solver)
		pair_respawn_two = state.get("positions", PackedFloat32Array())
	await _nbody_free_render(solver)
	solver.set_seed(respawn_seed_pos, respawn_seed_vel)
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: pairwise replay solver failed to initialize")
	else:
		await _nbody_step(solver, 0.001, [[absorber], [absorber], [absorber],
			[absorber], [absorber]])
		state = await _nbody_sample(solver)
		pair_respawn_replay = state.get("positions", PackedFloat32Array())
		_check(pair_respawn_two == pair_respawn_replay,
			"nbody_numeric: same frame seed must reproduce pairwise respawns")
	await _nbody_free_render(solver)
	solver.substeps = 1
	solver.set_seed(respawn_seed_pos, respawn_seed_vel)
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: single-substep respawn solver failed to initialize")
	else:
		await _nbody_step(solver, 0.001, [[absorber], [absorber], [absorber]])
		state = await _nbody_sample(solver)
		var pair_respawn_one: PackedFloat32Array = state.get(
			"positions", PackedFloat32Array())
		_check(pair_respawn_two.size() == 4 and pair_respawn_one.size() == 4
			and Vector3(pair_respawn_two[0], pair_respawn_two[1], pair_respawn_two[2])
				.distance_to(Vector3(pair_respawn_one[0], pair_respawn_one[1],
					pair_respawn_one[2])) > 1e-4,
			"nbody_numeric: pairwise respawns in successive substeps must use distinct salts")
	await _nbody_free_render(solver)

	solver.substeps = NBodySolver.MAX_SUBSTEPS
	solver.particle_count = 2
	solver.tex_width = 2
	solver.gravity_constant = 1.0
	solver.random_seed = 0
	solver.self_gravity = true
	var circular_speed := sqrt(2.0 / pow(4.0 + solver.softening * solver.softening, 1.5))
	var orbit_step_count := NBodySolver.MAX_SUBSTEPS * 4
	var orbit_step_dt := TAU / (circular_speed * float(orbit_step_count))
	solver.dt = orbit_step_dt
	solver.set_seed(
		PackedFloat32Array([-1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0]),
		PackedFloat32Array([0.0, circular_speed, 0.0, 0.0,
			0.0, -circular_speed, 0.0, 0.0]))
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: circular-orbit solver failed to initialize")
	else:
		var orbit_samples: Array = []
		for _sample in NBodySolver.MAX_SUBSTEPS * 2 + 1:
			orbit_samples.append([])
		for _orbit_chunk in 4:
			await _nbody_step(solver, orbit_step_dt, orbit_samples)
		state = await _nbody_sample(solver)
		if state.has("positions") and state.has("velocities"):
			var relative_position := Vector3(state.positions[0] - state.positions[4],
				state.positions[1] - state.positions[5],
				state.positions[2] - state.positions[6])
			var first_velocity := Vector3(state.velocities[0], state.velocities[1],
				state.velocities[2])
			var second_velocity := Vector3(state.velocities[4], state.velocities[5],
				state.velocities[6])
			var total_energy := 0.5 * (first_velocity.length_squared()
				+ second_velocity.length_squared()) - 1.0 / sqrt(
				relative_position.length_squared() + solver.softening * solver.softening)
			var initial_energy := circular_speed * circular_speed - 1.0 / sqrt(
				4.0 + solver.softening * solver.softening)
			var angular_momentum := relative_position.cross(
				first_velocity - second_velocity).z
			print("NBODY ORBIT energy=%.8f initial=%.8f angular=%.8f initial_angular=%.8f" % [
				total_energy, initial_energy, angular_momentum, 4.0 * circular_speed])
			_check(absf((total_energy - initial_energy) / initial_energy) < 1e-3,
				"nbody_numeric: DKD energy drift exceeded 0.1% over one circular orbit")
			_check(absf(absf(angular_momentum) - 4.0 * circular_speed) < 1e-5,
				"nbody_numeric: central pair force failed to conserve angular momentum")
	await _nbody_free_render(solver)
	await _test_nbody_firework_output()
	_finish("nbody_numeric")


func _test_nbody_firework_output() -> void:
	var solver := NBodySolver.new()
	solver.particle_count = 2048
	solver.tex_width = 64
	solver.substeps = 2
	solver.dt = 0.075
	solver.random_seed = 0
	var scene := FireworkScene.new()
	scene.period = 40.0
	scene.rockets = 16.0
	scene.burst_speed = 20.0
	scene.gravity_strength = 3.0
	scene.spread = 50.0
	scene.air_drag = 0.1
	scene.normalize_params()
	scene.apply_defaults(solver)
	var seed := scene.seed(solver.particle_count, solver, solver.random_seed)
	solver.set_seed(seed.positions, seed.velocities)
	RenderingServer.call_on_render_thread(solver.init_render)
	if not await _nbody_wait_initialized(solver):
		_check(false, "nbody_numeric: maximum-firework solver failed to initialize")
		await _nbody_free_render(solver)
		return
	var empty_samples: Array = []
	var axes: Array[Vector3] = []
	for _sample in solver.substeps * 2 + 1:
		empty_samples.append([])
		axes.append(Vector3.UP)
	var constants := solver.make_step_constants(solver.dt, 0.0)
	var packed_samples := solver.pack_attractor_samples(empty_samples, axes)
	RenderingServer.call_on_render_thread(
		solver.step_render.bind(constants, packed_samples)
	)
	await process_frame
	var state := await _nbody_sample(solver)
	var positions: PackedFloat32Array = state.get("positions", PackedFloat32Array())
	var valid_positions := positions.size() == solver.particle_count * 4
	var moved_count := 0
	var bounds := scene.render_bounds(solver, [])
	if valid_positions:
		for i in solver.particle_count:
			var offset := i * 4
			if not is_finite(positions[offset]) or not is_finite(positions[offset + 1]) \
					or not is_finite(positions[offset + 2]):
				valid_positions = false
			var p := Vector3(positions[offset], positions[offset + 1], positions[offset + 2])
			if p.length_squared() > 0.01:
				moved_count += 1
			if p.x < bounds.position.x or p.y < bounds.position.y or p.z < bounds.position.z \
					or p.x > bounds.end.x or p.y > bounds.end.y or p.z > bounds.end.z:
				valid_positions = false
	_check(moved_count > solver.particle_count * 0.9,
		"nbody_numeric: maximum-firework compute must publish analytic positions")
	_check(valid_positions,
		"nbody_numeric: maximum firework positions must stay finite")
	await _nbody_free_render(solver)


func _run_nbody_perf() -> void:
	await _boot_frames(3)
	var adapter := RenderingServer.get_video_adapter_name()
	var has_samples := true
	var p95_by_count: Dictionary = {}
	for count in [4096, 8192, 16384, 32768]:
		var solver := NBodySolver.new()
		solver.particle_count = count
		solver.tex_width = ceili(sqrt(float(count)))
		solver.self_gravity = true
		solver.config.self_gravity_max_particles = count
		solver.substeps = 2
		solver.dt = 0.075
		solver.softening = 0.12
		solver.escape_radius = 1000000.0
		solver.profiling = true
		var positions := PackedFloat32Array()
		var velocities := PackedFloat32Array()
		positions.resize(count * 4)
		velocities.resize(count * 4)
		velocities.fill(0.0)
		for i in count:
			var angle := float(i) * 2.399963229728653
			var radius := 10.0 + 0.1 * sqrt(float(i))
			positions[i * 4] = cos(angle) * radius
			positions[i * 4 + 1] = sin(angle) * radius
			positions[i * 4 + 2] = 0.05 * sin(angle * 0.37)
			positions[i * 4 + 3] = 1.0
		solver.set_seed(positions, velocities)
		solver.set_attractors([])
		RenderingServer.call_on_render_thread(solver.init_render)
		if not await _nbody_wait_initialized(solver):
			_check(false, "nbody_perf: %d-particle solver failed to initialize" % count)
			await _nbody_free_render(solver)
			has_samples = false
			break

		var source_samples: Array = []
		for _sample in solver.substeps * 2 + 1:
			source_samples.append([])
		var timings: Array[float] = []
		var frame_times: Array[float] = []
		var last_timestamp_frame := -1
		var deadline := Time.get_ticks_msec() + 180000
		var sent_steps := 0
		while timings.size() < 20 and Time.get_ticks_msec() < deadline:
			var step_start_usec := Time.get_ticks_usec()
			await _nbody_step(solver, solver.dt, source_samples)
			var frame_ms := float(Time.get_ticks_usec() - step_start_usec) / 1000.0
			sent_steps += 1
			var timing_state := await _nbody_read_perf_timing(solver)
			var timestamp_frame := int(timing_state.get("frame", -1))
			var total_ms := float(timing_state.get("timings", {}).get("total", 0.0))
			if timestamp_frame > last_timestamp_frame and total_ms > 0.0:
				last_timestamp_frame = timestamp_frame
				if sent_steps > 3:
					timings.append(total_ms)
					frame_times.append(frame_ms)
		if timings.size() < 20:
			_check(false, "nbody_perf: only collected %d of 20 samples at %d particles" % [
				timings.size(), count,
			])
			has_samples = false
		else:
			timings.sort()
			var p95_ms := timings[ceili(float(timings.size()) * 0.95) - 1]
			p95_by_count[count] = p95_ms
			frame_times.sort()
			var p95_cpu_wait_ms := frame_times[ceili(float(frame_times.size()) * 0.95) - 1]
			print("NBODY PERF adapter=%s count=%d p95_ms=%.3f p95_cpu_wait_ms=%.3f limit_ms=33 pass=%s samples=%d" % [
				adapter, count, p95_ms, p95_cpu_wait_ms, str(p95_ms <= 33.0), timings.size(),
			])
		await _nbody_free_render(solver)
		if not has_samples:
			break
	if has_samples:
		var ultra_count: int = NBodyQualityProfile.PARTICLE_COUNT[SimQualityProfile.Tier.ULTRA]
		var ultra_p95_ms := float(p95_by_count.get(ultra_count, -1.0))
		_check(ultra_p95_ms > 0.0 and ultra_p95_ms <= 33.0,
			"nbody_perf: selected Ultra count %d p95 is %.3f ms; limit is 33 ms" % [
				ultra_count, ultra_p95_ms,
			])
	_check(has_samples, "nbody_perf: failed to collect all required GPU timing samples")
	_finish("nbody_perf")


func _nbody_read_perf_timing(solver: NBodySolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_nbody_perf_timing.bind(solver, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(result.get("done", false), "nbody_perf: GPU timestamp read timed out")
	return result


func _read_nbody_perf_timing(solver: NBodySolver, result: Dictionary) -> void:
	result["frame"] = solver._rd.get_captured_timestamps_frame()
	result["timings"] = GpuTimings.read(solver._rd, "nbody/")
	result["done"] = true


func _nbody_wait_initialized(solver: NBodySolver) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while not solver.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	return solver.initialized


func _nbody_free_render(solver: NBodySolver) -> void:
	var result := {}
	RenderingServer.call_on_render_thread(func():
		solver.free_render()
		result["done"] = true
	)
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(result.get("done", false), "nbody_numeric: solver teardown timed out")


func _nbody_step(solver: NBodySolver, step_dt: float, samples: Array) -> void:
	var axes: Array[Vector3] = []
	for _sample in samples:
		axes.append(Vector3.UP)
	var packed_samples := solver.pack_attractor_samples(samples, axes)
	var constants := solver.make_step_constants(step_dt, 0.0)
	RenderingServer.call_on_render_thread(solver.step_render.bind(constants, packed_samples))
	await process_frame


func _nbody_sample(solver: NBodySolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_nbody_state.bind(solver, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(result.get("done", false), "nbody_numeric: GPU readback timed out")
	return result


func _read_nbody_state(solver: NBodySolver, result: Dictionary) -> void:
	result["positions"] = solver._rd.buffer_get_data(solver._buffers["positions"]).to_float32_array()
	result["velocities"] = solver._rd.buffer_get_data(solver._buffers["velocities"]).to_float32_array()
	result["texture"] = solver._rd.texture_get_data(solver._tex_rid, 0).to_float32_array()
	result["done"] = true


func _run_ocean_freeze() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	demo.quality.fallback_tier = OceanQualityProfile.Tier.LOW
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready(), "ocean_freeze: ocean did not initialize")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("ocean_freeze")
		return
	var foam: OceanFoamWindow = demo.foam_window
	_check(foam._enabled and foam._ocean_bound, "ocean_freeze: interaction foam is inactive")
	demo.set_frozen(false)
	demo.set_time_scale(1.0)
	await _boot_frames(2)
	var live_material: ShaderMaterial = foam._feedback_materials[(foam._frame - 1) & 1]
	var live_decay := float(live_material.get_shader_parameter("decay"))
	_check(live_decay < 1.0
		and float(live_material.get_shader_parameter("injection_strength")) > 0.0,
		"ocean_freeze: live interaction foam did not advance")
	demo.set_frozen(true)
	await _boot_frames(2)
	var frozen_material: ShaderMaterial = foam._feedback_materials[(foam._frame - 1) & 1]
	_check(is_equal_approx(float(frozen_material.get_shader_parameter("decay")), 1.0)
		and is_zero_approx(float(frozen_material.get_shader_parameter("blur_amount")))
		and is_zero_approx(float(frozen_material.get_shader_parameter("injection_strength"))),
		"ocean_freeze: paused waves still evolve interaction foam")
	demo.set_frozen(false)
	demo.set_time_scale(0.0)
	await _boot_frames(2)
	var paused_material: ShaderMaterial = foam._feedback_materials[(foam._frame - 1) & 1]
	_check(is_equal_approx(float(paused_material.get_shader_parameter("decay")), 1.0)
		and is_zero_approx(float(paused_material.get_shader_parameter("blur_amount")))
		and is_zero_approx(float(paused_material.get_shader_parameter("injection_strength"))),
		"ocean_freeze: zero time scale still evolves interaction foam")
	print("OCEAN FREEZE live_decay=%.6f frozen_decay=%.6f paused_decay=%.6f" % [
		live_decay,
		float(frozen_material.get_shader_parameter("decay")),
		float(paused_material.get_shader_parameter("decay"))])
	demo.queue_free()
	await process_frame
	_finish("ocean_freeze")


func _run_ocean_ultra() -> void:
	await _boot_frames(2)
	var setting_key := "ocean_quality_profile"
	var manager: Node = root.get_node("/root/GameManager")
	var saved_tier: int = manager.get_setting(setting_key,
		OceanQualityProfile.Tier.HIGH)
	manager.settings[setting_key] = OceanQualityProfile.Tier.HIGH
	var demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	manager.settings[setting_key] = saved_tier
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready(), "ocean_ultra: High boot did not initialize")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("ocean_ultra")
		return
	demo.set_frozen(true)
	await _boot_frames(2)
	var displacement_rid: RID = demo.solver.get_displacement_tex_rid()
	var foam_rid: RID = demo.solver.get_foam_near_tex_rid(0)
	var frame_before: int = demo.solver._frame
	_check(is_zero_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail"))),
		"ocean_ultra: High boot has Ultra surface detail")
	demo.set_quality_profile(OceanQualityProfile.Tier.ULTRA)
	await _boot_frames(2)
	_check(demo.quality.effective == OceanQualityProfile.Tier.ULTRA
		and is_equal_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail")), 1.0),
		"ocean_ultra: Ultra profile did not update the material")
	_check(demo.solver.short_cascade_half_rate,
		"ocean_ultra: Ultra restored the expensive full-rate short cascade")
	_check(demo.solver.initialized and demo.texture_bound
		and demo.solver.get_displacement_tex_rid() == displacement_rid
		and demo.solver.get_foam_near_tex_rid(0) == foam_rid
		and demo.solver._frame == frame_before,
		"ocean_ultra: High to Ultra rebuilt GPU resources or cleared foam")
	demo.set_quality_profile(OceanQualityProfile.Tier.HIGH)
	await _boot_frames(2)
	_check(is_zero_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail")))
		and demo.solver.get_displacement_tex_rid() == displacement_rid
		and demo.solver.get_foam_near_tex_rid(0) == foam_rid,
		"ocean_ultra: Ultra to High did not preserve GPU resources")
	manager.set_setting(setting_key, saved_tier)
	demo.queue_free()
	await _boot_frames(2)

	manager.settings[setting_key] = OceanQualityProfile.Tier.ULTRA
	var ultra_demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(ultra_demo)
	manager.settings[setting_key] = saved_tier
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not ultra_demo.capture_ready():
		await process_frame
	_check(ultra_demo.capture_ready(), "ocean_ultra: Ultra boot did not initialize")
	if ultra_demo.capture_ready():
		_check(ultra_demo.quality.effective == OceanQualityProfile.Tier.ULTRA
			and is_equal_approx(float(ultra_demo.surface_mat.get_shader_parameter(
				"ultra_detail")), 1.0),
			"ocean_ultra: direct Ultra boot missed the material setting")
		_check(ultra_demo.solver.short_cascade_half_rate,
			"ocean_ultra: direct Ultra boot missed the efficient cascade cadence")
	ultra_demo.queue_free()
	await process_frame
	print("OCEAN ULTRA resources_preserved=true boot_detail=1")
	_finish("ocean_ultra")


func _run_ocean_single_wave() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	demo.quality.fallback_tier = OceanQualityProfile.Tier.LOW
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready(), "ocean_single_wave: ocean did not initialize")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("ocean_single_wave")
		return
	demo.set_frozen(true)
	await _boot_frames(2)
	var solver: OceanSolver = demo.solver
	var n := solver.map_size
	var spectrum := PackedByteArray()
	spectrum.resize(n * n * 16)
	var positive := Vector2i(n / 2 + 3, n / 2 + 4)
	var negative := Vector2i(n / 2 - 3, n / 2 - 4)
	spectrum.encode_float((positive.y * n + positive.x) * 16, 0.5)
	spectrum.encode_float((negative.y * n + negative.x) * 16 + 8, 0.5)
	solver.take_render_refresh_request()
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_update(solver._spectrum_tex, 0, spectrum)
		var pc := solver._pack_push_constant(0, 0.0, 0.0)
		pc.encode_float(60, 0.0)
		var cl := rd.compute_list_begin()
		solver._dispatch(cl, "spectrum_evolve", pc, n / 16, n / 16, 1)
		solver._dispatch(cl, "fft", pc, 1, n, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "transpose", pc, n / 32, n / 32, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "fft", pc, 1, n, OceanSolver.NUM_SPECTRA)
		solver._dispatch(cl, "map_assemble", pc, n / 16, n / 16, 1)
		rd.compute_list_end()
	)
	var derivative_bytes: PackedByteArray = await TextureReadback.new().read_layer(
		solver.get_derivative_tex_rid(), 0, n * n * 8)
	var displacement_bytes: PackedByteArray = await TextureReadback.new().read_layer(
		solver.get_displacement_tex_rid(), 0, n * n * 8)
	if derivative_bytes.is_empty() or displacement_bytes.is_empty():
		_check(false, "ocean_single_wave: GPU readback failed")
		demo.queue_free()
		_finish("ocean_single_wave")
		return
	var derivative := Image.create_from_data(n, n, false, Image.FORMAT_RGBAH, derivative_bytes)
	var displacement := Image.create_from_data(n, n, false, Image.FORMAT_RGBAH, displacement_bytes)
	var crest := derivative.get_pixel(0, 0)
	var trough := derivative.get_pixel(n / 8, 0)
	var crest_divergence := crest.r + crest.g
	var trough_divergence := trough.r + trough.g
	_check(displacement.get_pixel(0, 0).g > 0.9
		and displacement.get_pixel(n / 8, 0).g < -0.9,
		"ocean_single_wave: analytic crest and trough heights are wrong")
	_check(crest_divergence < -0.001 and trough_divergence > 0.001,
		"ocean_single_wave: chop does not compress crests and expand troughs")
	print("OCEAN WAVE crest_divergence=%.6f trough_divergence=%.6f" % [
		crest_divergence, trough_divergence])
	demo.queue_free()
	await process_frame
	_finish("ocean_single_wave")


func _run_fluid_scene_retention() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid == null or
			demo.fluid.renderer == null or not demo.fluid.renderer._tex_bound):
		await process_frame
	var ready: bool = demo.fluid != null and demo.fluid.renderer != null \
		and demo.fluid.renderer._tex_bound
	_check(ready, "fluid_scene_retention: demo did not initialize")
	if not ready:
		demo.queue_free()
		_finish("fluid_scene_retention")
		return
	demo.menu.visible = false
	demo.configure_fluid(FluidSystem.FluidKind.WATER_OIL, FluidSystem.Scenario.BASIN)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and demo.fluid._pending_init:
		await process_frame
	demo._on_material_selected(FluidSystem.FluidKind.WATER)
	_check(demo.fluid.scenario == FluidSystem.Scenario.BASIN,
		"fluid_scene_retention: changing liquid reset the selected scene")
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	_check(not demo.fluid._pending_init and demo.fluid.active_solver.initialized,
		"fluid_scene_retention: solver did not reinitialize")
	print("FLUSCENE scene=%d mode=%d initialized=%s" % [
		int(demo.fluid.scenario), int(demo.fluid.mode),
		str(demo.fluid.active_solver.initialized)])
	demo.queue_free()
	await process_frame
	_finish("fluid_scene_retention")


func _run_fluid_pool() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid == null or
			demo.fluid.renderer == null or not demo.fluid.renderer._tex_bound):
		await process_frame
	_check(demo.fluid != null and demo.fluid.renderer != null and
		demo.fluid.renderer._tex_bound, "fluid_pool: demo did not initialize")
	if _failures > 0:
		demo.queue_free()
		_finish("fluid_pool")
		return
	demo.menu.visible = false
	demo.fluid.set_particle_count(16384)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	var base_count: int = demo.fluid.particle_count
	var initial_count := base_count * FluidSystem.POOL_START_MULTIPLIER
	var capacity := base_count * FluidSystem.POOL_CAPACITY_MULTIPLIER
	_check(demo.fluid.active_solver.particle_count == capacity and
		demo.fluid.active_solver.active_count == initial_count,
		"fluid_pool: Pool did not start at the base count with the 3x add capacity")
	var reference: PackedFloat32Array = demo.fluid.sph_solver._seed_data.duplicate()
	var positions_match := true
	for kind in range(1, FluidSystem.FluidKind.size()):
		demo.configure_fluid(kind, FluidSystem.Scenario.POOL)
		deadline = Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
				not demo.fluid.active_solver.initialized):
			await process_frame
		var seed: PackedFloat32Array = demo.fluid.sph_solver._seed_data
		for i in range(0, 256, 4):
			for axis in 3:
				if not is_equal_approx(seed[i + axis], reference[i + axis]):
					positions_match = false
		if kind == FluidSystem.FluidKind.WATER_OIL:
			var water_phase_count := 0
			var oil_phase_count := 0
			for particle in initial_count:
				if seed[particle * 4 + 3] > 0.5:
					oil_phase_count += 1
				else:
					water_phase_count += 1
			_check(water_phase_count > 0 and oil_phase_count > 0,
				"fluid_pool: Water + Oil did not seed both phases")
		_check(demo.fluid.active_solver.active_count == initial_count,
			"fluid_pool: a liquid starts with a different particle amount")
	_check(positions_match, "fluid_pool: liquid modes use different Pool seed positions")
	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.POOL)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	demo._cycle_material()
	_check(demo.fluid.mode == FluidSystem.FluidKind.LAVA and
		demo.fluid.scenario == FluidSystem.Scenario.POOL and
		str(demo.material_action.find_child("ActionCaption", true, false).text) == "Lava",
		"fluid_pool: the single liquid action failed to cycle in Pool")
	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.BASIN)
	_check(not demo.pool_add_action.visible,
		"fluid_pool: add action is visible outside Pool")
	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.POOL)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	var solver: SphFluidSolver = demo.fluid.active_solver
	var generation_before: int = solver.init_generation
	var count_before: int = solver.active_count
	for i in FluidSystem.POOL_ADD_BATCH_DIVISOR:
		demo.pool_add_action.emit_signal("pressed")
	await _wait_sim(demo, 0.2)
	var ids := await _sample_fluid_id_integrity(solver, capacity)
	_check(solver.active_count == capacity and solver.active_count > count_before,
		"fluid_pool: Add did not append liquid to the running simulation")
	_check(int(ids.get("missing", -1)) == 0 and int(ids.get("duplicates", -1)) == 0,
		"fluid_pool: adding particles overwrote or duplicated live particle ids")
	_check(not demo.fluid.can_add_pool_liquid() and demo.pool_add_action.disabled,
		"fluid_pool: Add did not stop at reserved capacity")
	_check(solver.init_generation == generation_before and solver.initialized and
		demo.fluid.scenario == FluidSystem.Scenario.POOL,
		"fluid_pool: Add restarted the solver or changed scene")
	print("FLUPOOL base=%d initial=%d capacity=%d after_add=%d same_seed=%s ids_missing=%d ids_duplicate=%d init=%d" % [
		base_count, initial_count, capacity, solver.active_count,
		str(positions_match), int(ids.get("missing", -1)),
		int(ids.get("duplicates", -1)), generation_before])
	demo.queue_free()
	await process_frame
	_finish("fluid_pool")


func _run_fluid_materials() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid == null or
			demo.fluid.renderer == null or not demo.fluid.renderer._tex_bound):
		await process_frame
	_check(demo.fluid != null and demo.fluid.renderer != null and
		demo.fluid.renderer._tex_bound, "fluid_materials: demo did not initialize")
	if _failures > 0:
		_finish("fluid_materials")
		return
	demo.menu.visible = false
	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.BASIN)
	await _wait_sim(demo, 0.5)
	demo.apply_look(4)
	await _wait_sim(demo, 0.5)
	var pouring := await _sample_fluid_phases(demo.fluid.sph_solver)
	await _wait_sim(demo, 18.0)
	var filled := await _sample_fluid_phases(demo.fluid.sph_solver)
	demo.fluid.sph_solver.emitter_enabled = false
	await _wait_sim(demo, 2.0)
	var final := await _sample_fluid_phases(demo.fluid.sph_solver)
	print("FLUMAT water=%d oil=%d pouring_oil=%d settled_delta=%.3f sim=%.2f" % [
		int(final.get("water_count", 0)), int(final.get("oil_count", 0)),
		int(pouring.get("oil_count", 0)),
		float(final.get("oil_y", 0.0)) - float(final.get("water_y", 0.0)),
		demo.fluid.sph_solver._sim_time])
	_check(int(pouring.get("oil_count", 0)) > 0 and
		int(filled.get("oil_count", 0)) > int(pouring.get("oil_count", 0)) + 1000,
		"fluid_materials: oil was not poured")
	_check(int(final.get("water_count", 0)) > 0 and
		int(final.get("water_count", 0)) == int(filled.get("water_count", -1)) and
		int(final.get("oil_count", 0)) == int(filled.get("oil_count", -1)),
		"fluid_materials: phases changed after the pour filled the basin")
	_check(float(final.get("oil_y", 0.0)) > float(final.get("water_y", 0.0)) + 0.3,
		"fluid_materials: oil did not settle above water")
	demo.queue_free()
	_finish("fluid_materials")


func _run_fluid_honey_fall() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid == null or
			demo.fluid.renderer == null or not demo.fluid.renderer._tex_bound):
		await process_frame
	var ready: bool = demo.fluid != null and demo.fluid.renderer != null \
		and demo.fluid.renderer._tex_bound
	_check(ready, "fluid_honey_fall: demo did not initialize")
	if not ready:
		demo.queue_free()
		_finish("fluid_honey_fall")
		return
	demo.menu.visible = false
	demo.configure_fluid(FluidSystem.FluidKind.HONEY, FluidSystem.Scenario.BASIN)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	var pour_speed: float = demo.fluid.sph_solver.emitter_velocity.y
	demo.configure_fluid(FluidSystem.FluidKind.HONEY, FluidSystem.Scenario.POOL)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	var solver: SphFluidSolver = demo.fluid.sph_solver
	solver.emitter_enabled = false
	solver.active_count = 1
	demo.fluid.renderer.set_visible_count(1)
	var seed := PackedFloat32Array([0.0, 10.0, 0.0, 0.0])
	RenderingServer.call_on_render_thread(solver.respawn_range.bind(0, seed))
	await _wait_sim(demo, 0.5)
	var state := await _sample_fluid_particle(solver, 0)
	var y: float = float(state.get("y", 10.0))
	var vy: float = float(state.get("vy", 0.0))
	print("FLUHONEY y=%.3f vy=%.3f pour_vy=%.1f sim=%.2f" % [
		y, vy, pour_speed, solver._sim_time])
	_check(is_equal_approx(pour_speed, -6.0),
		"fluid_honey_fall: Basin honey emitter has a different launch speed")
	_check(y < 9.0 and vy < -4.0,
		"fluid_honey_fall: honey free-fall is damped by its material viscosity")
	demo.configure_fluid(FluidSystem.FluidKind.HONEY, FluidSystem.Scenario.CASCADE)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (demo.fluid._pending_init or
			not demo.fluid.active_solver.initialized):
		await process_frame
	demo.flow_slider.value = demo.flow_slider.max_value
	await _wait_sim(demo, 8.0)
	var normal_stream := await _sample_honey_stream(solver)
	demo.flow_slider.value = demo.flow_slider.min_value
	await _wait_sim(demo, 2.0)
	demo.flow_slider.value = demo.flow_slider.max_value
	await _wait_sim(demo, 8.0)
	var high_stream := await _sample_honey_stream(solver)
	_check(is_equal_approx(demo.flow_slider.max_value, FluidSystem.HONEY_CASCADE_FLOW_MAX)
		and is_equal_approx(demo.fluid.flow_rate, demo.flow_slider.value),
		"fluid_honey_fall: Flow slider and honey emitter disagree")
	print("FLUHONEY stream_normal=%d/%d stream_high=%d/%d" % [
		int(normal_stream.get("escaped", -1)), int(normal_stream.get("airborne", 0)),
		int(high_stream.get("escaped", -1)), int(high_stream.get("airborne", 0))])
	_check(int(normal_stream.get("airborne", 0)) > 100 and
		int(normal_stream.get("escaped", -1)) < int(normal_stream.get("airborne", 0)) * 0.05,
		"fluid_honey_fall: normal-flow honey stream sprays outside the chute")
	_check(int(high_stream.get("airborne", 0)) > 100 and
		int(high_stream.get("escaped", -1)) < int(high_stream.get("airborne", 0)) * 0.05,
		"fluid_honey_fall: high-flow honey stream sprays outside the chute")
	demo.queue_free()
	_finish("fluid_honey_fall")


func _sample_honey_stream(solver: SphFluidSolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_honey_stream.bind(solver, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


func _read_honey_stream(solver: SphFluidSolver, result: Dictionary) -> void:
	var positions := solver._rd.buffer_get_data(
		solver.parity_positions_rid(solver.current_parity())).to_float32_array()
	var airborne := 0
	var escaped := 0
	for i in solver.live_count():
		if positions[i * 4 + 1] < 10.5:
			continue
		airborne += 1
		if absf(positions[i * 4] - solver.emitter_origin.x) > 1.0 or \
				absf(positions[i * 4 + 2] - solver.emitter_origin.z) > 1.0:
			escaped += 1
	result["airborne"] = airborne
	result["escaped"] = escaped
	result["done"] = true


func _sample_fluid_particle(solver: SphFluidSolver, index: int) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_fluid_particle.bind(solver, index, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


func _read_fluid_particle(solver: SphFluidSolver, index: int, result: Dictionary) -> void:
	var parity := solver.current_parity()
	var positions := solver._rd.buffer_get_data(
		solver.parity_positions_rid(parity)).to_float32_array()
	var velocities := solver._rd.buffer_get_data(
		solver.parity_velocities_rid(parity)).to_float32_array()
	result["y"] = positions[index * 4 + 1]
	result["vy"] = velocities[index * 4 + 1]
	result["done"] = true


func _sample_fluid_id_integrity(solver: SphFluidSolver, count: int) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_fluid_id_integrity.bind(solver, count, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


func _read_fluid_id_integrity(solver: SphFluidSolver, count: int,
		result: Dictionary) -> void:
	var parity := solver.current_parity()
	var velocities := solver._rd.buffer_get_data(
		solver.parity_velocities_rid(parity)).to_float32_array()
	var seen := PackedByteArray()
	seen.resize(count)
	var duplicates := 0
	for i in solver.live_count():
		var id := int(round(velocities[i * 4 + 3]))
		if id < 0 or id >= count:
			duplicates += 1
		elif seen[id] != 0:
			duplicates += 1
		else:
			seen[id] = 1
	var missing := 0
	for id in count:
		if seen[id] == 0:
			missing += 1
	result["missing"] = missing
	result["duplicates"] = duplicates
	result["done"] = true


func _sample_fluid_phases(solver: SphFluidSolver) -> Dictionary:
	var result := {}
	RenderingServer.call_on_render_thread(_read_fluid_phases.bind(solver, result))
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


func _read_fluid_phases(solver: SphFluidSolver, result: Dictionary) -> void:
	var key := "positions_a" if solver.current_parity() == 0 else "positions_b"
	var positions := solver._rd.buffer_get_data(solver._buffers[key]).to_float32_array()
	var sums := Vector2.ZERO
	var counts := Vector2i.ZERO
	for i in solver.live_count():
		if positions[i * 4 + 3] > 0.5:
			sums.y += positions[i * 4 + 1]
			counts.y += 1
		else:
			sums.x += positions[i * 4 + 1]
			counts.x += 1
	result["water_count"] = counts.x
	result["oil_count"] = counts.y
	result["water_y"] = sums.x / maxf(float(counts.x), 1.0)
	result["oil_y"] = sums.y / maxf(float(counts.y), 1.0)
	result["done"] = true


## ── fluid_foam ──────────────────────────────────────────────────────────
## Regression gate for the white-particle (foam) aging rule. SebLague ages
## spray stranded with no fluid neighbours unconditionally; our port gated that
## on planet mode, so tank-mode orphans kept their full 5-15 s lifetime forever,
## filled the pool, and eventually starved spawning.
##
## The gate tests the rule itself, deterministically: spawning is frozen, every
## fluid particle is teleported into an airborne blob, and a synthetic cohort of
## 2000 foam particles (life 1.0 s, zero velocity) is written straight into the
## foam buffers on the dry floor ring, 6+ m from where the blob lands. The
## cohort has zero fluid neighbours. With the fix it ages at 5x and is dead in
## 0.2 s; with the bug nothing ages it and all 2000 stay alive. No reliance on
## splash chaos, quality tier or user settings.
##
## Waits run in SIMULATED seconds polled from the solver's clock (the fixed
## 1/60 SimStepClock makes frame counts unequal to time above 60 fps); frame
## guards only bound the wait if rendering stalls.
## Sentinel: "TEST PASS fluid_foam" (GPU phase of tests/run_tests.sh).

func _run_fluid_foam() -> void:
	await _boot_frames(2)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.menu.visible = false

	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var fluid: Node = demo.fluid
		if fluid != null and fluid.renderer != null and fluid.renderer._tex_bound:
			break

	demo.fluid.set_foam_enabled(true)
	demo.fluid.set_sph_foam_amount(0.0)
	await _wait_sim(demo, WARM_SIM)

	_teleport_fluid_away(demo)
	await _wait_sim(demo, 0.5)
	_inject_foam_cohort(demo)
	await _wait_sim(demo, INJECT_CHECK_SIM)
	var injected := await _sample_foam(demo)
	print("FLUFOAM injected_alive=%d" % int(injected.get("foam_live", -1)))

	await _wait_sim(demo, RESIDUE_SIM)
	var residue := await _sample_foam(demo)
	print("FLUFOAM residue_alive=%d" % int(residue.get("foam_live", -1)))

	var injected_count := int(injected.get("foam_live", -1))
	var residue_count := int(residue.get("foam_live", -1))
	var fail := ""
	if injected_count < INJECT_MIN_ALIVE:
		fail = "inject_failed alive=%d min=%d" % [injected_count, INJECT_MIN_ALIVE]
	elif residue_count >= PASS_MAX_ALIVE:
		fail = "zero_neighbour_foam_immortal alive=%d max=%d" % [
			residue_count, PASS_MAX_ALIVE]
	if fail != "":
		print("FLUFOAM FAIL %s" % fail)
		print("TEST FAIL fluid_foam")
		quit(1)
		return
	print("FLUFOAM PASS injected=%d residue=%d" % [injected_count, residue_count])
	print("TEST PASS fluid_foam")
	quit(0)


## Lifts every fluid slot into one rest-density lattice cube hovering above the
## tank, so the floor ring where the cohort lands stays fluid-free for seconds.
func _teleport_fluid_away(demo: Node) -> void:
	var solver: RefCounted = demo.fluid.sph_solver
	var count: int = demo.fluid.particle_count
	var spacing: float = solver.spacing
	var side := ceili(pow(float(count), 1.0 / 3.0))
	var blob := PackedFloat32Array()
	blob.resize(count * 4)
	for i in count:
		var x := i % side
		@warning_ignore("integer_division")
		var y := (i / side) % side
		@warning_ignore("integer_division")
		var z := i / (side * side)
		var p := Vector3(-side * spacing * 0.5 + x * spacing,
			6.0 + y * spacing,
			-side * spacing * 0.5 + z * spacing)
		blob[i * 4] = p.x
		blob[i * 4 + 1] = p.y
		blob[i * 4 + 2] = p.z
		blob[i * 4 + 3] = 0.0
	RenderingServer.call_on_render_thread(solver.respawn_range.bind(0, blob))


## Overwrites the foam pool with a known cohort on the dry floor ring: life
## 1.0 s, zero velocity, render scale 1. Slots past the cohort stay beyond
## foam_live() and are never touched by the update pass.
func _inject_foam_cohort(demo: Node) -> void:
	var solver: RefCounted = demo.fluid.sph_solver
	var cohort := PackedFloat32Array()
	cohort.resize(COHORT * 4)
	var vel := PackedFloat32Array()
	vel.resize(COHORT * 4)
	var golden := PI * (3.0 - sqrt(5.0))
	for i in COHORT:
		var ang := golden * float(i)
		var radius := COHORT_RADIUS + float(i % 8) * 0.12
		cohort[i * 4] = cos(ang) * radius
		cohort[i * 4 + 1] = 0.11
		cohort[i * 4 + 2] = sin(ang) * radius
		cohort[i * 4 + 3] = COHORT_LIFE
		vel[i * 4 + 3] = 1.0
	var counters := PackedInt32Array([COHORT, 0, 0, 0, 0, 0])
	RenderingServer.call_on_render_thread(_write_foam_buffers.bind(
		solver, cohort.to_byte_array(), vel.to_byte_array(),
		counters.to_byte_array()))


func _write_foam_buffers(solver: RefCounted, pos_bytes: PackedByteArray,
		vel_bytes: PackedByteArray, count_bytes: PackedByteArray) -> void:
	solver._rd.buffer_update(solver._buffers["foam_pos"], 0, pos_bytes.size(), pos_bytes)
	solver._rd.buffer_update(solver._buffers["foam_vel"], 0, vel_bytes.size(), vel_bytes)
	solver._rd.buffer_update(solver._buffers["foam_count"], 0, count_bytes.size(), count_bytes)


func _wait_sim(demo: Node, seconds: float) -> void:
	var solver: RefCounted = demo.fluid.sph_solver
	var target: float = float(solver._sim_time) + seconds
	var guard := int(seconds * GUARD_FRAMES_PER_SECOND)
	while float(solver._sim_time) < target and guard > 0:
		await process_frame
		guard -= 1


func _sample_foam(demo: Node) -> Dictionary:
	var result := {}
	demo.fluid.request_validation_stats(result)
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


## ── fluid_resize ────────────────────────────────────────────────────────
## F-FLU-3 probe: does the screen-space fluid composite follow window resizes?
## Boots the real fluid demo, captures at 1280x720, resizes the window to a
## different aspect (900x720), captures again. With the resize unhandled the
## prepass viewports keep their boot-time size and proj_scale, so the fluid
## surface no longer lines up with the scene behind it.
##
## Output PNGs in res://tmp/flu3/, log lines start with "FLU3 ".

func _run_fluid_resize() -> void:
	await _boot_frames(2)
	root.size = Vector2i(1280, 720)
	var demo: Node = load("res://scenes/fluid_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(1280, 720)
	demo.menu.visible = false

	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var renderer: Node = demo.fluid.renderer
		if renderer != null and renderer._tex_bound:
			break
	for i in FLU3_SETTLE_FRAMES:
		await process_frame

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FLU3_OUT_DIR))
	await _grab_flu3("before_resize_1280x720.png")

	root.size = Vector2i(900, 720)
	for i in 20:
		await process_frame
	await _grab_flu3("after_resize_900x720.png")

	var cam: Camera3D = demo.fluid.camera
	print("FLU3 PROBE DONE window=%dx%d main_viewport=%s depth_vp=%s" % [
		root.size.x, root.size.y,
		str(cam.get_viewport().get_visible_rect().size),
		str(demo.fluid.renderer.depth_vp.size),
	])
	quit(0)


func _grab_flu3(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s" % [FLU3_OUT_DIR, shot_name]))
	print("FLU3 SHOT " + shot_name)


## ── fluid_tier ──────────────────────────────────────────────────────────
## Regression gate for the quality-tier switch lifecycle. Every queued re-init
## validates FluidConfig first, so a tier push that leaves the config pair
## inconsistent strands the solver uninitialized and the fluid vanishes (the
## 2026-09-23 Ultra->Medium bug). This walks the REAL menu path — the same
## set_tier the Quality profile option emits — through every downshift and
## upshift, scene changes and a restart, and asserts the solver comes back
## initialized each time. Boots at Medium first, since a fresh boot never went
## through the buggy path.
## Sentinel: "TEST PASS fluid_tier" (GPU phase of tests/run_tests.sh).

func _run_fluid_tier() -> void:
	await _boot_frames(2)
	var manager: Node = root.get_node("GameManager")
	manager.set_setting("fluid_quality_profile", 1) # MEDIUM
	manager.current_demo = "fluid_demo"

	var demo: Node = load(TIER_DEMO).instantiate()
	root.add_child(demo)
	await process_frame
	demo.menu.visible = false

	if not await _soak(demo):
		_fail_tier(demo, "boot at Medium")
		return
	print("FLUTIER boot_medium initialized=%s" % demo.fluid.active_solver.initialized)

	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.CASCADE)
	if not await _soak(demo) or demo.fluid.scenario != FluidSystem.Scenario.CASCADE:
		_fail_tier(demo, "switch to Cascade")
		return
	print("FLUTIER cascade_scene initialized=%s" % demo.fluid.active_solver.initialized)
	demo.configure_fluid(FluidSystem.FluidKind.WATER, FluidSystem.Scenario.POOL)
	if not await _soak(demo):
		_fail_tier(demo, "return to Pool")
		return

	# Every downshift from Ultra used to strand the solver, plus the upshifts
	# around them; end back on Medium.
	for tier in [3, 0, 2, 1]:
		demo.quality.set_tier(tier)
		if not await _soak(demo):
			_fail_tier(demo, "tier %d" % tier)
			return
		print("FLUTIER tier_%d initialized=%s count=%d tex=%d" % [tier,
			demo.fluid.active_solver.initialized, demo.fluid.particle_count,
			demo.fluid.config.texture_width])

	demo.quality.set_tier(SimQualityProfile.Tier.ULTRA)
	demo.menu._do_reset()
	if not await _soak(demo) \
			or demo.quality.requested != FluidQualityProfile.default_tier() \
			or demo.quality._option.selected != FluidQualityProfile.default_tier() \
			or demo.fluid.particle_count != FluidQualityProfile.PARTICLE_COUNT[
				FluidQualityProfile.default_tier()] \
			or int(manager.get_setting("fluid_quality_profile", -1)) \
				!= FluidQualityProfile.default_tier():
		_fail_tier(demo, "factory tier reset")
		return
	print("FLUTIER factory_reset requested=%d stored=%d" % [demo.quality.requested,
		manager.get_setting("fluid_quality_profile", -1)])

	# The Reset action: free + re-init against the current config.
	demo.fluid.restart()
	if not await _soak(demo):
		_fail_tier(demo, "restart")
		return

	manager.set_setting("fluid_quality_profile", 3) # restore the user's tier
	print("TEST PASS fluid_tier")
	quit(0)


## Waits for the queued free+init to land and the sim to run for a second: a
## stranded solver reports initialized=false, a config error surfaces as a
## timeout here because init_render returns before allocating.
func _soak(demo: Node) -> bool:
	var deadline := Time.get_ticks_msec() + TIER_INIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var fluid: Node = demo.fluid
		if fluid != null and fluid.active_solver != null \
				and fluid.active_solver.initialized and fluid.renderer != null \
				and fluid.renderer._tex_bound:
			break
	if not demo.fluid.active_solver.initialized:
		return false
	var solver: SphFluidSolver = demo.fluid.active_solver
	var target: float = float(solver._sim_time) + TIER_SOAK_SIM
	var guard := int(TIER_SOAK_SIM * GUARD_FRAMES_PER_SECOND)
	while float(solver._sim_time) < target and guard > 0:
		await process_frame
		guard -= 1
	return demo.fluid.active_solver.initialized


func _fail_tier(demo: Node, stage: String) -> void:
	print("FLUTIER FAIL %s initialized=%s count=%d tex=%d" % [stage,
		demo.fluid.active_solver.initialized, demo.fluid.particle_count,
		demo.fluid.config.texture_width])
	print("TEST FAIL fluid_tier")
	quit(1)


## ── fractal_policy ──────────────────────────────────────────────────────
## Display-policy probe: what the screen shows DURING zoom gestures.
##
## Boots the real fractal_demo scene with no harness and drives realistic
## wheel input (notched zoom with pauses) plus a continuous deep dive. The
## policy under test:
##   1. the preview pass always runs at the FULL iteration count the view
##      needs — a capped preview paints deep zooms black (blob) or false
##      structure; resolution, not iterations, is the cost knob;
##   2. the display follows the preview while moving (live current view, no
##      unbounded stretch of an older render);
##   3. after stillness the full-res refine lands and stays;
##   4. the autopilot (perpetual motion) keeps the same guarantees.
## Frame times are logged during gestures as a jank metric. PNGs land in
## res://tmp/policy/ for visual inspection.

func _run_fractal_policy() -> void:
	await _boot_frames(3)
	root.size = Vector2i(POLICY_W, POLICY_H)
	var demo: Node = load("res://scenes/fractal_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(POLICY_W, POLICY_H)

	var cam: FractalCamera = demo._camera
	var view: FractalView = demo._view
	view.resize(root.size)
	demo._autopilot.enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(POLICY_OUT_DIR))

	# ── Phase A: boot settles to the refined image ────────────────────────
	if not await _wait_settled(view, 10000):
		_fail("boot never settled (state=%d blend=%.3f)" % [view.state, _blend(view)])
		quit(1)
		return
	_shot_policy("a_settled")

	# ── Phase B: realistic wheel scroll — notches with pauses ─────────────
	cam.fractal_type = 0
	cam.center_x = -0.743643887037151
	cam.center_y = 0.131825904205330
	cam.log_zoom = 3.0 * POLICY_LN10
	cam.target_log_zoom = 3.0 * POLICY_LN10
	view.invalidate_orbit()
	if not await _wait_settled(view, 10000):
		_fail("overview never settled before the gesture")
		quit(1)
		return
	var pre_luma := _shot_policy("b_pre_zoom")

	var samples := 0
	var live := 0
	var capped := 0
	var max_delta := 0.0
	for notch in POLICY_NOTCHES:
		cam.zoom_at(FractalCamera.ZOOM_STEP, Vector2(POLICY_W * 0.5, POLICY_H * 0.5), true)
		for f in POLICY_NOTCH_FRAMES:
			var before := Time.get_ticks_usec()
			await process_frame
			max_delta = maxf(max_delta, float(Time.get_ticks_usec() - before) / 1.0e6)
			if f % 4 == 0:
				samples += 1
				var blend := _blend(view)
				var need := cam.iterations_full()
				var iters := _preview_iters(view)
				if iters < need:
					capped += 1
				if blend < 0.5:
					live += 1
				if notch >= POLICY_NOTCHES - 3 and blend >= 0.5:
					_fail("wheel scroll end holds a stale image (blend=%.3f, need=%d)" % [
						blend, need])
				if iters != 0 and iters < need:
					_fail("preview runs capped: %d of %d iterations" % [iters, need])
	print("POLICY scroll live=%d/%d capped=%d/%d max_frame=%.3fs" % [
		live, samples, capped, samples, max_delta])
	if max_delta > 0.25:
		print("POLICY WARN: gesture frame spike %.3fs" % max_delta)
	_shot_policy("b_scroll_late")

	# ── Phase C: continuous deep dive stays live and correct ──────────────
	if not await _wait_settled(view, 20000):
		_fail("post-scroll view never settled (state=%d)" % view.state)
	cam.target_log_zoom = 11.0 * POLICY_LN10
	var became_live := false
	for f in 15:
		await process_frame
		if _blend(view) < 0.5:
			became_live = true
		if _preview_iters(view) < cam.iterations_full():
			_fail("dive preview capped at %d of %d iterations" % [
				_preview_iters(view), cam.iterations_full()])
	if not became_live:
		_fail("deep dive never switched to the live preview (blend=%.3f)" % _blend(view))
	print("POLICY dive live=%s blend=%.3f" % [became_live, _blend(view)])
	var mid_luma := _shot_policy("c_dive_mid")
	if mid_luma < 0.25 * pre_luma:
		_fail("dive frame went dark (luma %.4f vs %.4f before)" % [mid_luma, pre_luma])

	# ── Phase D: stillness lands the refine ───────────────────────────────
	if not await _wait_settled(view, 20000):
		_fail("deep view never settled after the dive (state=%d)" % view.state)
	_shot_policy("d_refined_deep")

	# ── Phase E: autopilot = perpetual motion ─────────────────────────────
	demo._autopilot.enabled = true
	demo._autopilot.restart()
	var saw_refined := false
	var auto_capped := false
	for f in 900:
		await process_frame
		if f % 90 == 0:
			print("POLICY auto f%03d blend=%.3f state=%d zoom=%.1f" % [
				f, _blend(view), view.state, cam.log_zoom / POLICY_LN10])
		if f == 150:
			_shot_policy("e_auto_moving")
		if view.state == FractalView.State.IDLE and _blend(view) >= 0.999:
			if not saw_refined:
				_shot_policy("e_auto_hold")
			saw_refined = true
		if _preview_iters(view) != 0 and _preview_iters(view) < cam.iterations_full():
			auto_capped = true
	demo._autopilot.enabled = false
	if auto_capped:
		_fail("autopilot previews ran below the needed iteration count")
	if not saw_refined:
		_fail("autopilot never landed a refined image during its holds")
	else:
		print("POLICY autopilot reached a refined image during holds")

	if _fails == 0:
		print("POLICY PROBE PASS")
	else:
		print("POLICY PROBE FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)


func _fail(msg: String) -> void:
	_fails += 1
	print("POLICY FAIL: %s" % msg)


func _shot_policy(name: String) -> float:
	var img := root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [POLICY_OUT_DIR, name]))
	var sum := 0.0
	var n := 0
	for py in range(0, POLICY_H, 16):
		for px in range(0, POLICY_W, 16):
			sum += img.get_pixel(px, py).get_luminance()
			n += 1
	var luma := sum / maxf(float(n), 1.0)
	print("POLICY SHOT %s luma=%.4f" % [name, luma])
	return luma


func _blend(view: FractalView) -> float:
	var raw: Variant = view.display.material.get_shader_parameter("refine_blend")
	return float(raw) if raw != null else 0.0


func _preview_iters(view: FractalView) -> int:
	return int(view._material_low.get_shader_parameter("max_iterations"))


func _wait_settled(view: FractalView, ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view.state == FractalView.State.IDLE and _blend(view) >= 0.999:
			return true
	return false


## ── fractal_zoom ────────────────────────────────────────────────────────
## F-FR2-1 probe: Julia perturbation vs Mandelbrot rebasing at deep zoom.
##
## Boots the real fractal_demo scene, drives the real FractalCamera to fixed
## deep-zoom targets, saves the displayed frame, then reads back the high
## viewport iteration data and compares it against a float64 CPU reference
## evaluated at the same pixel centers. Deviations beyond float32 boundary
## fuzz mean the perturbation path misrenders (glitch blobs).
##
## Output lines start with "FR2 " and PNGs land in res://tmp/fr2/.

func _run_fractal_zoom() -> void:
	await _boot_frames(2)

	var c := Vector2(JULIA_RE, JULIA_IM)
	# Repelling fixed point of z^2 + c: always on the Julia set boundary.
	var fp := (Vector2.ONE + _complex_sqrt(1.0 - 4.0 * c.x, -4.0 * c.y)) * 0.5
	# Preimage of the critical point: the orbit passes through ~0.
	var pc := _complex_sqrt(-c.x, -c.y)
	# Depth-3 preimage of the fixed point, principal branch each time.
	var p3 := fp
	for i in 3:
		var d := p3 - c
		p3 = _complex_sqrt(d.x, d.y)

	var ln10 := 2.302585092994046
	_targets = [
		["mandel_1e6", 0, -0.743643887037151, 0.131825904205330, 6.0 * ln10],
		["mandel_1e9", 0, -0.743643887037151, 0.131825904205330, 9.0 * ln10],
		["julia_fp_1e6", 1, fp.x, fp.y, 6.0 * ln10],
		["julia_fp_1e9", 1, fp.x, fp.y, 9.0 * ln10],
		["julia_fp_1e10", 1, fp.x, fp.y, 10.0 * ln10],
		["julia_pc_1e6", 1, pc.x, pc.y, 6.0 * ln10],
		["julia_pc_1e9", 1, pc.x, pc.y, 9.0 * ln10],
		["julia_pc_1e10", 1, pc.x, pc.y, 10.0 * ln10],
		["julia_p3fp_1e9", 1, p3.x, p3.y, 9.0 * ln10],
	]

	root.size = Vector2i(VIEW_W, VIEW_H)
	var demo: Node = load("res://scenes/fractal_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(VIEW_W, VIEW_H)

	var cam: FractalCamera = demo._camera
	var view: FractalView = demo._view
	view.resize(root.size)
	demo._autopilot.enabled = false
	view.aa_quality = 1

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp/fr2"))

	for target in _targets:
		await _run_fractal_target(cam, view, target)

	print("FR2 PROBE DONE")
	quit(0)


static func _f32(v: float) -> float:
	var p := PackedFloat32Array([v])
	return p[0]


static func _complex_sqrt(x: float, y: float) -> Vector2:
	var r := sqrt(x * x + y * y)
	return Vector2(
		sqrt(maxf((r + x) * 0.5, 0.0)),
		signf(y) * sqrt(maxf((r - x) * 0.5, 0.0))
	)


func _run_fractal_target(cam: FractalCamera, view: FractalView, target: Array) -> void:
	var tname: String = target[0]
	cam.fractal_type = target[1]
	cam.center_x = target[2]
	cam.center_y = target[3]
	cam.log_zoom = target[4]
	cam.target_log_zoom = target[4]
	cam.update_motion(1.0)
	view.invalidate_orbit()

	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view.state == FractalView.State.IDLE:
			break
	if view.state != FractalView.State.IDLE:
		print("FR2 %s TIMEOUT state=%d" % [tname, view.state])
	# The display fades from the low-res preview to the refined high viewport;
	# grab only once the fade completed so the PNG matches the readback.
	var display_mat: ShaderMaterial = view.display.material
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var blend: float = display_mat.get_shader_parameter("refine_blend")
		if blend >= 0.999:
			break

	var shot := root.get_texture().get_image()
	shot.save_png(ProjectSettings.globalize_path("res://tmp/fr2/%s.png" % tname))
	var data: Image = view.view_high.get_texture().get_image()

	var iters: int = cam.iterations_full()
	var half := VIEW_BASE / cam.zoom()
	var metric := _compare_fractal(
		data, _f32(cam.center_x), _f32(cam.center_y), target[1], iters,
		VIEW_BASE * 2.0 * half * (float(VIEW_W) / float(VIEW_H)), 2.0 * half, tname
	)
	print("FR2 %s type=%d iters=%d total=%d cls_mismatch=%d big_mu=%d avg_dmu=%.4f" % [
		tname, target[1], iters, metric.total, metric.mismatch, metric.big_mu, metric.avg_dmu,
	])


func _compare_fractal(img: Image, seed_x: float, seed_y: float, ftype: int, iters: int,
		wsx: float, wsy: float, tname: String) -> Dictionary:
	var gx := 0
	var gy := 0
	for px in range(0, VIEW_W, SAMPLE_STEP):
		gx += 1
	for py in range(0, VIEW_H, SAMPLE_STEP):
		gy += 1
	var gpu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var cpu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var mask_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var dmu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var total := 0
	var mismatch := 0
	var gpu_only := 0
	var cpu_only := 0
	var big_mu := 0
	var dmu_sum := 0.0
	var dmu_signed := 0.0
	var dmu_n := 0
	var iy := 0
	for py in range(0, VIEW_H, SAMPLE_STEP):
		var off_y := ((float(py) + 0.5) / float(VIEW_H) - 0.5) * wsy
		var ix := 0
		for px in range(0, VIEW_W, SAMPLE_STEP):
			var off_x := ((float(px) + 0.5) / float(VIEW_W) - 0.5) * wsx
			var ref := _fractal_reference(ftype, seed_x + off_x, seed_y + off_y, iters)
			var g := img.get_pixel(px, py)
			var gpu_escaped := g.a > 0.5
			total += 1
			var gpu_mu := floorf(g.r) * 64.0 + g.g
			gpu_img.set_pixel(ix, iy, _dbg_color(gpu_escaped, gpu_mu, iters))
			cpu_img.set_pixel(ix, iy, _dbg_color(ref.escaped, ref.mu, iters))
			var bad: bool = gpu_escaped != ref.escaped
			if bad:
				mismatch += 1
				if gpu_escaped:
					gpu_only += 1
				else:
					cpu_only += 1
				mask_img.set_pixel(ix, iy, Color(1.0, 0.0, 0.0))
			else:
				mask_img.set_pixel(ix, iy, Color(0.0, 1.0, 0.0))
				if ref.escaped:
					var d := absf(gpu_mu - ref.mu)
					var signed: float = gpu_mu - ref.mu
					dmu_sum += d
					dmu_signed += signed
					dmu_n += 1
					var t := clampf(absf(signed) / 200.0, 0.0, 1.0)
					dmu_img.set_pixel(ix, iy,
						Color(1.0 - t if signed < 0.0 else 0.0, 1.0 - t if signed > 0.0 else 0.0, 0.0))
					if d > 1.0:
						big_mu += 1
				else:
					dmu_img.set_pixel(ix, iy, Color(0.0, 0.0, 0.0))
			ix += 1
		iy += 1
	var base := ProjectSettings.globalize_path("res://tmp/fr2/%s" % tname)
	gpu_img.save_png(base + "_gpu.png")
	cpu_img.save_png(base + "_cpu.png")
	mask_img.save_png(base + "_mask.png")
	dmu_img.save_png(base + "_dmu.png")
	print("FR2 %s gpu_only=%d cpu_only=%d signed_dmu=%.3f" % [tname, gpu_only, cpu_only,
		dmu_signed / maxf(float(dmu_n), 1.0)])
	return {
		"total": total,
		"mismatch": mismatch,
		"big_mu": big_mu,
		"avg_dmu": dmu_sum / maxf(float(dmu_n), 1.0),
	}


func _dbg_color(escaped: bool, mu: float, iters: int) -> Color:
	if not escaped:
		return Color(0.0, 0.0, 0.0)
	var t := clampf(mu / float(iters), 0.0, 1.0)
	return Color(t, t, t)


func _fractal_reference(ftype: int, x0: float, y0: float, iters: int) -> Dictionary:
	var zx := 0.0
	var zy := 0.0
	var cx := x0
	var cy := y0
	if ftype == 1:
		zx = x0
		zy = y0
		cx = JULIA_RE
		cy = JULIA_IM
	var n := 0.0
	var escaped := false
	for i in iters:
		var t := zx * zx - zy * zy + cx
		zy = 2.0 * zx * zy + cy
		zx = t
		n += 1.0
		if zx * zx + zy * zy > BAILOUT2:
			escaped = true
			break
	var mu := float(iters)
	if escaped:
		var log_zn := log(zx * zx + zy * zy) * 0.5
		var nu := log(log_zn / 5.545177444479562) / 0.6931471805599453
		mu = n + 1.0 - nu
	return {"escaped": escaped, "mu": mu}


## ── grass ───────────────────────────────────────────────────────────────
## F-GRA-3 probe: does the grass blade fill (GrassRenderer.generate) run more
## than once at launch? Each generate() rebuilds all five LOD MultiMeshes, so
## sampling the identity of the first seeded LOD mesh every frame counts fills without
## touching the runtime path.
##
## seed=0  fresh settings (no persisted Density slider value)
## seed=1  persisted Density that differs from the tier density (0.7)
## seed=2  persisted Density equal to the tier density
##
## Log lines start with "GRA3 ".

func _run_grass() -> void:
	await _boot_frames(2)
	var seed_mode := 0
	var tier := GrassQualityProfile.Tier.MEDIUM
	var palette_seed := 0
	for arg in _extra:
		if arg.begins_with("seed="):
			seed_mode = int(arg.get_slice("=", 1))
		elif arg.begins_with("tier="):
			tier = clampi(int(arg.get_slice("=", 1)), 0, 3)
		elif arg.begins_with("palette="):
			palette_seed = clampi(int(arg.get_slice("=", 1)), 0, 3)
	var settings: Node = root.get_node("/root/UserSettings")
	settings.clear_sim("grass_demo")
	# SimMenu derives its persistence section from GameManager.current_demo;
	# without the real launch flow it stays empty and restore is disabled.
	root.get_node("/root/GameManager").current_demo = "grass_demo"
	root.get_node("/root/GameManager").set_setting("grass_quality_profile", tier)
	var expected_sun_elevation := 24.0
	var expected_sun_azimuth := 187.0
	settings.set_sim_value("grass_demo", "☀️ Sunlight/Sun elevation", expected_sun_elevation)
	settings.set_sim_value("grass_demo", "☀️ Sunlight/Sun azimuth", expected_sun_azimuth)
	if seed_mode == 1:
		settings.set_sim_value("grass_demo", DENSITY_KEY, 0.5)
	elif seed_mode == 2:
		settings.set_sim_value("grass_demo", DENSITY_KEY, TIER_DENSITY)
	if palette_seed == 3:
		settings.set_sim_value("grass_demo", "🎨 Grass Palette/Palette", 3)
		settings.set_sim_value("grass_demo", "🎨 Grass Palette/Base Color", Color(0.22, 0.1, 0.29))
		settings.set_sim_value("grass_demo", "🎨 Grass Palette/Color Gradient", 0.4)

	var demo: Node = load("res://scenes/grass_demo.tscn").instantiate()

	var last_lod_id := 0
	var generates := 0
	var frames: Array = []
	var densities: Array = []

	# The first fill runs inside _ready during add_child, before the first
	# awaitable frame, so sample synchronously here and then every frame.
	root.add_child(demo)
	var boot_sun_color: Color = demo.sun.light_color
	var boot_horizon: Color = demo.sky_material.get_shader_parameter("horizon_color")
	var ground_material: ShaderMaterial = demo.ground_mesh.material_override
	var profile: Dictionary = GrassQualityProfile.values(tier)
	_check(demo.grass.material.get_shader_parameter("cloud_shadow_texture") \
			== demo.cloudscape._shadow_viewport.get_texture() \
			and ground_material.get_shader_parameter("cloud_shadow_texture") \
			== demo.cloudscape._shadow_viewport.get_texture() \
			and (float(demo.cloudscape._shadow_material.get_shader_parameter("cloud_shadow_strength")) > 0.0) \
				== bool(profile.shadows) \
			and is_equal_approx(float(demo.cloudscape._shadow_material.get_shader_parameter("coverage")),
				demo.cloudscape._coverage),
		"GRA3: cloud shadows did not reach grass and ground at player boot")
	_check((demo.main_camera.cull_mask & OceanCloudscape.CLOUD_LAYER) == 0 \
			and demo.cloudscape._cloud_camera.cull_mask == OceanCloudscape.CLOUD_LAYER,
		"GRA3: cloud raymarch escaped into the player camera")
	demo._set_shadows(false)
	_check(is_zero_approx(float(demo.cloudscape._shadow_material.get_shader_parameter("cloud_shadow_strength"))),
		"GRA3: disabling shadows left cloud shadows active")
	demo._set_shadows(true)
	demo.cloudscape.set_enabled(false)
	_check(is_zero_approx(float(demo.cloudscape._shadow_material.get_shader_parameter("cloud_shadow_strength"))),
		"GRA3: disabling clouds left cloud shadows active")
	demo.cloudscape.set_enabled(true)
	demo._set_shadows(profile.shadows)
	var sun_direction: Vector3 = demo.sun.global_basis.z.normalized()
	var sky_direction: Vector3 = demo.sky_material.get_shader_parameter("sun_direction")
	var cloud_direction: Vector3 = demo.cloudscape._data_material.get_shader_parameter("sun_direction")
	_check(is_equal_approx(demo.sun_elevation, expected_sun_elevation) \
			and is_equal_approx(demo.sun_azimuth, expected_sun_azimuth) \
			and demo.sun.rotation_degrees.is_equal_approx(
				Vector3(-expected_sun_elevation, expected_sun_azimuth, 0.0)) \
			and (sun_direction - sky_direction).length() < 0.0001 \
			and (sun_direction - cloud_direction).length() < 0.0001,
		"GRA3: persisted sun position did not reach the light, sky and clouds")
	var sun_elevation_slider: HSlider = demo.menu._entries["☀️ Sunlight/Sun elevation"].node
	var sun_azimuth_slider: HSlider = demo.menu._entries["☀️ Sunlight/Sun azimuth"].node
	sun_elevation_slider.value = 42.0
	sun_azimuth_slider.value = 260.0
	_check(demo.sun.light_color != boot_sun_color \
			and demo.sky_material.get_shader_parameter("horizon_color") != boot_horizon,
		"GRA3: changing sun elevation did not update the daylight palette")
	sun_direction = demo.sun.global_basis.z.normalized()
	sky_direction = demo.sky_material.get_shader_parameter("sun_direction")
	cloud_direction = demo.cloudscape._data_material.get_shader_parameter("sun_direction")
	_check(is_equal_approx(demo.sun_elevation, 42.0) \
			and is_equal_approx(demo.sun_azimuth, 260.0) \
			and is_equal_approx(float(settings.get_sim_value(
				"grass_demo", "☀️ Sunlight/Sun elevation", -1.0)), 42.0) \
			and is_equal_approx(float(settings.get_sim_value(
				"grass_demo", "☀️ Sunlight/Sun azimuth", -1.0)), 260.0) \
			and (sun_direction - sky_direction).length() < 0.0001 \
			and (sun_direction - cloud_direction).length() < 0.0001,
		"GRA3: sun sliders did not update and persist the position across renderers")
	_check(demo.grass.near_detail == profile.near_detail \
			and demo.grass.shadows_enabled == profile.shadows \
			and demo.sun.shadow_enabled == profile.shadows \
			and (seed_mode != 0 or is_equal_approx(demo.grass.density, profile.density)),
		"GRA3: quality tier %d did not reach the player boot path" % tier)
	var expected_base: Color = Color(0.22, 0.1, 0.29) if palette_seed == 3 else demo.BASE_COLOR
	var expected_gradient := 0.4 if palette_seed == 3 else 0.0
	_check(demo.grass.demo_stage == 3 \
			and demo._palette_index == palette_seed \
			and demo._palette_option.selected == palette_seed \
			and demo.grass.material.get_shader_parameter("base_color") == expected_base \
			and is_equal_approx(demo.grass.material.get_shader_parameter("chromatic_strength"), expected_gradient) \
			and demo.ground_mesh.material_override.get_shader_parameter("clump_noise") != null,
		"GRA3: grass palette or ground variation missing at player boot")
	demo.apply_look(0)
	demo._palette_action.pressed.emit()
	var palette_caption := demo._palette_action.find_child("ActionCaption", true, false) as Label
	_check(demo._palette_index == 1 and palette_caption.text == "Meadow" \
			and settings.get_sim_value("grass_demo", "🎨 Grass Palette/Palette", -1) == 1 \
			and demo.grass.material.get_shader_parameter("base_color") == demo.COLOR_PALETTES[1].base \
			and demo.grass.material.get_shader_parameter("plume_color") == demo.COLOR_PALETTES[1].plume \
			and demo.ground_mesh.material_override.get_shader_parameter("moss_color") == demo.COLOR_PALETTES[1].moss,
		"GRA3: palette action did not recolor the whole field")
	var custom_ground := Color(0.2, 0.3, 0.1)
	var ground_picker: ColorPickerButton = demo._palette_pickers["straw"]
	ground_picker.color = custom_ground
	ground_picker.color_changed.emit(custom_ground)
	demo._chromatic_slider.value = 0.35
	_check(demo.ground_mesh.material_override.get_shader_parameter("straw_color") == custom_ground \
			and settings.get_sim_value("grass_demo", "🎨 Grass Palette/Ground Light", null) == custom_ground \
			and is_equal_approx(demo.grass.material.get_shader_parameter("chromatic_strength"), 0.35),
		"GRA3: custom palette controls did not update and persist")
	demo.apply_look(3)
	_check(is_equal_approx(demo.grass.material.get_shader_parameter("chromatic_strength"), 0.7) \
			and is_equal_approx(demo.ground_mesh.material_override.get_shader_parameter("chromatic_strength"), 0.7),
		"GRA3: Prism shader colors did not reach grass and ground")
	demo._palette_action.pressed.emit()
	_check(demo._palette_index == 0 and palette_caption.text == "Pampas" \
			and settings.get_sim_value("grass_demo", "🎨 Grass Palette/Palette", -1) == 0,
		"GRA3: palette action did not wrap to Pampas")
	demo._on_stage_selected(2)
	var wind_slider: HSlider = demo.menu._entries["🌿 Grass Properties/Wind Speed"].node
	wind_slider.value = 2.5
	_check(is_equal_approx(demo.grass.wind_speed, 2.5) \
			and is_equal_approx(demo.grass.material.get_shader_parameter("wind_speed"), 2.5) \
			and demo.grass.material.get_shader_parameter("demo_stage") == 2,
		"GRA3: Wind Speed slider did not reach the shader at the Pampas step")
	wind_slider.value = 1.0
	demo._on_stage_selected(3)
	demo.apply_preset(1)
	demo._wind_preset_action.pressed.emit()
	var wind_caption := demo._wind_preset_action.find_child("ActionCaption", true, false) as Label
	_check(is_equal_approx(demo.grass.wind_speed, 2.5) \
			and is_equal_approx(demo.grass.wind_direction_degrees, 70.0) \
			and is_equal_approx(demo.grass.gustiness, 0.85) \
			and wind_caption.text == "Gusty",
		"GRA3: wind preset action did not advance and update the field")
	demo._wind_preset_action.pressed.emit()
	demo._wind_preset_action.pressed.emit()
	_check(wind_caption.text == "Calm" and is_zero_approx(demo.grass.wind_speed),
		"GRA3: wind preset action did not wrap to Calm")
	demo.apply_preset(1)
	var gust_button: Button
	for button in demo.menu._actions:
		var caption := button.find_child("ActionCaption", true, false) as Label
		if caption != null and caption.text == "Gust":
			gust_button = button
	_check(gust_button != null, "GRA3: Gust action missing")
	if gust_button != null:
		gust_button.pressed.emit()
	_check(is_zero_approx(demo.grass._gust_age) and is_equal_approx(demo.grass._gust_strength, 1.0),
		"GRA3: Gust action did not trigger the runtime")
	_check(is_zero_approx(demo.grass._gust_pulse), "GRA3: gust starts with an instant pulse")
	var gust_origin: Vector2 = demo.grass.material.get_shader_parameter("gust_origin")
	var gust_direction: Vector2 = demo.grass.material.get_shader_parameter("gust_direction")
	var gust_distance := (Vector2(demo.orbit_cam.target.x, demo.orbit_cam.target.z) - gust_origin).dot(gust_direction)
	var arrival: float = gust_distance / demo.grass._gust_speed
	var peak_age: float = (gust_distance + 60.0) / demo.grass._gust_speed
	_check(arrival < 2.25 and peak_age < 3.6, "GRA3: Gust action arrives too late in the visible field")
	print("GRA3 GUST BUTTON arrival=%.3fs peak=%.3fs" % [arrival, peak_age])
	demo.grass.tick(0.03, demo.orbit_cam.target, demo.orbit_cam.get_camera().global_position)
	var early_pulse: float = demo.grass._gust_pulse
	demo.grass.tick(0.12, demo.orbit_cam.target, demo.orbit_cam.get_camera().global_position)
	_check(early_pulse > 0.0 and early_pulse < demo.grass._gust_pulse,
		"GRA3: gust does not build gradually")
	_check_grass_gust_coverage(demo.grass)
	demo.grass.tick(demo.grass._gust_duration, demo.orbit_cam.target,
		demo.orbit_cam.get_camera().global_position)
	_check(is_zero_approx(demo.grass._gust_pulse) and demo.grass._gust_age < 0.0 \
			and float(demo.grass.material.get_shader_parameter("gust_age")) < 0.0 \
			and is_zero_approx(float(demo.grass.material.get_shader_parameter("gust_pulse"))),
		"GRA3: expired gust left active shader state")
	_check_grass_deformation()
	var post_fx_rect: ColorRect = demo._post_fx_rect
	_check(post_fx_rect != null and not post_fx_rect.visible \
			and int(demo._post_fx_material.get_shader_parameter("filter_mode")) == 0,
		"GRA3: post filter is not off at boot")
	demo.set_capture_params({"filter": 1})
	_check(post_fx_rect.visible \
			and int(demo._post_fx_material.get_shader_parameter("filter_mode")) == 1 \
			and int(settings.get_sim_value("grass_demo", "🎞 Filters/Filter", -1)) == 1,
		"GRA3: filter capture param did not enable and persist Obra Dinn")
	demo.set_capture_params({"filter": 0})
	_check(not post_fx_rect.visible \
			and int(settings.get_sim_value("grass_demo", "🎞 Filters/Filter", -1)) == 0,
		"GRA3: filter capture param did not switch back to Off")
	if not demo.grass._lod_variants.is_empty():
		generates += 1
		frames.append(-1)
		densities.append(demo.grass.density)
		last_lod_id = (demo.grass._lod_variants[0][0] as MultiMesh).get_instance_id()
		demo.grass.set_demo_stage(0)
		var stage_kept_layout := (demo.grass._lod_variants[0][0] as MultiMesh).get_instance_id() == last_lod_id
		demo.grass.set_demo_stage(3)
		_check(stage_kept_layout, "GRA3: changing the learning step rebuilt grass instances")

	for frame in GRASS_SAMPLE_FRAMES:
		await process_frame
		var grass: Node = demo.grass
		if grass == null:
			continue
		var variants: Array = grass._lod_variants
		if variants.is_empty():
			continue
		var id: int = (variants[0][0] as MultiMesh).get_instance_id()
		if id != last_lod_id:
			generates += 1
			frames.append(frame)
			densities.append(grass.density)
			last_lod_id = id

	var collision_shape: HeightMapShape3D = demo.get_node("Ground/CollisionShape3D").shape
	var collision_image := GRASS_HEIGHTMAP.noise.get_seamless_image(
		collision_shape.map_width, collision_shape.map_depth)
	collision_image.convert(Image.FORMAT_RF)
	var collision_source := collision_image.get_data().to_float32_array()
	var collision_state: PhysicsDirectSpaceState3D = demo.get_world_3d().direct_space_state
	for sample in [Vector2i(192, 192), Vector2i(256, 256),
			Vector2i(320, 320), Vector2i(192, 320)]:
		var world_x := float(sample.x) - float(collision_shape.map_width - 1) * 0.5
		var world_z := float(sample.y) - float(collision_shape.map_depth - 1) * 0.5
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(world_x, 10.0, world_z), Vector3(world_x, -10.0, world_z))
		var hit: Dictionary = collision_state.intersect_ray(query)
		var source_x: int = posmod(sample.x - (collision_shape.map_width >> 1),
			collision_shape.map_width)
		var source_z: int = posmod(sample.y - (collision_shape.map_depth >> 1),
			collision_shape.map_depth)
		var expected_height: float = (collision_source[
			source_x + source_z * collision_shape.map_width]
			- 0.5) * demo.config.heightmap_scale_m
		var collision_matches := not hit.is_empty() \
				and absf(hit.position.y - expected_height) <= 0.01
		_check(collision_matches,
			"GRA3: collision height is misaligned at map sample %s" % sample)
		if not collision_matches:
			break

	var first_variant: Array = demo.grass._lod_variants[0]
	var lod_ordered := true
	var lod_counts: Array[int] = []
	for lod_index in first_variant.size():
		var lod: MultiMesh = first_variant[lod_index]
		lod_counts.append(lod.instance_count)
		if lod_index > 0 and lod.instance_count > lod_counts[lod_index - 1]:
			lod_ordered = false
	for lod_index in range(1, first_variant.size()):
		var fine_lod: MultiMesh = first_variant[lod_index - 1]
		var coarse_lod: MultiMesh = first_variant[lod_index]
		if coarse_lod.instance_count == 0:
			continue
		for sample_index in [0, coarse_lod.instance_count - 1]:
			if not coarse_lod.get_instance_transform(sample_index).origin \
					.is_equal_approx(fine_lod.get_instance_transform(sample_index).origin):
				lod_ordered = false
	_check(lod_ordered and lod_counts[0] >= lod_counts[1] and lod_counts[1] >= lod_counts[2] \
			and lod_counts[2] >= lod_counts[3] and lod_counts[3] >= lod_counts[4],
		"GRA3: LOD levels are not graded subsets of one layout")
	var first_tile: MultiMeshInstance3D = demo.grass._tiles[0][0]
	_check(first_tile.custom_aabb.position.x <= -9.0 \
			and first_tile.custom_aabb.position.z <= -9.0 \
			and first_tile.custom_aabb.position.y <= -3.5 \
			and first_tile.custom_aabb.size.y >= 9.0,
		"GRA3: grass tile bounds do not cover maximum wind displacement")
	var shadow_source: MultiMesh = demo.grass._lod_variants[
		demo.grass._variant_for_tile(first_tile)][2]
	var expected_shadow: Transform3D = shadow_source.get_instance_transform(0)
	expected_shadow.origin += demo.grass._tiles[0][1]
	var baked_shadow: Transform3D = demo.grass._shadow_instance.multimesh.get_instance_transform(0)
	_check(baked_shadow.origin.is_equal_approx(expected_shadow.origin),
		"GRA3: shadow proxy transforms do not match their tile source")

	for profile_tier in range(4):
		demo.set_quality_profile(profile_tier)
		var tier_values: Dictionary = GrassQualityProfile.values(profile_tier)
		var tier_matches: bool = is_equal_approx(demo.grass.density, tier_values.density) \
				and demo.grass.near_detail == tier_values.near_detail \
				and demo.grass.shadows_enabled == tier_values.shadows \
				and demo.sun.shadow_enabled == tier_values.shadows \
				and (float(demo.cloudscape._shadow_material.get_shader_parameter("cloud_shadow_strength")) > 0.0) \
					== bool(tier_values.shadows) \
				and is_equal_approx(demo.shadow_distance_m,
					tier_values.shadow_distance_m) \
				and is_equal_approx(demo.sun.directional_shadow_max_distance,
					tier_values.shadow_distance_m)
		var expected_casting := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
			if tier_values.shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var shadow_instance: MultiMeshInstance3D = demo.grass._shadow_instance
		tier_matches = tier_matches and shadow_instance.cast_shadow == expected_casting \
			and shadow_instance.multimesh.instance_count < first_tile.multimesh.instance_count \
				* demo.grass._tiles.size()
		for tile_data in demo.grass._tiles:
			if tile_data[0].cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				tier_matches = false
				break
		_check(tier_matches, "GRA3: live quality switch failed at tier %d" % profile_tier)
		if not tier_matches:
			break
	var shadow_distance_slider: HSlider = demo.menu._entries["⚙️ Rendering/Shadow distance"].node
	shadow_distance_slider.value = 53.0
	_check(is_equal_approx(demo.shadow_distance_m, 53.0) \
			and is_equal_approx(demo.sun.directional_shadow_max_distance, 53.0),
		"GRA3: shadow distance slider did not update the light")

	if _failures > 0:
		printerr("GRA3 PROBE FAIL: %d check(s)" % _failures)
		quit(1)
		return
	print("GRA3 PROBE DONE seed=%d tier=%d generates=%d frames=%s densities=%s final_density=%.3f near_detail=%s" % [
		seed_mode, tier, generates, str(frames), str(densities), demo.grass.density,
		str(demo.grass.near_detail)])
	quit(0)


func _check_grass_gust_coverage(grass: GrassRenderer) -> void:
	var original_direction := grass.wind_direction_degrees
	var checked := 0
	for degrees in [0.0, 35.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]:
		grass.set_wind_direction(degrees)
		grass.add_gust(4.0, Vector3(127.0, 0.0, -63.0))
		var direction: Vector2 = grass.material.get_shader_parameter("gust_direction")
		var origin: Vector2 = grass.material.get_shader_parameter("gust_origin")
		var half := grass.config.tile_size_m * 0.5
		for data in grass._tiles:
			var position: Vector3 = data[0].global_position
			for corner in [Vector2(-half, -half), Vector2(half, -half),
					Vector2(-half, half), Vector2(half, half)]:
				var distance: float = (Vector2(position.x, position.z) + corner - origin).dot(direction)
				var peak_age: float = (distance + 60.0) / grass._gust_speed
				_check(distance >= 8.99 and peak_age >= 0.15 \
						and (distance + 190.0) / grass._gust_speed <= grass._gust_release_start + 0.001 \
						and (distance + 275.0) / grass._gust_speed <= grass._gust_duration + 0.001,
					"GRA3: gust missed a tile corner or expired before its recoil")
				checked += 1
	grass.set_wind_direction(original_direction)
	print("GRA3 GUST coverage_corners=%d directions=8" % checked)


func _check_grass_deformation() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("GRA3 DEFORMATION SKIP renderer has no GPU device")
		return
	var shader_text := FileAccess.get_file_as_string("res://shaders/grass/grass.gdshader")
	var functions := shader_text.substr(shader_text.find("mat3 rotate_y"))
	functions = functions.substr(0, functions.find("void vertex()"))
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) readonly buffer Inputs { vec4 inputs[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Results { vec4 results[]; };
layout(push_constant, std430) uniform Params { uint count; } params;
""" + functions + """
void main() {
	uint id = gl_GlobalInvocationID.x;
	if (id >= params.count) { return; }
	vec4 vertex = inputs[id * 4];
	vec4 root = inputs[id * 4 + 1];
	vec4 curve = inputs[id * 4 + 2];
	vec4 part_bend = inputs[id * 4 + 3];
	float head = float(part_bend.x == 1.0);
	float pampas = float(part_bend.x > 0.0);
	mat3 rest = rotate_y(0.61) * mat3(vec3(0.83,0,0), vec3(0,1.37,0), vec3(0,0,1));
	vec3 position = rest * vertex.xyz;
	if (head > 0.5) {
		vec3 pivot = rest * vec3(0.71 * 0.38, 1.1, 0.71 * 0.38);
		position = pivot + rotate_y(0.3) * (position - pivot) * 1.2;
	}
	mat3 normal_rotation;
	vec3 bent = bend_tuft_vertex(position, root, curve, vertex.w, pampas, head,
		1.0, rest, part_bend.zw, normal_rotation);
	float residue = wind_flutter(12.34, 2.5, 1.0, 4.7, 0.0, 1.0)
		- wind_flutter(12.34, 2.5, 1.0, -1.0, 0.0, 0.0);
	float distance = 9.0 + float(id) * 0.25;
	vec2 peak = gust_envelope(distance, (distance + 60.0) / 200.0, 200.0);
	results[id] = vec4(bent, abs(residue) + abs(peak.x - 1.0) + abs(peak.y));
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	_check(spirv.compile_error_compute.is_empty(), "GRA3: deformation shader: " + spirv.compile_error_compute)
	if not spirv.compile_error_compute.is_empty():
		rd.free()
		return
	var cases: Array = []
	var input := PackedFloat32Array()
	var builder := preload("res://scripts/grass/grass_multimesh_builder.gd")
	for detailed in [false, true]:
		var arrays: Array = builder.make_tuft_mesh(detailed).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var roots: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		var curves: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
		for bend in [Vector2.ZERO, Vector2(-0.18, 0.04), Vector2(0.5, -0.05), Vector2(0.86, 0.6), Vector2(1.17, 0.77)]:
			cases.append([arrays, input.size() / 16, bend])
			for index in vertices.size():
				var kind := floorf(uv[index].x * 0.5)
				input.append_array(PackedFloat32Array([vertices[index].x, vertices[index].y,
					vertices[index].z, uv[index].y if kind == 0.0 else uv[index].y / 0.75]))
				for metadata in [roots, curves]:
					for channel in 4:
						input.append(metadata[index * 4 + channel])
				input.append_array(PackedFloat32Array([kind, 1.0, bend.x, bend.y]))
	var count := input.size() / 16
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var input_buffer := rd.storage_buffer_create(input.size() * 4, input.to_byte_array())
	var output_buffer := rd.storage_buffer_create(count * 16)
	var uniforms: Array[RDUniform] = []
	for binding in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(input_buffer if binding == 0 else output_buffer)
		uniforms.append(uniform)
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	var compute := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute, pipeline)
	rd.compute_list_bind_uniform_set(compute, uniform_set, 0)
	var push_constants := PackedInt32Array([count, 0, 0, 0]).to_byte_array()
	rd.compute_list_set_push_constant(compute, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute, ceili(float(count) / 64.0), 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var output := rd.buffer_get_data(output_buffer).to_float32_array()
	var rest := Basis(Vector3.UP, 0.61) * Basis.from_scale(Vector3(0.83, 1.37, 1.0))
	var max_error := 0.0
	var max_joint_gap := 0.0
	var segments := 0
	for sample in cases:
		var arrays: Array = sample[0]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var positions := PackedVector3Array()
		var rest_positions := PackedVector3Array()
		var stalk_tip := Vector3.ZERO
		for index in vertices.size():
			var offset := (int(sample[1]) + index) * 4
			positions.append(Vector3(output[offset], output[offset + 1], output[offset + 2]))
			_check(absf(output[offset + 3]) < 0.000001, "GRA3: gust envelope or flutter regression")
			var position := rest * vertices[index]
			if uv[index].x >= 2.0 and uv[index].x <= 3.0:
				var pivot := rest * Vector3(0.71 * 0.38, 1.1, 0.71 * 0.38)
				position = pivot + Basis(Vector3.UP, 0.3) * (position - pivot) * 1.2
			rest_positions.append(position)
			if sample[2] == Vector2.ZERO:
				_check(position.distance_to(positions[index]) < 0.000002,
					"GRA3: deformation changes the resting tuft")
		for triangle in range(0, indices.size(), 6):
			var a := indices[triangle]
			var b := indices[triangle + 1]
			var c := indices[triangle + 2]
			var d := indices[triangle + 5]
			var rest_length := ((rest_positions[c] + rest_positions[d]) * 0.5).distance_to(
				(rest_positions[a] + rest_positions[b]) * 0.5)
			var bent_length := ((positions[c] + positions[d]) * 0.5).distance_to(
				(positions[a] + positions[b]) * 0.5)
			max_error = maxf(max_error, absf(bent_length / rest_length - 1.0))
			segments += 1
			if uv[c].x >= 4.0 and is_equal_approx(uv[c].y, 0.75):
				stalk_tip = (positions[c] + positions[d]) * 0.5
			if uv[a].x == 2.0 and is_equal_approx(uv[a].y, 0.75):
				max_joint_gap = maxf(max_joint_gap, stalk_tip.distance_to((positions[a] + positions[b]) * 0.5))
	_check(max_error < 0.00001, "GRA3: wind stretches grass segments: %.8f" % max_error)
	_check(max_joint_gap < 0.000002, "GRA3: wind detaches plume from stalk: %.8f" % max_joint_gap)
	print("GRA3 DEFORMATION segments=%d max_relative_length_error=%.8f max_joint_gap=%.8f flutter_residue=0" % [segments, max_error, max_joint_gap])
	for resource in [uniform_set, pipeline, shader, input_buffer, output_buffer]:
		rd.free_rid(resource)
	rd.free()


## ── mixopt ──────────────────────────────────────────────────────────────
## Boot-path probe for the Mixwell demo options and snapshot-cache churn: it
## instantiates res://scenes/mixwell_demo.tscn exactly like a player launch
## (GameManager.current_demo set, no harness) and drives the public option API.
##
## Checks:
## - every quality tier lands the tier-table spp in config AND in the dropdown
##   (the tier push passes the raw spp, the menu passes an index — both paths);
## - picking an official example re-syncs the Source dropdown;
## - the comparison overlay re-syncs the Display widget and drops diagnostics;
## - idle accumulation does not rebuild the render snapshot every frame.
##
## Log lines start with "MIXOPT ".

func _run_mixopt() -> void:
	await _boot_frames(2)
	var failures := 0
	var settings: Node = root.get_node("/root/UserSettings")
	settings.clear_sim("mixwell_demo")
	var manager: Node = root.get_node("/root/GameManager")
	manager.current_demo = "mixwell_demo"
	manager.set_setting("mixwell_quality_profile", 1)

	var demo: Node = load("res://scenes/mixwell_demo.tscn").instantiate()
	root.add_child(demo)
	for i in 10:
		await process_frame
	if not demo.solver.is_initialized():
		print("MIXOPT FAIL solver not initialized (GPU compute unavailable?)")
		quit(1)
		return
	print("MIXOPT boot ok quality=%s" % demo.quality.label())

	# Quality tiers: the raw spp must reach config and the dropdown item.
	var tier := (int(demo.quality.requested) + 1) % 4
	for step in 4:
		while demo._render_transition or not demo.solver.is_initialized():
			await process_frame
		demo.quality.set_tier(tier)
		for i in 4:
			await process_frame
		var expected: int = MixwellQualityProfile.values(tier).target_spp
		var actual: int = demo.config.target_spp
		if actual != expected:
			failures += 1
			print("MIXOPT FAIL tier %d config.target_spp=%d expected %d" % [tier, actual, expected])
		var node: OptionButton = demo.quality._controls["target_spp"].node
		var shown := MixwellConfig.SPP_TARGETS.find(expected)
		if node.selected != shown:
			failures += 1
			print("MIXOPT FAIL tier %d spp dropdown item=%d expected %d" % [tier, node.selected, shown])
		tier = (tier + 1) % 4
	if failures == 0:
		print("MIXOPT PASS quality tiers drive spp + dropdown")

	# Official examples must re-sync the Source dropdown (Fig. 15 grid -> source 0).
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	demo._select_official_example(4)
	await process_frame
	if demo.source_option.selected != demo.source_mode:
		failures += 1
		print("MIXOPT FAIL source dropdown %d != source_mode %d" % [
			demo.source_option.selected, demo.source_mode])
	elif demo.config.source_mode != 0 or demo.solver.get_boundary_mode() \
			!= demo.config.boundary_mode:
		failures += 1
		print("MIXOPT FAIL example source not applied to config/solver")
	else:
		print("MIXOPT PASS official example re-syncs Source dropdown")

	# The comparison overlay forces Result view: Display widget + diagnostics follow.
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	demo._select_display(4)
	if not demo.solver.diagnostics_enabled():
		failures += 1
		print("MIXOPT FAIL display 'Area error' did not enable diagnostics")
	demo._select_comparison(1)
	if demo.display_mode != 0 or demo.display_option.selected != 0:
		failures += 1
		print("MIXOPT FAIL comparison left display_mode=%d widget=%d" % [
			demo.display_mode, demo.display_option.selected])
	elif demo.solver.diagnostics_enabled():
		failures += 1
		print("MIXOPT FAIL diagnostics still enabled under comparison overlay")
	else:
		print("MIXOPT PASS comparison overlay re-syncs Display + diagnostics")
	demo._select_comparison(0)
	await process_frame

	# Idle accumulation: the snapshot cache must hold (no per-frame rebuilds).
	while demo._render_transition or not demo.solver.is_initialized():
		await process_frame
	var builds_before: int = demo.solver.snapshot_build_count
	for i in CHURN_FRAMES:
		await process_frame
	var built: int = demo.solver.snapshot_build_count - builds_before
	if built > MAX_IDLE_BUILDS:
		failures += 1
		print("MIXOPT FAIL snapshot rebuilt %dx in %d idle frames" % [built, CHURN_FRAMES])
	else:
		print("MIXOPT PASS snapshot cache held (%d builds / %d frames)" % [built, CHURN_FRAMES])
	if demo.status_label.text.is_empty():
		failures += 1
		print("MIXOPT FAIL status label empty")
	else:
		print("MIXOPT PASS status label populated")

	if failures == 0:
		print("MIXOPT PROBE DONE ok")
		quit(0)
	else:
		print("MIXOPT PROBE DONE failures=%d" % failures)
		quit(1)


## ── tornado_boot_look ───────────────────────────────────────────────────
## Boot-parity probe: instantiates the tornado demo the way a player run does
## (no capture harness, no apply_look call) and asserts the look state
## _apply_storm_type(0) must apply at boot. The funnel/particles historically
## kept their brown shader-default dust when the boot call was missing, which
## capture-only validation masked because the harness always calls apply_look.
## Sentinel: "TEST PASS tornado_boot_look" (GPU phase of tests/run_tests.sh).

func _check_boot_look() -> void:
	_check(_demo.get("storm_type") == 0,
		"boot did not leave storm_type at the Normal default")
	var funnel_mat: ShaderMaterial = _demo.get_node("Tornado/FunnelVolume").material_override
	var cloud_mat: ShaderMaterial = _demo.get_node("Tornado/CloudDeck").material_override
	var dust_mat: ShaderMaterial = _demo.get_node("Tornado/DustParticles").process_material
	var skirt_mat: ShaderMaterial = _demo.get_node("Tornado/SkirtParticles").process_material
	var ground_mesh: MeshInstance3D = _demo.get_node("Ground/MeshInstance3D")
	var ground_mat: Material = ground_mesh.material_override \
		if ground_mesh.material_override != null \
		else ground_mesh.get_surface_override_material(0)
	_check(ground_mat is ShaderMaterial
		and (ground_mat as ShaderMaterial).shader != null
		and (ground_mat as ShaderMaterial).shader.resource_path == GROUND_SHADER_PATH,
		"ground does not use %s at boot" % GROUND_SHADER_PATH)
	_check(_param(funnel_mat, "storm_type") == 0
		and _param(cloud_mat, "storm_type") == 0
		and _param(ground_mat as ShaderMaterial, "storm_type") == 0,
		"boot did not push storm_type into the funnel/cloud/ground materials")
	var storm_color: Color = _demo.get("storm_color")
	_check(_param_color(funnel_mat, "funnel_color", storm_color),
		"boot funnel_color %s does not match the storm color %s" % [
			_param(funnel_mat, "funnel_color"), storm_color])
	var deck_tone: Color = storm_color.lerp(Color(0.5, 0.52, 0.57), 0.22)
	_check(_param_color(funnel_mat, "deck_color", deck_tone),
		"boot deck_color %s does not match the derived deck tone %s" % [
			_param(funnel_mat, "deck_color"), deck_tone])
	_check(_param_color(cloud_mat, "cloud_color", deck_tone),
		"boot cloud_color %s does not match the derived deck tone %s" % [
			_param(cloud_mat, "cloud_color"), deck_tone])
	var dust_color := Color(0.46, 0.46, 0.48)
	_check(_param_color(funnel_mat, "dust_color", dust_color)
		and _param_color(cloud_mat, "dust_color", dust_color),
		"boot kept the shader-default dust color on the funnel/cloud")
	_check(_param_color(dust_mat, "particle_color", dust_color)
		and _param_color(skirt_mat, "particle_color", dust_color),
		"boot kept the shader-default particle color on the dust/skirt particles")
	_check(_param_color(ground_mat as ShaderMaterial, "ground_a", Color(0.27, 0.235, 0.19))
		and _param_color(ground_mat as ShaderMaterial, "ground_b", Color(0.185, 0.17, 0.15))
		and _param_color(ground_mat as ShaderMaterial, "ground_accent", Color(0.14, 0.135, 0.13))
		and _paramf(ground_mat as ShaderMaterial, "ground_glow", 0.0),
		"boot did not apply the Normal ground palette")
	var env: Environment = _demo.get_node("WorldEnvironment").environment
	_check(_color_near(env.background_color, Color(0.45, 0.47, 0.52))
		and _color_near(env.fog_light_color, Color(0.3, 0.32, 0.37))
		and _color_near(env.ambient_light_color, Color(0.5, 0.52, 0.57)),
		"boot did not apply the Normal environment palette")


func _param(material: Material, parameter: StringName) -> Variant:
	return (material as ShaderMaterial).get_shader_parameter(parameter)


func _param_color(material: ShaderMaterial, parameter: StringName,
		expected: Color) -> bool:
	var value: Variant = material.get_shader_parameter(parameter)
	return value is Color and _color_near(value, expected)


func _paramf(material: ShaderMaterial, parameter: StringName, expected: float) -> bool:
	var value: Variant = material.get_shader_parameter(parameter)
	return value is float and absf(value - expected) < 1.0e-4


func _color_near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 1.0e-4 and absf(a.g - b.g) < 1.0e-4 \
		and absf(a.b - b.b) < 1.0e-4 and absf(a.a - b.a) < 1.0e-4


## ── fps ─────────────────────────────────────────────────────────────────
## Quality-tier fps probe: loads a demo, applies a tier through its
## SimQualityState, and reports the average fps over a wall-clock window with
## vsync off. Read-only with respect to persistence — GameManager.set_setting
## only touches the in-memory dictionary, and the process quits without saving.
##
##   tests/probe.sh fps nbody_demo medium
##   godot -s res://tests/probe.gd -- fps target=ocean_demo tier=3 seconds=6

func _fps_parse_args() -> bool:
	for arg in _extra:
		var split: PackedStringArray = arg.split("=", true, 1)
		if split.size() == 1:
			_fps_set_target(arg)
			continue
		var value: String = split[1]
		match String(split[0]):
			"target": _fps_set_target(value)
			"tier":
				var lowered := value.to_lower()
				_tier = TIER_NAMES.find(lowered)
				if _tier < 0:
					_tier = clampi(int(value), 0, TIER_NAMES.size() - 1)
			"seconds": _seconds = clampf(float(value), 1.0, 60.0)
			"warmup": _warmup = maxi(0, int(value))
			"settle": _fps_settle_seconds = clampf(float(value), 0.0, 60.0)
			"size":
				var dims := value.split("x")
				if dims.size() == 2:
					_size = Vector2i(maxi(16, int(dims[0])), maxi(16, int(dims[1])))
			"bodies": _fps_bodies = clampi(int(value), 1, 40)
			"medium": _fps_medium = clampi(int(value), 0, 4)
	if _scene_path == "" or _tier < 0:
		push_error("FPS PROBE FAIL: need a demo target and tier=" + str(TIER_NAMES))
		quit(1)
		return false
	return true


func _fps_set_target(value: String) -> void:
	if "://" in value:
		_scene_path = value
		return
	for entry in GameManager.DEMOS:
		if entry.key == value:
			_scene_path = entry.scene
			root.get_node("GameManager").set("current_demo", entry.key)
			return
	push_error("FPS PROBE FAIL: unknown demo key %s" % value)
	quit(1)


func _run_fps() -> void:
	await process_frame
	if not await _fps_wait_ready():
		return
	if _demo.has_method("set_quality_profile"):
		_demo.set_quality_profile(_tier)
	elif "quality" in _demo and _demo.quality is SimQualityState:
		_demo.quality.set_tier(_tier)
	else:
		push_error("FPS PROBE FAIL: %s has no quality state" % _scene_path)
		quit(1)
		return
	if not await _fps_wait_ready():
		return
	if _fps_medium >= 0:
		if not _demo.has_method("set_capture_medium"):
			push_error("FPS PROBE FAIL: target does not support medium selection")
			quit(1)
			return
		_demo.set_capture_medium(_fps_medium)
	if _fps_bodies > 0:
		if not _demo.has_method("_throw_object"):
			push_error("FPS PROBE FAIL: target does not support body population")
			quit(1)
			return
		_demo.set("max_objects", _fps_bodies)
		_demo.set("_object_index", 3)
		_demo.set("_object_density_kg_m3", 650.0)
		_demo.set("_throw_speed_m_s", 1.0)
		var bodies: Array = _demo.get("bodies")
		while bodies.size() < _fps_bodies:
			_demo.call("_throw_object")
			bodies = _demo.get("bodies")
	# UserSettings restores the persisted window size once the autoloads are in;
	# force the requested size back so the measurement is deterministic.
	root.size = _size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var settle_deadline := Time.get_ticks_usec() + int(_fps_settle_seconds * 1_000_000.0)
	while Time.get_ticks_usec() < settle_deadline:
		await process_frame
	for frame in _warmup:
		await process_frame
	var frames := 0
	var t0 := Time.get_ticks_usec()
	var deadline := t0 + int(_seconds * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		frames += 1
	var elapsed := float(Time.get_ticks_usec() - t0) / 1_000_000.0
	var population := ""
	if _demo.has_method("_throw_object"):
		var live_bodies: Array = _demo.get("bodies")
		population = " bodies=%d" % live_bodies.size()
	print("FPS PROBE target=%s tier=%s fps=%.1f frames=%d seconds=%.2f settle=%.1f size=%dx%d%s" % [
		_scene_path.get_file().get_basename(), TIER_NAMES[_tier],
		float(frames) / elapsed, frames, elapsed, _fps_settle_seconds,
		_size.x, _size.y, population])
	quit(0)


## Same readiness contract as capture_demo: demos expose capture_ready() when
## their GPU resources are up, and a tier switch can rebuild them.
func _fps_wait_ready() -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("FPS PROBE FAIL: target did not become ready")
		quit(1)
		return false
	return true


## ── foam_convergence / foam_histogram (shared readback helpers) ─────────

func _half(bits: int) -> float:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return NAN
	var sign := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return sign * mantissa * pow(2.0, -24.0)
	return sign * (1.0 + mantissa / 1024.0) * pow(2.0, exponent - 15)


func _read_texture(rid: RID, layer: int, expected_bytes: int = 0) -> PackedByteArray:
	var data: PackedByteArray = await TextureReadback.new().read_layer(rid, layer,
		expected_bytes)
	if data.is_empty():
		push_error("PROBE FAIL: texture readback failed (timeout or size mismatch)")
	return data


func _foam_base(data: PackedByteArray, size: int) -> PackedByteArray:
	var base_bytes := size * size * 8
	var expected := 0
	var mip_size := size
	while mip_size > 0:
		expected += mip_size * mip_size * 8
		mip_size /= 2
	if data.size() != expected:
		return PackedByteArray()
	return data.slice(0, base_bytes)


## ── foam_convergence ────────────────────────────────────────────────────
## Reads back normal/foam textures at frames 60/180/600/1800/3600, prints
## "FOAM CONVERGENCE" stats, fails on non-finite/unbounded fields.

func _foam_source_stats(data: PackedByteArray, size: int) -> Dictionary:
	var finite := 0
	var active := 0
	var sum := 0.0
	for i in size * size:
		var value := _half(data.decode_u16(i * 8 + 6))
		if is_nan(value) or is_inf(value):
			continue
		finite += 1
		sum += value
		if value > 0.035:
			active += 1
	return {
		"mean": sum / maxf(float(finite), 1.0),
		"coverage": float(active) / maxf(float(finite), 1.0),
		"finite": finite,
		"expected": size * size,
	}


func _foam_stats(data: PackedByteArray, size: int) -> Dictionary:
	var finite := 0
	var persistent_sum := 0.0
	var fresh_sum := 0.0
	var maximum := 0.0
	var minimum := 0.0
	for i in size * size:
		var persistent := data.decode_float(i * 8)
		var fresh := data.decode_float(i * 8 + 4)
		if is_nan(persistent) or is_inf(persistent) \
				or is_nan(fresh) or is_inf(fresh):
			continue
		finite += 1
		persistent_sum += persistent
		fresh_sum += fresh
		maximum = maxf(maximum, maxf(persistent, fresh))
		minimum = minf(minimum, minf(persistent, fresh))
	var divisor := maxf(float(finite), 1.0)
	return {
		"persistent": persistent_sum / divisor,
		"fresh": fresh_sum / divisor,
		"max": maximum,
		"min": minimum,
		"finite": finite,
		"expected": size * size,
	}


func _run_foam_convergence() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline \
			and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("FOAM PROBE FAIL: ocean did not initialize before deadline")
		demo.queue_free()
		quit(1)
		return
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	deadline = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("FOAM PROBE FAIL: quality did not initialize")
		quit(1)
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(FIXED_DT)
	demo.set_capture_ui(false)
	demo.set_capture_interaction(false)
	demo.set_frozen(false)
	var elapsed := 0
	var map_size: int = demo.solver.map_size
	var near_size: int = demo.solver.foam_near_size
	print("FOAM PROBE preset=Storm quality=High seed=1000,31337 domains=%s map_size=%d near_size=%d" % [
		demo.solver.foam_field_domains(), map_size, near_size])
	for target in CONV_SAMPLE_FRAMES:
		while elapsed < target:
			demo.move_capture_camera(Vector3(0.5, 0.0, 0.0))
			await process_frame
			elapsed += 1
		demo.set_frozen(true)
		var lines: Array[String] = []
		for layer in 3:
			var normal := await _read_texture(demo.solver.get_normal_tex_rid(), layer,
				map_size * map_size * 8)
			var foam := _foam_base(await _read_texture(
				demo.solver.get_foam_near_read_tex_rid(), layer), near_size)
			if normal.is_empty() or foam.is_empty():
				push_error("FOAM PROBE FAIL: empty layer %d at frame %d" % [layer, target])
				demo.queue_free()
				quit(1)
				return
			var source := _foam_source_stats(normal, map_size)
			var field := _foam_stats(foam, near_size)
			if source.finite != source.expected or field.finite != field.expected or field.max > 1.0 or field.min < 0.0:
				push_error("FOAM PROBE FAIL: non-finite or unbounded field")
				quit(1)
				return
			lines.append("layer=%d cascade_source_mean=%.6f cascade_source_cov=%.6f persistent_mean=%.6f fresh_mean=%.6f max=%.6f source_finite=%d/%d foam_finite=%d/%d" % [
				layer, source.mean, source.coverage, field.persistent, field.fresh,
				field.max, source.finite, source.expected, field.finite, field.expected])
		print("FOAM CONVERGENCE frame=%d seconds=%.1f state=%s %s" % [
			target, float(target) * FIXED_DT, JSON.stringify(demo.solver.foam_state()), " | ".join(lines)])
		demo.set_frozen(false)
	demo.queue_free()
	await process_frame
	print("FOAM CONVERGENCE DONE")
	quit(0)


## ── foam_histogram ──────────────────────────────────────────────────────
## Runs 600 frames, reads back foam layers, prints "HISTO" stats +
## source-alpha histograms.

func _field_stats(source: PackedByteArray, source_size: int,
		foam: PackedByteArray, foam_size: int) -> Dictionary:
	var source_texels := source_size * source_size
	var foam_texels := foam_size * foam_size
	var source_sum := 0.0
	var persistent_sum := 0.0
	var fresh_sum := 0.0
	var maximum := 0.0
	var source_finite := 0
	var foam_finite := 0
	var source_active := 0
	for i in source_texels:
		var source_value := _half(source.decode_u16(i * 8 + 6))
		if is_nan(source_value) or is_inf(source_value):
			continue
		source_finite += 1
		source_sum += source_value
		if source_value > 0.035:
			source_active += 1
	for i in foam_texels:
		var persistent := foam.decode_float(i * 8)
		var fresh := foam.decode_float(i * 8 + 4)
		if is_nan(persistent) or is_inf(persistent) \
				or is_nan(fresh) or is_inf(fresh):
			continue
		foam_finite += 1
		persistent_sum += persistent
		fresh_sum += fresh
		maximum = maxf(maximum, maxf(persistent, fresh))
	var source_divisor := maxf(float(source_finite), 1.0)
	var foam_divisor := maxf(float(foam_finite), 1.0)
	return {
		"source_mean": source_sum / source_divisor,
		"source_coverage": float(source_active) / source_divisor,
		"persistent_mean": persistent_sum / foam_divisor,
		"fresh_mean": fresh_sum / foam_divisor,
		"max": maximum,
		"finite": foam_finite,
		"expected": foam_texels,
		"source_finite": source_finite,
		"source_expected": source_texels,
	}


func _histogram(data: PackedByteArray, size: int, offset: int, stride: int) -> String:
	var bins := PackedInt32Array()
	bins.resize(21)
	var count := 0
	for i in range(0, size * size, stride):
		var value := _half(data.decode_u16(i * 8 + offset))
		if is_nan(value) or is_inf(value):
			continue
		bins[mini(int(clampf(value, 0.0, 1.0) * 20.0), 20)] += 1
		count += 1
	var line := ""
	for bin in 21:
		line += " %.0f" % (float(bins[bin]) * 100.0 / maxf(float(count), 1.0))
	return line


func _run_foam_histogram() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline \
			and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("HISTO FAIL: ocean did not initialize before deadline")
		demo.queue_free()
		quit(1)
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(1.0 / 30.0)
	demo.set_frozen(false)
	for frame in 600:
		await process_frame
	demo.set_frozen(true)
	await process_frame
	var size: int = demo.solver.foam_near_size
	var map_size: int = demo.solver.map_size
	var normal_layers: Array[PackedByteArray] = []
	var foam_layers: Array[PackedByteArray] = []
	for layer in 3:
		normal_layers.append(await _read_texture(demo.solver.get_normal_tex_rid(), layer,
			map_size * map_size * 8))
		foam_layers.append(_foam_base(await _read_texture(
			demo.solver.get_foam_near_read_tex_rid(), layer), size))
		if normal_layers[layer].is_empty() or foam_layers[layer].is_empty():
			push_error("HISTO FAIL: empty layer %d readback" % layer)
			demo.queue_free()
			quit(1)
			return
		var stats := _field_stats(normal_layers[layer], map_size, foam_layers[layer], size)
		if stats.finite != stats.expected or stats.source_finite != stats.source_expected:
			push_error("HISTO FAIL: non-finite field")
			quit(1)
			return
		print("HISTO layer=%d cascade_source_mean=%.6f cascade_source_cov=%.6f persistent_mean=%.6f fresh_mean=%.6f max=%.6f finite=%d/%d source_finite=%d/%d" % [
			layer, stats.source_mean, stats.source_coverage, stats.persistent_mean,
			stats.fresh_mean, stats.max, stats.finite, stats.expected,
			stats.source_finite, stats.source_expected])
		print("HISTO layer=%d source_alpha:%s" % [layer,
			_histogram(normal_layers[layer], map_size, 6, 4)])
	demo.queue_free()
	await process_frame
	print("HISTO DONE")
	quit(0)
