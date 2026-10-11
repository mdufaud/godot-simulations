extends RefCounted

## Regression probes for the island coastal base (milestone A of the ocean
## handoff). Modes:
##  - "island_spectrum": entering Island Beach must not recalibrate the FFT
##    spectrum (depth, spectral moments, displacement field at equal time).
##  - "seam": ring injection must honor source_depth_m for orbital velocity,
##    pack every cascade that passes the wavelength cutoff, and deliver the
##    incident wave across the rim with <=5% amplitude rupture and <=5%
##    standing-wave reflection on a flat constant-depth bed.
##  - "dispersion": monochromatic waves on a flat bed must propagate at the
##    exact finite-depth phase speed within 5% and keep their amplitude.
##  - "volume": closed-domain 30 s volume drift and open-domain volume budget
##    within 1%.
## The seam/dispersion/volume modes drive the production OceanShoreSolver
## directly (same path the island scene steps), not a probe copy of it.

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const ShoreSolver := preload("res://scripts/ocean/ocean_shore_solver.gd")

const SCENE_PATH := "res://scenes/ocean_demo.tscn"
const N := 128
const BOUNDARY_N := ShoreSolver.BOUNDARY_SIZE
const DOMAIN := 160.0
const CELL := DOMAIN / float(N)
const TILES: PackedFloat32Array = [2039.0, 111.0, 25.0]
const GRAVITY := 9.81
const DT := 1.0 / 30.0
const SAMPLE_HZ := 15.0
const SAMPLE_EVERY := 2
const AMP := 0.5 # two spectrum taps (+k, -k) make a 1.0 m incident amplitude
const INCIDENT_AMP := 1.0
const RING_DEPTH_M := 16.0
const SEAM_MODE := 50 # lambda = 2039/50 = 40.78 m, kh = 2.465 at 16 m
const DISP_DEPTH_M := 8.0
const DISP_WAVELENGTHS := [40.0, 34.0] # kh = 1.257, 1.479 at 8 m depth
const DISP_AMPLITUDE := 0.2

static var _ready := false
static var _init_ok := false


static func run(tree: SceneTree, check: Callable, mode: String) -> void:
	match mode:
		"island_spectrum":
			await _island_spectrum(tree, check)
		"seam":
			await _seam(tree, check)
		"dispersion":
			await _dispersion(tree, check)
		"dispersion_2d":
			await _dispersion(tree, check, Vector2.ONE.normalized())
		"volume":
			await _volume(tree, check)
		"foam":
			await _foam(tree, check)
		"boundary_phase":
			await _boundary_phase(tree, check)
		"breaking_diffusion":
			await _breaking_diffusion(tree, check)
		_:
			check.call(false, "ocean_coastal_probe: unknown mode %s" % mode)


static func _island_spectrum(tree: SceneTree, check: Callable) -> void:
	var demo: Node = (load(SCENE_PATH) as PackedScene).instantiate()
	demo.quality.fallback_tier = OceanQualityProfile.Tier.LOW
	tree.root.add_child(demo)
	if not await _wait_scene(tree, demo):
		check.call(false, "island_spectrum: open ocean did not initialize")
		_release_scene(tree, demo)
		return
	demo.apply_preset(1)
	await _frames(tree, 4)
	demo.set_frozen(true)
	demo.set_process(false)
	demo.set_physics_process(false)
	var open := _sea_state(demo)
	var open_field: PackedFloat32Array = await _fresh_displacement(tree, demo)
	demo.set_process(true)
	demo.set_physics_process(true)
	demo.set_scene_mode(1, false)
	if not await _wait_scene(tree, demo):
		check.call(false, "island_spectrum: island mode did not initialize")
		_release_scene(tree, demo)
		return
	demo.set_frozen(true)
	demo.set_process(false)
	demo.set_physics_process(false)
	var island := _sea_state(demo)
	var island_field: PackedFloat32Array = await _fresh_displacement(tree, demo)
	check.call(is_equal_approx(island.depth, open.depth),
		"entering Island Beach recalibrated the FFT spectrum depth (%.3f m -> %.3f m)"
			% [open.depth, island.depth])
	check.call(absf(island.period - open.period) < 1.0e-9,
		"entering Island Beach changed the effective swell period (%.6f s -> %.6f s)"
			% [open.period, island.period])
	check.call(absf(island.m0 - open.m0) < 1.0e-9 and absf(island.m1 - open.m1) < 1.0e-9
		and absf(island.m2 - open.m2) < 1.0e-9,
		"entering Island Beach changed the spectral moments (m0 %.9f -> %.9f)"
			% [open.m0, island.m0])
	var max_diff := 0.0
	for i in open_field.size():
		max_diff = maxf(max_diff, absf(open_field[i] - island_field[i]))
	check.call(max_diff < 0.002,
		"FFT displacement field changed on island entry at equal time (max diff %.6f)" % max_diff)
	print("OCEAN ISLAND SPEC open_depth=%.3f island_depth=%.3f field_diff=%.6f m0=%.9f period=%.6f" % [
		open.depth, island.depth, max_diff, open.m0, open.period])
	demo.set_process(true)
	demo.set_physics_process(true)
	demo.set_scene_mode(0, false)
	if await _wait_scene(tree, demo):
		check.call(is_equal_approx(demo.solver.water_depth, open.depth),
			"return to Open Ocean did not restore the spectrum depth (%.3f)" % demo.solver.water_depth)
	_release_scene(tree, demo)


