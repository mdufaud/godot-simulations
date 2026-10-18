extends RefCounted

const Tufts := preload("res://scripts/grass/grass_multimesh_builder.gd")
const TorrentLandscape := preload("res://scripts/demos/river/river_torrent_landscape.gd")
const ROCK_PATHS := [
	"res://resources/rocks/boulder_01/boulder_01_2k.gltf",
	"res://resources/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.gltf",
	"res://resources/rocks/rock_face_02/rock_face_02_2k.gltf",
]
const BOULDER_PATHS := [
	"res://resources/rocks/boulder_01/boulder_01_2k.gltf",
	"res://resources/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.gltf",
]
const OUTER_EXTENT_M := 150.0

var field: RiverField = RiverLandscape.new()
var materials: Array[ShaderMaterial] = []
var grass_material: ShaderMaterial
var root: Node3D
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


func build(host: Node3D, selected_field: RiverField = null) -> void:
	clear()
	if selected_field != null:
		field = selected_field
	else:
		field = RiverLandscape.new()
	root = Node3D.new()
	root.name = "RiverScenery"
	host.add_child(root)
	_host = root
	_rng.seed = 41927
	_build_ground()
	LoadingPump.stage("Placing rocks")
	_build_rocks()
	LoadingPump.stage("Planting grass")
	_build_grass()
	if field.waterfall != null and field.waterfall.is_vertical():
		LoadingPump.stage("Building cliff")
		_build_cliff()


func clear() -> void:
	if is_instance_valid(root):
		root.free()
	root = null
	_host = null
	if field != null:
		field.obstacles.clear()
		field.obstacle_meshes.clear()
	materials.clear()
	_grass_tiles.clear()
	_grass_meshes.clear()
	_collision_shapes.clear()


func set_water_level(level_m: float) -> void:
	var plane := Vector4(0.0, 1.0, -field.surface_slope, -level_m)
	for material in materials:
		material.set_shader_parameter("river_plane", plane)
		material.set_shader_parameter("river_reflection_layer", RiverSystem.REFLECTION_LAYER)
		material.set_shader_parameter("river_height_texture", field.bed_texture)
		material.set_shader_parameter("river_domain_m", field.domain_m)
		material.set_shader_parameter("river_waterfall", field.waterfall != null)
		if field.waterfall != null:
			var profile := field.waterfall
			material.set_shader_parameter("river_pool_levels_m", Vector2(level_m, level_m + profile.height_m))
			material.set_shader_parameter("river_fall_geometry", Vector4(profile.width_m, profile.height_m, profile.crest_z_m, profile.run_m()))


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
	LoadingPump.stage("Loading terrain textures")
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_ground.gdshader")
	for prefix: String in ["gravel", "grass"]:
		var asset := "clean_pebbles" if prefix == "gravel" else "leafy_grass"
		material.set_shader_parameter(prefix + "_albedo", _texture(asset, "diff"))
		material.set_shader_parameter(prefix + "_normal", _texture(asset, "nor_gl"))
		material.set_shader_parameter(prefix + "_roughness", _texture(asset, "rough"))
	var rock := "res://resources/rocks/namaqualand_cliff_01/textures/namaqualand_cliff_01_%s_2k.jpg"
	material.set_shader_parameter("rock_albedo", load(rock % "diff"))
	material.set_shader_parameter("rock_normal", load(rock % "nor_gl"))
	material.set_shader_parameter("rock_arm", load(rock % "arm"))
	material.set_shader_parameter("caustics_texture", load("res://resources/ocean/foam_detail.png"))
	material.set_shader_parameter("water_normal", load("res://resources/ocean/micro_normal.png"))
	material.set_shader_parameter("water_detail", water_detail)
	materials.append(material)
	LoadingPump.stage("Computing terrain mesh")
	var mesh := MeshInstance3D.new()
	mesh.name = "RiverBanks"
	mesh.mesh = _ground_mesh()
	mesh.material_override = material
	_host.add_child(mesh)
	LoadingPump.stage("Building terrain collision")
	mesh.create_trimesh_collision()


