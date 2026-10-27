extends "res://tests/test_case.gd"
## CPU gate for the terrain ball's contact plane: the normal it builds from its
## five height probes must match the slope it is resting on.


func _initialize() -> void:
	_test_normal_matches_slope()
	_finish("surface_ball")


func _test_normal_matches_slope() -> void:
	var ball := SurfaceBall.new(0.22)
	for slope in [Vector2(0.0, 0.0), Vector2(0.5, 0.0), Vector2(0.0, -0.3), Vector2(0.4, 0.25)]:
		var results := PackedVector4Array()
		for offset: Vector2 in SurfaceBall.PROBE_OFFSETS:
			var probe := offset * ball.radius
			results.append(Vector4(slope.x * probe.x + slope.y * probe.y, 0.0, 0.0, 1.0))
		var expected := Vector3(-slope.x, 1.0, -slope.y).normalized()
		var normal: Vector3 = ball._surface_normal(results, 0)
		_check(normal.distance_to(expected) < 1e-5,
			"plane h = %s . xz gave normal %s, expected %s" % [slope, normal, expected])
	ball.free()
