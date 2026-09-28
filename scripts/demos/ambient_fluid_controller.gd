extends Node3D

const SPHERE_PROFILE := preload("res://resources/ambient_fluid/sphere_bem.tres")
const PLATE_PROFILE := preload("res://resources/ambient_fluid/plate_bem.tres")
const BOX_PROFILE := preload("res://resources/ambient_fluid/body_bem.tres")
const FALLING_PLATE := preload("res://resources/ambient_fluid/presets/falling_plate.tres")
const MAGNUS_BALL := preload("res://resources/ambient_fluid/presets/magnus_ball.tres")
const BALLOON := preload("res://resources/ambient_fluid/presets/balloon.tres")
const UNDERWATER_BODY := preload("res://resources/ambient_fluid/presets/underwater_body.tres")
const POOL_EFFECTS_SCRIPT := preload("res://scripts/demos/ambient_fluid/ambient_fluid_pool_effects.gd")
const WATER_LEVEL := 0.4
const POOL_HALF_SIZE := Vector2(6.8, 4.8)
const MEDIUM_NAMES := ["Water", "Oil", "Honey", "Air", "Vacuum"]
const MEDIUM_DENSITIES := [998.0, 850.0, 1420.0, 1.204, 0.0]
const MEDIUM_VISCOSITIES := [1.002e-3, 0.065, 185.13, 1.81e-5, 0.0]
const OBJECT_NAMES := ["Ball", "Cube", "Plate", "Random"]
const SCENARIO_NAMES := ["Pool Showcase", "Falling Plate", "Magnus Ball", "Balloon", "Underwater Body"]
const SCIENTIFIC_PRESETS := [FALLING_PLATE, MAGNUS_BALL, BALLOON, UNDERWATER_BODY]
const TRAJECTORY_LIMIT := 3600

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_camera: OrbitCamera = $CameraPivot
@onready var water_surface: MeshInstance3D = $Pool/WaterSurface
@onready var water_shader_material: ShaderMaterial = water_surface.material_override as ShaderMaterial
@onready var waterlines := [$Pool/FrontWaterline, $Pool/BackWaterline,
	$Pool/LeftWaterline, $Pool/RightWaterline]
@onready var liquid_sides: Node3D = $Pool/LiquidSides
@onready var pool_floor: MeshInstance3D = $Pool/Floor
@onready var front_glass: MeshInstance3D = $Pool/FrontGlass
@onready var medium_label: Label3D = $Pool/MediumLabel
@onready var _viewport := ViewportGuard.attach(self)

var fluid_body: AmbientFluidBody3D
var bodies: Array[AmbientFluidBody3D] = []
var demo_menu := AmbientFluidMenu.new()
var quality := SimQualityState.new()
var _medium_index := 0
var _fluid_density_kg_m3 := 998.0
var _dynamic_viscosity_pa_s := 1.002e-3
var _object_index := 3
var _object_density_kg_m3 := 35.0
var _throw_speed_m_s := 5.0
var _flow_speed_m_s := 0.0
var _spawn_serial := 0
var _mix_drop_index := 0
var _last_action := "Ready"
var _rng := RandomNumberGenerator.new()
var _scenario_index := 0
var _vacuum_baseline := true
var _trajectory_rows: Array[String] = []
var pool_effects: Node
var honey_surface_material: StandardMaterial3D


func _ready() -> void:
	orbit_camera.target = Vector3(0.0, -0.25, 0.0)
	orbit_camera.distance = 14.0
	orbit_camera.pitch = -23.0
	orbit_camera.yaw = 0.0
	orbit_camera.min_distance = 7.0
	orbit_camera.max_distance = 26.0
	_rng.seed = 0xA6B1E17
	menu.persist_id = "ambient_fluid_demo_v2"
	quality.setup(AmbientFluidQualityProfile, "ambient_fluid_quality_profile",
		_apply_quality)
	quality.restore()
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
		})
	menu.add_section("Performance")
	menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	var msaa_option: OptionButton = menu.add_option_button("MSAA", ["Off", "2×", "4×"],
		_msaa_index(_viewport.msaa()), _set_msaa)
	quality.bind("msaa", msaa_option, _set_msaa,
		func(mode: int) -> int: return _msaa_index(mode))
	quality.attach_menu_option(menu)
	pool_effects = POOL_EFFECTS_SCRIPT.new()
	pool_effects.name = "PoolEffects"
	$Pool.add_child(pool_effects)
	pool_effects.call("configure")
	honey_surface_material = StandardMaterial3D.new()
	honey_surface_material.albedo_color = Color(0.74, 0.38, 0.045, 0.37)
	honey_surface_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	honey_surface_material.roughness = 0.2
	honey_surface_material.metallic = 0.0
	honey_surface_material.metallic_specular = 0.06
	_update_medium_visuals()
	_drop_buoyancy_set()


