class_name WaterBuoyancy
extends Node3D
## Buoyancy for Jolt rigid bodies on the Gerstner water surface.
## Mirrors the wave math from ocean.gdshader (same params, same time) so
## floating objects follow the rendered surface exactly.

signal body_splashed(position: Vector3, strength: float)

const GRAVITY := 9.8
const MAX_DEPTH := 1.5

@export var buoyancy := 26.0
@export var linear_drag := 1.4
@export var angular_drag := 0.8
@export var splash_min_speed := 2.0

var waves: Array[Vector4] = []
var wave_height := 1.0
var choppiness := 1.0
var wave_time := 0.0
var water_level := 0.0

var _bodies: Array[RigidBody3D] = []
var _probe_offsets: Dictionary = {}
var _submerged: Dictionary = {}
var _drift_cooldown: Dictionary = {}


func register_body(body: RigidBody3D, half_extents: Vector3) -> void:
	_bodies.append(body)
	var hx := maxf(half_extents.x * 0.7, 0.1)
	var hz := maxf(half_extents.z * 0.7, 0.1)
	_probe_offsets[body] = [
		Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz),
		Vector3(-hx, 0, hz), Vector3(hx, 0, hz),
	]
	_submerged[body] = false
	_drift_cooldown[body] = 0.0


func clear_bodies() -> void:
	_bodies.clear()
	_probe_offsets.clear()
	_submerged.clear()
	_drift_cooldown.clear()


func get_water_height(world_pos: Vector3) -> float:
	var p := Vector2(world_pos.x, world_pos.z)
	var sample := p
	for i in 3:
		var disp := _displacement(sample)
		sample = p - Vector2(disp.x, disp.z)
	return water_level + _displacement(sample).y


func _physics_process(delta: float) -> void:
	for i in range(_bodies.size() - 1, -1, -1):
		var body := _bodies[i]
		if not is_instance_valid(body):
			_bodies.remove_at(i)
			continue
		_apply_buoyancy(body, delta)


func _apply_buoyancy(body: RigidBody3D, delta: float) -> void:
	var probes: Array = _probe_offsets[body]
	var submerged_count := 0

	for offset: Vector3 in probes:
		var world_p: Vector3 = body.global_transform * offset
		var depth := get_water_height(world_p) - world_p.y
		if depth <= 0.0:
			continue
		submerged_count += 1
		var force := Vector3.UP * (buoyancy * clampf(depth, 0.0, MAX_DEPTH) * body.mass / probes.size())
		body.apply_force(force, world_p - body.global_position)

	if submerged_count > 0:
		var frac := float(submerged_count) / probes.size()
		body.apply_central_force(-body.linear_velocity * linear_drag * frac * body.mass)
		body.apply_torque(-body.angular_velocity * angular_drag * frac * body.mass)

	var now_submerged := submerged_count > 0
	_drift_cooldown[body] = maxf(0.0, _drift_cooldown[body] - delta)
	if now_submerged and not _submerged[body]:
		var impact := absf(body.linear_velocity.y)
		if impact > splash_min_speed:
			body_splashed.emit(body.global_position, impact)
			_drift_cooldown[body] = 0.3
	elif now_submerged and _drift_cooldown[body] <= 0.0 \
			and Vector2(body.linear_velocity.x, body.linear_velocity.z).length_squared() > 2.25:
		body_splashed.emit(body.global_position, 0.5)
		_drift_cooldown[body] = 0.25
	_submerged[body] = now_submerged


func _displacement(p: Vector2) -> Vector3:
	var out := Vector3.ZERO
	for w in waves:
		if w.w < 0.01:
			continue
		var k := TAU / w.w
		var speed := sqrt(GRAVITY / k)
		var d := Vector2(w.x, w.y).normalized()
		var f := k * (d.dot(p) - speed * wave_time)
		var a := (w.z / k) * wave_height
		out.x += d.x * a * choppiness * cos(f)
		out.y += a * sin(f)
		out.z += d.y * a * choppiness * cos(f)
	return out
