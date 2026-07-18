class_name VoronoiFracture
extends RefCounted
## Bakes a box into Voronoi cells. A cell is the half-space intersection of the
## box planes with the bisector plane against every nearby seed, which
## Geometry3D turns into a point cloud; the faces are then recovered plane by
## plane. Output feeds a ConvexPolygonShape3D (the points) and a MeshInstance3D
## (the faces) — the two views of the same convex hull.

# A cell only ever borders its close seeds, so the bisectors against distant ones
# are redundant. Clipping against all of them would make the hull O(N^3) per cell
# and turn a 200-cell wall into a multi-second freeze.
const NEIGHBOURS := 16
const ON_PLANE_EPS := 1e-4


## Returns [{points: PackedVector3Array, mesh: ArrayMesh, center: Vector3,
## seed: int, neighbours: PackedInt32Array}, ...], with points and mesh in the
## cell's own local space (centred on its centroid). neighbours lists the seed
## indices whose bisector actually became a face of this cell — i.e. the cells
## it physically touches — which is what a structural-support graph needs.
static func fracture_box(size: Vector3, seeds: PackedVector3Array) -> Array:
	var cells := []
	var box_planes := Geometry3D.build_box_planes(size * 0.5)
	for i in seeds.size():
		var planes := box_planes.duplicate()
		var owners := PackedInt32Array()
		for j in _nearest(seeds, i):
			var n := (seeds[j] - seeds[i]).normalized()
			var mid := (seeds[j] + seeds[i]) * 0.5
			planes.append(Plane(n, n.dot(mid)))
			owners.append(j)
		var points := Geometry3D.compute_convex_mesh_points(planes)
		if points.size() < 4:
			continue
		var center := Vector3.ZERO
		for p in points:
			center += p
		center /= points.size()
		var local := PackedVector3Array()
		local.resize(points.size())
		for k in points.size():
			local[k] = points[k] - center
		var mesh := _hull_mesh(local, planes, center, box_planes.size())
		if mesh == null:
			continue
		# A bisector that ended up carrying >= 3 hull points survived the clip as
		# a real face, so the two cells share that face and are true neighbours.
		var neighbours := PackedInt32Array()
		for pi in owners.size():
			var plane: Plane = planes[box_planes.size() + pi]
			var on := 0
			for p in points:
				if absf(plane.distance_to(p)) < ON_PLANE_EPS:
					on += 1
					if on == 3:
						neighbours.append(owners[pi])
						break
		cells.append({points = local, mesh = mesh, center = center,
				seed = i, neighbours = neighbours})
	return cells


static func _nearest(seeds: PackedVector3Array, i: int) -> PackedInt32Array:
	var order := []
	for j in seeds.size():
		if j != i:
			order.append({idx = j, d = seeds[i].distance_squared_to(seeds[j])})
	order.sort_custom(func(a, b): return a.d < b.d)
	var out := PackedInt32Array()
	for k in mini(NEIGHBOURS, order.size()):
		out.append(order[k].idx)
	return out


# Vertex colour tags the face's origin so materials can style the raw fracture
# core differently from the wall's finished surface (brick shader keys on it,
# standard materials multiply it in as grime).
const EXTERIOR_COLOR := Color(1.0, 1.0, 1.0)
const INTERIOR_COLOR := Color(0.62, 0.62, 0.62)


# Geometry3D hands back an unordered point cloud, so the faces have to be
# rebuilt: every plane that carries >= 3 of the points is one face, and its
# points fan out in angular order around their centroid. UV is the vertex's
# wall-space XY, so a texture runs unbroken across neighbouring chunks until
# they separate; the first box_plane_count planes are the wall's outer skin.
static func _hull_mesh(local: PackedVector3Array, planes: Array, center: Vector3,
		box_plane_count: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := 0
	for plane_i in planes.size():
		var plane: Plane = planes[plane_i]
		var face_col := EXTERIOR_COLOR if plane_i < box_plane_count else INTERIOR_COLOR
		var on_face := PackedVector3Array()
		for p in local:
			if absf(plane.distance_to(p + center)) < ON_PLANE_EPS:
				on_face.append(p)
		if on_face.size() < 3:
			continue
		var centroid := Vector3.ZERO
		for p in on_face:
			centroid += p
		centroid /= on_face.size()

		var normal := plane.normal
		var u := normal.cross(Vector3.UP)
		if u.length_squared() < 1e-6:
			u = normal.cross(Vector3.RIGHT)
		u = u.normalized()
		var v := normal.cross(u)
		var sorted := Array(on_face)
		sorted.sort_custom(func(a, b):
			var da: Vector3 = a - centroid
			var db: Vector3 = b - centroid
			return atan2(da.dot(v), da.dot(u)) < atan2(db.dot(v), db.dot(u))
		)
		for k in range(1, sorted.size() - 1):
			var tri: Array = [sorted[0], sorted[k], sorted[k + 1]]
			# Godot's front faces are CLOCKWISE, so an outward face must wind against
			# its own normal. Get this backwards and every outer face is culled: the
			# cell's correct normals are then invisible and the wall renders as the
			# unlit inside of its own shards (verified — the outer triangles were all
			# there, all with +Z normals, and all being culled).
			var geo: Vector3 = (tri[1] - tri[0]).cross(tri[2] - tri[0])
			if geo.dot(normal) > 0.0:
				tri.reverse()
			for p in tri:
				st.set_normal(normal)
				st.set_color(face_col)
				var wall: Vector3 = p + center
				st.set_uv(Vector2(wall.x, wall.y))
				st.add_vertex(p)
		faces += 1
	if faces < 4:
		return null
	return st.commit()


## Seeds biased towards an impact point: cells get smaller near it, so the wall
## shatters into shards where it is hit and stays chunky at the edges.
static func seed_points(size: Vector3, count: int, focus: Vector3, bias: float,
		rng: RandomNumberGenerator) -> PackedVector3Array:
	var seeds := PackedVector3Array()
	seeds.resize(count)
	for i in count:
		var p := Vector3(
			rng.randf_range(-0.5, 0.5) * size.x,
			rng.randf_range(-0.5, 0.5) * size.y,
			rng.randf_range(-0.5, 0.5) * size.z
		)
		seeds[i] = p.lerp(focus + (p - focus) * 0.35, bias * rng.randf())
	return seeds
