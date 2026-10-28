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
