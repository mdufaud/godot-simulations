extends "res://tests/test_case.gd"

## The project's single probe entry point: every probe is a `_run_<name>`
## method here, dispatched by tests/probe.sh (setsid + timeout + group kill on
## an isolated virtual Wayland display) or directly by the GPU phase of
## tests/run_tests.sh. `tests/probe.sh list` prints the names. Only
## tornado_boot_look (frame-driven) and fps (boots its scene here) dispatch
## outside the _run_<name> convention.

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const GRASS_HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const OceanParameterProbe := preload("res://tests/ocean_parameter_probe.gd")
const OceanCoastalProbe := preload("res://tests/ocean_coastal_probe.gd")
const OceanBreakerProbe := preload("res://tests/ocean_breaker_probe.gd")
const WaterfallField := preload("res://scripts/demos/river/river_waterfall_landscape.gd")
const SlopeLandscape := preload("res://scripts/demos/river/river_slope_landscape.gd")

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
var _fps_params: Dictionary = {}
var _fps_profile := false

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


## The smoke demo boots on its stored preset and tier without any harness, and
## every preset, tier and lane action reaches the same consistent state.
func _run_smoke_boot() -> void:
	var demo = (load("res://scenes/smoke_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	if not await _smoke_ready(demo):
		_check(false, "smoke_boot: boot scene never became ready")
		_finish("smoke_boot")
		return
	var boot_preset := clampi(int(demo.menu.stored_value("Scene", "Preset", 0)), 0,
		demo.PRESETS.size() - 1)
	_check(demo.preset_idx == boot_preset, "smoke_boot: booted on preset %d, stored %d" % [
		demo.preset_idx, boot_preset])
	_smoke_check_state(demo, "boot")
	for index in demo.PRESETS.size():
		demo.apply_preset(index)
		_check(await _smoke_ready(demo), "smoke_boot: preset %d never became ready" % index)
		_smoke_check_state(demo, "preset %d" % index)
	for tier in SmokeQualityProfile.tier_count():
		demo.set_quality_profile(tier)
		_check(await _smoke_ready(demo), "smoke_boot: tier %d never became ready" % tier)
		_smoke_check_state(demo, "tier %d" % tier)
	demo.set_quality_profile(SmokeQualityProfile.default_tier())
	_check(await _smoke_ready(demo), "smoke_boot: default tier never became ready")
	var lights_before: int = demo.props.volume_lights().size()
	demo.throw_flare()
	demo.scene_action()
	demo.set_paused(true)
	await _boot_frames(3)
	demo.set_paused(false)
	demo.set_emitters_on(false)
	demo.set_emitters_on(true)
	_check(demo.props._flares.size() == 1, "smoke_boot: throw spawned %d flares" % [
		demo.props._flares.size()])
	_check(demo.props.volume_lights().size() == lights_before + 1,
		"smoke_boot: the thrown flare added no light to the smoke")
	_check(demo.solver.source_count() > 0, "smoke_boot: no source reached the solver")
	demo.next_preset()
	_check(await _smoke_ready(demo), "smoke_boot: next preset never became ready")
	demo.reset_scene()
	_check(await _smoke_ready(demo), "smoke_boot: reset never became ready")
	_smoke_check_state(demo, "after actions")
	print("SMOKE BOOT presets=%d tiers=%d failures=%d" % [demo.PRESETS.size(),
		SmokeQualityProfile.tier_count(), _failures])
	demo.queue_free()
	await process_frame
	_finish("smoke_boot")


func _smoke_ready(demo) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if demo.capture_ready():
			await _boot_frames(2)
			return true
	return false


func _smoke_check_state(demo, label: String) -> void:
	var preset: SmokePreset = demo.PRESETS[demo.preset_idx]
	var config: SmokeConfig = demo.solver.config
	var values: Dictionary = SmokeQualityProfile.values(demo.quality.effective)
	_check(config != preset.config and config.domain_size_m == preset.config.domain_size_m
		and config.buoyancy_mps2_per_k == preset.config.buoyancy_mps2_per_k
		and config.smoke_weight_mps2 == preset.config.smoke_weight_mps2
		and config.vorticity_confinement == preset.config.vorticity_confinement
		and config.extinction_per_m == preset.config.extinction_per_m
		and config.wind_speed_mps == preset.config.wind_speed_mps,
		"smoke_boot %s: running config differs from the preset's air and look" % label)
	_check(config.grid_cell_budget == values.grid_cell_budget
		and config.pressure_iterations == values.pressure_iterations
		and config.march_step_cells == values.march_step_cells
		and config.light_downsample == values.light_downsample
		and config.light_step_cells == values.light_step_cells
		and config.maccormack == values.maccormack
		and config.sim_rate_hz == values.sim_rate_hz,
		"smoke_boot %s: running config differs from tier %d" % [label, demo.quality.effective])
	_check(demo.solver.grid_dims() == config.grid_dims() and demo.volume.is_bound(),
		"smoke_boot %s: solver grid %s, config grid %s" % [label, demo.solver.grid_dims(),
			config.grid_dims()])
	_check(demo.sun.shadow_enabled == values.scene_shadows,
		"smoke_boot %s: sun shadows differ from the tier" % label)
	var occupancy: PackedFloat32Array = demo.solver.read_field("occupancy")
	var solid := 0
	for value in occupancy:
		if value > 0.5:
			solid += 1
	_check(solid > 0, "smoke_boot %s: static props baked no solid cell" % label)
	_check(is_equal_approx(demo.smoke_menu._buoyancy.value, config.buoyancy_mps2_per_k)
		and is_equal_approx(demo.smoke_menu._extinction.value, config.extinction_per_m),
		"smoke_boot %s: menu rows differ from the running config" % label)
	print("SMOKE BOOT %s preset=%d tier=%d grid=%s solid=%d" % [label, demo.preset_idx,
		demo.quality.effective, demo.solver.grid_dims(), solid])


func _run_terrain_hydro() -> void:
	var demo = (load("res://scenes/terrain_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: boot scene did not initialize and bind its surface")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var boot_preset := clampi(int(demo.menu.stored_value("Scene", "Preset", 9)),
		0, demo.PRESETS.size() - 1)
	_check(demo.preset_idx == boot_preset and demo.solver.get_height_tex_rid().is_valid(),
		"terrain_hydro: boot preset differs from the saved scene or has no height texture")
	var boot_grid: float = demo.view.sand_mat.get_shader_parameter("grid_n")
	_check(absf(boot_grid - float(demo.solver.grid_n)) < 0.01,
		"terrain_hydro: boot material grid does not match the solver")
	var boot_snow_enabled: bool = demo._preset.snow_enabled
	_check(demo.solver.snow_enabled == boot_snow_enabled
		and demo.view.sand_mat.get_shader_parameter("snow_enabled") == boot_snow_enabled
		and demo.view.water_mat.get_shader_parameter("snow_enabled") == boot_snow_enabled,
		"terrain_hydro: boot snow state differs across preset, solver and materials")
	_terrain_hydro_check_surface(demo, "boot")
	_check(absf(demo.solver.world_size - demo._preset.world_size_m) < 1e-5
		and absf(float(demo.view.sand_mat.get_shader_parameter("world_size"))
			- demo.solver.world_size) < 1e-5
		and absf(float(demo.view.water_mat.get_shader_parameter("world_size"))
			- demo.solver.world_size) < 1e-5
		and demo.view.sand_mat.get_shader_parameter("height_tex") == demo.height_texture
		and demo.view.water_mat.get_shader_parameter("height_tex") == demo.height_texture
		and demo.view.water_mat.get_shader_parameter("velocity_tex") == demo.velocity_texture
		and demo.solver.get_velocity_tex_rid().is_valid()
		and demo.view.sand_mat.get_shader_parameter("landscape_materials")
		== demo._preset.landscape_materials,
		"terrain_hydro: boot surface/velocity binding or preset material flag is stale")
	demo.set_frozen(true)
	demo.solver.grid_n = 64
	demo.apply_preset(9)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: Mountain preset failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	demo.set_mountain_size(80.0)
	demo.set_mountain_height(14.0)
	demo.regenerate()
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: pending Mountain dimensions failed to regenerate")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(demo.solver.world_size == 80.0 and demo._preset.mountain_height_m == 14.0,
		"terrain_hydro: New terrain did not apply pending size and elevation")
	demo.set_mountain_size(64.0)
	demo.set_mountain_height(12.0)
	demo.set_mountain_density(2.4)
	demo.set_mountain_ruggedness(0.46)
	demo.set_mountain_valley_width(0.16)
	demo.set_mountain_valley_depth(0.72)
	demo.set_mountain_ridge_irregularity(0.12)
	demo.set_mountain_surface_detail(1.0)
	var alpine_seed := 8675309
	demo.generate_alpine(alpine_seed)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: default-size Alpine failed to initialize and bind")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(demo.preset_idx == 9 and demo.solver.world_size == 64.0
		and demo._preset.mountain_height_m == 12.0,
		"terrain_hydro: Mountain did not restore its 64 m by 12 m defaults")
	_check(demo.solver.rain_rate_m_s == 0.0 and demo.solver.uplift_rate_m_s == 0.0
		and demo.solver.uplift_mode == TerrainConfig.UpliftMode.NONE,
		"terrain_hydro: Mountain rain or uplift was enabled by default")
	_check(not demo.drying_enabled and demo.solver.infiltration_rate_m_s == 0.0
		and not demo.rain_enabled and demo.solver.rain_rate_m_s == 0.0
		and not demo.erosion_running and demo.solver.erosion_rate == 0.0,
		"terrain_hydro: Mountain drying, rain or erosion was enabled by default")
	_check(demo._preset.landscape_materials
		and demo.view.sand_mat.get_shader_parameter("landscape_materials")
		and demo.view.water.visible
		and demo.view.water_mat.get_shader_parameter("landscape_water")
		and not demo.view.sand_mat.get_shader_parameter("snow_enabled")
		and not demo.view.water_mat.get_shader_parameter("snow_enabled")
		and not demo.solver.snow_enabled
		and demo.solver.snowfall_rate_m_s == 0.0
		and demo.solver.freeze_rate_m_s == 0.0
		and demo.solver.melt_rate_m_s == 0.0,
		"terrain_hydro: Mountain snow material or climate source was enabled")
	var locked_tool: int = demo.tool_choice
	demo.set_snowfall(0.01)
	demo.set_freeze(0.01)
	demo.set_melt(0.01)
	_check(demo.solver.snowfall_rate_m_s == 0.0
		and demo.solver.freeze_rate_m_s == 0.0
		and demo.solver.melt_rate_m_s == 0.0,
		"terrain_hydro: public snow setters enabled snow in Mountain")
	demo.select_tool(TerrainBrush.SNOW)
	demo.select_tool(TerrainBrush.PACK)
	_check(demo.tool_choice == locked_tool,
		"terrain_hydro: disabled Mountain snow accepted Snow or Pack tool selection")
	var generated_a := await _terrain_hydro_field(demo)
	_check(_terrain_hydro_sums(generated_a).z == 0.0,
		"terrain_hydro: Mountain generation initialized snow")
	_check(not demo.summit_water and demo.solver.summit_sources.is_empty(),
		"terrain_hydro: Mountain regeneration retained summit sources")
	demo.generate_alpine(alpine_seed)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: repeated Alpine generation failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var generated_b := await _terrain_hydro_field(demo)
	_check(generated_a == generated_b,
		"terrain_hydro: public seeded Mountain generation changed for a repeated seed")
	demo.regenerate()
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: random Mountain regeneration failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var random_seed_a: int = demo._mountain_seed
	var random_a := await _terrain_hydro_field(demo)
	demo.regenerate()
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: second random Mountain regeneration failed")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var random_seed_b: int = demo._mountain_seed
	var random_b := await _terrain_hydro_field(demo)
	_check(random_seed_a != random_seed_b and random_a != random_b,
		"terrain_hydro: consecutive New terrain actions did not produce unique random terrain")
	demo.generate_alpine(alpine_seed)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: fixed-seed Mountain restore failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	demo.set_drying(false)
	demo.set_erosion_running(false)
	demo.set_rain_enabled(false)
	demo.set_rain(0.006)
	demo.set_erosion(0.8)
	_check(demo.solver.rain_rate_m_s == 0.0 and demo.solver.erosion_rate == 0.0
		and absf(demo.mountain_rain_rate_m_s - 0.006) < 1e-7
		and absf(demo.mountain_erosion_rate - 0.8) < 1e-7,
		"terrain_hydro: changing disabled Rain/Erosion controls changed live rates")
	demo.set_rain_enabled(true)
	_check(absf(demo.solver.rain_rate_m_s - 0.006) < 1e-7
		and demo.solver.erosion_rate == 0.0,
		"terrain_hydro: Rain toggle did not activate rain independently")
	demo.set_erosion_running(true)
	_check(absf(demo.solver.rain_rate_m_s - 0.006) < 1e-7
		and absf(demo.solver.erosion_rate - 0.8) < 1e-7,
		"terrain_hydro: Erosion toggle changed Rain or failed to restore erosion strength")
	demo.set_erosion(1.2)
	demo.set_rain(0.004)
	_check(absf(demo.solver.rain_rate_m_s - 0.004) < 1e-7
		and absf(demo.solver.erosion_rate - 1.2) < 1e-7,
		"terrain_hydro: Rain/Erosion controls did not update their independent live rates")
	demo.set_erosion_running(false)
	_check(demo.solver.rain_rate_m_s == 0.004 and demo.solver.erosion_rate == 0.0,
		"terrain_hydro: disabling Erosion also changed Rain")
	demo.set_rain_enabled(false)
	_check(demo.solver.rain_rate_m_s == 0.0 and demo.solver.erosion_rate == 0.0,
		"terrain_hydro: disabling Rain changed Erosion")
	var fixed_dt := 1.0 / 60.0
	var fixed_steps := 600
	demo.solver.flow_rate = 0.0
	demo.solver.snow_flow_rate = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.infiltration_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.stochasticity = 0.0
	demo.solver.snowfall_rate_m_s = 0.01
	demo.solver.freeze_rate_m_s = 0.01
	demo.solver.melt_rate_m_s = 0.01
	demo.set_rain(0.0025)
	demo.set_erosion(1.2)
	demo.set_erosion_running(false)
	demo.set_rain_enabled(true)
	var rain_start := await _terrain_hydro_field(demo)
	var rain_start_sums := _terrain_hydro_sums(rain_start)
	await _terrain_hydro_steps(demo, fixed_steps, fixed_dt)
	var rain_only := await _terrain_hydro_field(demo)
	var rain_only_sums := _terrain_hydro_sums(rain_only)
	var rain_flux := await _terrain_hydro_flux_stats(demo)
	var expected_rain: float = demo.mountain_rain_rate_m_s * fixed_dt \
		* float(fixed_steps * 64 * 64)
	var rain_gain := rain_only_sums.y - rain_start_sums.y
	_check(absf(rain_gain - expected_rain) < 1e-3 * maxf(expected_rain, 1.0),
		"terrain_hydro: Rain-only water budget differs (%.6f vs %.6f)"
			% [rain_gain, expected_rain])
	_check(absf((rain_only_sums.x + rain_only_sums.w)
		- (rain_start_sums.x + rain_start_sums.w)) < 1e-4
		* maxf(rain_start_sums.x + rain_start_sums.w, 1.0),
		"terrain_hydro: Rain-only run changed total R+A")
	var unchanged_solids := true
	for i in rain_only.size() / 4:
		if rain_only[i * 4] != rain_start[i * 4] or rain_only[i * 4 + 3] != rain_start[i * 4 + 3]:
			unchanged_solids = false
			break
	_check(unchanged_solids, "terrain_hydro: disabled Erosion altered the bed or sediment")
	_check(rain_flux.x > 1e-6 and rain_flux.y > 1e-5,
		"terrain_hydro: Rain-only run did not produce hydraulic flux and water redistribution")
	_check(_terrain_hydro_channel_spread(rain_only, 1) > 1e-5,
		"terrain_hydro: Rain-only water remained a uniform source layer")
	_check(rain_only_sums.z == 0.0,
		"terrain_hydro: disabled Mountain snow source changed the snow channel")
	var before_erosion := await _terrain_hydro_field(demo)
	var before_erosion_flux := await _terrain_hydro_flux_stats(demo)
	demo.set_erosion_running(true)
	var immediate_erosion := await _terrain_hydro_field(demo)
	var immediate_erosion_flux := await _terrain_hydro_flux_stats(demo)
	_check(demo.rain_enabled and demo.solver.rain_rate_m_s == 0.0025
		and demo.erosion_running and demo.solver.erosion_rate == 1.2
		and before_erosion == immediate_erosion and before_erosion_flux == immediate_erosion_flux,
		"terrain_hydro: enabling Erosion changed Rain or the current water/flux fields")
	var water_start_sums := _terrain_hydro_sums(immediate_erosion)
	await _terrain_hydro_steps(demo, fixed_steps, fixed_dt)
	var watered := await _terrain_hydro_field(demo)
	var watered_sums := _terrain_hydro_sums(watered)
	var finite := true
	for value in watered:
		if is_nan(value) or is_inf(value) or value < -1e-6:
			finite = false
			break
	var water_gain := watered_sums.y - water_start_sums.y
	var solid_before := water_start_sums.x + water_start_sums.w
	var solid_after := watered_sums.x + watered_sums.w
	_check(absf(water_gain - expected_rain) < 1e-3 * maxf(expected_rain, 1.0),
		"terrain_hydro: Rain budget changed when Erosion enabled (%.6f vs %.6f)"
			% [water_gain, expected_rain])
	_check(absf(solid_after - solid_before) < 1e-4 * maxf(solid_before, 1.0),
		"terrain_hydro: rain-driven R+A mass drifted (%.6f -> %.6f)"
			% [solid_before, solid_after])
	_check(watered_sums.x < rain_only_sums.x - 1e-5
		and watered_sums.w > rain_only_sums.w + 1e-6,
		"terrain_hydro: enabling Erosion did not transfer Alpine sand into sediment")
	_check(watered_sums.z == 0.0,
		"terrain_hydro: rain or climate created Mountain snow")
	_check(finite, "terrain_hydro: rain-driven erosion produced invalid or negative channels")
	print("TERRAIN HYDRO seed=%d size=%.1f height=%.1f steps=%d rain_gain=%.6f expected=%.6f sand_loss=%.6f sediment_gain=%.6f"
		% [alpine_seed, demo.solver.world_size, demo._preset.mountain_height_m, fixed_steps,
			water_gain, expected_rain, rain_only_sums.x - watered_sums.x,
			watered_sums.w - rain_only_sums.w])
	demo.set_erosion_running(false)
	_check(demo.rain_enabled and demo.solver.rain_rate_m_s == 0.0025
		and demo.solver.erosion_rate == 0.0,
		"terrain_hydro: disabling Erosion also disabled Rain")
	var after_disable := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	await _terrain_hydro_steps(demo, 10, fixed_dt)
	var after_disable_steps := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	var short_rain_expected := 0.0025 * fixed_dt * 10.0 * 64.0 * 64.0
	_check(absf((after_disable_steps.y - after_disable.y) - short_rain_expected) < 1e-4,
		"terrain_hydro: Rain stopped when Erosion was disabled")
	demo.set_rain_enabled(false)
	_check(not demo.erosion_running and demo.solver.erosion_rate == 0.0
		and demo.solver.rain_rate_m_s == 0.0,
		"terrain_hydro: disabling Rain changed Erosion state")
	var after_rain_off := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	await _terrain_hydro_steps(demo, 10, fixed_dt)
	var after_rain_off_steps := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	_check(absf(after_rain_off_steps.y - after_rain_off.y) < 1e-4,
		"terrain_hydro: disabled Rain toggle continued adding water")
	demo.apply_preset(1)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: legacy scene failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(demo.preset_idx == 1 and demo.solver.world_size == 4.0,
		"terrain_hydro: switching back to a legacy preset did not restore its 4 m domain")
	_terrain_hydro_check_surface(demo, "legacy preset")
	demo.regenerate()
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: legacy Reset failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(demo.preset_idx == 1 and demo.solver.world_size == 4.0,
		"terrain_hydro: legacy Reset did not retain the selected legacy scene")
	_terrain_hydro_check_surface(demo, "legacy Reset")
	demo.apply_preset(7)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: Thaw preset failed to initialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var thaw_start := await _terrain_hydro_field(demo)
	var thaw_start_sums := _terrain_hydro_sums(thaw_start)
	_check(demo.solver.snow_enabled and absf(demo.solver.melt_rate_m_s - 0.06) < 1e-6
		and demo.solver.snowfall_rate_m_s == 0.0 and demo.solver.freeze_rate_m_s == 0.0
		and thaw_start_sums.z > 0.0 and demo.view.water.visible,
		"terrain_hydro: Thaw did not restore snow, melt, or legacy water-surface state")
	_terrain_hydro_check_surface(demo, "Thaw")
	demo.solver.rain_rate_m_s = 0.0
	demo.solver.erosion_rate = 0.0
	demo.solver.flow_rate = 0.0
	demo.solver.water_flow_rate = 0.0
	demo.solver.snow_flow_rate = 0.0
	demo.solver.evap_rate_m_s = 0.0
	demo.solver.infiltration_rate_m_s = 0.0
	demo.solver.uplift_rate_m_s = 0.0
	demo.solver.uplift_mode = TerrainConfig.UpliftMode.NONE
	demo.solver.snowfall_rate_m_s = 0.0
	demo.solver.freeze_rate_m_s = 0.0
	demo.solver.melt_rate_m_s = 0.06
	demo.solver.stochasticity = 0.0
	var thaw_before := await _terrain_hydro_field(demo)
	var thaw_before_sums := _terrain_hydro_sums(thaw_before)
	await _terrain_hydro_steps(demo, 180, 1.0 / 60.0)
	var thaw_after := await _terrain_hydro_field(demo)
	var thaw_after_sums := _terrain_hydro_sums(thaw_after)
	var expected_melt := 0.06 * 3.0 * float(demo.solver.grid_n * demo.solver.grid_n)
	var thaw_water_gain := thaw_after_sums.y - thaw_before_sums.y
	var snow_loss := thaw_before_sums.z - thaw_after_sums.z
	var thaw_finite := true
	for value in thaw_after:
		if is_nan(value) or is_inf(value) or value < -1e-6:
			thaw_finite = false
			break
	_check(absf(thaw_water_gain - expected_melt) < expected_melt * 1e-3
		and absf(snow_loss - expected_melt) < expected_melt * 1e-3
		and absf((thaw_after_sums.y + thaw_after_sums.z)
			- (thaw_before_sums.y + thaw_before_sums.z)) < expected_melt * 1e-4,
		"terrain_hydro: Thaw melt did not conserve its expected G+B budget")
	_check(thaw_finite, "terrain_hydro: Thaw produced invalid or negative channels")
	demo.apply_preset(7)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: normal Thaw preset failed to reinitialize")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(absf(demo.solver.melt_rate_m_s - 0.06) < 1e-6
		and absf(demo.solver.evap_rate_m_s - 0.005) < 1e-6
		and demo.solver.water_flow_rate > 0.0
		and demo.view.water.visible
		and demo.view.water_mat.shader.resource_path.ends_with("terrain_water.gdshader")
		and demo.view.water_mat.get_shader_parameter("height_tex") == demo.height_texture
		and demo.view.water_mat.get_shader_parameter("velocity_tex") == demo.velocity_texture
		and demo.solver.get_velocity_tex_rid().is_valid(),
		"terrain_hydro: Thaw physical water surface lost its live field/velocity or default flow")
	await _terrain_hydro_steps(demo, 900, 1.0 / 60.0)
	var thaw_water := await _terrain_hydro_field(demo)
	var thaw_water_sums := _terrain_hydro_sums(thaw_water)
	var wet_level := _terrain_hydro_wet_level_spread(thaw_water, demo.solver.grid_n, 0.005)
	print("TERRAIN HYDRO thaw water_mean=%.6f snow_mean=%.6f wet_cells=%.0f level_spread=%.6f"
		% [thaw_water_sums.y / float(demo.solver.grid_n * demo.solver.grid_n),
			thaw_water_sums.z / float(demo.solver.grid_n * demo.solver.grid_n), wet_level.x, wet_level.y])
	_check(thaw_water_sums.y > float(demo.solver.grid_n * demo.solver.grid_n) * 0.01
		and thaw_water_sums.z < float(demo.solver.grid_n * demo.solver.grid_n) * 0.001
		and wet_level.x > float(demo.solver.grid_n * demo.solver.grid_n) * 0.5
		and wet_level.y < 0.01,
		"terrain_hydro: normal Thaw did not produce a broad, mostly level physical water surface")
	demo.apply_preset(4)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: River & delta preset failed after Thaw")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_terrain_hydro_check_surface(demo, "River & delta")
	var river_start := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	_check(river_start.y == 0.0 and demo.auto_water and demo._preset.waters_by_itself(),
		"terrain_hydro: River & delta did not start dry with its automatic water source")
	demo.set_capture_fixed_delta(1.0 / 60.0)
	demo.set_frozen(false)
	for i in 900:
		await process_frame
	demo.set_frozen(true)
	demo.set_capture_fixed_delta(-1.0)
	var river_field := await _terrain_hydro_field(demo)
	var river_sums := _terrain_hydro_sums(river_field)
	var river_count: int = demo.solver.grid_n * demo.solver.grid_n
	var river_peak := 0.0
	var river_downhill := 0.0
	var river_dry := 0
	for i in river_count:
		var water: float = river_field[i * 4 + 1]
		river_peak = maxf(river_peak, water)
		river_downhill += water * ((float(i % demo.solver.grid_n) + 0.5)
			* demo.solver.cell_size() - demo.solver.world_size * 0.5)
		if water < 0.001:
			river_dry += 1
	var river_mean := river_sums.y / float(river_count)
	river_downhill /= maxf(river_sums.y, 1e-6)
	print("TERRAIN HYDRO river water_mean=%.6f water_peak=%.6f downhill=%.6f dry_fraction=%.6f"
		% [river_mean, river_peak, river_downhill, float(river_dry) / float(river_count)])
	_check(river_mean > 0.001 and river_mean < 0.03 and river_peak < 0.25
		and river_downhill > 0.1 and river_dry > river_count / 2,
		"terrain_hydro: normal River & delta flooded the bed or failed to carry water downhill")

	demo.apply_preset(6)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: Avalanche preset failed after River & delta")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	var avalanche_sums := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	_check(demo.solver.snow_enabled and absf(demo.solver.snowfall_rate_m_s - 0.001) < 1e-6
		and demo.solver.melt_rate_m_s == 0.0 and avalanche_sums.z > 0.0,
		"terrain_hydro: Avalanche failed to restore its snowfall and melt settings")
	_terrain_hydro_check_surface(demo, "Avalanche")
	demo.apply_preset(8)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: Squall preset failed after Avalanche")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	await _terrain_hydro_steps(demo, 1, 1.0 / 60.0)
	var squall_sums := _terrain_hydro_sums(await _terrain_hydro_field(demo))
	_check(demo.solver.snow_enabled
		and absf(demo.solver.snowfall_rate_m_s - 0.004) < 1e-6
		and absf(demo.solver.freeze_rate_m_s - 0.0025) < 1e-6
		and demo.solver.melt_rate_m_s == 0.0 and squall_sums.z > 0.0,
		"terrain_hydro: Squall failed to restore its snow and climate settings")
	_terrain_hydro_check_surface(demo, "Squall")
	demo.set_mountain_size(64.0)
	demo.set_mountain_height(12.0)
	demo.set_mountain_density(2.4)
	demo.set_mountain_ruggedness(0.46)
	demo.set_mountain_valley_width(0.16)
	demo.set_mountain_valley_depth(0.72)
	demo.set_mountain_ridge_irregularity(0.12)
	demo.set_mountain_surface_detail(1.0)
	demo.generate_alpine(alpine_seed)
	if not await _terrain_hydro_ready(demo):
		_check(false, "terrain_hydro: restoring Mountain defaults failed")
		demo.queue_free()
		await process_frame
		_finish("terrain_hydro")
		return
	_check(demo.solver.world_size == 64.0 and demo._preset.mountain_height_m == 12.0,
		"terrain_hydro: returning to Mountain did not restore 64 m by 12 m")
	_terrain_hydro_check_surface(demo, "restored Mountain")
	demo.queue_free()
	await process_frame
	_finish("terrain_hydro")


