extends "res://scripts/demos/river/river_slope_landscape.gd"

const BANK_WIDTH_M := 1.1
const SIDE_START_M := 1.6
const SIDE_GRADE := 0.25
const HILL_HEIGHT_M := 1.8
const FILL_EDGE_M := 2.2


func sample_bed(point: Vector2) -> float:
	return _bed_at(_along_m(point), _lateral_m(point))


func sample(point: Vector2, level_m: float) -> Color:
	var height := sample_height(point, level_m)
	var wet := smoothstep(0.0, 0.12, height - sample_bed(point))
	if wet <= 0.0:
		return Color(0.0, 0.0, 0.0, 0.0)
	var tangent := _tangent(point)
	var velocity := tangent
	var source := 0.0
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
		wet *= smoothstep(radius * 0.82, radius, distance)
	return Color(velocity.x * wet, velocity.y * wet, source * wet, wet)


func half_width_m(along_m: float) -> float:
	return 1.7 + 0.45 * sin(along_m * 0.29 + 0.4) + 0.3 * sin(along_m * 0.71 + 1.9)


func channel_edge_m(point: Vector2) -> float:
	return absf(_lateral_m(point)) - half_width_m(_along_m(point))


func fill_height_m(point: Vector2) -> float:
	var along := _along_m(point)
	var lateral := _lateral_m(point)
	var reach := half_width_m(along) + FILL_EDGE_M
	return lerpf(_bed_at(along, minf(lateral, -reach)), _bed_at(along, maxf(lateral, reach)), smoothstep(-reach, reach, lateral))


func point_at(along_m: float, lateral_m: float) -> Vector2:
	var offset := lateral_m / cos(atan(_bend_slope(along_m))) + BEND_SHIFT_M * smoothstep(-BEND_LENGTH_M, BEND_LENGTH_M, along_m)
	return downstream * along_m + downstream.orthogonal() * offset


func _bed_at(along_m: float, lateral_m: float) -> float:
	var side := -1.0 if lateral_m < 0.0 else 1.0
	var edge := absf(lateral_m) - half_width_m(along_m) - 0.18 * sin(along_m * 1.3 + side * 2.1) - 0.09 * sin(along_m * 2.9 + side)
	var bank := smoothstep(-0.25, BANK_WIDTH_M, edge) * (1.0 + 0.35 * sin(along_m * 0.37 + side * 1.7))
	var roughness := (0.05 * sin(along_m * 1.7 + lateral_m * 2.3) + 0.04 * sin(along_m * 3.1 - lateral_m * 1.1)) \
		* (1.0 - smoothstep(-0.25, 0.5, edge))
	var sides := maxf(edge - SIDE_START_M, 0.0) * SIDE_GRADE \
		+ smoothstep(4.0, 16.0, edge) * HILL_HEIGHT_M * (1.0 + 0.5 * sin(along_m * 0.13 + side * 2.4))
	return -grade * along_m - DEPTH_M + roughness + bank + sides