static func _seam(tree: SceneTree, check: Callable) -> void:
	var session := _start_solver(-RING_DEPTH_M)
	if not await _solver_ready(tree):
		check.call(false, "seam: shore solver did not initialize")
		_stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	solver.source_depth_m = RING_DEPTH_M
	await _seam_case(tree, session, check, 0, 25, 0.05, 0.05)
	await _seam_case(tree, session, check, 0, SEAM_MODE, 0.05, 0.05)
	# The 111 m cascade must inject too.
	await _write_mode(tree, session, 1, 2)
	await _step_frames(tree, solver, 1)
	var boundary1 := await _read_boundary_layer(solver._boundary_rid, 1)
	var height1 := 0.0
	for i in BOUNDARY_N * BOUNDARY_N:
		height1 = maxf(height1, absf(boundary1[i * 4]))
	check.call(height1 > 0.4,
		"cascade 1 (111 m tile) never injects through the ring boundary (max eta %.4f)" % height1)
	var k1 := TAU * 2.0 / TILES[1]
	var omega1 := sqrt(GRAVITY * k1 * tanh(k1 * RING_DEPTH_M))
	var far := await _record_amplitudes(tree, solver, 12.0, 2.0 * TAU / omega1)
	var far_amplitude := far[31]
	check.call(absf(far_amplitude / INCIDENT_AMP - 1.0) < 0.05,
		"cascade-1 wave amplitude off target in the interior (%.4f m at z=-40)" % far_amplitude)
	_stop_solver(session)


static func _seam_case(tree: SceneTree, session: Dictionary, check: Callable,
		layer: int, mode: int, rupture_gate: float, reflection_gate: float) -> void:
	var solver: OceanShoreSolver = session.solver
	var k := TAU * float(mode) / TILES[layer]
	var kh := k * RING_DEPTH_M
	var omega := sqrt(GRAVITY * k * tanh(kh))
	var c_exact := omega / k
	await _write_mode(tree, session, layer, mode)
	await _step_frames(tree, solver, 1)
	var boundary := await _read_boundary_layer(solver._boundary_rid, layer)
	var height_max := 0.0
	var speed_max := 0.0
	for i in BOUNDARY_N * BOUNDARY_N:
		height_max = maxf(height_max, absf(boundary[i * 4]))
		speed_max = maxf(speed_max, absf(boundary[i * 4 + 2]))
	var expected := omega / (k * RING_DEPTH_M)
	var measured := speed_max / maxf(height_max, 1.0e-6)
	check.call(absf(measured / expected - 1.0) < 0.05,
		"ring orbital velocity ignores source_depth_m (ratio %.3f, expected %.3f)"
			% [measured, expected])
	var wave_period := TAU / omega
	var amplitudes := await _record_amplitudes(tree, solver, 12.0, 3.0 * wave_period, omega)
	var seam_mean := 0.0
	var seam_count := 0
	var envelope_min := INF
	var envelope_max := 0.0
	for row in range(12, 44):
		var amplitude: float = amplitudes[row]
		if row <= 20:
			seam_mean += amplitude
			seam_count += 1
		if row >= 13:
			envelope_min = minf(envelope_min, amplitude)
			envelope_max = maxf(envelope_max, amplitude)
	seam_mean /= maxf(seam_count, 1)
	check.call(absf(seam_mean / INCIDENT_AMP - 1.0) < rupture_gate,
		"incident amplitude ruptures across the rim (interior %.3f m of %.1f m, lambda=%.1f)"
			% [seam_mean, INCIDENT_AMP, TAU / k])
	var reflection := (envelope_max - envelope_min) / maxf(envelope_max + envelope_min, 1.0e-6)
	var reflected_energy := reflection * reflection
	check.call(reflected_energy < reflection_gate,
		"standing-wave reflection exceeds %.0f%% of the incident energy (energy=%.3f, lambda=%.1f)"
			% [reflection_gate * 100.0, reflected_energy, TAU / k])
	var profile := ""
	for row in range(8, 64, 4):
		profile += "%d:%.3f " % [row, amplitudes[row]]
	print("OCEAN SEAM mode=%d lambda=%.2f kh=%.3f boundary_height_max=%.4f interior=%.4f reflection_amplitude=%.4f reflection_energy=%.6f profile %s" % [
		mode, TAU / k, kh, height_max, seam_mean, reflection, reflected_energy, profile])