func _terrain_hydro_ready(demo: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and (not demo.solver.initialized or not demo.texture_bound):
		await process_frame
	return demo.solver.initialized and demo.texture_bound


func _terrain_hydro_check_surface(demo: Node, context: String) -> void:
	var landscape: bool = demo._preset.landscape_materials
	_check(demo.view.water.visible
		and demo.view.sand_mat.get_shader_parameter("landscape_materials") == landscape
		and demo.view.water_mat.get_shader_parameter("landscape_water") == landscape
		and demo.view.terrain.material_override == demo.view.sand_mat
		and demo.view.water.material_override == demo.view.water_mat,
		"terrain_hydro: %s water surface/material state differs from its preset" % context)


func _terrain_hydro_wet_level_spread(field: PackedFloat32Array, n: int, min_depth: float) -> Vector2:
	var low := INF
	var high := -INF
	var wet_count := 0.0
	for i in n * n:
		var offset := i * 4
		if field[offset + 1] <= min_depth:
			continue
		var head := field[offset] + field[offset + 1] + field[offset + 2]
		low = minf(low, head)
		high = maxf(high, head)
		wet_count += 1.0
	return Vector2(wet_count, high - low)


func _terrain_hydro_steps(demo: Node, count: int, dt: float) -> void:
	for i in count:
		RenderingServer.call_on_render_thread(demo.solver.step_render.bind(dt))
		await process_frame


func _terrain_hydro_field(demo: Node) -> PackedFloat32Array:
	var data: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_height_tex_rid(), 0)
	_check(not data.is_empty(), "terrain_hydro: height readback timed out")
	return data.to_float32_array()


func _terrain_hydro_flux_stats(demo: Node) -> Vector2:
	var data: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_flux_tex_rid(), 0)
	_check(not data.is_empty(), "terrain_hydro: flux readback timed out")
	var flux := data.to_float32_array()
	var total := 0.0
	var peak := 0.0
	for i in flux.size():
		var value := absf(flux[i])
		total += value
		peak = maxf(peak, value)
	return Vector2(total, peak)


func _terrain_hydro_channel_spread(field: PackedFloat32Array, channel: int) -> float:
	var low := INF
	var high := -INF
	for i in field.size() / 4:
		var value: float = field[i * 4 + channel]
		low = minf(low, value)
		high = maxf(high, value)
	return high - low


func _terrain_hydro_sums(field: PackedFloat32Array) -> Vector4:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var a := 0.0
	for i in field.size() / 4:
		r += field[i * 4]
		g += field[i * 4 + 1]
		b += field[i * 4 + 2]
		a += field[i * 4 + 3]
	return Vector4(r, g, b, a)


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


func _run_ocean_parameters() -> void:
	await _boot_frames(2)
	await OceanParameterProbe.new().run(self, _check, "parameters")
	_finish("ocean_parameters_gpu")


func _run_ocean_swell() -> void:
	await _boot_frames(2)
	await OceanParameterProbe.new().run(self, _check, "swell")
	_finish("ocean_swell")


func _run_ocean_extremes() -> void:
	await _boot_frames(2)
	await OceanParameterProbe.run(self, _check, "extremes")
	_finish("ocean_extremes")


func _run_ocean_contracts() -> void:
	var empty: Array[float] = []
	var values: Array[float] = [4.0, 1.0, 3.0, 2.0]
	_check(OceanProfiling._median(empty, 7.0) == 7.0
		and OceanProfiling._percentile(empty, 0.95, 7.0) == 7.0
		and OceanProfiling._median(values, 0.0) == 2.5
		and OceanProfiling._percentile(values, 0.95, 0.0) == 4.0
		and values == [4.0, 1.0, 3.0, 2.0], "ocean_contracts: statistics changed")
	var cancelled := TextureReadback.Request.new()
	cancelled.cancel()
	cancelled.complete(PackedByteArray([1]))
	_check(cancelled.cancelled() and not cancelled.pending() and cancelled.data().is_empty(),
		"ocean_contracts: cancelled readback accepted a late callback")
	var expired := TextureReadback.Request.new()
	expired.timeout()
	expired.complete(PackedByteArray([1]))
	_check(expired.timed_out() and expired.data().is_empty(),
		"ocean_contracts: timed out readback accepted a late callback")
	await _boot_frames(2)
	for name in ["calm", "breeze", "swell", "storm"]:
		var path := "res://resources/ocean/presets/%s.tres" % name
		var text := FileAccess.get_file_as_string(path)
		var properties := text.substr(text.find("[resource]") + 10).strip_edges()
		_check(properties.begins_with("script ="),
			"ocean_contracts: %s attaches its script after exported values" % name)
		var preset: OceanPreset = load(path)
		_check(preset.validate().is_empty(), "ocean_contracts: invalid preset %s" % name)
	var fields: Array[PackedFloat32Array] = []
	var displacement: Array[PackedFloat32Array] = []
	for layer in 3:
		var zero := PackedFloat32Array()
		zero.resize(16)
		fields.append(zero.duplicate())
		displacement.append(zero.duplicate())
	var capture := preload("res://scripts/ocean/ocean_capture_metrics.gd")
	for strain in [Vector3(-0.4, 0.5, 0.0), Vector3(-0.5, 0.1, 0.0)]:
		for index in range(0, 16, 4):
			fields[0][index] = strain.x
			fields[0][index + 1] = strain.y
		var measured: Dictionary = capture.measure(displacement, fields, 2,
			PackedFloat32Array([100.0, 20.0, 5.0]), 0.8)
		var expected := 0.0 if strain.x > -0.5 else 0.25
		_check(absf(measured.source_mean - expected) < 0.000001,
			"ocean_contracts: capture source differs from the foam determinant")
		print("OCEAN CONTRACTS source=%.6f expected=%.6f" % [measured.source_mean, expected])
	if RenderingServer.get_rendering_device() == null:
		var demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
		root.add_child(demo)
		await _boot_frames(2)
		demo.queue_free()
		await _boot_frames(2)
		_check(not is_instance_valid(demo), "ocean_contracts: unsupported scene did not exit")
	else:
		var result := {"clean": false}
		RenderingServer.call_on_render_thread(func():
			var solver := OceanSolver.new()
			solver._rd = RenderingServer.get_rendering_device()
			var valid := "#version 450\nlayout(local_size_x=1) in;\nvoid main() {}\n"
			var compiled := solver._compile_stage_render("contract_valid", valid)
			solver._buffers["contract_buffer"] = solver._rd.storage_buffer_create(16)
			print("OCEAN CONTRACTS expected_shader_failure")
			var rejected := not solver._compile_stage_render("contract_invalid", "#version 450\n#error Expected failure\n")
			result.clean = compiled and rejected and not solver.initialized \
				and solver._shaders.is_empty() and solver._pipelines.is_empty() \
				and solver._buffers.is_empty()
			solver.free_render()
		)
		await RenderingServer.frame_post_draw
		_check(result.clean, "ocean_contracts: failed compilation leaked GPU resources")
		print("OCEAN CONTRACTS failed_compile_clean=%s" % result.clean)
	_finish("ocean_contracts")


func _record_ocean_metadata(demo: Node, result: Dictionary) -> void:
	result.value = await demo.capture_metadata_async("probe")
	result.done = true


func _record_ocean_rings(demo: Node, result: Dictionary) -> void:
	result.value = await demo.capture_foam_rings()
	result.done = true


func _wait_ocean_capture_ready(demo: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	return demo.capture_ready()


func _run_ocean_capture() -> void:
	await _boot_frames(2)
	var manager: Node = root.get_node("/root/GameManager")
	var saved_tier: int = manager.get_setting("ocean_quality_profile", OceanQualityProfile.Tier.HIGH)
	manager.settings["ocean_quality_profile"] = OceanQualityProfile.Tier.HIGH \
		if _extra.has("high=1") else OceanQualityProfile.Tier.LOW
	var demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	manager.settings["ocean_quality_profile"] = saved_tier
	if not await _wait_ocean_capture_ready(demo):
		_check(false, "ocean_capture: boot did not initialize")
		demo.queue_free()
		_finish("ocean_capture")
		return
	demo.set_capture_fixed_delta(1.0 / 60.0)
	if _extra.has("expected_failure=1"):
		demo.set_frozen(true)
		demo.set_capture_profiling(true)
		demo.set_capture_debug(2)
		var original: Environment = demo.world_env.environment
		var failure := {"done": false, "value": ""}
		_record_ocean_metadata(demo, failure)
		await RenderingServer.frame_post_draw
		var pending: TextureReadback.Request = demo._capture._pending_request
		_check(pending != null and demo._capture._profile_suspended,
			"ocean_capture: timeout injection did not reach GPU readback")
		print("OCEAN CAPTURE expected_readback_timeout")
		pending.timeout()
		var restored: bool = failure.done and demo.world_env.environment == original \
			and not demo._capture.measurement_active and demo.solver.profiling \
			and demo._profiling.capture_enabled and demo._viewport.measure_render_time() \
			and int(demo.surface_mat.get_shader_parameter("debug_view")) == 2
		_check(restored, "ocean_capture: timeout did not restore runtime state")
		print("OCEAN CAPTURE failure_restored=%s" % restored)
		demo.queue_free()
		manager.set_setting("ocean_quality_profile", saved_tier)
		return
	demo.set_frozen(false)
	await RenderingServer.frame_post_draw
	var time_before: float = demo._sim_time
	var frame_before: int = demo.solver._frame
	await demo.warmup_foam(0.2)
	_check(absf(demo._sim_time - time_before - 0.2) < 0.000001
		and demo.solver._frame - frame_before == 12 and not demo._warmup_active,
		"ocean_capture: warmup also dispatched or advanced the normal clock")
	demo.profiler.set_enabled(true)
	demo.set_capture_profiling(true)
	demo.profiler.set_enabled(false)
	_check(demo.solver.profiling and demo._viewport.measure_render_time(),
		"ocean_capture: closing overlay disabled capture profiling")
	await _boot_frames(260)
	var stats: Dictionary = demo._profiling.statistics()
	_check(stats.profile_samples == 240 and stats.frame_ms > 0.0
		and stats.frame_p95_ms >= stats.frame_ms,
		"ocean_capture: sample limit or frame percentiles changed")
	demo.set_frozen(true)
	await _boot_frames(2)
	demo.set_capture_profiling(true)
	demo._profiling.collect_sample()
	var sample_count: int = demo._profiling.statistics().profile_samples
	demo._profiling.collect_sample()
	_check(sample_count == 1 and demo._profiling.statistics().profile_samples == sample_count,
		"ocean_capture: repeated GPU frame was collected twice")
	demo.profiler.set_enabled(true)
	demo.set_capture_profiling(false)
	_check(demo.solver.profiling and demo._viewport.measure_render_time(),
		"ocean_capture: capture disabled active overlay profiling")
	demo.profiler.set_enabled(false)
	_check(not demo.solver.profiling and not demo._viewport.measure_render_time(),
		"ocean_capture: profiling remained active without a user")
	demo.set_capture_profiling(true)
	demo.set_capture_debug(2)
	var environment: Environment = demo.world_env.environment
	var tint_visible: bool = demo.underwater_tint.visible
	var metadata: String = await demo.capture_metadata_async("probe")
	_check(metadata.begins_with("CAPTURE META ") and metadata.contains("measure_version=6")
		and demo.world_env.environment == environment
		and demo.underwater_tint.visible == tint_visible
		and int(demo.surface_mat.get_shader_parameter("debug_view")) == 2
		and not demo._capture.measurement_active and demo.solver.profiling
		and demo._profiling.capture_enabled and demo._viewport.measure_render_time(),
		"ocean_capture: metadata did not restore render or profiling state")
	print("OCEAN CAPTURE samples=240 deduplicated=true restored=true warmup_steps=12")
	var transition := {"done": false, "value": []}
	_record_ocean_rings(demo, transition)
	demo._camera_water = Vector4(10000.0, 0.0, 0.0, 1.0)
	demo._camera_water_valid = true
	demo._update_underwater(demo.main_camera.global_position)
	_check(not demo.underwater_tint.visible, "ocean_capture: measurement showed underwater tint")
	demo._capture.invalidate()
	_check(transition.done and demo.underwater_tint.visible
		and is_equal_approx(environment.fog_density, 0.03),
		"ocean_capture: restoration lost the current underwater state")
	demo._camera_water_valid = false
	demo._update_underwater(demo.main_camera.global_position)
	var replacement := {"done": false, "value": []}
	_record_ocean_rings(demo, replacement)
	var new_environment: Environment = environment.duplicate()
	var new_material: ShaderMaterial = demo.surface_mat.duplicate()
	new_material.set_shader_parameter("debug_view", 3)
	demo.world_env.environment = new_environment
	demo.ocean_mesh.material_override = new_material
	demo._capture.invalidate()
	_check(replacement.done and demo.world_env.environment == new_environment
		and demo.ocean_mesh.material_override == new_material
		and int(new_material.get_shader_parameter("debug_view")) == 3,
		"ocean_capture: restoration overwrote replacement objects")
	demo.world_env.environment = environment
	demo.ocean_mesh.material_override = demo.surface_mat
	demo.set_capture_debug(2)
	var rings_result := {"done": false, "value": []}
	_record_ocean_rings(demo, rings_result)
	_check(demo._capture.measurement_active, "ocean_capture: ring measurement did not start")
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	_check(rings_result.done and rings_result.value.is_empty()
		and demo.world_env.environment == environment
		and not demo._capture.measurement_active
		and int(demo.surface_mat.get_shader_parameter("debug_view")) == 2,
		"ocean_capture: rebuild did not cancel and restore the ring measurement")
	_check(await _wait_ocean_capture_ready(demo), "ocean_capture: rebuild did not initialize")
	var read_result := {"done": false, "value": ""}
	_record_ocean_metadata(demo, read_result)
	await RenderingServer.frame_post_draw
	_check(not read_result.done and demo._capture._profile_suspended,
		"ocean_capture: metadata was not awaiting GPU readback")
	demo.set_quality_profile(OceanQualityProfile.Tier.LOW)
	_check(read_result.done and String(read_result.value).begins_with("CAPTURE FAIL")
		and demo.solver.profiling and demo._profiling.capture_enabled,
		"ocean_capture: rebuild did not settle the pending readback")
	_check(await _wait_ocean_capture_ready(demo), "ocean_capture: second rebuild did not initialize")
	var exit_result := {"done": false, "value": ""}
	_record_ocean_metadata(demo, exit_result)
	await RenderingServer.frame_post_draw
	var retired_capture: OceanCapture = demo._capture
	demo.queue_free()
	await _boot_frames(2)
	_check(not is_instance_valid(demo) and exit_result.done
		and String(exit_result.value).begins_with("CAPTURE FAIL")
		and not retired_capture.measurement_active
		and retired_capture._pending_request == null
		and not retired_capture._metadata_provider.is_valid()
		and ViewportGuard.measured_viewports == 0,
		"ocean_capture: exit left a coroutine, callback or measured viewport behind")
	manager.settings["ocean_quality_profile"] = OceanQualityProfile.Tier.LOW
	var next_demo: Node = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(next_demo)
	manager.settings["ocean_quality_profile"] = saved_tier
	_check(await _wait_ocean_capture_ready(next_demo), "ocean_capture: reentry did not initialize")
	if next_demo.capture_ready():
		next_demo.set_frozen(true)
		var reentry: String = await next_demo.capture_metadata_async("reentry")
		_check(reentry.begins_with("CAPTURE META ") and not next_demo.solver.profiling,
			"ocean_capture: reentry inherited profiling or capture state")
	next_demo.queue_free()
	await _boot_frames(2)
	manager.set_setting("ocean_quality_profile", saved_tier)
	print("OCEAN CAPTURE rebuild_cancelled=true exit_cancelled=true reentry=true")
	_finish("ocean_capture")


func _run_river_swe() -> void:
	await _boot_frames(2)
	var manager := root.get_node("GameManager")
	var saved_tier: int = manager.get_setting("river_quality_profile")
	manager.set_setting("river_quality_profile", 1)
	var demo: Node = load("res://scenes/river_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(demo.capture_ready() and demo.river.swe.initialized,
		"river_swe: normal player boot must initialize the full river simulation")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("river_swe")
		return
	var flood_pixel := Vector2i((Vector2(8.431, 0.0) / demo.river.field.domain_m + Vector2.ONE * 0.5)
		* Vector2(demo.river.field.solver_terrain_image.get_size()))
	_check(demo.river.field.solver_terrain_image.get_pixelv(flood_pixel).a < -0.1,
		"river_swe: generated source must retain current on banks that are dry at level zero")
	demo.set_quality_profile(2)
	demo.apply_preset(2)
	demo.set_capture_fixed_delta(1.0 / 60.0)
	await _boot_frames(900)
	demo.set_frozen(true)
	await _boot_frames(3)
	var snapshot: Dictionary = demo.river.swe.solver.snapshot()
	var grid: Vector2i = demo.river.swe.solver.grid
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(snapshot.surface, 0, grid.x * grid.y * 16)
	var terrain_bytes: PackedByteArray = await TextureReadback.new().read_layer(snapshot.terrain, 0, bytes.size())
	var values := bytes.to_float32_array()
	var terrain := terrain_bytes.to_float32_array()
	var max_depth := 0.0
	var max_speed := 0.0
	var max_change := 0.0
	var mean_change := 0.0
	var downstream := 0.0
	var wet_count := 0
	var finite := true
	for value in values:
		finite = finite and is_finite(value)
	for cell in values.size() / 4:
		var i := cell * 4
		max_depth = maxf(max_depth, values[i + 3])
		if values[i + 3] > 0.03:
			max_speed = maxf(max_speed, Vector2(values[i], values[i + 1]).length())
			var change: float = values[i + 2] - terrain[i + 1] - demo.config.water_level_m
			max_change = maxf(max_change, absf(change))
			mean_change += change
			downstream += values[i + 1]
			wet_count += 1
	mean_change /= maxf(wet_count, 1.0)
	_check(finite and max_depth > 0.1 and max_depth < 4.0 and max_speed < 15.0,
		"river_swe: depth and momentum must remain finite and bounded")
	_check(downstream < 0.0 and max_change > 0.02 and absf(mean_change) < 0.15,
		"river_swe: obstacle response must keep the authored mean water level")
	await _boot_frames(12)
	var frozen_bytes: PackedByteArray = await TextureReadback.new().read_layer(snapshot.surface, 0, bytes.size())
	_check(bytes == frozen_bytes and is_zero_approx(demo.river.swe._spray.speed_scale),
		"river_swe: pause must freeze solver and droplets")
	var old_region: Rect2 = demo.river.swe.region_m
	var old_mesh: Mesh = demo.river._surface.mesh
	var old_foam: PackedByteArray = await TextureReadback.new().read_layer(snapshot.foam, 0, bytes.size())
	_check(old_region == Rect2(-demo.river.field.domain_m * 0.5, demo.river.field.domain_m),
		"river_swe: the persistent solver must cover the full field")
	demo.move_capture_camera(Vector3(4.0, 0.0, 0.0))
	demo.orbit._update_transform()
	await _boot_frames(4)
	for distance: float in [8.0, 24.0, 24.5, 56.0, 60.0, 65.0, 12.0]:
		demo.orbit.distance = distance
		demo.orbit._update_transform()
		await _boot_frames(3)
		_check(demo.river.swe.active and demo.river.swe.region_m == old_region
			and demo.river.swe.solver.grid == grid and demo.river._surface.mesh == old_mesh,
			"river_swe: zoom and pan must preserve the solver domain, resolution and water geometry")
	for pitch: float in [-80.0, -20.0, 5.0]:
		demo.orbit.pitch = pitch
		demo.orbit._update_transform()
		await _boot_frames(3)
	demo.set_capture_view("default")
	await _boot_frames(3)
	var returned: PackedByteArray = await TextureReadback.new().read_layer(snapshot.surface, 0, bytes.size())
	var returned_foam: PackedByteArray = await TextureReadback.new().read_layer(snapshot.foam, 0, bytes.size())
	_check(returned == bytes and returned_foam == old_foam,
		"river_swe: a paused camera round trip must leave the entire water surface and foam byte-identical")
	demo.set_quality_profile(0)
	await _boot_frames(3)
	var low_surface: PackedByteArray = await TextureReadback.new().read_layer(snapshot.surface, 0, bytes.size())
	_check(low_surface == bytes and demo.river.swe.active and demo.river.swe.solver.grid == grid,
		"river_swe: render quality must not reset, resize or replace the physics with an impostor")
	demo.orbit.distance = 65.0
	demo.orbit._update_transform()
	var idle_time: float = demo.river.swe.solver.snapshot().time_s
	demo.set_frozen(false)
	await _boot_frames(12)
	_check(float(demo.river.swe.solver.snapshot().time_s) > idle_time + 0.1,
		"river_swe: the full river must keep evolving when the camera is distant in Low quality")
	demo.set_capture_view("default")
	demo.set_quality_profile(1)
	demo.apply_preset(1)
	demo.set_capture_fixed_delta(-1.0)
	await _boot_frames(4)
	demo._menu_builder.crate_action.pressed.emit()
	_check(demo.interactions.crates.size() == 1 and demo.interactions.crates[0].linear_velocity.length() > 5.0,
		"river_swe: native action must throw a physical crate from the player camera")
	var crate: RigidBody3D = demo.interactions.crates[0]
	await physics_frame
	var point := Vector2(RiverLandscape.center_x(0.0) - 2.0, 0.0)
	crate.global_position = Vector3(point.x, RiverLandscape.water_height(point, 0.06) + 0.15, point.y)
	crate.linear_velocity = Vector3.ZERO
	crate.angular_velocity = Vector3.ZERO
	var start_position := crate.global_position
	deadline = Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		await physics_frame
	var drift := crate.global_position - start_position
	print("RIVER SWE crate_position=%s velocity=%s samples=%s support=%s frozen=%s mass=%.2f" % [crate.global_position, crate.linear_velocity, crate._samples, crate.last_support_force_n, crate.freeze, crate.mass])
	_check(drift.z < -0.8 and absf(crate.global_position.y - RiverLandscape.water_height(Vector2(crate.global_position.x, crate.global_position.z), 0.06)) < 0.7,
		"river_swe: asynchronous GPU queries must float crates and transport them downstream")
	demo.set_frozen(true)
	await physics_frame
	await physics_frame
	var paused_position := crate.global_position
	for frame in 20:
		await physics_frame
	_check(crate.global_position.is_equal_approx(paused_position), "river_swe: pause must freeze crates")
	demo.set_frozen(false)
	demo._menu_builder.flow_action.pressed.emit()
	_check(not demo.river.swe.enabled and demo.river.water_material.get_shader_parameter("swe_enabled") == false,
		"river_swe: comparison action must restore guided flow")
	demo._menu_builder.crate_action.pressed.emit()
	_check(demo.interactions.crates.size() == 2, "river_swe: crates must also work with guided flow")
	var guided_start := crate.global_position
	deadline = Time.get_ticks_msec() + 2500
	while Time.get_ticks_msec() < deadline:
		await physics_frame
	_check(crate.global_position.z < guided_start.z - 0.2, "river_swe: guided fallback must also advect physical crates")
	demo.set_capture_view("near")
	await _boot_frames(2)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tmp/river-crates-verify.png")
	demo.reset_river()
	_check(demo.interactions.crates.is_empty(), "river_swe: reset must clear spawned crates")
	demo._menu_builder.flow_action.pressed.emit()
	_check(demo.river.swe.enabled, "river_swe: comparison must restore SWE selection")
	print("RIVER SWE wet=%d depth_max=%.3f speed_max=%.3f height_change=%.3f mean_change=%.3f downstream=%.3f camera_roundtrip_identical=%s crate_drift=%s" % [
		wet_count, max_depth, max_speed, max_change, mean_change, downstream / maxf(wet_count, 1.0), returned == bytes and returned_foam == old_foam, drift])
	await _check_river_queries(demo)
	demo.queue_free()
	await _boot_frames(3)
	await _check_river_flood_and_foam()
	await _check_river_foam_render()
	manager.set_setting("river_quality_profile", saved_tier)
	_finish("river_swe")


func _run_river_waterfall() -> void:
	await _boot_frames(2)
	root.size = Vector2i(960, 600)
	var manager := root.get_node("GameManager")
	manager.set_setting("river_quality_profile", 1)
	var demo := (load("res://scenes/river_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(demo.capture_ready(), "river_waterfall: river boot must reach its normal ready state")
	if not demo.capture_ready():
		demo.queue_free()
		_finish("river_waterfall")
		return
	demo.set_capture_fixed_delta(1.0 / 60.0)
	for scene: int in [1, 2]:
		demo.set_scene(scene)
		deadline = Time.get_ticks_msec() + 30000
		while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
			await process_frame
		var river: RiverSystem = demo.river
		var angle := 50.0 if scene == 1 else 90.0
		_check(demo.capture_ready() and river.swe.active and river.waterfall != null
			and is_equal_approx(river.field.waterfall.angle_degrees, angle),
			"river_waterfall: controller must boot the selected waterfall through the live SWE system")
		if not river.swe.initialized:
			continue
		var field: RiverField = river.field
		var config: RiverWaterfallConfig = field.waterfall
		var sample_points := [Vector2.ZERO, Vector2(0.0, config.crest_z_m),
			Vector2(config.width_m * 0.5, config.crest_z_m), Vector2(0.0, -field.domain_m.y * 0.5),
			Vector2(0.0, field.domain_m.y * 0.5)]
		for point: Vector2 in sample_points:
			var sample: Color = field.sample(point, river.config.water_level_m)
			_check(Vector4(sample.r, sample.g, sample.b, sample.a).is_finite() and is_finite(field.sample_bed(point))
				and is_finite(field.sample_height(point, river.config.water_level_m)),
				"river_waterfall: edge and transition field samples must stay finite")
		await _boot_frames(150)
		demo.set_frozen(true)
		await _boot_frames(3)
		var status: Dictionary = river.swe.solver.snapshot()
		print("RIVER WATERFALL scene=%d removed=%.6f received=%.6f transport=%.6f cfl=%.5f backlog=%.5f overflow=%d time=%.3f" % [scene,
			status.volume_removed, status.volume_received, status.transport_volume, status.cfl_max, status.backlog_s, status.overflow, status.time_s])
		_check(status.volume_removed > 0.0 and is_finite(status.volume_removed)
			and is_finite(status.volume_received) and is_finite(status.transport_volume)
			and is_finite(status.level_relaxation_volume) and is_finite(status.boundary_volume)
			and is_finite(status.backlog_s) and is_finite(status.cfl_max)
			and int(status.overflow) == 0,
			"river_waterfall: GPU transport diagnostics must be finite and remain within capacity")
		var volume_error := absf(float(status.volume_removed) - float(status.volume_received)
			- float(status.transport_volume)) / maxf(float(status.volume_removed), 0.0001)
		_check(volume_error <= 0.005,
			"river_waterfall: removed volume must equal received plus transported volume within 0.5 percent")
		var grid: Vector2i = river.swe.solver.grid
		var waterfall_size := Vector2i(config.lane_count,
			config.packet_capacity if config.is_vertical() else config.film_cells)
		var surface_before: PackedByteArray = await TextureReadback.new().read_layer(
			status.surface, 0, grid.x * grid.y * 16)
		var fall_before: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_surface, 0, waterfall_size.x * waterfall_size.y * 16)
		var velocity_before: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_velocity, 0, waterfall_size.x * waterfall_size.y * 16)
		var clock_before: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_clock, 0, 16)
		var boundary_bytes: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_boundary, 0, config.lane_count * 16)
		var boundaries := boundary_bytes.to_float32_array()
		var valid_boundaries := boundaries.size() == config.lane_count * 4
		for lane in config.lane_count:
			var offset := lane * 4
			valid_boundaries = valid_boundaries and Vector4(boundaries[offset], boundaries[offset + 1],
				boundaries[offset + 2], boundaries[offset + 3]).is_finite() and boundaries[offset + 1] > 0.0
		_check(valid_boundaries, "river_waterfall: GPU reception boundaries must publish finite source heights, lengths, receivers and pool heights")
		if not config.is_vertical():
			var ds := config.length_m() / config.film_cells
			for lane in config.lane_count:
				var bottom := Vector2((float(lane) + 0.5) / config.lane_count * config.width_m - config.width_m * 0.5,
					config.crest_z_m - config.run_m())
				var cell := Vector2i(((bottom - river.swe.region_m.position) / river.swe.cell_m).floor()).clamp(Vector2i.ZERO, grid - Vector2i.ONE)
				var offset := (cell.y * grid.x + cell.x) * 16
				var lower := surface_before.decode_float(offset + 8) if surface_before.decode_float(offset + 12) > 0.02 else river.config.water_level_m
				var last := clampi(floori((config.height_m - config.bed_depth_m - lower) / sin(deg_to_rad(angle)) / ds), 1, config.film_cells - 1)
				_check(absf(boundaries[lane * 4 + 1] - float(last + 1) * ds) < 0.00001,
					"river_waterfall: film reception must follow the simulated pool height, including drawdown below Level")
		var finite_buffers := true
		for value in surface_before.to_float32_array() + fall_before.to_float32_array() \
				+ velocity_before.to_float32_array() + clock_before.to_float32_array():
			finite_buffers = finite_buffers and is_finite(value)
		_check(finite_buffers, "river_waterfall: GPU surface and waterfall state must remain finite")
		var sheet_state: PackedFloat32Array = fall_before.to_float32_array()
		var clearance := INF
		for offset in range(0, sheet_state.size(), 4):
			if sheet_state[offset + 3] <= 0.00001:
				continue
			var point := Vector2(sheet_state[offset], sheet_state[offset + 2])
			clearance = minf(clearance, sheet_state[offset + 1] - field.sample_ground_height(point))
		_check(clearance >= 0.0099, "river_waterfall: both transports must stay above the actual collision triangles")
		print("RIVER WATERFALL scene=%d ground_clearance=%.6f" % [scene, clearance])
		if scene == 2:
			var sheet: PackedFloat32Array = fall_before.to_float32_array()
			var sheet_point := Vector3.ZERO
			for row in config.packet_capacity:
				var offset := (row * config.lane_count + config.lane_count / 2) * 4
				if sheet[offset + 3] > 0.00001 and sheet[offset + 1] > 2.0 and sheet[offset + 1] < 4.0:
					sheet_point = Vector3(sheet[offset], sheet[offset + 1], sheet[offset + 2])
					break
			_check(river.submit_body_queries(PackedVector3Array([sheet_point])), "river_waterfall: body query must accept a rendered sheet point")
			var body_batch := river.take_query_batch()
			deadline = Time.get_ticks_msec() + 5000
			while body_batch.is_empty() and Time.get_ticks_msec() < deadline:
				await process_frame
				body_batch = river.take_query_batch()
			_check(not body_batch.is_empty() and body_batch.values[7] == 3.0 and absf(body_batch.values[11]) < 0.00001,
				"river_waterfall: free-sheet queries must describe the same finite volume as the rendered sheet")
		_check(status.cfl_max <= 0.4001 and volume_error < 0.005,
			"river_waterfall: CFL must remain below the configured limit")
		var time_before := river.simulation_time_s
		demo.set_frozen(true)
		await _boot_frames(3)
		status = river.swe.solver.snapshot()
		var surface_after: PackedByteArray = await TextureReadback.new().read_layer(
			status.surface, 0, surface_before.size())
		var fall_after: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_surface, 0, fall_before.size())
		var velocity_after: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_velocity, 0, velocity_before.size())
		var clock_after: PackedByteArray = await TextureReadback.new().read_layer(
			status.waterfall_clock, 0, clock_before.size())
		_check(is_equal_approx(time_before, river.simulation_time_s)
			and surface_before == surface_after and fall_before == fall_after
			and velocity_before == velocity_after and clock_before == clock_after,
			"river_waterfall: pause must freeze both pool and waterfall GPU state byte-for-byte")
		demo.set_frozen(false)
		for preset in 4:
			demo.apply_preset(preset)
			demo.set_speed(4.0)
			demo.set_level(0.65 if preset % 2 == 0 else -0.2)
			await _boot_frames(90)
			status = river.swe.solver.snapshot()
			volume_error = absf(float(status.volume_removed) - float(status.volume_received)
				- float(status.transport_volume)) / maxf(float(status.volume_removed), 0.0001)
			_check(is_finite(status.volume_removed) and is_finite(status.transport_volume)
				and status.cfl_max <= 0.4001 and volume_error < 0.005 and status.overflow == 0,
				"river_waterfall: every preset must retain stable conservative transport at control extremes")
			print("RIVER WATERFALL extreme scene=%d preset=%d error=%.7f cfl=%.5f" % [scene, preset, volume_error, status.cfl_max])
			var admitted: float = status.volume_removed
			demo.set_speed(0.0)
			await _boot_frames(180)
			status = river.swe.solver.snapshot()
			print("RIVER WATERFALL closed scene=%d preset=%d admitted=%.5f removed=%.5f remaining=%.7f" % [scene, preset, admitted, status.volume_removed, status.transport_volume])
			_check(float(status.transport_volume) < 0.03,
				"river_waterfall: closing the flow must retain and drain all transported water")
		demo.apply_preset(1)
		demo.reset_river()
		_check(is_zero_approx(river.simulation_time_s), "river_waterfall: reset must restart the runtime clock")
		var generation: int = river.query_generation
		_check(river.submit_body_queries(PackedVector3Array([Vector3(0.0, 2.0, config.crest_z_m)])),
			"river_waterfall: live solver must accept a body batch before scene switching")
		demo.set_scene(2 if scene == 1 else 1)
		_check(river.query_generation > generation and river.take_query_batch().is_empty(),
			"river_waterfall: reset and scene switching must cancel outstanding asynchronous body queries")
		demo.set_scene(scene)
		deadline = Time.get_ticks_msec() + 30000
		while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
			await process_frame
		if demo.capture_ready():
			var Body := preload("res://scripts/river/river_buoyant_body.gd")
			var crate: RigidBody3D = Body.new()
			demo.interactions.add_child(crate)
			demo.interactions.crates.append(crate)
			crate.global_position = Vector3(0.0, demo.config.water_level_m + 6.3, config.crest_z_m + 2.0)
			crate.linear_velocity = Vector3(0.0, 0.0, -demo.config.speed_m_s)
			var reached_ramp := false
			deadline = Time.get_ticks_msec() + 18000
			while Time.get_ticks_msec() < deadline and (crate.global_position.z > config.crest_z_m - config.run_m() - 1.0 or crate.global_position.y > demo.config.water_level_m + 0.7):
				await physics_frame
				reached_ramp = reached_ramp or demo.river.field.water_zone(Vector2(crate.global_position.x, crate.global_position.z)) == WaterfallField.ZONE_RAMP
			_check((reached_ramp or scene == 2) and crate.global_position.z < config.crest_z_m - config.run_m() - 1.0
				and crate.global_position.y < demo.config.water_level_m + 1.0,
				"river_waterfall: floating body must descend from the upper pool down the ramp into the basin")
			print("RIVER WATERFALL crate scene=%d position=%s velocity=%s support=%s" % [scene, crate.global_position, crate.linear_velocity, crate.last_support_force_n])
			await _boot_frames(180)
			_check(crate.global_position.y > demo.config.water_level_m - 0.3
				and crate.global_position.y < demo.config.water_level_m + 0.7
				and crate.last_support_force_n.y > 100.0,
				"river_waterfall: the descended crate must regain buoyancy and remain afloat in the basin")
			demo.interactions.clear()
			await _boot_frames(2)
	demo.apply_preset(1)
	demo.set_scene(1)
	for angle: float in [20.0, 35.0, 65.0, 80.0, 89.0, 89.9, 90.0]:
		demo.set_waterfall_angle(angle)
		deadline = Time.get_ticks_msec() + 30000
		while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(demo.capture_ready(), "river_waterfall: changing angle must reach the runtime ready state")
		if not demo.capture_ready():
			continue
		await _boot_frames(180)
		demo.set_frozen(true)
		await _boot_frames(3)
		var status: Dictionary = demo.river.swe.solver.snapshot()
		var error := absf(float(status.volume_removed) - float(status.volume_received) - float(status.transport_volume)) / maxf(float(status.volume_removed), 0.0001)
		var profile: RiverWaterfallConfig = demo.river.field.waterfall
		var rows := profile.packet_capacity if profile.is_vertical() else profile.film_cells
		var bytes: PackedByteArray = await TextureReadback.new().read_layer(status.waterfall_surface, 0, profile.lane_count * rows * 16)
		var values := bytes.to_float32_array()
		var finite := true
		var clearance := INF
		for offset in range(0, values.size(), 4):
			finite = finite and Vector4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]).is_finite()
			if values[offset + 3] > 0.00001:
				clearance = minf(clearance, values[offset + 1] - demo.river.field.sample_ground_height(Vector2(values[offset], values[offset + 2])))
		_check(finite and clearance >= 0.0099 and error < 0.005 and status.cfl_max <= 0.4001
			and status.overflow == 0 and status.volume_removed > 0.0,
			"river_waterfall: every supported angle must retain finite, conservative transport above the collision mesh")
		_check(demo.river.waterfall.material.get_shader_parameter("free_fall") == profile.is_vertical(),
			"river_waterfall: render mode must match the actual transport at every angle")
		print("RIVER WATERFALL angle=%.1f error=%.7f cfl=%.5f clearance=%.6f rows=%d" % [angle, error, status.cfl_max, clearance, rows])
		demo.set_frozen(false)
	demo.queue_free()
	await _boot_frames(2)
	manager.set_setting("river_quality_profile", 1)
	_finish("river_waterfall")


