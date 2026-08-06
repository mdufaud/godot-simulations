extends "res://tests/test_case.gd"

const ClothWindScript := preload("res://scripts/cloth/cloth_wind.gd")


func _initialize() -> void:
	_test_zero_speed()
	_test_fixed_direction()
	_test_wander_and_gust_limits()
	_finish("cloth_wind")


func _test_zero_speed() -> void:
	var wind := ClothWind.new()
	wind.speed = 0.0
	_check(wind.vector(3.0) == Vector3.ZERO, "zero speed produces no wind")


func _test_fixed_direction() -> void:
	var wind := ClothWind.new()
	wind.speed = 10.0
	wind.gustiness = 0.0
	wind.wander = false
	wind.direction_rad = 0.0
	_check(wind.vector(7.0).is_equal_approx(Vector3(10.0, 0.0, 0.0)),
		"fixed direction points along +x")
	wind.direction_rad = PI * 0.5
	_check(wind.vector(7.0).is_equal_approx(Vector3(0.0, 0.0, 10.0)),
		"fixed direction points along +z")


func _test_wander_and_gust_limits() -> void:
	var wind := ClothWind.new()
	wind.speed = 12.0
	wind.gustiness = 0.8
	wind.wander = true
	var first: Vector3 = wind.vector(0.0)
	var later: Vector3 = wind.vector(11.0)
	_check(first.length() <= wind.speed * (1.0 + wind.gustiness) + 1e-5,
		"gust envelope stays within its bound")
	_check(later.length() <= wind.speed * (1.0 + wind.gustiness) + 1e-5,
		"wander envelope stays within its bound")
	_check(first.distance_to(later) > 1e-4, "wander changes the wind vector")
