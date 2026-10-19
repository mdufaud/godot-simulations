class_name FireworkScene
extends NBodySceneDef
## Staggered launch, ascent and aerial shell bursts on the GPU.

var period := 40.0
var rockets := 4.0
var burst_speed := 17.0
var gravity_strength := 1.0
var spread := 24.0
var air_drag := 1.1


func title() -> String:
	return "Fireworks"


func view_distance(_solver: NBodySolver) -> float:
	var bounds := render_bounds(_solver, [])
	var focus := view_target(_solver).y
	var half_height := maxf(absf(bounds.position.y - focus),
		absf(bounds.end.y - focus))
	return maxf(80.0, 2.15 * maxf(half_height, bounds.end.x))


func view_target(_solver: NBodySolver, _sim_time: float = 0.0) -> Vector3:
	return Vector3(0.0, spread * 1.75, 0.0)


func params() -> Array:
	return [
		{key = "period", label = "Burst period", min = 15.0, max = 70.0},
		{key = "rockets", label = "Rockets", min = 1.0, max = 16.0, step = 1.0},
		{key = "burst_speed", label = "Burst speed", min = 4.0, max = 20.0},
		{key = "gravity_strength", label = "Gravity", min = 0.1, max = 3.0},
		{key = "spread", label = "Spread", min = 5.0, max = 50.0},
	]


func advanced_params() -> Array:
	return [{key = "air_drag", label = "Air drag", min = 0.1, max = 3.0}]


func normalize_params() -> void:
	rockets = clampf(roundf(rockets), 1.0, 16.0)
	air_drag = clampf(air_drag, 0.1, 3.0)


func apply_defaults(solver: NBodySolver) -> void:
	solver.force_mode = 2
	solver.firework_period_s = period
	solver.firework_spread_m = spread
	solver.firework_speed_min_mps = burst_speed * 0.15
	solver.firework_gravity_mps2 = gravity_strength
	solver.firework_speed_max_mps = burst_speed
	solver.firework_rocket_groups = floorf(maxf(rockets, 1.0))
	solver.firework_drag = air_drag
	solver.escape_radius = 0.0
	# Unused by the analytic path (it writes the glow channel directly), but keep
	# them sane for the horizonless status displays.
	solver.v_ref = burst_speed
	solver.disk_r_min = 1.0
	solver.disk_r_max = spread


# Positions are analytic, so the seed only carries mass + colour; park
# everything at the origin, frame one overwrites it all.
func seed(count: int, _solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xF12E30 ^ seed_value
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	for i in count:
		vel[i * 4 + 3] = rng.randf()
	return {positions = pos, velocities = vel}


func render_bounds(_solver: NBodySolver, _sources: Array) -> AABB:
	var age := minf(period * 1.25 * 0.54, 23.0)
	var drag := 0.04 + 0.08 * air_drag
	var speed := burst_speed * 1.14 * 1.22
	var radius := log(1.0 + drag * speed * age) / drag
	var xz := spread * 1.175 + radius + 2.0
	var bottom := minf(0.0, spread * 2.2 - radius
		- 0.045 * gravity_strength * age * age) - 2.0
	var top := spread * 2.6 + radius + 2.0
	return AABB(Vector3(-xz, bottom, -xz),
		Vector3(xz * 2.0, top - bottom, xz * 2.0))
