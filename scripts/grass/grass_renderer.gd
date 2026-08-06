class_name GrassRenderer extends Node3D

const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")
const GrassMultimeshBuilder := preload("res://scripts/grass/grass_multimesh_builder.gd")

const TILE_SIZE := 10.0
const MAP_RADIUS := 80.0
const SHADOW_DISTANCE := 40.0

var density := 1.0
var wind_speed := 1.0
var material: ShaderMaterial
var _tiles: Array[Array] = []
var _previous_tile_id := Vector3.ZERO
var _gust := 0.0


func build() -> void:
	material = GRASS_MAT.duplicate() as ShaderMaterial
	material.set_shader_parameter("heightmap", preload("res://resources/grass/grass_heightmap.tres"))
	material.set_shader_parameter("heightmap_scale", 5.0)
	set_crush_center(Vector3.ZERO)
	_build_tiles()
	generate()


func set_crush_center(world_position: Vector3) -> void:
	material.set_shader_parameter("crush_center", world_position)


func set_wind_speed(value: float) -> void:
	wind_speed = value
	material.set_shader_parameter("wind_speed", value + _gust)


func add_gust(strength: float) -> void:
	_gust = strength
	material.set_shader_parameter("wind_speed", wind_speed + _gust)


func tick(delta: float, camera_target: Vector3) -> void:
	if _gust > 0.0:
		_gust = maxf(0.0, _gust - 1.4 * delta)
		material.set_shader_parameter("wind_speed", wind_speed + _gust)
	var tile_id := ((camera_target + Vector3.ONE * TILE_SIZE * 0.5)
		/ TILE_SIZE * Vector3(1, 0, 1)).floor()
	if tile_id == _previous_tile_id:
		return
	for data in _tiles:
		data[0].global_position = data[1] + Vector3(1, 0, 1) * TILE_SIZE * tile_id
	_previous_tile_id = tile_id


func set_density(value: float) -> void:
	density = value
	generate()


func set_clumping(value: float) -> void:
	material.set_shader_parameter("clumping_factor", value)


func set_colors(base: Color, tip: Color, sss: Color) -> void:
	material.set_shader_parameter("base_color", base)
	material.set_shader_parameter("tip_color", tip)
	material.set_shader_parameter("subsurface_scattering_color", sss)


func set_shadows(enabled: bool) -> void:
	for data in _tiles:
		var near: bool = data[1].length() < SHADOW_DISTANCE
		data[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_tiles() -> void:
	var half := TILE_SIZE * 0.5
	var tile_aabb := AABB(Vector3(-half - 2.0, -3.0, -half - 2.0),
		Vector3(TILE_SIZE + 4.0, 8.0, TILE_SIZE + 4.0))
	for x in range(-int(MAP_RADIUS), int(MAP_RADIUS), int(TILE_SIZE)):
		for z in range(-int(MAP_RADIUS), int(MAP_RADIUS), int(TILE_SIZE)):
			var instance := MultiMeshInstance3D.new()
			instance.material_override = material
			instance.position = Vector3(x, 0.0, z)
			instance.custom_aabb = tile_aabb
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
				if Vector2(x, z).length() < SHADOW_DISTANCE \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(instance)
			_tiles.append([instance, instance.position])


func generate() -> void:
	var multimesh_lods: Array[MultiMesh] = [
		GrassMultimeshBuilder.build(1.0 * density, TILE_SIZE, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.5 * density, TILE_SIZE, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.25 * density, TILE_SIZE, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.1 * density, TILE_SIZE, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.02 * (1.0 if density != 0.0 else 0.0),
			TILE_SIZE, GRASS_MESH_LOW),
	]
	for data in _tiles:
		var distance: float = data[1].length()
		if distance < 12.0:
			data[0].multimesh = multimesh_lods[0]
		elif distance < 40.0:
			data[0].multimesh = multimesh_lods[1]
		elif distance < 55.0:
			data[0].multimesh = multimesh_lods[2]
		elif distance < 70.0:
			data[0].multimesh = multimesh_lods[3]
		else:
			data[0].multimesh = multimesh_lods[4]
