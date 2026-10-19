extends "res://tests/test_case.gd"


func _initialize() -> void:
	_test_black_hole_bounds()
	_test_ring_bounds()
	_test_collision_core_center_of_mass()
	_test_collision_escape_speed_ratio_tracks_g()
	_test_seed_reproducibility_and_variation()
	_test_pulsar_seed_stays_inside_escape_radius()
	_test_scene_render_bounds()
	_test_added_scene_models()
	_test_step_snapshot()
	_finish("nbody_values")


func _test_black_hole_bounds() -> void:
	var scene := BlackHoleScene.new()
	scene.bh_radius = 10.0
	scene.r_min = 3.0
	scene.r_max = 10.0
	scene.normalize_params()
	var solver := NBodySolver.new()
	scene.apply_defaults(solver)
	_check(scene.r_min >= scene.bh_radius * 2.0
		and scene.r_max >= scene.r_min * 1.5,
		"black-hole disk bounds must clear the absorb radius and remain ordered")
	_check(is_equal_approx(solver.disk_r_min, scene.r_min)
		and is_equal_approx(solver.disk_r_max, scene.r_max),
		"black-hole defaults must use the normalized disk bounds")
	_check(is_equal_approx(scene.attractors(solver)[0].radius, scene.bh_radius),
		"black-hole absorb radius must match the event-horizon visual")


func _test_ring_bounds() -> void:
	var scene := PlanetRingsScene.new()
	scene.ring_inner = 20.0
	scene.ring_outer = 8.0
	scene.moon_orbit = 5.0
	scene.normalize_params()
	var solver := NBodySolver.new()
	scene.apply_defaults(solver)
	_check(scene.ring_outer >= scene.ring_inner + 1.0,
		"ring inner and outer bounds must stay ordered")
	_check(scene.moon_orbit > scene.ring_inner * 0.45 + 0.3,
		"the inner moon orbit must clear the planet absorb radius")
	_check(is_equal_approx(solver.disk_r_min, scene.ring_inner)
		and is_equal_approx(solver.disk_r_max, scene.ring_outer),
		"ring force and respawn bounds must match the sliders")


func _test_collision_core_center_of_mass() -> void:
	var scene := GalaxyCollisionScene.new()
	var solver := NBodySolver.new()
	var sources := scene.attractors(solver)
	for t in [0.02, 0.06, 0.15, 0.4]:
		scene.update_attractors(t, sources, solver)
		var center_of_mass: Vector3 = (sources[0].pos * scene.mass_a
			+ sources[1].pos * scene.mass_b) / (scene.mass_a + scene.mass_b)
		_check(center_of_mass.length() < 1e-4,
			"CPU DKD core motion must preserve the barycentric frame")
		_check(is_finite(sources[0].pos.x) and is_finite(sources[1].pos.x),
			"CPU DKD core motion must remain finite")


func _test_collision_escape_speed_ratio_tracks_g() -> void:
	var scene := GalaxyCollisionScene.new()
	var solver := NBodySolver.new()
	solver.gravity_constant = 1.0
	var sources := scene.attractors(solver)
	var speed_g1: float = (sources[1].vel - sources[0].vel).length()
	var distance := sqrt(scene.start_distance * scene.start_distance
		+ scene.impact_offset * scene.impact_offset
		+ scene.core_softening * scene.core_softening)
	var expected := scene.approach_speed_ratio * sqrt(
		2.0 * solver.gravity_constant * (scene.mass_a + scene.mass_b) / distance)
	_check(is_equal_approx(speed_g1, expected),
		"collision approach speed must match the softened escape-speed ratio")
	solver.gravity_constant = 4.0
	sources = scene.attractors(solver)
	_check(is_equal_approx((sources[1].vel - sources[0].vel).length(), speed_g1 * 2.0),
		"collision initial speed must scale with sqrt(G)")


func _test_seed_reproducibility_and_variation() -> void:
	var scene := PlanetRingsScene.new()
	var solver := NBodySolver.new()
	scene.apply_defaults(solver)
	var first := scene.seed(32, solver, 0)
	var replay := scene.seed(32, solver, 0)
	var next := scene.seed(32, solver, 1)
	_check(first.positions == replay.positions and first.velocities == replay.velocities,
		"a repeated scene seed must recreate positions and velocities exactly")
	_check(first.positions != next.positions,
		"a new scene seed must change the deterministic initial sample")


