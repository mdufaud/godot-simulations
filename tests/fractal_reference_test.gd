extends "res://tests/test_case.gd"
## The camera-relative form of the 3D distance estimators (FractalReference,
## the CPU mirror of the shader) against the absolute float64 one (FractalDE).

const CASES := 400


func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261110
	var names := ["apollonian", "menger", "kleinian"]
	for fractal_type in 3:
		var reference := FractalReference.new()
		var worst := 0.0
		var off := 0
		for case in CASES:
			var params := {
				fractal_type = fractal_type,
				iterations = rng.randi_range(4, 10),
				detail_iterations = rng.randi_range(0, 6),
				apollonian_scale = rng.randf_range(1.1, 1.9),
				klein_r = rng.randf_range(1.84, 1.96),
				klein_i = rng.randf_range(-0.15, 0.15),
				klein_box_x = rng.randf_range(0.6, 1.2),
				klein_box_z = rng.randf_range(0.6, 1.4),
			}
			var x := rng.randf_range(-1.5, 1.5)
			var y := rng.randf_range(0.1, 1.7)
			var z := rng.randf_range(-1.5, 1.5)
			# Offsets from a ray step next to the camera to one across the scene.
			var reach := pow(10.0, rng.randf_range(-7.0, 0.5))
			var dx := rng.randf_range(-1.0, 1.0) * reach
			var dy := rng.randf_range(-1.0, 1.0) * reach
			var dz := rng.randf_range(-1.0, 1.0) * reach
			reference.update(x, y, z, params)
			var relative := reference.relative_distance(dx, dy, dz, params)
			var absolute := FractalDE.evaluate_at(x + dx, y + dy, z + dz, params)
			var error := absf(relative - absolute) / maxf(absf(absolute), 1e-9)
			worst = maxf(worst, error)
			if error > 1e-5:
				off += 1
		print("REFERENCE %s worst relative error %.3f%%, %d / %d cases off" % [
			names[fractal_type], worst * 100.0, off, CASES])
		# A point rounding onto the other side of a fold lands on another branch.
		_check(off <= CASES / 100, "%s: %d cases disagree with the absolute estimator" % [
			names[fractal_type], off])

	# The camera itself: a zero offset is the estimator at the camera.
	var check := FractalReference.new()
	for fractal_type in 3:
		var params := {fractal_type = fractal_type, iterations = 12, detail_iterations = 20}
		check.update(0.31, 0.77, -0.42, params)
		var at_camera := FractalDE.evaluate_at(0.31, 0.77, -0.42, params)
		_check(absf(check.relative_distance(0.0, 0.0, 0.0, params) - at_camera)
			<= 1e-6 * maxf(absf(at_camera), 1e-12),
			"%s: zero offset is the camera's own distance" % names[fractal_type])

	# A camera 1e-7 from a wall: the rows must still resolve offsets below that.
	for fractal_type in 3:
		var params := {fractal_type = fractal_type, iterations = 8, detail_iterations = 18}
		var dir := Vector3(0.36, -0.48, -0.8)
		var along := 0.0
		for i in 4000:
			var step := FractalDE.evaluate_at(0.31 + dir.x * along, 0.77 + dir.y * along,
				-0.42 + dir.z * along, params)
			if step < 1e-13:
				break
			along += step * 0.9
		along -= 1e-7
		var x := 0.31 + dir.x * along
		var y := 0.77 + dir.y * along
		var z := -0.42 + dir.z * along
		check.update(x, y, z, params)
		var worst := 0.0
		for i in 200:
			var dx := rng.randf_range(-1.0, 1.0) * 5e-8
			var dy := rng.randf_range(-1.0, 1.0) * 5e-8
			var dz := rng.randf_range(-1.0, 1.0) * 5e-8
			worst = maxf(worst, absf(check.relative_distance(dx, dy, dz, params)
				- FractalDE.evaluate_at(x + dx, y + dy, z + dz, params)))
		print("REFERENCE %s near-wall worst error %.3f%% of the 1e-7 view" % [
			names[fractal_type], worst / 1e-7 * 100.0])
		_check(worst <= 2e-9, "%s: offsets next to a wall drift from the estimator" % names[
			fractal_type])
	_finish("fractal_reference")
