extends Node3D

const GRID := 128
const COUNT := GRID * GRID
const UPDATE_LOCAL_SIZE := 64
const FIXED_STEP_S := 1.0 / 30.0
const MAX_CATCHUP_STEPS := 8
const GRAVITY_M_S2 := OceanSolver.GRAVITY
const EMISSION_RATE_PER_AMOUNT_S := 600.0
const WIND_DRAG_S := 1.0
const SPRAY_WIDTH_M := 64.0
const SHADER_PATH := "res://shaders/ocean/ocean_spray_update.comp"
const DEFORMATION_PATH := "res://shaders/ocean/ocean_deformation.gdshaderinc"

var amount := 0.0
var wind_direction := Vector2(1.0, 0.0)

var _enabled := false
var _material: ShaderMaterial
var _instance: MultiMeshInstance3D
var _displacements: Texture2DArrayRD
var _normals: Texture2DArrayRD
var _foam_near_a: Texture2DArrayRD
var _foam_near_b: Texture2DArrayRD
var _particle_texture := Texture2DRD.new()
var _particle_state_rid := RID()
var _update_shader_rid := RID()
var _update_pipeline_rid := RID()
var _update_uniform_set_rid := RID()
var _repeat_sampler_rid := RID()
var _clamp_sampler_rid := RID()
var _rd: RenderingDevice
var _particle_capacity := 0
var _physical_ready := false
var _physical_enabled := false
var _shore_fields_ready := false
var _storm_mood := 0.0
var _simulation_accumulator := 0.0
var _simulation_tick := 0
var _tile_lengths := PackedFloat32Array()
var _map_size := 0


func build(displacements: Texture2DArrayRD, normals: Texture2DArrayRD,
		tile_lengths: PackedFloat32Array, _camera: Camera3D) -> void:
	_displacements = displacements
	_normals = normals
	_tile_lengths = tile_lengths.duplicate()
	if _instance == null:
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = quad
		multimesh.instance_count = COUNT
		for i in COUNT:
			multimesh.set_instance_transform(i, Transform3D.IDENTITY)
		_material = ShaderMaterial.new()
		_material.shader = load("res://shaders/ocean/ocean_spray.gdshader")
		_material.set_shader_parameter("particle_state", _particle_texture)
		_instance = MultiMeshInstance3D.new()
		_instance.multimesh = multimesh
		_instance.material_override = _material
		_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_instance.custom_aabb = AABB(Vector3(-110.0, -20.0, -110.0), Vector3(220.0, 80.0, 220.0))
		add_child(_instance)
	var scales := PackedVector4Array()
	for tile in tile_lengths:
		var inverse := 1.0 / tile
		scales.append(Vector4(inverse, inverse, 1.0, 1.0))
	_material.set_shader_parameter("map_scales", scales)
	_material.set_shader_parameter("displacements", _displacements)
	_material.set_shader_parameter("normals", _normals)
	if _foam_near_a != null and _foam_near_b != null:
		bind_foam_fields(_foam_near_a, _foam_near_b)
	_instance.visible = _enabled and amount > 0.0


func set_enabled(on: bool) -> void:
	_enabled = on
	if _instance != null:
		_instance.visible = on and amount > 0.0


func update_state(camera_position: Vector3, mood: float, sim_time: float) -> void:
	if _material == null:
		return
	global_position = Vector3(camera_position.x, 0.0, camera_position.z)
	_storm_mood = mood
	_material.set_shader_parameter("window_center", Vector2(camera_position.x, camera_position.z))
	_material.set_shader_parameter("storm_mood", mood)
	_material.set_shader_parameter("spray_amount", amount)
	_material.set_shader_parameter("particle_interpolation_s", _simulation_accumulator)
	_material.set_shader_parameter("sim_time", sim_time)
	_material.set_shader_parameter("wind_direction", wind_direction)
	_instance.visible = _enabled and amount > 0.0


func set_physical_enabled(on: bool) -> void:
	_physical_enabled = on and _physical_ready
	if _material != null:
		_material.set_shader_parameter("persistent_particles", _physical_enabled)
		_material.set_shader_parameter("particle_capacity", _particle_capacity)
	if _instance != null:
		_instance.visible = _enabled and amount > 0.0