static func _dispersion(tree: SceneTree, check: Callable, direction := Vector2(0.0, 1.0)) -> void:
	var session := _start_solver(-DISP_DEPTH_M)
	if not await _solver_ready(tree):
		check.call(false, "dispersion: shore solver did not initialize")
		_stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	# Free-wave measurement: seed an exact eigenmode (eta and in-phase flux)
	# on a flat constant-depth bed, let the interior evolve undriven, and fit
	# the modal phase at two late snapshots. The rim reflections need >16 s to
	# return, so the window is clean; a hydrostatic interior reads sqrt(g h)
	# instead of the finite-depth dispersion (+15% to +31% in the tested band).
	# (A boundary-forced variant was replaced: the generation band and the
	# far-rim reflections inside its DFT window biased both phase and
	# amplitude beyond the instrumented thresholds.)
	for wavelength: float in DISP_WAVELENGTHS:
		var k := TAU / wavelength
		var kh := k * DISP_DEPTH_M
		var omega_exact := sqrt(GRAVITY * k * tanh(kh))
		var c_exact := omega_exact / k
		solver.source_depth_m = DISP_DEPTH_M
		solver.reset()
		await _step_frames(tree, solver, 1)
		var seed := PackedFloat32Array()
		seed.resize(N * N * 4)
		for y in N:
			for x in N:
				var phase := k * direction.dot(_world(x, y))
				var eta := DISP_AMPLITUDE * cos(phase)
				var flux := DISP_AMPLITUDE * omega_exact / k * cos(phase)
				var i := (y * N + x) * 4
				seed[i] = DISP_DEPTH_M + eta
				seed[i + 1] = flux * direction.x
				seed[i + 2] = flux * direction.y
		await _seed_state(tree, session, seed)
		# Snapshots after the seed's discrete-transient settles (0.8 s) and
		# 2 s apart; the wave travels ~15 m and stays far from both rims.
		var phases: Array[float] = []
		var amplitudes: Array[float] = []
		var stepped := 0
		for snap_index in 2:
			var frames := int(round((1.0 + 2.0 * float(snap_index)) / DT))
			for frame in frames - stepped:
				RenderingServer.call_on_render_thread(solver.step_render.bind(
					DT, float(stepped + frame + 1) * DT, Vector2.ZERO, 1.0, 0.5,
					PackedVector4Array()))
				await RenderingServer.frame_post_draw
			stepped = frames
			var surface := await _read_layer(solver.get_texture_rid(), 0)
			var gram := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			var sums := Vector3.ZERO
			for row in range(24, 96):
				for col in range(24, 96):
					var phase := k * direction.dot(_world(col, row))
					var basis := Vector3(cos(phase), sin(phase), 1.0)
					gram.x += basis * basis.x
					gram.y += basis * basis.y
					gram.z += basis
					sums += basis * surface[(row * N + col) * 4]
			var fitted := gram.inverse() * sums
			phases.append(atan2(fitted.y, fitted.x))
			amplitudes.append(Vector2(fitted.x, fitted.y).length())
		var dphi := phases[1] - phases[0]
		while dphi > PI:
			dphi -= TAU
		while dphi < -PI:
			dphi += TAU
		var omega_measured := absf(dphi) / 2.0
		var c_measured := omega_measured / k
		check.call(absf(c_measured / c_exact - 1.0) < 0.05,
			"free-wave phase speed on constant depth misses the exact dispersion by %.1f%% (lambda=%.1f m, kh=%.2f)"
				% [absf(c_measured / c_exact - 1.0) * 100.0, wavelength, kh])
		var retention := amplitudes[1] / maxf(amplitudes[0], 1.0e-6)
		check.call(absf(retention - 1.0) < 0.05,
			"free wave changed amplitude by %.1f%% over 2 s (lambda=%.1f m)"
				% [absf(retention - 1.0) * 100.0, wavelength])
		print("OCEAN DISP lambda=%.2f kh=%.3f direction=%s c=%.4f c_exact=%.4f error=%.4f amplitude_ratio=%.4f" % [
			wavelength, kh, direction, c_measured, c_exact, c_measured / c_exact - 1.0, retention])
		solver.reset()
	print("OCEAN DISP done")
	_stop_solver(session)


static func _volume(tree: SceneTree, check: Callable) -> void:
	var session := _start_solver(0.0)
	if not await _solver_ready(tree):
		check.call(false, "volume: shore solver did not initialize")
		_stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	# Closed basin: wall bed, a traveling pulse, 30 s of sloshing.
	solver.config.open_boundaries_enabled = false
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	for y in N:
		for x in N:
			var p := _world(x, y)
			bed[y * N + x] = 10.0 if maxf(absf(p.x), absf(p.y)) > 62.0 else -2.0
	RenderingServer.call_on_render_thread(func(): solver.set_bathymetry(bed))
	await RenderingServer.frame_post_draw
	solver.reset()
	await _step_frames(tree, solver, 1)
	var seed := PackedFloat32Array()
	seed.resize(N * N * 4)
	var initial := 0.0
	for y in N:
		for x in N:
			var i := y * N + x
			var p := _world(x, y)
			var pulse := 0.6 * exp(-pow((p.x + 12.0) / 7.0, 2.0) - pow(p.y / 10.0, 2.0))
			var h := maxf(pulse - bed[i], 0.0)
			seed[i * 4] = h
			seed[i * 4 + 1] = h * pulse * sqrt(GRAVITY / maxf(h, 0.01))
			initial += h * CELL * CELL
	await _seed_state(tree, session, seed)
	await _step_frames(tree, solver, 900)
	var after := await _state_mass(tree, session)
	var drift := (after - initial) / initial
	check.call(absf(drift) < 0.01, "closed-domain volume drifted by %.3f%% over 30 s" % (drift * 100.0))
	print("OCEAN VOL closed_initial=%.3f closed_after=%.3f drift=%.6f" % [initial, after, drift])
	# Open domain: flat ring-depth bed, continuous monochromatic injection.
	solver.config.open_boundaries_enabled = true
	var flat := PackedFloat32Array()
	flat.resize(N * N)
	flat.fill(-RING_DEPTH_M)
	RenderingServer.call_on_render_thread(func(): solver.set_bathymetry(flat))
	await RenderingServer.frame_post_draw
	solver.reset()
	await _step_frames(tree, solver, 1)
	solver.source_depth_m = RING_DEPTH_M
	await _write_mode(tree, session, 0, SEAM_MODE)
	RenderingServer.call_on_render_thread(solver.step_render.bind(0.0, 0.0,
		Vector2.ZERO, 0.0, 0.0, PackedVector4Array()))
	await RenderingServer.frame_post_draw
	var reference := await _state_mass(tree, session)
	await _step_frames(tree, solver, 900)
	var result := {"mass": 0.0, "balance": PackedFloat32Array()}
	RenderingServer.call_on_render_thread(func():
		var control: PackedByteArray = session.rd.buffer_get_data(solver._buffers.control)
		var index: int = control.decode_u32(16)
		var state: PackedFloat32Array = session.rd.buffer_get_data(solver._buffers.state,
			index * N * N * 16, N * N * 16).to_float32_array()
		var mass := 0.0
		for i in N * N:
			mass += state[i * 4]
		result.mass = mass * CELL * CELL
		result.balance = session.rd.buffer_get_data(solver._buffers.balance).to_float32_array()
	)
	await RenderingServer.frame_post_draw
	var boundary_volume := 0.0
	var sponge_volume := 0.0
	var clipping_volume := 0.0
	for i in N * N:
		boundary_volume += result.balance[i * 4]
		sponge_volume += result.balance[i * 4 + 1]
		clipping_volume += result.balance[i * 4 + 2]
	var closure := absf(result.mass - reference - boundary_volume - sponge_volume - clipping_volume)
	check.call(closure / reference < 0.01,
		"open-domain volume budget does not close within 1%% (error %.3f m3)" % closure)
	check.call(absf(boundary_volume) + absf(sponge_volume) > 1.0,
		"open-domain budget did not exercise boundary or sponge exchange")
	print("OCEAN VOL open_initial=%.3f open_mass=%.3f boundary=%.3f sponge=%.3f clipping=%.6f closure=%.6f" % [
		reference, result.mass, boundary_volume, sponge_volume, clipping_volume, closure])
	_stop_solver(session)


