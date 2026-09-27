class_name BlackHoleScene
extends NBodySceneDef
## Supermassive black hole with an accretion disk. G = 1, so with M_bh = 1 the
## circular period at r = 10 is 2*pi*10^1.5 ~ 200 time units.

var bh_mass := 1.0
var bh_radius := 2.0
var r_min := 6.0
var r_max := 40.0
var thickness := 0.8
var dispersion := 0.04
var disk_mass := 0.35
var bulge_fraction := 0.03


func title() -> String:
	return "Black hole disk"


func view_distance(_solver: NBodySolver) -> float:
	return maxf(70.0, maxf(r_max, r_min * 1.5) * 1.75)


func params() -> Array:
	return [
		{key = "bh_mass", label = "BH mass", min = 0.2, max = 8.0},
		{key = "bh_radius", label = "Absorb radius", min = 0.3, max = 10.0},
		{key = "r_min", label = "Disk inner", min = 3.0, max = 40.0},
		{key = "r_max", label = "Disk outer", min = 10.0, max = 160.0},
		{key = "thickness", label = "Thickness", min = 0.0, max = 8.0},
		{key = "dispersion", label = "Dispersion", min = 0.0, max = 0.3},
		{key = "disk_mass", label = "Disk mass", min = 0.0, max = 4.0},
	]


func advanced_params() -> Array:
	return [{key = "bulge_fraction", label = "Bulge fraction", min = 0.0, max = 0.15}]


func normalize_params() -> void:
	bh_radius = clampf(bh_radius, 0.3, 10.0)
	r_min = clampf(r_min, 3.0, 40.0)
	r_max = clampf(r_max, 10.0, 160.0)
	r_min = maxf(r_min, bh_radius * 2.0)
	r_max = maxf(r_max, r_min * 1.5)
	bulge_fraction = clampf(bulge_fraction, 0.0, 0.15)


func supports_self_gravity() -> bool:
	return true


func apply_defaults(solver: NBodySolver) -> void:
	solver.softening = 0.15
	solver.attractor_softening = 0.05
	solver.disk_r_min = _inner()
	solver.disk_r_max = maxf(r_max, _inner() * 1.5)
	solver.disk_thickness = thickness
	solver.dispersion = dispersion
	solver.disk_mass = disk_mass
	solver.escape_radius = solver.disk_r_max * 4.0
	# Normalizes the speed -> colour ramp, so the inner disk stays blue-white
	# whatever the black hole mass is.
	solver.v_ref = sqrt(solver.gravity_constant * bh_mass / solver.disk_r_min)


func attractors(_solver: NBodySolver) -> Array:
	return [{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = bh_mass, radius = _horizon()}]


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EEDBEEF ^ seed_value
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	var m_particle := solver.disk_mass / float(count)
	var bulge := int(count * bulge_fraction)
	# A 0.85 * v_circ orbit dips to r_p = 0.565 * r, so keep the bulge floor above
	# twice the horizon or the black hole eats the bulge on the first pass.
	var bulge_min := maxf(solver.disk_r_min * 0.65, _horizon() * 2.0)

	for i in count:
		var p: Vector3
		var v: Vector3
		var r: float
		if i < bulge:
			# Pressure-supported bulge: isotropic shell, orbits on random planes.
			r = lerpf(bulge_min, solver.disk_r_min, pow(rng.randf(), 0.6))
			var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			p = dir * r
			var axis := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
			var tangent := axis.cross(dir)
			if tangent.length_squared() < 1e-6:
				tangent = Vector3.RIGHT
			v = tangent.normalized() * _v_circ(r, solver) * 0.85
		else:
			# Surface density ~ 1/r => radius is uniform in [r_min, r_max].
			r = lerpf(solver.disk_r_min, solver.disk_r_max, rng.randf())
			var ang := rng.randf() * TAU
			var t := rng.randf() * 2.0 - 1.0
			# Flared disk: the scale height grows outward, so a wide disk does not
			# look like a razor blade and a dense one still has depth.
			var h := solver.disk_thickness * (0.3 + 0.7 * r / solver.disk_r_max)
			p = Vector3(r * cos(ang), t * t * t * h, r * sin(ang))
			v = Vector3(-sin(ang), 0.0, cos(ang)) * _v_circ(r, solver)

		# Dispersion seeds the instability that grows structure in self-gravity mode.
		var speed := v.length()
		v += Vector3(rng.randfn(), rng.randfn() * 0.3, rng.randfn()) * (solver.dispersion * speed)

		pos[i * 4] = p.x
		pos[i * 4 + 1] = p.y
		pos[i * 4 + 2] = p.z
		pos[i * 4 + 3] = m_particle
		vel[i * 4] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = rng.randf()

	return {positions = pos, velocities = vel}


func _horizon() -> float:
	return bh_radius


# The disk must clear the horizon, or its inner edge is swallowed and respawned
# every frame. Growing the black hole pushes the disk out rather than the reverse,
# so the hole is always as big as the slider says.
func _inner() -> float:
	return maxf(r_min, bh_radius * 2.0)


# Must match enclosed_mass() in nbody_common.comp, or respawned particles would
# come back on the wrong orbit.
func _v_circ(r: float, solver: NBodySolver) -> float:
	var span := maxf(solver.disk_r_max - solver.disk_r_min, 1e-6)
	var frac := clampf((r - solver.disk_r_min) / span, 0.0, 1.0)
	var m_enc := bh_mass + solver.disk_mass * frac
	return sqrt(solver.gravity_constant * m_enc / maxf(r, 1e-3))
