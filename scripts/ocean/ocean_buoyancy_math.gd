extends RefCounted


static func water_plane(probe_positions: PackedVector3Array,
		probe_depths: PackedFloat32Array, valid_mask: PackedByteArray,
		surface_normal: Vector3) -> Dictionary:
	if probe_positions.size() != probe_depths.size() \
			or (not valid_mask.is_empty() and valid_mask.size() < probe_positions.size()):
		return {}
	var normal := surface_normal.normalized()
	if normal.y <= 0.05:
		return {}
	var plane_offset := 0.0
	var valid_count := 0
	for i in probe_positions.size():
		if not valid_mask.is_empty() and valid_mask[i] == 0:
			continue
		var water_point := probe_positions[i] + Vector3.UP * probe_depths[i]
		plane_offset += normal.dot(water_point)
		valid_count += 1
	if valid_count == 0:
		return {}
	var point := normal * (plane_offset / float(valid_count))
	return {"point": point, "normal": normal}


static func clipped_box(shape_size: Vector3, body_transform: Transform3D,
		plane_point: Vector3, plane_normal: Vector3) -> Dictionary:
	var half := shape_size * 0.5
	var local_vertices := [
		Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, half.y, -half.z), Vector3(-half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z), Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, half.z), Vector3(-half.x, half.y, half.z),
	]
	var vertices: Array[Vector3] = []
	for vertex in local_vertices:
		vertices.append(body_transform.basis * vertex)
	var faces: Array = [
		[0, 1, 5, 4], [3, 7, 6, 2], [0, 3, 2, 1],
		[4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5],
	]
	var normal := plane_normal.normalized()
	if normal.length_squared() < 0.99:
		return {"volume": 0.0, "centroid": body_transform.origin}
	var distances: Array[float] = []
	var any_inside := false
	var any_outside := false
	var relative_plane_point := plane_point - body_transform.origin
	for vertex in vertices:
		var distance := normal.dot(vertex - relative_plane_point)
		distances.append(distance)
		any_inside = any_inside or distance <= 0.000001
		any_outside = any_outside or distance > 0.000001
	if not any_inside:
		return {"volume": 0.0, "centroid": body_transform.origin}
	var total_volume := shape_size.x * shape_size.y * shape_size.z \
		* absf(body_transform.basis.determinant())
	if not any_outside:
		return {"volume": total_volume, "centroid": body_transform.origin}
	var clipped_faces: Array[Array] = []
	var cap_points: Array[Vector3] = []
	for face in faces:
		var clipped: Array[Vector3] = []
		for edge in face.size():
			var current_index: int = face[edge]
			var next_index: int = face[(edge + 1) % face.size()]
			var current_distance: float = distances[current_index]
			var next_distance: float = distances[next_index]
			var current_inside := current_distance <= 0.000001
			var next_inside := next_distance <= 0.000001
			if current_inside:
				clipped.append(vertices[current_index])
			if current_inside != next_inside:
				var fraction := current_distance / (current_distance - next_distance)
				var intersection := vertices[current_index].lerp(vertices[next_index], fraction)
				clipped.append(intersection)
				if not _contains_near(cap_points, intersection):
					cap_points.append(intersection)
		if clipped.size() >= 3:
			clipped_faces.append(clipped)
	if cap_points.size() >= 3:
		var cap_center := Vector3.ZERO
		for point in cap_points:
			cap_center += point
		cap_center /= float(cap_points.size())
		var axis := Vector3.RIGHT if absf(normal.x) < 0.8 else Vector3.FORWARD
		var tangent := axis.cross(normal).normalized()
		var bitangent := normal.cross(tangent)
		cap_points.sort_custom(func(a: Vector3, b: Vector3) -> bool:
			var da := a - cap_center
			var db := b - cap_center
			return atan2(da.dot(bitangent), da.dot(tangent)) \
				< atan2(db.dot(bitangent), db.dot(tangent)))
		clipped_faces.append(cap_points)
	var signed_volume := 0.0
	var centroid_moment := Vector3.ZERO
	for face in clipped_faces:
		var anchor: Vector3 = face[0]
		for i in range(1, face.size() - 1):
			var b: Vector3 = face[i]
			var c: Vector3 = face[i + 1]
			var tetra_volume := anchor.dot(b.cross(c)) / 6.0
			signed_volume += tetra_volume
			centroid_moment += (anchor + b + c) * (tetra_volume * 0.25)
	if signed_volume <= 0.0000001:
		return {"volume": 0.0, "centroid": body_transform.origin}
	return {"volume": signed_volume,
		"centroid": body_transform.origin + centroid_moment / signed_volume}


static func quadratic_drag(relative_velocity: Vector3, projected_area: float,
		fluid_density: float, drag_coefficient: float) -> Vector3:
	var speed := relative_velocity.length()
	if speed <= 0.000001 or projected_area <= 0.0:
		return Vector3.ZERO
	return relative_velocity * (-0.5 * fluid_density * drag_coefficient
		* projected_area * speed)


static func projected_box_area(shape_size: Vector3, body_transform: Transform3D,
		flow_direction: Vector3) -> float:
	if flow_direction.length_squared() <= 0.000001:
		return 0.0
	var direction := flow_direction.normalized()
	var basis := body_transform.basis.orthonormalized()
	return shape_size.y * shape_size.z * absf(direction.dot(basis.x)) \
		+ shape_size.x * shape_size.z * absf(direction.dot(basis.y)) \
		+ shape_size.x * shape_size.y * absf(direction.dot(basis.z))


static func _contains_near(points: Array[Vector3], point: Vector3) -> bool:
	for existing in points:
		if existing.distance_squared_to(point) < 0.0000000001:
			return true
	return false