# ---------------------------------------------------------------- helpers --

static func _foam(tree: SceneTree, check: Callable) -> void:
	var session := _start_solver(-RING_DEPTH_M)
	if not await _solver_ready(tree):
		check.call(false, "foam: shore solver did not initialize")
		await _stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	solver.source_depth_m = RING_DEPTH_M
	var seeded := PackedFloat32Array()
	seeded.resize(N * N * 4)
	for i in N * N:
		seeded[i * 4 + 1] = RING_DEPTH_M * 0.4
	RenderingServer.call_on_render_thread(func():
		var bytes := seeded.to_byte_array()
		bytes.append_array(seeded.to_byte_array())
		for name in ["foam", "completed_foam"]:
			session.rd.buffer_update(solver._buffers[name], 0, bytes.size(), bytes)
	)
	await RenderingServer.frame_post_draw
	for frame in 30:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 0.0, 0.0, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var retained := await _read_layer(solver.get_foam_texture_rid(), 0)
	var band := retained[(64 * N + 121) * 4 + 1]
	var inner := retained[(64 * N + 64) * 4 + 1]
	check.call(absf(band / 0.4 - 1.0) <= 0.01,
		"foam: sponge erased persistent coverage at rest (%.6f of 0.4)" % band)
	check.call(absf(inner / 0.4 - 1.0) <= 0.01,
		"foam: interior persistent coverage changed with zero decay (%.6f of 0.4)" % inner)
	print("OCEAN FOAM retention time_s=1.0 band=%.6f interior=%.6f" % [band, inner])
	solver.reset()
	await _step_frames(tree, solver, 1)
	var uniform := PackedFloat32Array()
	uniform.resize(N * N * 4)
	for i in N * N:
		uniform[i * 4] = RING_DEPTH_M
		uniform[i * 4 + 1] = RING_DEPTH_M * 15.0
	await _seed_state(tree, session, uniform)
	for frame in 30:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2(15.0, 0.0), 8.0, 0.2, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var uniform_foam := await _read_layer(solver.get_foam_texture_rid(), 0)
	var uniform_coverage := maxf(uniform_foam[(64 * N + 64) * 4], uniform_foam[(64 * N + 64) * 4 + 1])
	check.call(uniform_coverage < 1.0e-5,
		"foam: uniform supercritical current generated spontaneous foam (%.6f)" % uniform_coverage)
	print("OCEAN FOAM uniform_current time_s=1.0 current_m_s=15 depth_m=16 interior_coverage=%.9f" % uniform_coverage)
	solver.reset()
	await _step_frames(tree, solver, 1)
	await _write_strain(session, -0.2)
	for frame in 60:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 0.0, 0.2, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var disabled := await _read_layer(solver.get_foam_texture_rid(), 0)
	var disabled_max := 0.0
	for i in N * N:
		disabled_max = maxf(disabled_max, maxf(disabled[i * 4], disabled[i * 4 + 1]))
	check.call(disabled_max <= 1.0e-6,
		"foam: zero foam_amount still generated coverage (%.6f)" % disabled_max)
	solver.reset()
	RenderingServer.call_on_render_thread(solver.step_render.bind(
		0.0, 0.0, Vector2.ZERO, 0.0, 0.2, PackedVector4Array()))
	await RenderingServer.frame_post_draw
	await _write_strain(session, -0.0625)
	for frame in 60:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 8.0, 0.2, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var generated := await _read_layer(solver.get_foam_texture_rid(), 0)
	var generated_band := generated[(64 * N + 121) * 4]
	var generated_inner := generated[(64 * N + 64) * 4]
	var density := (solver.whitecap_threshold - 0.8125) * 8.0 * 7.5 / 2.3 * (1.0 - exp(-2.3 * 2.0))
	var value := density * 0.75
	var expected := value * value * (3.0 - 2.0 * value)
	check.call(generated_band > 0.01 and generated_inner > 0.01,
		"foam: combined FFT strain did not generate whitecaps (band %.6f, interior %.6f)"
			% [generated_band, generated_inner])
	check.call(absf(generated_band / maxf(generated_inner, 1.0e-8) - 1.0) <= 0.01,
		"foam: sponge suppressed generated whitecaps relative to the interior")
	check.call(absf(generated_inner / expected - 1.0) <= 0.05,
		"foam: coverage differs from the offshore rate model (%.6f vs %.6f)" % [generated_inner, expected])
	print("OCEAN FOAM source time_s=2.0 requested_amount=8 applied_amount=8 decay_s_inv=0.2 disabled_max=%.6f band=%.6f interior=%.6f grid=%d cell_m=%.3f vram_bytes=%d gpu_ms=unavailable" % [
		disabled_max, generated_band, generated_inner, N, CELL, solver.estimate_vram_bytes()])
	await _stop_solver(session)


