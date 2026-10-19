class_name PlanetarySystemScene
extends NBodySceneDef

const PLANET_ORBITS := [6.0, 10.0, 16.0, 24.0]
const PLANET_MASSES := [0.003, 0.008, 0.02, 0.05]
const PLANET_RADII := [0.28, 0.36, 0.48, 0.62]
const PLANET_INCLINATIONS := [0.0, 0.04, -0.06, 0.08]

var star_mass := 8.0
var planet_mass_scale := 1.0
var belt_inner := 28.0
var belt_outer := 58.0
var belt_thickness := 1.2
var dispersion := 0.02


func title() -> String:
	return "Planetary system"


func params() -> Array:
	return [
		{key = "star_mass", label = "Star mass", min = 2.0, max = 20.0},
		{key = "planet_mass_scale", label = "Planet mass scale", min = 0.5, max = 3.0},
		{key = "belt_inner", label = "Belt inner radius", min = 16.0, max = 45.0},
		{key = "belt_outer", label = "Belt outer radius", min = 35.0, max = 90.0},
	]


func advanced_params() -> Array:
	return [
		{key = "belt_thickness", label = "Belt thickness", min = 0.0, max = 4.0},
		{key = "dispersion", label = "Orbital dispersion", min = 0.0, max = 0.1},
	]


func normalize_params() -> void:
	star_mass = clampf(star_mass, 2.0, 20.0)
	planet_mass_scale = clampf(planet_mass_scale, 0.5, 3.0)
	belt_inner = clampf(belt_inner, 16.0, 45.0)
	belt_outer = clampf(belt_outer, 35.0, 90.0)
	belt_outer = maxf(belt_outer, belt_inner + 5.0)
	belt_thickness = clampf(belt_thickness, 0.0, 4.0)
	dispersion = clampf(dispersion, 0.0, 0.1)


func apply_defaults(solver: NBodySolver) -> void:
	solver.softening = 0.08
	solver.attractor_softening = 0.08
	solver.disk_mass = 0.0
	solver.disk_r_min = belt_inner
	solver.disk_r_max = belt_outer
	solver.disk_thickness = belt_thickness
	solver.dispersion = dispersion
	solver.escape_radius = belt_outer * 2.5
	solver.v_ref = sqrt(solver.gravity_constant * star_mass / belt_inner)


func view_distance(_solver: NBodySolver) -> float:
	return maxf(80.0, belt_outer * 2.1)


func attractors(solver: NBodySolver) -> Array:
	var sources: Array = [
		{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = star_mass, radius = 1.4},
	]
	sources.append_array(_planet_states(0.0, solver))
	return sources


func attractor_emission(index: int) -> Color:
	match index:
		0: return Color(1.0, 0.62, 0.2)
		1: return Color(0.35, 0.65, 1.0)
		2: return Color(1.0, 0.42, 0.2)
		3: return Color(0.35, 1.0, 0.65)
		4: return Color(0.8, 0.55, 1.0)
	return Color.BLACK


func update_attractors(t: float, list: Array, solver: NBodySolver) -> bool:
	var planets := _planet_states(t, solver)
	for i in planets.size():
		list[i + 1].pos = planets[i].pos
		list[i + 1].vel = planets[i].vel
	return true


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51A7E ^ seed_value
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	positions.resize(count * 4)
	velocities.resize(count * 4)
	for i in count:
		var radius := lerpf(belt_inner, belt_outer, rng.randf())
		var angle := rng.randf() * TAU
		var position := Vector3(radius * cos(angle),
			rng.randfn() * belt_thickness * 0.35, radius * sin(angle))
		var orbital_speed := sqrt(solver.gravity_constant * star_mass / radius)
		var velocity := Vector3(-sin(angle), 0.0, cos(angle)) * orbital_speed
		velocity += Vector3(rng.randfn(), rng.randfn() * 0.2, rng.randfn()) \
			* (dispersion * orbital_speed)
		var offset := i * 4
		positions[offset] = position.x
		positions[offset + 1] = position.y
		positions[offset + 2] = position.z
		velocities[offset] = velocity.x
		velocities[offset + 1] = velocity.y
		velocities[offset + 2] = velocity.z
		velocities[offset + 3] = rng.randf()
	return {positions = positions, velocities = velocities}


func _planet_states(t: float, solver: NBodySolver) -> Array:
	var states: Array = []
	for i in PLANET_ORBITS.size():
		var orbit: float = PLANET_ORBITS[i]
		var mass: float = PLANET_MASSES[i] * planet_mass_scale
		var omega := sqrt(solver.gravity_constant * (star_mass + mass) / pow(orbit, 3.0))
		var angle := omega * t + float(i) * 0.72
		var local_position := Vector3(orbit * cos(angle), 0.0, orbit * sin(angle))
		var local_velocity := Vector3(-sin(angle), 0.0, cos(angle)) * (omega * orbit)
		var orbit_basis := Basis(Vector3.RIGHT, PLANET_INCLINATIONS[i])
		states.append({
			pos = orbit_basis * local_position,
			vel = orbit_basis * local_velocity,
			mass = mass,
			radius = PLANET_RADII[i],
		})
	return states