func init_render(displacements: RID, derivatives: RID, foam_a: RID, foam_b: RID,
		velocity_fields: RID, map_size: int, tile_lengths: PackedFloat32Array,
		capacity: int, coast_field: RID = RID(), wake_field: RID = RID(),
		shore_surface: RID = RID(), shore_foam: RID = RID(),
		shore_derivative: RID = RID(), breaking_settings: RID = RID()) -> void:
	free_render()
	_rd = GpuPreflight.device("OceanSpray")
	if _rd == null or capacity <= 0 or capacity > COUNT \
			or not coast_field.is_valid() or not wake_field.is_valid() \
			or not breaking_settings.is_valid():
		return
	_particle_capacity = capacity
	_tile_lengths = tile_lengths.duplicate()
	_map_size = map_size
	_particle_state_rid = _create_particle_state(capacity)
	if not _particle_state_rid.is_valid():
		free_render()
		return
	_rd.texture_clear(_particle_state_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	var version_end := source.find("\n")
	if version_end < 0:
		push_error("Ocean spray update shader is missing its version preamble")
		free_render()
		return
	var source_body := source.substr(version_end + 1)
	var shader_source := "#version 450\n" \
		+ FileAccess.get_file_as_string(DEFORMATION_PATH) + "\n" + source_body
	var spirv := ShaderCache.compile(_rd, "ocean_spray_update", shader_source)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		push_error("Ocean spray update shader compile error:\n%s" % spirv.compile_error_compute)
		free_render()
		return
	_update_shader_rid = _rd.shader_create_from_spirv(spirv)
	_update_pipeline_rid = _rd.compute_pipeline_create(_update_shader_rid)
	_repeat_sampler_rid = _create_sampler(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT)
	_clamp_sampler_rid = _create_sampler(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE)
	var uniforms: Array[RDUniform] = []
	var state_uniform := RDUniform.new()
	state_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	state_uniform.binding = 0
	state_uniform.add_id(_particle_state_rid)
	uniforms.append(state_uniform)
	uniforms.append(_sampled_texture_uniform(1, _repeat_sampler_rid, displacements))
	uniforms.append(_sampled_texture_uniform(2, _repeat_sampler_rid, derivatives))
	uniforms.append(_sampled_texture_uniform(3, _clamp_sampler_rid, foam_a))
	uniforms.append(_sampled_texture_uniform(4, _clamp_sampler_rid, foam_b))
	uniforms.append(_sampled_texture_uniform(5, _repeat_sampler_rid, velocity_fields))
	uniforms.append(_sampled_texture_uniform(6, _clamp_sampler_rid, coast_field))
	uniforms.append(_sampled_texture_uniform(7, _clamp_sampler_rid, wake_field))
	_shore_fields_ready = shore_surface.is_valid() and shore_foam.is_valid() \
		and shore_derivative.is_valid()
	uniforms.append(_sampled_texture_uniform(8, _clamp_sampler_rid,
		shore_surface if shore_surface.is_valid() else coast_field))
	uniforms.append(_sampled_texture_uniform(9, _clamp_sampler_rid,
		shore_foam if shore_foam.is_valid() else coast_field))
	uniforms.append(_sampled_texture_uniform(10, _clamp_sampler_rid,
		shore_derivative if shore_derivative.is_valid() else coast_field))
	var breaking_uniform := RDUniform.new()
	breaking_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	breaking_uniform.binding = 11
	breaking_uniform.add_id(breaking_settings)
	uniforms.append(breaking_uniform)
	_update_uniform_set_rid = _rd.uniform_set_create(uniforms, _update_shader_rid, 0)
	if not _update_uniform_set_rid.is_valid():
		free_render()
		return
	_particle_texture.texture_rd_rid = _particle_state_rid
	_physical_ready = true
	_simulation_accumulator = 0.0
	_simulation_tick = 0
	call_deferred("_set_particle_capacity", capacity)


func step_render(elapsed: float, simulation_time: float, center: Vector2,
		wind_velocity: Vector2, current_velocity: Vector2, foam_center: Vector2,
		foam_domains: Vector3, foam_index: int, breaking_threshold: float,
		local_centers: Vector4, shore_enabled: bool = false) -> void:
	if not _physical_ready or not _physical_enabled or elapsed <= 0.0:
		return
	_simulation_accumulator += elapsed
	var step_count := mini(int(floor(_simulation_accumulator / FIXED_STEP_S)),
		MAX_CATCHUP_STEPS)
	if step_count <= 0:
		return
	_simulation_accumulator -= float(step_count) * FIXED_STEP_S
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, FIXED_STEP_S)
	pc.encode_float(4, simulation_time - _simulation_accumulator)
	pc.encode_float(8, _storm_mood)
	pc.encode_float(12, amount)
	pc.encode_float(16, center.x)
	pc.encode_float(20, center.y)
	pc.encode_float(24, SPRAY_WIDTH_M)
	pc.encode_float(28, OceanShoreSolver.DOMAIN_M)
	pc.encode_float(32, wind_velocity.x)
	pc.encode_float(36, wind_velocity.y)
	pc.encode_float(40, current_velocity.x)
	pc.encode_float(44, current_velocity.y)
	pc.encode_float(48, foam_center.x)
	pc.encode_float(52, foam_center.y)
	pc.encode_float(56, foam_domains.x)
	pc.encode_float(60, local_centers.x)
	pc.encode_float(68, float(foam_index))
	pc.encode_float(64, local_centers.y)
	pc.encode_float(72, local_centers.z)
	pc.encode_float(76, local_centers.w)
	pc.encode_float(80, _tile_lengths[0])
	pc.encode_float(84, _tile_lengths[1])
	pc.encode_float(88, _tile_lengths[2])
	pc.encode_float(92, 256.0)
	pc.encode_float(96, GRAVITY_M_S2)
	pc.encode_float(100, breaking_threshold)
	pc.encode_float(104, EMISSION_RATE_PER_AMOUNT_S)
	pc.encode_float(108, WIND_DRAG_S)
	pc.encode_s32(112, _particle_capacity)
	pc.encode_s32(116, step_count)
	pc.encode_s32(120, 1 if shore_enabled and _shore_fields_ready else 0)
	pc.encode_s32(124, _simulation_tick)
	_simulation_tick += step_count
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _update_pipeline_rid)
	_rd.compute_list_bind_uniform_set(cl, _update_uniform_set_rid, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, ceili(float(_particle_capacity) / UPDATE_LOCAL_SIZE), 1, 1)
	_rd.compute_list_end()