static func _write_strain(session: Dictionary, strain_x: float) -> void:
	RenderingServer.call_on_render_thread(func():
		var values := PackedFloat32Array()
		values.resize(N * N * 4)
		for i in N * N:
			values[i * 4] = strain_x
		var image := Image.create_from_data(N, N, false, Image.FORMAT_RGBAF, values.to_byte_array())
		image.convert(Image.FORMAT_RGBAH)
		for layer in 3:
			session.rd.texture_update(session.breaking, layer, image.get_data())
	)
	await RenderingServer.frame_post_draw


static func _boundary_phase(tree: SceneTree, check: Callable) -> void:
	var session := _start_solver(-RING_DEPTH_M)
	if not await _solver_ready(tree):
		check.call(false, "boundary_phase: shore solver did not initialize")
		await _stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	solver.source_depth_m = RING_DEPTH_M
	solver.spectrum_depth_m = 80.0
	var mode := 10
	var k := TAU * float(mode) / TILES[0]
	var expected := sqrt(GRAVITY * k * tanh(k * solver.spectrum_depth_m))
	var local_k := k
	for iteration in 8:
		var th := tanh(local_k * RING_DEPTH_M)
		var derivative := GRAVITY * (th + local_k * RING_DEPTH_M * (1.0 - th * th))
		local_k -= (GRAVITY * local_k * th - expected * expected) / derivative
	var expected_ratio := expected / (local_k * RING_DEPTH_M)
	var measured_ratio := 0.0
	await _write_mode(tree, session, 0, mode)
	var phases: Array[float] = []
	for frame in 61:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 0.0, 0.0, PackedVector4Array()))
		await RenderingServer.frame_post_draw
		if frame == 0 or frame == 60:
			var field := await _read_boundary_layer(solver._boundary_rid, 0)
			if frame == 60:
				var max_height := 0.0
				var max_speed := 0.0
				for i in BOUNDARY_N * BOUNDARY_N:
					max_height = maxf(max_height, absf(field[i * 4]))
					max_speed = maxf(max_speed, absf(field[i * 4 + 2]))
				measured_ratio = max_speed / maxf(max_height, 1.0e-8)
			var c := 0.0
			var s := 0.0
			for row in BOUNDARY_N:
				var spatial := TAU * float(mode * row) / float(BOUNDARY_N)
				c += field[(row * BOUNDARY_N) * 4] * cos(spatial)
				s += field[(row * BOUNDARY_N) * 4] * sin(spatial)
			check.call(c * c + s * s > 1.0,
				"boundary_phase: incident eigenmode is absent")
			phases.append(atan2(s, c))
	var measured := absf(wrapf(phases[1] - phases[0], -PI, PI)) / 2.0
	var error := absf(measured / expected - 1.0)
	check.call(error <= 0.05,
		"boundary_phase: shore injection changes offshore frequency by %.2f%%" % (error * 100.0))
	check.call(absf(measured_ratio / expected_ratio - 1.0) <= 0.05,
		"boundary_phase: velocity uses the offshore wave number in the shallow ring (%.6f vs %.6f)"
			% [measured_ratio, expected_ratio])
	print("OCEAN PHASE flux velocity_per_height=%.6f expected=%.6f local_k_m_inv=%.6f" % [
		measured_ratio, expected_ratio, local_k])
	print("OCEAN PHASE scenario=depth_transition seed=synthetic mode=%d offshore_depth_m=80 ring_depth_m=%.1f expected_rad_s=%.6f measured_rad_s=%.6f relative_error=%.6f time_s=%.6f grid=%d vram_bytes=%d gpu_ms=unavailable" % [
		mode, RING_DEPTH_M, expected, measured, error, 61.0 * DT, N, solver.estimate_vram_bytes()])
	await _stop_solver(session)


