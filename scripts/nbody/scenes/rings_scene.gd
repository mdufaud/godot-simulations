class_name PlanetRingsScene
extends NBodySceneDef
## Planet with a razor-thin ring and two moons on analytic circular orbits. The
## moons' pull carves gaps and spiral density wakes into the ring; particles that
## stray inside a moon's absorb radius are eaten and respawn at the ring's edge.

var planet_mass := 1.0
var ring_inner := 6.0
var ring_outer := 16.0
var moon_mass := 0.006
var moon_orbit := 10.5
var thickness := 0.05


func title() -> String:
	return "Planet rings + moons"


func star_size() -> float:
	return 0.035


func brightness() -> float:
	return 0.3


func view_distance() -> float:
	return ring_outer * 3.0


func params() -> Array:
	return [
		{key = "planet_mass", label = "Planet mass", min = 0.3, max = 4.0},
		{key = "ring_inner", label = "Ring inner", min = 3.0, max = 20.0},
		{key = "ring_outer", label = "Ring outer", min = 8.0, max = 40.0},
		{key = "moon_mass", label = "Moon mass", min = 0.0, max = 0.03},
		{key = "moon_orbit", label = "Moon orbit", min = 5.0, max = 30.0},
		{key = "thickness", label = "Thickness", min = 0.0, max = 1.0},
	]


func apply_defaults(solver: NBodySolver) -> void:
	solver.gravity_constant = 1.0
	# Rings are cold: tiny softening keeps moon wakes sharp.
	solver.softening = 0.05
	solver.attractor_softening = 0.03
	solver.disk_r_min = ring_inner
	solver.disk_r_max = maxf(ring_outer, ring_inner + 1.0)
	solver.disk_thickness = thickness
	solver.dispersion = 0.004
	solver.disk_mass = 0.0
	solver.escape_radius = solver.disk_r_max * 6.0
	solver.v_ref = sqrt(planet_mass / ring_inner)


func attractors() -> Array:
	var list := [
		{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = planet_mass, radius = ring_inner * 0.45},
	]
	for m in _moons():
		list.append({pos = m.pos, vel = m.vel, mass = moon_mass, radius = 0.3})
	return list


func update_attractors(t: float, list: Array) -> bool:
	var moons := _moons(t)
	for k in moons.size():
		list[k + 1].pos = moons[k].pos
		list[k + 1].vel = moons[k].vel
	return true


func seed(count: int, solver: NBodySolver) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51A7031
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)

	for i in count:
		var r := lerpf(solver.disk_r_min, solver.disk_r_max, rng.randf())
		var ang := rng.randf() * TAU
		var p := Vector3(r * cos(ang), (rng.randf() * 2.0 - 1.0) * thickness, r * sin(ang))
		var v := Vector3(-sin(ang), 0.0, cos(ang)) * sqrt(planet_mass / r)
		var speed := v.length()
		v += Vector3(rng.randfn(), rng.randfn() * 0.2, rng.randfn()) * (solver.dispersion * speed)

		pos[i * 4] = p.x
		pos[i * 4 + 1] = p.y
		pos[i * 4 + 2] = p.z
		pos[i * 4 + 3] = 0.0
		vel[i * 4] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = rng.randf()

	return {positions = pos, velocities = vel}


# One moon at moon_orbit, a second shepherd just past the ring edge, opposite phase.
func _moons(t: float = 0.0) -> Array:
	var out := []
	var radii := [moon_orbit, ring_outer * 1.18]
	for k in radii.size():
		var r: float = radii[k]
		var omega := sqrt(planet_mass / pow(r, 3.0))
		var ang := omega * t + PI * k
		out.append({
			pos = Vector3(r * cos(ang), 0.0, r * sin(ang)),
			vel = Vector3(-sin(ang), 0.0, cos(ang)) * (omega * r),
		})
	return out
