extends RefCounted


class CellMeasure extends RefCounted:
	var anchor_m: Vector3 = Vector3.ZERO
	var open_fraction: float = 0.0
	var vertices_m: PackedVector3Array = PackedVector3Array()
	var tetrahedra_m: PackedVector3Array = PackedVector3Array()


static func linear_liquid_fraction(phi_center: float, phi_span: Vector3) -> float:
	var spans: Array[float] = []
	var max_span := maxf(absf(phi_span.x), maxf(absf(phi_span.y), absf(phi_span.z)))
	for span in [absf(phi_span.x), absf(phi_span.y), absf(phi_span.z)]:
		if span > 1.0e-6 * max_span:
			spans.append(span)
	var dimension := spans.size()
	if dimension == 0:
		return 1.0 if phi_center < 0.0 else 0.0
	var total_span := 0.0
	var denominator := 1.0
	for span in spans:
		total_span += span
		denominator *= span
	var threshold := 0.5 * total_span - phi_center
	if threshold <= 0.0:
		return 0.0
	if threshold >= total_span:
		return 1.0
	var factorial := 1.0 if dimension == 1 else (2.0 if dimension == 2 else 6.0)
	var fraction := 0.0
	for subset in range(1 << dimension):
		var shifted_threshold := threshold
		var parity := 0
		for axis in dimension:
			if subset & (1 << axis):
				shifted_threshold -= spans[axis]
				parity += 1
		var term := pow(maxf(shifted_threshold, 0.0), dimension) / (factorial * denominator)
		fraction += -term if parity % 2 else term
	return clampf(fraction, 0.0, 1.0)


static func obstacle_planes(obstacles: Array[Dictionary]) -> Array[Array]:
	var result: Array[Array] = []
	for obstacle in obstacles:
		var transform: Transform3D = obstacle.transform
		var size: Vector3 = obstacle.size
		var planes: Array[Plane] = []
		for local_plane: Plane in Geometry3D.build_box_planes(size * 0.5):
			var normal := transform.basis.inverse().transposed() * local_plane.normal
			if normal.length_squared() <= 1.0e-20:
				continue
			normal = normal.normalized()
			var local_point := local_plane.normal * local_plane.d
			var world_point := transform * local_point
			var plane := Plane(normal, normal.dot(world_point))
			if plane.distance_to(transform.origin) > 0.0:
				plane = Plane(-plane.normal, -plane.d)
			planes.append(plane)
		result.append(planes)
	return result


static func open_cube(center: Vector3, dx: float, domain: AABB,
		obstacles: Array[Array], with_tetrahedra: bool = false) -> CellMeasure:
	if dx <= 0.0:
		return _empty_measure(center)
	var epsilon := maxf(1.0e-7, dx * 1.0e-6)
	var cube_planes: Array[Plane] = []
	for plane: Plane in Geometry3D.build_box_planes(Vector3.ONE * dx * 0.5):
		cube_planes.append(plane)
	var domain_max := domain.position + domain.size
	for axis in 3:
		var positive := Vector3.ZERO
		positive[axis] = 1.0
		var negative := -positive
		cube_planes.append(Plane(positive, domain_max[axis] - center[axis]))
		cube_planes.append(Plane(negative, center[axis] - domain.position[axis]))
	var pieces: Array[Dictionary] = []
	var initial := _piece(cube_planes, epsilon)
	if initial.is_empty():
		return _empty_measure(center)
	pieces.append(initial)
	for obstacle_world: Array in obstacles:
		var cut_planes: Array[Plane] = []
		var obstacle_misses := false
		var obstacle_covers_cube := true
		for world_plane: Plane in obstacle_world:
			var plane := Plane(world_plane.normal, world_plane.d - world_plane.normal.dot(center))
			var extent := 0.5 * dx * (absf(plane.normal.x) + absf(plane.normal.y) + absf(plane.normal.z))
			if -extent - plane.d > epsilon:
				obstacle_misses = true
				break
			if extent - plane.d > epsilon:
				obstacle_covers_cube = false
				cut_planes.append(plane)
		if obstacle_misses:
			continue
		if obstacle_covers_cube:
			return _empty_measure(center)
		var next_pieces: Array[Dictionary] = []
		for current: Dictionary in pieces:
			next_pieces.append_array(_subtract_cube_piece(current, cut_planes, epsilon))
		pieces = next_pieces
		if pieces.is_empty():
			return _empty_measure(center)
	var total_volume := 0.0
	var first_moment := Vector3.ZERO
	var largest_volume := -1.0
	var largest_centroid := Vector3.ZERO
	for piece: Dictionary in pieces:
		var volume: float = piece.volume
		var centroid: Vector3 = piece.centroid
		total_volume += volume
		first_moment += centroid * volume
		if volume > largest_volume:
			largest_volume = volume
			largest_centroid = centroid
	if total_volume <= 0.0:
		return _empty_measure(center)
	var centroid := first_moment / total_volume
	var in_solid := false
	for obstacle_world: Array in obstacles:
		var inside := true
		for world_plane: Plane in obstacle_world:
			var local_plane := Plane(world_plane.normal,
				world_plane.d - world_plane.normal.dot(center))
			if local_plane.distance_to(centroid) > epsilon:
				inside = false
				break
		if inside:
			in_solid = true
			break
	if in_solid:
		centroid = largest_centroid
	var result := CellMeasure.new()
	result.anchor_m = center + centroid
	result.open_fraction = clampf(total_volume / (dx * dx * dx), 0.0, 1.0)
	for piece: Dictionary in pieces:
		for point: Vector3 in piece.points:
			result.vertices_m.append(center + point)
		if not with_tetrahedra:
			continue
		var piece_centroid: Vector3 = piece.centroid
		for face: Dictionary in piece.faces:
			var face_points: PackedVector3Array = face.points
			for index in range(1, face_points.size() - 1):
				var a: Vector3 = face_points[0]
				var b: Vector3 = face_points[index]
				var c: Vector3 = face_points[index + 1]
				if (a - piece_centroid).dot((b - piece_centroid).cross(c - piece_centroid)) == 0.0:
					continue
				result.tetrahedra_m.append(center + piece_centroid)
				result.tetrahedra_m.append(center + a)
				result.tetrahedra_m.append(center + b)
				result.tetrahedra_m.append(center + c)
	return result