static func _breaking_diffusion(tree: SceneTree, check: Callable) -> void:
	var depth := 2.0
	var session := _start_solver(-depth)
	if not await _solver_ready(tree):
		check.call(false, "breaking_diffusion: shore solver did not initialize")
		await _stop_solver(session)
		return
	var solver: OceanShoreSolver = session.solver
	solver.source_depth_m = depth
	solver.spectrum_depth_m = depth
	var k := TAU / 20.0
	var seed := PackedFloat32Array()
	seed.resize(N * N * 4)
	for y in N:
		var z := _world(0, y).y
		for x in N:
			var i := (y * N + x) * 4
			seed[i] = depth
			seed[i + 1] = depth * (10.0 + 0.5 * cos(k * z))
	await _seed_state(tree, session, seed)
	for frame in 30:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2(10.0, 0.0), 0.0, 0.0, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var result := {"state": PackedByteArray(), "control": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var control: PackedByteArray = session.rd.buffer_get_data(solver._buffers.control, 0, 64)
		var index := control.decode_u32(16)
		result.control = control
		result.state = session.rd.buffer_get_data(solver._buffers.state, index * N * N * 16, N * N * 16)
	)
	await RenderingServer.frame_post_draw
	var state: PackedFloat32Array = result.state.to_float32_array()
	var c := 0.0
	var s := 0.0
	for row in range(32, 96):
		var i := (row * N + 64) * 4
		var u := state[i + 1] / maxf(state[i], 1.0e-8)
		var z := _world(64, row).y
		c += u * cos(k * z)
		s += u * sin(k * z)
	var amplitude := 2.0 * sqrt(c * c + s * s) / 64.0
	var physical_time: float = result.control.decode_float(0)
	var viscosity := solver.config.eddy_coefficient * depth * sqrt(GRAVITY * depth)
	var upper_amplitude := 0.5 * exp(-viscosity * k * k) * 1.05
	check.call(is_finite(amplitude) and amplitude > 0.1 and amplitude < upper_amplitude,
		"breaking_diffusion: viscosity amplified the shear mode (amplitude %.6f from 0.5 m/s)" % amplitude)
	check.call(absf(physical_time - 1.0) < 0.001,
		"breaking_diffusion: solver failed to advance one second (actual %.6f s)" % physical_time)
	print("OCEAN BREAK scenario=transverse_shear seed=analytic depth_m=2 current_m_s=10 wavelength_m=20 initial_amplitude_m_s=0.5 final_amplitude_m_s=%.6f physical_time_s=%.6f requested_time_s=1 grid=%d cell_m=%.3f vram_bytes=%d gpu_ms=unavailable" % [
		amplitude, physical_time, N, CELL, solver.estimate_vram_bytes()])
	await _stop_solver(session)


static func _start_solver(bed_depth: float) -> Dictionary:
	var session := {"solver": null, "rd": null, "spectrum": RID(), "breaking": RID()}
	_ready = false
	_init_ok = false
	RenderingServer.call_on_render_thread(func():
		var rd := GpuPreflight.device("OceanCoastalProbe")
		if rd == null:
			_ready = true
			return
		var format := RDTextureFormat.new()
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
		format.width = N
		format.height = N
		format.array_layers = 3
		format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var spectrum := rd.texture_create(format, RDTextureView.new(), [])
		rd.texture_clear(spectrum, Color(0, 0, 0, 0), 0, 1, 0, 3)
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		var breaking := rd.texture_create(format, RDTextureView.new(), [])
		rd.texture_clear(breaking, Color(0, 0, 0, 0), 0, 1, 0, 3)
		var solver := ShoreSolver.new()
		var bed := PackedFloat32Array()
		bed.resize(N * N)
		bed.fill(bed_depth)
		_init_ok = solver.init_render(spectrum, N, TILES, 0, bed, breaking)
		session.solver = solver
		session.rd = rd
		session.spectrum = spectrum
		session.breaking = breaking
		_ready = true
	)
	return session


static func _solver_ready(tree: SceneTree) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		if _ready:
			return _init_ok
	return false


static func _stop_solver(session: Dictionary) -> void:
	RenderingServer.call_on_render_thread(func():
		var solver: OceanShoreSolver = session.solver
		var rd: RenderingDevice = session.rd
		var spectrum: RID = session.spectrum
		if solver != null:
			solver.free_render()
		if spectrum.is_valid():
			rd.free_rid(spectrum)
		if session.breaking.is_valid():
			rd.free_rid(session.breaking)
		session.breaking = RID()
		session.solver = null
		session.spectrum = RID()
	)
	await RenderingServer.frame_post_draw


static func _write_mode(_tree: SceneTree, session: Dictionary, layer: int, mode: int) -> void:
	RenderingServer.call_on_render_thread(func():
		var rd: RenderingDevice = session.rd
		var spectrum: RID = session.spectrum
		var solver: OceanShoreSolver = session.solver
		rd.texture_clear(spectrum, Color(0, 0, 0, 0), 0, 1, 0, 3)
		var wave := PackedFloat32Array()
		wave.resize(N * N * 4)
		var positive := Vector2i(N / 2 + mode, N / 2)
		var negative := Vector2i(N / 2 - mode, N / 2)
		wave[(positive.y * N + positive.x) * 4] = AMP
		wave[(negative.y * N + negative.x) * 4 + 2] = AMP
		rd.texture_update(spectrum, layer, wave.to_byte_array())
		solver.reset()
	)
	await RenderingServer.frame_post_draw


static func _step_frames(tree: SceneTree, solver: OceanShoreSolver, count: int) -> void:
	for frame in count:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 1.0, 0.5, PackedVector4Array()))
		await RenderingServer.frame_post_draw