func _run_river_shutdown() -> void:
	await _boot_frames(2)
	var manager := root.get_node("GameManager")
	manager.set_setting("river_quality_profile", 3)
	var demo: Node = load("res://scenes/river_demo.tscn").instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(demo.capture_ready() and demo.river.swe.active, "river_shutdown: live river must be ready")
	if not demo.capture_ready():
		quit(1)
		return
	if not _extra.is_empty() and _extra[0] == "active":
		print("RIVER SHUTDOWN pending_query=false active=true")
		manager.quit_game()
		return
	demo._menu_builder.crate_action.pressed.emit()
	var solver: RefCounted = demo.river.swe.solver
	var pending := false
	while not pending and Time.get_ticks_msec() < deadline:
		await process_frame
		solver._mutex.lock()
		pending = solver._query_busy
		solver._mutex.unlock()
	_check(pending and demo.interactions.crates.size() == 1,
		"river_shutdown: player crate must have a GPU water query pending at exit")
	if not pending:
		quit(1)
		return
	print("RIVER SHUTDOWN pending_query=true active=true")
	manager.quit_game()


func _run_river_motion() -> void:
	await _boot_frames(2)
	var guided := _extra.size() > 1 and _extra[1] == "guided"
	root.size = Vector2i(906, 574)
	root.get_node("GameManager").set_setting("river_quality_profile", 1)
	var output_dir := "res://tmp/river-motion-probe" if _extra.is_empty() else _extra[0]
	if output_dir.begins_with("res://"):
		output_dir = ProjectSettings.globalize_path(output_dir)
	elif not output_dir.begins_with("/"):
		output_dir = ProjectSettings.globalize_path("res://" + output_dir)
	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	if error != OK:
		push_error("PROBE NOT DONE river_motion: cannot create output directory %s (%s)" % [output_dir, error])
		quit(1)
		return
	var demo := (load("res://scenes/river_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	demo.set_capture_ui(false)
	demo.set_capture_fixed_delta(1.0 / 60.0)
	demo.orbit.target = Vector3(2.0, 1.0, 3.5)
	demo.orbit.distance = 13.0
	demo.orbit.pitch = -70.0
	demo.orbit.yaw = 180.0
	demo.orbit._update_transform()
	var deadline := Time.get_ticks_msec() + 90000
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not demo.capture_ready() or not demo.river.swe.active:
		push_error("PROBE NOT DONE river_motion: SWE-backed river did not become ready and active")
		quit(1)
		return
	if guided:
		demo._menu_builder.flow_action.pressed.emit()
		if demo.river.swe.active:
			push_error("PROBE NOT DONE river_motion: Flow action did not select guided flow")
			quit(1)
			return
	if not await _river_motion_capture(demo, output_dir, "natural_boot"):
		quit(1)
		return
	while demo.river.simulation_time_s < 7.0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if demo.river.simulation_time_s < 7.0 or not demo.river.swe.initialized:
		push_error("PROBE NOT DONE river_motion: Natural Flow did not reach 7 s with SWE initialized")
		quit(1)
		return
	if not await _river_motion_capture(demo, output_dir, "natural_7s"):
		quit(1)
		return
	demo._menu_builder.preset_option.select(2)
	demo._menu_builder.preset_option.item_selected.emit(2)
	if demo.preset_index != 2 or not demo.river.swe.initialized or demo.river.swe.active == guided:
		push_error("PROBE NOT DONE river_motion: Rapids preset switch changed the selected flow")
		quit(1)
		return
	while demo.river.simulation_time_s < 7.0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if demo.river.simulation_time_s < 7.0:
		push_error("PROBE NOT DONE river_motion: Rapids did not reach 7 s")
		quit(1)
		return
	if not await _river_motion_capture(demo, output_dir, "rapids_7s"):
		quit(1)
		return
	while demo.river.simulation_time_s < 15.0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if demo.river.simulation_time_s < 15.0:
		push_error("PROBE NOT DONE river_motion: Rapids did not reach 15 s")
		quit(1)
		return
	if not await _river_motion_capture(demo, output_dir, "rapids_15s"):
		quit(1)
		return
	var quality_option: OptionButton = demo._menu_builder.quality_option
	for tier: int in [1, 3]:
		if demo.quality.requested != tier:
			quality_option.select(tier)
			quality_option.item_selected.emit(tier)
		if demo.quality.requested != tier or demo.quality.effective != tier or not demo.river.swe.initialized or demo.river.swe.active == guided:
			push_error("PROBE NOT DONE river_motion: quality %s switch changed the selected flow" % demo.quality.label())
			quit(1)
			return
		var quality_name := "medium" if tier == 1 else "ultra"
		for moving: bool in [false, true]:
			demo.orbit.distance = 13.0
			for frame in 180:
				demo.orbit.yaw = 180.0 + (12.0 * sin(float(frame) / 179.0 * TAU) if moving else 0.0)
				demo.orbit._update_transform()
				await process_frame
				if frame % 6 == 5:
					var view_name := "moving" if moving else "fixed"
					if not await _river_motion_capture(demo, output_dir,
						"%s_%s_%03d" % [quality_name, view_name, frame + 1]):
						quit(1)
						return
		if not demo.river.swe.initialized or demo.river.swe.active == guided:
			push_error("PROBE NOT DONE river_motion: selected flow changed during %s camera sequence" % quality_name)
			quit(1)
			return
		demo.orbit.distance = 32.0
		demo.orbit._update_transform()
		await _boot_frames(12)
		if not await _river_motion_capture(demo, output_dir, "%s_far32" % quality_name):
			quit(1)
			return
		demo.orbit.distance = 13.0
		demo.orbit._update_transform()
		await _boot_frames(12)
		if not demo.river.swe.initialized or demo.river.swe.active == guided:
			push_error("PROBE NOT DONE river_motion: selected flow changed after far-camera return at %s" % quality_name)
			quit(1)
			return
		if not await _river_motion_capture(demo, output_dir, "%s_return13" % quality_name):
			quit(1)
			return
	print("PROBE DONE river_motion dir=%s shots=natural_boot,natural_7s,rapids_7s,rapids_15s,medium,ultra" % output_dir)
	demo.queue_free()
	await _boot_frames(2)
	quit(0)


func _river_motion_capture(demo: Node, output_dir: String, name: String) -> bool:
	await RenderingServer.frame_post_draw
	var path := output_dir.path_join(name + ".png")
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		push_error("PROBE NOT DONE river_motion: failed to save %s (%s)" % [path, error])
		return false
	print("RIVER MOTION path=%s time=%.3f preset=%d SWE=%s quality=%s TAA=%s distance=%.1f" % [
		path, demo.river.simulation_time_s, demo.preset_index, demo.river.swe.active,
		demo.quality.label(), root.use_taa, demo.orbit.distance])
	return true


func _run_river_foam_render() -> void:
	await _boot_frames(2)
	await _check_river_foam_render()
	_finish("river_foam_render")


func _check_river_foam_render() -> void:
	const SIZE := 256
	const DOMAIN := Vector2(8.0, 8.0)
	const TAU := 6.283185307179586
	var view := SubViewport.new()
	view.size = Vector2i(SIZE, SIZE)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new()
	view.add_child(camera)
	camera.position = Vector3(0.0, 5.0, 0.0)
	camera.look_at(Vector3.ZERO, Vector3.BACK)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0 / 0.28
	camera.make_current()
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string("res://shaders/river/river_water.gdshader") \
		.replace("depth_draw_always;", "depth_draw_always, unshaded;") \
		.replace("ALPHA = wet_coverage;", "ALBEDO = vec3(foam); EMISSION = vec3(0.0); RADIANCE = vec4(0.0); ALPHA = wet_coverage;")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("domain_m", DOMAIN)
	material.set_shader_parameter("foam_detail", true)
	material.set_shader_parameter("reflection_enabled", false)
	material.set_shader_parameter("ripple_height_m", 0.0)
	material.set_shader_parameter("swe_region_m", Vector4(-20.0, -20.0, 40.0, 40.0))
	var zero_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	zero_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	var zero_texture := ImageTexture.create_from_image(zero_image)
	material.set_shader_parameter("bed_height_texture", zero_texture)
	material.set_shader_parameter("turbulence_texture", zero_texture)
	material.set_shader_parameter("swe_foam", zero_texture)
	var terrain_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	terrain_image.fill(Color(-1.0, 0.0, 0.0, 1.0))
	material.set_shader_parameter("swe_terrain", ImageTexture.create_from_image(terrain_image))
	var foam_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	foam_image.fill(Color(0.45, 0.0, 0.0, 1.0))
	var foam_texture := ImageTexture.create_from_image(foam_image)
	material.set_shader_parameter("foam_map", foam_texture)
	var pattern_image := Image.create(64, 64, false, Image.FORMAT_RGBAF)
	var noise_image := Image.create(64, 64, false, Image.FORMAT_RGBAF)
	for y in 64:
		for x in 64:
			var u := float(x) * TAU / 64.0
			var v := float(y) * TAU / 64.0
			var filament := clampf(0.5 + 0.32 * sin(3.0 * u + 2.0 * v) + 0.24 * cos(2.0 * u - 5.0 * v)
				+ 0.18 * sin(7.0 * u + v), 0.0, 1.0)
			var noise := clampf(0.5 + 0.22 * sin(2.0 * u + v) + 0.18 * cos(3.0 * u - 2.0 * v), 0.0, 1.0)
			pattern_image.set_pixel(x, y, Color(filament, 0.0, 0.0, 1.0))
			noise_image.set_pixel(x, y, Color(noise, noise, noise, 1.0))
	pattern_image.generate_mipmaps()
	noise_image.generate_mipmaps()
	var pattern_texture := ImageTexture.create_from_image(pattern_image)
	var noise_texture := ImageTexture.create_from_image(noise_image)
	material.set_shader_parameter("foam_filaments", pattern_texture)
	material.set_shader_parameter("foam_bubbles", pattern_texture)
	material.set_shader_parameter("turbulence_texture", noise_texture)
	var surface := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = DOMAIN
	surface.mesh = mesh
	surface.material_override = material
	view.add_child(surface)
	var field_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	var swe_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	swe_image.fill(Color(0.0, 2.0, 0.0, 1.0))
	var swe_texture := ImageTexture.create_from_image(swe_image)
	var foam_cases: Array[Dictionary] = [
		{"name": "positive_x", "velocity": Vector2(2.0, 0.0), "guide": Vector2.RIGHT, "speed": 2.0, "live": false},
		{"name": "negative_x", "velocity": Vector2(-2.0, 0.0), "guide": Vector2.LEFT, "speed": 2.0, "live": false},
		{"name": "positive_z", "velocity": Vector2(0.0, 2.0), "guide": Vector2.DOWN, "speed": 2.0, "live": false},
		{"name": "double_speed", "velocity": Vector2(4.0, 0.0), "guide": Vector2.RIGHT, "speed": 4.0, "live": false},
		{"name": "live_swe", "velocity": Vector2(0.0, 2.0), "guide": Vector2.RIGHT, "speed": 2.0, "live": true},
		{"name": "live_swe_zero_drive", "velocity": Vector2(0.0, 2.0), "guide": Vector2.RIGHT, "speed": 0.0, "live": true},
	]
	var initial_images: Array[Image] = []
	var moved_images: Array[Image] = []
	var offsets: Array[Vector2] = []
	for test_case: Dictionary in foam_cases:
		var velocity: Vector2 = test_case["velocity"]
		var guide: Vector2 = test_case["guide"]
		var live: bool = test_case["live"]
		field_image.fill(Color(guide.x, guide.y, 0.0, 1.0))
		var field_texture := ImageTexture.create_from_image(field_image)
		material.set_shader_parameter("flow_map", field_texture)
		material.set_shader_parameter("speed_m_s", test_case["speed"])
		material.set_shader_parameter("foam_reference_flow", guide)
		material.set_shader_parameter("swe_enabled", live)
		material.set_shader_parameter("swe_surface", swe_texture if live else zero_texture)
		material.set_shader_parameter("swe_foam", foam_texture if live else zero_texture)
		material.set_shader_parameter("flow_distance_m", 0.0)
		material.set_shader_parameter("simulation_time_s", 0.0)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		initial_images.append(view.get_texture().get_image())
		var distance := float(test_case["speed"]) * 0.05
		material.set_shader_parameter("flow_distance_m", distance)
		material.set_shader_parameter("simulation_time_s", 0.05)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		moved_images.append(view.get_texture().get_image())
		var origin := camera.unproject_position(Vector3.ZERO)
		var endpoint := camera.unproject_position(Vector3(velocity.x * 0.05, 0.0, velocity.y * 0.05))
		offsets.append(endpoint - origin)
	for index in foam_cases.size():
		var offset: Vector2 = offsets[index]
		var aligned_error := 0.0
		var still_error := 0.0
		var samples := 0.0
		for y in range(24, SIZE - 24):
			for x in range(24, SIZE - 24):
				var source := Vector2(x, y) - offset
				var low := Vector2i(floori(source.x), floori(source.y))
				var fraction := source - Vector2(low)
				var a := initial_images[index].get_pixel(low.x, low.y).srgb_to_linear()
				var b := initial_images[index].get_pixel(low.x + 1, low.y).srgb_to_linear()
				var c := initial_images[index].get_pixel(low.x, low.y + 1).srgb_to_linear()
				var d := initial_images[index].get_pixel(low.x + 1, low.y + 1).srgb_to_linear()
				var expected := a.lerp(b, fraction.x).lerp(c.lerp(d, fraction.x), fraction.y).r
				var actual := moved_images[index].get_pixel(x, y).srgb_to_linear().r
				aligned_error += absf(expected - actual)
				still_error += absf(initial_images[index].get_pixel(x, y).srgb_to_linear().r - actual)
				samples += 1.0
		aligned_error /= samples
		still_error /= samples
		_check(offset.length() > 5.0 and aligned_error < 0.04 and aligned_error < still_error * 0.75,
			"river_foam_render: %s foam must translate by the projected local velocity" % foam_cases[index]["name"])
		print("RIVER FOAM %s offset=%s aligned=%.5f stationary=%.5f" % [
			foam_cases[index]["name"], offset, aligned_error, still_error])
	_check(offsets[0].x * offsets[1].x < 0.0 and absf(offsets[3].x - offsets[0].x * 2.0) < 0.01,
		"river_foam_render: reversing direction and doubling speed must reverse and double displacement")
	var circular_image := Image.create(64, 64, false, Image.FORMAT_RGBAF)
	for y in 64:
		for x in 64:
			var point := (Vector2((float(x) + 0.5) / 64.0, (float(y) + 0.5) / 64.0) - Vector2(0.5, 0.5)) * DOMAIN
			var radius := point.length()
			var velocity := Vector2(-point.y, point.x) / maxf(radius, 0.5)
			circular_image.set_pixel(x, y, Color(velocity.x, velocity.y, 0.0, 1.0))
	material.set_shader_parameter("flow_map", ImageTexture.create_from_image(circular_image))
	material.set_shader_parameter("foam_reference_flow", Vector2.RIGHT)
	material.set_shader_parameter("speed_m_s", 2.0)
	material.set_shader_parameter("swe_enabled", false)
	material.set_shader_parameter("swe_surface", zero_texture)
	material.set_shader_parameter("swe_foam", zero_texture)
	material.set_shader_parameter("flow_distance_m", 0.0)
	material.set_shader_parameter("simulation_time_s", 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var circular_render := view.get_texture().get_image()
	var circular_error := 0.0
	for y in range(24, SIZE - 24):
		for x in range(24, SIZE - 24):
			circular_error += absf(initial_images[0].get_pixel(x, y).srgb_to_linear().r
				- circular_render.get_pixel(x, y).srgb_to_linear().r)
	circular_error /= float((SIZE - 48) * (SIZE - 48))
	_check(circular_error < 0.01,
		"river_foam_render: newborn foam detail must not fold into circular arcs in a nonuniform guide field")
	print("RIVER FOAM circular_guide_error=%.6f" % circular_error)
	field_image.fill(Color(1.0, 0.0, 0.0, 1.0))
	material.set_shader_parameter("flow_map", ImageTexture.create_from_image(field_image))
	material.set_shader_parameter("foam_reference_flow", Vector2(0.25, 0.0))
	material.set_shader_parameter("swe_enabled", false)
	material.set_shader_parameter("swe_surface", zero_texture)
	material.set_shader_parameter("swe_foam", zero_texture)
	material.set_shader_parameter("flow_distance_m", 0.0)
	material.set_shader_parameter("simulation_time_s", 0.0)
	var means := PackedFloat32Array()
	var contrasts := PackedFloat32Array()
	var cycle_images: Array[Image] = []
	field_image.fill(Color(1.0, 0.0, 0.0, 1.0))
	var field_texture := ImageTexture.create_from_image(field_image)
	material.set_shader_parameter("flow_map", field_texture)
	material.set_shader_parameter("speed_m_s", 2.0)
	material.set_shader_parameter("foam_reference_flow", Vector2(0.25, 0.0))
	material.set_shader_parameter("swe_enabled", false)
	for time: float in [0.0, 0.5, 1.0, 1.5, 2.0]:
		material.set_shader_parameter("flow_distance_m", time * 2.0)
		material.set_shader_parameter("simulation_time_s", time)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := view.get_texture().get_image()
		cycle_images.append(image)
		var sum := 0.0
		var squared_sum := 0.0
		for y in SIZE:
			for x in SIZE:
				var value := image.get_pixel(x, y).srgb_to_linear().r
				sum += value
				squared_sum += value * value
		var count := float(SIZE * SIZE)
		means.append(sum / count)
		contrasts.append(sqrt(maxf(squared_sum / count - pow(sum / count, 2.0), 0.0)))
	var baseline_mean := maxf(means[0], 0.0001)
	var min_contrast := contrasts[0]
	var mean_error := 0.0
	for index in range(1, means.size()):
		mean_error = maxf(mean_error, absf(means[index] - means[0]) / baseline_mean)
		min_contrast = minf(min_contrast, contrasts[index])
	_check(means[0] > 0.1 and contrasts[0] > 0.02 and mean_error < 0.05
		and min_contrast > contrasts[0] * 0.8,
		"river_foam_render: local foam advection must preserve coverage and contrast over two seconds")
	var cycle_difference := 0.0
	for y in SIZE:
		for x in SIZE:
			cycle_difference += absf(cycle_images[0].get_pixel(x, y).srgb_to_linear().r
				- cycle_images[3].get_pixel(x, y).srgb_to_linear().r)
	cycle_difference /= float(SIZE * SIZE)
	_check(cycle_difference > 0.05, "river_foam_render: foam must keep travelling across a complete flow cycle")
	print("RIVER FOAM full_cycle_change=%.6f" % cycle_difference)
	var phase_edges := [[1.5 - 0.0001, 1.5 + 0.0001], [0.75 - 0.0001, 0.75 + 0.0001],
		[0.375 - 0.003, 0.375 + 0.003], [1.125 - 0.003, 1.125 + 0.003]]
	for edge: Array in phase_edges:
		var edge_images: Array[Image] = []
		for time: float in edge:
			material.set_shader_parameter("flow_distance_m", time * 2.0)
			material.set_shader_parameter("simulation_time_s", time)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			edge_images.append(view.get_texture().get_image())
		var edge_error := 0.0
		var delta_s := float(edge[1]) - float(edge[0])
		var offset := camera.unproject_position(Vector3(2.0 * delta_s, 0.0, 0.0)) - camera.unproject_position(Vector3.ZERO)
		for y in range(24, SIZE - 24):
			for x in range(24, SIZE - 24):
				var source := Vector2(x, y) - offset
				var low := Vector2i(floori(source.x), floori(source.y))
				var fraction := source - Vector2(low)
				var a := edge_images[0].get_pixel(low.x, low.y).srgb_to_linear()
				var b := edge_images[0].get_pixel(low.x + 1, low.y).srgb_to_linear()
				var c := edge_images[0].get_pixel(low.x, low.y + 1).srgb_to_linear()
				var d := edge_images[0].get_pixel(low.x + 1, low.y + 1).srgb_to_linear()
				var expected := a.lerp(b, fraction.x).lerp(c.lerp(d, fraction.x), fraction.y).r
				edge_error += absf(expected - edge_images[1].get_pixel(x, y).srgb_to_linear().r)
		edge_error /= float((SIZE - 48) * (SIZE - 48))
		_check(edge_error < 0.01, "river_foam_render: foam transitions must remain continuous after accounting for physical transport")
		print("RIVER FOAM crossing_time=%.6f aligned_change=%.6f" % [float(edge[0]), edge_error])
	var normals_shader := Shader.new()
	normals_shader.code = FileAccess.get_file_as_string("res://shaders/river/river_water.gdshader") \
		.replace("depth_draw_always;", "depth_draw_always, unshaded;") \
		.replace("ALPHA = wet_coverage;", "ALBEDO = NORMAL * 0.5 + 0.5; EMISSION = vec3(0.0); RADIANCE = vec4(0.0); ALPHA = wet_coverage;")
	material.shader = normals_shader
	var normal_image := Image.create(2, 1, false, Image.FORMAT_RGBAF)
	normal_image.set_pixel(0, 0, Color(0.2, 0.5, 1.0, 1.0))
	normal_image.set_pixel(1, 0, Color(0.8, 0.5, 1.0, 1.0))
	material.set_shader_parameter("micro_normal", ImageTexture.create_from_image(normal_image))
	material.set_shader_parameter("foam_detail", false)
	material.set_shader_parameter("foam_enabled", false)
	material.set_shader_parameter("surface_detail", 1.0)
	material.set_shader_parameter("ripple_height_m", 0.18)
	material.set_shader_parameter("flow_map", field_texture)
	var normals: Array[Image] = []
	for distance: float in [1.5 - 0.0001, 1.5 + 0.0001]:
		material.set_shader_parameter("flow_distance_m", distance)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		normals.append(view.get_texture().get_image())
	var normal_jump := 0.0
	for y in SIZE:
		for x in SIZE:
			normal_jump += absf(normals[0].get_pixel(x, y).srgb_to_linear().r
				- normals[1].get_pixel(x, y).srgb_to_linear().r)
	normal_jump /= float(SIZE * SIZE)
	_check(normal_jump < 0.005, "river_foam_render: Ultra water normals must remain continuous when the flow phase wraps")
	print("RIVER FOAM mean_error=%.5f min_contrast=%.5f normal_phase_jump=%.6f" % [mean_error, min_contrast, normal_jump])
	view.queue_free()
	await _boot_frames(2)


func _river_query(river: RiverSystem, points: PackedVector2Array) -> Dictionary:
	if not river.submit_queries(points):
		_check(false, "river_swe: query submission must succeed")
		return {}
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var batch := river.take_query_batch()
		if not batch.is_empty():
			_check(batch.points == points and batch.values.size() == points.size() * 4,
				"river_swe: queries must preserve order and return exactly four values per point")
			return batch
		await process_frame
	_check(false, "river_swe: query readback must finish before its deadline")
	return {}


func _check_river_queries(demo: Node) -> void:
	var river: RiverSystem = demo.river
	var query_deadline := Time.get_ticks_msec() + 10000
	while demo.interactions._pending and Time.get_ticks_msec() < query_deadline:
		await physics_frame
	_check(not demo.interactions._pending, "river_swe: crate query ownership must drain before direct query checks")
	demo.set_frozen(true)
	river.swe.set_enabled(false)
	var rock: Vector4 = river.field.obstacles[0]
	var bank_x := RiverLandscape.center_x(0.0) + RiverLandscape.half_width(0.0)
	var bank_end := bank_x + 8.0
	for iteration in 28:
		var middle := (bank_x + bank_end) * 0.5
		var depth := river.field.sample_height(Vector2(middle, 0.0), river.config.water_level_m) - river.field.sample_bed(Vector2(middle, 0.0))
		if depth > 0.06:
			bank_x = middle
		else:
			bank_end = middle
	var guided_points := PackedVector2Array([Vector2(bank_x, 0.0), Vector2(rock.x, rock.y),
		Vector2(rock.x, rock.y - rock.z * 2.0), Vector2(100.0, 100.0)])
	var batch := await _river_query(river, guided_points)
	if batch.is_empty():
		return
	_check(absf(batch.values[3] - 0.06) < 0.00001 and batch.values[7] == 0.0
		and batch.values[13] == 0.0 and batch.values[14] == 0.0 and batch.values[15] == 0.0,
		"river_swe: initialized guided queries must preserve shallow depth, dry obstacles and domain bounds")
	var wake_flow := river.field.sample(guided_points[2], river.config.water_level_m)
	_check(absf(batch.values[9] - wake_flow.r * river.config.speed_m_s) < 0.00001
		and absf(batch.values[10] - wake_flow.g * river.config.speed_m_s) < 0.00001,
		"river_swe: guided queries must use the current-level obstacle-deflected flow")
	river.swe.set_enabled(true)
	for tier: int in [1, 2]:
		demo.set_quality_profile(tier)
		await _boot_frames(3)
		var region := river.swe.region_m
		var points := PackedVector2Array([region.get_center(), region.position + Vector2(1.75, 12.0),
			Vector2(RiverLandscape.center_x(region.end.y + 1.0), region.end.y + 1.0)])
		var status := river.swe.solver.snapshot()
		var grid := river.swe.solver.grid
		var bytes := await TextureReadback.new().read_layer(status.surface, 0, grid.x * grid.y * 16)
		var published := RiverField.new()
		published.domain_m = region.size
		published.solver_terrain_image = Image.create_from_data(grid.x, grid.y, false, Image.FORMAT_RGBAF, bytes)
		batch = await _river_query(river, points)
		if batch.is_empty():
			return
		for index in points.size():
			var point := points[index]
			var surface := published._sample_data(point - region.get_center())
			var flow := river.field.sample(point, river.config.water_level_m)
			var height := river.field.sample_height(point, river.config.water_level_m)
			var depth := maxf(height - river.field.sample_bed(point), 0.0) if flow.a > 0.0 else 0.0
			var inside := Rect2(-river.field.domain_m * 0.5, river.field.domain_m).has_point(point)
			var guided := Vector4(height, flow.r * river.config.speed_m_s if inside else 0.0,
				flow.g * river.config.speed_m_s if inside else 0.0, depth if inside else 0.0)
			var live := Vector4(surface.b, surface.r, surface.g, surface.a)
			var weight := 1.0 if index == 0 else (0.5 if index == 1 else 0.0)
			var expected := guided.lerp(live, weight)
			for channel in 4:
				_check(absf(batch.values[index * 4 + channel] - expected[channel]) < 0.0001,
					"river_swe: query blend must match the published surface inside, across and outside the fixed domain")
		if tier == 2:
			var expected: PackedFloat32Array = batch.values
			_check(river.submit_queries(points), "river_swe: snapshot query must be accepted")
			_check(not river.submit_queries(points), "river_swe: pending GPU batch must reject another query")
			var old_level := river.config.water_level_m
			demo.move_capture_camera(Vector3(4.0, 0.0, 0.0))
			demo.orbit._update_transform()
			demo.set_quality_profile(0)
			demo.set_level(old_level + 0.1)
			await _boot_frames(3)
			var deadline := Time.get_ticks_msec() + 10000
			batch = river.take_query_batch()
			while batch.is_empty() and Time.get_ticks_msec() < deadline:
				await process_frame
				batch = river.take_query_batch()
			_check(not batch.is_empty(), "river_swe: camera and quality changes must not strand a GPU batch")
			if not batch.is_empty():
				for index in expected.size():
					_check(absf(batch.values[index] - expected[index]) < 0.0001,
						"river_swe: in-flight query weights and guided values must retain their submission state")
			_check((demo._menu_builder.flow_action.find_child("ActionCaption", true, false) as Label).text == "SWE"
				and river.swe.active, "river_swe: Low must retain the selected live solver")
	print("RIVER SWE queries=guided_and_live snapshot=true camera_independent=true")


func _check_river_flood_and_foam() -> void:
	var river := RiverSystem.new()
	river.config = RiverConfig.new()
	river.config.water_level_m = 0.0
	river.config.foam_amount = 0.0
	river.field = RiverField.new()
	river.field.domain_m = Vector2(24.07, 40.03)
	river.field.solver_terrain_image = Image.create(2, 2, false, Image.FORMAT_RGBAF)
	river.field.solver_terrain_image.fill(Color(0.0, 0.0, 0.0, -1.0))
	river.camera = Camera3D.new()
	root.add_child(river.camera)
	river.scene_world = river.camera.get_world_3d()
	river.compute_available = GpuPreflight.available()
	river.reflection_scale = 0.0
	river.foam_size_px = Vector2i(16, 16)
	river.frozen = true
	river.fixed_delta_s = 1.0 / 60.0
	root.add_child(river)
	river.start()
	var deadline := Time.get_ticks_msec() + 10000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(river.swe.initialized, "river_swe: isolated basin must initialize through RiverSystem.start")
	_check(river.swe.region_m.size == Vector2(river.swe.solver.grid) * river.swe.cell_m,
		"river_swe: custom field UV bounds must match the rounded simulation grid")
	if not river.swe.initialized:
		river.camera.queue_free()
		river.queue_free()
		return
	for count: int in [1, 4, 32]:
		var points := PackedVector2Array()
		points.resize(count)
		points.fill(Vector2.ZERO)
		var batch := await _river_query(river, points)
		if not batch.is_empty():
			_check(batch.values[3] == 0.0, "river_swe: a dry basin must initially have zero depth")
	await _check_river_foam_sources(river)
	var start_time := float(river.swe.solver.snapshot().time_s)
	river.config.water_level_m = 0.06
	river.apply_config(river.config)
	_check(not river.swe._reset, "river_swe: raising the level must preserve accumulated solver state")
	river.frozen = false
	deadline = Time.get_ticks_msec() + 10000
	while float(river.swe.solver.snapshot().time_s) < start_time + 2.0 and Time.get_ticks_msec() < deadline:
		await process_frame
	river.frozen = true
	var flooded := await _river_query(river, PackedVector2Array([Vector2.ZERO]))
	if not flooded.is_empty():
		_check(flooded.values[3] > 0.02 and flooded.values[2] < -0.01,
			"river_swe: a level increase must wet isolated dry cells and restore their driving current without reset")
		print("RIVER SWE flood_depth=%.6f flood_velocity_z=%.6f" % [flooded.values[3], flooded.values[2]])
	await _check_river_foam_rates(river)
	river.swe.set_enabled(true)
	await _boot_frames(3)
	_check(river.swe.active and river.submit_queries(PackedVector2Array([Vector2.ZERO]))
		and not river._query_weights.is_empty(), "river_swe: stop regression must have an outstanding GPU query")
	var cache_hits := ShaderCache._hits
	var cache_misses := ShaderCache._misses
	river.stop()
	_check(river.take_query_batch().is_empty() and river._query_weights.is_empty() and river._query_guided.is_empty(),
		"river_swe: stop must discard all pending query data")
	river.start()
	deadline = Time.get_ticks_msec() + 10000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(river.swe.initialized, "river_swe: restart after a pending GPU query must initialize")
	_check(ShaderCache._hits > cache_hits and ShaderCache._misses == cache_misses,
		"river_swe: restart must reuse cached bytecode without compiling the unchanged shader")
	if river.swe.initialized:
		var restarted := await _river_query(river, PackedVector2Array([Vector2.ZERO]))
		if not restarted.is_empty():
			_check(restarted.values[3] > 0.05, "river_swe: restart must deliver a new water batch without stale query data")
	river.stop()
	river.camera.queue_free()
	river.queue_free()
	await _boot_frames(3)


func _check_river_foam_sources(river: RiverSystem) -> void:
	var original_field := river.field
	var original_config := river.config.duplicate() as RiverConfig
	var source_cases := ["uniform", "transverse_shear", "grade", "convergence", "eddy", "drop"]
	for case_name: String in source_cases:
		river.stop()
		river.field = _river_foam_source_field(case_name)
		river.config.water_level_m = 0.0
		river.config.speed_m_s = 1.0
		river.config.foam_amount = 1.0
		river.config.whitewater_strength = 1.0
		river.frozen = true
		river.start()
		var deadline := Time.get_ticks_msec() + 10000
		while (not river.swe.initialized or river.swe._reset) and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(river.swe.initialized, "river_swe: %s source field must initialize" % case_name)
		if not river.swe.initialized:
			break
		await RenderingServer.frame_post_draw
		var grid := river.swe.solver.grid
		var status: Dictionary = river.swe.solver.snapshot()
		var bytes: PackedByteArray = await TextureReadback.new().read_layer(status.foam, 0, grid.x * grid.y * 16)
		_check(not bytes.is_empty(), "river_swe: %s foam source readback failed" % case_name)
		if bytes.is_empty():
			continue
		var values := bytes.to_float32_array()
		var max_source := 0.0
		var center_source := 0.0
		var away_source := 0.0
		for y in grid.y:
			for x in grid.x:
				var offset := (y * grid.x + x) * 4
				var source: float = values[offset + 1]
				var world_x := (float(x) + 0.5) * river.swe.cell_m - grid.x * river.swe.cell_m * 0.5
				var world_z := (float(y) + 0.5) * river.swe.cell_m - grid.y * river.swe.cell_m * 0.5
				max_source = maxf(max_source, source)
				if absf(world_x) < 0.5 and absf(world_z) < 0.5:
					center_source = maxf(center_source, source)
				elif (absf(world_z) > 2.0 if case_name == "drop" else Vector2(world_x, world_z).length() > 2.0):
					away_source = maxf(away_source, source)
		if case_name in ["convergence", "eddy", "drop"]:
			_check(center_source > 0.01 and away_source < 0.001,
				"river_swe: %s must create localized foam source (center=%.6f away=%.6f)" % [case_name, center_source, away_source])
		else:
			_check(max_source < 0.001,
				"river_swe: %s flow must not create foam source (max=%.6f)" % [case_name, max_source])
		print("RIVER SWE foam_source case=%s max=%.6f center=%.6f away=%.6f" % [case_name, max_source, center_source, away_source])
	river.stop()
	river.field = original_field
	river.config = original_config
	river.start()
	var deadline := Time.get_ticks_msec() + 10000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(river.swe.initialized, "river_swe: original isolated basin must restart after foam source cases")


func _river_foam_source_field(case_name: String) -> RiverField:
	var field := RiverField.new()
	field.domain_m = Vector2(8.0, 8.0)
	var size := Vector2i(64, 64)
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
	for y in size.y:
		var world_z := (float(y) + 0.5) * 0.125 - 4.0
		for x in size.x:
			var world_x := (float(x) + 0.5) * 0.125 - 4.0
			var transverse := 0.0
			var longitudinal := -1.2
			var height := 0.8
			if case_name == "transverse_shear":
				transverse = 0.25 * world_z
			elif case_name == "grade":
				height += 0.04 * world_z
			elif case_name == "drop":
				height += 0.4 * smoothstep(-0.6, 0.6, world_z)
			elif case_name in ["convergence", "eddy"]:
				var influence := exp(-0.5 * (world_x * world_x + world_z * world_z))
				transverse = -0.8 * (world_z if case_name == "eddy" else world_x) * influence
				longitudinal += 0.8 * (world_x if case_name == "eddy" else -world_z) * influence
			image.set_pixel(x, y, Color(0.0, height, transverse, longitudinal))
	field.solver_terrain_image = image
	return field


func _check_river_foam_rates(river: RiverSystem) -> void:
	river.swe.set_enabled(false)
	river.config.speed_m_s = 1.0
	river.config.foam_amount = 1.0
	river.config.whitewater_strength = 0.0
	var flow_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	flow_image.fill(Color(0.0, 0.0, 0.2, 0.5))
	var flow_texture := ImageTexture.create_from_image(flow_image)
	var noise_image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	noise_image.fill(Color(0.5, 0.5, 0.5, 1.0))
	var noise_texture := ImageTexture.create_from_image(noise_image)
	for material in river._foam_materials:
		material.set_shader_parameter("flow_map", flow_texture)
		material.set_shader_parameter("turbulence_texture", noise_texture)
	var coverages := PackedFloat32Array()
	for rate: int in [30, 60, 120]:
		river.fixed_delta_s = 1.0 / rate
		river.reset()
		river.frozen = false
		var deadline := Time.get_ticks_msec() + 15000
		while river._reset_frames > 0 and Time.get_ticks_msec() < deadline:
			await process_frame
		var target_time := river.simulation_time_s + 5.0
		while river.simulation_time_s < target_time and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(river.simulation_time_s >= target_time, "river_swe: foam rate trial must simulate five seconds")
		river.frozen = true
		await RenderingServer.frame_post_draw
		var image := river._foam_views[1 - river._foam_index].get_texture().get_image()
		coverages.append(image.get_pixel(8, 8).r)
	_check(coverages[1] > 0.001, "river_swe: foam comparison must have measurable transported coverage")
	for coverage in coverages:
		_check(absf(coverage - coverages[1]) / maxf(coverages[1], 0.000001) < 0.05,
			"river_swe: guided foam coverage must agree within five percent at 30, 60 and 120 FPS")
	print("RIVER SWE foam_30=%.6f foam_60=%.6f foam_120=%.6f" % [coverages[0], coverages[1], coverages[2]])


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
	var live_delta := float(live_material.get_shader_parameter("delta"))
	_check(live_delta > 0.0,
		"ocean_freeze: live interaction foam did not advance")
	demo.set_frozen(true)
	await _boot_frames(2)
	var frozen_material: ShaderMaterial = foam._feedback_materials[(foam._frame - 1) & 1]
	_check(is_zero_approx(float(frozen_material.get_shader_parameter("delta"))),
		"ocean_freeze: paused waves still evolve interaction foam")
	demo.set_frozen(false)
	demo.set_time_scale(0.0)
	await _boot_frames(2)
	var paused_material: ShaderMaterial = foam._feedback_materials[(foam._frame - 1) & 1]
	_check(is_zero_approx(float(paused_material.get_shader_parameter("delta"))),
		"ocean_freeze: zero time scale still evolves interaction foam")
	print("OCEAN FREEZE live_delta=%.6f frozen_delta=%.6f paused_delta=%.6f" % [
		live_delta,
		float(frozen_material.get_shader_parameter("delta")),
		float(paused_material.get_shader_parameter("delta"))])
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
	_check(is_zero_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail"))),
		"ocean_ultra: High boot has Ultra surface detail")
	demo.set_quality_profile(OceanQualityProfile.Tier.ULTRA)
	_check(await _wait_ocean_capture_ready(demo), "ocean_ultra: Ultra rebuild did not initialize")
	await RenderingServer.frame_post_draw
	_check(demo.quality.effective == OceanQualityProfile.Tier.ULTRA
		and is_equal_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail")), 1.0),
		"ocean_ultra: Ultra profile did not update the material")
	_check(demo.solver.short_cascade_half_rate,
		"ocean_ultra: Ultra restored the expensive full-rate short cascade")
	_check(demo.solver.initialized and demo.texture_bound
		and demo.solver.get_displacement_tex_rid() != displacement_rid
		and demo.solver.get_foam_near_tex_rid(0) != foam_rid
		and demo.spray._particle_capacity == OceanQualityProfile.SPRAY_CAPACITY[OceanQualityProfile.Tier.ULTRA],
		"ocean_ultra: High to Ultra did not rebuild the physical resource budget")
	displacement_rid = demo.solver.get_displacement_tex_rid()
	foam_rid = demo.solver.get_foam_near_tex_rid(0)
	demo.set_quality_profile(OceanQualityProfile.Tier.HIGH)
	_check(await _wait_ocean_capture_ready(demo), "ocean_ultra: High rebuild did not initialize")
	await RenderingServer.frame_post_draw
	_check(is_zero_approx(float(demo.surface_mat.get_shader_parameter("ultra_detail")))
		and demo.solver.get_displacement_tex_rid() != displacement_rid
		and demo.solver.get_foam_near_tex_rid(0) != foam_rid
		and demo.spray._particle_capacity == OceanQualityProfile.SPRAY_CAPACITY[OceanQualityProfile.Tier.HIGH],
		"ocean_ultra: Ultra to High did not rebuild the physical resource budget")
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
	print("OCEAN ULTRA physical_budget_rebuilt=true boot_detail=1")
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
		var pc := solver._pack_push_constant(0)
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


func _run_ocean_island_spectrum() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "island_spectrum")
	_finish("ocean_island_spectrum")


func _run_ocean_seam() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "seam")
	_finish("ocean_seam")


func _run_ocean_shore_dispersion() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "dispersion")
	_finish("ocean_shore_dispersion")


