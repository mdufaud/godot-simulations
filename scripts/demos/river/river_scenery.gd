extends RefCounted

const Tufts := preload("res://scripts/grass/grass_multimesh_builder.gd")
const TorrentLandscape := preload("res://scripts/demos/river/river_torrent_landscape.gd")
const WaterfallLandscape := preload("res://scripts/demos/river/river_waterfall_landscape.gd")
const CascadeLandscape := preload("res://scripts/demos/river/river_cascade_landscape.gd")
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
const DROPPED_HEIGHT_RATIO := 1.25
const DROP_CLEARANCE_M := 0.05
const ROCK_DENSITY_KG_M3 := 2600.0
const ROCK_FRICTION := 0.9
const ROCK_BOUNCE := 0.1
const SETTLE_TIMEOUT_S := 10.0
const CREST_ROCK_SETBACK_M := 0.45
# The cliff below a vertical crest is a ground row this far downstream of it, so the face stands upright.
const CLIFF_SEAM_M := 0.01
# Ground triangles steeper than this, about 82 degrees, are the steps a spilling field falls from.
const CLIFF_SLOPE := 7.0
const CLIFF_SPAN_M := 0.4

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
var fall_rocks := true
var dropped_rocks := 0
var ground_cache: Dictionary = {}
var _grass_tiles: Array[MultiMeshInstance3D] = []
var _grass_meshes: Array[ArrayMesh] = []
var _host: Node3D
var _rng := RandomNumberGenerator.new()
var _collision_shapes: Dictionary = {}
var _hull_points: Dictionary = {}
var _falling: Dictionary[RigidBody3D, float] = {}


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


func clear() -> void:
	if dropped_rocks > 0 and field != null:
		field.solver_terrain_image = null
	dropped_rocks = 0
	_falling.clear()
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
	_hull_points.clear()


func set_water_level(level_m: float) -> void:
	var plane := Vector4(0.0, 1.0, -field.surface_slope, -level_m)
	for material in materials:
		material.set_shader_parameter("river_plane", plane)
		material.set_shader_parameter("river_reflection_layer", RiverSystem.REFLECTION_LAYER)
		material.set_shader_parameter("river_height_texture", field.bed_texture)
		material.set_shader_parameter("river_domain_m", field.domain_m)
		material.set_shader_parameter("river_pool_planes", field.reflection_pools)
		if field.reflection_pools:
			var anchors := field.reflection_anchors_m
			material.set_shader_parameter("river_pool_levels_m", Vector2(field.reflection_plane(level_m, anchors.x).d,
				field.reflection_plane(level_m, anchors.y).d))


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
	var ground: Array = ground_cache.get(field, [])
	if ground.is_empty():
		LoadingPump.stage("Computing terrain mesh")
		var built := _ground_mesh()
		LoadingPump.stage("Building terrain collision")
		ground = [built, built.create_trimesh_shape()]
		ground_cache[field] = ground
	var mesh := MeshInstance3D.new()
	mesh.name = "RiverBanks"
	mesh.mesh = ground[0]
	mesh.material_override = material
	_host.add_child(mesh)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = ground[1]
	mesh.add_child(body)
	body.add_child(shape)


func _ground_mesh() -> ArrayMesh:
	var torrent := field is TorrentLandscape
	var fall := field as WaterfallLandscape
	var rows := PackedFloat32Array()
	var columns := PackedFloat32Array()
	var size := Vector2i.ZERO
	if field is CascadeLandscape:
		# One vertex per solver cell centre, so a lip between two cells stands as one upright quad.
		size = Vector2i(field.domain_m / CascadeLandscape.GRID_CELL_M)
		for z in size.y:
			rows.append(-field.domain_m.y * 0.5 + (z + 0.5) * CascadeLandscape.GRID_CELL_M)
		for x in size.x:
			columns.append(-field.domain_m.x * 0.5 + (x + 0.5) * CascadeLandscape.GRID_CELL_M)
	else:
		size = Vector2i(field.domain_m / (0.25 if torrent or fall != null else 0.5)) + Vector2i.ONE
		for z in size.y:
			rows.append(-field.domain_m.y * 0.5 + float(z) / float(size.y - 1) * field.domain_m.y)
		for x in size.x:
			columns.append(-field.domain_m.x * 0.5 + float(x) / float(size.x - 1) * field.domain_m.x)
	if fall != null:
		var crest := fall.CREST_Z_M
		if fall.is_vertical():
			rows.append_array(PackedFloat32Array([crest - CLIFF_SEAM_M, crest]))
		else:
			var lower_end := crest - fall.run_m()
			var round_m := minf(fall.RAMP_ROUND_M, fall.run_m() * 0.2)
			for z in [lower_end - round_m, lower_end, lower_end + round_m, crest - round_m, crest, crest + round_m]:
				rows.append(z)
			for step in range(1, 64):
				rows.append(lerpf(lower_end, crest, float(step) / 64.0))
		rows.sort()
		var unique := PackedFloat32Array()
		for z in rows:
			if unique.is_empty() or z != unique[-1]:
				unique.append(z)
		rows = unique
		size.y = rows.size()
	columns = _pad_outward(columns, CascadeLandscape.GRID_CELL_M if field is CascadeLandscape else field.domain_m.x / float(size.x - 1))
	rows = _pad_outward(rows, field.domain_m.y / float(size.y - 1))
	var count := Vector2i(columns.size(), rows.size())
	var spills := field.spills
	var vertex_rows := []
	vertex_rows.resize(count.y)
	var vertex_task := WorkerThreadPool.add_group_task(func(z: int) -> void:
		var row_vertices := PackedVector3Array()
		var row_normals := PackedVector3Array()
		var row_uvs := PackedVector2Array()
		var row_tangents := PackedFloat32Array()
		for x in count.x:
			var point := Vector2(columns[x], rows[z])
			var height := _terrain(point)
			var dx := _ground_slope(_terrain(point + Vector2(0.05, 0.0)) - height, height - _terrain(point - Vector2(0.05, 0.0)), spills)
			var dz := _ground_slope(_terrain(point + Vector2(0.0, 0.05)) - height, height - _terrain(point - Vector2(0.0, 0.05)), spills)
			row_vertices.append(Vector3(point.x, height, point.y))
			row_normals.append(Vector3(-dx, 1.0, -dz).normalized())
			row_uvs.append(point)
			var tangent := Vector3(1.0, dx, 0.0).normalized()
			row_tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, 1.0]))
		vertex_rows[z] = [row_vertices, row_normals, row_uvs, row_tangents], count.y)
	LoadingPump.wait_for_group(vertex_task)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	for row: Array in vertex_rows:
		vertices.append_array(row[0])
		normals.append_array(row[1])
		uvs.append_array(row[2])
		tangents.append_array(row[3])
	var index_rows := []
	index_rows.resize(count.y - 1)
	var index_task := WorkerThreadPool.add_group_task(func(z: int) -> void:
		var row := PackedInt32Array()
		var cliffs := PackedInt32Array()
		for x in count.x - 1:
			var i := z * count.x + x
			var quad := PackedInt32Array([i, i + 1, i + count.x + 1, i, i + count.x + 1, i + count.x]) \
				if torrent and absf(vertices[i].y - vertices[i + count.x + 1].y) < absf(vertices[i + 1].y - vertices[i + count.x].y) \
				else PackedInt32Array([i, i + 1, i + count.x, i + 1, i + count.x + 1, i + count.x])
			for t in 2:
				var triangle := quad.slice(t * 3, t * 3 + 3)
				var facet := (vertices[triangle[1]] - vertices[triangle[0]]).cross(vertices[triangle[2]] - vertices[triangle[0]])
				if spills and Vector2(facet.x, facet.z).length() > CLIFF_SLOPE * absf(facet.y):
					cliffs.append_array(triangle)
				else:
					row.append_array(triangle)
		index_rows[z] = [row, cliffs], count.y - 1)
	LoadingPump.wait_for_group(index_task)
	var indices := PackedInt32Array()
	var cliffs := PackedInt32Array()
	for row: Array in index_rows:
		indices.append_array(row[0])
		cliffs.append_array(row[1])
	# A cliff triangle gets its own vertices, shared ones would shade the wall like the ground above it. It faces down
	# the slope smoothed over CLIFF_SPAN_M, so a lip across the cell staircase does not shade as stripes.
	for c in range(0, cliffs.size(), 3):
		var corners := [vertices[cliffs[c]], vertices[cliffs[c + 1]], vertices[cliffs[c + 2]]]
		var centre: Vector3 = (corners[0] + corners[1] + corners[2]) / 3.0
		var point := Vector2(centre.x, centre.z)
		var facing := Vector2(_terrain(point - Vector2(CLIFF_SPAN_M, 0.0)) - _terrain(point + Vector2(CLIFF_SPAN_M, 0.0)),
			_terrain(point - Vector2(0.0, CLIFF_SPAN_M)) - _terrain(point + Vector2(0.0, CLIFF_SPAN_M)))
		var normal: Vector3 = Vector3(facing.x, 0.0, facing.y).normalized() if facing.length() > 0.01 \
			else (corners[2] - corners[0]).cross(corners[1] - corners[0]).normalized()
		for corner: Vector3 in corners:
			indices.append(vertices.size())
			vertices.append(corner)
			normals.append(normal)
			uvs.append(Vector2(corner.x, corner.z))
			tangents.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 1.0]))
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


# Slope from the forward and backward differences: their mean on smooth ground, the gentler one where they disagree
# by a step, so a vertex at the foot or top of a cliff keeps the slope of its own side.
static func _ground_slope(forward_m: float, backward_m: float, spills: bool) -> float:
	if spills and absf(forward_m - backward_m) > CLIFF_SLOPE * 0.05:
		return (forward_m if absf(forward_m) < absf(backward_m) else backward_m) / 0.05
	return (forward_m + backward_m) / 0.1


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
	if field is WaterfallLandscape:
		_build_waterfall_bank_rocks()
		return
	if field is TorrentLandscape:
		_build_torrent_rocks()
		return
	if field is CascadeLandscape:
		_build_cascade_rocks()
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
	var profile := field as WaterfallLandscape
	var crest := profile.CREST_Z_M
	var foot := crest - profile.run_m()
	var half := profile.WIDTH_M * 0.5
	if fall_rocks:
		_build_fall_rocks()
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


func _build_fall_rocks() -> void:
	var profile := field as WaterfallLandscape
	var crest := profile.CREST_Z_M
	var lip := profile.HEIGHT_M - profile.BED_DEPTH_M
	var cliff := profile.angle_degrees >= 70.0
	var crest_point := Vector2(-1.7, crest + CREST_ROCK_SETBACK_M)
	_add_rock(crest_point, 0.6, lip - 0.3, profile.HEIGHT_M + 0.42 - (lip - 0.3), BOULDER_PATHS)
	# (x m, fraction of the drop below the lip, radius m, height above the face upstream: only water with v^2/2g past it climbs on)
	var face_rocks := [] if cliff else [Vector4(1.1, 0.33, 0.6, 0.45), Vector4(-0.95, 0.62, 0.5, 0.4)]
	for rock: Vector4 in face_rocks:
		var face_y := lip - rock.y * profile.HEIGHT_M
		var point := Vector2(rock.x, crest - rock.y * profile.run_m())
		var top := face_y + rock.z * profile.HEIGHT_M / profile.run_m() + rock.w
		var base := maxf(_footprint_floor(point, rock.z), face_y - rock.z * 1.2) - 0.15
		_add_rock(point, rock.z, base, top - base, BOULDER_PATHS)
	var impact := crest - (profile.run_m() if not cliff else 0.9)
	for rock: Vector4 in [Vector4(2.0, impact - 0.7, 0.6, 0.45), Vector4(-2.25, impact - 2.1, 0.5, 0.32)]:
		var point := Vector2(rock.x, rock.y)
		var base := _footprint_floor(point, rock.z) - 0.2
		_add_rock(point, rock.z, base, rock.w - base, BOULDER_PATHS)


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


func _build_cascade_rocks() -> void:
	var cascade := field as CascadeLandscape
	for river in cascade.rivers:
		for k in river.lips_m.size():
			for spur_across: float in river.spurs_m[k]:
				var point: Vector2 = river.line_point(river.lips_m[k] - 0.4, spur_across)
				var radius := _rng.randf_range(0.3, 0.45)
				_add_rock(point, radius, _footprint_floor(point, radius) - 0.1, radius * _rng.randf_range(0.9, 1.4), BOULDER_PATHS)
	for rock: Vector3 in [Vector3(-4.5, -15.0, 0.8), Vector3(2.5, -16.5, 0.6), Vector3(-2.5, -18.0, 0.7), Vector3(4.0, -9.5, 0.5)]:
		_add_stream_rock(Vector2(rock.x, rock.y), rock.z, _rng.randf_range(0.15, 0.45))
	var wet_meshes := field.obstacle_meshes.size()
	var inner := field.domain_rect().grow(-1.5)
	for i in 60:
		var point := Vector2(_rng.randf_range(inner.position.x, inner.end.x), _rng.randf_range(inner.position.y, inner.end.y))
		if cascade.channel_edge_m(point) < 1.2:
			continue
		var radius := lerpf(0.2, 1.2, pow(_rng.randf(), 2.0))
		_add_rock(point, radius, _footprint_floor(point, radius) - radius * 0.2, radius * _rng.randf_range(0.7, 1.3), BOULDER_PATHS)
	for i in 30:
		var point := Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(field.domain_m.y * 0.55, 95.0)
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


