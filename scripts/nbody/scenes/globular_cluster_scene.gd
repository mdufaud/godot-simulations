class_name GlobularClusterScene
extends NBodySceneDef

var cluster_mass := 24.0
var scale_radius := 14.0
var velocity_scale := 0.9


func title() -> String:
	return "Globular cluster"


func supports_self_gravity() -> bool:
	return true


func default_self_gravity() -> bool:
	return true


func params() -> Array:
	return [
		{key = "cluster_mass", label = "Cluster mass", min = 8.0, max = 60.0},
		{key = "scale_radius", label = "Scale radius", min = 6.0, max = 24.0},
	]


func advanced_params() -> Array:
	return [{key = "velocity_scale", label = "Velocity scale", min = 0.6, max = 1.3}]


func normalize_params() -> void:
	cluster_mass = clampf(cluster_mass, 8.0, 60.0)
	scale_radius = clampf(scale_radius, 6.0, 24.0)
	velocity_scale = clampf(velocity_scale, 0.6, 1.3)


func apply_defaults(solver: NBodySolver) -> void:
	solver.softening = maxf(0.12, scale_radius * 0.025)
	solver.attractor_softening = 0.05
	solver.disk_mass = 0.0
	solver.disk_r_min = scale_radius
	solver.disk_r_max = scale_radius * 5.0
	solver.disk_thickness = 0.0
	solver.dispersion = 0.0
	solver.escape_radius = scale_radius * 8.0
	solver.v_ref = sqrt(solver.gravity_constant * cluster_mass / scale_radius)


func view_distance(_solver: NBodySolver) -> float:
	return scale_radius * 8.5


func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC1057E2 ^ seed_value
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	positions.resize(count * 4)
	velocities.resize(count * 4)
	var truncated_mass := pow(16.0 / 17.0, 1.5)
	var sigma_center := sqrt(solver.gravity_constant * cluster_mass / (6.0 * scale_radius))
	var particle_mass := cluster_mass / float(count)
	for i in count:
		var u := maxf(rng.randf_range(1e-6, truncated_mass), 1e-6)
		var radius := scale_radius / sqrt(pow(u, -2.0 / 3.0) - 1.0)
		var direction := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var position := direction * radius
		var local_sigma := sigma_center * pow(1.0 + pow(radius / scale_radius, 2.0), -0.25)
		var velocity := Vector3(rng.randfn(), rng.randfn(), rng.randfn()) \
			* (local_sigma * velocity_scale)
		var escape_speed := sqrt(2.0 * solver.gravity_constant * cluster_mass \
			/ sqrt(radius * radius + scale_radius * scale_radius))
		if velocity.length() > escape_speed * 0.95:
			velocity = velocity.normalized() * escape_speed * 0.95
		var offset := i * 4
		positions[offset] = position.x
		positions[offset + 1] = position.y
		positions[offset + 2] = position.z
		positions[offset + 3] = particle_mass
		velocities[offset] = velocity.x
		velocities[offset + 1] = velocity.y
		velocities[offset + 2] = velocity.z
		velocities[offset + 3] = rng.randf()
	return {positions = positions, velocities = velocities}
