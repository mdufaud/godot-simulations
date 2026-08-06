extends "res://tests/test_case.gd"
## Unit tests for the fractal core: the float64 camera, the curated points of
## interest and the perturbation reference orbit. No scene, no GPU.


func _initialize() -> void:
	_test_view_mapping()
	_test_iterations()
	_test_zoom_anchor()
	_test_pan()
	_test_reset()
	_test_pois()
	_test_orbit()
	_finish("fractal_math")


func _new_camera() -> FractalCamera:
	var camera := FractalCamera.new()
	camera.viewport_size = Vector2(200.0, 100.0)
	camera.center_x = 0.0
	camera.center_y = 0.0
	camera.log_zoom = 0.0
	camera.target_log_zoom = 0.0
	return camera


func _test_view_mapping() -> void:
	var camera := _new_camera()
	_check(is_equal_approx(camera.zoom(), 1.0), "zoom 1 at log_zoom 0")
	_check(is_equal_approx(camera.view_half(), 1.75), "view half is VIEW_BASE at zoom 1")
	_check(is_equal_approx(camera.aspect(), 2.0), "aspect follows the viewport")
	_check(is_equal_approx(camera.span_x(), 7.0), "span is 2 x half x aspect")
	_check(is_equal_approx(camera.world_x_at(0.5), 0.0), "screen centre maps to the view centre")
	_check(is_equal_approx(camera.world_y_at(0.5), 0.0), "screen middle maps to the view centre")
	_check(is_equal_approx(camera.world_x_at(1.0), 3.5), "right edge is half a span out")
	_check(is_equal_approx(camera.world_y_at(0.0), -1.75), "top edge is half a height up")

	camera.log_zoom = log(4.0)
	_check(is_equal_approx(camera.view_half(), 0.4375), "zooming in shrinks the view height")

	# Deep zoom is the whole point: the centre must stay exact past float32.
	camera.center_x = -0.743643887037151
	camera.log_zoom = log(1.0e10)
	_check(absf(camera.world_x_at(0.5) - -0.743643887037151) < 1.0e-15,
		"the centre survives a 1e10 zoom")


func _test_iterations() -> void:
	var camera := _new_camera()
	_check(camera.iterations_full() == 128, "auto iterations floor at 128")
	camera.log_zoom = FractalCamera.LN10 * 3.0
	_check(camera.iterations_full() == 918,
		"auto iterations at zoom 1e3: %d" % camera.iterations_full())
	camera.log_zoom = FractalCamera.LN10 * 30.0
	_check(camera.iterations_full() == 20000, "auto iterations cap at 20000")
	camera.auto_iterations = false
	camera.manual_iterations = 555
	_check(camera.iterations_full() == 555, "manual iterations win when auto is off")

	camera.fractal_type = 0
	_check(is_equal_approx(camera.max_log_zoom(), log(1.0e13)), "mandelbrot reaches 1e13")
	camera.fractal_type = 1
	_check(is_equal_approx(camera.max_log_zoom(), log(1.0e10)), "julia reaches 1e10")
	camera.fractal_type = 2
	_check(is_equal_approx(camera.max_log_zoom(), log(1.0e4)),
		"the float32 fractals stop at 1e4")


func _test_zoom_anchor() -> void:
	var camera := _new_camera()
	var corner := Vector2(0.0, 0.0)
	var world_x := camera.world_x_at(0.0)
	var world_y := camera.world_y_at(0.0)
	camera.zoom_at(log(2.0), corner, true)
	_check(is_equal_approx(camera.target_log_zoom, log(2.0)), "wheel raises the zoom target")
	_check(is_equal_approx(camera.log_zoom, 0.0), "the zoom itself only moves on update")
	for i in 200:
		camera.update_motion(0.05)
	_check(is_equal_approx(camera.log_zoom, log(2.0)), "the zoom settles on its target")
	_check(absf(camera.world_x_at(0.0) - world_x) < 1.0e-9,
		"the anchored point stays put in x")
	_check(absf(camera.world_y_at(0.0) - world_y) < 1.0e-9,
		"the anchored point stays put in y")

	# Panning mid-ease drops the anchor, otherwise the drag fights the zoom.
	camera.target_log_zoom = log(8.0)
	camera.zoom_at(0.0, corner, true)
	camera.update_motion(0.01)
	camera.pan_by(Vector2(10.0, 0.0))
	var centre_after_pan := camera.center_x
	camera.update_motion(0.05)
	_check(is_equal_approx(camera.center_x, centre_after_pan),
		"panning drops the anchor, so the easing stops dragging the centre back")

	camera.log_zoom = 0.0
	camera.target_log_zoom = 0.0
	camera.zoom_at(-100.0, corner, true)
	_check(camera.target_log_zoom >= camera.min_log_zoom(),
		"zooming out is clamped at the overview")