static func _empty_measure(center: Vector3) -> CellMeasure:
	var result := CellMeasure.new()
	result.anchor_m = center
	return result


static func open_face(center: Vector3, dx: float, component: int, domain: AABB,
		obstacles: Array[Array]) -> float:
	if dx <= 0.0:
		return 0.0
	var epsilon := maxf(1.0e-7, dx * 1.0e-6)
	var axes := _face_axes(component)
	var domain_max := domain.position + domain.size
	if center[component] < domain.position[component] - epsilon \
			or center[component] > domain_max[component] + epsilon:
		return 0.0
	var half := dx * 0.5
	var pieces: Array[PackedVector2Array] = [PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half)])]
	for face_axis in 2:
		var axis: int = axes[face_axis]
		var upper := domain_max[axis] - center[axis]
		var lower := center[axis] - domain.position[axis]
		var upper_plane := Vector3.ZERO
		var lower_plane := Vector3.ZERO
		if face_axis == 0:
			upper_plane = Vector3(1.0, 0.0, upper)
			lower_plane = Vector3(-1.0, 0.0, lower)
		else:
			upper_plane = Vector3(0.0, 1.0, upper)
			lower_plane = Vector3(0.0, -1.0, lower)
		pieces[0] = _clip_polygon(pieces[0], upper_plane, epsilon)
		pieces[0] = _clip_polygon(pieces[0], lower_plane, epsilon)
		if _polygon_area(pieces[0]) <= epsilon * epsilon:
			return 0.0
	for obstacle_world: Array in obstacles:
		var cut_planes: Array[Vector3] = []
		var obstacle_misses := false
		var obstacle_covers_face := true
		for world_plane: Plane in obstacle_world:
			var a: float = world_plane.normal[axes.x]
			var b: float = world_plane.normal[axes.y]
			var c: float = world_plane.d - world_plane.normal.dot(center)
			var extent := half * (absf(a) + absf(b))
			if -extent - c > epsilon:
				obstacle_misses = true
				break
			if extent - c > epsilon:
				obstacle_covers_face = false
				cut_planes.append(Vector3(a, b, c))
		if obstacle_misses:
			continue
		if obstacle_covers_face:
			return 0.0
		var next_pieces: Array[PackedVector2Array] = []
		for current: PackedVector2Array in pieces:
			next_pieces.append_array(_subtract_face_piece(current, cut_planes, epsilon))
		pieces = next_pieces
		if pieces.is_empty():
			return 0.0
	var area := 0.0
	for polygon: PackedVector2Array in pieces:
		area += _polygon_area(polygon)
	return clampf(area / (dx * dx), 0.0, 1.0)


