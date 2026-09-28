class_name GrassRenderer extends Node3D

const GRASS_MESH_HIGH := preload("res://resources/grass/grass_high.obj")
const GRASS_MESH_LOW := preload("res://resources/grass/grass_low.obj")
const GRASS_MAT := preload("res://resources/grass/grass_material.tres")
const HEIGHTMAP := preload("res://resources/grass/grass_heightmap.tres")
const GROUND_SHADER := preload("res://shaders/grass/ground.gdshader")
const GrassMultimeshBuilder := preload("res://scripts/grass/grass_multimesh_builder.gd")

const TILE_VARIANTS := 8
const LOD_DISTANCES := [12.0, 40.0, 55.0, 70.0]

var config: GrassConfig = GrassConfig.new()
var density := 1.0
var near_detail := true
var wind_speed := 1.0
var wind_direction_degrees := 35.0
var gustiness := 0.65
var demo_stage := 3
var shadows_enabled := true
var material: ShaderMaterial
var _tiles: Array[Array] = []
var _previous_tile_id := Vector3.ZERO
var _gust_pulse := 0.0
var _gust_age := -1.0
var _gust_strength := 0.0
var _layout_seed := 821
var _lod_variants: Array[Array] = []
var _rank_camera_position := Vector3.ZERO
var _tuft_mesh_high: ArrayMesh
var _tuft_mesh_low: ArrayMesh


func build() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Grass config: %s" % config_error)
		return
	material = GRASS_MAT.duplicate() as ShaderMaterial
	material.set_shader_parameter("heightmap", HEIGHTMAP)
	material.set_shader_parameter("heightmap_scale", config.heightmap_scale_m)
	_tuft_mesh_high = GrassMultimeshBuilder.make_tuft_mesh(true)
	_tuft_mesh_low = GrassMultimeshBuilder.make_tuft_mesh(false)
	set_wind_speed(wind_speed)
	set_wind_direction(wind_direction_degrees)
	set_gustiness(gustiness)
	set_demo_stage(demo_stage)
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
	mat.set_shader_parameter("clump_noise", material.get_shader_parameter("clump_noise"))
	return mat


func set_wind_speed(value: float) -> void:
	wind_speed = clampf(value, 0.0, 5.0)
	if material != null:
		material.set_shader_parameter("wind_speed", wind_speed)


func set_wind_direction(value_degrees: float) -> void:
	wind_direction_degrees = fposmod(value_degrees, 360.0)
	var angle := deg_to_rad(wind_direction_degrees)
	if material != null:
		material.set_shader_parameter("wind_direction", Vector2(cos(angle), sin(angle)))


func set_gustiness(value: float) -> void:
	gustiness = clampf(value, 0.0, 1.0)
	if material != null:
		material.set_shader_parameter("gustiness", gustiness)


func set_demo_stage(value: int) -> void:
	demo_stage = clampi(value, 0, 3)
	if material != null:
		material.set_shader_parameter("demo_stage", demo_stage)
	for lods in _lod_variants:
		for lod_index in lods.size():
			var multimesh: MultiMesh = lods[lod_index]
			multimesh.mesh = _mesh_for_lod(lod_index)


func set_near_detail(enabled: bool) -> void:
	if near_detail == enabled:
		return
	near_detail = enabled
	set_demo_stage(demo_stage)


func add_gust(strength: float = 1.0, center: Vector3 = Vector3.ZERO) -> void:
	_gust_age = 0.0
	_gust_strength = clampf(strength / 4.0, 0.0, 1.0)
	_gust_pulse = 0.0
	if material != null:
		material.set_shader_parameter("gust_origin", Vector2(center.x, center.z))
		material.set_shader_parameter("gust_age", _gust_age)
		material.set_shader_parameter("gust_pulse", 0.0)


