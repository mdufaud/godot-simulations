class_name TidalStreamScene
extends NBodySceneDef

var black_hole_mass := 20.0
var satellite_mass := 0.8
var apocenter_distance := 45.0
var cluster_radius := 5.5
var approach_speed_ratio := 0.32
var dispersion := 0.04

var _satellite_pos := Vector3.ZERO
var _satellite_vel := Vector3.ZERO
var _last_t := 0.0


func title() -> String:
	return "Tidal stream"


func params() -> Array:
	return [
		{key = "black_hole_mass", label = "Black hole mass", min = 10.0, max = 60.0},
		{key = "satellite_mass", label = "Satellite mass", min = 0.1, max = 3.0},
		{key = "apocenter_distance", label = "Start distance", min = 25.0, max = 90.0},
		{key = "cluster_radius", label = "Cluster radius", min = 1.0, max = 8.0},
	]


func advanced_params() -> Array:
	return [
		{key = "approach_speed_ratio", label = "Speed / escape speed", min = 0.2, max = 0.7},
		{key = "dispersion", label = "Internal dispersion", min = 0.0, max = 0.15},
	]


func normalize_params() -> void:
	black_hole_mass = clampf(black_hole_mass, 10.0, 60.0)
	satellite_mass = clampf(satellite_mass, 0.1, 3.0)
	apocenter_distance = clampf(apocenter_distance, 25.0, 90.0)
	cluster_radius = clampf(cluster_radius, 1.0, 8.0)
	cluster_radius = minf(cluster_radius, apocenter_distance * 0.2)
	approach_speed_ratio = clampf(approach_speed_ratio, 0.2, 0.7)
	dispersion = clampf(dispersion, 0.0, 0.15)


func apply_defaults(solver: NBodySolver) -> void:
	solver.softening = 0.12
	solver.attractor_softening = 0.12
	solver.respawn_mode = 3
	solver.disk_mass = 0.0
	solver.disk_r_min = maxf(1.5, cluster_radius * 0.5)
	solver.disk_r_max = maxf(solver.disk_r_min + 1.0, cluster_radius * 1.5)
	solver.disk_thickness = 0.0
	solver.dispersion = dispersion
	solver.escape_radius = apocenter_distance * 4.0
	var periapsis := _periapsis()
	solver.v_ref = sqrt(solver.gravity_constant * black_hole_mass / maxf(periapsis, 1.0))


func view_distance(_solver: NBodySolver) -> float:
	return maxf(72.0, apocenter_distance * 2.7)


func attractors(solver: NBodySolver) -> Array:
	_satellite_pos = Vector3(apocenter_distance, 0.0, 0.0)
	var escape_speed := sqrt(2.0 * solver.gravity_constant * black_hole_mass \
		/ (apocenter_distance * apocenter_distance \
			+ solver.attractor_softening * solver.attractor_softening))
	_satellite_vel = Vector3(0.0, 0.0, approach_speed_ratio * escape_speed)
	_last_t = 0.0
	return [
		{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = black_hole_mass,
			radius = maxf(0.5, pow(black_hole_mass, 1.0 / 3.0) * 0.4)},
		{pos = _satellite_pos, vel = _satellite_vel, mass = satellite_mass,
			radius = maxf(0.3, cluster_radius * 0.25)},
	]


func attractor_emission(index: int) -> Color:
	match index:
		0: return Color(0.22, 0.36, 0.78)
		1: return Color(1.0, 0.48, 0.18)
	return Color.BLACK


func update_attractors(t: float, list: Array, solver: NBodySolver) -> bool:
	var dt := t - _last_t
	_last_t = t
	if dt <= 0.0:
		return false
	var steps := maxi(1, ceili(dt / 0.02))
	var h := dt / float(steps)
	for _step in steps:
		_satellite_pos += _satellite_vel * (0.5 * h)
		var r := _satellite_pos
		var d2 := r.length_squared() \
			+ solver.attractor_softening * solver.attractor_softening
		var acc := -r * (solver.gravity_constant * black_hole_mass \
			/ (d2 * sqrt(d2)))
		_satellite_vel += acc * h
		_satellite_pos += _satellite_vel * (0.5 * h)
	list[1].pos = _satellite_pos
	list[1].vel = _satellite_vel
	return true


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x71DA15 ^ seed_value
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	positions.resize(count * 4)
	velocities.resize(count * 4)
	for i in count:
		var radius := cluster_radius * pow(rng.randf(), 1.0 / 3.0)
		var direction := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var position := _satellite_pos + direction * radius
		var random_axis := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var tangent := random_axis.cross(direction)
		if tangent.length_squared() < 1e-6:
			tangent = Vector3.UP.cross(direction)
		tangent = tangent.normalized()
		var local_speed := sqrt(solver.gravity_constant * satellite_mass \
			/ maxf(radius, solver.attractor_softening))
		var velocity := _satellite_vel + tangent * local_speed * rng.randf_range(0.35, 0.8)
		velocity += Vector3(rng.randfn(), rng.randfn(), rng.randfn()) \
			* (dispersion * local_speed)
		var offset := i * 4
		positions[offset] = position.x
		positions[offset + 1] = position.y
		positions[offset + 2] = position.z
		velocities[offset] = velocity.x
		velocities[offset + 1] = velocity.y
		velocities[offset + 2] = velocity.z
		velocities[offset + 3] = rng.randf()
	return {positions = positions, velocities = velocities}


func _periapsis() -> float:
	var ratio_squared := approach_speed_ratio * approach_speed_ratio
	return apocenter_distance * ratio_squared / maxf(1.0 - ratio_squared, 0.05)
