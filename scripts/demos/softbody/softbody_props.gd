class_name SoftBodyProps extends Node3D
## Everything Jolt simulates in the soft body demo: the layout's static props,
## the press plate, thrown balls and falling rocks. Each one holds a stable slot
## in the solver's collider list, so the contact force the solver reads back for
## a slot lands on the body that held it.

const MAX_DYNAMIC := 40
const PRESS_SIZE_M := Vector3(1.8, 0.2, 1.2)
const PRESS_TOP_M := 1.6
const PRESS_BOTTOM_M := 0.15
const PRESS_PERIOD_S := 5.0
const BALL_RADIUS_M := 0.14
const BALL_MASS_KG := 3.0
## The solver shoves the jelly as if a body were immovable, and the body gets the
## reaction a tick late: the push is damped on the body's normal velocity and may at
## most carry its weight (with margin) and stop its approach, along the reaction's
## direction smoothed over REACTION_SMOOTHING_S (it jitters with the jelly's
## wobble). Friction may only oppose the body's slide, at most stopping it.
const REACTION_SMOOTHING_S := 0.1
const REACTION_SUPPORT := 1.2
const REACTION_RESTITUTION := 0.3
const REACTION_DAMPING_HZ := 30.0

var _slots: Array[CollisionShape3D] = []
var _bodies: Array[PhysicsBody3D] = []
var _smoothed := PackedVector3Array()
var _dynamic: Array[RigidBody3D] = []
var _press: AnimatableBody3D
var _press_phase := 0.0
var _press_previous := Vector3.ZERO
var _press_velocity := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _materials := {}


func build(preset: SoftBodyPreset) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_slots.clear()
	_bodies.clear()
	_dynamic.clear()
	_smoothed.clear()
	_press = null
	_press_phase = 0.0
	_rng.seed = 7
	match preset.layout:
		SoftBodyPreset.Layout.STAIRS:
			for step in 3:
				_add_static(Vector3(1.2, 0.3 * (step + 1), 0.8),
					Vector3(0.6 - 0.8 * step, 0.15 * (step + 1), 0.0), Color(0.55, 0.5, 0.45))
		SoftBodyPreset.Layout.PEGS:
			for i in 5:
				var x := -1.2 + 0.6 * i
				_add_static(Vector3(0.12, 0.5, 1.4), Vector3(x, 0.25, 0.0), Color(0.4, 0.42, 0.46))
		SoftBodyPreset.Layout.PRESS:
			_press = AnimatableBody3D.new()
			_press.position = Vector3(0.0, PRESS_TOP_M, 0.0)
			_attach(_press, _box_shape(PRESS_SIZE_M), PRESS_SIZE_M, Color(0.6, 0.62, 0.66), 0.0)
			for side in [-1.0, 1.0]:
				_add_static(Vector3(0.12, 2.2, 0.12), Vector3(side * 1.0, 1.1, -0.65),
					Color(0.3, 0.3, 0.32))
			_press_previous = _press.position
	for i in preset.rock_count:
		drop_rock(preset.camera_target_m)


func press_available() -> bool:
	return _press != null


## Lowers and raises the press plate while on; it parks at the top when off.
func animate_press(delta: float, on: bool) -> void:
	if _press == null:
		return
	if on or _press_phase > 0.0:
		_press_phase = fmod(_press_phase + delta / PRESS_PERIOD_S, 1.0) if on \
			else maxf(_press_phase - delta / PRESS_PERIOD_S, 0.0)
	var lift := 0.5 + 0.5 * cos(_press_phase * TAU)
	_press.position.y = lerpf(PRESS_BOTTOM_M + PRESS_SIZE_M.y * 0.5, PRESS_TOP_M, lift)
	_press_velocity = (_press.position - _press_previous) / maxf(delta, 1e-4)
	_press_previous = _press.position


func throw_ball(origin: Vector3, velocity: Vector3) -> void:
	var ball := _rigid(origin, BALL_MASS_KG)
	var shape := SphereShape3D.new()
	shape.radius = BALL_RADIUS_M
	_attach(ball, shape, Vector3.ONE * BALL_RADIUS_M, Color(0.95, 0.75, 0.2), BALL_RADIUS_M)
	ball.linear_velocity = velocity


func drop_rock(center: Vector3) -> void:
	var size := Vector3(_rng.randf_range(0.15, 0.3), _rng.randf_range(0.12, 0.25),
		_rng.randf_range(0.15, 0.3))
	var origin := Vector3(center.x + _rng.randf_range(-0.8, 0.8), _rng.randf_range(2.5, 4.5),
		center.z + _rng.randf_range(-0.8, 0.8))
	var rock := _rigid(origin, 2500.0 * size.x * size.y * size.z)
	rock.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, 0.0)
	_attach(rock, _box_shape(size), size, Color(0.45, 0.43, 0.4), 0.0)


func dynamic_count() -> int:
	return _dynamic.size()


