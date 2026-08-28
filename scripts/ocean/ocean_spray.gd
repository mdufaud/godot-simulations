extends Node3D

const GRID := 128
const COUNT := GRID * GRID

var amount := 0.0
var wind_direction := Vector2(1.0, 0.0)

var _enabled := false
var _material: ShaderMaterial
var _instance: MultiMeshInstance3D
var _displacements: Texture2DArrayRD
var _normals: Texture2DArrayRD
var _foam_a: Texture2DArrayRD
var _foam_b: Texture2DArrayRD


func build(displacements: Texture2DArrayRD, normals: Texture2DArrayRD,
		tile_lengths: PackedFloat32Array, _camera: Camera3D,
		foam_a: Texture2DArrayRD = null, foam_b: Texture2DArrayRD = null,
		foam_indices: Vector4 = Vector4(0.0, 0.0, 0.0, 0.0)) -> void:
	_displacements = displacements
	_normals = normals
	_foam_a = foam_a
	_foam_b = foam_b
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
	if _foam_a != null and _foam_b != null:
		_material.set_shader_parameter("foam_history_a", _foam_a)
		_material.set_shader_parameter("foam_history_b", _foam_b)
		_material.set_shader_parameter("foam_history_indices", foam_indices)
	_instance.visible = _enabled and amount > 0.0


func set_enabled(on: bool) -> void:
	_enabled = on
	if _instance != null:
		_instance.visible = on and amount > 0.0


func update_state(camera_position: Vector3, mood: float, sim_time: float) -> void:
	if _material == null:
		return
	global_position = Vector3(camera_position.x, 0.0, camera_position.z)
	_material.set_shader_parameter("window_center", Vector2(camera_position.x, camera_position.z))
	_material.set_shader_parameter("storm_mood", mood)
	_material.set_shader_parameter("spray_amount", amount)
	_material.set_shader_parameter("sim_time", sim_time)
	_material.set_shader_parameter("wind_direction", wind_direction)
	_instance.visible = _enabled and amount > 0.0


func set_sun_direction(direction: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("sun_direction", direction)


func set_wind_direction(direction: Vector2) -> void:
	wind_direction = direction.normalized()


func release_textures() -> void:
	if _instance != null:
		_instance.visible = false
	_displacements = null
	_normals = null
	_foam_a = null
	_foam_b = null