func _ground_mesh() -> ArrayMesh:
	var torrent := field is TorrentLandscape
	var size := Vector2i(field.domain_m / (0.25 if torrent else 0.5)) + Vector2i.ONE if field.waterfall == null else Vector2i(97, 193)
	field.ground_rows_m.clear()
	var rows := PackedFloat32Array()
	for z in size.y:
		rows.append(-field.domain_m.y * 0.5 + float(z) / float(size.y - 1) * field.domain_m.y)
	if field.waterfall != null:
		if not field.waterfall.is_vertical():
			var crest := field.waterfall.crest_z_m
			var lower_end := crest - field.waterfall.run_m()
			var round_m := minf(0.35, field.waterfall.run_m() * 0.2)
			for z in [lower_end, lower_end + round_m, crest - round_m, crest]:
				rows.append(z)
			for step in range(1, 64):
				rows.append(lerpf(lower_end, crest, float(step) / 64.0))
		rows.sort()
		for z in rows:
			if field.ground_rows_m.is_empty() or z != field.ground_rows_m[-1]:
				field.ground_rows_m.append(z)
		rows = field.ground_rows_m.duplicate()
		size.y = rows.size()
		field.ground_height_image = Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
	var columns := PackedFloat32Array()
	for x in size.x:
		columns.append(-field.domain_m.x * 0.5 + float(x) / float(size.x - 1) * field.domain_m.x)
	columns = _pad_outward(columns, field.domain_m.x / float(size.x - 1))
	rows = _pad_outward(rows, field.domain_m.y / float(size.y - 1))
	var count := Vector2i(columns.size(), rows.size())
	var inner := (count - size) / 2
	var cell_size := field.domain_m / Vector2(size - Vector2i.ONE)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var indices := PackedInt32Array()
	for z in count.y:
		LoadingPump.tick()
		for x in count.x:
			var point := Vector2(columns[x], rows[z])
			var dx := (_terrain(point + Vector2(0.05, 0.0)) - _terrain(point - Vector2(0.05, 0.0))) / 0.1
			var dz := (_terrain(point + Vector2(0.0, 0.05)) - _terrain(point - Vector2(0.0, 0.05))) / 0.1
			if field.waterfall != null and field.waterfall.is_vertical() \
					and absf(point.x) <= field.channel_half_width(point.y) + 0.5 \
					and absf(point.y - field.waterfall.crest_z_m) < 0.4:
				dz = 0.0
			var height := _terrain(point)
			vertices.append(Vector3(point.x, height, point.y))
			var image_cell := Vector2i(x, z) - inner
			if field.ground_height_image != null and image_cell.x >= 0 and image_cell.y >= 0 and image_cell.x < size.x and image_cell.y < size.y:
				field.ground_height_image.set_pixel(image_cell.x, image_cell.y, Color(height, point.y, 0.0, 1.0))
			normals.append(Vector3(-dx, 1.0, -dz).normalized())
			uvs.append(point)
			var tangent := Vector3(1.0, dx, 0.0).normalized()
			tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, 1.0]))
	for z in count.y - 1:
		for x in count.x - 1:
			if _inside_cliff_gap(Vector2(columns[x] + columns[x + 1], rows[z] + rows[z + 1]) * 0.5):
				continue
			var i := z * count.x + x
			if torrent and absf(vertices[i].y - vertices[i + count.x + 1].y) < absf(vertices[i + 1].y - vertices[i + count.x].y):
				indices.append_array(PackedInt32Array([i, i + 1, i + count.x + 1, i, i + count.x + 1, i + count.x]))
			else:
				indices.append_array(PackedInt32Array([i, i + 1, i + count.x, i + 1, i + count.x + 1, i + count.x]))
	if field.waterfall != null and field.waterfall.is_vertical():
		var crest := field.waterfall.crest_z_m
		for side: float in [-1.0, 1.0]:
			for x in size.x - 1:
				var x0 := -field.domain_m.x * 0.5 + x * cell_size.x
				var x1 := x0 + cell_size.x
				var z0 := crest - cell_size.y if side < 0.0 else crest
				var z1 := crest if side < 0.0 else crest + cell_size.y
				var base := vertices.size()
				for point: Vector2 in [Vector2(x0, z0), Vector2(x1, z0), Vector2(x0, z1), Vector2(x1, z1)]:
					vertices.append(Vector3(point.x, _bed(Vector2(point.x, crest + side * 0.001)), point.y))
					normals.append(Vector3.UP)
					uvs.append(point)
					tangents.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
				indices.append_array(PackedInt32Array([base, base + 1, base + 2, base + 1, base + 3, base + 2]))
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


