class_name SmokeProps extends Node3D
## The smoke demo's set per preset layout: ground, scenery, fixtures under the
## continuous emitters, lights and Jolt bodies. Baked props are voxelized into the
## grid's occupancy from their meshes; bodies and thrown flares are packed as
## moving obstacles and sources every frame. Every surface takes the renderer's
## smoke shadow as its next pass.

const ROCKS: Array[Mesh] = [
	preload("res://resources/fire/fire_rock_0.res"),
	preload("res://resources/fire/fire_rock_1.res"),
	preload("res://resources/fire/fire_rock_2.res"),
]
const STONE := preload("res://resources/fire/fire_stone.tres")
const CRATE := preload("res://resources/materials/props_crate.tres")
const METAL := preload("res://resources/materials/props_metal.tres")
const FLARE_COLORS: Array[Color] = [Color(0.92, 0.1, 0.08), Color(1.0, 0.5, 0.04),
	Color(0.55, 0.18, 0.9), Color(0.1, 0.75, 0.25), Color(0.12, 0.4, 1.0), Color(1.0, 0.85, 0.1)]
const MAX_FLARES := 3
const FLARE_SMOKE_S := 8.0
const FLARE_LIFE_S := 12.0
const FLARE_RADIUS_M := 0.04
const FLARE_LENGTH_M := 0.24
const FLARE_DENSITY_PER_S := 6.0
const FLARE_HEAT_K_PER_S := 150.0
const GROUND_SIZE_M := 600.0
const SPOT_SWEEP_M := Vector2(2.2, 1.0)

var shadow_material: Material
var _static_meshes: Array[MeshInstance3D] = []
var _bodies: Array[RigidBody3D] = []
var _flares: Array[RigidBody3D] = []
var _lights: Array[Light3D] = []
var _spots: Array[SpotLight3D] = []
var _materials := {}
var _thrown := 0


func build(preset: SmokePreset) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_static_meshes.clear()
	_bodies.clear()
	_flares.clear()
	_lights.clear()
	_spots.clear()
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	floor_shape.shape = BoxShape3D.new()
	(floor_shape.shape as BoxShape3D).size = Vector3(40.0, 1.0, 40.0)
	floor_body.position.y = -0.5
	floor_body.add_child(floor_shape)
	add_child(floor_body)
	match preset.layout:
		SmokePreset.Layout.FLARES:
			_add_ground(_downloaded("leafy_grass", Color(0.24, 0.33, 0.14), 0.0, 1.0, 3.0))
			_add_rock(0, Vector3(-4.6, 0.1, -2.6), 1.7, 30.0)
			_add_rock(1, Vector3(3.6, 0.1, -3.4), 1.4, 150.0)
			_add_rock(2, Vector3(-1.2, 0.1, -4.0), 1.1, 260.0)
			_add_crate(Vector3(0.9, 0.3, 2.0))
			_add_crate(Vector3(1.4, 0.3, 2.6))
			_add_sphere(0.3, 3.0, Vector3(-2.2, 0.3, 2.4), Color(0.85, 0.85, 0.82))
		SmokePreset.Layout.STACKS:
			_add_ground(_downloaded("clean_pebbles", Color(0.42, 0.4, 0.37), 0.0, 1.0, 2.0))
			var concrete := _downloaded("concrete_wall_001", Color(0.55, 0.52, 0.48), 0.0, 0.9, 2.0)
			_add_baked(_box_mesh(Vector3(4.0, 2.8, 2.6)), concrete, Vector3(-3.0, 1.4, -2.6))
			_add_baked(_box_mesh(Vector3(1.6, 1.3, 1.6)), concrete, Vector3(0.6, 0.65, -2.9))
			_add_crate(Vector3(1.8, 0.3, 1.6))
			_add_crate(Vector3(1.8, 0.9, 1.6))
			_add_crate(Vector3(2.5, 0.3, 1.2))
		SmokePreset.Layout.CANNON:
			_add_ground(_material(Color(0.035, 0.035, 0.04), 0.0, 0.95))
			# The drum is not baked: its piston emitter pushes the air inside it.
			_add_visual(_cylinder_mesh(1.05, 1.05, 1.6), _shaded(METAL), Vector3(-4.15, 2.5, 0.0),
				Vector3(0.0, 0.0, PI * 0.5))
			_add_baked(_box_mesh(Vector3(0.8, 1.45, 0.6)), _shaded(METAL), Vector3(-4.15, 0.72, 0.0))
			_add_baked(_torus_mesh(0.55, 1.1), _shaded(METAL), Vector3(-3.3, 2.5, 0.0),
				Vector3(0.0, 0.0, PI * 0.5))
			_add_baked(_torus_mesh(0.85, 0.95), _material(Color(0.85, 0.32, 0.08), 0.3, 0.4),
				Vector3(0.6, 2.5, 0.0), Vector3(0.0, 0.0, PI * 0.5))
			_add_baked(_box_mesh(Vector3(0.08, 1.55, 0.08)), _shaded(METAL), Vector3(0.6, 0.775, 0.0))
			for level in 3:
				_add_crate(Vector3(3.0, 0.3 + 0.6 * level, 0.0))
		SmokePreset.Layout.TUNNEL:
			_add_ground(_downloaded("grey_tiles", Color(0.3, 0.31, 0.33), 0.0, 0.7, 1.5))
			var wall := _material(Color(0.05, 0.055, 0.065), 0.3, 0.6)
			_add_visual(_box_mesh(Vector3(12.4, 4.2, 0.1)), wall, Vector3(0.0, 2.05, -2.1))
			# The overhead sun stands for the ceiling lights, so the ceiling casts no shadow.
			var ceiling := _add_visual(_box_mesh(Vector3(12.4, 0.1, 4.3)), wall, Vector3(0.0, 4.1, 0.0))
			ceiling.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			for z in [-1.3, 0.0, 1.3]:
				var strip := _add_visual(_box_mesh(Vector3(11.0, 0.03, 0.12)),
					_glow(Color(0.9, 0.95, 1.0), 3.0), Vector3(0.0, 4.04, z))
				strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_add_baked(_cylinder_mesh(0.3, 0.3, 4.0), _shaded(METAL), Vector3(-1.5, 2.0, 0.0),
				Vector3(PI * 0.5, 0.0, 0.0))
			var floater := _add_sphere(0.35, 20.0, Vector3(2.5, 2.0, 0.0), Color(0.85, 0.4, 0.12))
			floater.gravity_scale = 0.0
			floater.linear_damp = 3.0
			floater.angular_damp = 3.0
		SmokePreset.Layout.STAGE:
			_add_ground(_material(Color(0.02, 0.02, 0.025), 0.2, 0.25))
			var black := _material(Color(0.03, 0.03, 0.035), 0.0, 0.8)
			_add_baked(_box_mesh(Vector3(9.0, 0.8, 3.5)), _material(Color(0.07, 0.05, 0.04), 0.0, 0.5),
				Vector3(0.0, 0.4, -3.25))
			_add_visual(_box_mesh(Vector3(14.0, 7.0, 0.1)), _material(Color(0.12, 0.015, 0.025), 0.0, 1.0),
				Vector3(0.0, 3.5, -5.1))
			_add_baked(_box_mesh(Vector3(0.8, 1.6, 0.7)), black, Vector3(-4.0, 1.6, -3.4))
			_add_baked(_box_mesh(Vector3(0.8, 1.6, 0.7)), black, Vector3(4.0, 1.6, -3.4))
			_add_visual(_box_mesh(Vector3(10.0, 0.25, 0.25)), _shaded(METAL), Vector3(0.0, 5.35, -1.6))
			for i in 3:
				_add_spot(Vector3(-3.0 + 3.0 * i, 5.1, -1.6),
					[Color(1.0, 0.15, 0.7), Color(0.15, 0.75, 1.0), Color(1.0, 0.55, 0.12)][i])
			_add_case(Vector3(-2.0, 0.3, 1.8))
			_add_case(Vector3(2.4, 0.3, 1.4))
			_add_sphere(0.25, 2.0, Vector3(0.6, 0.25, 2.2), Color(0.8, 0.8, 0.85))
	for emitter in preset.emitters:
		if emitter.is_continuous() and emitter.density_per_s > 0.0:
			_add_fixture(preset.layout, emitter)


## World-space triangles of every baked prop (the floor is the solver's own wall).
func static_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	for instance in _static_meshes:
		var xform := instance.global_transform
		for vertex in instance.mesh.get_faces():
			faces.append(xform * vertex)
	return faces


func is_grabbable(body: Object) -> bool:
	return body is RigidBody3D and (_bodies.has(body) or _flares.has(body))


## Scene lights and burning flares, for the smoke to scatter.
func volume_lights() -> Array[Light3D]:
	return _lights