func _physics_process(_delta: float) -> void:
	if pool_effects != null:
		pool_effects.call("update_bodies", bodies)
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
			continue
		var density_label := body.get_node("DensityLabel") as Label3D
		density_label.global_position = body.global_position \
			+ Vector3.UP * float(density_label.get_meta("offset"))
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


func _set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func _set_msaa(mode: int) -> void:
	_viewport.set_msaa(mode)


static func _msaa_index(mode: int) -> int:
	match mode:
		Viewport.MSAA_2X: return 1
		Viewport.MSAA_4X: return 2
		_: return 0


func _apply_quality(values: Dictionary) -> void:
	_viewport.set_msaa(values.msaa)


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
	_update_medium_visuals()
	var samples: Array[Dictionary] = _showcase_samples()
	var positions := [Vector2(-4.4, -1.0), Vector2(0.0, 1.4),
		Vector2(1.4, -0.7), Vector2(4.4, -1.0)]
	var slot: int = maxi(_mix_drop_index - 1, 0) % 6
	var row_z: float = [-3.5, 3.5, 0.0, -3.5, 3.5, 0.0][slot]
	var height_offset: float = 2.5 * float(slot / 3) \
		if _mix_drop_index > 0 else 0.0
	_mix_drop_index += 1
	for index in samples.size():
		var sample: Dictionary = samples[index]
		var spawn_position := Vector3(-4.5 + 3.0 * index,
			2.4 + index * 0.2 + height_offset, row_z) \
			if _mix_drop_index > 1 else Vector3(positions[index].x,
				2.4 + index * 0.2, positions[index].y)
		for existing in bodies:
			if is_instance_valid(existing) and Vector2(existing.global_position.x,
					existing.global_position.z).distance_to(Vector2(spawn_position.x,
					spawn_position.z)) < 2.5:
				spawn_position.y = maxf(spawn_position.y, existing.global_position.y + 2.5)
		var body := _spawn_body(index % 3, float(sample.density),
			spawn_position,
			Vector3.ZERO, Vector3(0.4, 0.7, -0.25), sample.color)
		body.name = "Buoyancy_%d" % index
	_last_action = "Dropped four density probes for %s" % MEDIUM_NAMES[_medium_index]


func _showcase_samples() -> Array[Dictionary]:
	if _medium_index >= 3:
		return [
			{density = 0.35, color = Color(0.95, 0.53, 0.12)},
			{density = 1.0, color = Color(0.58, 0.86, 0.38)},
			{density = 5.0, color = Color(0.93, 0.28, 0.2)},
			{density = 2600.0, color = Color(0.65, 0.52, 0.86)},
		]
	return [
		{density = 400.0, color = Color(0.95, 0.53, 0.12)},
		{density = 650.0, color = Color(0.58, 0.86, 0.38)},
		{density = 1050.0, color = Color(0.93, 0.28, 0.2)},
		{density = 2600.0, color = Color(0.65, 0.52, 0.86)},
	]


func _spawn_body(type_index: int, density: float, spawn_position: Vector3,
		velocity: Vector3, spin: Vector3, color_override := Color.TRANSPARENT,
		config_override: AmbientFluidConfig = null, uniform_medium := false,
		fluid_active := true) -> AmbientFluidBody3D:
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
	material.metallic = 0.14
	material.roughness = 0.28
	material.clearcoat_enabled = true
	material.clearcoat = 0.35
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = material
	body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = _collision_for(type_index)
	body.add_child(collision)

	var label := Label3D.new()
	label.name = "DensityLabel"
	label.text = "%.0f" % density
	label.top_level = true
	label.set_meta("offset", _half_height_for(type_index) + 0.45)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 32
	label.pixel_size = 0.012
	label.outline_size = 10
	label.modulate = Color(0.98, 0.99, 1.0)
	body.add_child(label)
	if not uniform_medium:
		body.set_pool_buoyancy_mesh(_pool_faces_for(type_index), WATER_LEVEL)
		body.set_pool_buoyancy_enabled(_medium_index <= 2)

	add_child(body)
	label.global_position = spawn_position + Vector3.UP * (_half_height_for(type_index) + 0.45)
	bodies.append(body)
	fluid_body = body
	return body


