class_name PulsarScene
extends NBodySceneDef
## Neutron star firing two polar particle jets. The magnetic axis is tilted off
## the spin axis (obliquity), so the beams sweep like a lighthouse and the wind
## wraps into an Archimedean spiral — garden-sprinkler geometry, which is what a
## real pulsar wind traces. Slow ejecta falls back onto the star and is re-fired.

var star_mass := 1.5
var spin_rate := 1.2
var obliquity := 0.7
var cone := 0.12
var jet_speed := 3.0
var nebula_radius := 90.0


func title() -> String:
	return "Pulsar jets"


func star_size() -> float:
	return 0.06


func view_distance() -> float:
	return nebula_radius * 1.5


func params() -> Array:
	return [
		{key = "star_mass", label = "Star mass", min = 0.3, max = 5.0},
		{key = "spin_rate", label = "Spin rate", min = 0.1, max = 6.0},
		{key = "obliquity", label = "Obliquity", min = 0.0, max = 1.5},
		{key = "cone", label = "Beam cone", min = 0.02, max = 0.6},
		{key = "jet_speed", label = "Jet speed", min = 1.0, max = 8.0},
		{key = "nebula_radius", label = "Nebula radius", min = 40.0, max = 200.0},
	]


func apply_defaults(solver: NBodySolver) -> void:
	solver.gravity_constant = 1.0
	solver.softening = 0.1
	solver.attractor_softening = 0.05
	solver.disk_mass = 0.0
	solver.disk_r_min = 3.0
	solver.disk_r_max = nebula_radius * 0.5
	solver.disk_thickness = 0.5
	solver.dispersion = 0.05
	solver.escape_radius = nebula_radius
	solver.respawn_mode = 1
	solver.jet_speed = jet_speed
	solver.axis_spread = cone
	solver.axis_dir = _axis(0.0)
	# Emission speed spans 0.8..1.2 * jet_speed: fresh ejecta lands on the hot end
	# of the ramp, fall-back debris cools toward red.
	solver.v_ref = jet_speed


func update_frame(t: float, solver: NBodySolver) -> void:
	solver.axis_dir = _axis(t)


func attractors() -> Array:
	return [{pos = Vector3.ZERO, vel = Vector3.ZERO, mass = star_mass, radius = 0.3}]


# Pre-fill the sprinkler spiral: a particle emitted at time -age along the beam
# axis of that moment has since flown speed * age outward. Without this the demo
# starts empty and takes nebula_radius / jet_speed time units to fill.
func seed(count: int, _solver: NBodySolver) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9017A12
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	var max_age := nebula_radius / jet_speed * 0.95

	for i in count:
		var age := rng.randf() * max_age
		var pole := 1.0 if rng.randf() < 0.5 else -1.0
		var jitter := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * 2.0
		var dir := (_axis(-age) * pole + jitter * cone).normalized()
		var speed := jet_speed * (0.8 + 0.4 * rng.randf())
		var p := dir * (0.5 + speed * age)
		var v := dir * speed

		pos[i * 4] = p.x
		pos[i * 4 + 1] = p.y
		pos[i * 4 + 2] = p.z
		pos[i * 4 + 3] = 0.0
		vel[i * 4] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = rng.randf()

	return {positions = pos, velocities = vel}


# Magnetic axis: tilted off +Y by obliquity, precessing around it at spin_rate.
func _axis(t: float) -> Vector3:
	var ang := spin_rate * t
	return Vector3(sin(obliquity) * cos(ang), cos(obliquity), sin(obliquity) * sin(ang))