func _pad_outward(values: PackedFloat32Array, step: float) -> PackedFloat32Array:
	var low := PackedFloat32Array()
	var high := PackedFloat32Array()
	var offset := 0.0
	while offset < OUTER_EXTENT_M:
		step *= 1.2
		offset += step
		low.append(values[0] - offset)
		high.append(values[-1] + offset)
	low.reverse()
	low.append_array(values)
	low.append_array(high)
	return low


func _terrain(point: Vector2) -> float:
	var outside := maxf(absf(point.x) - field.domain_m.x * 0.5, absf(point.y) - field.domain_m.y * 0.5)
	if outside <= 0.0:
		return _bed(point)
	var ridge := (sin(point.x * 0.038 + point.y * 0.027) + sin(point.y * 0.054 - point.x * 0.016)) * 3.0 + 8.0
	var banks := 0.0
	if field is TorrentLandscape:
		var torrent := field as TorrentLandscape
		var rect := field.domain_rect()
		var border := torrent.fill_height_m(point.clamp(rect.position, rect.end))
		var free := torrent.fill_height_m(point)
		var blend := clampf(0.5 + 0.5 * (free - border) / 1.5, 0.0, 1.0)
		banks = lerpf(border, free, blend) + 1.5 * blend * (1.0 - blend)
	else:
		var center := _center_x(point.y)
		var reach := _half_width(point.y) + 5.0
		banks = (_bed(Vector2(center - reach, point.y)) + _bed(Vector2(center + reach, point.y))) * 0.5
	var bed := lerpf(_bed(point), maxf(_bed(point), banks), smoothstep(0.0, 4.0 if field is TorrentLandscape else 10.0, outside))
	return bed + smoothstep(0.0, 40.0, outside) * ridge


func _build_rocks() -> void:
	if field.waterfall != null:
		_build_waterfall_bank_rocks()
		return
	if field is TorrentLandscape:
		_build_torrent_rocks()
		return
	if not field is RiverLandscape:
		return
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
		var point := Vector2(_center_x(rock.y) + rock.x * 0.7, rock.y)
		var base := _bed(point) - 0.22
		var radius := rock.z * 0.85
		var height := rock.z * 1.35
		_add_rock(point, radius, base, height)
		field.obstacles.append(Vector4(point.x, point.y, radius, base + height))
	for i in 20:
		var z := _rng.randf_range(-field.domain_m.y * 0.5 + 2.0, field.domain_m.y * 0.5 - 2.0)
		var side := -1.0 if i % 2 == 0 else 1.0
		var point := Vector2(_center_x(z) + side * (_half_width(z) + _rng.randf_range(0.2, 5.0)), z)
		var radius := _rng.randf_range(0.35, 1.7)
		_add_rock(point, radius, _bed(point) - radius * 0.3, radius * _rng.randf_range(0.9, 1.5))


