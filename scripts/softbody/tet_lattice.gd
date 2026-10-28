class_name TetLattice extends RefCounted
## Tetrahedral lattice of a soft body, in its local frame: the cells of a regular
## grid over the shape's bounding box whose centre lies inside its SDF, each split
## into six Kuhn tetrahedra, mirrored on odd cells, that share vertices with their
## neighbours. A vertex's colour is its lattice parity, so no tetrahedron holds two
## vertices of one colour and every colour can be solved in parallel.

const COLORS := 8
## Corner bits x = 1, y = 2, z = 4. Each tetrahedron walks corner 0 to corner 7
## through these two corners, one per axis order.
const KUHN := [[1, 3], [1, 5], [2, 3], [2, 6], [4, 5], [4, 6]]

var dims := Vector3i.ZERO
var origin := Vector3.ZERO
var cell := Vector3.ZERO
var rest := PackedVector3Array()
var colors := PackedInt32Array()
## Four vertex indices per tetrahedron, positively oriented.
var tets := PackedInt32Array()
## A vertex's share of its tetrahedra volume: its lumped mass per unit density.
var volume_share := PackedFloat32Array()
## 1 where the vertex touches an empty cell.
var surface := PackedByteArray()
## Boundary faces of the tetrahedra, three vertices each, wound so that
## (b - a) x (c - a) points out of the body.
var triangles := PackedInt32Array()
var _cell_first_tet := PackedInt32Array()
var _rest_inverse: Array[Basis] = []


static func build(shape: SoftBodyShape, cell_m: float) -> TetLattice:
	var lattice := TetLattice.new()
	var extent := shape.extent_m()
	var d := Vector3i(maxi(1, roundi(2.0 * extent.x / cell_m)),
		maxi(1, roundi(2.0 * extent.y / cell_m)), maxi(1, roundi(2.0 * extent.z / cell_m)))
	lattice.dims = d
	lattice.cell = 2.0 * extent / Vector3(d)
	lattice.origin = -extent
	var filled := PackedByteArray()
	filled.resize(d.x * d.y * d.z)
	for z in d.z:
		for y in d.y:
			for x in d.x:
				var center := lattice.origin + (Vector3(x, y, z) + Vector3.ONE * 0.5) * lattice.cell
				filled[x + d.x * (y + d.y * z)] = 1 if shape.sdf(center) < 0.0 else 0
	var vertex_of := PackedInt32Array()
	vertex_of.resize((d.x + 1) * (d.y + 1) * (d.z + 1))
	vertex_of.fill(-1)
	var coords: Array[Vector3i] = []
	lattice._cell_first_tet.resize(filled.size())
	lattice._cell_first_tet.fill(-1)
	var corners := PackedInt32Array()
	corners.resize(8)
	for z in d.z:
		for y in d.y:
			for x in d.x:
				var cell_index := x + d.x * (y + d.y * z)
				if filled[cell_index] == 0:
					continue
				for c in 8:
					var v := Vector3i(x + (c & 1), y + ((c >> 1) & 1), z + ((c >> 2) & 1))
					var key := v.x + (d.x + 1) * (v.y + (d.y + 1) * v.z)
					if vertex_of[key] < 0:
						vertex_of[key] = lattice.rest.size()
						lattice.rest.append(lattice.origin + Vector3(v) * lattice.cell)
						lattice.colors.append((v.x & 1) + 2 * (v.y & 1) + 4 * (v.z & 1))
						lattice.volume_share.append(0.0)
						coords.append(v)
					corners[c] = vertex_of[key]
				lattice._cell_first_tet[cell_index] = lattice.tets.size() / 4
				# Mirrored on odd cells: one shared diagonal everywhere makes the
				# material anisotropic; the mirrored faces still match across cells.
				var m := (x & 1) | ((y & 1) << 1) | ((z & 1) << 2)
				for path in KUHN:
					lattice._add_tet(corners[m], corners[path[0] ^ m], corners[path[1] ^ m],
						corners[7 ^ m])
	lattice.surface.resize(coords.size())
	for i in coords.size():
		var v := coords[i]
		var inside := true
		for c in 8:
			var n := v - Vector3i(c & 1, (c >> 1) & 1, (c >> 2) & 1)
			if n.x < 0 or n.y < 0 or n.z < 0 or n.x >= d.x or n.y >= d.y or n.z >= d.z \
					or filled[n.x + d.x * (n.y + d.y * n.z)] == 0:
				inside = false
				break
		lattice.surface[i] = 0 if inside else 1
	lattice._extract_boundary()
	return lattice


func vertex_count() -> int:
	return rest.size()


func tet_count() -> int:
	return tets.size() / 4


func volume() -> float:
	var total := 0.0
	for share in volume_share:
		total += share
	return total


## Rest edge matrix of a tetrahedron: its edges from vertex 0, as columns.
func rest_edges(tet: int) -> Basis:
	var x0 := rest[tets[tet * 4]]
	return Basis(rest[tets[tet * 4 + 1]] - x0, rest[tets[tet * 4 + 2]] - x0,
		rest[tets[tet * 4 + 3]] - x0)


## Per render vertex: CUSTOM0 = the 4 lattice vertices of its tetrahedron,
## CUSTOM1.xyz = its barycentric weights on vertices 1..3, CUSTOM2.xyz = the
## rest edges transposed times its normal (F^-T n = Ds^-T (Dm^T n)).
func embed(points: PackedVector3Array, normals: PackedVector3Array) -> Array[PackedFloat32Array]:
	if _rest_inverse.is_empty():
		for tet in tet_count():
			_rest_inverse.append(rest_edges(tet).inverse())
	var vertices := PackedFloat32Array()
	var weights := PackedFloat32Array()
	var edges := PackedFloat32Array()
	for i in points.size():
		var p := points[i]
		var home := Vector3i(((p - origin) / cell).floor()).clamp(Vector3i.ZERO, dims - Vector3i.ONE)
		var best_tet := -1
		var best_score := -INF
		var best_weights := Vector3.ZERO
		for radius in [1, 2, 4]:
			for z in range(home.z - radius, home.z + radius + 1):
				for y in range(home.y - radius, home.y + radius + 1):
					for x in range(home.x - radius, home.x + radius + 1):
						if x < 0 or y < 0 or z < 0 or x >= dims.x or y >= dims.y or z >= dims.z:
							continue
						var first := _cell_first_tet[x + dims.x * (y + dims.y * z)]
						if first < 0:
							continue
						for tet in range(first, first + 6):
							var w := _rest_inverse[tet] * (p - rest[tets[tet * 4]])
							var score := minf(1.0 - w.x - w.y - w.z, minf(w.x, minf(w.y, w.z)))
							if score > best_score:
								best_score = score
								best_tet = tet
								best_weights = w
			if best_tet >= 0:
				break
		var m := rest_edges(best_tet).transposed() * normals[i]
		vertices.append_array([tets[best_tet * 4], tets[best_tet * 4 + 1],
			tets[best_tet * 4 + 2], tets[best_tet * 4 + 3]])
		weights.append_array([best_weights.x, best_weights.y, best_weights.z, 0.0])
		edges.append_array([m.x, m.y, m.z, 0.0])
	return [vertices, weights, edges]


# A face held by one tetrahedron only is on the boundary. Faces of a positively
# oriented tetrahedron, wound outward.
func _extract_boundary() -> void:
	var faces := {}
	for tet in tet_count():
		var v := tets.slice(tet * 4, tet * 4 + 4)
		for face in [[1, 2, 3], [0, 3, 2], [0, 1, 3], [0, 2, 1]]:
			var tri := Vector3i(v[face[0]], v[face[1]], v[face[2]])
			var sorted := [tri.x, tri.y, tri.z]
			sorted.sort()
			var key := Vector3i(sorted[0], sorted[1], sorted[2])
			if faces.has(key):
				faces.erase(key)
			else:
				faces[key] = tri
	for tri: Vector3i in faces.values():
		triangles.append_array([tri.x, tri.y, tri.z])


func _add_tet(a: int, b: int, c: int, d: int) -> void:
	var x0 := rest[a]
	var volume6 := (rest[b] - x0).dot((rest[c] - x0).cross(rest[d] - x0))
	if volume6 < 0.0:
		tets.append_array([a, c, b, d])
	else:
		tets.append_array([a, b, c, d])
	var share := absf(volume6) / 24.0
	for v in [a, b, c, d]:
		volume_share[v] += share
