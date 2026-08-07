extends Node3D

const SPHERE_PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")
const PLATE_PROFILE := preload("res://resources/ambient_fluid/plate_bem.tres")
const BOX_PROFILE := preload("res://resources/ambient_fluid/body_bem.tres")
const FALLING_PLATE := preload("res://resources/ambient_fluid/presets/falling_plate.tres")
const MAGNUS_BALL := preload("res://resources/ambient_fluid/presets/magnus_ball.tres")
const BALLOON := preload("res://resources/ambient_fluid/presets/balloon.tres")
const UNDERWATER_BODY := preload("res://resources/ambient_fluid/presets/underwater_body.tres")
const WATER_LEVEL := 0.4
const POOL_HALF_SIZE := Vector2(6.8, 4.8)
const MAX_OBJECTS := 24
const MEDIUM_NAMES := ["Water", "Oil", "Honey", "Air", "Vacuum"]
const MEDIUM_DENSITIES := [998.0, 850.0, 1420.0, 1.204, 0.0]
const MEDIUM_VISCOSITIES := [1.002e-3, 0.065, 2.0, 1.81e-5, 0.0]
const OBJECT_NAMES := ["Ball", "Cube", "Plate", "Random"]
const SCENARIO_NAMES := ["Pool Showcase", "Falling Plate", "Magnus Ball", "Balloon", "Underwater Body"]
const SCIENTIFIC_PRESETS := [FALLING_PLATE, MAGNUS_BALL, BALLOON, UNDERWATER_BODY]
const TRAJECTORY_LIMIT := 3600

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_camera: OrbitCamera = $CameraPivot
@onready var water_surface: MeshInstance3D = $Pool/WaterSurface
@onready var water_volume: MeshInstance3D = $Pool/WaterVolume
@onready var medium_label: Label3D = $Pool/MediumLabel

var fluid_body: AmbientFluidBody3D
var bodies: Array[AmbientFluidBody3D] = []
var demo_menu := AmbientFluidMenu.new()
var _medium_index := 0
var _object_index := 3
var _object_density_kg_m3 := 35.0
var _throw_speed_m_s := 5.0
var _flow_speed_m_s := 0.0
var _spawn_serial := 0
var _last_action := "Ready"
var _rng := RandomNumberGenerator.new()
var _scenario_index := 0
var _vacuum_baseline := true
var _trajectory_rows: Array[String] = []


func _ready() -> void:
	orbit_camera.target = Vector3(0.0, -0.6, 0.0)
	orbit_camera.distance = 15.5
	orbit_camera.pitch = -18.0
	orbit_camera.yaw = 0.0
	orbit_camera.min_distance = 7.0
	orbit_camera.max_distance = 26.0
	_rng.seed = 0xA6B1E17
	menu.persist_id = "ambient_fluid_demo_v2"
	demo_menu.build(menu, _medium_index, _object_index, _object_density_kg_m3,
		_throw_speed_m_s, _flow_speed_m_s, {
			scenario = _set_scenario,
			fluid_model = _set_fluid_model,
			vacuum_baseline = _set_vacuum_baseline,
			fluid_density = _set_custom_fluid_density,
			viscosity = _set_custom_viscosity,
			separation = _set_custom_separation,
			initial_speed = _set_initial_speed,
			initial_spin = _set_initial_spin,
			medium = _set_medium,
			object = _set_object,
			object_density = _set_object_density,
			throw_speed = _set_throw_speed,
			flow_speed = _set_flow_speed,
			next_fluid = _cycle_medium,
			throw = _throw_object,
			drop_mix = _drop_buoyancy_set,
			reset = _reset_experiment,
			clear = _clear_objects,
			export_csv = _export_csv,
		})
	_update_medium_visuals()
	_drop_buoyancy_set()


func _physics_process(_delta: float) -> void:
	if _trajectory_rows.size() >= TRAJECTORY_LIMIT:
		return
	for body in bodies:
		if not is_instance_valid(body) or _trajectory_rows.size() >= TRAJECTORY_LIMIT:
			break
		_trajectory_rows.append("%d,%s,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f" % [
			Engine.get_physics_frames(), body.name, body.global_position.x,
			body.global_position.y, body.global_position.z, body.linear_velocity.x,
			body.linear_velocity.y, body.linear_velocity.z, body.kinetic_energy_j()])