func free_render() -> void:
	_physical_ready = false
	_physical_enabled = false
	_shore_fields_ready = false
	if _material != null:
		_material.set_shader_parameter("persistent_particles", false)
	_particle_texture.texture_rd_rid = RID()
	if _rd == null:
		return
	for rid in [_update_uniform_set_rid]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_update_uniform_set_rid = RID()
	for rid in [_update_pipeline_rid, _update_shader_rid]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_update_pipeline_rid = RID()
	_update_shader_rid = RID()
	for rid in [_repeat_sampler_rid, _clamp_sampler_rid]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_repeat_sampler_rid = RID()
	_clamp_sampler_rid = RID()
	if _particle_state_rid.is_valid():
		_rd.free_rid(_particle_state_rid)
	_particle_state_rid = RID()
	_particle_capacity = 0
	_rd = null
	call_deferred("_set_particle_capacity", COUNT)


func _exit_tree() -> void:
	_physical_ready = false
	_physical_enabled = false
	_shore_fields_ready = false
	_particle_texture.texture_rd_rid = RID()
	if _material != null:
		_material.set_shader_parameter("persistent_particles", false)
	if _rd == null:
		return
	var resources: Array[RID] = []
	for rid in [_update_uniform_set_rid, _update_pipeline_rid, _update_shader_rid,
			_repeat_sampler_rid, _clamp_sampler_rid, _particle_state_rid]:
		if rid.is_valid():
			resources.append(rid)
	var device := _rd
	_update_uniform_set_rid = RID()
	_update_pipeline_rid = RID()
	_update_shader_rid = RID()
	_repeat_sampler_rid = RID()
	_clamp_sampler_rid = RID()
	_particle_state_rid = RID()
	_particle_capacity = 0
	_rd = null
	if not resources.is_empty():
		RenderingServer.call_on_render_thread(
			Callable(get_script(), "_free_resource_snapshot").bind(device, resources))


static func _free_resource_snapshot(device: RenderingDevice, resources: Array[RID]) -> void:
	for rid in resources:
		device.free_rid(rid)


func set_sun_direction(direction: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_direction", direction)


func estimate_vram_bytes() -> int:
	return _particle_capacity * 3 * 16


func set_wind_direction(direction: Vector2) -> void:
	wind_direction = direction.normalized()


func bind_foam_fields(a: Texture2DArrayRD, b: Texture2DArrayRD) -> void:
	_foam_near_a = a
	_foam_near_b = b
	if _material != null:
		_material.set_shader_parameter("foam_near_a", _foam_near_a)
		_material.set_shader_parameter("foam_near_b", _foam_near_b)
		_material.set_shader_parameter("foam_near_enabled", _foam_near_a != null and _foam_near_b != null)


func set_foam_state(center: Vector2, domains: Vector3, index: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("foam_near_center", center)
	_material.set_shader_parameter("foam_domains", domains)
	_material.set_shader_parameter("foam_near_index", index)


func release_textures() -> void:
	if _instance != null:
		_instance.visible = false
	_physical_enabled = false
	_physical_ready = false
	if _material != null:
		_material.set_shader_parameter("persistent_particles", false)
	_particle_texture.texture_rd_rid = RID()
	_displacements = null
	_normals = null
	_foam_near_a = null
	_foam_near_b = null


func _set_particle_capacity(capacity: int) -> void:
	if _instance == null or _instance.multimesh == null:
		return
	_instance.multimesh.visible_instance_count = clampi(capacity, 0, COUNT)
	_material.set_shader_parameter("particle_capacity", clampi(capacity, 0, COUNT))


func _create_particle_state(capacity: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = capacity
	format.height = 3
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return _rd.texture_create(format, RDTextureView.new(), [])


func _create_sampler(repeat_mode: RenderingDevice.SamplerRepeatMode) -> RID:
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = repeat_mode
	state.repeat_v = repeat_mode
	return _rd.sampler_create(state)


func _sampled_texture_uniform(binding: int, sampler: RID, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform
