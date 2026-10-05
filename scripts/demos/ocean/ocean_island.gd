class_name OceanIsland
extends Node3D

const TERRAIN_DOMAIN_M := 140.0
const TERRAIN_SIZE := 281
const OFFSHORE_DEPTH_M := 4.0
const ISLAND_RADIUS_M := Vector2(35.0, 25.0)
const ISLAND_SHADER := preload("res://shaders/ocean/ocean_island.gdshader")
const BOULDER_ROCK := preload("res://resources/rocks/boulder_01/boulder_01_2k.gltf")

var terrain_material: ShaderMaterial
var _built := false
var _rock_heights := PackedFloat32Array()
var _shore_surface: Texture2D
var _shore_foam: Texture2D
var _shore_domain_m := 160.0
var _foam_enabled := true
var _foam_amount := 1.0


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	_rock_heights.resize(TERRAIN_SIZE * TERRAIN_SIZE)
	_rock_heights.fill(-OFFSHORE_DEPTH_M)
	_build_terrain()
	_add_rock(BOULDER_ROCK, "CentralRock", Vector2(-3.5, -3.0), 25.0, 0.38, -1.2)
	_add_rock(BOULDER_ROCK, "CentralBoulder", Vector2(9.0, -2.0), 11.0, -0.6, 0.85)
	for index in range(6):
		var angle := deg_to_rad(-146.0 + index * 22.0)
		var point := Vector2(cos(angle) * 31.0, sin(angle) * 22.0)
		_add_rock(BOULDER_ROCK, "RockyCoast%d" % index, point,
			11.5 + 1.5 * sin(float(index) * 2.7), -angle + 0.5, -1.0)
	_sync_material()


func sample_bed(world: Vector2) -> float:
	if not _built:
		build()
	var local := world - Vector2(position.x, position.z)
	return maxf(_terrain_height(local), _sample_rock_height(local)) + position.y


func create_bathymetry(size: int, domain: float = 160.0) -> PackedFloat32Array:
	if not _built:
		build()
	var heights := PackedFloat32Array()
	heights.resize(size * size)
	for z in range(size):
		for x in range(size):
			var world := (Vector2(x, z) + Vector2(0.5, 0.5)) * (domain / float(size))
			world -= Vector2.ONE * domain * 0.5
			heights[z * size + x] = sample_bed(world)
	return heights


func bind_shore(surface: Texture2D, foam: Texture2D, domain_m: float = 160.0) -> void:
	_shore_surface = surface
	_shore_foam = foam
	_shore_domain_m = domain_m
	_sync_material()


func set_foam_enabled(enabled: bool) -> void:
	_foam_enabled = enabled
	_sync_material()


func set_foam_amount(amount: float) -> void:
	_foam_amount = maxf(amount, 0.0)
	_sync_material()


func camera_view(view: String) -> Dictionary:
	match view:
		"island_beach":
			return {"target": Vector3(-34.0, 0.3, 4.0), "distance": 20.0,
				"pitch": -7.0, "yaw": -78.0}
		"island_rocks":
			return {"target": Vector3(-4.0, 2.5, -19.0), "distance": 45.0,
				"pitch": -21.0, "yaw": 192.0}
		_:
			return {"target": Vector3(0.0, 2.0, 0.0), "distance": 92.0,
				"pitch": -40.0, "yaw": 27.0}


func _terrain_height(point: Vector2) -> float:
	var ellipse := point / ISLAND_RADIUS_M
	var angle := atan2(ellipse.y, ellipse.x)
	var coast_radius := 1.0 + 0.035 * sin(angle * 3.0 + 0.7)
	coast_radius += 0.018 * sin(angle * 7.0 - 1.1)
	var inward_m := (coast_radius - ellipse.length()) * 29.0
	var beach_height := clampf(inward_m * 0.16, -OFFSHORE_DEPTH_M, 1.8)
	var rocky_height := clampf(inward_m * 0.72, -OFFSHORE_DEPTH_M, 3.0)
	var height := lerpf(beach_height, rocky_height, _rocky_weight(point))
	var dry_blend := smoothstep(0.4, 4.0, inward_m)
	height += dry_blend * (0.065 * sin(point.x * 0.38 + point.y * 0.17)
		+ 0.04 * sin(point.y * 0.72 - point.x * 0.16))
	return height


func _rocky_weight(point: Vector2) -> float:
	var ellipse := point / ISLAND_RADIUS_M
	var north := -ellipse.y / maxf(ellipse.length(), 0.001)
	return smoothstep(0.44, 0.58, north)