func _process(_delta: float) -> void:
	for index in range(bodies.size() - 1, -1, -1):
		var body := bodies[index]
		if not is_instance_valid(body) or body.global_position.y < -12.0 \
				or body.global_position.length() > 80.0:
			if is_instance_valid(body):
				body.queue_free()
			bodies.remove_at(index)
	demo_menu.update_status(bodies, MEDIUM_NAMES[_medium_index], _last_action,
		SCENARIO_NAMES[_scenario_index])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo and key.physical_keycode == KEY_SPACE:
			_throw_object()
			get_viewport().set_input_as_handled()
		elif key.pressed and not key.echo and key.physical_keycode == KEY_F:
			_cycle_medium()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
			_throw_object()
			get_viewport().set_input_as_handled()


func _throw_object() -> void:
	if _scenario_index != 0:
		_scenario_index = 0
		_clear_objects()
	var type_index := _resolved_object_index()
	var spawn_position := Vector3(
		_rng.randf_range(-5.4, 5.4),
		_rng.randf_range(2.0, 4.8),
		_rng.randf_range(-3.4, 3.4))
	var target := Vector3(
		_rng.randf_range(-5.0, 5.0),
		_rng.randf_range(-0.8, 0.35),
		_rng.randf_range(-3.2, 3.2))
	var direction := (target - spawn_position).normalized()
	var speed := _rng.randf_range(maxf(1.0, _throw_speed_m_s * 0.45), _throw_speed_m_s)
	var velocity := direction * speed
	_spawn_body(type_index, _object_density_kg_m3, spawn_position, velocity,
		Vector3(_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0),
			_rng.randf_range(-2.0, 2.0)))
	_last_action = "Dropped %s at %.1f m/s into pool (%.0f kg/m³)" % [
		OBJECT_NAMES[type_index], speed, _object_density_kg_m3]


func _drop_buoyancy_set() -> void:
	_scenario_index = 0
	demo_menu.sync_scenario(0)
	var samples: Array[Dictionary] = _showcase_samples()
	for index in samples.size():
		var sample: Dictionary = samples[index]
		var body := _spawn_body(index % 3, float(sample.density),
			Vector3(-4.2 + index * 2.8, 4.8 + index * 0.35, -0.8),
			Vector3.ZERO, Vector3(0.4, 0.7, -0.25), sample.color)
		body.name = "Buoyancy_%d" % index
	_last_action = "Dropped four density probes for %s" % MEDIUM_NAMES[_medium_index]


func _showcase_samples() -> Array[Dictionary]:
	if _medium_index >= 3:
		return [
			{density = 0.35, color = Color(0.96, 0.72, 0.2)},
			{density = 1.0, color = Color(0.25, 0.8, 0.95)},
			{density = 5.0, color = Color(0.95, 0.38, 0.25)},
			{density = 2600.0, color = Color(0.55, 0.6, 0.7)},
		]
	return [
		{density = 35.0, color = Color(0.96, 0.72, 0.2)},
		{density = 650.0, color = Color(0.25, 0.8, 0.95)},
		{density = 1050.0, color = Color(0.95, 0.38, 0.25)},
		{density = 2600.0, color = Color(0.55, 0.6, 0.7)},
	]