func _test_pulsar_seed_stays_inside_escape_radius() -> void:
	var scene := PulsarScene.new()
	scene.nebula_radius = 200.0
	scene.jet_speed = 8.0
	var solver := NBodySolver.new()
	scene.apply_defaults(solver)
	var initial := scene.seed(4096, solver, 0)
	var inside_escape_radius := true
	for i in 4096:
		var offset := i * 4
		var p := Vector3(initial.positions[offset], initial.positions[offset + 1],
			initial.positions[offset + 2])
		if p.length() > solver.escape_radius:
			inside_escape_radius = false
			break
	_check(inside_escape_radius,
		"pulsar prefill positions must stay inside the rendered escape domain")
	var camera_half_fov := deg_to_rad(30.0)
	_check(scene.view_distance(solver) * sin(camera_half_fov)
		>= scene.nebula_radius * 1.19,
		"pulsar camera fit must contain the nebula sphere with a margin")


func _test_scene_render_bounds() -> void:
	var scene := BlackHoleScene.new()
	scene.r_max = 160.0
	var solver := NBodySolver.new()
	scene.apply_defaults(solver)
	var bounds := scene.render_bounds(solver, scene.attractors(solver))
	_check(bounds.position.x <= -solver.escape_radius
		and bounds.end.x >= solver.escape_radius
		and solver.escape_radius == 640.0,
		"black-hole MultiMesh bounds must include the maximum escape domain")
	var vortex := VortexScene.new()
	vortex.height = 100.0
	vortex.apply_defaults(solver)
	var vortex_bounds := vortex.render_bounds(solver, [])
	_check(vortex_bounds.position.y <= -75.0 and vortex_bounds.end.y >= 75.0,
		"vortex bounds must cover the full top and side respawn field")
	var fireworks := FireworkScene.new()
	fireworks.period = 70.0
	fireworks.burst_speed = 20.0
	fireworks.gravity_strength = 3.0
	fireworks.spread = 50.0
	fireworks.air_drag = 0.1
	fireworks.normalize_params()
	fireworks.apply_defaults(solver)
	var firework_bounds := fireworks.render_bounds(solver, [])
	var early_focus := fireworks.view_target(solver, 13.65)
	var late_focus := fireworks.view_target(solver, 58.5)
	_check(early_focus == late_focus and firework_bounds.has_point(early_focus),
		"firework camera focus must stay fixed and inside the render bounds")
	var age := minf(fireworks.period * 1.25 * 0.54, 23.0)
	var drag := 0.04 + 0.08 * fireworks.air_drag
	var speed := fireworks.burst_speed * 1.14 * 1.22
	var radius := log(1.0 + drag * speed * age) / drag
	var xz := fireworks.spread * 1.175 + radius
	var low := minf(0.0, fireworks.spread * 2.2 - radius
		- 0.045 * fireworks.gravity_strength * age * age)
	_check(firework_bounds.position.x <= -xz
		and firework_bounds.end.x >= xz
		and firework_bounds.position.y <= low
		and firework_bounds.end.y >= fireworks.spread * 2.6 + radius,
		"analytic firework bounds must contain launch and maximum shell expansion")
	var half_height := maxf(absf(firework_bounds.position.y - early_focus.y),
		absf(firework_bounds.end.y - early_focus.y))
	_check(fireworks.view_distance(solver) * sin(deg_to_rad(30.0))
		>= half_height * 1.05,
		"firework Frame distance must fit the launch and burst envelope")


