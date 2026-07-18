class_name FireworkScene
extends NBodySceneDef
## Fireworks show. Fully analytic on the GPU: every star's position is a pure
## function of (index, sim time) — see firework() in nbody_step_attractors.comp.
## Particles are split across `rockets` staggered groups; each group bursts as
## one synchronized shell, decelerates under air drag, droops under gravity,
## fades quadratically with sparkle, then relaunches somewhere else.

var period := 20.0
var rockets := 8.0
var burst_speed := 12.0
var gravity_strength := 0.8
var spread := 24.0


func title() -> String:
	return "Fireworks"


func star_size() -> float:
	return 0.05


func brightness() -> float:
	return 0.6


func view_distance() -> float:
	return spread * 3.5


func params() -> Array:
	return [
		{key = "period", label = "Burst period", min = 5.0, max = 40.0},
		{key = "rockets", label = "Rockets", min = 1.0, max = 16.0},
		{key = "burst_speed", label = "Burst speed", min = 4.0, max = 20.0},
		{key = "gravity_strength", label = "Gravity", min = 0.1, max = 3.0},
		{key = "spread", label = "Spread", min = 5.0, max = 50.0},
	]


func apply_defaults(solver: NBodySolver) -> void:
	solver.force_mode = 2
	solver.param_a = period
	solver.param_b = spread
	solver.aux2 = Vector4(
		burst_speed * 0.15, gravity_strength, burst_speed, floorf(maxf(rockets, 1.0))
	)
	solver.escape_radius = 1000.0
	# Unused by the analytic path (it writes the glow channel directly), but keep
	# them sane for the horizonless status displays.
	solver.v_ref = burst_speed
	solver.disk_r_min = 1.0
	solver.disk_r_max = spread


# Positions are analytic, so the seed only carries mass + colour; park
# everything at the origin, frame one overwrites it all.
func seed(count: int, _solver: NBodySolver) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xF12E30
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	for i in count:
		vel[i * 4 + 3] = rng.randf()
	return {positions = pos, velocities = vel}