static func _subtract_cube_piece(current: Dictionary, obstacle: Array[Plane],
		epsilon: float) -> Array[Dictionary]:
	var outside: Array[Dictionary] = []
	var remaining: Dictionary = current
	for plane: Plane in obstacle:
		var points: PackedVector3Array = remaining.points
		var minimum := INF
		var maximum := -INF
		for point in points:
			var distance := plane.distance_to(point)
			minimum = minf(minimum, distance)
			maximum = maxf(maximum, distance)
		if minimum >= -epsilon:
			outside.append(remaining)
			return outside
		if maximum <= epsilon:
			continue
		var outside_piece := _piece(_with_plane(remaining.planes, _flip_plane(plane)), epsilon)
		if not outside_piece.is_empty():
			outside.append(outside_piece)
		remaining = _piece(_with_plane(remaining.planes, plane), epsilon)
		if remaining.is_empty():
			return outside
	return outside


static func _subtract_face_piece(current: PackedVector2Array, obstacle: Array[Vector3],
		epsilon: float) -> Array[PackedVector2Array]:
	var outside: Array[PackedVector2Array] = []
	var remaining := current
	for plane in obstacle:
		var minimum := INF
		var maximum := -INF
		for point in remaining:
			var distance: float = plane.x * point.x + plane.y * point.y - plane.z
			minimum = minf(minimum, distance)
			maximum = maxf(maximum, distance)
		if minimum >= -epsilon:
			outside.append(remaining)
			return outside
		if maximum <= epsilon:
			continue
		var outside_piece := _clip_polygon(remaining, Vector3(-plane.x, -plane.y, -plane.z), epsilon)
		if _polygon_area(outside_piece) > epsilon * epsilon:
			outside.append(outside_piece)
		remaining = _clip_polygon(remaining, plane, epsilon)
		if _polygon_area(remaining) <= epsilon * epsilon:
			return outside
	return outside


static func _piece(planes: Array[Plane], epsilon: float) -> Dictionary:
	if planes.size() < 6:
		return {}
	var box_planes: Array[Plane] = []
	for index in 6:
		box_planes.append(planes[index])
	var box_points: PackedVector3Array = Geometry3D.compute_convex_mesh_points(box_planes)
	if box_points.size() < 4:
		return {}
	var faces: Array[Dictionary] = []
	for plane: Plane in box_planes:
		var points := PackedVector3Array()
		for point in box_points:
			if absf(plane.distance_to(point)) <= epsilon * 4.0:
				points.append(point)
		if points.size() >= 3:
			faces.append({normal = plane.normal, points = _order_points(points, plane.normal, epsilon)})
	for index in range(6, planes.size()):
		faces = _clip_polyhedron(faces, planes[index], epsilon)
		if faces.is_empty():
			return {}
	var points := PackedVector3Array()
	for face: Dictionary in faces:
		for point: Vector3 in face.points:
			_append_unique_point(points, point, epsilon)
	if points.size() < 4:
		return {}
	var reference := Vector3.ZERO
	for point in points:
		reference += point
	reference /= float(points.size())
	var volume := 0.0
	var moment := Vector3.ZERO
	for face: Dictionary in faces:
		var face_points: PackedVector3Array = face.points
		for index in range(1, face_points.size() - 1):
			var a: Vector3 = face_points[0]
			var b: Vector3 = face_points[index]
			var c: Vector3 = face_points[index + 1]
			var tetra_volume := (a - reference).dot((b - reference).cross(c - reference)) / 6.0
			volume += tetra_volume
			moment += (reference + a + b + c) * (0.25 * tetra_volume)
	if volume <= epsilon * epsilon * epsilon:
		return {}
	return {planes = planes, points = points, faces = faces, volume = volume, centroid = moment / volume}


static func _clip_polyhedron(faces: Array[Dictionary], plane: Plane,
		epsilon: float) -> Array[Dictionary]:
	var minimum := INF
	var maximum := -INF
	for face: Dictionary in faces:
		for point: Vector3 in face.points:
			var distance := plane.distance_to(point)
			minimum = minf(minimum, distance)
			maximum = maxf(maximum, distance)
	if maximum <= 0.0:
		return faces
	if minimum > 0.0:
		return []
	var clipped_faces: Array[Dictionary] = []
	var cap_points := PackedVector3Array()
	for face: Dictionary in faces:
		var clipped := _clip_face(face.points, plane, cap_points, epsilon)
		if clipped.size() >= 3 and _polygon_area_3d(clipped, face.normal) > epsilon * epsilon:
			clipped_faces.append({normal = face.normal, points = clipped})
	if cap_points.size() >= 3:
		var cap := _order_points(cap_points, plane.normal, epsilon)
		if cap.size() >= 3 and _polygon_area_3d(cap, plane.normal) > epsilon * epsilon:
			clipped_faces.append({normal = plane.normal, points = cap})
	return clipped_faces