func add_dropped_rock(hit: Vector3, normal: Vector3) -> void:
	var radius := _rng.randf_range(0.45, 0.75)
	var height := radius * DROPPED_HEIGHT_RATIO
	dropped_rocks += 1
	var rock := _make_rock(radius, height, BOULDER_PATHS, 0.0)
	rock.name = "Rock"
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(rock, meshes)
	rock.position -= rock.transform * _rock_bounds(meshes).get_center()
	var points := PackedVector3Array()
	for mesh in meshes:
		if not _hull_points.has(mesh.mesh):
			_hull_points[mesh.mesh] = (mesh.mesh.create_convex_shape(true, true) as ConvexPolygonShape3D).points
		for point: Vector3 in _hull_points[mesh.mesh]:
			points.append(rock.transform * (mesh.transform * point))
	var hull := ConvexPolygonShape3D.new()
	hull.points = points
	var shape := CollisionShape3D.new()
	shape.shape = hull
	var body := RigidBody3D.new()
	body.name = "FallingRock"
	body.mass = ROCK_DENSITY_KG_M3 * TAU / 3.0 * radius * radius * height
	body.continuous_cd = true
	body.physics_material_override = PhysicsMaterial.new()
	body.physics_material_override.friction = ROCK_FRICTION
	body.physics_material_override.bounce = ROCK_BOUNCE
	body.add_child(shape)
	body.add_child(rock)
	_host.add_child(body)
	body.global_position = hit + normal * (maxf(radius, height * 0.5) + DROP_CLEARANCE_M)
	_falling[body] = 0.0


func settle_rocks(delta: float, frozen: bool) -> Array[MeshInstance3D]:
	var settled: Array[MeshInstance3D] = []
	for body: RigidBody3D in _falling.keys():
		body.freeze = frozen
		if frozen:
			continue
		_falling[body] += delta
		if not body.sleeping and _falling[body] < SETTLE_TIMEOUT_S:
			continue
		_falling.erase(body)
		var rock := body.get_node("Rock") as Node3D
		var pose := rock.global_transform
		body.remove_child(rock)
		_host.add_child(rock)
		rock.global_transform = pose
		body.queue_free()
		settled.append_array(_anchor_rock(rock))
	return settled


func falling_rocks() -> int:
	return _falling.size()


func _add_rock(point: Vector2, radius: float, base: float, height: float, paths: Array = ROCK_PATHS, tilt_rad := 0.0) -> Array[MeshInstance3D]:
	var rock := _make_rock(radius, height, paths, tilt_rad)
	rock.position += Vector3(point.x, base, point.y)
	_host.add_child(rock)
	return _anchor_rock(rock)


func _make_rock(radius: float, height: float, paths: Array, tilt_rad: float) -> Node3D:
	var scene := load(paths[_rng.randi_range(0, paths.size() - 1)]) as PackedScene
	var rock := scene.instantiate() as Node3D
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(rock, meshes)
	var bounds := _rock_bounds(meshes)
	var scale := Vector3(radius * 2.0 / maxf(bounds.size.x, 0.01), height / maxf(bounds.size.y, 0.01), radius * 2.0 / maxf(bounds.size.z, 0.01))
	rock.scale = scale
	rock.rotation.y = _rng.randf_range(0.0, TAU)
	if tilt_rad > 0.0:
		rock.rotation.x = _rng.randf_range(-tilt_rad, tilt_rad)
		rock.rotation.z = _rng.randf_range(-tilt_rad, tilt_rad)
	rock.position = Vector3(0.0, -bounds.position.y * scale.y, 0.0)
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
	return rock


func _anchor_rock(rock: Node3D) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(rock, meshes)
	for mesh in meshes:
		if not _collision_shapes.has(mesh.mesh):
			_collision_shapes[mesh.mesh] = mesh.mesh.create_trimesh_shape()
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = _collision_shapes[mesh.mesh]
		mesh.add_child(body)
		body.add_child(shape)
	field.obstacle_meshes.append_array(meshes)
	return meshes


func _rock_bounds(meshes: Array[MeshInstance3D]) -> AABB:
	var bounds := AABB()
	for i in meshes.size():
		var box := meshes[i].transform * meshes[i].get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	return bounds


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
					else ((field as CascadeLandscape).channel_edge_m(point) if field is CascadeLandscape \
					else absf(point.x - _center_x(point.y)) - _half_width(point.y))
				var band := Vector2(0.6, 18.0) if field is TorrentLandscape or field is CascadeLandscape else Vector2(2.0, 9.0)
				if edge < band.x or edge > band.y or _rng.randf() < 0.14 + 0.1 * sin(point.x * 0.7 + point.y * 0.4):
					continue
				if field is WaterfallLandscape and absf(point.y - WaterfallLandscape.CREST_Z_M) < 4.0:
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
