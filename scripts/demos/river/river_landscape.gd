class_name RiverLandscape extends RiverField

const DOMAIN_M := Vector2(48.0, 108.0)
const SLOPE := 0.003
const DROP_CENTERS_M := Vector3(14.0, 6.0, -3.0)
const DROP_HEIGHTS_M := Vector3(0.35, 0.55, 0.35)
const DROP_HALF_WIDTH_M := 1.4

func _init() -> void:
	domain_m = DOMAIN_M
	surface_slope = SLOPE
	reflection_anchors_m = Vector4(-4.4, 1.5, 10.0, 15.4)
	terrace_heights_m = Vector4(0.0, 0.35, 0.9, 1.25)


func sample_bed(point: Vector2) -> float:
	return bed_height(point)


func sample_height(point: Vector2, level_m: float) -> float:
	return water_height(point, level_m)


func channel_center_x(z: float) -> float:
	return center_x(z)


func channel_half_width(z: float) -> float:
	return half_width(z)


static func center_x(z: float) -> float:
	return 3.8 * sin(z * 0.075) + 1.1 * sin(z * 0.17 + 0.6)


static func half_width(z: float) -> float:
	return 3.0 + 0.6 * cos(z * 0.12) + 1.3 * exp(-pow((z + 15.0) / 11.0, 2.0))


static func bed_height(point: Vector2) -> float:
	var edge := absf(point.x - center_x(point.y)) - half_width(point.y)
	var bank := smoothstep(-1.3, 5.5, edge)
	var noise := 0.13 * sin(point.x * 0.55 + sin(point.y * 0.2))
	noise += 0.08 * sin(point.y * 0.81 + point.x * 0.36)
	var hillside := 1.0 - exp(-maxf(edge - 6.0, 0.0) * 0.08)
	return channel_height(point.y, point.x) - 0.64 + bank * 2.05 + noise * (0.2 + bank) + hillside * 3.2


static func channel_height(z: float, x: float = 0.0) -> float:
	var height := z * SLOPE
	for index in 3:
		var center := drop_center(x, index)
		height += DROP_HEIGHTS_M[index] * smoothstep(center - DROP_HALF_WIDTH_M, center + DROP_HALF_WIDTH_M, z)
	return height


static func drop_center(x: float, index: int) -> float:
	return DROP_CENTERS_M[index] + 0.65 * sin(x * 0.72 + index * 0.87) + 0.27 * sin(x * 1.38 + index * 0.5)


static func water_height(point: Vector2, level_m: float) -> float:
	return channel_height(point.y, point.x) + level_m


static func water_plane(level_m: float, anchor_z_m: float = 0.0) -> Plane:
	var normal := Vector3(0.0, 1.0, -SLOPE).normalized()
	var height := water_height(Vector2(0.0, anchor_z_m), level_m) - anchor_z_m * SLOPE
	return Plane(normal, height / sqrt(1.0 + SLOPE * SLOPE))


func sample(point: Vector2, level_m: float) -> Color:
	var height := water_height(point, level_m)
	var depth := height - bed_height(point)
	if depth <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var velocity := _reference_velocity(point)
	var tangent := velocity.normalized()
	var source := 0.0
	for index in 3:
		var crest := sin(point.x * 0.95 + index * 2.1) + 0.3 * sin(point.x * 1.77 - index * 0.8)
		var activity := lerpf(0.35, 1.0, smoothstep(-0.8, 0.8, crest))
		source = maxf(source, exp(-pow((point.y - drop_center(point.x, index) + 0.7) / 0.9, 2.0)) * 0.3 * activity)
	var wet := smoothstep(0.0, 0.12, depth)
	for rock in obstacles:
		if rock.w < height - 0.08:
			continue
		var offset := point - Vector2(rock.x, rock.y)
		var radius := rock.z
		var distance := offset.length()
		if distance < radius * 0.82:
			return Color(0.0, 0.0, 0.0, 0.0)
		var normal := offset / maxf(distance, 0.001)
		var influence := 1.0 - smoothstep(radius, radius * 3.0, distance)
		velocity -= normal * velocity.dot(normal) * influence
		velocity += tangent * influence * 0.18
		var along := offset.dot(tangent)
		var across := absf(offset.cross(tangent))
		var wake := exp(-across * across / (radius * radius * 0.45))
		wake *= smoothstep(0.0, radius, along) * (1.0 - smoothstep(radius, radius * 4.0, along))
		var incoming := maxf(-normal.dot(tangent), 0.0)
		var rim := exp(-pow((distance - radius * 1.05) / (radius * 0.24), 2.0)) * incoming * incoming
		source = maxf(source, maxf(wake * 0.35, rim * 0.8))
		wet *= smoothstep(radius * 0.82, radius * 1.0, distance)
	return Color(velocity.x * wet, velocity.y * wet, source * wet, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	var velocity := _reference_velocity(point)
	return Color(velocity.x, velocity.y, 0.0, 1.0)


func _reference_velocity(point: Vector2) -> Vector2:
	var derivative := 3.8 * 0.075 * cos(point.y * 0.075)
	derivative += 1.1 * 0.17 * cos(point.y * 0.17 + 0.6)
	var tangent := Vector2(-derivative, -1.0).normalized()
	var width := half_width(point.y)
	var lateral := absf(point.x - center_x(point.y)) / width
	return tangent * (3.6 / width) * lerpf(1.0, 0.3, smoothstep(0.55, 1.25, lateral))