func throw_flare(origin_m: Vector3, velocity_mps: Vector3, time_s: float) -> void:
	if _flares.size() >= MAX_FLARES:
		_remove_flare(_flares[0])
	var color := FLARE_COLORS[_thrown % FLARE_COLORS.size()]
	_thrown += 1
	var shape := CylinderShape3D.new()
	shape.radius = FLARE_RADIUS_M
	shape.height = FLARE_LENGTH_M
	var flare := _make_body(shape, _cylinder_mesh(FLARE_RADIUS_M, FLARE_RADIUS_M, FLARE_LENGTH_M),
		0.4, _shaded(METAL))
	_add_flare_head(flare, color)
	flare.position = origin_m
	flare.linear_velocity = velocity_mps
	flare.angular_velocity = Vector3(4.0, 0.0, 2.0)
	flare.continuous_cd = true
	flare.set_meta("thrown_s", time_s)
	flare.set_meta("color", color)
	add_child(flare)
	_flares.append(flare)


func update(time_s: float) -> void:
	for flare in _flares.duplicate():
		var age := time_s - float(flare.get_meta("thrown_s"))
		if age > FLARE_LIFE_S:
			_remove_flare(flare)
		elif age > FLARE_SMOKE_S:
			_lights.erase(flare.get_meta("light"))
			(flare.get_meta("light") as Light3D).visible = false
			(flare.get_meta("head") as StandardMaterial3D).emission_enabled = false
	for i in _spots.size():
		var spot := _spots[i]
		var phase := time_s * 0.5 + i * 2.1
		var aim := Vector3(spot.position.x * 0.4 + sin(phase) * SPOT_SWEEP_M.x, 0.8,
			-1.0 + cos(phase * 0.7) * SPOT_SWEEP_M.y)
		spot.look_at(aim)


## Continuous and pulsed emitters on their schedule, triggered ones for trigger_s
## after [param action_s], plus the burning flares.
func pack_sources(emitters: Array[SmokeEmitter], time_s: float, action_s: float,
		rate_scale: float, heat_scale: float, speed_scale: float) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	for emitter in emitters:
		if emitter.is_on(time_s, action_s):
			packed.append_array(emitter.pack(rate_scale, heat_scale, speed_scale))
	for flare in _flares:
		if time_s - float(flare.get_meta("thrown_s")) < FLARE_SMOKE_S:
			packed.append_array(SmokeSolver.pack_source(
				flare.global_position + Vector3.UP * FLARE_LENGTH_M, Vector3.ONE * 0.25,
				FLARE_DENSITY_PER_S * rate_scale, FLARE_HEAT_K_PER_S * heat_scale, Vector3.ZERO, 0.0,
				flare.get_meta("color")))
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


## The prop a continuous emitter stands on: a burning canister, a chimney stack or
## a fog machine.
func _add_fixture(layout: SmokePreset.Layout, emitter: SmokeEmitter) -> void:
	var top := emitter.position_m - Vector3(0.0, emitter.extent_m.y, 0.0)
	match layout:
		SmokePreset.Layout.FLARES:
			var canister := _add_visual(_cylinder_mesh(FLARE_RADIUS_M, FLARE_RADIUS_M, FLARE_LENGTH_M),
				_shaded(METAL), Vector3(top.x, FLARE_LENGTH_M * 0.5, top.z))
			_add_flare_head(canister, emitter.color)
		SmokePreset.Layout.STACKS:
			var height := top.y
			_add_baked(_cylinder_mesh(0.42, 0.55, height),
				_downloaded("concrete_wall_001", Color(0.55, 0.52, 0.48), 0.0, 0.9, 2.0),
				Vector3(top.x, height * 0.5, top.z))
			_add_visual(_cylinder_mesh(0.44, 0.44, 0.5), _material(Color(0.08, 0.07, 0.065), 0.0, 0.9),
				Vector3(top.x, height - 0.25, top.z))
		SmokePreset.Layout.STAGE:
			_add_visual(_box_mesh(Vector3(0.55, 0.3, 0.4)), _material(Color(0.03, 0.03, 0.035), 0.4, 0.5),
				Vector3(top.x, top.y - 0.12, top.z - 0.4))


## Burning cap and its light on a canister centred at the parent's origin.
func _add_flare_head(parent: Node3D, color: Color) -> void:
	var head := StandardMaterial3D.new()
	head.albedo_color = color
	head.emission_enabled = true
	head.emission = color
	head.emission_energy_multiplier = 6.0
	var cap := MeshInstance3D.new()
	cap.mesh = _cylinder_mesh(FLARE_RADIUS_M * 1.05, FLARE_RADIUS_M * 1.05, 0.04)
	cap.material_override = head
	cap.position.y = FLARE_LENGTH_M * 0.5
	parent.add_child(cap)
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 1.5
	light.omni_range = 3.0
	light.position.y = FLARE_LENGTH_M * 0.5 + 0.08
	parent.add_child(light)
	parent.set_meta("light", light)
	parent.set_meta("head", head)
	_lights.append(light)


