class_name PortalMath
extends RefCounted

const HALF_TURN := Basis(
	Vector3(-1.0, 0.0, 0.0),
	Vector3(0.0, 1.0, 0.0),
	Vector3(0.0, 0.0, -1.0)
)


static func mapping(source: Transform3D, destination: Transform3D) -> Transform3D:
	if not _is_rigid(source.basis) or not _is_rigid(destination.basis):
		push_error("Portal mapping requires rigid, positive-determinant transforms")
		return Transform3D.IDENTITY
	var source_rigid := Transform3D(source.basis.orthonormalized(), source.origin)
	var destination_rigid := Transform3D(destination.basis.orthonormalized(), destination.origin)
	return destination_rigid * Transform3D(HALF_TURN, Vector3.ZERO) * source_rigid.affine_inverse()


static func map_transform(mapping_transform: Transform3D, value: Transform3D) -> Transform3D:
	var mapped := mapping_transform * value
	return Transform3D(mapped.basis.orthonormalized(), mapped.origin)


static func map_vector(mapping_transform: Transform3D, value: Vector3) -> Vector3:
	return mapping_transform.basis.orthonormalized() * value


static func signed_distance(plane_transform: Transform3D, point: Vector3) -> float:
	var normal := plane_transform.basis.z.normalized()
	return normal.dot(point - plane_transform.origin)


static func crossing_point(previous_local: Vector3, current_local: Vector3) -> Vector3:
	var denominator := previous_local.z - current_local.z
	if absf(denominator) <= 0.000001:
		return current_local
	return previous_local.lerp(current_local, clampf(previous_local.z / denominator, 0.0, 1.0))


static func inside_aperture(point_local: Vector3, opening_size: Vector2) -> bool:
	return absf(point_local.x) <= opening_size.x * 0.5 \
		and absf(point_local.y) <= opening_size.y * 0.5


static func _is_rigid(basis: Basis) -> bool:
	return basis.determinant() > 0.0 \
		and absf(basis.x.length_squared() - 1.0) <= 0.0001 \
		and absf(basis.y.length_squared() - 1.0) <= 0.0001 \
		and absf(basis.z.length_squared() - 1.0) <= 0.0001 \
		and absf(basis.x.dot(basis.y)) <= 0.0001 \
		and absf(basis.x.dot(basis.z)) <= 0.0001 \
		and absf(basis.y.dot(basis.z)) <= 0.0001
