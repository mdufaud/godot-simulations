extends RefCounted

const Tufts := preload("res://scripts/grass/grass_multimesh_builder.gd")
const ROCK_PATHS := [
	"res://resources/rocks/boulder_01/boulder_01_2k.gltf",
	"res://resources/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.gltf",
	"res://resources/rocks/rock_face_02/rock_face_02_2k.gltf",
]

var field := RiverLandscape.new()
var materials: Array[ShaderMaterial] = []
var grass_material: ShaderMaterial
var grass_enabled := true
var grass_density := 0.5
var grass_distance_m := 38.0
var grass_detail := false
var grass_shadows := false
var water_detail := 0.0
var _grass_tiles: Array[MultiMeshInstance3D] = []
var _grass_meshes: Array[ArrayMesh] = []
var _host: Node3D
var _rng := RandomNumberGenerator.new()
var _collision_shapes: Dictionary = {}


func build(host: Node3D) -> void:
	_host = host
	_rng.seed = 41927
	_build_ground()
	_build_background()
	_build_rocks()
	_build_grass()


func set_water_level(level_m: float) -> void:
	var plane := Vector4(0.0, 1.0, -RiverLandscape.SLOPE, -level_m)
	for material in materials:
		material.set_shader_parameter("river_plane", plane)
		material.set_shader_parameter("river_reflection_layer", RiverSystem.REFLECTION_LAYER)
		material.set_shader_parameter("river_height_texture", field.bed_texture)
		material.set_shader_parameter("river_domain_m", RiverLandscape.DOMAIN_M)


func set_water_detail(value: float) -> void:
	water_detail = value
	if not materials.is_empty():
		materials[0].set_shader_parameter("water_detail", value)


func set_water_clarity(value: float) -> void:
	materials[0].set_shader_parameter("water_clarity", value)


func tick(time_s: float, flow_distance_m: float) -> void:
	grass_material.set_shader_parameter("wind_time", fposmod(time_s, 1000.0))
	grass_material.set_shader_parameter("wave_time", fposmod(time_s * 0.8, TAU * 160.0))
	materials[0].set_shader_parameter("flow_distance_m", flow_distance_m)


func set_grass_enabled(enabled: bool) -> void:
	grass_enabled = enabled
	for tile in _grass_tiles:
		tile.visible = enabled


func set_grass_quality(density: float, distance_m: float, high_detail: bool, shadows: bool) -> void:
	grass_density = density
	grass_distance_m = distance_m
	grass_detail = high_detail
	grass_shadows = shadows
	for tile in _grass_tiles:
		tile.multimesh.visible_instance_count = roundi(tile.multimesh.instance_count * density)
		tile.multimesh.mesh = _grass_meshes[1 if high_detail else 0]
		tile.visibility_range_end = distance_m
		tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _texture(asset: String, kind: String) -> Texture2D:
	var path := "res://resources/materials/%s/%s_%s_2k.jpg" % [asset, asset, kind]
	return load(path) as Texture2D


func _build_ground() -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_ground.gdshader")
	for prefix: String in ["gravel", "grass"]:
		var asset := "clean_pebbles" if prefix == "gravel" else "leafy_grass"
		material.set_shader_parameter(prefix + "_albedo", _texture(asset, "diff"))
		material.set_shader_parameter(prefix + "_normal", _texture(asset, "nor_gl"))
		material.set_shader_parameter(prefix + "_roughness", _texture(asset, "rough"))
	material.set_shader_parameter("caustics_texture", load("res://resources/ocean/foam_detail.png"))
	material.set_shader_parameter("water_normal", load("res://resources/ocean/micro_normal.png"))
	material.set_shader_parameter("water_detail", water_detail)
	materials.append(material)
	var mesh := MeshInstance3D.new()
	mesh.name = "RiverBanks"
	mesh.mesh = _ground_mesh()
	mesh.material_override = material
	_host.add_child(mesh)
	mesh.create_trimesh_collision()