func _make_config(density: float, velocity: Vector3, spin: Vector3) -> AmbientFluidConfig:
	var config := AmbientFluidConfig.new()
	config.fluid_density_kg_m3 = _fluid_density_kg_m3
	config.dynamic_viscosity_pa_s = _dynamic_viscosity_pa_s
	config.separation_angle_rad = PI * 0.5
	config.body_density_kg_m3 = density
	config.initial_velocity_m_s = velocity
	config.initial_spin_rad_s = spin
	return config


func _sample_medium_density(position: Vector3, _half_height: float) -> float:
	if _medium_index <= 2:
		if absf(position.x) > POOL_HALF_SIZE.x or absf(position.z) > POOL_HALF_SIZE.y:
			return 0.0
		return _fluid_density_kg_m3
	if _medium_index == 3:
		return _fluid_density_kg_m3
	return 0.0


func _sample_medium_velocity(position: Vector3) -> Vector3:
	if _medium_index <= 2 and absf(position.x) <= POOL_HALF_SIZE.x \
			and absf(position.z) <= POOL_HALF_SIZE.y:
		return Vector3(_flow_speed_m_s, 0.0, 0.0)
	if _medium_index == 3:
		return Vector3(_flow_speed_m_s, 0.0, 0.0)
	return Vector3.ZERO


func _set_medium(index: int) -> void:
	var previous_medium := _medium_index
	_medium_index = clampi(index, 0, MEDIUM_NAMES.size() - 1)
	_fluid_density_kg_m3 = MEDIUM_DENSITIES[_medium_index]
	_dynamic_viscosity_pa_s = MEDIUM_VISCOSITIES[_medium_index]
	if previous_medium != _medium_index and pool_effects != null:
		pool_effects.call("reset_effects")
	for body in bodies:
		body.set_pool_buoyancy_enabled(_medium_index <= 2 \
			and not body.pool_buoyancy_faces_local.is_empty())
		body.set_fluid_density_kg_m3(_fluid_density_kg_m3)
		body.set_dynamic_viscosity_pa_s(_dynamic_viscosity_pa_s)
		body.sleeping = false
	_update_medium_visuals()
	demo_menu.sync_fluid(_medium_index, _fluid_density_kg_m3,
		_dynamic_viscosity_pa_s)
	_last_action = "Fluid changed to %s" % MEDIUM_NAMES[_medium_index]


func set_capture_view(view_name: String) -> void:
	match view_name:
		"near": orbit_camera.distance = 9.0
		"far": orbit_camera.distance = 24.0
		"high":
			orbit_camera.distance = 11.0
			orbit_camera.pitch = -48.0
		_: orbit_camera.distance = 14.0


func set_capture_scenario(index: int) -> void:
	_set_scenario(index)


func set_capture_medium(index: int) -> void:
	_set_medium(index)


func set_capture_ui(visible: bool) -> void:
	menu.visible = visible


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
	_fluid_density_kg_m3 = value
	for body in bodies:
		body.set_fluid_density_kg_m3(value)
	_update_medium_visuals()


