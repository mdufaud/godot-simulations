class_name SmokeProps extends Node3D
## The smoke demo's scenery per preset layout. Static props are baked into the
## grid's occupancy from their meshes; Jolt bodies and grenades are packed as
## moving obstacles and sources every frame.

const ROCKS: Array[Mesh] = [
	preload("res://resources/fire/fire_rock_0.res"),
	preload("res://resources/fire/fire_rock_1.res"),
	preload("res://resources/fire/fire_rock_2.res"),
]
const MAX_GRENADES := 3
const GRENADE_SMOKE_S := 6.0
const GRENADE_LIFE_S := 9.0
const GRENADE_RADIUS_M := 0.07

var _static_meshes: Array[MeshInstance3D] = []
var _bodies: Array[RigidBody3D] = []
var _grenades: Array[RigidBody3D] = []
var _materials := {}


func build(preset: SmokePreset) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_static_meshes.clear()
	_bodies.clear()
	_grenades.clear()
	_add_static(BoxShape3D.new(), _box_mesh(Vector3(40.0, 1.0, 40.0)), Vector3(0.0, -0.5, 0.0),
		Vector3.ZERO, Color(0, 0, 0), false)
	match preset.layout:
		SmokePreset.Layout.YARD:
			_add_static_box(Vector3(0.7, 2.2, 0.7), Vector3(-1.6, 1.1, -0.6), Color(0.45, 0.22, 0.17))
			_add_rock(0, Vector3(0.9, 0.2, 1.4), 1.1, 20.0)
			_add_rock(1, Vector3(1.7, 0.2, -1.2), 0.9, 140.0)
			_add_rock(2, Vector3(-0.4, 0.2, 1.9), 0.8, 260.0)
			_add_sphere(0.35, 20.0, Vector3(0.4, 0.35, 0.0))
			_add_box(Vector3(0.5, 0.5, 0.5), 8.0, Vector3(1.2, 0.25, 0.2))
			_add_box(Vector3(0.5, 0.5, 0.5), 8.0, Vector3(1.2, 0.75, 0.2))
			_add_box(Vector3(0.6, 0.4, 0.6), 8.0, Vector3(-0.6, 0.2, -1.9))
		SmokePreset.Layout.TUNNEL:
			_add_torus(0.4, 0.75, Vector3(2.0, 2.0, 0.0), Vector3(PI * 0.5, 0.0, 0.0))
			var floater := _add_sphere(0.45, 20.0, Vector3(-2.2, 2.0, 0.0))
			floater.gravity_scale = 0.0
			floater.linear_damp = 3.0
			floater.angular_damp = 3.0
		SmokePreset.Layout.CANNON:
			_add_torus(0.7, 1.1, Vector3(-3.3, 2.5, 0.0), Vector3(0.0, 0.0, PI * 0.5))
			for level in 3:
				_add_box(Vector3(0.6, 0.6, 0.6), 6.0, Vector3(3.0, 0.3 + 0.6 * level, 0.0))
		SmokePreset.Layout.DRY_ICE:
			_add_static_box(Vector3(1.8, 0.9, 1.1), Vector3(0.0, 0.45, 0.0), Color(0.36, 0.28, 0.22))
			_add_rock(0, Vector3(-2.0, 0.2, 1.2), 1.0, 70.0)
			_add_rock(1, Vector3(1.8, 0.2, -1.6), 1.2, 200.0)
			_add_rock(2, Vector3(2.2, 0.2, 1.8), 0.9, 320.0)
			_add_box(Vector3(0.5, 0.5, 0.5), 8.0, Vector3(-1.6, 0.25, -1.5))
			_add_box(Vector3(0.5, 0.5, 0.5), 8.0, Vector3(1.4, 0.25, 1.0))
			_add_sphere(0.3, 10.0, Vector3(-0.5, 0.3, 2.0))


## World-space triangles of every static prop except the floor (the solver's
## own wall).
func static_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	for instance in _static_meshes:
		var xform := instance.global_transform
		for vertex in instance.mesh.get_faces():
			faces.append(xform * vertex)
	return faces


func is_grabbable(body: Object) -> bool:
	return body is RigidBody3D and (_bodies.has(body) or _grenades.has(body))


