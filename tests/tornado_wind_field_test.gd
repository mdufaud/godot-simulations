extends "res://tests/test_case.gd"

const TornadoWindFieldScript := preload("res://scripts/tornado/tornado_wind_field.gd")


func _initialize() -> void:
	_test_bounds_and_centerline()
	_test_grid_matches_analytic_field()
	_test_models_return_finite_wind()
	_finish("tornado_wind_field")


func _new_field() -> TornadoWindField:
	var field := TornadoWindField.new()
	field.u_max = 30.0
	field.r_core0 = 10.0
	field.height = 120.0
	field.flare = 1.0
	field.base_pos = Vector3(4.0, 0.0, -3.0)
	return field


func _test_bounds_and_centerline() -> void:
	var field := _new_field()
	_check(field.centerline_at(0.0).is_equal_approx(field.base_pos), "centerline starts at base")
	_check(field.wind_at(Vector3(0.0, -0.01, 0.0)) == Vector3.ZERO,
		"wind below volume is zero")
	_check(field.wind_at(Vector3(0.0, field.height + 0.01, 0.0)) == Vector3.ZERO,
		"wind above volume is zero")
	_check(field.wind_at(field.base_pos + Vector3(9.0 * field.r_core0, 0.0, 0.0)) == Vector3.ZERO,
		"wind outside influence radius is zero")
	_check(field.wind_at(field.base_pos + Vector3(field.r_core0, 30.0, 0.0)).length() > 0.0,
		"wind inside volume is non-zero")


func _test_grid_matches_analytic_field() -> void:
	var field := _new_field()
	field.bake_wind_grid()
	var radial_index := 10.0
	var vertical_index := 20.0
	var r_bar := TornadoWindField.INFLUENCE_FACTOR * radial_index \
		/ float(TornadoWindField.WIND_GRID_R - 1)
	var y := field.height * vertical_index / float(TornadoWindField.WIND_GRID_Y - 1)
	var sample: Vector3 = field.sample_wind_grid(r_bar, y)
	var point := field.centerline_at(y) + Vector3(field.core_radius_at(y) * r_bar, 0.0, 0.0)
	var analytic: Vector3 = field.wind_at(point)
	var reconstructed := Vector3(sample.x, sample.z, -sample.y)
	_check(reconstructed.distance_to(analytic) < 0.01,
		"wind grid matches analytic field at grid node")


func _test_models_return_finite_wind() -> void:
	var field := _new_field()
	var point := field.base_pos + Vector3(14.0, 45.0, 2.0)
	for model in [TornadoWindField.Model.RANKINE, TornadoWindField.Model.BURGERS_ROTT,
		TornadoWindField.Model.SULLIVAN]:
		field.model = model
		field.bake_wind_grid()
		var value: Vector3 = field.wind_at(point)
		_check(is_finite(value.x) and is_finite(value.y) and is_finite(value.z),
			"wind model returned finite velocity")