static func _record_amplitudes(tree: SceneTree, solver: OceanShoreSolver,
		settle_s: float, window_s: float, omega: float = 0.0) -> PackedFloat32Array:
	var rows: PackedFloat32Array = []
	rows.resize(N)
	var minimum: PackedFloat32Array = []
	var maximum: PackedFloat32Array = []
	minimum.resize(N)
	maximum.resize(N)
	var height_fit: Array[Vector3] = []
	var flux_fit: Array[Vector3] = []
	height_fit.resize(N)
	flux_fit.resize(N)
	height_fit.fill(Vector3.ZERO)
	flux_fit.fill(Vector3.ZERO)
	var gram := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	for row in N:
		minimum[row] = INF
		maximum[row] = -INF
	var settle := int(ceil(settle_s / DT))
	var samples := int(ceil(window_s * SAMPLE_HZ))
	var frame := 0
	while frame < settle + samples * SAMPLE_EVERY:
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			DT, float(frame + 1) * DT, Vector2.ZERO, 1.0, 0.5, PackedVector4Array()))
		if frame >= settle and (frame - settle) % SAMPLE_EVERY == 0:
			var surface := await _read_layer(solver.get_texture_rid(), 0)
			var basis := Vector3(cos(omega * float(frame) * DT), sin(omega * float(frame) * DT), 1.0)
			gram.x += basis * basis.x
			gram.y += basis * basis.y
			gram.z += basis
			for row in N:
				var eta := surface[(row * N + 64) * 4]
				minimum[row] = minf(minimum[row], eta)
				maximum[row] = maxf(maximum[row], eta)
				height_fit[row] += basis * eta
				flux_fit[row] += basis * surface[(row * N + 64) * 4 + 2] * surface[(row * N + 64) * 4 + 3]
		await RenderingServer.frame_post_draw
		frame += 1
	for row in N:
		rows[row] = (maximum[row] - minimum[row]) * 0.5
	if omega > 0.0:
		var inverse := gram.inverse()
		var k := omega * omega / GRAVITY
		for iteration in 12:
			var th := tanh(k * RING_DEPTH_M)
			k -= (GRAVITY * k * th - omega * omega) / (GRAVITY * (th + k * RING_DEPTH_M * (1.0 - th * th)))
		var c := omega / k
		var incident_mean := 0.0
		var incident_energy := 0.0
		var reflected_energy := 0.0
		for row in range(12, 44):
			var height := inverse * height_fit[row]
			var flux := inverse * flux_fit[row] / c
			var incoming := Vector2(height.x + flux.x, height.y + flux.y) * 0.5
			var outgoing := Vector2(height.x - flux.x, height.y - flux.y) * 0.5
			if row <= 20:
				incident_mean += incoming.length() / 9.0
			incident_energy += incoming.length_squared()
			reflected_energy += outgoing.length_squared()
		print("OCEAN SEAM harmonic omega_rad_s=%.6f incident_mean_m=%.6f reflected_energy_ratio=%.6f" % [
			omega, incident_mean, reflected_energy / maxf(incident_energy, 1.0e-8)])
	return rows


static func _read_layer(rid: RID, layer: int) -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(rid, layer, N * N * 16)
	return bytes.to_float32_array()


static func _read_boundary_layer(rid: RID, layer: int) -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(rid, layer, BOUNDARY_N * BOUNDARY_N * 16)
	return bytes.to_float32_array()


static func _seed_state(_tree: SceneTree, session: Dictionary, data: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(func():
		var solver: OceanShoreSolver = session.solver
		solver.step_render(0.0, 0.0, Vector2.ZERO, 0.0, 0.0, PackedVector4Array())
		var bytes := data.to_byte_array()
		var doubled := bytes.duplicate()
		doubled.append_array(bytes)
		var rd: RenderingDevice = session.rd
		for name in ["state", "completed_state"]:
			rd.buffer_update(solver._buffers[name], 0, doubled.size(), doubled)
	)
	await RenderingServer.frame_post_draw


static func _state_mass(_tree: SceneTree, session: Dictionary) -> float:
	var mass := {"value": 0.0}
	RenderingServer.call_on_render_thread(func():
		var solver: OceanShoreSolver = session.solver
		var control: PackedByteArray = session.rd.buffer_get_data(solver._buffers.control)
		var index: int = control.decode_u32(16)
		var state: PackedFloat32Array = session.rd.buffer_get_data(solver._buffers.state,
			index * N * N * 16, N * N * 16).to_float32_array()
		var sum := 0.0
		for i in N * N:
			sum += state[i * 4]
		mass.value = sum * CELL * CELL
	)
	await RenderingServer.frame_post_draw
	return mass.value


static func _world(x: int, y: int) -> Vector2:
	return (Vector2(x, y) + Vector2(0.5, 0.5)) * CELL - Vector2.ONE * DOMAIN * 0.5


static func _sea_state(demo: Node) -> Dictionary:
	var moments: Dictionary = demo.solver.physical_moments()
	return {
		"depth": float(demo.solver.water_depth),
		"period": float(demo.solver.effective_swell_period()),
		"m0": float(moments.get("m0", 0.0)),
		"m1": float(moments.get("m1", 0.0)),
		"m2": float(moments.get("m2", 0.0)),
	}


static func _fresh_displacement(_tree: SceneTree, demo: Node) -> PackedFloat32Array:
	RenderingServer.call_on_render_thread(func():
		demo.solver.initialized = false
		demo.solver.init_render()
	)
	await RenderingServer.frame_post_draw
	await _frames(Engine.get_main_loop() as SceneTree, 2)
	RenderingServer.call_on_render_thread(demo.solver.step_render.bind(DT, DT, Vector2.ZERO))
	await RenderingServer.frame_post_draw
	var n: int = demo.solver.map_size
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(
		demo.solver.get_displacement_tex_rid(), 0, n * n * 8)
	var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBAH, bytes)
	image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array()