func _test_pan() -> void:
	var camera := _new_camera()
	camera.pan_by(Vector2(0.0, 100.0))
	_check(is_equal_approx(camera.center_y, -3.5),
		"dragging a full height moves the view by its full height: %f" % camera.center_y)
	_check(is_equal_approx(camera.center_x, 0.0), "a vertical drag leaves x alone")


func _test_reset() -> void:
	var camera := _new_camera()
	camera.fractal_type = 2
	camera.log_zoom = 12.0
	camera.reset_for_type()
	_check(is_equal_approx(camera.center_x, -1.72), "burning ship resets onto its body")
	_check(is_equal_approx(camera.center_y, -0.04), "burning ship reset y")
	_check(is_equal_approx(camera.log_zoom, FractalCamera.overview_log_zoom()),
		"reset backs out to the overview")
	_check(is_equal_approx(camera.target_log_zoom, camera.log_zoom),
		"reset stops any easing in flight")
	camera.fractal_type = 0
	camera.reset_for_type()
	_check(is_equal_approx(camera.center_x, -0.6), "mandelbrot resets onto its body")


func _test_pois() -> void:
	_check(FractalPoi.list_for(0).size() == 5, "five mandelbrot points")
	_check(FractalPoi.list_for(1).size() == 1, "one julia point")
	_check(FractalPoi.list_for(2).size() == 2, "two burning ship points")
	_check(FractalPoi.list_for(3).size() == 2, "two tricorn points")
	var first := FractalPoi.list_for(0)[0]
	_check(absf(first.x - -0.743643887037151) < 1.0e-15, "the seahorse valley point is exact")
	_check(is_equal_approx(first.max_zoom, 1.0e10), "and carries its depth limit")


func _test_orbit() -> void:
	var camera := _new_camera()
	# Deep inside the main cardioid, so the orbit provably never escapes.
	camera.center_x = -0.5
	camera.center_y = 0.0
	camera.log_zoom = log(1.0e4)

	var orbit := FractalOrbit.new()
	_check(orbit.length == 0, "a fresh orbit holds nothing")
	orbit.ensure(camera, 0.0, 0.0, 200)
	_check(orbit.length == 314, "orbit runs 1.25 x iterations + 64: %d" % orbit.length)
	_check(orbit.texture != null, "orbit uploads a texture")
	_check(orbit.texture.get_size() == Vector2(FractalOrbit.TEX_WIDTH, 1),
		"one row is enough for 314 iterations")
	_check(is_equal_approx(orbit.origin_x, camera.center_x), "orbit is anchored on the centre")

	camera.center_x += 1.0e-6
	orbit.ensure(camera, 0.0, 0.0, 200)
	_check(absf(orbit.origin_x - -0.5) < 1.0e-15,
		"a small move reuses the cached orbit")

	camera.center_x = 0.0
	camera.center_y = 0.0
	orbit.ensure(camera, 0.0, 0.0, 200)
	_check(is_equal_approx(orbit.origin_x, 0.0), "leaving the neighbourhood recomputes")

	orbit.ensure(camera, 0.0, 0.0, 4000)
	_check(orbit.length == 5064, "asking for more iterations recomputes: %d" % orbit.length)
	_check(orbit.texture.get_size() == Vector2(FractalOrbit.TEX_WIDTH, 2),
		"5064 iterations spill onto a second row")

	# An escaping centre stops early instead of filling the buffer.
	camera.center_x = 2.0
	camera.center_y = 2.0
	orbit.ensure(camera, 0.0, 0.0, 200)
	_check(orbit.length < 10, "an escaping orbit stops at once: %d" % orbit.length)

	orbit.invalidate()
	_check(orbit.length == 0, "invalidate drops the cache")
