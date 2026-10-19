extends "res://tests/test_case.gd"

const Curtain := preload("res://scripts/river/river_waterfall_curtain.gd")


func _initialize() -> void:
	_check_cliff()
	_check_rotated_cliff()
	_check_ramp()
	_check_fast_rounded_ramp()
	_check_deep_inlet()
	_check_gorge()
	_finish("river_waterfall_curtain")


func _curtain(ground: Callable, from: Vector3, to: Vector3) -> RiverWaterfallCurtain:
	var curtain := Curtain.new()
	curtain.ground = ground
	curtain.crest_from = from
	curtain.crest_to = to
	curtain.surface_height_m = 6.5
	curtain.speed_m_s = 1.0
	curtain.landing_level_m = 0.5
	curtain.columns = 4
	curtain.rows = 64
	return curtain


func _check_cliff() -> void:
	var curtain := _curtain(func(point: Vector2) -> float: return 6.0 if point.y > 0.0 else 0.0,
		Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	var arrays := curtain.build().surface_get_arrays(0)
	_check(curtain.downstream.is_equal_approx(Vector3.FORWARD), "Crest from left to right must flow towards -Z")
	_check(curtain.impact_points.size() == 5, "Every wet cliff column must land in the pool")
	var landed := true
	for point in curtain.impact_points:
		landed = landed and point.z < -1.04 and point.z > -1.16 and absf(point.y - 0.5) < 0.05
	_check(landed, "A 1 m/s jet leaving a 5.5 m drop must land about 1.1 m from the cliff")
	var finite := true
	for vertex: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
		finite = finite and vertex.is_finite()
	_check(finite, "Cliff curtain vertices must be finite")


func _check_rotated_cliff() -> void:
	var curtain := _curtain(func(point: Vector2) -> float: return 6.0 if point.x < 0.0 else 0.0,
		Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0))
	curtain.build()
	var landed := curtain.impact_points.size() == 5
	for point in curtain.impact_points:
		landed = landed and point.x > 1.04 and point.x < 1.16
	_check(curtain.downstream.is_equal_approx(Vector3.RIGHT) and landed,
		"A crest turned a quarter turn must produce the same fall turned a quarter turn")


func _check_ramp() -> void:
	var ramp := func(point: Vector2) -> float: return clampf(6.0 + point.y, 0.0, 6.0)
	var curtain := _curtain(ramp, Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	curtain.landing_level_m = 0.3
	var arrays := curtain.build().surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var traits: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var above := true
	var attached := 0
	var slope_vertices := 0
	var stride := curtain.columns + 3
	for index in vertices.size():
		var point := vertices[index]
		if traits[index * 4 + 3] > 1.5 or traits[index * 4 + 3] < -0.5:
			continue
		above = above and point.y >= ramp.call(Vector2(point.x, point.z)) - 0.001
		if point.z < -1.0 and point.z > -5.0:
			slope_vertices += 1
			attached += 1 if traits[index * 4 + 3] > 0.5 else 0
	_check(above, "Ramp curtain must never dip below the ground")
	_check(slope_vertices > 0 and attached == slope_vertices, "Water must cling to a 45 degree ramp below the lip")
	var entered := curtain.impact_points.size() == 5
	for point in curtain.impact_points:
		entered = entered and point.z < -5.4 and point.z > -5.9
	_check(entered, "Ramp water must enter the pool where the ramp meets the landing level")


func _check_fast_rounded_ramp() -> void:
	var slope := tan(deg_to_rad(50.0))
	var ramp := func(point: Vector2) -> float:
		if point.y >= 0.0:
			return 6.0
		if point.y > -0.35:
			var t := -point.y / 0.35
			return 6.0 - slope * 0.35 * (2.0 * t * t - t * t * t)
		return maxf(6.0 + slope * point.y, 0.0)
	var curtain := _curtain(ramp, Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	curtain.surface_height_m = 6.77
	curtain.speed_m_s = 2.4
	curtain.landing_level_m = 0.12
	var arrays := curtain.build().surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var traits: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var slope_vertices := 0
	var attached := 0
	for index in vertices.size():
		var point := vertices[index]
		if traits[index * 4 + 3] > 1.5 or traits[index * 4 + 3] < -0.5 or point.z > 0.0 or point.y < 0.5:
			continue
		slope_vertices += 1
		attached += 1 if traits[index * 4 + 3] > 0.5 else 0
	_check(slope_vertices > 0 and attached == slope_vertices,
		"A thick fast film must cling to a rounded 50 degree lip instead of jumping over an air pocket")


func _check_deep_inlet() -> void:
	var slope := tan(deg_to_rad(50.0))
	var grounds := [
		func(point: Vector2) -> float: return 6.0 if point.y > 0.0 else 0.0,
		func(point: Vector2) -> float: return 6.0 if point.y >= 0.0 else maxf(6.0 + slope * point.y, 0.0),
	]
	var flush := true
	for ground: Callable in grounds:
		var curtain := _curtain(ground, Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
		curtain.surface_height_m = 7.19
		curtain.speed_m_s = 1.7
		curtain.landing_level_m = 0.54
		var arrays := curtain.build().surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var traits: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
		for index in vertices.size():
			if traits[index * 4 + 3] < -0.5 or vertices[index].z < 0.0:
				continue
			flush = flush and absf(vertices[index].y - curtain.surface_height_m) < 0.02
	_check(flush, "A 1.19 m deep inlet must reach the upstream surface up to the lip, with no step under the pool edge")


func _check_gorge() -> void:
	var gorge := func(point: Vector2) -> float: return (6.0 if point.y > 0.0 else 0.0) + (10.0 if absf(point.x) > 1.05 else 0.0)
	var curtain := _curtain(gorge, Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0))
	var vertices: PackedVector3Array = curtain.build().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var stride := curtain.columns + 3
	var tucked := true
	for row in vertices.size() / stride:
		for slot: int in [row * stride, row * stride + stride - 1]:
			var point := vertices[slot]
			tucked = tucked and gorge.call(Vector2(point.x, point.z)) >= point.y
	_check(tucked, "Curtain edges must sink into the gorge walls along the whole fall")