func _build_waterfall_bank_rocks() -> void:
	var profile := field.waterfall
	var crest := profile.crest_z_m
	var foot := crest - profile.run_m()
	var half := profile.width_m * 0.5
	for side: float in [-1.0, 1.0]:
		for rock: Vector3 in [Vector3(half + 1.0, crest + 1.8, 1.0), Vector3(half + 0.2, foot - 3.2, 0.9), Vector3(half + 0.4, foot - 8.5, 1.1)]:
			var point := Vector2(side * rock.x, rock.y + _rng.randf_range(-0.6, 0.6))
			_add_rock(point, rock.z, _bed(point) - rock.z * 0.35, rock.z * _rng.randf_range(1.0, 1.4))
	for i in 10:
		var z := _rng.randf_range(crest + 3.0, field.domain_m.y * 0.5 - 1.5)
		var side := -1.0 if i % 2 == 0 else 1.0
		var radius := _rng.randf_range(0.3, 0.9)
		var point := Vector2(side * (half + _rng.randf_range(1.5, 6.0)), z)
		if absf(point.x) + radius < field.domain_m.x * 0.5:
			_add_rock(point, radius, _bed(point) - radius * 0.3, radius * _rng.randf_range(0.8, 1.3))


func _build_torrent_rocks() -> void:
	var torrent := field as TorrentLandscape
	var inner := field.domain_rect().grow(-1.5)
	var along := -42.0
	while along < 42.0:
		along += _rng.randf_range(2.0, 3.6)
		var half := torrent.half_width_m(along)
		var point := torrent.point_at(along, _rng.randf_range(-0.6, 0.6) * half)
		var radius := minf(_rng.randf_range(0.3, 0.75), half * 0.45)
		var emergence := _rng.randf_range(-0.12, 0.5)
		if not inner.has_point(point):
			continue
		_add_stream_rock(point, radius, emergence)
	for end: float in [-1.0, 1.0]:
		along = 0.0
		while inner.has_point(torrent.point_at(along + end * 0.5, 0.0)):
			along += end * 0.5
		var half := torrent.half_width_m(along)
		for lateral: float in [-1.3, -0.7, -0.1, 0.5, 1.1]:
			var point := torrent.point_at(along + _rng.randf_range(-0.8, 0.8), lateral * half)
			_add_stream_rock(point, minf(_rng.randf_range(0.8, 1.3), half * 0.6), _rng.randf_range(0.5, 1.1))
	for i in 110:
		var side := -1.0 if i % 2 == 0 else 1.0
		along = _rng.randf_range(-42.0, 42.0)
		var radius := lerpf(0.15, 1.1, pow(_rng.randf(), 2.0))
		var point := torrent.point_at(along, side * (torrent.half_width_m(along) + _rng.randf_range(-0.1, 3.2) + radius * 0.5))
		var height := radius * _rng.randf_range(0.7, 1.3)
		if inner.has_point(point):
			_add_rock(point, radius, _footprint_floor(point, radius) - radius * 0.15, height, BOULDER_PATHS)
	var wet_meshes := field.obstacle_meshes.size()
	for i in 28:
		var side := -1.0 if i % 2 == 0 else 1.0
		along = _rng.randf_range(-42.0, 42.0)
		var radius := _rng.randf_range(0.9, 2.2)
		var point := torrent.point_at(along, side * (torrent.half_width_m(along) + _rng.randf_range(4.5, 18.0)))
		var height := radius * _rng.randf_range(0.8, 1.3)
		if inner.has_point(point):
			_add_rock(point, radius, _footprint_floor(point, radius) - radius * 0.2, height, BOULDER_PATHS, 0.3)
	for i in 36:
		var point := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(field.domain_m.x * 0.55, 95.0)
		var radius := _rng.randf_range(1.4, 3.6)
		_add_rock(point, radius, _footprint_floor(point, radius) - radius * 0.3, radius * _rng.randf_range(0.7, 1.2), BOULDER_PATHS, 0.3)
	field.obstacle_meshes.resize(wet_meshes)


func _add_stream_rock(point: Vector2, radius: float, emergence_m: float) -> void:
	var base := _footprint_floor(point, radius) - 0.2
	var top := field.sample_height(point, 0.06) + emergence_m
	_add_rock(point, radius, base, top - base, BOULDER_PATHS)
	if emergence_m > 0.0:
		field.obstacles.append(Vector4(point.x, point.y, radius, top))