static func _wait_scene(tree: SceneTree, demo: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		if demo.capture_ready() and demo.solver.initialized and demo.texture_bound:
			return true
	return false


static func _release_scene(tree: SceneTree, demo: Node) -> void:
	demo.queue_free()
	await tree.process_frame
	await RenderingServer.frame_post_draw


static func _frames(tree: SceneTree, count: int) -> void:
	for i in count:
		await tree.process_frame


static func run_dispersive_convergence(tree: SceneTree, check: Callable, anderson_depth: int = 0) -> void:
	var demo: Node = (load(SCENE_PATH) as PackedScene).instantiate()
	demo.quality.fallback_tier = OceanQualityProfile.Tier.MEDIUM
	tree.root.add_child(demo)
	if not await _wait_scene(tree, demo):
		check.call(false, "dispersive convergence: ocean scene did not initialize")
		await _release_scene(tree, demo)
		return
	demo.set_process(false)
	demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	var medium_ready := false
	for _frame in 180:
		await RenderingServer.frame_post_draw
		if demo.solver.initialized and demo.solver.quality_tier == OceanQualityProfile.Tier.MEDIUM:
			medium_ready = true
			break
	if not medium_ready:
		check.call(false, "dispersive convergence: medium quality did not initialize")
		await _release_scene(tree, demo)
		return
	demo.set_capture_scene(1)
	demo.set_capture_view("coast")
	var coast_ready := false
	for _frame in 180:
		await RenderingServer.frame_post_draw
		if demo.solver.initialized and demo.solver.shore_enabled \
				and demo.solver.shore_solver._initialized:
			coast_ready = true
			break
	if not coast_ready:
		check.call(false, "dispersive convergence: island coast did not initialize")
		await _release_scene(tree, demo)
		return
	demo.apply_preset(3)
	demo.set_capture_height_gain(5.0)
	demo.set_capture_time(0.0)
	demo.set_time_scale(1.0)
	var physical_time := 0.0
	var stepped_frames := 0
	for _frame in 450:
		demo._process(DT)
		await RenderingServer.frame_post_draw
		stepped_frames += 1
	var progress := {}
	RenderingServer.call_on_render_thread(func():
		var bytes: PackedByteArray = demo.solver.shore_solver._rd.buffer_get_data(
			demo.solver.shore_solver._buffers.control, 0, 4)
		progress["physical_time_s"] = bytes.decode_float(0)
	)
	await RenderingServer.frame_post_draw
	physical_time = float(progress.get("physical_time_s", 0.0))
	while physical_time < 14.99 and stepped_frames < 480:
		for _frame in mini(5, 480 - stepped_frames):
			demo._process(DT)
			await RenderingServer.frame_post_draw
			stepped_frames += 1
		progress.clear()
		RenderingServer.call_on_render_thread(func():
			var bytes: PackedByteArray = demo.solver.shore_solver._rd.buffer_get_data(
				demo.solver.shore_solver._buffers.control, 0, 4)
			progress["physical_time_s"] = bytes.decode_float(0)
		)
		await RenderingServer.frame_post_draw
		physical_time = float(progress.get("physical_time_s", 0.0))
	demo.set_frozen(true)
	demo.set_physics_process(false)
	await RenderingServer.frame_post_draw
	var coast: OceanShoreSolver = demo.solver.shore_solver
	var budgets: Array[int] = [1, 2, 4, 6, 12]
	var sample := {}
	RenderingServer.call_on_render_thread(func():
		var state_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.state)
		var accel_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.accel)
		var disp_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.disp)
		var brk_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.brk)
		var diagnostic_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.disp_diagnostic)
		var control_before: PackedByteArray = coast._rd.buffer_get_data(coast._buffers.control)
		sample.merge(coast.diagnose_dispersive_budgets_render(budgets, anderson_depth), true)
		sample["state_preserved"] = state_before == coast._rd.buffer_get_data(coast._buffers.state) \
			and accel_before == coast._rd.buffer_get_data(coast._buffers.accel) \
			and disp_before == coast._rd.buffer_get_data(coast._buffers.disp) \
			and brk_before == coast._rd.buffer_get_data(coast._buffers.brk) \
			and diagnostic_before == coast._rd.buffer_get_data(coast._buffers.disp_diagnostic) \
			and control_before == coast._rd.buffer_get_data(coast._buffers.control)
	)
	await RenderingServer.frame_post_draw
	print("OCEAN DISP BUDGETS scenario=Storm_height_gain_5 seed=production method=%s anderson_depth=%d grid=%d cell_m=%.3f requested_height_gain=5 effective_height_gain=%.3f controller_time_s=%.6f coast_time_s=%.6f steps=%d dt_s=%.9f time_scale=1 iterations=%s rhs_source=%s initial_guess=%s initial_residual=%.9f state_preserved=%s memory=%s gpu_timing=%s" % [
		str(sample.get("method", "unavailable")), int(sample.get("anderson_depth", anderson_depth)),
		int(sample.get("grid_size", 0)), DOMAIN / float(maxi(int(sample.get("grid_size", 1)), 1)),
		demo.solver.effective_height_gain(), demo._sim_time,
		float(sample.get("physical_time_s", 0.0)), stepped_frames, DT, str(budgets),
		str(sample.get("rhs_source", "unavailable")), str(sample.get("initial_guess", "unavailable")),
		float(sample.get("initial_residual", INF)), str(sample.get("state_preserved", false)),
		str(sample.get("memory", "unavailable")), str(sample.get("gpu_timing", "unavailable"))])
	for history: Dictionary in sample.get("histories", []):
		print("OCEAN DISP HISTORY budget=%d residuals=%s final=%.9f contraction=%.9f anderson_updates=%d rank_rejections=%d" % [
			int(history.budget), str(history.residuals), float(history.final_residual),
			float(history.contraction), int(history.get("anderson_updates", 0)),
			int(history.get("rank_rejections", 0))])
		for residual: float in history.residuals:
			check.call(is_finite(residual), "dispersive convergence: non-finite residual")
	check.call(physical_time >= 14.99 and stepped_frames <= 480 \
		and bool(sample.get("state_preserved", false)) \
		and sample.get("histories", []).size() == budgets.size(),
		"dispersive convergence: wrong 15 s Storm height-gain 5 capture state or diagnostics changed it")
	await _release_scene(tree, demo)
