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
var outer_moon_ratio := 1.18


func title() -> String:
	return "Planet rings + moons"


func view_distance(_solver: NBodySolver) -> float:
	return maxf(24.0, ring_outer * outer_moon_ratio * 1.35)


func params() -> Array:
	return [
		{key = "planet_mass", label = "Planet mass", min = 0.3, max = 4.0},
		{key = "ring_inner", label = "Ring inner", min = 3.0, max = 20.0},
		{key = "ring_outer", label = "Ring outer", min = 8.0, max = 40.0},
		{key = "moon_mass", label = "Moon mass", min = 0.0, max = 0.03},
		{key = "moon_orbit", label = "Moon orbit", min = 5.0, max = 30.0},
		{key = "thickness", label = "Thickness", min = 0.0, max = 1.0},
	]


func advanced_params() -> Array:
	return [{key = "outer_moon_ratio", label = "Outer moon / ring", min = 1.05, max = 1.5}]


func normalize_params() -> void:
	ring_inner = clampf(ring_inner, 3.0, 20.0)
	ring_outer = clampf(ring_outer, 8.0, 40.0)
	ring_inner = minf(ring_inner, ring_outer - 1.0)
	moon_orbit = clampf(moon_orbit, 5.0, 30.0)
	moon_orbit = maxf(moon_orbit, ring_inner * 0.45 + 0.31)
	outer_moon_ratio = clampf(outer_moon_ratio, 1.05, 1.5)


func apply_defaults(solver: NBodySolver) -> void:
	# Rings are cold: tiny softening keeps moon wakes sharp.
	solver.softening = 0.05
	solver.attractor_softening = 0.03
	solver.disk_r_min = ring_inner
	solver.disk_r_max = ring_outer
	solver.disk_thickness = thickness
	solver.dispersion = 0.004
	solver.disk_mass = 0.0
	solver.escape_radius = solver.disk_r_max * 6.0
	solver.v_ref = sqrt(solver.gravity_constant * planet_mass / ring_inner)


func attractors(solver: NBodySolver) -> Array:
	var list := [
		{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = planet_mass, radius = ring_inner * 0.45},
	]
	for m in _moons(0.0, solver):
		list.append({pos = m.pos, vel = m.vel, mass = moon_mass, radius = 0.3})
	return list


func update_attractors(t: float, list: Array, solver: NBodySolver) -> bool:
	var moons := _moons(t, solver)
	for k in moons.size():
		list[k + 1].pos = moons[k].pos
		list[k + 1].vel = moons[k].vel
	return true


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51A7031 ^ seed_value
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)

	for i in count:
		var r := lerpf(solver.disk_r_min, solver.disk_r_max, rng.randf())
		var ang := rng.randf() * TAU
		var p := Vector3(r * cos(ang), (rng.randf() * 2.0 - 1.0) * thickness, r * sin(ang))
		var v := Vector3(-sin(ang), 0.0, cos(ang)) \
			* sqrt(solver.gravity_constant * planet_mass / r)
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
func _moons(t: float, solver: NBodySolver) -> Array:
	var out := []
	var radii := [moon_orbit, ring_outer * outer_moon_ratio]
	for k in radii.size():
		var r: float = radii[k]
		var omega := sqrt(solver.gravity_constant * planet_mass / pow(r, 3.0))
		var ang := omega * t + PI * k
		out.append({
			pos = Vector3(r * cos(ang), 0.0, r * sin(ang)),
			vel = Vector3(-sin(ang), 0.0, cos(ang)) * (omega * r),
		})
	return out
