class_name TrojanSwarmScene
extends NBodySceneDef

var primary_mass := 8.0
var mass_ratio := 0.015
var orbit_radius := 24.0
var swarm_spread := 3.0
var dispersion := 0.025


func title() -> String:
	return "Trojan swarms"


func params() -> Array:
	return [
		{key = "primary_mass", label = "Primary mass", min = 2.0, max = 20.0},
		{key = "mass_ratio", label = "Secondary mass ratio", min = 0.001, max = 0.035},
		{key = "orbit_radius", label = "Orbit radius", min = 12.0, max = 40.0},
		{key = "swarm_spread", label = "Swarm spread", min = 0.5, max = 5.0},
	]


func advanced_params() -> Array:
	return [{key = "dispersion", label = "Velocity dispersion", min = 0.0, max = 0.15}]


func normalize_params() -> void:
	primary_mass = clampf(primary_mass, 2.0, 20.0)
	mass_ratio = clampf(mass_ratio, 0.001, 0.035)
	orbit_radius = clampf(orbit_radius, 12.0, 40.0)
	swarm_spread = clampf(swarm_spread, 0.5, 5.0)
	dispersion = clampf(dispersion, 0.0, 0.15)


func apply_defaults(solver: NBodySolver) -> void:
	solver.softening = 0.08
	solver.attractor_softening = 0.05
	solver.disk_mass = 0.0
	solver.disk_r_min = orbit_radius * 0.8
	solver.disk_r_max = orbit_radius * 1.25
	solver.disk_thickness = swarm_spread
	solver.dispersion = dispersion
	solver.escape_radius = orbit_radius * 3.5
	solver.v_ref = sqrt(solver.gravity_constant * primary_mass * (1.0 + mass_ratio)
		/ orbit_radius)


func view_distance(_solver: NBodySolver) -> float:
	return maxf(60.0, orbit_radius * 4.0)


func attractors(solver: NBodySolver) -> Array:
	return _system_state(0.0, solver)


func attractor_emission(index: int) -> Color:
	return Color(1.0, 0.65, 0.28) if index == 0 else Color(0.35, 0.72, 1.0)


func update_attractors(t: float, list: Array, solver: NBodySolver) -> bool:
	var states := _system_state(t, solver)
	for i in states.size():
		list[i].pos = states[i].pos
		list[i].vel = states[i].vel
	return true


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x7A01A9 ^ seed_value
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	positions.resize(count * 4)
	velocities.resize(count * 4)
	var states := _system_state(0.0, solver)
	var omega := sqrt(solver.gravity_constant * primary_mass * (1.0 + mass_ratio)
		/ pow(orbit_radius, 3.0))
	var orbital_speed := omega * orbit_radius
	for i in count:
		var sign := 1.0 if i % 2 == 0 else -1.0
		var l_point_angle := sign * PI / 3.0
		var primary_position: Vector3 = states[0].pos
		var center := primary_position + Vector3(
			orbit_radius * cos(l_point_angle), 0.0, orbit_radius * sin(l_point_angle))
		var position := center + Vector3(
			rng.randfn() * swarm_spread * 0.38,
			rng.randfn() * swarm_spread * 0.16,
			rng.randfn() * swarm_spread * 0.38)
		var velocity := Vector3(-omega * position.z, 0.0, omega * position.x)
		velocity += Vector3(rng.randfn(), rng.randfn(), rng.randfn()) \
			* (orbital_speed * dispersion)
		var offset := i * 4
		positions[offset] = position.x
		positions[offset + 1] = position.y
		positions[offset + 2] = position.z
		velocities[offset] = velocity.x
		velocities[offset + 1] = velocity.y
		velocities[offset + 2] = velocity.z
		velocities[offset + 3] = rng.randf()
	return {positions = positions, velocities = velocities}


func _system_state(t: float, solver: NBodySolver) -> Array:
	var total_mass := primary_mass * (1.0 + mass_ratio)
	var secondary_mass := primary_mass * mass_ratio
	var mu := secondary_mass / total_mass
	var omega := sqrt(solver.gravity_constant * total_mass / pow(orbit_radius, 3.0))
	var angle := omega * t
	var radial := Vector3(cos(angle), 0.0, sin(angle))
	var tangent := Vector3(-sin(angle), 0.0, cos(angle))
	return [
		{
			pos = -mu * orbit_radius * radial,
			vel = -mu * orbit_radius * omega * tangent,
			mass = primary_mass,
			radius = 0.65,
		},
		{
			pos = (1.0 - mu) * orbit_radius * radial,
			vel = (1.0 - mu) * orbit_radius * omega * tangent,
			mass = secondary_mass,
			radius = 0.32,
		},
	]