func _footprint_floor(point: Vector2, radius: float) -> float:
	var lowest := _terrain(point)
	for offset: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		lowest = minf(lowest, _terrain(point + offset * radius * 0.8))
	return lowest


func _build_cliff() -> void:
	var config: RiverWaterfallConfig = field.waterfall
	var z := config.crest_z_m
	var width := field.domain_m.x
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 96:
		var x0 := -width * 0.5 + width * i / 96.0
		var x1 := -width * 0.5 + width * (i + 1) / 96.0
		var a := Vector3(x0, _bed(Vector2(x0, z - 0.25)), z)
		var b := Vector3(x1, _bed(Vector2(x1, z - 0.25)), z)
		var c := Vector3(x0, _bed(Vector2(x0, z + 0.25)), z)
		var d := Vector3(x1, _bed(Vector2(x1, z + 0.25)), z)
		for point: Vector3 in [a, b, c, b, d, c]:
			surface.set_uv(Vector2(point.x, point.z))
			surface.set_normal(Vector3.FORWARD)
			surface.add_vertex(point)
	surface.generate_tangents()
	var face := MeshInstance3D.new()
	face.name = "WaterfallCliffFace"
	face.mesh = surface.commit()
	face.material_override = materials[0]
	_host.add_child(face)
	face.create_trimesh_collision()


func _add_rock(point: Vector2, radius: float, base: float, height: float, paths: Array = ROCK_PATHS, tilt_rad := 0.0) -> void:
	var scene := load(paths[_rng.randi_range(0, paths.size() - 1)]) as PackedScene
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
	if tilt_rad > 0.0:
		rock.rotation.x = _rng.randf_range(-tilt_rad, tilt_rad)
		rock.rotation.z = _rng.randf_range(-tilt_rad, tilt_rad)
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
				var domain := field.domain_m
				var extent_x := domain.x * 0.5 - 1.0
				var extent_z := domain.y * 0.5 - 1.0
				if absf(point.y) > extent_z or absf(point.x) > extent_x:
					continue
				var edge_density := 1.0 - smoothstep(domain.x * 0.34, extent_x, absf(point.x))
				edge_density *= 1.0 - smoothstep(domain.y * 0.39, extent_z, absf(point.y))
				if _rng.randf() > edge_density:
					continue
				var edge := (field as TorrentLandscape).channel_edge_m(point) if field is TorrentLandscape \
					else absf(point.x - _center_x(point.y)) - _half_width(point.y)
				var band := Vector2(0.6, 18.0) if field is TorrentLandscape else Vector2(2.0, 9.0)
				if edge < band.x or edge > band.y or _rng.randf() < 0.14 + 0.1 * sin(point.x * 0.7 + point.y * 0.4):
					continue
				if field.waterfall != null and absf(point.y - field.waterfall.crest_z_m) < 4.0:
					continue
				if _bed(point) < field.sample_height(point, 0.65) + 0.08:
					continue
				var slope := Vector2(_bed(point + Vector2(0.3, 0.0)) - _bed(point - Vector2(0.3, 0.0)),
					_bed(point + Vector2(0.0, 0.3)) - _bed(point - Vector2(0.0, 0.3))).length() / 0.6
				if slope > 0.6:
					continue
				positions.append(Vector3(point.x, _bed(point) - 0.015, point.y))
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
			if field is TorrentLandscape:
				instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			_grass_tiles.append(instance)
			_host.add_child(instance)


func _bed(point: Vector2) -> float:
	return field.sample_bed(point)


func _center_x(z: float) -> float:
	return RiverLandscape.center_x(z) if field is RiverLandscape else field.channel_center_x(z)


func _half_width(z: float) -> float:
	return RiverLandscape.half_width(z) if field is RiverLandscape else field.channel_half_width(z)


func _inside_cliff_gap(point: Vector2) -> bool:
	return field.waterfall != null and field.waterfall.is_vertical() \
		and absf(point.x) <= field.domain_m.x * 0.5 \
		and absf(point.y - field.waterfall.crest_z_m) <= 0.125
