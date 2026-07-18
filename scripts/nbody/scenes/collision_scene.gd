class_name GalaxyCollisionScene
extends NBodySceneDef
## Two galaxies (a central mass + test-particle disk each) on a bound collision
## course. The two cores are integrated on the CPU in update_attractors() —
## leapfrog on the 2-body problem — while their disks tidally shred on the GPU.

const CORE_SOFT2 := 1.0
const DISK_R_MIN := 3.0

var mass_a := 1.0
var mass_b := 0.6
var start_distance := 90.0
var impact_offset := 16.0
var approach_speed := 0.14
var disk_a := 26.0
var disk_b := 18.0
var tilt_b := 0.7

var _pos_a := Vector3.ZERO
var _vel_a := Vector3.ZERO
var _pos_b := Vector3.ZERO
var _vel_b := Vector3.ZERO
var _last_t := 0.0


func title() -> String:
	return "Galaxy collision"


func view_distance() -> float:
	return start_distance * 1.6


func params() -> Array:
	return [
		{key = "mass_a", label = "Mass A", min = 0.3, max = 4.0},
		{key = "mass_b", label = "Mass B", min = 0.3, max = 4.0},
		{key = "start_distance", label = "Start distance", min = 40.0, max = 200.0},
		{key = "impact_offset", label = "Impact offset", min = 0.0, max = 60.0},
		{key = "approach_speed", label = "Approach speed", min = 0.0, max = 0.5},
		{key = "disk_a", label = "Disk A radius", min = 8.0, max = 60.0},
		{key = "disk_b", label = "Disk B radius", min = 8.0, max = 60.0},
		{key = "tilt_b", label = "Tilt B", min = 0.0, max = 1.5},
	]


func apply_defaults(solver: NBodySolver) -> void:
	solver.gravity_constant = 1.0
	solver.softening = 0.15
	solver.attractor_softening = 0.05
	# Respawn ring lives on galaxy A's disk (the shader respawns around attractor 0).
	solver.disk_r_min = DISK_R_MIN
	solver.disk_r_max = disk_a
	solver.disk_thickness = 0.5
	solver.dispersion = 0.04
	solver.disk_mass = 0.0
	solver.escape_radius = start_distance * 3.0
	solver.v_ref = sqrt(mass_a / DISK_R_MIN)


func attractors() -> Array:
	# Barycentric frame: rel = pos_b - pos_a starts at (d, 0, offset), closing
	# along -x. Bound when approach_speed < escape speed, so the cores dance.
	var m := mass_a + mass_b
	var rel_pos := Vector3(start_distance, 0.0, impact_offset)
	var rel_vel := Vector3(-approach_speed, 0.0, 0.0)
	_pos_a = -rel_pos * (mass_b / m)
	_pos_b = rel_pos * (mass_a / m)
	_vel_a = -rel_vel * (mass_b / m)
	_vel_b = rel_vel * (mass_a / m)
	_last_t = 0.0
	return [
		{pos = _pos_a, vel = _vel_a, mass = mass_a, radius = _horizon(mass_a)},
		{pos = _pos_b, vel = _vel_b, mass = mass_b, radius = _horizon(mass_b)},
	]


func update_attractors(t: float, list: Array) -> bool:
	var dt := t - _last_t
	_last_t = t
	if dt <= 0.0:
		return false
	# Substep the CPU leapfrog so a close core passage stays stable.
	var steps := maxi(1, ceili(dt / 0.02))
	var h := dt / steps
	for _s in steps:
		var r := _pos_b - _pos_a
		var d2 := r.length_squared() + CORE_SOFT2
		var acc := r / (d2 * sqrt(d2))
		_vel_a += acc * (mass_b * h)
		_vel_b -= acc * (mass_a * h)
		_pos_a += _vel_a * h
		_pos_b += _vel_b * h
	list[0].pos = _pos_a
	list[0].vel = _vel_a
	list[1].pos = _pos_b
	list[1].vel = _vel_b
	return true


func seed(count: int, _solver: NBodySolver) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0111DE
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	var count_a := int(count * mass_a / (mass_a + mass_b))
	var basis_b := Basis(Vector3.RIGHT, tilt_b)

	for i in count:
		var in_a := i < count_a
		var center := _pos_a if in_a else _pos_b
		var center_v := _vel_a if in_a else _vel_b
		var m_core := mass_a if in_a else mass_b
		var r_out := disk_a if in_a else disk_b
		var r := lerpf(DISK_R_MIN, r_out, rng.randf())
		var ang := rng.randf() * TAU
		var tz := rng.randf() * 2.0 - 1.0
		var h := 0.5 * (0.3 + 0.7 * r / r_out)
		var p := Vector3(r * cos(ang), tz * tz * tz * h, r * sin(ang))
		var v := Vector3(-sin(ang), 0.0, cos(ang)) * sqrt(m_core / r)
		if not in_a:
			p = basis_b * p
			v = basis_b * v
		var speed := v.length()
		v += Vector3(rng.randfn(), rng.randfn() * 0.3, rng.randfn()) * (0.04 * speed)
		p += center
		v += center_v

		pos[i * 4] = p.x
		pos[i * 4 + 1] = p.y
		pos[i * 4 + 2] = p.z
		pos[i * 4 + 3] = 0.0
		vel[i * 4] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = rng.randf()

	return {positions = pos, velocities = vel}


func _horizon(m: float) -> float:
	return 0.5 * pow(m, 1.0 / 3.0)
