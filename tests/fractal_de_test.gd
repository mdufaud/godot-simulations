extends "res://tests/test_case.gd"

const FractalDEScript := preload("res://scripts/fractal_3d/fractal_de.gd")


func _initialize() -> void:
	_test_fractal_types_are_finite()
	_test_iterations_and_parameters_change_distance()
	_finish("fractal_de")


func _test_fractal_types_are_finite() -> void:
	var points := [Vector3(0.2, -0.35, 0.7), Vector3(-1.1, 0.4, 0.15)]
	for fractal_type in 3:
		for point: Vector3 in points:
			var value: float = FractalDEScript.evaluate(point, {
				fractal_type = fractal_type,
				iterations = 12,
			})
			_check(is_finite(value), "fractal type %d returned a non-finite distance" % fractal_type)

	var menger_center: float = FractalDEScript.evaluate(Vector3.ZERO, {
		fractal_type = 1,
		iterations = 1,
	})
	_check(is_equal_approx(menger_center, 1.0 / 3.0), "Menger first iteration distance")


func _test_iterations_and_parameters_change_distance() -> void:
	var point := Vector3(0.37, -0.21, 0.46)
	var apollonian_low: float = FractalDEScript.evaluate(point, {
		fractal_type = 0,
		iterations = 4,
		apollonian_scale = 1.1,
	})
	var apollonian_high: float = FractalDEScript.evaluate(point, {
		fractal_type = 0,
		iterations = 12,
		apollonian_scale = 1.7,
	})
	_check(absf(apollonian_low - apollonian_high) > 1e-6,
		"Apollonian iterations and scale affect distance")

	var klein_default: float = FractalDEScript.evaluate(point, {
		fractal_type = 2,
		iterations = 16,
	})
	var klein_variant: float = FractalDEScript.evaluate(point, {
		fractal_type = 2,
		iterations = 16,
		klein_r = 1.84,
		klein_i = 0.18,
		klein_box_x = 0.55,
		klein_box_z = 1.45,
	})
	_check(absf(klein_default - klein_variant) > 1e-6,
		"Kleinian parameters affect distance")
