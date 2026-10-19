class_name VortexScene
extends NBodySceneDef
## Liquid tornado. Velocity-servo flow field: swirl around the axis, updraft
## inside the funnel wall, downdraft outside (recirculation), funnel radius
## widening with height, plus large-scale turbulent gusts. Particles spill out
## the top and are sucked back in at the ground inlet — that bottom-to-top mass
## flux and the gusts are what keep the picture visibly alive.

var swirl_speed := 3.5
var updraft := 2.5
var turbulence := 2.5
var funnel_radius := 14.0
var height := 70.0
var downdraft_ratio := 0.6


func title() -> String:
	return "Tornado vortex"


func view_distance(_solver: NBodySolver) -> float:
	return height * 1.8


func params() -> Array:
	return [
		{key = "swirl_speed", label = "Swirl speed", min = 0.5, max = 8.0},
		{key = "updraft", label = "Updraft", min = 0.3, max = 6.0},
		{key = "turbulence", label = "Turbulence", min = 0.0, max = 8.0},
		{key = "funnel_radius", label = "Funnel radius", min = 4.0, max = 35.0},
		{key = "height", label = "Height", min = 8.0, max = 100.0},
	]


func advanced_params() -> Array:
	return [{key = "downdraft_ratio", label = "Downdraft ratio", min = 0.0, max = 1.5}]


func normalize_params() -> void:
	downdraft_ratio = clampf(downdraft_ratio, 0.0, 1.5)


func apply_defaults(solver: NBodySolver) -> void:
	solver.force_mode = 1
	solver.respawn_mode = 2
	solver.vortex_updraft_mps = updraft
	solver.vortex_swirl_mps = swirl_speed
	solver.vortex_turbulence_mps2 = turbulence
	solver.vortex_downdraft_ratio = downdraft_ratio
	# Funnel geometry rides the disk slots (see nbody_common.comp Params).
	solver.disk_r_min = funnel_radius * 0.15
	solver.disk_r_max = funnel_radius
	solver.disk_thickness = height * 0.5
	solver.escape_radius = funnel_radius * 2.5
	solver.v_ref = swirl_speed


# Seed the funnel wall directly: without this the first seconds are a formless
# cloud snapping onto the cone.
func seed(count: int, solver: NBodySolver, seed_value: int = 0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x707BADE ^ seed_value
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	pos.resize(count * 4)
	vel.resize(count * 4)
	var half_h := solver.disk_thickness

	for i in count:
		var y := (rng.randf() * 2.0 - 1.0) * half_h
		var ht := clampf((y + half_h) / (2.0 * half_h), 0.0, 1.0)
		var r_t := lerpf(solver.disk_r_min, solver.disk_r_max, ht * ht)
		var r := r_t * (0.55 + rng.randf() * 0.6)
		var ang := rng.randf() * TAU
		var rd := Vector3(cos(ang), 0.0, sin(ang))
		var p := rd * r + Vector3(0.0, y, 0.0)
		var v := Vector3(-rd.z, 0.0, rd.x) * swirl_speed + Vector3(0.0, updraft * 0.5, 0.0)

		pos[i * 4] = p.x
		pos[i * 4 + 1] = p.y
		pos[i * 4 + 2] = p.z
		pos[i * 4 + 3] = 0.0
		vel[i * 4] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = rng.randf()

	return {positions = pos, velocities = vel}


func render_bounds(solver: NBodySolver, _sources: Array) -> AABB:
	var extent := Vector3(solver.escape_radius, solver.disk_thickness * 1.5,
		solver.escape_radius)
	extent += Vector3.ONE * maxf(2.0, solver.dt * maxf(2.0 * solver.v_ref, 1.0))
	return AABB(-extent, extent * 2.0)
