extends "res://tests/test_case.gd"
## GPU parity of the Mixwell reverse-drift functions: one sample of each pattern
## preset rendered by the compute shaders, against the CPU twin
## (MixwellDiagnostics.cpu_advect, 64-bit) at a grid of pixels. The shaders run
## in 32-bit floats: a pixel may differ by TOLERANCE_PX, plus twice what the CPU
## map itself moves when its input moves by 1e-6 -- on a crease, where strokes
## cross, that is several pixels, and 32-bit rounding lands anywhere in it.

const Gallery := preload("res://scripts/mixwell/mixwell_gallery.gd")
const Diagnostics := preload("res://scripts/mixwell/mixwell_diagnostics.gd")
const Periodicity := preload("res://scripts/mixwell/mixwell_periodicity.gd")

const SIZE := Vector2i(320, 180)
const GRID := Vector2i(20, 12)
## Displacement error allowed, in pixels.
const TOLERANCE_PX := 0.02
## Input nudge (canvas units, ~float32 rounding of the coordinates) whose effect
## on the CPU map measures how sensitive a pixel is.
const NUDGE := 1.0e-6
const PRESETS := [
	Gallery.SINGLE_LINE, Gallery.FINITE_SEGMENT, Gallery.NONPAREIL, Gallery.NONPAREIL_NOISY,
	Gallery.GEL_GIT, Gallery.FEATHER, Gallery.BIRD_WING, Gallery.PEACOCK, Gallery.SUPER_TORNADO,
	Gallery.CIRCLE_GRID, Gallery.SINE_CURVE,
]

var _readback: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var config := MixwellConfig.new()
	config.brush_radius_px = 9.0
	var solver := MixwellSolver.new()
	solver.initialize(SIZE, config, SIZE)
	solver.set_preset(Gallery.SINGLE_LINE)
	RenderingServer.call_on_render_thread(solver.init_render.bind(solver.create_render_snapshot()))
	await RenderingServer.frame_post_draw
	_check(solver.is_initialized(), "Mixwell solver initialised its compute stages")
	if not solver.is_initialized():
		_finish("mixwell_parity")
		return
	for preset in PRESETS:
		await _check_preset(solver, config, preset)
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
	_finish("mixwell_parity")


func _check_preset(solver: MixwellSolver, config: MixwellConfig, preset: int) -> void:
	solver.set_preset(preset)
	var snapshot = solver.create_render_snapshot()
	_readback.clear()
	RenderingServer.call_on_render_thread(func() -> void:
		solver.reset_accumulation()
		solver.render_sample(0, snapshot)
		_readback.append(solver.readback_displacement()))
	while _readback.is_empty():
		await process_frame
	var values: PackedFloat32Array = _readback[0]
	var operations: Array[Dictionary] = snapshot.operations
	var jitter := Periodicity.r2_sample(0)
	var aspect := float(SIZE.x) / float(SIZE.y)
	var pixel_size := 2.0 / float(SIZE.y)
	var worst := 0.0
	var errors: Array[float] = []
	var worst_at := Vector2i.ZERO
	var unexplained := 0
	for gy in GRID.y:
		for gx in GRID.x:
			var pixel := Vector2i((gx * SIZE.x) / GRID.x + 3, (gy * SIZE.y) / GRID.y + 2)
			var coordinate := (Vector2(pixel) + jitter) / Vector2(SIZE) * 2.0 \
					* Vector2(aspect, 1.0) - Vector2(aspect, 1.0)
			var expected := _advect(coordinate, operations, config) - coordinate
			var offset := (pixel.y * SIZE.x + pixel.x) * 2
			var actual := Vector2(values[offset], values[offset + 1])
			var error := actual.distance_to(expected) / pixel_size
			errors.append(error)
			if error > TOLERANCE_PX:
				var sensitivity := 0.0
				for nudge in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0), Vector2(0.0, NUDGE),
						Vector2(0.0, -NUDGE)]:
					var moved: Vector2 = _advect(coordinate + nudge, operations, config) - coordinate - nudge
					sensitivity = maxf(sensitivity, moved.distance_to(expected) / pixel_size)
				if error > TOLERANCE_PX + 2.0 * sensitivity:
					unexplained += 1
					print("MIXWELL PARITY %s pixel %s error %.4f px, CPU sensitivity %.4f px"
							% [Gallery.preset_name(preset), str(pixel), error, sensitivity])
			if error > worst:
				worst = error
				worst_at = pixel
	errors.sort()
	print("MIXWELL PARITY %-18s max_error=%.5f px at %s median=%.5f p95=%.5f p99=%.5f" % [
		Gallery.preset_name(preset), worst, str(worst_at), errors[errors.size() / 2],
		errors[int(errors.size() * 0.95)], errors[int(errors.size() * 0.99)]])
	_check(unexplained == 0 and errors[errors.size() / 2] <= 0.1 * TOLERANCE_PX,
			"%s: GPU and CPU reverse drift differ beyond float precision (%d pixels)"
			% [Gallery.preset_name(preset), unexplained])


func _advect(coordinate: Vector2, operations: Array[Dictionary], config: MixwellConfig) -> Vector2:
	return Diagnostics.cpu_advect(coordinate, operations, false,
			Vector2(2.0 * float(SIZE.x) / float(SIZE.y), 2.0), config.brush_radius_px, SIZE, -1,
			config.affine_radius_px, config.affine_strength, config.cutoff_gamma,
			config.drift_compensation, config.midpoint_alpha)