func _set_custom_viscosity(value: float) -> void:
	_dynamic_viscosity_pa_s = value
	for body in bodies:
		body.set_dynamic_viscosity_pa_s(value)
	_update_medium_visuals()


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
	for waterline in waterlines:
		waterline.visible = liquid_visible
	water_surface.material_override = honey_surface_material if _medium_index == 2 \
		else water_shader_material
	liquid_sides.visible = liquid_visible
	if pool_effects != null:
		pool_effects.call("set_liquid_effects_enabled", _medium_index <= 1 \
			and _scenario_index == 0)
	var surface_material := water_shader_material
	var volume_material := ($Pool/LiquidSides/Back as MeshInstance3D).material_override as StandardMaterial3D
	var floor_material := pool_floor.material_override as ShaderMaterial
	var glass_material := front_glass.material_override as ShaderMaterial
	var wall_material := ($Pool/LeftWall as MeshInstance3D).material_override as StandardMaterial3D
	var waterline_material := (waterlines[0] as MeshInstance3D).material_override as StandardMaterial3D
	match _medium_index:
		0:
			waterline_material.albedo_color = Color(0.42, 0.88, 0.93)
			medium_label.text = "WATER  ·  %.0f kg/m³" % _fluid_density_kg_m3
			medium_label.font_size = 40
			medium_label.pixel_size = 0.013
			medium_label.modulate = Color(0.55, 0.9, 1.0)
			volume_material.albedo_color = Color(0.09, 0.34, 0.42, 0.08)
			floor_material.set_shader_parameter("base_color", Color(0.11, 0.2, 0.25))
			wall_material.albedo_color = Color(0.3, 0.42, 0.49)
			glass_material.set_shader_parameter("glass_color", Color(0.5, 0.77, 0.82))
			glass_material.set_shader_parameter("base_alpha", 0.01)
		1:
			waterline_material.albedo_color = Color(0.98, 0.72, 0.28)
			medium_label.text = "OIL  ·  %.0f kg/m³" % _fluid_density_kg_m3
			medium_label.font_size = 48
			medium_label.pixel_size = 0.015
			medium_label.modulate = Color(1.0, 0.78, 0.28)
			volume_material.albedo_color = Color(0.43, 0.31, 0.06, 0.07)
			floor_material.set_shader_parameter("base_color", Color(0.31, 0.33, 0.32))
			wall_material.albedo_color = Color(0.34, 0.41, 0.43)
			glass_material.set_shader_parameter("glass_color", Color(0.82, 0.66, 0.34))
			glass_material.set_shader_parameter("base_alpha", 0.015)
		2:
			waterline_material.albedo_color = Color(1.0, 0.58, 0.14)
			medium_label.text = "HONEY  ·  %.0f kg/m³\n%.0f Pa·s (coriander, 5 °C)" % [
				_fluid_density_kg_m3, _dynamic_viscosity_pa_s]
			medium_label.font_size = 36
			medium_label.pixel_size = 0.013
			medium_label.modulate = Color(1.0, 0.55, 0.12)
			volume_material.albedo_color = Color(0.6, 0.29, 0.03, 0.08)
			floor_material.set_shader_parameter("base_color", Color(0.34, 0.31, 0.27))
			wall_material.albedo_color = Color(0.38, 0.39, 0.38)
			glass_material.set_shader_parameter("glass_color", Color(0.62, 0.27, 0.02))
			glass_material.set_shader_parameter("base_alpha", 0.0)
		3:
			medium_label.text = "AIR  ·  %.3f kg/m³" % _fluid_density_kg_m3
			medium_label.font_size = 48
			medium_label.pixel_size = 0.015
			medium_label.modulate = Color(0.85, 0.92, 1.0)
			volume_material.albedo_color = Color(0.09, 0.34, 0.42, 0.045)
			floor_material.set_shader_parameter("base_color", Color(0.22, 0.34, 0.42))
			wall_material.albedo_color = Color(0.3, 0.42, 0.49)
			glass_material.set_shader_parameter("glass_color", Color(0.04, 0.29, 0.42))
			glass_material.set_shader_parameter("base_alpha", 0.015)
		_:
			medium_label.text = "VACUUM  ·  no drag / no buoyancy"
			medium_label.font_size = 48
			medium_label.pixel_size = 0.015
			medium_label.modulate = Color(0.75, 0.75, 0.8)
			volume_material.albedo_color = Color(0.09, 0.34, 0.42, 0.045)
			floor_material.set_shader_parameter("base_color", Color(0.22, 0.34, 0.42))
			wall_material.albedo_color = Color(0.3, 0.42, 0.49)
			glass_material.set_shader_parameter("glass_color", Color(0.04, 0.29, 0.42))
			glass_material.set_shader_parameter("base_alpha", 0.015)
	if surface_material != null:
		match _medium_index:
			0:
				surface_material.set_shader_parameter("shallow_color", Color(0.16, 0.52, 0.57))
				surface_material.set_shader_parameter("deep_color", Color(0.04, 0.24, 0.32))
				surface_material.set_shader_parameter("absorption_color", Color(0.16, 0.07, 0.045))
				surface_material.set_shader_parameter("wave_height", 0.045)
				surface_material.set_shader_parameter("contact_foam_strength", 0.35)
				surface_material.set_shader_parameter("transmission_strength", 0.1)
				surface_material.set_shader_parameter("surface_alpha", 0.95)
			1:
				surface_material.set_shader_parameter("shallow_color", Color(0.69, 0.42, 0.055))
				surface_material.set_shader_parameter("deep_color", Color(0.3, 0.16, 0.02))
				surface_material.set_shader_parameter("absorption_color", Color(0.08, 0.12, 0.3))
				surface_material.set_shader_parameter("wave_height", 0.035)
				surface_material.set_shader_parameter("contact_foam_strength", 0.0)
				surface_material.set_shader_parameter("transmission_strength", 0.52)
				surface_material.set_shader_parameter("surface_alpha", 0.52)
			2:
				surface_material.set_shader_parameter("shallow_color", Color(0.85, 0.43, 0.055))
				surface_material.set_shader_parameter("deep_color", Color(0.44, 0.18, 0.02))
				surface_material.set_shader_parameter("absorption_color", Color(0.08, 0.24, 0.46))
				surface_material.set_shader_parameter("wave_height", 0.0)
				surface_material.set_shader_parameter("contact_foam_strength", 0.0)
				surface_material.set_shader_parameter("transmission_strength", 0.18)
				surface_material.set_shader_parameter("surface_alpha", 0.86)


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
	_mix_drop_index = 0
	if pool_effects != null:
		pool_effects.call("reset_effects")
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
	_fluid_density_kg_m3 = preset.fluid_density_kg_m3
	_dynamic_viscosity_pa_s = preset.dynamic_viscosity_pa_s
	_update_medium_visuals()
	demo_menu.sync_fluid(_medium_index, preset.fluid_density_kg_m3,
		preset.dynamic_viscosity_pa_s)
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


