class_name FireInteraction extends RefCounted
## What the player points at the fire: the aim ray, the held weapon, the water jet
## presets, the thrown bucket and the flamethrower torch.
##
## The host assigns [member player], [member weapons], [member solver],
## [member water] and [member presentation], then calls [method update] once per
## frame before the solver steps.

# --- Water nozzle (Fire-X Fig. 8) ---
## The paper finds the spray aimed at the flame base is what stops the fire, so all
## three intensity presets aim there and vary how much water arrives per second.
## Each level sets the SPH emitter's frequency, velocity and spray cone; more water
## means a wider, faster, denser stream.
##
## Both the jet and the bucket leave the held weapon and converge on the crosshair.
##
# Frequency is particles/second, so it doubles as how dense the stream looks; all
# presets run well past Tab. 3's 100 Hz cap (game feel over the paper's nozzle) so
# the screen-space surface keeps enough neighbours in flight to fuse the stream
# into a continuous column rather than a dotted line. Gravity also nearly doubles
# the speed over the drop, stretching the spacing on the way down, so the rate has
# margin built in.
#
# Spray angle is 0: these are laminar jets, Fig. 8's other nozzle. A cone spreads
# the stream as it flies (5 deg over the ~6.7 m throw fans it from 0.12 m to ~0.4 m
# radius, an ~11x density drop), which pulls the droplets past the render radius
# and reads as golf balls flung in every direction. The paper prefers the spray for
# extinguishing, but the laminar stream is the one that looks like water.
#
const WATER_PRESETS := {
	1: {"freq": 420.0, "vel": 9.0, "spray": 0.0, "radius": 0.045},
	2: {"freq": 720.0, "vel": 12.0, "spray": 35.0, "radius": 0.05},
	3: {"freq": 1100.0, "vel": 15.0, "spray": 50.0, "radius": 0.055},
}
## A bucket is a lob, not a firehose: one throw every this many seconds.
const BUCKET_INTERVAL := 0.5

var player: FpsWalker
var weapons: FireWeapons
var solver: FireGpuSolver
var water: FireWater
var presentation: FirePresentation

var jet_enabled := false
var water_level := 0
var flamethrower_firing := false
var is_smothering := false

var _equipped := FireWeapons.Kind.NONE
var _bucket_cooldown := 0.0
var _particle_cap := 2000


func set_particle_cap(cap: int) -> void:
	_particle_cap = cap


## Aims the held weapon and drives the torch. Call before the solver steps: the
## torch is a per-substep emitter the grid loop reads.
func update(delta: float, gas_mode: bool) -> void:
	var aim := aim_ray()
	if flamethrower_firing and not gas_mode:
		var muzzle := weapons.muzzle_position()
		var direction := _weapon_direction(aim, muzzle)
		solver.set_torch(muzzle, direction, solver.torch_length)
		solver.set_torch_seed(muzzle, muzzle + direction * solver.torch_length,
			solver.torch_tip_radius + solver.cell_size * 8.0)
		weapons.set_firing(true)
	else:
		solver.clear_torch()
		weapons.set_firing(false)

	_bucket_cooldown = maxf(_bucket_cooldown - delta, 0.0)
	if water.initialized and jet_enabled:
		var muzzle := weapons.muzzle_position()
		water.jet_position = muzzle
		water.jet_direction = _weapon_direction(aim, muzzle)


## Where the player is looking: the camera, its forward axis, and the first solid
## along it (capped, so aiming at the sky still yields a usable point).
func aim_ray() -> Dictionary:
	var cam := player.get_camera()
	var origin := cam.global_position
	var direction := -cam.global_transform.basis.z
	var point := origin + direction * 4.0
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 12.0)
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.has("position"):
		point = hit["position"]
	return {"origin": origin, "direction": direction, "point": point}


## The three water buttons are a radio group: turning one on selects that intensity
## and clears the others; turning the active one off stops the jet.
func set_water_level(level: int, on: bool) -> void:
	if not on:
		if water_level == level:
			jet_enabled = false
			water_level = 0
			if _equipped == FireWeapons.Kind.WATER_GUN:
				equip(FireWeapons.Kind.NONE)
		return
	stop_flamethrower()
	equip(FireWeapons.Kind.WATER_GUN)
	water_level = level
	jet_enabled = true
	var p: Dictionary = WATER_PRESETS[level]
	water.jet_frequency = p.freq
	water.jet_velocity = p.vel
	water.jet_spray_angle = p.spray
	presentation.set_water_radius(p.radius)


func set_flamethrower(on: bool) -> void:
	if not on:
		solver.clear_torch()
		weapons.set_firing(false)
		flamethrower_firing = false
		if _equipped == FireWeapons.Kind.FLAMETHROWER:
			equip(FireWeapons.Kind.NONE)
		return
	flamethrower_firing = true
	jet_enabled = false
	water_level = 0
	equip(FireWeapons.Kind.FLAMETHROWER)
	weapons.set_firing(true)


func stop_flamethrower() -> void:
	flamethrower_firing = false
	solver.clear_torch()
	weapons.set_firing(false)


## Queued rather than called, because init_render is itself queued: calling
## directly would run against a FireWater that has not allocated its buffers yet
## and spawn nothing.
func pour_water() -> void:
	if _bucket_cooldown > 0.0 or not water.initialized:
		return
	_bucket_cooldown = BUCKET_INTERVAL
	# A bucket lobbed at the fire, not a packed ball: the old version put the whole
	# budget in a 0.4 m sphere, whose SPH pressure detonated it into an explosion.
	# It leaves the player's hands spread over a wide loose volume so the solver
	# does not blow it apart.
	stop_flamethrower()
	equip(FireWeapons.Kind.WATER_GUN)
	var aim := aim_ray()
	var muzzle := weapons.muzzle_position()
	var direction := _weapon_direction(aim, muzzle)
	var origin: Vector3 = muzzle + direction * 1.2
	var throw: Vector3 = direction * 8.0
	RenderingServer.call_on_render_thread(water.spawn_droplets.bind(
		mini(_particle_cap, 2000), origin, 0.5, throw))


func equip(kind: int) -> void:
	_equipped = kind
	weapons.equip(kind)


## Drops the weapon, the jet and the torch. Used by the fuel switch and by Reset.
func reset() -> void:
	jet_enabled = false
	water_level = 0
	flamethrower_firing = false
	solver.clear_torch()
	equip(FireWeapons.Kind.NONE)
	weapons.set_firing(false)


func _weapon_direction(aim: Dictionary, muzzle: Vector3) -> Vector3:
	var direction: Vector3 = aim["point"] - muzzle
	return direction.normalized() if direction.length() > 1.2 else aim["direction"]