func _run_ocean_shore_dispersion_2d() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "dispersion_2d")
	_finish("ocean_shore_dispersion_2d")


func _run_ocean_shore_convergence() -> void:
	await _boot_frames(2)
	var anderson_depth := 3 if _extra.has("anderson_depth=3") else 0
	await OceanCoastalProbe.run_dispersive_convergence(self, _check, anderson_depth)
	_finish("ocean_shore_convergence")


func _run_ocean_shore_volume() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "volume")
	_finish("ocean_shore_volume")


func _run_ocean_shore_foam() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "foam")
	_finish("ocean_shore_foam")


func _run_ocean_boundary_phase() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "boundary_phase")
	_finish("ocean_boundary_phase")


func _run_ocean_breaking_diffusion() -> void:
	await _boot_frames(2)
	await OceanCoastalProbe.run(self, _check, "breaking_diffusion")
	_finish("ocean_breaking_diffusion")


func _run_ocean_sph_breaker() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run(self, _check)
	print("BREAKER ACCEPTANCE candidate=sph scope=numerical_particle_state physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_sph_breaker")


func _run_ocean_sph_stiffness() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe._run_resolution(self, _check, 0.12, "sph", 0, 0.0, 400.0)
	print("BREAKER ACCEPTANCE candidate=sph scope=pressure_stiffness physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_sph_stiffness")


func _run_ocean_sph_pressure_conservation() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_sph_pressure_conservation(self, _check)
	_finish("ocean_sph_pressure_conservation")


func _run_ocean_breaker_boot() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_boot(self, _check)
	_finish("ocean_breaker_boot")


func _run_ocean_apic_breaker() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run(self, _check, "apic")
	print("BREAKER ACCEPTANCE candidate=apic scope=numerical_particle_state physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_apic_breaker")


func _run_ocean_apic_rest() -> void:
	await _boot_frames(2)
	for spacing in [0.24, 0.18]:
		await OceanBreakerProbe._run_apic_rest(self, _check, spacing)
	_finish("ocean_apic_rest")


func _run_ocean_apic_surface_projection() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_surface_projection(self, _check)
	_finish("ocean_apic_surface_projection")


func _run_ocean_apic_surface_transport() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_surface_transport(self, _check)
	_finish("ocean_apic_surface_transport")


func _run_ocean_apic_surface_strain() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_surface_strain(self, _check)
	_finish("ocean_apic_surface_strain")


func _run_ocean_apic_geometric_flux_cache() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_geometric_flux_cache(self, _check)
	_finish("ocean_apic_geometric_flux_cache")


func _run_ocean_apic_linear_wave() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_linear_wave(self, _check, not _extra.has("uncoupled=1"), _extra.has("geometric=1"), _extra.has("pressure_planes=1"), 1 if _extra.has("substeps=1") else 3, 1.0 if _extra.has("flip=1") else (0.95 if _extra.has("flip=0.95") else 0.0), _extra.has("geometric_split=1"))
	_finish("ocean_apic_linear_wave")


func _run_ocean_apic_cube_fraction() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_cube_fraction(self, _check)
	_finish("ocean_apic_cube_fraction")


func _run_ocean_apic_amount_transport() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_amount_transport(self, _check, 2 if _extra.has("amount_order=2") else 1)
	_finish("ocean_apic_amount_transport")


func _run_ocean_apic_amount_reconstruction() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_amount_reconstruction(self, _check)
	_finish("ocean_apic_amount_reconstruction")


func _run_ocean_apic_amount_consistency() -> void:
	await _boot_frames(2)
	var ticks := 0 if _extra.has("boot=1") else (30 if _extra.has("ticks=30") else 1)
	await OceanBreakerProbe.run_apic_amount_consistency(self, _check, _extra.has("still_water=1"), ticks,
		_extra.has("advection_only=1"), _extra.has("first_substep=1"))
	_finish("ocean_apic_amount_consistency")


func _run_ocean_apic_surface_wall_barrier() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_surface_wall_barrier(self, _check)
	_finish("ocean_apic_surface_wall_barrier")


func _run_ocean_apic_surface_boot() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_surface_boot(self, _check, _extra.has("amount_surface=1") or _extra.has("geometric=1"), _extra.has("geometric=1"), _extra.has("geometric=1") and _extra.has("grid=0.12"), not _extra.has("rock=0"), 1.0 / 15.0 if _extra.has("slope=15") else 1.0 / 8.0)
	_finish("ocean_apic_surface_boot")


func _run_ocean_island_visual() -> void:
	await _boot_frames(2)
	var old_screen_space_aa := root.screen_space_aa
	var manager := root.get_node("GameManager")
	var old_scene: int = manager.get_setting("ocean_scene_mode", 0)
	var old_quality: int = manager.get_setting("ocean_quality_profile", 2)
	manager.set_setting("ocean_scene_mode", 1)
	manager.set_setting("ocean_quality_profile", 1)
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.initialized and demo.texture_bound, "island visual: runtime boot failed")
	if demo.solver.initialized and demo.texture_bound:
		_check(demo.current_scene_index == 1 and demo.solver.shore_solver.config.visual_breakers_enabled,
			"island visual: restored boot did not select the hybrid coast")
		_check(demo.surface_mat.get_shader_parameter("shore_visual_breakers_enabled") == true,
			"island visual: renderer was not wired at normal boot")
		_check(root.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA,
			"island visual: shoreline antialiasing was not enabled at normal boot")
		_check(demo.solver.foam_near_size == 512, "island visual: Medium foam budget was not applied at boot")
		_check(demo.solver.shore_solver.get_breaker_texture_rid().is_valid()
			and demo.solver.shore_solver.get_contact_texture_rid().is_valid(),
			"island visual: shared crest/contact maps were not created")
		_check(demo.shore_breaker_texture.texture_rd_rid == demo.solver.get_shore_breaker_texture_rid()
			and demo.shore_contact_texture.texture_rd_rid == demo.solver.get_shore_contact_texture_rid()
			and demo.surface_mat.get_shader_parameter("shore_breaker") == demo.shore_breaker_texture
			and demo.island.rock_wet_material.get_shader_parameter("shore_contact") == demo.shore_contact_texture,
			"island visual: runtime consumers did not share crest/contact maps")
		_check(demo.island.rock_wet_material.get_shader_parameter("shore_breaker") == demo.shore_breaker_texture,
			"island visual: runtime consumers did not share crest/contact maps")
		_check(demo.island.terrain_material.get_shader_parameter("shore_breaker") == demo.shore_breaker_texture
			and demo.solver.shore_solver._displacement_rid == demo.solver.get_displacement_tex_rid()
			and demo.solver.shore_solver._velocity_rid == demo.solver.velocity_solver.get_texture_rid(),
			"island visual: normal boot did not bind the shared FFT carrier to the coast and terrain")
		_check(is_equal_approx(demo.surface_mat.get_shader_parameter("shore_blend_width_m"),
			demo.solver.shore_solver.config.surface_blend_width_m()), "island visual: renderer and query blend widths differ")
		_check(demo.surface_mat.get_shader_parameter("shore_depth_blend_m").is_equal_approx(
			demo.solver.shore_solver.config.surface_depth_blend_m()), "island visual: renderer and query depth blends differ")
		var depth: float = demo.solver.water_depth
		demo.set_frozen(true)
		var frozen_time: float = demo._sim_time
		await _boot_frames(4)
		_check(is_equal_approx(demo._sim_time, frozen_time), "island visual: freeze advanced the wave clock")
		for index in 4:
			demo.apply_preset(index)
			var preset: OceanPreset = demo.PRESETS[index]
			_check(is_equal_approx(demo.solver.wind_speed, preset.wind_speed_mps)
				and is_equal_approx(demo.solver.height_gain, preset.height_gain), "island visual: preset amplitude or wind changed")
		demo.set_capture_wind_direction(PI * 0.25)
		await _boot_frames(4)
		_check(demo.surface_mat.get_shader_parameter("wind_direction").is_equal_approx(Vector2.ONE.normalized()),
			"island visual: direction change did not reach the animated crest")
		demo.set_quality_profile(0)
		for frame in 360:
			await process_frame
			if demo.solver.initialized and demo.texture_bound:
				break
		_check(demo.texture_bound and demo.solver.shore_solver.config.visual_breakers_enabled
			and demo.solver.shore_solver.config.selected_resolution_cells == 128, "island visual: Low quality rebuild lost the hybrid coast")
		demo.set_quality_profile(1)
		for frame in 360:
			await process_frame
			if demo.solver.initialized and demo.texture_bound:
				break
		_check(demo.texture_bound and demo.solver.shore_solver.config.selected_resolution_cells == 160,
			"island visual: Medium quality rebuild failed")
		demo.set_frozen(false)
		await _boot_frames(4)
		_check(demo._sim_time > frozen_time and is_equal_approx(demo.time_scale, 1.0), "island visual: resume did not advance real time")
		demo.set_frozen(true)
		demo.set_capture_foam(false)
		_check(demo.surface_mat.get_shader_parameter("foam_feedback_enabled") == false,
			"island visual: foam toggle did not reach the renderer")
		demo.set_scene_mode(0, false)
		for frame in 360:
			await process_frame
			if demo.solver.initialized and demo.texture_bound:
				break
		_check(not demo.solver.shore_enabled and demo.island == null
			and demo.surface_mat.get_shader_parameter("shore_visual_breakers_enabled") == false
			and is_equal_approx(demo.solver.water_depth, depth), "island visual: ocean roundtrip changed depth or retained the fold")
		_check(demo.solver.foam_near_size == 1024, "island visual: ocean roundtrip retained the island foam budget")
		_check(not demo.solver.shore_solver.get_texture_rid().is_valid()
			and not demo.solver.shore_solver.get_foam_texture_rid().is_valid()
			and not demo.solver.shore_solver.get_breaker_texture_rid().is_valid()
			and not demo.solver.shore_solver.get_contact_texture_rid().is_valid()
			and demo.solver.shore_solver.estimate_vram_bytes() == 0, "island visual: shoreline resources survived scene exit")
		print("OCEAN ISLAND VISUAL boot=restored quality=Medium propagation=shallow_water crest=fft_surface foam_transport=fft_velocity presets=checked direction=checked quality_switch=checked freeze_resume=checked foam_toggle=checked roundtrip=checked offshore_depth_m=%.3f" % depth)
	demo.queue_free()
	await _boot_frames(3)
	manager.set_setting("ocean_scene_mode", old_scene)
	manager.set_setting("ocean_quality_profile", old_quality)
	_check(root.screen_space_aa == old_screen_space_aa,
		"island visual: shoreline antialiasing survived scene exit")
	_finish("ocean_island_visual")