func _add_spot(position_m: Vector3, color: Color) -> void:
	var spot := SpotLight3D.new()
	spot.light_color = color
	spot.light_energy = 7.0
	spot.spot_range = 14.0
	spot.spot_angle = 16.0
	spot.spot_angle_attenuation = 2.0
	spot.light_volumetric_fog_energy = 6.0
	spot.position = position_m
	add_child(spot)
	_add_visual(_cylinder_mesh(0.14, 0.2, 0.35), _shaded(METAL), position_m + Vector3(0.0, 0.1, 0.0))
	_spots.append(spot)
	_lights.append(spot)


func _add_ground(material: Material) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * GROUND_SIZE_M
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = material
	add_child(ground)


func _add_rock(index: int, position_m: Vector3, scale_factor: float, yaw_deg: float) -> void:
	var rock := _add_baked(ROCKS[index], _shaded(STONE), position_m,
		Vector3(0.0, deg_to_rad(yaw_deg), 0.0))
	rock.scale = Vector3.ONE * scale_factor


## Static prop the smoke flows around: collision for the bodies, mesh for the grid.
func _add_baked(mesh: Mesh, material: Material, position_m: Vector3,
		rotation_rad := Vector3.ZERO) -> MeshInstance3D:
	var body := StaticBody3D.new()
	body.position = position_m
	body.rotation = rotation_rad
	var collision := CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	body.add_child(collision)
	add_child(body)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	body.add_child(instance)
	_static_meshes.append(instance)
	return instance


## Set dressing outside the smoke's reach, or too thin to matter to it.
func _add_visual(mesh: Mesh, material: Material, position_m: Vector3,
		rotation_rad := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position_m
	instance.rotation = rotation_rad
	add_child(instance)
	return instance


func _add_sphere(radius_m: float, mass_kg: float, position_m: Vector3, color: Color) -> RigidBody3D:
	var shape := SphereShape3D.new()
	shape.radius = radius_m
	var mesh := SphereMesh.new()
	mesh.radius = radius_m
	mesh.height = radius_m * 2.0
	var body := _make_body(shape, mesh, mass_kg, _material(color, 0.0, 0.45))
	body.position = position_m
	add_child(body)
	_bodies.append(body)
	return body


func _add_crate(position_m: Vector3) -> void:
	_add_box(Vector3.ONE * 0.6, 8.0, position_m, _shaded(CRATE))


func _add_case(position_m: Vector3) -> void:
	_add_box(Vector3(0.9, 0.6, 0.6), 12.0, position_m, _material(Color(0.04, 0.04, 0.045), 0.6, 0.35))


func _add_box(size_m: Vector3, mass_kg: float, position_m: Vector3, material: Material) -> void:
	var shape := BoxShape3D.new()
	shape.size = size_m
	var body := _make_body(shape, _box_mesh(size_m), mass_kg, material)
	body.position = position_m
	add_child(body)
	_bodies.append(body)


func _make_body(shape: Shape3D, mesh: Mesh, mass_kg: float, material: Material) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass_kg
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	body.add_child(instance)
	return body


func _remove_flare(flare: RigidBody3D) -> void:
	_flares.erase(flare)
	_lights.erase(flare.get_meta("light"))
	flare.queue_free()


func _box_mesh(size_m: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size_m
	return mesh


func _cylinder_mesh(top_radius_m: float, bottom_radius_m: float, height_m: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius_m
	mesh.bottom_radius = bottom_radius_m
	mesh.height = height_m
	return mesh


func _torus_mesh(inner_m: float, outer_m: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_m
	mesh.outer_radius = outer_m
	return mesh


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var key := [color, metallic, roughness]
	if not _materials.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.metallic = metallic
		material.roughness = roughness
		material.next_pass = shadow_material
		_materials[key] = material
	return _materials[key]


func _glow(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.BLACK
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


## A shared material with the smoke shadow, never the preloaded resource itself.
func _shaded(source: Material) -> Material:
	if not _materials.has(source):
		var material := source.duplicate() as Material
		material.next_pass = shadow_material
		_materials[source] = material
	return _materials[source]


func _downloaded(asset: String, fallback: Color, metallic: float, roughness: float,
		tile_m: float) -> Material:
	var key := [asset, tile_m]
	if not _materials.has(key):
		var material := GeometryKit.make_downloaded_material(asset, fallback, metallic, roughness,
			1.0 / tile_m)
		material.uv1_triplanar = true
		material.uv1_world_triplanar = true
		material.next_pass = shadow_material
		_materials[key] = material
	return _materials[key]
