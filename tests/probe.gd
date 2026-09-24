extends "res://tests/test_case.gd"

## The project's single probe entry point: every probe is a `_run_<name>`
## method here, dispatched by tests/probe.sh (setsid + timeout + group kill on
## an isolated virtual Wayland display) or directly by the GPU phase of
## tests/run_tests.sh. `tests/probe.sh list` prints the names. Only
## tornado_boot_look (frame-driven) and fps (boots its scene here) dispatch
## outside the _run_<name> convention.

const TextureReadback := preload("res://scripts/core/texture_readback.gd")

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
## upshift, a solver A/B switch and a restart, and asserts the solver comes back
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

	demo.solver_option.select(FluidSystem.Method.PBF)
	demo.solver_option.item_selected.emit(FluidSystem.Method.PBF)
	demo.scenario_option.select(FluidSystem.Scenario.CASCADE)
	demo.scenario_option.item_selected.emit(FluidSystem.Scenario.CASCADE)
	await process_frame
	var stored_solver := int(demo.menu.stored_value("Simulation", "Solver", -1))
	if demo.fluid.method != FluidSystem.Method.SPH \
			or demo.solver_option.selected != FluidSystem.Method.SPH \
			or stored_solver != FluidSystem.Method.SPH:
		_fail_tier(demo, "Cascade/SPH persistence")
		return
	print("FLUTIER cascade_solver runtime=%d widget=%d stored=%d" % [
		demo.fluid.method, demo.solver_option.selected, stored_solver])
	demo.scenario_option.select(FluidSystem.Scenario.DAM)
	demo.scenario_option.item_selected.emit(FluidSystem.Scenario.DAM)
	if not await _soak(demo):
		_fail_tier(demo, "return to Dam")
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

	# Solver A/B re-inits validate the same config pair.
	demo.fluid.set_method(FluidSystem.Method.PBF)
	if not await _soak(demo):
		_fail_tier(demo, "solver PBF")
		return
	print("FLUTIER solver_pbf initialized=%s" % demo.fluid.active_solver.initialized)
	demo.fluid.set_method(FluidSystem.Method.SPH)
	if not await _soak(demo):
		_fail_tier(demo, "solver SPH")
		return

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
	var solver: RefCounted = demo.fluid.active_solver
	if not ("_sim_time" in solver):
		# The PBF solver has no sim clock; a fixed frame soak still lets the
		# queued steps run (and any late breakage surface).
		for i in 90:
			await process_frame
		return demo.fluid.active_solver.initialized
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
## sampling the identity of _lod_meshes[0] every frame counts the fills without
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
	for arg in _extra:
		if arg.begins_with("seed="):
			seed_mode = int(arg.get_slice("=", 1))
	var settings: Node = root.get_node("/root/UserSettings")
	settings.clear_sim("grass_demo")
	# SimMenu derives its persistence section from GameManager.current_demo;
	# without the real launch flow it stays empty and restore is disabled.
	root.get_node("/root/GameManager").current_demo = "grass_demo"
	root.get_node("/root/GameManager").set_setting("grass_quality_profile", 1)
	if seed_mode == 1:
		settings.set_sim_value("grass_demo", DENSITY_KEY, 0.5)
	elif seed_mode == 2:
		settings.set_sim_value("grass_demo", DENSITY_KEY, TIER_DENSITY)

	var demo: Node = load("res://scenes/grass_demo.tscn").instantiate()

	var last_lod_id := 0
	var generates := 0
	var frames: Array = []
	var densities: Array = []

	# The first fill runs inside _ready during add_child, before the first
	# awaitable frame, so sample synchronously here and then every frame.
	root.add_child(demo)
	if not demo.grass._lod_meshes.is_empty():
		generates += 1
		frames.append(-1)
		densities.append(demo.grass.density)
		last_lod_id = (demo.grass._lod_meshes[0] as MultiMesh).get_instance_id()

	for frame in GRASS_SAMPLE_FRAMES:
		await process_frame
		var grass: Node = demo.grass
		if grass == null:
			continue
		var meshes: Array = grass._lod_meshes
		if meshes.is_empty():
			continue
		var id: int = (meshes[0] as MultiMesh).get_instance_id()
		if id != last_lod_id:
			generates += 1
			frames.append(frame)
			densities.append(grass.density)
			last_lod_id = id

	print("GRA3 PROBE DONE seed=%d generates=%d frames=%s densities=%s final_density=%.3f" % [
		seed_mode, generates, str(frames), str(densities), demo.grass.density])
	quit(0)


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
			"size":
				var dims := value.split("x")
				if dims.size() == 2:
					_size = Vector2i(maxi(16, int(dims[0])), maxi(16, int(dims[1])))
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
	# UserSettings restores the persisted window size once the autoloads are in;
	# force the requested size back so the measurement is deterministic.
	root.size = _size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for frame in _warmup:
		await process_frame
	var frames := 0
	var t0 := Time.get_ticks_usec()
	var deadline := t0 + int(_seconds * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		frames += 1
	var elapsed := float(Time.get_ticks_usec() - t0) / 1_000_000.0
	print("FPS PROBE target=%s tier=%s fps=%.1f frames=%d seconds=%.2f size=%dx%d" % [
		_scene_path.get_file().get_basename(), TIER_NAMES[_tier],
		float(frames) / elapsed, frames, elapsed, _size.x, _size.y])
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