func _run_ocean_apic_surface_rest() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_shore_rest(self, _check, "apic", 180.0, true, _extra.has("amount_surface=1"), 2 if _extra.has("amount_order=2") else 1)
	_finish("ocean_apic_surface_rest")


func _run_ocean_apic_surface_breaker() -> void:
	await _boot_frames(2)
	var grid_dx := 0.12 if _extra.has("grid=0.12") else 0.0
	var substeps := 1 if _extra.has("substeps=1") else (3 if _extra.has("substeps=3") else 0)
	var duration_s := 1.0 / 60.0 if _extra.has("first_tick=1") else 8.0
	if _extra.has("duration=3"):
		duration_s = 3.0
	elif _extra.has("duration=6.5"):
		duration_s = 6.5
	var amount_tracking := _extra.has("amount=1")
	var amount_surface := _extra.has("amount_surface=1")
	await OceanBreakerProbe._run_resolution(self, _check, 0.12, "apic", 0, grid_dx, 180.0, true, duration_s, substeps, 1, amount_tracking or amount_surface, amount_surface, 2 if _extra.has("amount_order=2") else 1, 128 if _extra.has("distance_iterations=128") else 64, _extra.has("geometric=1"), 1.0 if _extra.has("flip=1") else (0.5 if _extra.has("flip=0.5") else 0.0), 512 if _extra.has("pressure_iterations=512") else 256, not _extra.has("rock=0"), 1.0 / 15.0 if _extra.has("slope=15") else 1.0 / 8.0, _extra.has("projection_energy=1"))
	print("BREAKER ACCEPTANCE candidate=apic scope=free_surface_boundary physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_apic_surface_breaker")


func _run_ocean_apic_surface_volume() -> void:
	await _boot_frames(2)
	var substeps := 1 if _extra.has("substeps=1") else (3 if _extra.has("substeps=3") else 0)
	var ticks_per_draw := 8 if _extra.has("batch=8") else 1
	var amount_surface := _extra.has("amount_surface=1")
	await OceanBreakerProbe._run_resolution(self, _check, 0.12, "apic", 0, 0.0, 180.0, true, 30.0, substeps, ticks_per_draw, amount_surface, amount_surface, 2 if _extra.has("amount_order=2") else 1, 64, _extra.has("geometric=1"), 1.0 if _extra.has("flip=1") else 0.0, 256, true, 1.0 / 8.0, _extra.has("projection_energy=1"))
	_finish("ocean_apic_surface_volume")


func _run_ocean_apic_surface_timestep() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_timestep(self, _check, true)
	_finish("ocean_apic_surface_timestep")


func _run_ocean_apic_volume_fraction() -> void:
	OceanBreakerProbe.run_apic_volume_fraction_values(_check)
	_finish("ocean_apic_volume_fraction")


func _run_ocean_apic_velocity_support() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_velocity_support(self, _check)
	_finish("ocean_apic_velocity_support")


func _run_ocean_apic_detached_gravity() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_detached_gravity(self, _check)
	_finish("ocean_apic_detached_gravity")


func _run_ocean_apic_thin_film() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_thin_film(self, _check)
	_finish("ocean_apic_thin_film")


func _run_ocean_apic_film_current() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_film_current(self, _check)
	_finish("ocean_apic_film_current")


func _run_ocean_apic_solid_geometry() -> void:
	OceanBreakerProbe.run_apic_solid_geometry(_check)
	_finish("ocean_apic_solid_geometry")


func _run_ocean_apic_dry_cut_cell() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_dry_cut_cell(self, _check)
	await OceanBreakerProbe.run_apic_dry_face_transport(self, _check)
	_finish("ocean_apic_dry_cut_cell")


func _run_ocean_breaker_seed() -> void:
	OceanBreakerProbe.run_seed_geometry(_check)
	_finish("ocean_breaker_seed")


func _run_ocean_apic_shore_rest() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_shore_rest(self, _check)
	_finish("ocean_apic_shore_rest")


func _run_ocean_sph_shore_rest() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_shore_rest(self, _check, "sph", 400.0)
	_finish("ocean_sph_shore_rest")


func _run_ocean_apic_grid() -> void:
	await _boot_frames(2)
	for grid_cell_size_m in [0.18, 0.12]:
		await OceanBreakerProbe._run_resolution(self, _check, 0.12, "apic", 0, grid_cell_size_m)
	print("BREAKER ACCEPTANCE candidate=apic scope=grid_resolution physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_apic_grid")


func _run_ocean_apic_dense() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe._run_resolution(self, _check, 0.06, "apic", 0, 0.12)
	print("BREAKER ACCEPTANCE candidate=apic scope=dense_particle_sampling physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_apic_dense")


func _run_ocean_apic_transfer() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_transfer(self, _check)
	_finish("ocean_apic_transfer")


func _run_ocean_apic_timestep() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_timestep(self, _check)
	_finish("ocean_apic_timestep")


func _run_ocean_apic_wall_slip() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_apic_wall_slip(self, _check)
	_finish("ocean_apic_wall_slip")


func _run_ocean_breaker_incident() -> void:
	await _boot_frames(2)
	OceanBreakerProbe.run_incident_cpu(_check)
	_finish("ocean_breaker_incident")


func _run_ocean_sph_prediction() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_sph_prediction(self, _check)
	_finish("ocean_sph_prediction")


func _run_ocean_sph_density_snapshot() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run_sph_density_snapshot(self, _check)
	_finish("ocean_sph_density_snapshot")


func _run_ocean_apic_scatter() -> void:
	await _boot_frames(2)
	await OceanBreakerProbe.run(self, _check, "apic", 1)
	print("BREAKER ACCEPTANCE candidate=apic p2g_transfer=1 scope=numerical_particle_state physical_overturning=unavailable rendered_performance=unavailable branch_selected=false")
	_finish("ocean_apic_scatter")


func _run_planet_water() -> void:
	await _boot_frames(2)
	root.size = Vector2i(1280, 720)
	var demo: Node = load("res://scenes/planet_demo.tscn").instantiate()
	root.add_child(demo)
	if not await _planet_water_wait(demo, false):
		demo.queue_free()
		_finish("planet_water")
		return
	var fluid: PlanetFluid = demo._fluid
	fluid.set_gravity(3.4)
	fluid.set_viscosity(0.24)
	fluid.set_slip(0.96)
	fluid.set_pour_fraction(FluidSystem.PLANET_MAX_POUR_FRACTION)
	for button: Button in demo.menu._actions:
		if button.tooltip_text == "Fluid":
			button.button_pressed = true
	if not await _planet_water_wait(demo, true):
		demo.queue_free()
		_finish("planet_water")
		return
	var system: FluidSystem = fluid._system
	var solver := system.sph_solver
	var cell: float = demo.generator.generated_world_size / system.planet_grid_dim
	_check(solver.grid_dims == system.config.grid_dims and
		solver.grid_origin.is_equal_approx(system.config.domain_origin) and
		is_equal_approx(solver.cell_size, cell) and is_equal_approx(solver.h, cell) and
		is_equal_approx(solver.spacing, cell * 0.48), "planet_water: init overwrote planet grid")
	_check(solver.particle_count == 65536 and solver.active_count == 0,
		"planet_water: capacity changed or dry boot activated particles")
	var renderer_id := system.renderer.get_instance_id()
	demo._menu_builder._pour_action.pressed.emit()
	_check(not fluid.can_pour(), "planet_water: pour cooldown was ignored")
	await _boot_frames(120)
	var stats := await _planet_water_stats(system)
	_check(int(stats.get("particles", 0)) == 32768 and int(stats.get("invalid", -1)) == 0
		and int(stats.get("outside", -1)) == 0, "planet_water: maximum pour invalid or outside domain")
	print("PLANET WATER maximum=%s" % stats)
	demo.sun_yaw = 145.0
	await _boot_frames(2)
	var light_direction: Vector3 = system.renderer.composite_material().get_shader_parameter("sun_direction")
	_check(light_direction.distance_to(-demo.sun_light.global_basis.z) < 0.001,
		"planet_water: water highlight did not follow Sun")
	for button: Button in demo.menu._debug_strip.get_children():
		if button.tooltip_text == "Atmosphere":
			button.button_pressed = false
	_check(not demo.atmosphere_quad.visible and
		not bool(system.renderer.composite_material().get_shader_parameter("atmosphere_enabled")),
		"planet_water: atmosphere toggle did not reach water composite")
	demo._menu_builder._reset_action.pressed.emit()
	_check(not fluid.is_ready(), "planet_water: Reset did not gate reinitialization")
	await _planet_water_wait(demo, true)
	_check(system.renderer.get_instance_id() == renderer_id and solver.active_count == 0 and
		is_equal_approx(system.pour_fraction, 0.5) and is_equal_approx(solver.planet_gravity, 3.4) and
		is_equal_approx(solver.viscosity_strength, 0.24) and is_equal_approx(solver.collision_damping, 0.96),
		"planet_water: Reset replaced renderer or lost tuning")
	demo._menu_builder._pour_action.pressed.emit()
	var pour_deadline := Time.get_ticks_msec() + 1000
	while not fluid.can_pour() and Time.get_ticks_msec() < pour_deadline:
		await process_frame
	demo._menu_builder._pour_action.pressed.emit()
	await _boot_frames(120)
	stats = await _planet_water_stats(system)
	_check(solver.active_count == 65536 and int(stats.get("invalid", -1)) == 0 and
		int(stats.get("outside", -1)) == 0, "planet_water: closely spaced pours failed at full capacity")
	print("PLANET WATER full_capacity=%s" % stats)
	demo.orbit_cam.target = Vector3(0, 1000, 0)
	await _boot_frames(2)
	_check(not demo.aim_point().is_finite() and demo._menu_builder._pour_action.disabled,
		"planet_water: missed aim still permits pouring")
	demo.orbit_cam.target = Vector3.ZERO
	await _boot_frames(2)
	demo.set_fluid_enabled(false)
	_check(fluid._system == null, "planet_water: disabling water kept solver alive")
	demo.generator.radius = 18.0
	demo.start_generation()
	demo.generator.radius = 30.0
	await _planet_water_wait(demo, false)
	_check(is_equal_approx(demo.generator.generated_radius, 18.0),
		"planet_water: queued generation read live shape parameters")
	demo._menu_builder._sliders["radius"].value = 25.0
	demo.generator.resolution = 96
	demo.queue_regen()
	demo.set_fluid_enabled(true)
	_check(fluid._system == null, "planet_water: enabled water before field publication")
	await _planet_water_wait(demo, true)
	_check(is_equal_approx(demo.generator.generated_radius, 25.0) and
		demo.generator.generated_resolution == 96 and
		is_equal_approx(fluid._system.planet_radius, 25.0),
		"planet_water: debounced latest shape/resolution or published metadata wrong")
	demo.generator.iso_level = 100.0
	demo.queue_regen()
	await _planet_water_wait(demo, false)
	_check(demo.planet_mesh.mesh == null and fluid._system == null and
		demo._menu_builder._pour_action.disabled, "planet_water: empty field retained old surface or pouring")
	demo.generator.iso_level = 0.0
	demo.apply_preset(0)
	await _planet_water_wait(demo, true)
	system = fluid._system
	fluid.set_gravity(2.6)
	fluid.set_viscosity(0.14)
	fluid.set_slip(0.999)
	fluid.set_pour_fraction(0.15)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for hashed in [false, true]:
		system.set_process(true)
		system.sph_solver.hash_grid_enabled = hashed
		fluid.reset()
		await _planet_water_wait(demo, true)
		system.set_process(false)
		system.set_profiling(true)
		fluid.pour_at(demo.aim_point())
		var frame_times := PackedFloat64Array()
		var gpu_times := PackedFloat64Array()
		for frame in 240:
			var started := Time.get_ticks_usec()
			system._process(1.0 / 60.0)
			await process_frame
			if frame >= 120:
				frame_times.append(float(Time.get_ticks_usec() - started) / 1000.0)
				var timings := system.get_timings()
				if timings.has("total"):
					gpu_times.append(timings.total)
		frame_times.sort()
		gpu_times.sort()
		stats = await _planet_water_stats(system)
		_check(int(stats.get("invalid", -1)) == 0 and int(stats.get("outside", -1)) == 0
			and int(stats.get("particles", 0)) == 9830 and not gpu_times.is_empty(),
			"planet_water: benchmark lost particles, validation, or GPU timings")
		print("PLANET WATER benchmark hash=%s capacity=%d cells=%d frame_median_ms=%.3f gpu_median_ms=%.3f stats=%s" % [
			hashed, system.sph_solver.particle_count, system.sph_solver._grid_cell_count(),
			frame_times[frame_times.size() / 2],
			gpu_times[gpu_times.size() / 2] if not gpu_times.is_empty() else -1.0, stats])
	Engine.max_fps = 60
	demo.apply_preset(4)
	await _planet_water_wait(demo, true)
	system = fluid._system
	for button: Button in demo.menu._debug_strip.get_children():
		if button.tooltip_text == "Atmosphere":
			button.button_pressed = true
	_check(system.planet_field == demo.generator.density_texture()
		and bool(system.renderer.composite_material().get_shader_parameter("interior_enabled")),
		"planet_water: exposed core did not share its field and atmosphere with water")
	var water_air: Vector3 = system.renderer.composite_material().get_shader_parameter("scattering_coefficients")
	var scene_air: Vector3 = demo.view.atmosphere.get_shader_parameter("scattering_coefficients")
	_check(water_air.is_equal_approx(scene_air)
			and water_air.is_equal_approx(demo._atmosphere.params()["scattering_coefficients"])
			and demo._atmosphere.fragmentation_strength > 0.9,
		"planet_water: water retained a different atmosphere around the fragmented shell")
	demo.orbit_cam.yaw = 11.3
	demo.orbit_cam.pitch = -8.4
	await _boot_frames(2)
	demo._menu_builder._pour_action.pressed.emit()
	await _boot_frames(300)
	stats = await _planet_water_stats(system)
	_check(int(stats.get("particles", 0)) == 9830 and int(stats.get("invalid", -1)) == 0
		and int(stats.get("outside", -1)) == 0,
		"planet_water: exposed-core pour invalid or outside its domain")
	print("PLANET WATER exposed_core=%s" % stats)
	demo.queue_free()
	await _boot_frames(2)
	_finish("planet_water")


func _planet_water_wait(demo: Node, water: bool) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if demo.capture_ready() and (not water or demo._fluid.is_ready()):
			return true
		await process_frame
	_check(false, "planet_water: runtime did not become ready (water=%s)" % water)
	return false


func _planet_water_stats(system: FluidSystem) -> Dictionary:
	var result := {}
	system.request_validation_stats(result)
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	return result


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
	var push_constants := PackedInt32Array([count]).to_byte_array()
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


