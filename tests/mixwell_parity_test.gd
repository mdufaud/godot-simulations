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
## A single GPU pass errs by up to ~1.5e-5 canvas units in slip mode (images are
## evaluated up to 5 units out); composites are judged at that input precision.
const SLIP_NUDGE := 1.5e-5
const PRESETS := [
	Gallery.SINGLE_LINE, Gallery.FINITE_SEGMENT, Gallery.NONPAREIL, Gallery.NONPAREIL_NOISY,
	Gallery.GEL_GIT, Gallery.FEATHER, Gallery.BIRD_WING, Gallery.PEACOCK, Gallery.SUPER_TORNADO,
	Gallery.CIRCLE_GRID, Gallery.SINE_CURVE,
]

var _readback: Array = []
var _slip := false


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
	# Slip walls (method of images): the pattern passes against the CPU twin's
	# images, and a stroke driven into a wall moves no fluid across it.
	# Each pass alone must match tightly; composed, the waves' images stretch
	# the whole field, so the composites are held to the CPU map's conditioning
	# at the GPU's single-pass precision (SLIP_NUDGE).
	solver.set_boundary_mode(MixwellConfig.BoundaryMode.SLIP_WALLS)
	var passes := {
		"horizontal comb": Gallery._comb(Vector2.ZERO, Vector2.RIGHT, 0.17777778, 0.0),
		"vertical comb": Gallery._comb(Vector2.ZERO, Vector2.UP, 0.13333333, 0.0),
		"Gel-Git pass": Gallery._gel_git(Vector2(0.0, -0.42), Vector2.RIGHT),
		"TriWave": Gallery._tri_wave(Vector2(-0.82, 0.0), Vector2(0.82, 0.0), 0.10, 0.13333333,
				false),
		"broken TriWave": Gallery._tri_wave(Vector2(0.82, 0.0), Vector2(-0.82, 0.0), -0.10,
				0.13333333, true),
	}
	for name in passes:
		solver.set_preset(Gallery.SINGLE_LINE)
		solver._pattern.set_operations([passes[name]])
		solver.mark_snapshot_dirty()
		await _check_snapshot(solver, config, name, true, true)
	for preset in [Gallery.FEATHER, Gallery.BIRD_WING]:
		await _check_preset(solver, config, preset, true)
	await _check_wall_stroke(solver)
	RenderingServer.call_on_render_thread(solver.free_render)
	await RenderingServer.frame_post_draw
	_finish("mixwell_parity")


func _render_displacement(solver: MixwellSolver) -> PackedFloat32Array:
	var snapshot = solver.create_render_snapshot()
	_readback.clear()
	RenderingServer.call_on_render_thread(func() -> void:
		solver.reset_accumulation()
		solver.render_sample(0, snapshot)
		_readback.append(solver.readback_displacement()))
	while _readback.is_empty():
		await process_frame
	return _readback[0]


func _check_preset(solver: MixwellSolver, config: MixwellConfig, preset: int,
		slip := false) -> void:
	solver.set_preset(preset)
	await _check_snapshot(solver, config, Gallery.preset_name(preset), slip, not slip)


func _check_snapshot(solver: MixwellSolver, config: MixwellConfig, label: String, slip: bool,
		strict: bool) -> void:
	_slip = slip
	var snapshot = solver.create_render_snapshot()
	var values := await _render_displacement(solver)
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
				var size := NUDGE if strict else SLIP_NUDGE
				for nudge in [Vector2(size, 0.0), Vector2(-size, 0.0), Vector2(0.0, size),
						Vector2(0.0, -size)]:
					var moved: Vector2 = _advect(coordinate + nudge, operations, config) - coordinate - nudge
					sensitivity = maxf(sensitivity, moved.distance_to(expected) / pixel_size)
				if error > TOLERANCE_PX + 2.0 * sensitivity:
					unexplained += 1
					print("MIXWELL PARITY %s pixel %s error %.4f px, CPU sensitivity %.4f px"
							% [label, str(pixel), error, sensitivity])
			if error > worst:
				worst = error
				worst_at = pixel
	errors.sort()
	print("MIXWELL PARITY %-18s%s max_error=%.5f px at %s median=%.5f p95=%.5f p99=%.5f" % [
		label, " (slip)" if slip else "", worst, str(worst_at),
		errors[errors.size() / 2],
		errors[int(errors.size() * 0.95)], errors[int(errors.size() * 0.99)]])
	_check(unexplained == 0 and (not strict or errors[errors.size() / 2] <= 0.1 * TOLERANCE_PX),
			"%s: GPU and CPU reverse drift differ beyond float precision (%d pixels)"
			% [label, unexplained])


func _advect(coordinate: Vector2, operations: Array[Dictionary], config: MixwellConfig) -> Vector2:
	var aspect := float(SIZE.x) / float(SIZE.y)
	return Diagnostics.cpu_advect(coordinate, operations, false,
			Vector2(2.0 * aspect, 2.0), config.brush_radius_px, SIZE, -1,
			config.affine_radius_px, config.affine_strength, config.cutoff_gamma,
			config.drift_compensation, config.midpoint_alpha,
			Vector2(aspect, 1.0) if _slip else Vector2.ZERO)


# A stroke ending just short of the y = +1 wall. Without walls it drags fluid
# out past the wall line; with slip walls its image cancels the flow through
# the wall, so the last pixel row moves along the wall, not across it.
func _check_wall_stroke(solver: MixwellSolver) -> void:
	var stroke := MixwellStroke.new()
	stroke.radius_px = 9.0
	stroke.points_px = PackedVector2Array([Vector2(160.0, 110.0), Vector2(160.0, 172.0)])
	var across := {}
	for mode in [MixwellConfig.BoundaryMode.FULLSCREEN, MixwellConfig.BoundaryMode.SLIP_WALLS]:
		solver.set_boundary_mode(mode)
		solver.set_strokes([], Gallery.FREEHAND_LAB)
		solver.set_strokes([stroke], Gallery.FREEHAND_LAB)
		var values := await _render_displacement(solver)
		var worst := 0.0
		for x in range(140, 181):
			var offset := ((SIZE.y - 1) * SIZE.x + x) * 2
			worst = maxf(worst, absf(values[offset + 1]))
		across[mode] = worst / (2.0 / float(SIZE.y))
	print("MIXWELL WALL stroke drift across the wall row: open %.3f px, slip %.3f px"
			% [across[MixwellConfig.BoundaryMode.FULLSCREEN], across[MixwellConfig.BoundaryMode.SLIP_WALLS]])
	_check(across[MixwellConfig.BoundaryMode.FULLSCREEN] > 1.0
			and across[MixwellConfig.BoundaryMode.SLIP_WALLS]
				< 0.1 * across[MixwellConfig.BoundaryMode.FULLSCREEN],
			"a slip wall stops the stroke's flow across it (%s)" % str(across))
