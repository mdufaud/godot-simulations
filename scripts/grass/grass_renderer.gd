class_name GrassRenderer extends Node3D

const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")
const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const GROUND_SHADER := preload("res://shaders/grass/ground.gdshader")
const GrassMultimeshBuilder := preload("res://scripts/grass/grass_multimesh_builder.gd")

const TILE_SIZE := 10.0
const MAP_RADIUS := 80.0
const SHADOW_DISTANCE := 40.0

var config: GrassConfig = GrassConfig.new()
var density := 1.0
var wind_speed := 1.0
var shadows_enabled := true
var material: ShaderMaterial
var _tiles: Array[Array] = []
var _previous_tile_id := Vector3.ZERO
var _gust := 0.0
var _lod_meshes: Array[MultiMesh] = []
var _rank_target := Vector3.ZERO


func build() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	material = GRASS_MAT.duplicate() as ShaderMaterial
	material.set_shader_parameter("heightmap", HEIGHTMAP)
	material.set_shader_parameter("heightmap_scale", config.heightmap_scale_m)
	set_crush_center(Vector3.ZERO)
	_build_tiles()
	generate()


## Soil material displacing a ground mesh with the same heightmap the blades
## sample; assign it to a subdivided ground plane so the visible ground
## matches the field the grass grows on.
func ground_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mat.set_shader_parameter("heightmap", HEIGHTMAP)
	mat.set_shader_parameter("heightmap_scale", config.heightmap_scale_m)
	return mat


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
	var tile_id := ((camera_target + Vector3.ONE * config.tile_size_m * 0.5)
		/ config.tile_size_m * Vector3(1, 0, 1)).floor()
	if tile_id == _previous_tile_id:
		return
	_rank_target = camera_target
	for data in _tiles:
		data[0].global_position = data[1] + Vector3(1, 0, 1) * config.tile_size_m * tile_id
	_previous_tile_id = tile_id
	_rank_tiles()


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
	shadows_enabled = enabled
	_apply_tile_shadows()


## Moves the near-field shadow ring and re-flags the tiles; empty before build().
func set_shadow_distance(distance_m: float) -> void:
	config.shadow_distance_m = distance_m
	_apply_tile_shadows()


func _apply_tile_shadows() -> void:
	for data in _tiles:
		var near: bool = _flat_distance(data[0]) < config.shadow_distance_m
		data[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows_enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_tiles() -> void:
	var half := config.tile_size_m * 0.5
	var tile_aabb := AABB(Vector3(-half - 2.0, -3.0, -half - 2.0),
		Vector3(config.tile_size_m + 4.0, 8.0, config.tile_size_m + 4.0))
	for x in range(-int(config.map_radius_m), int(config.map_radius_m), int(config.tile_size_m)):
		for z in range(-int(config.map_radius_m), int(config.map_radius_m), int(config.tile_size_m)):
			var instance := MultiMeshInstance3D.new()
			instance.material_override = material
			instance.position = Vector3(x, 0.0, z)
			instance.custom_aabb = tile_aabb
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
				if Vector2(x, z).length() < config.shadow_distance_m \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(instance)
			_tiles.append([instance, instance.position])


func generate() -> void:
	_lod_meshes = [
		GrassMultimeshBuilder.build(1.0 * density, config.tile_size_m, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.5 * density, config.tile_size_m, GRASS_MESH_HIGH),
		GrassMultimeshBuilder.build(0.25 * density, config.tile_size_m, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.1 * density, config.tile_size_m, GRASS_MESH_LOW),
		GrassMultimeshBuilder.build(0.02 * (1.0 if density != 0.0 else 0.0),
			config.tile_size_m, GRASS_MESH_LOW),
	]
	_rank_tiles()


## LOD and shadow rings follow the camera focus, not the carpet origin: tiles
## reposition on every tile step and must be re-ranked or grass visibly thins
## around the player.
func _rank_tiles() -> void:
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		var flat := _flat_distance(instance)
		if flat < 12.0:
			instance.multimesh = _lod_meshes[0]
		elif flat < 40.0:
			instance.multimesh = _lod_meshes[1]
		elif flat < 55.0:
			instance.multimesh = _lod_meshes[2]
		elif flat < 70.0:
			instance.multimesh = _lod_meshes[3]
		else:
			instance.multimesh = _lod_meshes[4]
		var near := flat < config.shadow_distance_m
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows_enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _flat_distance(instance: MultiMeshInstance3D) -> float:
	return Vector2(instance.global_position.x - _rank_target.x,
		instance.global_position.z - _rank_target.z).length()