func _test_added_scene_models() -> void:
	var solver := NBodySolver.new()
	var planetary := PlanetarySystemScene.new()
	planetary.apply_defaults(solver)
	var planets := planetary.attractors(solver)
	var first_orbit: float = planetary.PLANET_ORBITS[0]
	_check(planets.size() == 5
		and is_equal_approx(planets[1].pos.length(), first_orbit),
		"planetary system must expose a central star and four bounded orbits")
	var circular_speed := sqrt(solver.gravity_constant *
		(planetary.star_mass + planets[1].mass) / first_orbit)
	_check(is_equal_approx(planets[1].vel.length(), circular_speed),
		"planetary source speed must follow the configured G and central mass")
	var planetary_seed := planetary.seed(32, solver, 4)
	var planetary_replay := planetary.seed(32, solver, 4)
	_check(planetary_seed.positions == planetary_replay.positions
		and planetary_seed.velocities == planetary_replay.velocities,
		"planetary belt seed must be reproducible")

	var cluster := GlobularClusterScene.new()
	cluster.apply_defaults(solver)
	var cluster_seed := cluster.seed(256, solver, 7)
	var seeded_mass := 0.0
	var cluster_inside_bound := true
	for i in 256:
		var offset := i * 4
		var position := Vector3(cluster_seed.positions[offset],
			cluster_seed.positions[offset + 1], cluster_seed.positions[offset + 2])
		seeded_mass += cluster_seed.positions[offset + 3]
		if position.length() > cluster.scale_radius * 4.0 + 0.001:
			cluster_inside_bound = false
	_check(cluster.supports_self_gravity() and cluster.default_self_gravity(),
		"globular cluster must start with direct particle self-gravity enabled")
	_check(is_equal_approx(seeded_mass, cluster.cluster_mass)
		and cluster_inside_bound,
		"globular cluster seed must conserve total mass inside its Plummer cutoff")

	var trojans := TrojanSwarmScene.new()
	trojans.apply_defaults(solver)
	var binary := trojans.attractors(solver)
	var total_binary_mass: float = binary[0].mass + binary[1].mass
	var binary_com: Vector3 = (binary[0].pos * binary[0].mass
		+ binary[1].pos * binary[1].mass) / total_binary_mass
	_check(binary.size() == 2 and binary_com.length() < 1e-5
		and is_equal_approx(binary[1].pos.distance_to(binary[0].pos), trojans.orbit_radius),
		"Trojan primaries must follow a barycentric circular orbit")
	trojans.update_attractors(1.0, binary, solver)
	_check(is_equal_approx(binary[1].pos.distance_to(binary[0].pos), trojans.orbit_radius),
		"Trojan orbit separation must stay fixed while the binary moves")

	var stream := TidalStreamScene.new()
	stream.apply_defaults(solver)
	var encounter := stream.attractors(solver)
	_check(solver.respawn_mode == 3,
		"tidal particles must respawn around the surviving satellite core")
	var expected_speed := stream.approach_speed_ratio * sqrt(
		2.0 * solver.gravity_constant * stream.black_hole_mass /
		(stream.apocenter_distance * stream.apocenter_distance
			+ solver.attractor_softening * solver.attractor_softening))
	_check(is_equal_approx(encounter[1].vel.length(), expected_speed),
		"tidal satellite initial speed must match the softened escape-speed ratio")
	var stream_seed := stream.seed(32, solver, 9)
	var stream_replay := stream.seed(32, solver, 9)
	_check(stream_seed.positions == stream_replay.positions
		and stream_seed.velocities == stream_replay.velocities,
		"tidal stream initial condition must be reproducible")
	stream.update_attractors(1.0, encounter, solver)
	_check(is_finite(encounter[1].pos.x) and is_finite(encounter[1].vel.z),
		"tidal satellite CPU orbit must remain finite")


func _test_step_snapshot() -> void:
	var solver := NBodySolver.new()
	solver.particle_count = 2
	solver.substeps = 2
	solver.self_gravity = true
	solver.set_attractors([{
		pos = Vector3(1.0, 2.0, 3.0), vel = Vector3.ZERO, mass = 4.0, radius = 0.5,
	}])
	var constants := solver.make_step_constants(0.025, 1.5)
	var samples: Array = []
	var axes: Array[Vector3] = []
	for i in 5:
		samples.append([{
			pos = Vector3(float(i), 2.0, 3.0), vel = Vector3.ZERO, mass = 4.0, radius = 0.5,
		}])
		axes.append(Vector3.UP)
	var packed_samples := solver.pack_attractor_samples(samples, axes)
	var sample_stride := NBodySolver.SOURCE_STRIDE_FLOATS
	var second_x_offset := sample_stride
	_check(constants.size() == 128 and constants.decode_s32(64) == 2
		and (constants.decode_s32(76) & NBodySolver.SELF_GRAVITY_BIT) != 0,
		"N-body step constants must snapshot substeps and the gravity mode")
	_check(is_equal_approx(constants.decode_float(0), 0.025)
		and is_equal_approx(constants.decode_float(108), 1.5),
		"N-body step constants must snapshot dt and simulation time")
	_check(is_equal_approx(constants.decode_float(96), float(solver.substeps)),
		"N-body push constants must encode substeps for respawn")
	_check(packed_samples.size() == 5 * sample_stride
		and is_equal_approx(packed_samples[second_x_offset], 1.0),
		"attractor snapshots must use the fixed stride and preserve each sample")
	samples[1][0].pos = Vector3(99.0, 0.0, 0.0)
	_check(is_equal_approx(packed_samples[second_x_offset], 1.0),
		"packed attractor samples must not alias the mutable scene list")