func _ground_mesh() -> ArrayMesh:
	var size := Vector2i(145, 321)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var indices := PackedInt32Array()
	for z in size.y:
		for x in size.x:
			var point := (Vector2(x, z) / Vector2(size - Vector2i.ONE) - Vector2.ONE * 0.5) * RiverLandscape.DOMAIN_M
			var dx := (RiverLandscape.bed_height(point + Vector2(0.05, 0.0)) - RiverLandscape.bed_height(point - Vector2(0.05, 0.0))) / 0.1
			var dz := (RiverLandscape.bed_height(point + Vector2(0.0, 0.05)) - RiverLandscape.bed_height(point - Vector2(0.0, 0.05))) / 0.1
			vertices.append(Vector3(point.x, RiverLandscape.bed_height(point), point.y))
			normals.append(Vector3(-dx, 1.0, -dz).normalized())
			uvs.append(point)
			var tangent := Vector3(1.0, dx, 0.0).normalized()
			tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, 1.0]))
			if x < size.x - 1 and z < size.y - 1:
				var i := z * size.x + x
				indices.append_array(PackedInt32Array([i, i + 1, i + size.x, i + 1, i + size.x + 1, i + size.x]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_background() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 100
	var span := 300.0
	for z in n:
		for x in n:
			var point := Vector2(x, z) * (span / n) - Vector2.ONE * span * 0.5
			if absf(point.x + 1.5) < RiverLandscape.DOMAIN_M.x * 0.5 - 3.0 and absf(point.y + 1.5) < RiverLandscape.DOMAIN_M.y * 0.5 - 3.0:
				continue
			for offset: Vector2 in [Vector2.ZERO, Vector2(3.0, 0.0), Vector2(0.0, 3.0), Vector2(3.0, 0.0), Vector2(3.0, 3.0), Vector2(0.0, 3.0)]:
				var p := point + offset
				var outside := maxf(absf(p.x) - RiverLandscape.DOMAIN_M.x * 0.5, absf(p.y) - RiverLandscape.DOMAIN_M.y * 0.5)
				var ridge := (sin(p.x * 0.038 + p.y * 0.027) + sin(p.y * 0.054 - p.x * 0.016)) * 3.0 + 8.0
				var height := RiverLandscape.bed_height(p) + smoothstep(0.0, 40.0, outside) * ridge
				surface.set_uv(p)
				surface.add_vertex(Vector3(p.x, height, p.y))
	surface.generate_normals()
	surface.generate_tangents()
	var instance := MeshInstance3D.new()
	instance.name = "DistantBanks"
	instance.mesh = surface.commit()
	instance.material_override = materials[0]
	_host.add_child(instance)


func _build_rocks() -> void:
	var channel_rocks := [
		Vector3(-2.1, 8.0, 1.45), Vector3(2.0, 5.0, 1.1),
		Vector3(0.2, -1.0, 0.8), Vector3(-2.7, -7.0, 1.25),
		Vector3(2.5, -10.0, 0.7), Vector3(-1.0, 18.0, 1.2),
		Vector3(2.4, 26.0, 1.4), Vector3(-2.5, -26.0, 1.1),
		Vector3(0.7, -35.0, 0.65), Vector3(1.8, 34.0, 0.8),
		Vector3(-3.2, 13.0, 0.75), Vector3(2.4, 12.0, 0.55),
		Vector3(1.8, 0.5, 0.7),
	]
	for rock: Vector3 in channel_rocks:
		var point := Vector2(RiverLandscape.center_x(rock.y) + rock.x, rock.y)
		var base := RiverLandscape.bed_height(point) - 0.22
		var height := rock.z * 1.35
		_add_rock(point, rock.z, base, height)
		field.obstacles.append(Vector4(point.x, point.y, rock.z, base + height))
	for i in 52:
		var z := _rng.randf_range(-76.0, 76.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var point := Vector2(RiverLandscape.center_x(z) + side * (RiverLandscape.half_width(z) + _rng.randf_range(0.2, 7.5)), z)
		var radius := _rng.randf_range(0.35, 1.7)
		_add_rock(point, radius, RiverLandscape.bed_height(point) - radius * 0.3, radius * _rng.randf_range(0.9, 1.5))


func _add_rock(point: Vector2, radius: float, base: float, height: float) -> void:
	var scene := load(ROCK_PATHS[_rng.randi_range(0, ROCK_PATHS.size() - 1)]) as PackedScene
	var rock := scene.instantiate() as Node3D
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(rock, meshes)
	var bounds := AABB()
	for i in meshes.size():
		var box := meshes[i].transform * meshes[i].get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	var scale := Vector3(radius * 2.0 / maxf(bounds.size.x, 0.01), height / maxf(bounds.size.y, 0.01), radius * 2.0 / maxf(bounds.size.z, 0.01))
	rock.scale = scale
	rock.rotation.y = _rng.randf_range(0.0, TAU)
	rock.position = Vector3(point.x, base - bounds.position.y * scale.y, point.y)
	for mesh in meshes:
		for surface in mesh.mesh.get_surface_count():
			var original := mesh.get_active_material(surface) as StandardMaterial3D
			var material := ShaderMaterial.new()
			material.shader = load("res://shaders/river/river_rock.gdshader")
			if original != null:
				material.set_shader_parameter("albedo_texture", original.albedo_texture)
				material.set_shader_parameter("normal_texture", original.normal_texture)
				material.set_shader_parameter("roughness_texture", original.roughness_texture)
				material.set_shader_parameter("roughness_green", original.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN)
				material.set_shader_parameter("albedo_tint", original.albedo_color)
			mesh.set_surface_override_material(surface, material)
			materials.append(material)
	_host.add_child(rock)
	for mesh in meshes:
		if not _collision_shapes.has(mesh.mesh):
			_collision_shapes[mesh.mesh] = mesh.mesh.create_trimesh_shape()
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = _collision_shapes[mesh.mesh]
		mesh.add_child(body)
		body.add_child(shape)
	field.obstacle_meshes.append_array(meshes)


func _collect_meshes(node: Node, meshes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		meshes.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, meshes)


func _build_grass() -> void:
	grass_material = (load("res://resources/grass/grass_material.tres") as ShaderMaterial).duplicate()
	grass_material.set_shader_parameter("heightmap_scale", 0.0)
	grass_material.set_shader_parameter("heightmap", load("res://resources/grass/grass_heightmap.tres"))
	grass_material.set_shader_parameter("base_color", Color(0.08, 0.17, 0.033))
	grass_material.set_shader_parameter("tip_color", Color(0.4, 0.49, 0.13))
	grass_material.set_shader_parameter("wind_speed", 0.6)
	grass_material.set_shader_parameter("gustiness", 0.35)
	_grass_meshes.assign([Tufts.make_tuft_mesh(false, false), Tufts.make_tuft_mesh(true, false)])
	for tile_z in range(-8, 9):
		for tile_x in range(-3, 4):
			var positions := PackedVector3Array()
			for i in 1040:
				var point := Vector2(tile_x * 10.0 + _rng.randf_range(-5.0, 5.0), tile_z * 10.0 + _rng.randf_range(-5.0, 5.0))
				if absf(point.y) > 79.0 or absf(point.x) > 35.0:
					continue
				var edge_density := 1.0 - smoothstep(24.0, 35.0, absf(point.x))
				edge_density *= 1.0 - smoothstep(62.0, 79.0, absf(point.y))
				if _rng.randf() > edge_density:
					continue
				var edge := absf(point.x - RiverLandscape.center_x(point.y)) - RiverLandscape.half_width(point.y)
				if edge < 2.0 or edge > 9.0 or _rng.randf() < 0.14 + 0.1 * sin(point.x * 0.7 + point.y * 0.4):
					continue
				if RiverLandscape.bed_height(point) < RiverLandscape.water_height(point, 0.65) + 0.08:
					continue
				positions.append(Vector3(point.x, RiverLandscape.bed_height(point) - 0.015, point.y))
			if positions.is_empty():
				continue
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_custom_data = true
			multimesh.mesh = _grass_meshes[1 if grass_detail else 0]
			multimesh.instance_count = positions.size()
			multimesh.visible_instance_count = roundi(positions.size() * grass_density)
			for i in positions.size():
				var scale := _rng.randf_range(0.35, 0.7)
				var pose := Transform3D(Basis().scaled(Vector3.ONE * scale), positions[i])
				multimesh.set_instance_transform(i, pose)
				multimesh.set_instance_custom_data(i, Color(_rng.randf(), _rng.randf(), _rng.randf(), _rng.randf()))
			var instance := MultiMeshInstance3D.new()
			instance.name = "BankGrass"
			instance.multimesh = multimesh
			instance.material_override = grass_material
			instance.layers = 4
			instance.visible = grass_enabled
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if grass_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.visibility_range_end = grass_distance_m
			instance.visibility_range_end_margin = 8.0
			_grass_tiles.append(instance)
			_host.add_child(instance)