func tick(delta: float, camera_target: Vector3, camera_position: Vector3) -> void:
	if _gust_age >= 0.0:
		_gust_age += delta
		var attack := smoothstep(0.0, 0.7, _gust_age)
		var release := 1.0 - smoothstep(2.2, 4.5, _gust_age)
		_gust_pulse = _gust_strength * attack * release
		material.set_shader_parameter("gust_pulse", _gust_pulse)
		material.set_shader_parameter("gust_age", _gust_age)
		if _gust_age >= 4.5:
			_gust_age = -1.0
	var tile_id := ((camera_target + Vector3.ONE * config.tile_size_m * 0.5)
		/ config.tile_size_m * Vector3(1, 0, 1)).floor()
	var camera_moved := camera_position.distance_squared_to(_rank_camera_position) > 1.0
	if tile_id == _previous_tile_id and not camera_moved:
		return
	_rank_camera_position = camera_position
	if tile_id != _previous_tile_id:
		for data in _tiles:
			var instance: MultiMeshInstance3D = data[0]
			instance.global_position = data[1] + Vector3(1, 0, 1) * config.tile_size_m * tile_id
		_previous_tile_id = tile_id
	_rank_tiles()


func set_density(value: float) -> void:
	value = clampf(value, 0.0, 2.0)
	if is_equal_approx(value, density):
		return
	density = value
	generate()


func set_clumping(value: float) -> void:
	material.set_shader_parameter("clumping_factor", clampf(value, 0.0, 1.0))


func set_colors(base: Color, tip: Color, sss: Color) -> void:
	material.set_shader_parameter("base_color", base)
	material.set_shader_parameter("tip_color", tip)
	material.set_shader_parameter("subsurface_scattering_color", sss)


func set_base_color(color: Color) -> void:
	material.set_shader_parameter("base_color", color)


func set_tip_color(color: Color) -> void:
	material.set_shader_parameter("tip_color", color)


func set_sss_color(color: Color) -> void:
	material.set_shader_parameter("subsurface_scattering_color", color)


func set_plume_color(color: Color) -> void:
	material.set_shader_parameter("plume_color", color)


func set_chromatic_strength(value: float) -> void:
	material.set_shader_parameter("chromatic_strength", value)


func set_shadows(enabled: bool) -> void:
	shadows_enabled = enabled
	_apply_tile_shadows()


func set_shadow_distance(distance_m: float) -> void:
	config.shadow_distance_m = distance_m
	_apply_tile_shadows()


func regenerate() -> void:
	_layout_seed += 1
	generate()


func generate() -> void:
	_lod_variants.clear()
	var high_mesh := _mesh_for_lod(0)
	var low_mesh := _mesh_for_lod(3)
	for variant_id in TILE_VARIANTS:
		_lod_variants.append(GrassMultimeshBuilder.build_lods(
			density, config.tile_size_m, high_mesh, low_mesh,
			_layout_seed + variant_id * 7919))
	_rank_tiles()


func _mesh_for_lod(lod_index: int) -> Mesh:
	var detailed := near_detail and lod_index < 3
	if demo_stage == 0:
		return GRASS_MESH_HIGH if detailed else GRASS_MESH_LOW
	return _tuft_mesh_high if detailed else _tuft_mesh_low


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
			add_child(instance)
			_tiles.append([instance, instance.position])
	_previous_tile_id = Vector3.ZERO


func _apply_tile_shadows() -> void:
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		var near := _camera_distance(instance) < config.shadow_distance_m
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows_enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## LOD and shadow rings follow the camera; orbit and zoom must re-rank tiles.
func _rank_tiles() -> void:
	if _lod_variants.is_empty():
		return
	for data in _tiles:
		var instance: MultiMeshInstance3D = data[0]
		var distance := _camera_distance(instance)
		var lod_index := 0
		while lod_index < LOD_DISTANCES.size() and distance >= LOD_DISTANCES[lod_index]:
			lod_index += 1
		var tile_x := int(round(instance.global_position.x / config.tile_size_m))
		var tile_z := int(round(instance.global_position.z / config.tile_size_m))
		var key := tile_x * 73856093 + tile_z * 19349663 + _layout_seed * 83492791
		var variant_id := absi(key) % TILE_VARIANTS
		instance.multimesh = _lod_variants[variant_id][lod_index]
		var near := distance < config.shadow_distance_m
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows_enabled and near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _camera_distance(instance: MultiMeshInstance3D) -> float:
	return instance.global_position.distance_to(_rank_camera_position)