func _spawn_body(type_index: int, density: float, spawn_position: Vector3,
		velocity: Vector3, spin: Vector3, color_override := Color.TRANSPARENT,
		config_override: AmbientFluidConfig = null, uniform_medium := false,
		fluid_active := true) -> AmbientFluidBody3D:
	while bodies.size() >= MAX_OBJECTS:
		var oldest: AmbientFluidBody3D = bodies.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	var body := AmbientFluidBody3D.new()
	_spawn_serial += 1
	body.name = "FluidObject_%d" % _spawn_serial
	body.profile = _profile_for(type_index)
	body.config = _make_config(density, velocity, spin) if config_override == null \
		else config_override.duplicate(true)
	body.fluid_enabled = fluid_active
	body.contacts_enabled = true
	body.profiling = true
	body.position = spawn_position
	if not uniform_medium:
		body.set_medium_density_sampler(_sample_medium_density.bind(_half_height_for(type_index)))
		body.set_medium_velocity_sampler(_sample_medium_velocity)
	var body_mass := body.config.body_density_kg_m3 * body.profile.volume_m3
	body.body_inertia_diagonal_kg_m2 = _inertia_for(type_index, body_mass)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "BodyMesh"
	mesh_instance.mesh = _mesh_for(type_index)
	var material := StandardMaterial3D.new()
	material.albedo_color = _density_color(density) if color_override.a <= 0.0 else color_override
	material.metallic = 0.18 if density > 1500.0 else 0.02
	material.roughness = 0.28
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = material
	body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = _collision_for(type_index)
	body.add_child(collision)

	var label := Label3D.new()
	label.text = "%.0f kg/m³\n%.1f kg" % [density, density * body.profile.volume_m3]
	label.position = Vector3(0.0, _half_height_for(type_index) + 0.35, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 22
	label.modulate = Color(0.9, 0.95, 1.0, 0.82)
	body.add_child(label)

	add_child(body)
	bodies.append(body)
	fluid_body = body
	return body


func _make_config(density: float, velocity: Vector3, spin: Vector3) -> AmbientFluidConfig:
	var config := AmbientFluidConfig.new()
	config.fluid_density_kg_m3 = MEDIUM_DENSITIES[_medium_index]
	config.dynamic_viscosity_pa_s = MEDIUM_VISCOSITIES[_medium_index]
	config.separation_angle_rad = PI * 0.5
	config.body_density_kg_m3 = density
	config.initial_velocity_m_s = velocity
	config.initial_spin_rad_s = spin
	return config


func _sample_medium_density(position: Vector3, half_height: float) -> float:
	if _medium_index <= 2:
		if absf(position.x) > POOL_HALF_SIZE.x or absf(position.z) > POOL_HALF_SIZE.y:
			return 0.0
		var submerged := clampf((WATER_LEVEL + half_height - position.y) \
			/ (half_height * 2.0), 0.0, 1.0)
		return MEDIUM_DENSITIES[_medium_index] * submerged
	if _medium_index == 3:
		return MEDIUM_DENSITIES[3]
	return 0.0


func _sample_medium_velocity(position: Vector3) -> Vector3:
	if _medium_index <= 2 and position.y < WATER_LEVEL \
			and absf(position.x) <= POOL_HALF_SIZE.x and absf(position.z) <= POOL_HALF_SIZE.y:
		return Vector3(_flow_speed_m_s, 0.0, 0.0)
	if _medium_index == 3:
		return Vector3(_flow_speed_m_s, 0.0, 0.0)
	return Vector3.ZERO


func _set_medium(index: int) -> void:
	_medium_index = clampi(index, 0, MEDIUM_NAMES.size() - 1)
	for body in bodies:
		body.set_fluid_density_kg_m3(MEDIUM_DENSITIES[_medium_index])
		body.set_dynamic_viscosity_pa_s(MEDIUM_VISCOSITIES[_medium_index])
		body.sleeping = false
	_update_medium_visuals()
	_last_action = "Fluid changed to %s" % MEDIUM_NAMES[_medium_index]


func _set_scenario(index: int) -> void:
	_scenario_index = clampi(index, 0, SCENARIO_NAMES.size() - 1)
	demo_menu.sync_scenario(_scenario_index)
	_reset_experiment()


func _set_fluid_model(index: int) -> void:
	_set_scenario(0 if index == 0 else maxi(_scenario_index, 1))


func _set_vacuum_baseline(enabled: bool) -> void:
	_vacuum_baseline = enabled
	if _scenario_index > 0:
		_reset_experiment()


func _set_custom_fluid_density(value: float) -> void:
	for body in bodies:
		body.set_fluid_density_kg_m3(value)


func _set_custom_viscosity(value: float) -> void:
	for body in bodies:
		body.set_dynamic_viscosity_pa_s(value)


func _set_custom_separation(value_degrees: float) -> void:
	for body in bodies:
		body.set_separation_angle_rad(deg_to_rad(value_degrees))


func _set_initial_speed(value: float) -> void:
	for body in bodies:
		var direction := body.config.initial_velocity_m_s.normalized()
		if direction == Vector3.ZERO:
			direction = Vector3.RIGHT
		body.set_initial_state(direction * value, body.config.initial_spin_rad_s)


func _set_initial_spin(value: float) -> void:
	for body in bodies:
		var axis := body.config.initial_spin_rad_s.normalized()
		if axis == Vector3.ZERO:
			axis = Vector3.UP
		body.set_initial_state(body.config.initial_velocity_m_s, axis * value)


func _cycle_medium() -> void:
	_set_medium((_medium_index + 1) % MEDIUM_NAMES.size())
	demo_menu.sync_fluid(_medium_index)


func _set_object(index: int) -> void:
	_object_index = clampi(index, 0, OBJECT_NAMES.size() - 1)


func _set_object_density(value: float) -> void:
	_object_density_kg_m3 = value


func _set_throw_speed(value: float) -> void:
	_throw_speed_m_s = value


func _set_flow_speed(value: float) -> void:
	_flow_speed_m_s = value
	for body in bodies:
		body.sleeping = false


func _update_medium_visuals() -> void:
	var liquid_visible := _medium_index <= 2
	water_surface.visible = liquid_visible
	water_volume.visible = liquid_visible
	var surface_material := water_surface.material_override as ShaderMaterial
	var volume_material := water_volume.material_override as StandardMaterial3D
	match _medium_index:
		0:
			medium_label.text = "WATER  ·  998 kg/m³"
			medium_label.modulate = Color(0.55, 0.9, 1.0)
		1:
			medium_label.text = "OIL  ·  850 kg/m³  ·  65× water viscosity"
			medium_label.modulate = Color(1.0, 0.78, 0.28)
		2:
			medium_label.text = "HONEY  ·  1420 kg/m³  ·  very viscous"
			medium_label.modulate = Color(1.0, 0.55, 0.12)
		3:
			medium_label.text = "AIR  ·  1.204 kg/m³"
			medium_label.modulate = Color(0.85, 0.92, 1.0)
		_:
			medium_label.text = "VACUUM  ·  no drag / no buoyancy"
			medium_label.modulate = Color(0.75, 0.75, 0.8)
	if surface_material != null and volume_material != null:
		match _medium_index:
			0:
				surface_material.set_shader_parameter("shallow_color", Color(0.08, 0.55, 0.72))
				surface_material.set_shader_parameter("deep_color", Color(0.015, 0.16, 0.3))
				surface_material.set_shader_parameter("wave_height", 0.075)
				volume_material.albedo_color = Color(0.02, 0.32, 0.52, 0.12)
			1:
				surface_material.set_shader_parameter("shallow_color", Color(0.64, 0.48, 0.08))
				surface_material.set_shader_parameter("deep_color", Color(0.17, 0.12, 0.015))
				surface_material.set_shader_parameter("wave_height", 0.035)
				volume_material.albedo_color = Color(0.42, 0.3, 0.03, 0.16)
			2:
				surface_material.set_shader_parameter("shallow_color", Color(0.85, 0.33, 0.025))
				surface_material.set_shader_parameter("deep_color", Color(0.22, 0.035, 0.008))
				surface_material.set_shader_parameter("wave_height", 0.012)
				volume_material.albedo_color = Color(0.52, 0.16, 0.015, 0.2)


func _reset_experiment() -> void:
	_clear_objects()
	_rng.seed = 0xA6B1E17
	_trajectory_rows.clear()
	if _scenario_index == 0:
		_drop_buoyancy_set()
	else:
		_load_scientific_scenario()
	_last_action = "Experiment reset"


func _clear_objects() -> void:
	for body in bodies:
		if is_instance_valid(body):
			body.queue_free()
	bodies.clear()
	fluid_body = null
	_last_action = "Pool cleared"


func _resolved_object_index() -> int:
	if _object_index < 3:
		return _object_index
	return _rng.randi_range(0, 2)


func _load_scientific_scenario() -> void:
	var preset: AmbientFluidConfig = SCIENTIFIC_PRESETS[_scenario_index - 1]
	_medium_index = 0 if preset.fluid_density_kg_m3 > 100.0 else 3
	_update_medium_visuals()
	var type_index: int = [2, 0, 0, 1][_scenario_index - 1]
	var base_position: Vector3 = [Vector3(0.0, 4.5, 0.0), Vector3(0.0, 2.5, 0.0),
		Vector3(0.0, 0.0, 0.0), Vector3(0.0, -1.5, 0.0)][_scenario_index - 1] as Vector3
	var offset := 2.0 if _vacuum_baseline else 0.0
	var fluid := _spawn_body(type_index, preset.body_density_kg_m3,
		base_position + Vector3.LEFT * offset, preset.initial_velocity_m_s,
		preset.initial_spin_rad_s, Color(0.2, 0.75, 1.0), preset, true, true)
	fluid.name = "%s_Fluid" % SCENARIO_NAMES[_scenario_index]
	if _vacuum_baseline:
		var vacuum := _spawn_body(type_index, preset.body_density_kg_m3,
			base_position + Vector3.RIGHT * offset, preset.initial_velocity_m_s,
			preset.initial_spin_rad_s, Color(0.75, 0.75, 0.78), preset, true, false)
		vacuum.name = "%s_Vacuum" % SCENARIO_NAMES[_scenario_index]
	_last_action = "Loaded %s with uniform medium" % SCENARIO_NAMES[_scenario_index]


func _export_csv(path := "user://ambient_fluid_trajectory.csv") -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_last_action = "CSV export failed: %s" % error_string(FileAccess.get_open_error())
		push_error(_last_action)
		return
	file.store_line("physics_frame,body,x_m,y_m,z_m,vx_m_s,vy_m_s,vz_m_s,energy_j")
	for row in _trajectory_rows:
		file.store_line(row)
	file.flush()
	_last_action = "Exported %d CSV rows" % _trajectory_rows.size()


func _profile_for(type_index: int) -> AmbientFluidProfile3D:
	match type_index:
		0:
			return SPHERE_PROFILE
		1:
			return BOX_PROFILE
		_:
			return PLATE_PROFILE


func _mesh_for(type_index: int) -> Mesh:
	match type_index:
		0:
			return _icosahedron_mesh()
		1:
			var box := BoxMesh.new()
			box.size = Vector3(1.8, 1.4, 1.0)
			return box
		_:
			var plate := BoxMesh.new()
			plate.size = Vector3(2.4, 0.18, 1.2)
			return plate


func _collision_for(type_index: int) -> Shape3D:
	match type_index:
		0:
			var sphere := ConvexPolygonShape3D.new()
			sphere.points = _icosahedron_vertices()
			return sphere
		1:
			var box := BoxShape3D.new()
			box.size = Vector3(1.8, 1.4, 1.0)
			return box
		_:
			var plate := BoxShape3D.new()
			plate.size = Vector3(2.4, 0.18, 1.2)
			return plate


func _half_height_for(type_index: int) -> float:
	match type_index:
		0:
			return 1.0
		1:
			return 0.7
		_:
			return 0.09


func _density_color(density: float) -> Color:
	if density < 500.0:
		return Color(0.96, 0.72, 0.2)
	if density < 998.0:
		return Color(0.2, 0.82, 0.92)
	if density < 1500.0:
		return Color(0.95, 0.4, 0.25)
	return Color(0.55, 0.6, 0.68)


func _inertia_for(type_index: int, body_mass: float) -> Vector3:
	var size := Vector3(2.0, 2.0, 2.0)
	if type_index == 1:
		size = Vector3(1.8, 1.4, 1.0)
	elif type_index == 2:
		size = Vector3(2.4, 0.18, 1.2)
	if type_index == 0:
		return Vector3.ONE * (0.4 * body_mass)
	return Vector3(
		body_mass * (size.y * size.y + size.z * size.z) / 12.0,
		body_mass * (size.x * size.x + size.z * size.z) / 12.0,
		body_mass * (size.x * size.x + size.y * size.y) / 12.0)


func _icosahedron_vertices() -> PackedVector3Array:
	var golden_ratio := (1.0 + sqrt(5.0)) * 0.5
	var scale := 1.0 / sqrt(1.0 + golden_ratio * golden_ratio)
	var vertices := PackedVector3Array([
		Vector3(-1.0, golden_ratio, 0.0), Vector3(1.0, golden_ratio, 0.0),
		Vector3(-1.0, -golden_ratio, 0.0), Vector3(1.0, -golden_ratio, 0.0),
		Vector3(0.0, -1.0, golden_ratio), Vector3(0.0, 1.0, golden_ratio),
		Vector3(0.0, -1.0, -golden_ratio), Vector3(0.0, 1.0, -golden_ratio),
		Vector3(golden_ratio, 0.0, -1.0), Vector3(golden_ratio, 0.0, 1.0),
		Vector3(-golden_ratio, 0.0, -1.0), Vector3(-golden_ratio, 0.0, 1.0),
	])
	for index in vertices.size():
		vertices[index] *= scale
	return vertices


func _icosahedron_mesh() -> ArrayMesh:
	var vertices := _icosahedron_vertices()
	var indices := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
