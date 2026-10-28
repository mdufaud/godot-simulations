class_name AmbientFluidShapes
extends RefCounted
## The ambient fluid demo's three bodies, built in one place for the BEM
## preprocessor (tools/regenerate_ambient_profile.gd) and for the meshes the
## demo renders, so the profiles always describe the drawn shapes.
##
## The surface forces are evaluated per face at its centroid (Eq. 16-22), so a
## face sees a single surface velocity. The sphere is a twice-subdivided
## icosahedron (320 faces) and the boxes are cut into cells of about a quarter
## metre: on a turning body the leading and trailing parts of one side then
## separate independently, which a two-triangle side cannot express.

enum Kind { SPHERE, BOX, PLATE }

const SPHERE_RADIUS := 1.0
const SPHERE_SUBDIVISIONS := 2
const BOX_SIZE := Vector3(1.8, 1.4, 1.0)
const BOX_SUBDIVISIONS := Vector3i(6, 5, 3)
const PLATE_SIZE := Vector3(2.4, 0.18, 1.2)
const PLATE_SUBDIVISIONS := Vector3i(7, 0, 3)


## The render mesh: a smooth-shaded icosphere, or a subdivided BoxMesh.
static func render_mesh(kind: int) -> Mesh:
	match kind:
		Kind.SPHERE:
			return icosphere_mesh(SPHERE_RADIUS, SPHERE_SUBDIVISIONS)
		Kind.BOX:
			return box_mesh(BOX_SIZE, BOX_SUBDIVISIONS)
		_:
			return box_mesh(PLATE_SIZE, PLATE_SUBDIVISIONS)


## The same surface as an ArrayMesh, the preprocessor's input.
static func bem_mesh(kind: int) -> ArrayMesh:
	var mesh := render_mesh(kind)
	if mesh is ArrayMesh:
		return mesh
	var converted := ArrayMesh.new()
	converted.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.get_mesh_arrays())
	return converted


static func box_mesh(size: Vector3, subdivisions: Vector3i) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	box.subdivide_width = subdivisions.x
	box.subdivide_height = subdivisions.y
	box.subdivide_depth = subdivisions.z
	return box


static func icosphere_vertices(radius: float, subdivisions: int) -> PackedVector3Array:
	return _icosphere(radius, subdivisions).vertices


static func icosphere_mesh(radius: float, subdivisions: int) -> ArrayMesh:
	var sphere := _icosphere(radius, subdivisions)
	var vertices: PackedVector3Array = sphere.vertices
	var indices: PackedInt32Array = sphere.indices
	var normals := PackedVector3Array()
	for vertex in vertices:
		normals.append(vertex.normalized())
	# Godot's front faces wind clockwise seen from outside.
	for triangle in range(0, indices.size(), 3):
		var second := indices[triangle + 1]
		indices[triangle + 1] = indices[triangle + 2]
		indices[triangle + 2] = second
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Icosahedron on the sphere of `radius`, each subdivision splitting every
## triangle in four and pushing the new vertices out to the sphere.
static func _icosphere(radius: float, subdivisions: int) -> Dictionary:
	var golden_ratio := (1.0 + sqrt(5.0)) * 0.5
	var vertices := PackedVector3Array([
		Vector3(-1.0, golden_ratio, 0.0), Vector3(1.0, golden_ratio, 0.0),
		Vector3(-1.0, -golden_ratio, 0.0), Vector3(1.0, -golden_ratio, 0.0),
		Vector3(0.0, -1.0, golden_ratio), Vector3(0.0, 1.0, golden_ratio),
		Vector3(0.0, -1.0, -golden_ratio), Vector3(0.0, 1.0, -golden_ratio),
		Vector3(golden_ratio, 0.0, -1.0), Vector3(golden_ratio, 0.0, 1.0),
		Vector3(-golden_ratio, 0.0, -1.0), Vector3(-golden_ratio, 0.0, 1.0),
	])
	for index in vertices.size():
		vertices[index] = vertices[index].normalized() * radius
	var indices := PackedInt32Array([
		0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
		1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
		4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
	])
	for _level in subdivisions:
		var midpoints := {}
		var refined := PackedInt32Array()
		for triangle in range(0, indices.size(), 3):
			var a := indices[triangle]
			var b := indices[triangle + 1]
			var c := indices[triangle + 2]
			var ab := _midpoint(vertices, midpoints, a, b, radius)
			var bc := _midpoint(vertices, midpoints, b, c, radius)
			var ca := _midpoint(vertices, midpoints, c, a, radius)
			refined.append_array(PackedInt32Array([a, ab, ca, b, bc, ab, c, ca, bc,
				ab, bc, ca]))
		indices = refined
	return {vertices = vertices, indices = indices}


static func _midpoint(vertices: PackedVector3Array, midpoints: Dictionary, a: int, b: int,
		radius: float) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if midpoints.has(key):
		return midpoints[key]
	vertices.append(((vertices[a] + vertices[b]) * 0.5).normalized() * radius)
	midpoints[key] = vertices.size() - 1
	return vertices.size() - 1