## Every slot as a solver collider; freed slots stay as empty entries.
func pack_colliders() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for slot in _slots.size():
		var shape_node := _slots[slot]
		if shape_node == null or not is_instance_valid(shape_node):
			var empty := PackedFloat32Array()
			empty.resize(SoftBodySolver.COLLIDER_VEC4S * 4)
			empty[19] = -1.0
			out.append_array(empty)
			continue
		var body := _bodies[slot]
		var linear := _press_velocity if body == _press else Vector3.ZERO
		var angular := Vector3.ZERO
		if body is RigidBody3D:
			linear = (body as RigidBody3D).linear_velocity
			angular = (body as RigidBody3D).angular_velocity
		var shape := shape_node.shape
		var xform := shape_node.global_transform
		if shape is SphereShape3D:
			out.append_array(SoftBodySolver.pack_collider(SoftBodySolver.COLLIDER_SPHERE, xform,
				Vector3((shape as SphereShape3D).radius, 0.0, 0.0), linear, angular,
				body is RigidBody3D))
		else:
			out.append_array(SoftBodySolver.pack_collider(SoftBodySolver.COLLIDER_BOX, xform,
				(shape as BoxShape3D).size * 0.5, linear, angular, body is RigidBody3D))
	return out


## Physics tick: pushes each dynamic body with the force its slot received.
func apply_reactions(reactions: PackedFloat32Array, delta: float) -> void:
	var gravity := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	for slot in _slots.size():
		var body := _bodies[slot] as RigidBody3D
		if body == null or not is_instance_valid(body) or slot * 6 + 5 >= reactions.size():
			continue
		var raw := Vector3(reactions[slot * 6], reactions[slot * 6 + 1], reactions[slot * 6 + 2])
		var torque := Vector3(reactions[slot * 6 + 3], reactions[slot * 6 + 4],
			reactions[slot * 6 + 5])
		_smoothed[slot] = _smoothed[slot].lerp(raw, 1.0 - exp(-delta / REACTION_SMOOTHING_S))
		var magnitude := raw.length()
		if magnitude < 1e-6:
			continue
		var n := (_smoothed[slot] if _smoothed[slot].length() > 1e-6 else raw).normalized()
		var v := body.linear_velocity
		var v_n := v.dot(n)
		var push := clampf(raw.dot(n) - body.mass * REACTION_DAMPING_HZ * v_n, 0.0,
			body.mass * (REACTION_SUPPORT * maxf(-gravity.dot(n), 0.0)
				+ (1.0 + REACTION_RESTITUTION) * maxf(-v_n, 0.0) / delta))
		var slide := v - n * v_n
		var applied := n * push
		if slide.length() > 1e-6:
			var against := -slide.normalized()
			applied += against * clampf(raw.dot(against), 0.0, body.mass * slide.length() / delta)
		body.apply_central_force(applied)
		body.apply_torque(torque * minf(applied.length() / maxf(raw.length(), 1e-6), 1.0))


func clear_dynamic() -> void:
	for body in _dynamic:
		if is_instance_valid(body):
			_free_slot(body)
			body.queue_free()
	_dynamic.clear()


func _process(_delta: float) -> void:
	for i in range(_dynamic.size() - 1, -1, -1):
		var body := _dynamic[i]
		if body.global_position.y < -5.0:
			_free_slot(body)
			body.queue_free()
			_dynamic.remove_at(i)


func _add_static(size: Vector3, origin: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = origin
	_attach(body, _box_shape(size), size, color, 0.0)


func _rigid(origin: Vector3, mass_kg: float) -> RigidBody3D:
	if _dynamic.size() >= MAX_DYNAMIC:
		var oldest := _dynamic.pop_front() as RigidBody3D
		_free_slot(oldest)
		oldest.queue_free()
	var body := RigidBody3D.new()
	body.mass = mass_kg
	body.position = origin
	body.can_sleep = false
	_dynamic.append(body)
	return body


func _attach(body: PhysicsBody3D, shape: Shape3D, size: Vector3, color: Color,
		radius: float) -> void:
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	var mesh := MeshInstance3D.new()
	if radius > 0.0:
		var sphere := SphereMesh.new()
		sphere.radius = radius
		sphere.height = radius * 2.0
		mesh.mesh = sphere
	else:
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
	mesh.material_override = _material(color)
	body.add_child(mesh)
	add_child(body)
	var slot := _slots.find(null)
	if slot < 0:
		if _slots.size() >= SoftBodySolver.MAX_COLLIDERS:
			return
		slot = _slots.size()
		_slots.append(null)
		_bodies.append(null)
		_smoothed.append(Vector3.ZERO)
	_slots[slot] = collision
	_bodies[slot] = body
	_smoothed[slot] = Vector3.ZERO


func _free_slot(body: PhysicsBody3D) -> void:
	var slot := _bodies.find(body)
	if slot >= 0:
		_slots[slot] = null
		_bodies[slot] = null


func _box_shape(size: Vector3) -> BoxShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	return shape


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.8
		_materials[color] = material
	return _materials[color]
