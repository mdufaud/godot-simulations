class_name MixwellBoundaries
extends RefCounted

const EDGE_IMAGES := [
	Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)
]
const CORNER_IMAGES := [
	Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1)
]


static func image_count() -> int:
	return EDGE_IMAGES.size() + CORNER_IMAGES.size()


static func mirror_point(value: Vector2, image: Vector2i, half_extent: Vector2) -> Vector2:
	var result := value
	if image.x != 0:
		result.x = 2.0 * float(image.x) * half_extent.x - value.x
	if image.y != 0:
		result.y = 2.0 * float(image.y) * half_extent.y - value.y
	return result


static func mirror_vector(value: Vector2, image: Vector2i) -> Vector2:
	return Vector2(-value.x if image.x != 0 else value.x,
		-value.y if image.y != 0 else value.y)


static func reflection_matrix(image: Vector2i) -> Vector4:
	return Vector4(-1.0 if image.x != 0 else 1.0, 0.0, 0.0,
		-1.0 if image.y != 0 else 1.0)


static func kernel_matrix(relative: Vector2, epsilon: float) -> Vector4:
	if not is_finite(epsilon) or epsilon <= 0.0:
		return Vector4.ZERO
	var radius_squared := relative.length_squared()
	if radius_squared <= 1.0e-30:
		return Vector4(1.0, 0.0, 0.0, 1.0)
	var radius := sqrt(radius_squared)
	var epsilon_squared := epsilon * epsilon
	var radius_epsilon := sqrt(radius_squared + epsilon_squared)
	var radius_epsilon_cubed := radius_epsilon * radius_epsilon * radius_epsilon
	var a := 1.0 - radius * (radius_squared + 2.0 * epsilon_squared) \
			/ radius_epsilon_cubed
	var b := epsilon_squared / (radius * radius_epsilon_cubed)
	return Vector4(a + b * relative.x * relative.x, b * relative.x * relative.y,
		b * relative.y * relative.x, a + b * relative.y * relative.y)


static func matrix_mul(a: Vector4, b: Vector4) -> Vector4:
	return Vector4(
		a.x * b.x + a.y * b.z, a.x * b.y + a.y * b.w,
		a.z * b.x + a.w * b.z, a.z * b.y + a.w * b.w)


static func matrix_inverse(value: Vector4) -> Vector4:
	var determinant := value.x * value.w - value.y * value.z
	if absf(determinant) <= 1.0e-30:
		return Vector4(1.0, 0.0, 0.0, 1.0)
	return Vector4(value.w, -value.y, -value.z, value.x) / determinant


static func calibration_matrix(endpoint: Vector2, half_extent: Vector2, epsilon: float) -> Vector4:
	if not is_finite(endpoint.x) or not is_finite(endpoint.y) \
			or not is_finite(half_extent.x) or not is_finite(half_extent.y) \
			or not is_finite(epsilon) or epsilon <= 0.0:
		return Vector4(1.0, 0.0, 0.0, 1.0)
	var result := Vector4(1.0, 0.0, 0.0, 1.0)
	for image in EDGE_IMAGES + CORNER_IMAGES:
		var image_point := mirror_point(endpoint, image, half_extent)
		result += matrix_mul(kernel_matrix(endpoint - image_point, epsilon),
			reflection_matrix(image))
	return matrix_inverse(result)