func _pool_faces_for(type_index: int) -> PackedVector3Array:
	var source_mesh := _mesh_for(type_index)
	var arrays: Array
	if source_mesh is BoxMesh:
		arrays = (source_mesh as BoxMesh).get_mesh_arrays()
	else:
		arrays = (source_mesh as ArrayMesh).surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var unique_vertices := PackedVector3Array()
	for position in positions:
		var duplicate := false
		for existing in unique_vertices:
			if existing.distance_squared_to(position) <= 1.0e-10:
				duplicate = true
				break
		if not duplicate:
			unique_vertices.append(position)
	var profile := _profile_for(type_index)
	var ordered_faces := PackedVector3Array()
	for face_index in profile.face_centers_m.size():
		var center: Vector3 = profile.face_centers_m[face_index]
		var normal: Vector3 = profile.face_normals[face_index]
		var expected_area: float = profile.face_areas_m2[face_index]
		var found := false
		for a in unique_vertices.size():
			if absf((unique_vertices[a] - center).dot(normal)) > 1.0e-4:
				continue
			for b in range(a + 1, unique_vertices.size()):
				if absf((unique_vertices[b] - center).dot(normal)) > 1.0e-4:
					continue
				for c in range(b + 1, unique_vertices.size()):
					if absf((unique_vertices[c] - center).dot(normal)) > 1.0e-4:
						continue
					var area := (unique_vertices[b] - unique_vertices[a]).cross(
						unique_vertices[c] - unique_vertices[a]).length() * 0.5
					if absf(area - expected_area) > maxf(1.0e-5, expected_area * 1.0e-5):
						continue
					var candidate_center := (unique_vertices[a] + unique_vertices[b] \
						+ unique_vertices[c]) / 3.0
					if candidate_center.distance_to(center) > 1.0e-4:
						continue
					ordered_faces.append(unique_vertices[a])
					ordered_faces.append(unique_vertices[b])
					ordered_faces.append(unique_vertices[c])
					found = true
					break
				if found:
					break
			if found:
				break
		if not found:
			push_error("Ambient fluid pool face %d has no matching canonical triangle" % face_index)
			return PackedVector3Array()
	return ordered_faces


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
		return Vector3.ONE * (0.289442719099992 * body_mass)
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
	var normals := PackedVector3Array()
	for vertex in vertices:
		normals.append(vertex.normalized())
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