static func _clip_face(points: PackedVector3Array, plane: Plane,
		cap_points: PackedVector3Array, epsilon: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	if points.is_empty():
		return result
	var previous: Vector3 = points[points.size() - 1]
	var previous_distance := plane.distance_to(previous)
	var previous_inside := previous_distance <= 0.0
	for current: Vector3 in points:
		var current_distance := plane.distance_to(current)
		var current_inside := current_distance <= 0.0
		if current_inside != previous_inside:
			var t := previous_distance / (previous_distance - current_distance)
			var intersection := previous.lerp(current, clampf(t, 0.0, 1.0))
			_append_unique_point(result, intersection, epsilon)
			_append_unique_point(cap_points, intersection, epsilon)
		if current_inside:
			_append_unique_point(result, current, epsilon)
			if current_distance == 0.0:
				_append_unique_point(cap_points, current, epsilon)
		previous = current
		previous_distance = current_distance
		previous_inside = current_inside
	return result


static func _order_points(points: PackedVector3Array, normal: Vector3,
		epsilon: float) -> PackedVector3Array:
	var unique := PackedVector3Array()
	for point in points:
		_append_unique_point(unique, point, epsilon)
	if unique.size() < 3:
		return unique
	var center := Vector3.ZERO
	for point in unique:
		center += point
	center /= float(unique.size())
	var u := normal.cross(Vector3.UP)
	if u.length_squared() < 1.0e-10:
		u = normal.cross(Vector3.RIGHT)
	u = u.normalized()
	var v := normal.cross(u)
	var sorted := Array(unique)
	sorted.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		var da := a - center
		var db := b - center
		return atan2(da.dot(v), da.dot(u)) < atan2(db.dot(v), db.dot(u)))
	var result := PackedVector3Array()
	for point: Vector3 in sorted:
		result.append(point)
	return result


static func _append_unique_point(points: PackedVector3Array, point: Vector3,
		epsilon: float) -> void:
	for existing in points:
		if existing.distance_squared_to(point) <= epsilon * epsilon:
			return
	points.append(point)


static func _polygon_area_3d(points: PackedVector3Array, normal: Vector3) -> float:
	if points.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in range(1, points.size() - 1):
		twice_area += (points[index] - points[0]).cross(points[index + 1] - points[0]).dot(normal)
	return absf(twice_area) * 0.5


static func _flip_plane(plane: Plane) -> Plane:
	return Plane(-plane.normal, -plane.d)


static func _with_plane(planes: Array[Plane], plane: Plane) -> Array[Plane]:
	var result: Array[Plane] = planes.duplicate()
	result.append(plane)
	return result


static func _face_axes(component: int) -> Vector2i:
	if component == 0:
		return Vector2i(1, 2)
	if component == 1:
		return Vector2i(0, 2)
	return Vector2i(0, 1)


static func _clip_polygon(polygon: PackedVector2Array, plane: Vector3,
		epsilon: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if polygon.is_empty():
		return result
	var previous: Vector2 = polygon[polygon.size() - 1]
	var previous_distance: float = plane.x * previous.x + plane.y * previous.y - plane.z
	var previous_inside := previous_distance <= epsilon
	for current: Vector2 in polygon:
		var current_distance: float = plane.x * current.x + plane.y * current.y - plane.z
		var current_inside := current_distance <= epsilon
		if current_inside != previous_inside:
			var denominator := previous_distance - current_distance
			if absf(denominator) > 1.0e-20:
				var t := previous_distance / denominator
				result.append(previous.lerp(current, clampf(t, 0.0, 1.0)))
		if current_inside:
			result.append(current)
		previous = current
		previous_distance = current_distance
		previous_inside = current_inside
	return result


static func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var twice_area := 0.0
	for i in polygon.size():
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % polygon.size()]
		twice_area += a.x * b.y - a.y * b.x
	return absf(twice_area) * 0.5