func _run_planet_shape() -> void:
	await _boot_frames(2)
	var settings := root.get_node("/root/UserSettings")
	var manager := root.get_node("/root/GameManager")
	var section := "sim.planet_demo"
	var saved: Dictionary = {}
	if settings._config.has_section(section):
		for key in settings._config.get_section_keys(section):
			saved[key] = settings._config.get_value(section, key)
	var quality_saved: Variant = manager.get_setting("planet_quality_profile", 0)
	manager.current_demo = "planet_demo"
	manager.set_setting("planet_quality_profile", PlanetQualityProfile.Tier.LOW)
	settings.clear_sim("planet_demo")
	settings.set_sim_value("planet_demo", "Shape/Preset", 4)
	settings.set_sim_value("planet_demo", "Shape/Seed", 0)
	var demo := (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	var config: PlanetConfig = demo.generator.config
	_check(demo.capture_ready() and demo.menu._entries["Shape/Preset"].node.selected == 4
			and demo.generator.generated_error == "",
		"planet_shape: Exposed Core did not boot and generate through the scene path")
	_check(config.reference_radius_m >= 4.0 and config.reference_radius_m <= 120.0
			and config.opening_count >= 1 and config.opening_count <= 8
			and config.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL
			and config.opening_count == 7 and is_equal_approx(config.fragment_separation_ratio, 0.18)
			and demo.generator.generated_terrain_style == PlanetConfig.TerrainStyle.CONTINENTAL
			and demo.generator.generated_opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL
			and is_equal_approx(float(demo.view.surface.get_shader_parameter("core_fraction")),
				config.core_fraction)
			and float(demo.view.surface.get_shader_parameter("core_emission")) > 0.0,
		"planet_shape: preset config or core material values were not initialized")
	_check(bool(demo.view.surface.get_shader_parameter("interior_enabled"))
			and bool(demo.view.atmosphere.get_shader_parameter("interior_enabled"))
			and demo.view.environment.glow_enabled,
		"planet_shape: interior and atmosphere effects were not enabled by runtime boot")
	var intact_air: Vector3 = Vector3(
		pow(400.0 / demo._atmosphere.wavelengths_nm.x, 4.0),
		pow(400.0 / demo._atmosphere.wavelengths_nm.y, 4.0),
		pow(400.0 / demo._atmosphere.wavelengths_nm.z, 4.0)
	) * demo._atmosphere.scattering_strength
	var broken_air: Vector3 = demo.view.atmosphere.get_shader_parameter("scattering_coefficients")
	_check(broken_air.length() < intact_air.length() * 0.06
			and is_equal_approx(demo._atmosphere.fragmentation_strength, config.opening_strength),
		"planet_shape: shattered shell boot retained a dense spherical atmosphere")
	var shell_field := await _planet_shape_read(demo.generator)
	var shape_data: PackedFloat32Array = demo.generator._request.shape_data.to_float32_array()
	var sites: Array[Vector3] = []
	for site_index in config.opening_count:
		var offset := (2 + site_index * 2) * 4
		sites.append(Vector3(shape_data[offset], shape_data[offset + 1],
			shape_data[offset + 2]).normalized())
	var shell_radius: float = demo.generator.generated_radius
	_check(_planet_field_at(shell_field, demo.generator, Vector3.ZERO) < 0.0
			and _planet_field_at(shell_field, demo.generator, sites[0] * shell_radius * 0.65) > 0.0,
		"planet_shape: shattered shell did not preserve the core and open its forward cavity")
	var seam_air_count := 0
	for first in sites.size():
		for second in range(first + 1, sites.size()):
			var seam_dir := (sites[first] + sites[second]).normalized()
			if seam_dir.dot(sites[0]) > 0.55:
				continue
			var first_dot := seam_dir.dot(sites[first])
			var second_dot := seam_dir.dot(sites[second])
			var top_dot := -INF
			var next_dot := -INF
			var top_index := -1
			var next_index := -1
			for site_index in sites.size():
				var score := seam_dir.dot(sites[site_index])
				if score > top_dot:
					next_dot = top_dot
					next_index = top_index
					top_dot = score
					top_index = site_index
				elif score > next_dot:
					next_dot = score
					next_index = site_index
			if [top_index, next_index].has(first) and [top_index, next_index].has(second) \
					and is_equal_approx(first_dot, second_dot):
				if _planet_field_at(shell_field, demo.generator, seam_dir * shell_radius * 0.85) > 0.0:
					seam_air_count += 1
					if seam_air_count >= 2:
						break
		if seam_air_count >= 2:
			break
	_check(seam_air_count >= 2,
		"planet_shape: shell regions had no separated side/back seams from their site axes")
	var belt_axis := Vector3(shape_data[113], shape_data[114], shape_data[115]).normalized()
	var belt_tangent := belt_axis.cross(Vector3.FORWARD).normalized()
	var belt_bitangent := belt_axis.cross(belt_tangent).normalized()
	for index in 16:
		var angle := TAU * float(index) / 16.0
		var direction := belt_tangent * cos(angle) + belt_bitangent * sin(angle)
		_check(_planet_field_at(shell_field, demo.generator, direction * shell_radius * 0.85) > 0.0,
			"planet_shape: shattered shell belt did not remain open around the entire planet")
	var sliders: Dictionary = demo._menu_builder._sliders
	var structure: OptionButton = demo._menu_builder._options["opening_style"]
	structure.select(PlanetConfig.OpeningStyle.CAVITIES)
	structure.emit_signal("item_selected", PlanetConfig.OpeningStyle.CAVITIES)
	demo._menu_builder._sliders["opening_count"].value = 3.0
	await _planet_shape_scene_wait(demo, 30000)
	_check(demo.generator.generated_opening_style == PlanetConfig.OpeningStyle.CAVITIES,
		"planet_shape: legacy capsule checks did not switch to CAVITIES mode")
	var cavity_air: Vector3 = demo.view.atmosphere.get_shader_parameter("scattering_coefficients")
	_check(cavity_air.is_equal_approx(intact_air)
			and is_zero_approx(demo._atmosphere.fragmentation_strength),
		"planet_shape: cavity mode did not restore its atmosphere")
	sliders["radius"].value = 23.0
	_check(is_equal_approx(demo.generator.radius, 23.0),
		"planet_shape: radius slider did not reach generator")
	for entry in [["seed", "seed", 24680], ["opening_strength", "opening_strength", 0.9],
			["core_fraction", "core_fraction", 0.3], ["continent_strength", "continent_strength", 0.35],
			["mountain_strength", "mountain_strength", 1.2], ["warp_strength", "warp_strength", 0.4],
			["opening_count", "opening_count", 5]]:
		var slider: HSlider = sliders[entry[0]]
		slider.value = float(entry[2])
		_check(is_equal_approx(float(config.get(entry[1])), slider.value),
			"planet_shape: %s slider did not reach generator config" % entry[0])
	sliders["core_emission"].value = 4.0
	_check(is_equal_approx(float(demo.get("core_emission")), 4.0)
			and is_equal_approx(float(demo.view.surface.get_shader_parameter("core_emission")), 4.0),
		"planet_shape: core emission slider did not reach the surface material")
	sliders["seed"].value = 0.0
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(is_equal_approx(float(demo.view.surface.get_shader_parameter("core_fraction")),
		config.core_fraction), "planet_shape: core fraction slider did not reach surface material")
	for entry in [["seed", 0.0], ["opening_strength", 0.8], ["opening_count", 3.0],
			["continent_strength", 0.3], ["mountain_strength", 1.1], ["warp_strength", 0.25],
			["core_fraction", 0.32]]:
		sliders[entry[0]].value = entry[1]
	demo.queue_regen()
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	var fields: Array[PackedFloat32Array] = []
	var generation_ms: Array[float] = []
	var triangles_64 := 0
	for radius in [4.0, 23.0, 120.0]:
		sliders["radius"].value = radius
		demo.generator.resolution = 64
		demo.queue_regen()
		await _planet_shape_scene_wait(demo, 30000)
		_check(demo.generator.generated_error == "" and demo.generator.generated_radius == radius,
			"planet_shape: generation error or wrong radius at %.1f" % radius)
		generation_ms.append(demo.generator.last_generate_ms)
		fields.append(await _planet_shape_read(demo.generator))
		if radius == 23.0:
			triangles_64 = demo.generator.triangle_count
			var mesh: ArrayMesh = demo.planet_mesh.mesh
			var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
			var bounds := AABB()
			for i in vertices.size():
				_check(vertices[i].is_finite() and normals[i].is_finite(),
					"planet_shape: non-finite mesh vertex or normal")
				if i == 0:
					bounds = AABB(vertices[i], Vector3.ZERO)
				else:
					bounds = bounds.expand(vertices[i])
			_check(vertices.size() > 0 and bounds.position.x >= -demo.generator.generated_world_size * 0.5
					and bounds.position.y >= -demo.generator.generated_world_size * 0.5
					and bounds.position.z >= -demo.generator.generated_world_size * 0.5
					and bounds.end.x <= demo.generator.generated_world_size * 0.5
					and bounds.end.y <= demo.generator.generated_world_size * 0.5
					and bounds.end.z <= demo.generator.generated_world_size * 0.5,
				"planet_shape: mesh bounds exceeded generated world size")
	var max_scale_error := 0.0
	for i in fields[0].size():
		var base := fields[0][i] / 4.0
		max_scale_error = maxf(max_scale_error, absf(base - fields[1][i] / 23.0))
		max_scale_error = maxf(max_scale_error, absf(base - fields[2][i] / 120.0))
	_check(max_scale_error <= 0.0001,
		"planet_shape: normalized density changed with radius (max error %.7f)" % max_scale_error)
	var same_seed := await _planet_shape_read_after_regen(demo, 23.0, 64, 0, 0.8)
	var repeat_delta := 0.0
	for i in fields[1].size():
		repeat_delta = maxf(repeat_delta, absf(fields[1][i] - same_seed[i]))
	_check(repeat_delta == 0.0, "planet_shape: same seed changed the density field")
	var different_seed := await _planet_shape_read_after_regen(demo, 23.0, 64, 1, 0.8)
	var seed_delta := 0.0
	for i in fields[1].size():
		seed_delta = maxf(seed_delta, absf(fields[1][i] - different_seed[i]))
	_check(seed_delta > 0.0001, "planet_shape: changing seed did not change the density field")
	var closed := await _planet_shape_read_after_regen(demo, 23.0, 64, 0, 0.0)
	var center := int(64 / 2) * 64 * 64 + int(64 / 2) * 64 + int(64 / 2)
	var opening_pos := Vector3(0.18, 0.34, 0.93).normalized() * 0.65 * 23.0
	var box: float = demo.generator.generated_world_size
	var coord := Vector3i(roundi((opening_pos.x / box + 0.5) * 63.0),
		roundi((opening_pos.y / box + 0.5) * 63.0),
		roundi((opening_pos.z / box + 0.5) * 63.0))
	var opening_index := coord.z * 64 * 64 + coord.y * 64 + coord.x
	_check(closed[center] < 0.0 and closed[opening_index] < 0.0,
		"planet_shape: protected core or closed opening was not solid")
	var opened := await _planet_shape_read_after_regen(demo, 23.0, 64, 0, 0.8)
	_check(opened[center] < 0.0 and opened[opening_index] > 0.0,
		"planet_shape: opening did not expose air through the shell while preserving the core")
	demo.generator.resolution = 96
	var triangles_96 := 0
	var ms96 := 0.0
	await _planet_shape_read_after_regen(demo, 23.0, 96, 0, 0.8)
	triangles_96 = demo.generator.triangle_count
	ms96 = demo.generator.last_generate_ms
	_check(demo.generator.generated_resolution == 96 and demo.generator.last_generate_ms > 0.0,
		"planet_shape: 96³ generation did not complete")
	config.triangle_budget_per_cell = 0.1
	demo.generator.resolution = 64
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	_check(not demo.generator.generated_error.is_empty() and demo.generator.triangle_count == 0
			and demo.planet_mesh.mesh == null,
		"planet_shape: triangle overflow returned a clipped or stale surface")
	config.triangle_budget_per_cell = 20.0
	demo.generator.resolution = 64
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	_check(demo.generator.generated_error.is_empty() and demo.generator.triangle_count > 0
			and demo.planet_mesh.mesh != null,
		"planet_shape: valid generation did not recover after overflow")
	settings.set_sim_value("planet_demo", "Shape/Seed", 123)
	settings.set_sim_value("planet_demo", "Interior/Structure", PlanetConfig.OpeningStyle.SHATTERED_SHELL)
	settings.set_sim_value("planet_demo", "Terrain detail/Terrain", PlanetConfig.TerrainStyle.CONTINENTAL)
	sliders["seed"].value = 123.0
	await _boot_frames(2)
	demo.queue_free()
	await _boot_frames(3)
	demo = (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready() and demo.menu._entries["Shape/Preset"].node.selected == 4
			and demo.generator.config.seed == 123
			and demo.generator.config.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL
			and demo.generator.generated_opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL,
		"planet_shape: Exposed Core seed/preset did not persist through runtime boot")
	demo.queue_free()
	await _boot_frames(3)
	settings.clear_sim("planet_demo")
	for key in saved:
		settings.set_sim_value("planet_demo", key, saved[key])
	settings._flush()
	manager.set_setting("planet_quality_profile", quality_saved)
	print("PLANET SHAPE scaled=4,23,120 resolution=64,96 max_error=%.8f ms64=%d,%d,%d ms96=%.0f triangles64=%d triangles96=%d" % [
		max_scale_error, generation_ms[0], generation_ms[1], generation_ms[2], ms96,
		triangles_64, triangles_96])
	_finish("planet_shape")


func _planet_shape_scene_wait(demo: Node, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not demo.capture_ready() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(demo.capture_ready(), "planet_shape: generation timed out")


func _planet_shape_read(generator: PlanetGenerator) -> PackedFloat32Array:
	var result := {}
	RenderingServer.call_on_render_thread(func():
		result["field"] = generator._rd.buffer_get_data(generator._density_buf).to_float32_array()
		result["done"] = true
	)
	var deadline := Time.get_ticks_msec() + 10000
	while not result.get("done", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(result.get("done", false), "planet_shape: density readback timed out")
	return result.get("field", PackedFloat32Array())


func _planet_shape_read_after_regen(demo: Node, radius: float, resolution: int,
		seed: int, opening_strength: float) -> PackedFloat32Array:
	var sliders: Dictionary = demo._menu_builder._sliders
	sliders["radius"].value = radius
	sliders["seed"].value = seed
	sliders["opening_strength"].value = opening_strength
	demo.generator.resolution = resolution
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	_check(demo.generator.generated_error == "",
		"planet_shape: generated_error=%s" % demo.generator.generated_error)
	return await _planet_shape_read(demo.generator)


func _run_planet_controls() -> void:
	await _boot_frames(2)
	var invalid_preset := PlanetPreset.new()
	for entry in [["moon_count", 4], ["ring_outer_ratio", 2.0], ["volcano_size_ratio", 0.0],
			["warp_strength", 2.0], ["lava_glow", 9.0], ["radius_m", 121.0],
			["layer_count", 9], ["noise_strength", -1.0], ["scattering_strength", -1.0]]:
		var original: Variant = invalid_preset.get(entry[0])
		invalid_preset.set(entry[0], entry[1])
		_check(not invalid_preset.validate().is_empty(),
			"planet_controls: preset accepted invalid %s before generation" % entry[0])
		invalid_preset.set(entry[0], original)
	_check(invalid_preset.validate().is_empty(), "planet_controls: default preset failed validation")
	var settings := root.get_node("/root/UserSettings")
	var manager := root.get_node("/root/GameManager")
	var section := "sim.planet_demo"
	var saved: Dictionary = {}
	if settings._config.has_section(section):
		for key in settings._config.get_section_keys(section):
			saved[key] = settings._config.get_value(section, key)
	manager.current_demo = "planet_demo"
	settings.clear_sim("planet_demo")
	var presets: Array[PlanetPreset] = [
		load("res://resources/planet/presets/terra.tres"),
		load("res://resources/planet/presets/verdant.tres"),
		load("res://resources/planet/presets/glacier.tres"),
		load("res://resources/planet/presets/asteroid.tres"),
		load("res://resources/planet/presets/exposed_core.tres"),
		load("res://resources/planet/presets/ringed_world.tres"),
		load("res://resources/planet/presets/volcanic_world.tres"),
	]
	var demo := (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	_check(demo._planet_ready and not demo._fluid.enabled and demo._fluid._system == null,
		"planet_controls: boot did not leave fluid disabled and unallocated")
	var preset_option: OptionButton = demo.menu._entries["Shape/Preset"].node
	_check(preset_option.item_count == presets.size() and preset_option.selected == 0,
		"planet_controls: preset selector did not boot at Terra")
	var layers: HSlider = demo._menu_builder._sliders["layer_count"]
	var detail: HSlider = demo.menu._entries["Performance/Surface detail"].node
	_check(is_equal_approx(layers.step, 1.0) and is_equal_approx(detail.step, 1.0),
		"planet_controls: Layers or Surface detail lost unit steps")
	var sun_button: Button = demo._menu_builder._sun_action
	_check(not sun_button.button_pressed and demo.sun_auto_rotate == false,
		"planet_controls: Sun did not start off")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready(), "planet_controls: initial planet generation did not settle")
	var radius_slider: HSlider = demo._menu_builder._sliders["radius"]
	var layers_slider: HSlider = demo._menu_builder._sliders["layer_count"]
	var lacunarity_slider: HSlider = demo._menu_builder._sliders["lacunarity"]
	radius_slider.value = 25.0
	layers_slider.value = 6.0
	lacunarity_slider.value = 2.5
	for entry in [["persistence", "persistence", 0.57], ["noise_scale", "noise_scale", 3.25],
			["noise_strength", "noise_strength", 2.2], ["noise_offset", "noise_offset", -0.45]]:
		var slider: HSlider = demo._menu_builder._sliders[entry[0]]
		slider.value = entry[2]
		_check(is_equal_approx(float(demo.generator.get(entry[1])), float(slider.value)) and
			slider.get_parent().get_child(2).text == "%.2f" % float(slider.value),
			"planet_controls: %s did not reach generation or label" % entry[0])
	_check(is_equal_approx(demo.generator.radius, 25.0)
			and demo.generator.num_layers == 6
			and is_equal_approx(demo.generator.lacunarity, 2.5)
			and radius_slider.get_parent().get_child(2).text == "25.00"
			and layers_slider.get_parent().get_child(2).text == "6"
			and lacunarity_slider.get_parent().get_child(2).text == "2.50",
		"planet_controls: Shape sliders did not update generator values and labels")
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready(), "planet_controls: batched Shape changes did not settle")
	preset_option.emit_signal("item_selected", 0)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	var steepness: HSlider = demo.menu._entries["Surface/Steepness"].node
	var intensity: HSlider = demo.menu._entries["Atmosphere/Intensity"].node
	var fluid_gravity: HSlider = demo.menu._entries["Fluid/Gravity"].node
	var render_scale: HSlider = demo.menu._entries["Performance/Render scale"].node
	var detail_slider: HSlider = demo.menu._entries["Performance/Surface detail"].node
	steepness.value = 0.61
	intensity.value = 1.1
	fluid_gravity.value = 3.5
	render_scale.value = 0.90
	detail_slider.value = 5.0
	for entry in [["Steep blend", "flat_blend", 0.0], ["Shade power", "shade_pow", 1.65]]:
		var slider: HSlider = demo.menu._entries["Surface/" + entry[0]].node
		slider.value = entry[2]
		_check(is_equal_approx(float(demo.view.surface.get_shader_parameter(entry[1])), slider.value),
			"planet_controls: %s did not reach surface shader" % entry[0])
	demo._menu_builder._sliders["height_bands"].value = 7.4
	_check(is_equal_approx(float(demo.view.surface.get_shader_parameter("height_bands")), 7.4),
		"planet_controls: Height bands did not reach surface shader")
	for param in demo._menu_builder._pickers:
		var picker: ColorPickerButton = demo._menu_builder._pickers[param]
		picker.color = Color(0.2, 0.4, 0.7)
		picker.color_changed.emit(picker.color)
		_check(demo.view.surface.get_shader_parameter(param).is_equal_approx(picker.color),
			"planet_controls: %s did not reach palette shader" % param)
	for entry in [["Falloff", "density_falloff", 4.7], ["Thickness", "shell_fraction", 0.42]]:
		var slider: HSlider = demo.menu._entries["Atmosphere/" + entry[0]].node
		slider.value = entry[2]
		_check(is_equal_approx(float(demo._atmosphere.get(entry[1])), slider.value),
			"planet_controls: %s did not reach atmosphere" % entry[0])
	demo._menu_builder._sliders["scattering"].value = 29.5
	demo._menu_builder._sliders["red_nm"].value = 680
	demo._menu_builder._sliders["green_nm"].value = 555
	demo._menu_builder._sliders["blue_nm"].value = 490
	_check(is_equal_approx(demo._atmosphere.scattering_strength, 29.5) and
		demo._atmosphere.wavelengths_nm.is_equal_approx(Vector3(680, 555, 490)),
		"planet_controls: scattering/wavelength sliders did not reach atmosphere")
	for entry in [["Pour amount", "pour_fraction", 0.24], ["Viscosity", "viscosity", 0.32],
			["Slip", "slip", 0.997]]:
		var slider: HSlider = demo.menu._entries["Fluid/" + entry[0]].node
		slider.value = entry[2]
		_check(is_equal_approx(float(demo._fluid.get(entry[1])), slider.value),
			"planet_controls: %s was lost while water disabled" % entry[0])
	_check(demo.menu._entries["Fluid/Slip"].node.get_parent().get_child(2).text == "0.997",
		"planet_controls: Slip label rounded away its precision")
	_check(is_equal_approx(float(demo.view.surface.get_shader_parameter("flat_threshold")), 0.61)
			and steepness.get_parent().get_child(2).text == "0.61"
			and is_equal_approx(demo._atmosphere.intensity, 1.1)
			and is_equal_approx(float(demo.view.atmosphere.get_shader_parameter("intensity")), 1.1)
			and intensity.get_parent().get_child(2).text == "1.10"
			and is_equal_approx(demo._fluid.gravity, 3.5)
			and fluid_gravity.get_parent().get_child(2).text == "3.50"
			and is_equal_approx(demo.render_scale, 0.90)
			and render_scale.get_parent().get_child(2).text == "0.90"
			and is_equal_approx(float(demo.view.surface.get_shader_parameter("detail_octaves")), 5.0)
			and detail_slider.get_parent().get_child(2).text == "5",
		"planet_controls: Surface, Atmosphere, Fluid, or Performance sliders did not update values/labels")

	var sun_rect := sun_button.get_global_rect()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = sun_rect.position + sun_rect.size * 0.5
	click.global_position = click.position
	click.pressed = true
	Input.parse_input_event(click)
	await _boot_frames(1)
	click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = sun_rect.position + sun_rect.size * 0.5
	click.global_position = click.position
	Input.parse_input_event(click)
	await _boot_frames(2)
	_check(sun_button.button_pressed and demo.sun_auto_rotate,
		"planet_controls: mouse click did not enable Sun rotation")
	var yaw_before: float = demo.sun_yaw
	var sun_dir_before: Vector3 = demo._atmosphere.sun_direction
	await _boot_frames(8)
	_check(demo.sun_yaw > yaw_before and is_equal_approx(
		demo.sun_light.rotation_degrees.y, demo.sun_yaw)
			and not demo._atmosphere.sun_direction.is_equal_approx(sun_dir_before)
			and demo.view.surface.get_shader_parameter("sun_direction").is_equal_approx(
				demo._atmosphere.sun_direction),
		"planet_controls: Sun rotation did not reach the light and surface material")

	var visible_action_index := 0
	for action in demo.menu._actions:
		if action == sun_button:
			break
		if action.visible:
			visible_action_index += 1
	var shortcut_key := KEY_1 + visible_action_index
	var shortcut := InputEventKey.new()
	shortcut.keycode = shortcut_key
	shortcut.physical_keycode = shortcut_key
	shortcut.pressed = true
	Input.parse_input_event(shortcut)
	await _boot_frames(2)
	shortcut.pressed = false
	Input.parse_input_event(shortcut)
	await _boot_frames(1)
	_check(not sun_button.button_pressed and not demo.sun_auto_rotate,
		"planet_controls: numeric shortcut did not stop Sun rotation")
	yaw_before = demo.sun_yaw
	await _boot_frames(6)
	_check(is_equal_approx(demo.sun_yaw, yaw_before),
		"planet_controls: Sun kept rotating after the shortcut disabled it")

	var touch := InputEventScreenTouch.new()
	touch.index = 0
	touch.position = sun_rect.position + sun_rect.size * 0.5
	touch.pressed = true
	Input.parse_input_event(touch)
	await _boot_frames(2)
	touch.pressed = false
	Input.parse_input_event(touch)
	await _boot_frames(2)
	_check(sun_button.button_pressed and demo.sun_auto_rotate,
		"planet_controls: touch input did not enable Sun rotation")
	var yaw_slider: HSlider = demo._menu_builder._sliders["sun_yaw"]
	yaw_slider.value = fmod(demo.sun_yaw + 35.0, 360.0)
	await _boot_frames(2)
	_check(not sun_button.button_pressed and not demo.sun_auto_rotate
			and is_equal_approx(demo.sun_light.rotation_degrees.y, demo.sun_yaw),
		"planet_controls: manual Yaw did not stop auto-rotation and update the light")

	for index in presets.size():
		preset_option.select(index)
		preset_option.emit_signal("item_selected", index)
		var ready_deadline := Time.get_ticks_msec() + 25000
		while Time.get_ticks_msec() < ready_deadline and not demo.capture_ready():
			await process_frame
		var preset: PlanetPreset = presets[index]
		_check(preset_option.selected == index
				and is_equal_approx(demo.generator.num_layers, preset.layer_count)
				and is_equal_approx(layers.value, preset.layer_count)
				and is_equal_approx(float(demo._menu_builder._sliders["scattering"].value),
					preset.scattering_strength)
				and demo._atmosphere.wavelengths_nm.is_equal_approx(preset.wavelengths_nm)
				and is_equal_approx(float(demo._menu_builder._sliders["red_nm"].value),
					preset.wavelengths_nm.x)
				and is_equal_approx(float(demo._menu_builder._sliders["green_nm"].value),
					preset.wavelengths_nm.y)
				and is_equal_approx(float(demo._menu_builder._sliders["blue_nm"].value),
					preset.wavelengths_nm.z),
			"planet_controls: preset %d did not sync shape, scattering, and wavelength controls" % index)
		if index == 5:
			_check(demo.config.ring_enabled and demo.config.moon_count == 3
					and demo._menu_builder._toggles["ring_enabled"].button_pressed
					and int(demo._menu_builder._sliders["moon_count"].value) == 3,
				"planet_controls: Ringed World did not sync rings and moons")
		if index == 6:
			_check(demo.config.volcano_count == 4
					and int(demo._menu_builder._sliders["volcano_count"].value) == 4
					and is_equal_approx(demo._menu_builder._sliders["lava_glow"].value, preset.lava_glow),
				"planet_controls: Volcanic World did not sync volcanoes and lava")
		_check(demo.capture_ready(), "planet_controls: preset %d generation did not settle" % index)
		if index == 3:
			_check(demo.generator.generated_terrain_style == PlanetConfig.TerrainStyle.ASTEROID,
				"planet_controls: Asteroid preset did not publish its terrain style")
		if index == 4:
			_check(demo.generator.generated_opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL,
				"planet_controls: Exposed Core preset did not publish its opening style")

	preset_option.select(2)
	preset_option.emit_signal("item_selected", 2)
	demo.queue_free()
	await _boot_frames(2)
	demo = (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready() and demo.menu._entries["Shape/Preset"].node.selected == 2
			and is_equal_approx(demo.generator.num_layers, presets[2].layer_count),
		"planet_controls: Glacier selection did not persist through the real boot path")
	demo.queue_free()
	await _boot_frames(2)
	settings.clear_sim("planet_demo")
	for key in saved:
		settings.set_sim_value("planet_demo", key, saved[key])
	settings._flush()
	print("PLANET CONTROLS presets=%d input=mouse,key,touch" % presets.size())
	_finish("planet_controls")


func _run_planet_orbits() -> void:
	await _boot_frames(2)
	var settings := root.get_node("/root/UserSettings")
	var manager := root.get_node("/root/GameManager")
	var section := "sim.planet_demo"
	var saved: Dictionary = {}
	if settings._config.has_section(section):
		for key in settings._config.get_section_keys(section):
			saved[key] = settings._config.get_value(section, key)
	var quality_saved: Variant = manager.get_setting("planet_quality_profile", 0)
	manager.current_demo = "planet_demo"
	manager.set_setting("planet_quality_profile", PlanetQualityProfile.Tier.LOW)
	settings.clear_sim("planet_demo")
	settings.set_sim_value("planet_demo", "Shape/Preset", 5)
	var demo := (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	var config: PlanetConfig = demo.generator.config
	_check(demo.capture_ready() and demo.menu._entries["Shape/Preset"].node.selected == 5
			and config.ring_enabled and config.moon_count == 3
			and demo.orbits.ring_root != null and demo.orbits.moon_nodes.size() == 3,
		"planet_orbits: Ringed World did not boot from stored settings into runtime orbit objects")
	var sliders: Dictionary = demo._menu_builder._sliders
	var toggles: Dictionary = demo._menu_builder._toggles
	for key in ["ring_inner_ratio", "ring_outer_ratio", "ring_tilt_deg", "ring_density",
			"ring_rocks", "moon_count", "moon_distance_ratio", "moon_size_ratio",
			"moon_eccentricity", "orbit_speed"]:
		_check(sliders.has(key), "planet_orbits: missing orbit slider %s" % key)
	_check(toggles.has("ring_enabled") and toggles["ring_enabled"].button_pressed,
		"planet_orbits: ring toggle did not reflect boot config")
	var generated_mesh_id: int = demo.planet_mesh.mesh.get_instance_id()
	var triangle_count: int = demo.generator.triangle_count
	for entry in [["ring_inner_ratio", 2.0], ["ring_outer_ratio", 3.4],
			["ring_tilt_deg", 42.0], ["moon_size_ratio", 0.2], ["moon_eccentricity", 0.16]]:
		sliders[entry[0]].value = entry[1]
		_check(is_equal_approx(float(config.get(entry[0])), float(entry[1])),
			"planet_orbits: %s slider did not reach the orbit config" % entry[0])
	sliders["moon_count"].value = 1.0
	_check(demo.orbits.moon_nodes.size() == 1, "planet_orbits: moon count did not remove satellites")
	sliders["moon_count"].value = 3.0
	sliders["ring_density"].value = 0.81
	sliders["moon_distance_ratio"].value = 4.8
	_check(is_equal_approx(config.ring_density, 0.81)
			and is_equal_approx(config.moon_distance_ratio, 4.8)
			and demo.generator.triangle_count == triangle_count
			and demo.planet_mesh.mesh.get_instance_id() == generated_mesh_id,
		"planet_orbits: ring/moon visual controls regenerated the main planet mesh")
	_check(demo.camera.far >= demo.orbit_cam.max_distance + demo.orbits.extent_radius() - 0.01,
		"planet_orbits: camera far plane clips the configured orbit extent")
	var dust_material: ShaderMaterial = demo.orbits.ring_root.get_node("DustBands").material_override
	_check(dust_material.render_priority == 2 and demo.view.atmosphere.render_priority == 0,
		"planet_orbits: ring material does not draw above the atmosphere")
	_check(demo.orbits.ring_rock_count >= 100
			and demo.orbits._rock_instance.multimesh.visible_instance_count == demo.orbits.ring_rock_count,
		"planet_orbits: ring rock count fell below the low-detail budget")

	var first_moon: MeshInstance3D = demo.orbits.moon_nodes[0]
	var moon_mesh: ArrayMesh = first_moon.mesh
	var moon_arrays: Array = moon_mesh.surface_get_arrays(0)
	var moon_vertices: PackedVector3Array = moon_arrays[Mesh.ARRAY_VERTEX]
	var moon_normals: PackedVector3Array = moon_arrays[Mesh.ARRAY_NORMAL]
	var outward_normals := 0
	for index in moon_vertices.size():
		var vertex: Vector3 = moon_vertices[index]
		var normal: Vector3 = moon_normals[index]
		_check(vertex.is_finite() and normal.is_finite(),
			"planet_orbits: moon mesh contains non-finite vertex or normal")
		if vertex.length_squared() > 0.000001 and normal.length_squared() > 0.000001:
			if vertex.normalized().dot(normal.normalized()) > 0.0:
				outward_normals += 1
	_check(moon_vertices.size() > 0 and moon_normals.size() == moon_vertices.size()
			and outward_normals > moon_vertices.size() * 0.95,
		"planet_orbits: moon mesh normals do not face outward")
	var dust_mesh: ArrayMesh = demo.orbits.ring_root.get_node("DustBands").mesh
	var dust_vertices: PackedVector3Array = dust_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var inner_ratio: float = config.ring_inner_ratio
	var outer_ratio: float = config.ring_outer_ratio
	var dust_min_radius := INF
	var dust_max_radius := 0.0
	var ring_inner_m: float = maxf(demo.generator.generated_radius * inner_ratio,
		demo.generator.generated_surface_radius * 1.05)
	var ring_outer_m: float = maxf(demo.generator.generated_radius * outer_ratio,
		ring_inner_m + demo.generator.generated_radius * 0.2)
	for vertex in dust_vertices:
		_check(vertex.is_finite(), "planet_orbits: ring dust mesh contains a non-finite vertex")
		dust_min_radius = minf(dust_min_radius, Vector2(vertex.x, vertex.z).length())
		dust_max_radius = maxf(dust_max_radius, Vector2(vertex.x, vertex.z).length())
	_check(not dust_vertices.is_empty()
			and is_equal_approx(dust_min_radius, ring_inner_m)
			and is_equal_approx(dust_max_radius, ring_outer_m),
		"planet_orbits: ring mesh bounds do not match configured radii")
	var rocks: MultiMesh = demo.orbits._rock_instance.multimesh
	var rock_outermost := 0.0
	for index in rocks.instance_count:
		var transform: Transform3D = rocks.get_instance_transform(index)
		_check(transform.origin.is_finite() and transform.basis.is_finite(),
			"planet_orbits: ring rock has a non-finite transform")
		rock_outermost = maxf(rock_outermost, Vector2(transform.origin.x, transform.origin.z).length())
	_check(rock_outermost > ring_inner_m
			and rock_outermost < ring_outer_m * 1.05,
		"planet_orbits: ring rocks are not distributed through the configured annulus")
	var full_rock_count := PlanetOrbitSystem.LOW_ROCK_COUNT
	sliders["ring_rocks"].value = 1.0
	_check(rocks.instance_count == full_rock_count
			and demo.orbits.ring_rock_count == full_rock_count
			and rocks.visible_instance_count == full_rock_count,
		"planet_orbits: increasing rock density exposed uninitialized instances")
	for index in rocks.instance_count:
		var transform: Transform3D = rocks.get_instance_transform(index)
		var radius := Vector2(transform.origin.x, transform.origin.z).length()
		_check(transform.origin.is_finite() and transform.basis.is_finite()
				and radius > ring_inner_m * 0.9
				and radius < ring_outer_m * 1.05,
			"planet_orbits: expanded rock budget revealed an invalid transform")

	var ring_normal: Vector3 = demo.orbits.ring_root.global_transform.basis.y.normalized()
	for index in demo.orbits.moon_nodes.size():
		var position: Vector3 = demo.orbits.moon_position(index, 2.4)
		_check(position.is_finite() and absf(position.dot(ring_normal)) < 0.001,
			"planet_orbits: moon orbit does not share the ring plane")
	var moon_axis: float = demo.orbits.moon_orbit_radius(0)
	var eccentricity: float = config.moon_eccentricity
	var angular_rate := 0.55 * pow(demo.generator.generated_radius / moon_axis, 1.5)
	var period := TAU / angular_rate
	_check(demo.orbits.moon_position(0, 3.1).is_equal_approx(
		demo.orbits.moon_position(0, 3.1 + period)),
		"planet_orbits: analytic moon position did not repeat after one period")
	var periapsis := INF
	var apoapsis := 0.0
	for sample in 360:
		var distance: float = demo.orbits.moon_position(0, period * float(sample) / 360.0).length()
		periapsis = minf(periapsis, distance)
		apoapsis = maxf(apoapsis, distance)
	_check(absf(periapsis - moon_axis * (1.0 - eccentricity)) < moon_axis * 0.002
			and absf(apoapsis - moon_axis * (1.0 + eccentricity)) < moon_axis * 0.002,
		"planet_orbits: analytic orbit periapsis/apoapsis bounds are wrong")
	_check(periapsis > ring_outer_m,
		"planet_orbits: first moon intersects the ring bounds")
	var previous_axis := 0.0
	for index in demo.orbits.moon_nodes.size():
		var axis: float = demo.orbits.moon_orbit_radius(index)
		var peri: float = axis * (1.0 - eccentricity)
		var moon_radius: float = config.moon_size_ratio * demo.generator.generated_radius
		_check(peri - moon_radius > ring_outer_m and axis > previous_axis,
			"planet_orbits: moon intersects the ring or shares another moon's orbit")
		previous_axis = axis
	var fast_axis: float = demo.orbits.moon_orbit_radius(1)
	_check(fast_axis > moon_axis
			and pow(demo.generator.generated_radius / moon_axis, 1.5)
				> pow(demo.generator.generated_radius / fast_axis, 1.5),
		"planet_orbits: inner moon does not have the faster period")
	var paused_elapsed: float = demo.orbits.elapsed
	var paused_position: Vector3 = demo.orbits.moon_nodes[0].position
	sliders["orbit_speed"].value = 0.0
	_check(is_equal_approx(demo.orbits.elapsed, paused_elapsed)
			and demo.orbits.moon_nodes[0].position.is_equal_approx(paused_position),
		"planet_orbits: changing orbit speed caused a phase jump")
	demo.orbits.advance(1.0)
	_check(is_equal_approx(demo.orbits.elapsed, paused_elapsed)
			and demo.orbits.moon_nodes[0].position.is_equal_approx(paused_position),
		"planet_orbits: speed zero did not pause orbital motion")
	sliders["orbit_speed"].value = 2.0
	var accelerated_elapsed: float = demo.orbits.elapsed
	demo.orbits.advance(0.5)
	_check(is_equal_approx(demo.orbits.elapsed, accelerated_elapsed + 1.0),
		"planet_orbits: orbit speed did not scale elapsed orbital time")
	sliders["orbit_speed"].value = 1.0

	var duplicate := PlanetOrbitSystem.new()
	root.add_child(duplicate)
	duplicate.configure(config, demo.generator.generated_radius,
		demo.generator.generated_surface_radius, 0)
	var duplicate_vertices: PackedVector3Array = duplicate.moon_nodes[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(duplicate_vertices == moon_vertices,
		"planet_orbits: moon mesh changed for the same seed")
	var duplicate_rocks: MultiMesh = duplicate._rock_instance.multimesh
	_check(duplicate_rocks.instance_count == rocks.instance_count,
		"planet_orbits: seeded ring rock budget changed")
	for index in rocks.instance_count:
		_check(rocks.get_instance_transform(index).is_equal_approx(
			duplicate_rocks.get_instance_transform(index)),
			"planet_orbits: ring rock transforms changed for the same seed")
	var changed_seed: PlanetConfig = config.duplicate()
	changed_seed.seed = 17
	duplicate.configure(changed_seed, demo.generator.generated_radius,
		demo.generator.generated_surface_radius, 0)
	_check(duplicate.moon_nodes[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] != moon_vertices
			and not duplicate._rock_instance.multimesh.get_instance_transform(0).is_equal_approx(
				rocks.get_instance_transform(0)),
		"planet_orbits: changing the seed did not change moon or ring geometry")
	duplicate.stop()
	duplicate.stop()
	duplicate.queue_free()

	var normalized_axis: float = moon_axis / demo.generator.generated_radius
	var normalized_position: Vector3 = demo.orbits.moon_position(0, 2.4) / demo.generator.generated_radius
	var normalized_ring_outer: float = dust_max_radius / demo.generator.generated_radius
	var scale_errors := 0.0
	for radius in [4.0, 23.0, 120.0]:
		sliders["radius"].value = radius
		deadline = Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline and not demo.capture_ready():
			await process_frame
		_check(demo.capture_ready() and demo.generator.generated_error == ""
				and is_equal_approx(demo.generator.generated_radius, radius),
			"planet_orbits: radius %.1f did not generate" % radius)
		var scaled_axis: float = demo.orbits.moon_orbit_radius(0) / demo.generator.generated_radius
		var scaled_position: Vector3 = demo.orbits.moon_position(0, 2.4) / demo.generator.generated_radius
		var scaled_ring_inner: float = maxf(demo.generator.generated_radius * config.ring_inner_ratio,
			demo.generator.generated_surface_radius * 1.05)
		var scaled_ring_outer: float = maxf(demo.generator.generated_radius * config.ring_outer_ratio,
			scaled_ring_inner + demo.generator.generated_radius * 0.2) / demo.generator.generated_radius
		scale_errors = maxf(scale_errors, absf(scaled_axis - normalized_axis))
		scale_errors = maxf(scale_errors, scaled_position.distance_to(normalized_position))
		scale_errors = maxf(scale_errors, absf(scaled_ring_outer - normalized_ring_outer))
		var scale_periapsis: float = scaled_axis * (1.0 - eccentricity) * demo.generator.generated_radius
		_check(scale_periapsis > scaled_ring_outer * demo.generator.generated_radius
				and scale_periapsis < demo.generator.generated_surface_radius * 14.0,
			"planet_orbits: ring/moon bounds intersect or escape the orbit view at radius %.1f" % radius)
		_check(demo.camera.far >= demo.orbit_cam.max_distance + demo.orbits.extent_radius() - 0.01,
			"planet_orbits: camera far plane clips scaled orbit bounds")
	_check(scale_errors < 0.002,
		"planet_orbits: normalized orbit/ring bounds changed with scale (%.6f)" % scale_errors)
	var low_detail_vertices: int = demo.orbits.moon_nodes[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	demo.quality.set_tier(PlanetQualityProfile.Tier.MEDIUM)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	_check(demo.capture_ready()
			and demo.generator.generated_resolution == PlanetQualityProfile.RESOLUTION[PlanetQualityProfile.Tier.MEDIUM]
			and demo.orbits.ring_rock_count == 420
			and demo.orbits.moon_nodes[0].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
			> low_detail_vertices,
		"planet_orbits: medium quality did not update orbit geometry budgets")

	toggles["ring_enabled"].button_pressed = false
	_check(demo.orbits.ring_root == null and demo.orbits.ring_rock_count == 0,
		"planet_orbits: disabling rings did not clean up ring objects")
	toggles["ring_enabled"].button_pressed = true
	_check(demo.orbits.ring_root != null and demo.orbits.ring_rock_count > 0,
		"planet_orbits: enabling rings did not restore ring objects")
	var preset_option: OptionButton = demo.menu._entries["Shape/Preset"].node
	preset_option.select(4)
	preset_option.emit_signal("item_selected", 4)
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline and not demo.capture_ready():
		await process_frame
	toggles["ring_enabled"].button_pressed = true
	sliders["moon_count"].value = 3.0
	var exposed_ring_outer: float = maxf(demo.generator.generated_radius * config.ring_outer_ratio,
		maxf(demo.generator.generated_radius * config.ring_inner_ratio,
			demo.generator.generated_surface_radius * 1.05) + demo.generator.generated_radius * 0.2)
	var exposed_moon_periapsis: float = demo.orbits.moon_orbit_radius(0) * (1.0 - config.moon_eccentricity)
	_check(demo.capture_ready() and demo.orbits.ring_root != null
			and demo.orbits.moon_nodes.size() == 3
			and exposed_ring_outer > demo.generator.generated_surface_radius
			and exposed_moon_periapsis > exposed_ring_outer
				+ config.moon_size_ratio * demo.generator.generated_radius
			and demo.camera.far >= demo.orbit_cam.max_distance + demo.orbits.extent_radius() - 0.01,
		"planet_orbits: manually ringed Exposed Core has intersecting or clipped orbit bounds")
	demo.orbits.stop()
	demo.orbits.stop()
	_check(demo.orbits.ring_root == null and demo.orbits.moon_nodes.is_empty()
			and demo.orbits.ring_rock_count == 0 and demo.orbits.get_child_count() == 0,
		"planet_orbits: stop was not idempotent or left orbit objects behind")
	demo.queue_free()
	await _boot_frames(3)
	settings.clear_sim("planet_demo")
	for key in saved:
		settings.set_sim_value("planet_demo", key, saved[key])
	settings._flush()
	manager.set_setting("planet_quality_profile", quality_saved)
	print("PLANET ORBITS rocks=%d moon_vertices=%d scale_error=%.6f period=%.3f" % [
		full_rock_count, moon_vertices.size(), scale_errors, period])
	_finish("planet_orbits")


func _run_planet_volcanoes() -> void:
	await _boot_frames(2)
	var settings := root.get_node("/root/UserSettings")
	var manager := root.get_node("/root/GameManager")
	var section := "sim.planet_demo"
	var saved: Dictionary = {}
	if settings._config.has_section(section):
		for key in settings._config.get_section_keys(section):
			saved[key] = settings._config.get_value(section, key)
	var quality_saved: Variant = manager.get_setting("planet_quality_profile", 0)
	manager.current_demo = "planet_demo"
	manager.set_setting("planet_quality_profile", PlanetQualityProfile.Tier.LOW)
	settings.clear_sim("planet_demo")
	settings.set_sim_value("planet_demo", "Shape/Preset", 6)
	var demo := (load("res://scenes/planet_demo.tscn") as PackedScene).instantiate()
	root.add_child(demo)
	await _planet_shape_scene_wait(demo, 30000)
	var config: PlanetConfig = demo.generator.config
	var generator: PlanetGenerator = demo.generator
	var original_volcano_count: int = config.volcano_count
	_check(demo.menu._entries["Shape/Preset"].node.selected == 6
			and config.volcano_count == 4 and generator.generated_volcanoes.size() == 4
			and demo.eruptions != null and demo.eruptions.active_count >= 0,
		"planet_volcanoes: stored Volcanic World did not boot geometry and eruption runtime")
	_check(demo.view.environment.glow_enabled
			and is_equal_approx(float(demo.view.surface.get_shader_parameter("lava_glow")), config.lava_glow)
			and int(demo.view.surface.get_shader_parameter("volcano_count")) == 4,
		"planet_volcanoes: boot glow or surface volcano uniforms were not initialized")
	var sliders: Dictionary = demo._menu_builder._sliders
	for key in ["volcano_count", "volcano_size_ratio", "volcano_height_ratio",
			"volcano_activity", "lava_glow", "eruption_rate_hz"]:
		_check(sliders.has(key), "planet_volcanoes: missing slider %s" % key)
	for volcano in generator.generated_volcanoes:
		var axis := Vector3(volcano.x, volcano.y, volcano.z)
		_check(axis.is_finite() and absf(axis.length() - 1.0) < 0.002
				and is_finite(volcano.w) and volcano.w > 0.0 and volcano.w < 1.5,
			"planet_volcanoes: descriptor axis or measured base radius is invalid")
	var original_mesh_id: int = demo.planet_mesh.mesh.get_instance_id()
	var original_triangles: int = generator.triangle_count
	sliders["volcano_activity"].value = 0.0
	sliders["lava_glow"].value = 2.0
	sliders["eruption_rate_hz"].value = 0.0
	_check(generator.triangle_count == original_triangles
			and demo.planet_mesh.mesh.get_instance_id() == original_mesh_id
			and is_equal_approx(config.volcano_activity, 0.0)
			and is_equal_approx(config.lava_glow, 2.0)
			and is_equal_approx(config.eruption_rate_hz, 0.0)
			and is_equal_approx(float(demo.view.surface.get_shader_parameter("lava_glow")), 2.0),
		"planet_volcanoes: live eruption controls regenerated terrain or missed material/config")
	var residue_deadline := Time.get_ticks_msec() + 3000
	while demo.eruptions.active_count > 0 and Time.get_ticks_msec() < residue_deadline:
		await process_frame
	_check(demo.eruptions.active_count == 0,
		"planet_volcanoes: inactive eruption fragments did not expire within three seconds")
	var inactive_emitted: int = demo.eruptions.emitted_count
	await _boot_frames(30)
	_check(demo.eruptions.emitted_count == inactive_emitted,
		"planet_volcanoes: activity zero continued to emit particles")
	sliders["volcano_activity"].value = 1.0
	sliders["eruption_rate_hz"].value = 6.0
	var emission_deadline := Time.get_ticks_msec() + 2000
	while demo.eruptions.active_count == 0 and Time.get_ticks_msec() < emission_deadline:
		await process_frame
	_check(demo.eruptions.active_count > 0 or demo.eruptions.emitted_count > 0,
		"planet_volcanoes: positive activity and rate did not restart eruptions")
	sliders["eruption_rate_hz"].value = 0.0
	var emitted_at_zero_rate: int = demo.eruptions.emitted_count
	_check(demo.eruptions.active_count > 0,
		"planet_volcanoes: zero rate removed already emitted fragments")
	await _boot_frames(30)
	_check(demo.eruptions.emitted_count == emitted_at_zero_rate,
		"planet_volcanoes: zero rate still emitted new particles")
	sliders["eruption_rate_hz"].value = 6.0
	var shape_mesh_id: int = demo.planet_mesh.mesh.get_instance_id()
	sliders["volcano_size_ratio"].value = 0.31
	sliders["volcano_height_ratio"].value = 0.20
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	_check(is_equal_approx(generator.generated_volcano_size_ratio, 0.31)
			and is_equal_approx(generator.generated_volcano_height_ratio, 0.20)
			and demo.planet_mesh.mesh.get_instance_id() != shape_mesh_id,
		"planet_volcanoes: shape sliders did not regenerate and publish their settings")
	var field := await _planet_shape_read(generator)
	var volcano := generator.generated_volcanoes[0]
	var volcano_shape_data: PackedFloat32Array = generator._request.shape_data.to_float32_array()
	_check(is_equal_approx(volcano_shape_data[75], PlanetConfig.VOLCANO_FLOOR_FRACTION)
			and is_equal_approx(volcano_shape_data[111], PlanetConfig.VOLCANO_CRATER_BOTTOM_RATIO)
			and is_equal_approx(volcano_shape_data[112], PlanetConfig.VOLCANO_CRATER_TOP_RATIO),
		"planet_volcanoes: density shape data lost crater floor or width constants")
	var axis := Vector3(volcano.x, volcano.y, volcano.z)
	var radius: float = generator.generated_radius
	var floor_ratio: float = volcano.w + generator.generated_volcano_height_ratio * PlanetConfig.VOLCANO_FLOOR_FRACTION
	var floor_air := _planet_field_at(field, generator, axis * radius * (floor_ratio + 0.045))
	var floor_below := _planet_field_at(field, generator, axis * radius * (floor_ratio - 0.035))
	var rim_solid := _planet_field_at(field, generator,
		axis.rotated(Vector3.UP.cross(axis).normalized(), generator.generated_volcano_size_ratio * 0.45)
			* radius * (volcano.w + generator.generated_volcano_height_ratio * 0.25))
	_check(floor_air > 0.0 and floor_below < 0.0 and rim_solid < 0.0,
		"planet_volcanoes: density readback did not contain an open crater floor and solid rim")
	var mesh: ArrayMesh = demo.planet_mesh.mesh
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var mesh_bounds := AABB()
	for index in vertices.size():
		_check(vertices[index].is_finite() and normals[index].is_finite(),
			"planet_volcanoes: generated mesh contains non-finite vertex or normal")
		mesh_bounds = AABB(vertices[index], Vector3.ZERO) if index == 0 else mesh_bounds.expand(vertices[index])
	var half_world := generator.generated_world_size * 0.5
	_check(not vertices.is_empty() and mesh_bounds.position.x >= -half_world
			and mesh_bounds.position.y >= -half_world and mesh_bounds.position.z >= -half_world
			and mesh_bounds.end.x <= half_world and mesh_bounds.end.y <= half_world
			and mesh_bounds.end.z <= half_world,
		"planet_volcanoes: generated mesh exceeded its allocated volume")
	var baseline := field
	var flank_rays: Array[Vector3] = []
	var flank_surfaces: Array[float] = []
	var flank_tangent := axis.cross(Vector3.UP).normalized()
	var flank_bitangent := axis.cross(flank_tangent).normalized()
	for azimuth in 16:
		var angle := TAU * float(azimuth) / 16.0
		var around := flank_tangent * cos(angle) + flank_bitangent * sin(angle)
		var ray := (axis * cos(0.45 * 0.31) + around * sin(0.45 * 0.31)).normalized()
		var top := volcano.w
		for radial_step in 100:
			var radial := volcano.w - 0.1 + float(radial_step) * 0.004
			if _planet_field_at(baseline, generator, ray * radius * radial) < 0.0:
				top = radial
		flank_rays.append(ray)
		flank_surfaces.append(top)
	var no_volcanoes: PackedFloat32Array
	sliders.volcano_count.value = 0
	await _planet_shape_scene_wait(demo, 30000)
	no_volcanoes = await _planet_shape_read(generator)
	var field_delta := 0.0
	for index in baseline.size():
		field_delta = maxf(field_delta, absf(baseline[index] - no_volcanoes[index]))
	_check(field_delta > 0.001 and generator.generated_volcanoes.is_empty(),
		"planet_volcanoes: count zero did not remove volcanoes from the live density field")
	var flank_min := INF
	var flank_max := -INF
	for azimuth in flank_rays.size():
		var top := volcano.w
		for radial_step in 100:
			var radial := volcano.w - 0.1 + float(radial_step) * 0.004
			if _planet_field_at(no_volcanoes, generator, flank_rays[azimuth] * radius * radial) < 0.0:
				top = radial
		var elevation := flank_surfaces[azimuth] - top
		flank_min = minf(flank_min, elevation)
		flank_max = maxf(flank_max, elevation)
	_check(flank_max > 0.025 and flank_max - flank_min > 0.008,
		"planet_volcanoes: generated flanks retained a uniform cone (height=%.4f range=%.4f)" % [flank_max, flank_max - flank_min])
	sliders.volcano_count.value = original_volcano_count
	await _planet_shape_scene_wait(demo, 30000)
	var same_seed: PackedVector4Array = generator.generated_volcanoes.duplicate()
	config.seed += 1
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	var changed_seed := generator.generated_volcanoes
	_check(same_seed.size() > 0 and same_seed.size() == changed_seed.size()
			and Vector3(same_seed[0].x, same_seed[0].y, same_seed[0].z).distance_to(
				Vector3(changed_seed[0].x, changed_seed[0].y, changed_seed[0].z)) > 0.01,
		"planet_volcanoes: changed seed did not change generated volcano descriptors")
	config.seed -= 1
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	var scaled_reference := generator.generated_volcanoes.duplicate()
	var scale_error := 0.0
	for scaled_radius in [4.0, 120.0]:
		sliders.radius.value = scaled_radius
		demo.queue_regen()
		await _planet_shape_scene_wait(demo, 30000)
		_check(generator.generated_volcanoes.size() == scaled_reference.size(),
			"planet_volcanoes: scaling changed descriptor count")
		for index in scaled_reference.size():
			var first := scaled_reference[index]
			var current := generator.generated_volcanoes[index]
			scale_error = maxf(scale_error, Vector3(first.x, first.y, first.z).distance_to(
				Vector3(current.x, current.y, current.z)))
			scale_error = maxf(scale_error, absf(first.w - current.w))
	_check(scale_error < 0.001,
		"planet_volcanoes: normalized descriptors changed with radius (%.6f)" % scale_error)
	demo.quality.set_tier(PlanetQualityProfile.Tier.MEDIUM)
	await _planet_shape_scene_wait(demo, 30000)
	_check(generator.generated_resolution == PlanetQualityProfile.RESOLUTION[PlanetQualityProfile.Tier.MEDIUM]
			and demo.eruptions.capacity == 192,
		"planet_volcanoes: medium quality did not update terrain and eruption budgets")
	var standalone := PlanetEruptionSystem.new()
	root.add_child(standalone)
	standalone.set_process(false)
	var test_config: PlanetConfig = config.duplicate()
	test_config.seed = 127
	standalone.start(test_config, generator.generated_volcanoes, 23.0, 0.32, 0.22,
		PlanetQualityProfile.Tier.LOW)
	for step in 30:
		standalone.advance(1.0 / 30.0)
	var positions := standalone.projectile_positions()
	_check(standalone.active_count <= standalone.capacity and standalone.active_count > 0,
		"planet_volcanoes: isolated eruption simulation missed its budget or emission")
	for position in positions:
		_check(position.is_finite(), "planet_volcanoes: projectile position is non-finite")
	var standalone_repeat := PlanetEruptionSystem.new()
	root.add_child(standalone_repeat)
	standalone_repeat.set_process(false)
	standalone_repeat.start(test_config, generator.generated_volcanoes, 23.0, 0.32, 0.22,
		PlanetQualityProfile.Tier.LOW)
	for step in 30:
		standalone_repeat.advance(1.0 / 30.0)
	_check(standalone_repeat.projectile_positions() == positions,
		"planet_volcanoes: fixed seed and step changed projectile positions")
	standalone_repeat.stop()
	standalone_repeat.queue_free()
	var normalized_positions := PackedVector3Array()
	for position in positions:
		normalized_positions.append(position / 23.0)
	var particle_scale_error := 0.0
	for scaled_radius in [4.0, 120.0]:
		var scaled_system := PlanetEruptionSystem.new()
		root.add_child(scaled_system)
		scaled_system.set_process(false)
		scaled_system.start(test_config, generator.generated_volcanoes, scaled_radius, 0.32, 0.22,
			PlanetQualityProfile.Tier.LOW)
		for step in 30:
			scaled_system.advance(1.0 / 30.0)
		var scaled_positions := scaled_system.projectile_positions()
		_check(scaled_positions.size() == normalized_positions.size(),
			"planet_volcanoes: particle count changed with radius")
		for index in mini(scaled_positions.size(), normalized_positions.size()):
			particle_scale_error = maxf(particle_scale_error,
				(scaled_positions[index] / scaled_radius).distance_to(normalized_positions[index]))
		scaled_system.stop()
		scaled_system.queue_free()
	_check(particle_scale_error < 0.0001,
		"planet_volcanoes: normalized eruption positions changed with radius (%.6f)" % particle_scale_error)
	standalone.stop()
	standalone.stop()
	_check(standalone.active_count == 0,
		"planet_volcanoes: stop did not clear active projectiles idempotently")
	standalone.queue_free()
	demo.generator.iso_level = generator.generated_radius * 5.0
	demo.queue_regen()
	await _planet_shape_scene_wait(demo, 30000)
	_check(demo.planet_mesh.mesh == null and generator.generated_volcanoes.is_empty()
			and demo.eruptions.active_count == 0 and demo.eruptions.capacity == 0
			and int(demo.view.surface.get_shader_parameter("volcano_count")) == 0
			and not demo.view.environment.glow_enabled,
		"planet_volcanoes: empty terrain retained volcano geometry or eruption runtime")
	demo.queue_free()
	await _boot_frames(3)
	settings.clear_sim("planet_demo")
	for key in saved:
		settings.set_sim_value("planet_demo", key, saved[key])
	settings._flush()
	manager.set_setting("planet_quality_profile", quality_saved)
	print("PLANET VOLCANOES count=%d field_delta=%.4f scale_error=%.6f particles=%d flank_range=%.4f" % [
		 same_seed.size(), field_delta, maxf(scale_error, particle_scale_error), positions.size(), flank_max - flank_min])
	_finish("planet_volcanoes")


func _planet_field_at(field: PackedFloat32Array, generator: PlanetGenerator, position: Vector3) -> float:
	var resolution: int = generator.generated_resolution
	var half: float = generator.generated_world_size * 0.5
	var grid := (position / (2.0 * half) + Vector3.ONE * 0.5) * float(resolution - 1)
	var base := Vector3i(floori(grid.x), floori(grid.y), floori(grid.z))
	var fraction := grid - Vector3(base)
	base.x = clampi(base.x, 0, resolution - 2)
	base.y = clampi(base.y, 0, resolution - 2)
	base.z = clampi(base.z, 0, resolution - 2)
	var value := 0.0
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var weight := (fraction.x if dx == 1 else 1.0 - fraction.x)
				weight *= fraction.y if dy == 1 else 1.0 - fraction.y
				weight *= fraction.z if dz == 1 else 1.0 - fraction.z
				value += field[(base.z + dz) * resolution * resolution
					+ (base.y + dy) * resolution + base.x + dx] * weight
	return value


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
			"param":
				var assignment := value.split(":", true, 1)
				if assignment.size() == 2:
					_fps_params[String(assignment[0])] = float(assignment[1])
			"profile": _fps_profile = value == "1" or value.to_lower() == "true"
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
	if not _fps_params.is_empty():
		if not _demo.has_method("set_capture_params"):
			push_error("FPS PROBE FAIL: target does not support parameter overrides")
			quit(1)
			return
		await _demo.set_capture_params(_fps_params)
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
	if _fps_profile and _demo.has_method("set_capture_profiling"):
		_demo.set_capture_profiling(true)
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
	if _fps_profile and _demo.has_method("capture_metadata"):
		print(_demo.capture_metadata("fps"))
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


func _run_river_slope() -> void:
	await _boot_frames(2)
	root.size = Vector2i(1280, 720)
	var speed := 0.85
	var cell := 0.125
	var output_dir := ProjectSettings.globalize_path("res://tmp/river-slope-probe")
	var grades: Array[float] = [0.05, 0.15, 0.30]
	var headings: Array[Vector2] = [Vector2(0.0, -1.0), Vector2(1.0, 0.0), Vector2(1.0, -1.0)]
	var window := Vector2(16.0, 24.0)
	var seconds := 10.0
	var shift := Vector2.ZERO
	var guidance := Vector2(1.0, 5.0)
	for arg in _extra:
		var pair := arg.split("=", true, 1)
		if pair[0] == "speed":
			speed = float(pair[1])
		elif pair[0] == "grades":
			grades.assign(Array(pair[1].split(",")).map(func(value: String) -> float: return float(value)))
		elif pair[0] == "headings":
			var names := {"z": Vector2(0.0, -1.0), "x": Vector2(1.0, 0.0), "diagonal": Vector2(1.0, -1.0)}
			headings.assign(Array(pair[1].split(",")).map(func(value: String) -> Vector2: return names[value]))
		elif pair[0] == "current_hz":
			guidance.x = float(pair[1])
		elif pair[0] == "level_hz":
			guidance.y = float(pair[1])
		elif pair[0] == "shift":
			shift = Vector2(float(pair[1].get_slice(",", 0)), float(pair[1].get_slice(",", 1)))
		elif pair[0] == "seconds":
			seconds = float(pair[1])
		elif pair[0] == "window":
			window = Vector2.ZERO if pair[1] == "0" else Vector2(16.0, 24.0)
		elif pair[0] == "cell":
			cell = float(pair[1])
		elif pair[0] == "out":
			output_dir = pair[1] if pair[1].begins_with("/") else ProjectSettings.globalize_path("res://" + pair[1])
	DirAccess.make_dir_recursive_absolute(output_dir)
	var scene := _river_probe_stage()
	var camera := scene.get_node("Camera") as Camera3D
	var all_pass := true
	for grade in grades:
		for heading in headings:
			all_pass = await _river_slope_case(scene, camera, grade, heading, speed, guidance, cell, window, seconds, shift, output_dir) and all_pass
	_check(all_pass, "river_slope: every channel must keep its water, depth, banks and foam within the criteria")
	scene.queue_free()
	_finish("river_slope")


func _river_slope_case(scene: Node3D, camera: Camera3D, grade: float, heading: Vector2,
		speed: float, guidance: Vector2, cell: float, window: Vector2, seconds: float, shift: Vector2, output_dir: String) -> bool:
	var field := SlopeLandscape.new(grade, heading, Vector2(40.0, 40.0))
	var config := RiverConfig.new()
	config.water_level_m = 0.0
	config.speed_m_s = speed
	config.current_guidance_hz = guidance.x
	config.level_guidance_hz = guidance.y
	var river := _river_probe_system(field, config, camera)
	river.swe_window_m = window
	river.swe_cell_m = cell
	river.fixed_delta_s = 1.0 / 60.0
	camera.global_transform = Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(shift.x, 30.0, shift.y))
	var ground := MeshInstance3D.new()
	ground.mesh = _river_slope_ground(field)
	scene.add_child(ground)
	scene.add_child(river)
	river.start()
	var deadline := Time.get_ticks_msec() + 30000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	var name := "grade%02d_%s" % [roundi(grade * 100.0), "z" if heading.x == 0.0 else ("x" if heading.y == 0.0 else "diagonal")]
	if not river.swe.initialized:
		print("RIVER SLOPE %s FAIL: solver did not initialize" % name)
		river.queue_free()
		ground.queue_free()
		return false
	river.swe.profiling = true
	var gpu_ms := 0.0
	var frames := roundi(seconds * 60.0)
	for frame in frames:
		await process_frame
		if frame >= frames / 2:
			gpu_ms += river.swe.gpu_ms() / float(frames - frames / 2)
	river.frozen = true
	await _boot_frames(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s/%s.png" % [output_dir, name])
	var snapshot: Dictionary = river.swe.solver.snapshot()
	var grid: Vector2i = river.swe.solver.grid
	var size := grid.x * grid.y * 16
	var surface := (await TextureReadback.new().read_layer(snapshot.surface, 0, size)).to_float32_array()
	var terrain := (await TextureReadback.new().read_layer(snapshot.terrain, 0, size)).to_float32_array()
	var foam := (await TextureReadback.new().read_layer(snapshot.foam, 0, size)).to_float32_array()
	var region: Rect2 = river.swe.region_m
	var wet := 0
	var kept := 0
	var core := 0
	var off_depth := 0
	var overtopped := 0
	var overtop_max := 0.0
	var foamy := 0
	var ratios := PackedFloat32Array()
	var depth_map := Image.create(grid.x, grid.y, false, Image.FORMAT_RGB8)
	for y in grid.y:
		for x in grid.x:
			var point := region.position + (Vector2(x, y) + Vector2.ONE * 0.5) * river.swe.cell_m
			var i := (y * grid.x + x) * 4
			var reference := maxf(terrain[i + 1] - terrain[i], 0.0)
			var depth := surface[i + 3]
			depth_map.set_pixel(x, y, Color(clampf(depth - reference, 0.0, 0.5) * 2.0, clampf(reference, 0.0, 0.3) / 0.3, clampf(reference - depth, 0.0, 0.3) / 0.3))
			if minf(minf(point.x - region.position.x, region.end.x - point.x),
					minf(point.y - region.position.y, region.end.y - point.y)) < 2.5:
				continue
			if reference <= 0.015:
				if depth > 0.05:
					overtopped += 1
				overtop_max = maxf(overtop_max, depth)
				continue
			wet += 1
			kept += int(depth > 0.015)
			foamy += int(foam[i] > 0.5)
			if reference >= 0.2:
				core += 1
				var ratio := depth / reference
				ratios.append(ratio)
				off_depth += int(ratio < 0.8 or ratio > 1.2)
	ratios.sort()
	depth_map.save_png("%s/%s_depth.png" % [output_dir, name])
	var kept_pct := 100.0 * kept / maxf(wet, 1.0)
	var off_pct := 100.0 * off_depth / maxf(core, 1.0)
	var foam_pct := 100.0 * foamy / maxf(wet, 1.0)
	var passed := wet > 0 and kept_pct >= 99.0 and off_pct <= 1.0 and overtopped == 0 and foam_pct <= 0.5
	print("RIVER SLOPE %s speed=%.2f guidance_hz=%.2f/%.2f cell=%.3f wet_cells=%d kept=%.2f%% depth_p01=%.3f depth_p50=%.3f depth_p99=%.3f outside_80_120=%.2f%% overtop_cells=%d overtop_max_m=%.3f foam=%.2f%% gpu_ms=%.3f %s" % [
		name, speed, guidance.x, guidance.y, river.swe.cell_m, wet, kept_pct,
		ratios[int(ratios.size() * 0.01)] if not ratios.is_empty() else 0.0,
		ratios[int(ratios.size() * 0.5)] if not ratios.is_empty() else 0.0,
		ratios[mini(int(ratios.size() * 0.99), ratios.size() - 1)] if not ratios.is_empty() else 0.0,
		off_pct, overtopped, overtop_max, foam_pct, gpu_ms, "PASS" if passed else "FAIL"])
	river.queue_free()
	ground.queue_free()
	await _boot_frames(2)
	return passed


func _river_probe_stage() -> Node3D:
	var scene := Node3D.new()
	root.add_child(scene)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.45, 0.55, 0.65)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	scene.add_child(sun)
	var camera := Camera3D.new()
	camera.name = "Camera"
	scene.add_child(camera)
	camera.current = true
	return scene


func _river_probe_system(field: RiverField, config: RiverConfig, camera: Camera3D) -> RiverSystem:
	var river := RiverSystem.new()
	river.config = config
	river.field = field
	river.camera = camera
	river.scene_world = camera.get_world_3d()
	river.compute_available = RenderingServer.get_rendering_device() != null
	river.micro_normal = load("res://resources/ocean/micro_normal.png")
	river.foam_filaments = load("res://resources/ocean/foam_variant_03_flowing_filaments.png")
	river.foam_bubbles = load("res://resources/ocean/foam_variant_01_microbubbles.png")
	river.reflection_scale = 0.0
	return river


func _river_slope_ground(field: RiverField) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := Vector2i(field.domain_m / 0.5)
	var origin := field.domain_rect().position
	for y in steps.y:
		for x in steps.x:
			var corners: Array[Vector2] = [origin + Vector2(x, y) * 0.5, origin + Vector2(x + 1, y) * 0.5,
				origin + Vector2(x, y + 1) * 0.5, origin + Vector2(x + 1, y + 1) * 0.5]
			for index in [0, 1, 2, 1, 3, 2]:
				var point: Vector2 = corners[index]
				surface.add_vertex(Vector3(point.x, field.sample_bed(point), point.y))
	surface.generate_normals()
	var mesh := surface.commit()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.36, 0.28)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	return mesh


func _run_river_domain() -> void:
	await _boot_frames(2)
	root.size = Vector2i(1280, 720)
	var scene := _river_probe_stage()
	var camera := scene.get_node("Camera") as Camera3D
	var field := SlopeLandscape.new(0.05, Vector2(0.0, -1.0), Vector2(40.0, 40.0))
	_river_prepare_images(field, Vector2.ZERO)
	var config := RiverConfig.new()
	config.water_level_m = 0.0
	config.current_guidance_hz = 1.0
	config.level_guidance_hz = 5.0
	var river := _river_probe_system(field, config, camera)
	river.swe_window_m = Vector2(16.0, 24.0)
	river.swe_range_m = 10.0
	river.swe_cell_m = 0.25
	river.fixed_delta_s = 1.0 / 60.0
	_river_look(camera, Vector2(0.0, 0.0))
	scene.add_child(river)
	var started := Time.get_ticks_usec()
	river.loading_stage = func(label: String) -> void:
		if not label.is_empty():
			print("RIVER DOMAIN stage %.2f ms %s" % [(Time.get_ticks_usec() - started) / 1000.0, label])
	river.start()
	var start_ms := (Time.get_ticks_usec() - started) / 1000.0
	var start_frame_ms := await _river_slowest_frame_ms(3)
	var deadline := Time.get_ticks_msec() + 30000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(river.swe.initialized and river.swe.region_m.size == Vector2(16.0, 24.0),
		"river_domain: the windowed solver must start on a 16 x 24 m window")
	await _boot_frames(120)
	river.frozen = true
	await _boot_frames(2)
	var before: Dictionary = await _river_window_state(river)
	_river_look(camera, Vector2(0.0, -8.0))
	await _boot_frames(3)
	var after: Dictionary = await _river_window_state(river)
	var moved: bool = after.region != before.region
	var shared := 0
	var identical := 0
	for key: Vector2i in before.depth:
		if after.depth.has(key):
			shared += 1
			identical += int(is_equal_approx(before.depth[key], after.depth[key]))
	print("RIVER DOMAIN window_follow moved=%s region=%s -> %s shared_cells=%d identical=%d" % [moved, before.region, after.region, shared, identical])
	_check(moved and shared > 0 and identical == shared,
		"river_domain: a window snap must carry the overlapping state over unchanged")
	river.frozen = false
	var steady_frame_ms := await _river_slowest_frame_ms(30)
	_river_prepare_images(field, Vector2(0.0, -24.0))
	started = Time.get_ticks_usec()
	river.move_domain(Vector2(0.0, -24.0))
	var move_ms := (Time.get_ticks_usec() - started) / 1000.0
	var move_frame_ms := await _river_slowest_frame_ms(3)
	_river_look(camera, Vector2(0.0, -24.0))
	await _boot_frames(180)
	var metrics := await _river_window_metrics(river, field)
	print("RIVER DOMAIN move_domain steady_frame_max_ms=%.2f start_ms=%.2f start_frame_ms=%.2f move_ms=%.2f move_frame_ms=%.2f region=%s kept=%.2f%% depth_p50=%.3f bed_error_m=%.4f" % [
		steady_frame_ms, start_ms, start_frame_ms, move_ms, move_frame_ms, river.swe.region_m, metrics.kept, metrics.depth_p50, metrics.bed_error_m])
	_check(river.field.domain_rect().has_point(Vector2(0.0, -24.0)) and river.swe.region_m.get_center().distance_to(Vector2(0.0, -24.0)) < 4.0
		and metrics.kept >= 99.0 and absf(metrics.depth_p50 - 1.0) < 0.05 and metrics.bed_error_m < 0.02,
		"river_domain: move_domain must keep simulating the moved river without a restart")
	_river_look(camera, Vector2(15.0, -24.0))
	var faded := await _river_wait(func() -> bool: return river.swe.blend == 0.0 and not river.swe.live, 3.0)
	_river_look(camera, Vector2(0.0, -24.0))
	await _boot_frames(2)
	var warming := river.swe.live and river.swe.blend == 0.0
	var returned := await _river_wait(func() -> bool: return river.swe.blend == 1.0, 3.0)
	print("RIVER DOMAIN lod faded=%s warming=%s returned=%s" % [faded, warming, returned])
	_check(faded and warming and returned,
		"river_domain: far from water the solver must fade out and stop, then warm up and fade back in")
	_river_prepare_images(field, Vector2(200.0, -24.0))
	river.move_domain(Vector2(200.0, -24.0))
	await _boot_frames(3)
	var idle := not river.field.has_water and not river._surface.visible
	_river_prepare_images(field, Vector2(0.0, -24.0))
	river.move_domain(Vector2(0.0, -24.0))
	await _boot_frames(3)
	var woken := river.field.has_water and river._surface.visible
	print("RIVER DOMAIN idle dry=%s woken=%s" % [idle, woken])
	_check(idle and woken, "river_domain: a dry domain must idle and wake again with water")
	river.stop()
	await _boot_frames(2)
	started = Time.get_ticks_usec()
	started = Time.get_ticks_usec()
	river.start()
	var restart_ms := (Time.get_ticks_usec() - started) / 1000.0
	var restart_frame_ms := await _river_slowest_frame_ms(3)
	print("RIVER DOMAIN restart start_ms=%.2f first_frame_ms=%.2f" % [restart_ms, restart_frame_ms])
	river.queue_free()
	scene.queue_free()
	await _boot_frames(2)
	_finish("river_domain")


func _river_prepare_images(field: RiverField, origin: Vector2) -> void:
	field.origin_m = origin
	field.flow_image = null
	field.bed_image = null
	var cells := Vector2i(160, 160)
	var flow := field.bake(0.0, cells)
	field.flow_image = flow.get_image()
	field.bed_image = field.bed_texture.get_image()
	var values := PackedFloat32Array()
	values.resize(cells.x * cells.y * 4)
	var corner := field.domain_rect().position
	for y in cells.y:
		for x in cells.x:
			var point := corner + (Vector2(x, y) + Vector2.ONE * 0.5) * field.domain_m / Vector2(cells)
			var drive := field.sample_solver(point, 0.0)
			var i := (y * cells.x + x) * 4
			values[i] = field.sample_bed(point)
			values[i + 1] = field.sample_height(point, 0.0)
			values[i + 2] = drive.r
			values[i + 3] = drive.g
	field.solver_terrain_image = Image.create_from_data(cells.x, cells.y, false, Image.FORMAT_RGBAF, values.to_byte_array())


func _river_look(camera: Camera3D, point: Vector2) -> void:
	camera.global_transform = Transform3D(Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(point.x, 6.0, point.y))


func _river_wait(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + roundi(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return condition.call()


func _river_slowest_frame_ms(count: int) -> float:
	var slowest := 0.0
	for frame in count:
		var started := Time.get_ticks_usec()
		await process_frame
		slowest = maxf(slowest, (Time.get_ticks_usec() - started) / 1000.0)
	return slowest


func _river_window_state(river: RiverSystem) -> Dictionary:
	var grid: Vector2i = river.swe.solver.grid
	var snapshot: Dictionary = river.swe.solver.snapshot()
	var surface := (await TextureReadback.new().read_layer(snapshot.surface, 0, grid.x * grid.y * 16)).to_float32_array()
	var region: Rect2 = river.swe.region_m
	var depth := {}
	for y in grid.y:
		for x in grid.x:
			var world := Vector2i(((region.position + (Vector2(x, y) + Vector2.ONE * 0.5) * river.swe.cell_m) / river.swe.cell_m).floor())
			depth[world] = surface[(y * grid.x + x) * 4 + 3]
	return {"region": region, "depth": depth}


func _river_window_metrics(river: RiverSystem, field: RiverField) -> Dictionary:
	var grid: Vector2i = river.swe.solver.grid
	var snapshot: Dictionary = river.swe.solver.snapshot()
	var size := grid.x * grid.y * 16
	var surface := (await TextureReadback.new().read_layer(snapshot.surface, 0, size)).to_float32_array()
	var terrain := (await TextureReadback.new().read_layer(snapshot.terrain, 0, size)).to_float32_array()
	var region: Rect2 = river.swe.region_m
	var wet := 0
	var kept := 0
	var bed_error := 0.0
	var ratios := PackedFloat32Array()
	for y in grid.y:
		for x in grid.x:
			var point := region.position + (Vector2(x, y) + Vector2.ONE * 0.5) * river.swe.cell_m
			if minf(minf(point.x - region.position.x, region.end.x - point.x),
					minf(point.y - region.position.y, region.end.y - point.y)) < 2.5:
				continue
			var i := (y * grid.x + x) * 4
			var reference := maxf(terrain[i + 1] - terrain[i], 0.0)
			if reference <= 0.015:
				continue
			wet += 1
			kept += int(surface[i + 3] > 0.015)
			if reference >= 0.2:
				ratios.append(surface[i + 3] / reference)
				bed_error = maxf(bed_error, absf(terrain[i] - field.sample_bed(point)))
	ratios.sort()
	return {"kept": 100.0 * kept / maxf(wet, 1.0), "depth_p50": ratios[ratios.size() / 2] if not ratios.is_empty() else 0.0,
		"bed_error_m": bed_error}


const FIXTURE_WALK_M_S := 1.5
const FIXTURE_WALK_FRAMES := 600
const FIXTURE_EYE_M := 2.5


func _run_river_fixtures() -> void:
	await _boot_frames(2)
	root.size = Vector2i(1280, 720)
	var source_dir := ProjectSettings.globalize_path("res://tmp/simple_forest_fixtures")
	var output_dir := ProjectSettings.globalize_path("res://tmp/river-fixtures-probe")
	var only := PackedStringArray()
	var continuous_dry := false
	var current_cap := 0.0
	var guided := false
	var record := false
	for arg in _extra:
		var pair := arg.split("=", true, 1)
		if pair[0] == "dir":
			source_dir = pair[1] if pair[1].begins_with("/") else ProjectSettings.globalize_path("res://" + pair[1])
		elif pair[0] == "out":
			output_dir = pair[1] if pair[1].begins_with("/") else ProjectSettings.globalize_path("res://" + pair[1])
		elif pair[0] == "only":
			only = pair[1].split(",")
		elif pair[0] == "dry_surface":
			continuous_dry = pair[1] == "continuous"
		elif pair[0] == "current_cap":
			current_cap = float(pair[1])
		elif pair[0] == "guided":
			guided = pair[1] == "1"
		elif pair[0] == "record":
			record = pair[1] == "1"
	DirAccess.make_dir_recursive_absolute(output_dir)
	var names := PackedStringArray()
	for file in DirAccess.get_files_at(source_dir):
		if file.ends_with(".json") and (only.is_empty() or only.has(file.get_basename())):
			names.append(file.get_basename())
	names.sort()
	var scene := _river_probe_stage()
	var camera := scene.get_node("Camera") as Camera3D
	var passed := 0
	for name in names:
		passed += int(await _river_fixture_case(scene, camera, source_dir, name, output_dir, continuous_dry,
			current_cap, guided, record))
	scene.queue_free()
	await _boot_frames(2)
	print("RIVER FIXTURES DONE passed=%d/%d" % [passed, names.size()])
	quit(0)


func _river_fixture_case(scene: Node3D, camera: Camera3D, source_dir: String, name: String, output_dir: String, continuous_dry: bool,
		current_cap: float, guided: bool, record: bool) -> bool:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/%s.json" % [source_dir, name]))
	var field := RiverField.new()
	field.solver_terrain_image = Image.load_from_file("%s/%s_solver_terrain.exr" % [source_dir, name])
	field.flow_image = Image.load_from_file("%s/%s_flow.exr" % [source_dir, name])
	field.bed_image = Image.load_from_file("%s/%s_bed.exr" % [source_dir, name])
	field.origin_m = Vector2(meta.origin_m[0], meta.origin_m[1])
	field.domain_m = Vector2(meta.domain_m[0], meta.domain_m[1])
	field.height_range_m = Vector2(meta.height_range_m[0], meta.height_range_m[1])
	if continuous_dry:
		print("RIVER FIXTURE %s dry_surface=continuous rewritten_texels=%d/%d" % [name,
			_river_fixture_continuous_dry(field.solver_terrain_image), _river_fixture_continuous_dry(field.bed_image)])
	if current_cap > 0.0:
		print("RIVER FIXTURE %s current_cap=%.2f capped_texels=%d" % [name, current_cap,
			_river_fixture_cap_current(field.solver_terrain_image, 2, false, current_cap)
			+ _river_fixture_cap_current(field.flow_image, 0, true, current_cap)])
	var terrain_image := field.solver_terrain_image
	var image_wet := 0
	var low_banks := 0
	for y in terrain_image.get_height():
		for x in terrain_image.get_width():
			image_wet += int(_river_fixture_wet(terrain_image, Vector2i(x, y)))
			low_banks += int(_river_fixture_low_bank(terrain_image, Vector2i(x, y)))
	print("RIVER FIXTURE %s loaded formats=%d/%d/%d wet_texels=%d expected=%d low_bank_texels=%d" % [name,
		terrain_image.get_format(), field.flow_image.get_format(), field.bed_image.get_format(),
		image_wet, int(meta.wet_texels), low_banks])
	var config := RiverConfig.new()
	config.water_level_m = 0.0
	config.speed_m_s = 1.0
	config.current_guidance_hz = 1.0
	config.level_guidance_hz = 5.0
	var river := _river_probe_system(field, config, camera)
	river.swe_window_m = Vector2(16.0, 24.0)
	river.swe_cell_m = 0.25
	river.swe_range_m = 20.0
	river.fixed_delta_s = 1.0 / 60.0
	var ground := MeshInstance3D.new()
	ground.mesh = _river_fixture_ground(field)
	scene.add_child(ground)
	var point := _river_fixture_start(field)
	var heading := _river_fixture_heading(field, point, Vector2.RIGHT)
	for step in roundi(FIXTURE_WALK_M_S * FIXTURE_WALK_FRAMES / 60.0 * 0.5 / 0.25):
		heading = _river_fixture_heading(field, point, heading)
		point -= heading * 0.25
	heading = _river_fixture_heading(field, point, heading)
	var walk_start := point
	_river_fixture_pose(camera, field, point, heading)
	scene.add_child(river)
	river.start()
	river.water_material.set_shader_parameter("guided_coverage", true)
	var deadline := Time.get_ticks_msec() + 30000
	while not river.swe.initialized and Time.get_ticks_msec() < deadline:
		await process_frame
	if not river.swe.initialized:
		print("RIVER FIXTURE %s FAIL: solver did not initialize" % name)
		river.queue_free()
		ground.queue_free()
		await _boot_frames(2)
		return false
	await _boot_frames(120)
	var start_pair: Array[Image] = []
	if guided:
		river.swe.set_enabled(false)
	else:
		start_pair = await _river_fixture_pair(river, output_dir, name, "start")
	river.frozen = false
	river.swe.profiling = true
	var gpu_ms := 0.0
	var clip_dir := "%s/%s_%s" % [output_dir, name, "guided" if guided else ("swe_cap" + str(current_cap) if current_cap > 0.0 else "swe")]
	if record:
		DirAccess.make_dir_recursive_absolute(clip_dir)
	for frame in FIXTURE_WALK_FRAMES:
		heading = heading.lerp(_river_fixture_heading(field, point, heading), 0.05).normalized()
		point += heading * FIXTURE_WALK_M_S / 60.0
		_river_fixture_pose(camera, field, point, heading)
		await process_frame
		if record and frame % 2 == 0:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("%s/%04d.png" % [clip_dir, frame / 2])
		if frame >= FIXTURE_WALK_FRAMES / 2:
			gpu_ms += river.swe.gpu_ms() / float(FIXTURE_WALK_FRAMES - FIXTURE_WALK_FRAMES / 2)
	if guided:
		print("RIVER FIXTURE %s guided walk done frames=%s" % [name, clip_dir if record else "none"])
		river.queue_free()
		ground.queue_free()
		await _boot_frames(2)
		return false
	river.frozen = true
	await _boot_frames(3)
	var snapshot: Dictionary = river.swe.solver.snapshot()
	var grid: Vector2i = river.swe.solver.grid
	var size := grid.x * grid.y * 16
	var surface := (await TextureReadback.new().read_layer(snapshot.surface, 0, size)).to_float32_array()
	var terrain := (await TextureReadback.new().read_layer(snapshot.terrain, 0, size)).to_float32_array()
	var foam := (await TextureReadback.new().read_layer(snapshot.foam, 0, size)).to_float32_array()
	var region: Rect2 = river.swe.region_m
	var wet := 0
	var kept := 0
	var overflow := 0
	var overflow_max := 0.0
	var foamy := 0
	var ratios := PackedFloat32Array()
	var faults := {"lost": [0, 0, 0], "overflow": [0, 0, 0], "depth": [0, 0, 0], "foam": [0, 0, 0]}
	var examples := PackedStringArray()
	var depth_map := Image.create(grid.x, grid.y, false, Image.FORMAT_RGB8)
	for y in grid.y:
		for x in grid.x:
			var cell_point := region.position + (Vector2(x, y) + Vector2.ONE * 0.5) * river.swe.cell_m
			var i := (y * grid.x + x) * 4
			var reference := maxf(terrain[i + 1] - terrain[i], 0.0)
			var depth := surface[i + 3]
			depth_map.set_pixel(x, y, Color(clampf(depth - reference, 0.0, 0.5) * 2.0, clampf(reference, 0.0, 0.3) / 0.3, clampf(reference - depth, 0.0, 0.3) / 0.3))
			if minf(minf(cell_point.x - region.position.x, region.end.x - cell_point.x),
					minf(cell_point.y - region.position.y, region.end.y - cell_point.y)) < 2.5:
				continue
			var kinds: Array[String] = []
			if reference <= 0.015:
				if depth > 0.05:
					overflow += 1
					kinds.append("overflow")
				overflow_max = maxf(overflow_max, depth)
			else:
				wet += 1
				kept += int(depth > 0.015)
				if depth <= 0.015:
					kinds.append("lost")
				if foam[i] > 0.5:
					foamy += 1
					kinds.append("foam")
				if reference >= 0.2:
					var ratio := depth / reference
					ratios.append(ratio)
					if ratio < 0.8 or ratio > 1.2:
						kinds.append("depth")
			if kinds.is_empty():
				continue
			var texel := Vector2i(((cell_point - field.domain_rect().position) / field.domain_m * Vector2(terrain_image.get_size())).floor())
			var cause := _river_fixture_cause(terrain_image, field, cell_point)
			for kind in kinds:
				faults[kind][cause] += 1
			if examples.size() < 12:
				var source := terrain_image.get_pixelv(texel)
				examples.append("%s@texel%s(%.2f,%.2f):solver_ref=%.3f,texel_depth=%.3f,depth=%.3f,%s" % ["+".join(kinds), texel,
					cell_point.x, cell_point.y, reference, source.g - source.r, depth, ["sentinel", "low_bank", "solver"][cause]])
	ratios.sort()
	depth_map.save_png("%s/%s_depth.png" % [output_dir, name])
	var end_pair := await _river_fixture_pair(river, output_dir, name, "end")
	var sheet := Image.create(1280, 720, false, Image.FORMAT_RGBA8)
	for index in 4:
		var tile: Image = (start_pair + end_pair)[index]
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(640, 360)
		sheet.blit_rect(tile, Rect2i(0, 0, 640, 360), Vector2i(index % 2 * 640, index / 2 * 360))
	sheet.save_png("%s/%s_sheet.png" % [output_dir, name])
	var kept_pct := 100.0 * kept / maxf(wet, 1.0)
	var p01 := ratios[int(ratios.size() * 0.01)] if not ratios.is_empty() else 0.0
	var p99 := ratios[mini(int(ratios.size() * 0.99), ratios.size() - 1)] if not ratios.is_empty() else 0.0
	var passed := wet > 0 and not ratios.is_empty() and kept_pct >= 99.0 and p01 >= 0.8 and p99 <= 1.2 and overflow == 0 and foamy == 0
	print("RIVER FIXTURE %s speed_p50=%.2f grade_p50=%.3f walk=%s->%s region=%s wet_cells=%d kept=%.2f%% depth_p01=%.3f depth_p50=%.3f depth_p99=%.3f overflow=%d overflow_max_m=%.3f foam_cells=%d gpu_ms=%.3f diff_start=%.4f diff_end=%.4f %s" % [
		name, float(meta.current_m_s.p50), float(meta.surface_grade.p50), walk_start.snapped(Vector2.ONE * 0.1), point.snapped(Vector2.ONE * 0.1),
		region, wet, kept_pct, p01, ratios[ratios.size() / 2] if not ratios.is_empty() else 0.0, p99, overflow, overflow_max, foamy, gpu_ms,
		_river_fixture_difference(start_pair[0], start_pair[1]), _river_fixture_difference(end_pair[0], end_pair[1]), "PASS" if passed else "FAIL"])
	print("RIVER FIXTURE %s faults sentinel/low_bank/solver lost=%s overflow=%s depth=%s foam=%s" % [
		name, faults.lost, faults.overflow, faults.depth, faults.foam])
	for example in examples:
		print("RIVER FIXTURE %s fault %s" % [name, example])
	river.queue_free()
	ground.queue_free()
	await _boot_frames(2)
	return passed


func _river_fixture_wet(terrain: Image, texel: Vector2i) -> bool:
	var data := terrain.get_pixelv(texel.clamp(Vector2i.ZERO, terrain.get_size() - Vector2i.ONE))
	return data.g - data.r > 0.015


func _river_fixture_continuous_dry(image: Image) -> int:
	var source := image.duplicate() as Image
	var bounds := Rect2i(Vector2i.ZERO, source.get_size())
	var rewritten := 0
	for y in bounds.size.y:
		for x in bounds.size.x:
			var texel := source.get_pixel(x, y)
			if _river_fixture_wet(source, Vector2i(x, y)):
				continue
			var level := -INF
			for neighbour_y in range(y - 1, y + 2):
				for neighbour_x in range(x - 1, x + 2):
					var neighbour := Vector2i(neighbour_x, neighbour_y)
					if bounds.has_point(neighbour) and _river_fixture_wet(source, neighbour):
						level = maxf(level, source.get_pixelv(neighbour).g)
			if level == -INF:
				continue
			texel.g = minf(texel.r - 0.05, level)
			image.set_pixel(x, y, texel)
			rewritten += 1
	return rewritten


func _river_fixture_cap_current(image: Image, channel: int, scaled_by_wet: bool, cap_m_s: float) -> int:
	var capped := 0
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			var wet := texel.a if scaled_by_wet else 1.0
			if wet <= 0.0:
				continue
			var current := Vector2(texel[channel], texel[channel + 1]) / wet
			if current.length() <= cap_m_s:
				continue
			current = current.limit_length(cap_m_s) * wet
			texel[channel] = current.x
			texel[channel + 1] = current.y
			image.set_pixel(x, y, texel)
			capped += 1
	return capped


func _river_fixture_low_bank(terrain: Image, texel: Vector2i) -> bool:
	if _river_fixture_wet(terrain, texel):
		return false
	var bed := terrain.get_pixelv(texel).r
	for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbour := texel + offset
		if Rect2i(Vector2i.ZERO, terrain.get_size()).has_point(neighbour) and _river_fixture_wet(terrain, neighbour) \
				and terrain.get_pixelv(neighbour).g > bed + 0.05:
			return true
	return false


func _river_fixture_cause(terrain: Image, field: RiverField, point: Vector2) -> int:
	var cell := (point - field.domain_rect().position) / field.domain_m * Vector2(terrain.get_size()) - Vector2.ONE * 0.5
	var texel := Vector2i(cell.round())
	if _river_fixture_wet(terrain, texel):
		var low := Vector2i(cell.floor())
		for offset: Vector2i in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.ONE]:
			if not _river_fixture_wet(terrain, low + offset):
				return 0
		return 2
	return 1 if _river_fixture_low_bank(terrain, texel) else 2


func _river_fixture_ground(field: RiverField) -> ArrayMesh:
	var image := field.solver_terrain_image
	var size := image.get_size()
	var cell := field.domain_m / Vector2(size)
	var corner := field.domain_rect().position + cell * 0.5
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for y in size.y:
		for x in size.x:
			var slope := Vector2(image.get_pixel(mini(x + 1, size.x - 1), y).r - image.get_pixel(maxi(x - 1, 0), y).r,
				image.get_pixel(x, mini(y + 1, size.y - 1)).r - image.get_pixel(x, maxi(y - 1, 0)).r) / (cell * 2.0)
			var point := corner + Vector2(x, y) * cell
			vertices.append(Vector3(point.x, image.get_pixel(x, y).r, point.y))
			normals.append(Vector3(-slope.x, 1.0, -slope.y).normalized())
			if x + 1 < size.x and y + 1 < size.y:
				var a := y * size.x + x
				indices.append_array([a, a + 1, a + size.x, a + 1, a + size.x + 1, a + size.x])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.36, 0.28)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	return mesh


func _river_fixture_start(field: RiverField) -> Vector2:
	var image := field.solver_terrain_image
	var size := image.get_size()
	var cell := field.domain_m / Vector2(size)
	var corner := field.domain_rect().position
	var deepest := Vector2.INF
	var deepest_m := 0.0
	var nearest := Vector2.INF
	for y in size.y:
		for x in size.x:
			var texel := image.get_pixel(x, y)
			var depth := texel.g - texel.r
			if depth <= 0.015:
				continue
			var point := corner + (Vector2(x, y) + Vector2.ONE * 0.5) * cell
			if point.distance_to(field.origin_m) <= 3.0 and depth > deepest_m:
				deepest = point
				deepest_m = depth
			if nearest == Vector2.INF or point.distance_to(field.origin_m) < nearest.distance_to(field.origin_m):
				nearest = point
	return deepest if deepest_m > 0.0 else nearest


func _river_fixture_heading(field: RiverField, point: Vector2, previous: Vector2) -> Vector2:
	var drive := field.sample_solver(point, 0.0)
	var current := Vector2(drive.r, drive.g)
	return current.normalized() if current.length() >= 0.05 else previous


func _river_fixture_pose(camera: Camera3D, field: RiverField, point: Vector2, heading: Vector2) -> void:
	var eye := Vector3(point.x, maxf(field.sample_height(point, 0.0), field.sample_bed(point)) + FIXTURE_EYE_M, point.y)
	var forward := Vector3(heading.x * cos(PI / 6.0), -sin(PI / 6.0), heading.y * cos(PI / 6.0))
	camera.look_at_from_position(eye, eye + forward, Vector3.UP)


func _river_fixture_pair(river: RiverSystem, output_dir: String, name: String, label: String) -> Array[Image]:
	river.frozen = true
	await _boot_frames(3)
	await RenderingServer.frame_post_draw
	var simulated := root.get_texture().get_image()
	river.swe.set_enabled(false)
	await _boot_frames(3)
	await RenderingServer.frame_post_draw
	var guided := root.get_texture().get_image()
	river.swe.set_enabled(true)
	simulated.save_png("%s/%s_%s_swe.png" % [output_dir, name, label])
	guided.save_png("%s/%s_%s_guided.png" % [output_dir, name, label])
	return [simulated, guided]


func _river_fixture_difference(a: Image, b: Image) -> float:
	var small_a := a.duplicate() as Image
	var small_b := b.duplicate() as Image
	small_a.resize(320, 180)
	small_b.resize(320, 180)
	var total := 0.0
	for y in 180:
		for x in 320:
			total += absf(small_a.get_pixel(x, y).get_luminance() - small_b.get_pixel(x, y).get_luminance())
	return total / (320.0 * 180.0)