func _build_terrain() -> void:
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = ISLAND_SHADER
	terrain_material.set_shader_parameter("foam_detail", load("res://resources/ocean/foam_detail.png"))
	if ResourceLoader.exists("res://resources/ocean/island_sand.png"):
		terrain_material.set_shader_parameter("sand_albedo",
			load("res://resources/ocean/island_sand.png"))
	terrain_material.set_shader_parameter("rock_albedo",
		load("res://resources/rocks/rock_face_02/textures/rock_face_02_diff_2k.jpg"))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	vertices.resize(TERRAIN_SIZE * TERRAIN_SIZE)
	normals.resize(vertices.size())
	colors.resize(vertices.size())
	var step_m := TERRAIN_DOMAIN_M / float(TERRAIN_SIZE - 1)
	for z in range(TERRAIN_SIZE):
		for x in range(TERRAIN_SIZE):
			var point := Vector2(x, z) * step_m - Vector2.ONE * TERRAIN_DOMAIN_M * 0.5
			var index := z * TERRAIN_SIZE + x
			vertices[index] = Vector3(point.x, _terrain_height(point), point.y)
			var dx := _terrain_height(point + Vector2(0.25, 0.0))
			dx -= _terrain_height(point - Vector2(0.25, 0.0))
			var dz := _terrain_height(point + Vector2(0.0, 0.25))
			dz -= _terrain_height(point - Vector2(0.0, 0.25))
			normals[index] = Vector3(-dx / 0.5, 1.0, -dz / 0.5).normalized()
			colors[index] = Color(1.0 - _rocky_weight(point), 0.0, 0.0, 1.0)
			if x < TERRAIN_SIZE - 1 and z < TERRAIN_SIZE - 1:
				indices.append_array(PackedInt32Array([index, index + 1, index + TERRAIN_SIZE,
					index + 1, index + TERRAIN_SIZE + 1, index + TERRAIN_SIZE]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var terrain_mesh := ArrayMesh.new()
	terrain_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var terrain := MeshInstance3D.new()
	terrain.name = "IslandTerrain"
	terrain.mesh = terrain_mesh
	terrain.material_override = terrain_material
	add_child(terrain)
	terrain.create_trimesh_collision()


func _add_rock(scene: PackedScene, rock_name: String, point: Vector2,
		width_m: float, yaw: float, base_m: float) -> void:
	var rock := scene.instantiate() as Node3D
	rock.name = rock_name
	var meshes: Array[Dictionary] = []
	_collect_meshes(rock, Transform3D.IDENTITY, meshes)
	var bounds := AABB()
	for index in range(meshes.size()):
		var entry: Dictionary = meshes[index]
		var mesh_bounds: AABB = entry.transform * entry.mesh.get_aabb()
		bounds = mesh_bounds if index == 0 else bounds.merge(mesh_bounds)
	var scale_factor := width_m / maxf(bounds.size.x, bounds.size.z)
	var center := bounds.get_center()
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_factor)
	var offset := basis * Vector3(center.x, bounds.position.y, center.z)
	rock.transform = Transform3D(basis, Vector3(point.x, base_m, point.y) - offset)
	add_child(rock)
	for entry in meshes:
		var mesh_instance: MeshInstance3D = entry.node
		mesh_instance.create_trimesh_collision()
		var mesh_transform: Transform3D = rock.transform * entry.transform
		var faces: PackedVector3Array = entry.mesh.get_faces()
		for face_index in range(0, faces.size(), 3):
			_rasterize_triangle(mesh_transform * faces[face_index],
				mesh_transform * faces[face_index + 1], mesh_transform * faces[face_index + 2])


func _collect_meshes(node: Node3D, parent_transform: Transform3D,
		meshes: Array[Dictionary]) -> void:
	var node_transform := parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		meshes.append({"node": node, "mesh": node.mesh, "transform": node_transform})
	for child in node.get_children():
		if child is Node3D:
			_collect_meshes(child, node_transform, meshes)


func _rasterize_triangle(a: Vector3, b: Vector3, c: Vector3) -> void:
	var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(denominator) < 0.000001:
		return
	var step_m := TERRAIN_DOMAIN_M / float(TERRAIN_SIZE - 1)
	var half_domain := TERRAIN_DOMAIN_M * 0.5
	var min_x := clampi(int(ceil((minf(a.x, minf(b.x, c.x)) + half_domain) / step_m)), 0, TERRAIN_SIZE - 1)
	var max_x := clampi(int(floor((maxf(a.x, maxf(b.x, c.x)) + half_domain) / step_m)), 0, TERRAIN_SIZE - 1)
	var min_z := clampi(int(ceil((minf(a.z, minf(b.z, c.z)) + half_domain) / step_m)), 0, TERRAIN_SIZE - 1)
	var max_z := clampi(int(floor((maxf(a.z, maxf(b.z, c.z)) + half_domain) / step_m)), 0, TERRAIN_SIZE - 1)
	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var px := x * step_m - half_domain
			var pz := z * step_m - half_domain
			var u := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / denominator
			var v := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / denominator
			if u >= -0.00001 and v >= -0.00001 and u + v <= 1.00001:
				var height := u * a.y + v * b.y + (1.0 - u - v) * c.y
				var index := z * TERRAIN_SIZE + x
				_rock_heights[index] = maxf(_rock_heights[index], height)


func _sample_rock_height(point: Vector2) -> float:
	var uv := (point / TERRAIN_DOMAIN_M + Vector2.ONE * 0.5) * (TERRAIN_SIZE - 1)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x >= TERRAIN_SIZE - 1 or uv.y >= TERRAIN_SIZE - 1:
		return -OFFSHORE_DEPTH_M
	var x := int(floor(uv.x))
	var z := int(floor(uv.y))
	var fraction := uv - Vector2(x, z)
	var index := z * TERRAIN_SIZE + x
	return lerpf(lerpf(_rock_heights[index], _rock_heights[index + 1], fraction.x),
		lerpf(_rock_heights[index + TERRAIN_SIZE], _rock_heights[index + TERRAIN_SIZE + 1], fraction.x), fraction.y)


func _sync_material() -> void:
	if terrain_material == null:
		return
	terrain_material.set_shader_parameter("shore_surface", _shore_surface)
	terrain_material.set_shader_parameter("shore_foam", _shore_foam)
	terrain_material.set_shader_parameter("shore_domain_m", _shore_domain_m)
	terrain_material.set_shader_parameter("shore_enabled", _shore_surface != null and _shore_foam != null)
	terrain_material.set_shader_parameter("foam_amount", _foam_amount if _foam_enabled else 0.0)