func throw_grenade(origin_m: Vector3, velocity_mps: Vector3, time_s: float) -> void:
	if _grenades.size() >= MAX_GRENADES:
		_remove_grenade(_grenades[0])
	var shape := SphereShape3D.new()
	shape.radius = GRENADE_RADIUS_M
	var grenade := _make_body(shape, _sphere_mesh(GRENADE_RADIUS_M), 0.5, Color(0.25, 0.32, 0.2))
	grenade.position = origin_m
	grenade.linear_velocity = velocity_mps
	grenade.continuous_cd = true
	grenade.set_meta("thrown_s", time_s)
	add_child(grenade)
	_grenades.append(grenade)


func update(time_s: float) -> void:
	for grenade in _grenades.duplicate():
		if time_s - float(grenade.get_meta("thrown_s")) > GRENADE_LIFE_S:
			_remove_grenade(grenade)


func pack_sources(emitters: Array[SmokeEmitter], time_s: float, forced: bool, rate_scale: float,
		heat_scale: float, speed_scale: float) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	for emitter in emitters:
		if forced or emitter.is_on(time_s):
			packed.append_array(emitter.pack(rate_scale * (3.0 if forced else 1.0), heat_scale,
				speed_scale))
	for grenade in _grenades:
		if time_s - float(grenade.get_meta("thrown_s")) < GRENADE_SMOKE_S:
			packed.append_array(SmokeSolver.pack_source(grenade.global_position,
				Vector3.ONE * 0.22, 5.0 * rate_scale, 0.0, Vector3.ZERO, 0.0))
	return packed


func pack_obstacles() -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	for body in _bodies:
		var shape := (body.get_child(0) as CollisionShape3D).shape
		if shape is SphereShape3D:
			packed.append_array(SmokeSolver.pack_sphere(body.global_position,
				(shape as SphereShape3D).radius, body.linear_velocity, body.angular_velocity))
		elif shape is BoxShape3D:
			packed.append_array(SmokeSolver.pack_box(body.global_transform,
				(shape as BoxShape3D).size * 0.5, body.linear_velocity, body.angular_velocity))
	return packed


func _add_static_box(size_m: Vector3, center_m: Vector3, color: Color) -> void:
	var shape := BoxShape3D.new()
	shape.size = size_m
	_add_static(shape, _box_mesh(size_m), center_m, Vector3.ZERO, color, true)


func _add_rock(index: int, position_m: Vector3, scale: float, yaw_deg: float) -> void:
	var mesh := ROCKS[index]
	var body := _add_static(mesh.create_convex_shape(), mesh, position_m,
		Vector3(0.0, deg_to_rad(yaw_deg), 0.0), Color(0.42, 0.4, 0.38), true)
	body.scale = Vector3.ONE * scale


func _add_torus(inner_m: float, outer_m: float, position_m: Vector3, rotation_rad: Vector3) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_m
	mesh.outer_radius = outer_m
	_add_static(mesh.create_trimesh_shape(), mesh, position_m, rotation_rad,
		Color(0.55, 0.5, 0.42), true)


func _add_static(shape: Shape3D, mesh: Mesh, position_m: Vector3, rotation_rad: Vector3,
		color: Color, baked: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = position_m
	body.rotation = rotation_rad
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	add_child(body)
	if baked:
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = _material(color)
		body.add_child(instance)
		_static_meshes.append(instance)
	return body


func _add_sphere(radius_m: float, mass_kg: float, position_m: Vector3) -> RigidBody3D:
	var shape := SphereShape3D.new()
	shape.radius = radius_m
	var body := _make_body(shape, _sphere_mesh(radius_m), mass_kg, Color(0.78, 0.42, 0.16))
	body.position = position_m
	add_child(body)
	_bodies.append(body)
	return body


func _add_box(size_m: Vector3, mass_kg: float, position_m: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size_m
	var body := _make_body(shape, _box_mesh(size_m), mass_kg, Color(0.24, 0.45, 0.62))
	body.position = position_m
	add_child(body)
	_bodies.append(body)


func _make_body(shape: Shape3D, mesh: Mesh, mass_kg: float, color: Color) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass_kg
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color)
	body.add_child(instance)
	return body


func _remove_grenade(grenade: RigidBody3D) -> void:
	_grenades.erase(grenade)
	grenade.queue_free()


func _box_mesh(size_m: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size_m
	return mesh


func _sphere_mesh(radius_m: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius_m
	mesh.height = radius_m * 2.0
	return mesh


func _material(color: Color) -> StandardMaterial3D:
	if not _materials.has(color):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.85
		_materials[color] = material
	return _materials[color]
