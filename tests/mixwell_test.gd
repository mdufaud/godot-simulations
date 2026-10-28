extends "res://tests/test_case.gd"

const Boundaries := preload("res://scripts/mixwell/mixwell_boundaries.gd")
const Config := preload("res://scripts/mixwell/mixwell_config.gd")
const Diagnostics := preload("res://scripts/mixwell/mixwell_diagnostics.gd")
const Gallery := preload("res://scripts/mixwell/mixwell_gallery.gd")
const Math := preload("res://scripts/mixwell/mixwell_math.gd")
const Pattern := preload("res://scripts/mixwell/mixwell_pattern.gd")
const Periodicity := preload("res://scripts/mixwell/mixwell_periodicity.gd")
const Solver := preload("res://scripts/mixwell/mixwell_solver.gd")
const Stroke := preload("res://scripts/mixwell/mixwell_stroke.gd")

const LINE_FIXTURES := [
	[0.1, -2.389415733948],
	[0.5, -0.885381030247],
	[1.0, -0.393174005061],
	[2.0, -0.112888420865],
	[4.0, -0.020688901885],
	[8.0, -0.002930832135],
]
const SEGMENT_FIXTURES := [
	[Vector2(0.35, 2.0), Vector2(0.092824923317, -0.066636462353)],
	[Vector2(0.0, 0.75), Vector2(-0.079986787063, -0.037436292334)],
	[Vector2(-1.3, 0.4), Vector2(-0.201790384492, 0.150361006574)],
]
const GOLDEN_COORDINATE := Vector2(0.37, -0.21)
const CPU_GOLDENS := [
	[0.359848827124, -0.209999993443],
	[0.372573584318, -0.206582069397],
	[0.370000004768, -0.209999993443],
	[0.202365919948, -0.209999993443],
	[0.282789975405, -0.209999993443],
	[0.364158302546, -0.002806842327],
	[0.343880176544, 0.007083654404],
	[0.210636630654, -0.435729742050],
	[0.313077807426, 0.011130049825],
	[-0.340353220701, 0.255645304918],
	[0.266750782728, -0.607660651207],
	[-0.068243294954, 0.054871618748],
	[0.276869505644, -0.058102622628],
	[0.575342893600, -0.029069144279],
	[0.265820562840, -0.209999993443],
	[0.323050290346, -0.224748045206],
	[0.374386221170, -0.188835710287],
	[0.418397188187, -0.508496403694],
]


func _initialize() -> void:
	_test_math_infinite_drift()
	_test_math_series_against_quadrature()
	_test_math_kernel_divergence()
	_test_math_segment_convergence()
	_test_math_area_preservation()
	_test_math_degenerate_and_singular_inputs()
	_test_math_stroke_spacing()
	_test_math_canvas_coordinate_mapping()
	_test_oracle_line_fixtures()
	_test_oracle_segment_fixtures()
	_test_segment_mask_matches_reference()
	_test_oracle_jacobian_grid_is_finite()
	_test_gallery_names_and_counts()
	_test_reference_patterns()
	_test_gallery_physical_reverse_order()
	_test_gallery_mean_compensation()
	_test_gallery_published_passes()
	_test_gallery_retained_stroke_passes()
	_test_baked_stroke_prefix()
	_test_pattern_round_trip()
	_test_pattern_physical_order()
	_test_pattern_curve_and_transform_expansion()
	_test_pattern_steps()
	_test_pattern_snapshot_carries_pattern()
	_test_affine_preset_keeps_stroke_radius()
	_test_pattern_diagnostics_are_standalone()
	_test_progressivity_r2_sequence()
	_test_progressivity_spp_targets()
	_test_progressivity_fixed_composite_period()
	_test_progressivity_periodic_coordinates()
	_test_periodic_tiling_needs_whole_pixels()
	_test_progressivity_path_comparison()
	_test_progressivity_budget_progression()
	_test_progressivity_render_snapshot()
	_test_affine_extensions()
	_test_slip_images()
	_test_diagnostics_contract()
	_test_controller_contract()
	_test_cpu_preset_matrix()
	_test_stress_and_export_contract()
	_test_zone_metrics_contract()
	_finish("mixwell")


func _test_math_infinite_drift() -> void:
	var value := Math.xi_series(1.0)
	_check(absf(value - -0.393175) <= 3.0e-5,
		"unit-cylinder drift at eta=1 matches Maxwell reference: %f" % value)
	var line := Math.rd_line(Math.point(0.0, 1.0), 1.0, Math.point(1.0, 0.0))
	_check(absf(line[0] - value) <= 1.0e-12, "rdLine drift follows line direction")
	_check(absf(line[1]) <= 1.0e-12, "rdLine preserves transverse coordinate")


func _test_math_series_against_quadrature() -> void:
	for eta in [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 20.0]:
		var series := Math.xi_series(eta)
		var regularized_eta := sqrt(eta * eta + Math.SERIES_DELTA * Math.SERIES_DELTA)
		var quadrature := Math.xi_quadrature(regularized_eta, 4096)
		_check(absf(series - quadrature) <= 3.0e-5,
			"series agrees with independent Maxwell quadrature at eta=%f: %f vs %f" \
			% [eta, series, quadrature])
	for boundary in [Math.SERIES_NEAR, Math.SERIES_FAR]:
		var below := Math.xi_series(boundary * (1.0 - 1.0e-7))
		var above := Math.xi_series(boundary * (1.0 + 1.0e-7))
		_check(absf(below - above) <= 2.0e-5,
			"matched asymptotic series is C0 at %f: %f" % [boundary, below - above])


func _test_math_kernel_divergence() -> void:
	var basis_x := Math.point(1.0, 0.0)
	for value in [Math.point(0.3, 0.4), Math.point(1.5, -0.7),
			Math.point(3.0, 2.2), Math.point(0.05, 0.7)]:
		var h := 1.0e-5
		var x_plus := Math.point(value[0] + h, value[1])
		var x_minus := Math.point(value[0] - h, value[1])
		var y_plus := Math.point(value[0], value[1] + h)
		var y_minus := Math.point(value[0], value[1] - h)
		var du_x_dx := (Math.body_kernel_mul(x_plus, basis_x, 1.0)[0] \
				- Math.body_kernel_mul(x_minus, basis_x, 1.0)[0]) / (2.0 * h)
		var du_y_dy := (Math.body_kernel_mul(y_plus, basis_x, 1.0)[1] \
				- Math.body_kernel_mul(y_minus, basis_x, 1.0)[1]) / (2.0 * h)
		_check(absf(du_x_dx + du_y_dy) <= 5.0e-5,
			"Mixwell velocity is divergence-free at (%f,%f)" % [value[0], value[1]])


func _test_math_segment_convergence() -> void:
	var particle := Math.point(0.35, 2.0)
	var start := Math.point(-0.8, -0.15)
	var end := Math.point(0.9, 0.2)
	var reference := Math.rd_segment_reference(particle, 1.0, start, end, 0.0002)
	var coarse := Math.rd_segment(particle, 1.0, start, end, 0.1)
	var fine := Math.rd_segment(particle, 1.0, start, end, 0.05)
	var coarse_error := _point_distance(coarse, reference)
	var fine_error := _point_distance(fine, reference)
	_check(coarse_error <= 5.0e-3, "alpha=0.1 segment error stays bounded: %f" % coarse_error)
	_check(fine_error < coarse_error * 0.35,
		"midpoint segment convergence is second order: %f -> %f" % [coarse_error, fine_error])
	_check(_point_is_finite(coarse) and _point_is_finite(fine) and _point_is_finite(reference),
		"segment reference and approximations remain finite")


func _test_math_area_preservation() -> void:
	var centre := Math.point(0.4, 0.7)
	var start := Math.point(-0.8, -0.15)
	var end := Math.point(0.9, 0.2)
	var h := 1.0e-3
	var map_x_plus := _segment_map(Math.point(centre[0] + h, centre[1]), start, end)
	var map_x_minus := _segment_map(Math.point(centre[0] - h, centre[1]), start, end)
	var map_y_plus := _segment_map(Math.point(centre[0], centre[1] + h), start, end)
	var map_y_minus := _segment_map(Math.point(centre[0], centre[1] - h), start, end)
	var dxx := (map_x_plus[0] - map_x_minus[0]) / (2.0 * h)
	var dxy := (map_y_plus[0] - map_y_minus[0]) / (2.0 * h)
	var dyx := (map_x_plus[1] - map_x_minus[1]) / (2.0 * h)
	var dyy := (map_y_plus[1] - map_y_minus[1]) / (2.0 * h)
	var determinant := dxx * dyy - dxy * dyx
	_check(absf(determinant - 1.0) <= 0.01,
		"finite-stroke map preserves area within 1%%: det=%f" % determinant)


func _test_math_degenerate_and_singular_inputs() -> void:
	var origin := Math.point(0.0, 0.0)
	var zero_segment := Math.rd_segment(Math.point(1.0, 2.0), 1.0, origin, origin)
	_check(_point_distance(zero_segment, Math.zero_point()) <= 1.0e-15,
		"zero-length segment has zero drift")
	var centre_kernel := Math.kernel_mul(origin, Math.point(3.0, -2.0), 1.0)
	_check(_point_distance(centre_kernel, Math.point(3.0, -2.0)) <= 1.0e-15,
		"kernel limit at the origin is identity")
	var near_line := Math.rd_line(origin, 1.0, Math.point(1.0, 0.0))
	_check(_point_is_finite(near_line), "regularized line drift has no NaN at the tine")
	_check(Math.rd_segment(origin, 1.0, Math.point(-1.0, 0.0), Math.point(1.0, 0.0), 0.1).size() == 2,
		"segment through the tine returns a displacement")


func _test_math_stroke_spacing() -> void:
	var stroke := Stroke.new()
	stroke.radius_px = 8.0
	stroke.append_drag_point(Vector2.ZERO, 2.0)
	stroke.append_drag_point(Vector2(10.0, 0.0), 2.0)
	_check(stroke.points_px.size() == 6, "drag polyline is split every 0.25 epsilon")
	for index in range(stroke.points_px.size() - 1):
		_check(absf(stroke.points_px[index + 1].distance_to(stroke.points_px[index]) - 2.0) <= 1.0e-5,
			"split points keep deterministic spacing")
	stroke.append_drag_point(Vector2(10.5, 0.0), 2.0, -1, true)
	_check(stroke.points_px[-1] == Vector2(10.5, 0.0), "stroke flush keeps release endpoint")


func _test_math_canvas_coordinate_mapping() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(200, 100), Config.new(), Vector2i(200, 100))
	var stroke := Stroke.new()
	stroke.points_px = PackedVector2Array([Vector2(50.0, 20.0), Vector2(150.0, 30.0)])
	solver.set_strokes([stroke])
	var segment: Vector4 = solver.get_segments()[0]
	_check(segment.y < 0.0 and segment.w < 0.0,
		"top-half canvas strokes map to shader top-half coordinates")
	# The canvas spans 2 units over its height in either orientation: on a
	# portrait canvas a 10 px stroke is 0.1 units, as the display draws it.
	var portrait := Solver.new()
	portrait.initialize(Vector2i(100, 200), Config.new(), Vector2i(100, 200))
	var flick := Stroke.new()
	flick.points_px = PackedVector2Array([Vector2(50.0, 100.0), Vector2(60.0, 100.0)])
	portrait.set_strokes([flick])
	var span: Vector4 = portrait.get_segments().back()
	_check(is_equal_approx(span.z, 0.1) and is_equal_approx(portrait.get_segments()[0].x, 0.0),
		"portrait strokes are normalised by the canvas height (%s)" % str(span))


func _test_oracle_line_fixtures() -> void:
	for fixture in LINE_FIXTURES:
		var value := Math.xi_series(fixture[0])
		_check(absf(value - fixture[1]) <= 3.0e-5,
			"rdLine matches independent float64 fixture at eta=%f: %.9f" % [fixture[0], value])


func _test_oracle_segment_fixtures() -> void:
	var start := Math.point(-0.8, -0.15)
	var end := Math.point(0.9, 0.2)
	for fixture in SEGMENT_FIXTURES:
		var point_value: Vector2 = fixture[0]
		var expected: Vector2 = fixture[1]
		var actual := Math.rd_segment(Math.point(point_value.x, point_value.y), 1.0,
			start, end, 0.05)
		var error := Vector2(actual[0], actual[1]).distance_to(expected)
		_check(error <= 5.0e-4,
			"rdSegment matches independent float64 fixture at (%f,%f): %.9f" \
			% [point_value.x, point_value.y, error])


# Mixwell.glsl rdSegment: mask = 1 - smoothstep(0.5 dMax, dMax, d), dMax = 10 r.
# The full drift reaches 5 epsilon from the stroke; nothing reaches 10 epsilon.
func _test_segment_mask_matches_reference() -> void:
	var epsilon := 0.05
	var segment := Vector4(-0.3, 0.0, 0.3, 0.0)
	for case in [[0.0, 1.0], [4.99, 1.0], [7.5, 0.5], [10.0, 0.0], [12.0, 0.0]]:
		var point := Vector2(0.1, case[0] * epsilon)
		_check(absf(Diagnostics.segment_mask(point, segment, epsilon, 10.0) - case[1]) <= 1.0e-6,
				"segment mask at %s epsilon is %s" % [str(case[0]), str(case[1])])
	var beyond: Array[Dictionary] = [{"type": Gallery.SEGMENT, "segment": segment}]
	var far := Vector2(0.1, 10.5 * epsilon)
	_check(Diagnostics.cpu_advect(far, beyond, false, Vector2(2.0, 2.0), 0.05 * 180.0,
			Vector2i(640, 360), -1, 180.0, 0.65, 10.0, 0, 0.1) == far,
			"a segment moves nothing beyond its cutoff")


func _test_oracle_jacobian_grid_is_finite() -> void:
	var start := Math.point(-0.8, -0.15)
	var end := Math.point(0.9, 0.2)
	var area_errors: Array[float] = []
	var h := 1.0e-3
	for row in range(-4, 5):
		for column in range(-6, 7):
			var centre := Math.point(float(column) * 0.22, float(row) * 0.22 + 0.13)
			var map_x_plus := _oracle_segment_map(Math.point(centre[0] + h, centre[1]), start, end)
			var map_x_minus := _oracle_segment_map(Math.point(centre[0] - h, centre[1]), start, end)
			var map_y_plus := _oracle_segment_map(Math.point(centre[0], centre[1] + h), start, end)
			var map_y_minus := _oracle_segment_map(Math.point(centre[0], centre[1] - h), start, end)
			var dxx := (map_x_plus[0] - map_x_minus[0]) / (2.0 * h)
			var dxy := (map_y_plus[0] - map_y_minus[0]) / (2.0 * h)
			var dyx := (map_x_plus[1] - map_x_minus[1]) / (2.0 * h)
			var dyy := (map_y_plus[1] - map_y_minus[1]) / (2.0 * h)
			var determinant := dxx * dyy - dxy * dyx
			_check(is_finite(determinant), "Jacobian grid contains NaN or Inf")
			area_errors.append(absf(determinant - 1.0))
	area_errors.sort()
	var p99 := area_errors[int(ceil(float(area_errors.size()) * 0.99)) - 1]
	_check(p99 >= 0.0 and is_finite(p99), "Jacobian grid reports finite p99")


func _test_gallery_names_and_counts() -> void:
	var names := Gallery.preset_names()
	_check(names == ["Single Line", "Finite Segment", "Freehand Lab", "Nonpareil",
			"Gel-Git", "Feather", "BirdWing", "Peacock", "FrogFoot"],
			"gallery exposes canonical preset names")
	_check(Gallery.preset_segments(Gallery.SINGLE_LINE).is_empty(),
			"single line uses analytic rdLine")
	_check(Gallery.preset_segments(Gallery.FINITE_SEGMENT).size() == 1,
			"finite segment has one segment")
	_check(Gallery.preset_segments(Gallery.FREEHAND_LAB).is_empty(),
			"freehand lab starts without preset segments")
	var nonpareil: Array[Dictionary] = Gallery.preset_pattern(Gallery.NONPAREIL).render_operations()
	_check(nonpareil.size() == 1 and nonpareil[0].type == Gallery.LINE_COMB,
		"Nonpareil is one rdNonpareil comb pass")
	var gel_git: Array[Dictionary] = Gallery.preset_pattern(Gallery.GEL_GIT).render_operations()
	_check(gel_git.size() == 1 and gel_git[0].type == Gallery.GEL_GIT_PASS,
		"Gel-Git is one pass of two superposed opposed combs")


# The reference pattern functions (Mixwell.glsl), checked on what defines them
# rather than on a second copy of their code.
func _test_reference_patterns() -> void:
	var epsilon := 0.05
	# Nonpareil: the windowed comb matches the infinite sum of its line drifts.
	for y in [0.0, 0.037, 0.09]:
		var windowed := Math.rd_nonpareil(Vector2(0.3, y), epsilon, Vector2.RIGHT, 0.18, 0.0, 10.0)
		var full := 0.0
		for k in range(-400, 401):
			full += Math.rd_line_height(absf(y - 0.18 * float(k)), epsilon)
		_check(absf(windowed.x - full) <= 1.0e-4 and windowed.y == 0.0,
				"Nonpareil window matches the full comb at y=%s (%s vs %s)" % [str(y), str(windowed.x), str(full)])
	# Gel-Git: tines every gap, alternately moving along and against direction,
	# so the drift at a Gel tine is the opposite of the drift at a Git tine, and
	# the field repeats every two gaps.
	var gap := 0.11851852
	var gel := Math.rd_gel_git(Vector2(0.1, 0.0), epsilon, Vector2.RIGHT, gap)
	var git := Math.rd_gel_git(Vector2(0.1, gap), epsilon, Vector2.RIGHT, gap)
	_check(gel.x < 0.0 and absf(gel.x + git.x) <= 1.0e-9,
			"Gel and Git tines drift oppositely (%s, %s)" % [str(gel.x), str(git.x)])
	# (Vector2 holds 32-bit floats, so the shifted point is off by ~1e-8.)
	_check(Math.rd_gel_git(Vector2(0.1, 0.03 + 2.0 * gap), epsilon, Vector2.RIGHT, gap).distance_to(
			Math.rd_gel_git(Vector2(0.1, 0.03), epsilon, Vector2.RIGHT, gap)) <= 1.0e-6,
			"Gel-Git repeats every two gaps")
	# TriWave: periodic along its line, zero beyond the mask reach, and a wave
	# moving forward drags the fluid along its path forward (reverse drift points
	# back). A few epsilon out the windowed sum leaves the dipole far field's
	# reflux uncancelled -- the reference's own truncation -- so the transport is
	# measured on the path.
	var wavelength := 0.26666667
	var amplitude := 0.1
	var here := Vector2(0.071, 0.043)
	var wave := Math.rd_tri_wave(here, epsilon, Vector2.RIGHT, wavelength, amplitude, false, 10.0, 0.1)
	var shifted := Math.rd_tri_wave(here + Vector2(wavelength, 0.0), epsilon, Vector2.RIGHT,
			wavelength, amplitude, false, 10.0, 0.1)
	_check(wave.distance_to(shifted) <= 1.0e-6, "TriWave repeats every wavelength")
	_check(Math.rd_tri_wave(Vector2(0.0, amplitude + 10.0 * epsilon + 0.01), epsilon,
			Vector2.RIGHT, wavelength, amplitude, false, 10.0, 0.1) == Vector2.ZERO,
			"TriWave moves nothing beyond its mask reach")
	var mean := Vector2.ZERO
	for index in 32:
		mean += Math.rd_tri_wave(Vector2(float(index) / 32.0 * wavelength, 0.05), epsilon,
				Vector2.RIGHT, wavelength, amplitude, false, 10.0, 0.1) / 32.0
	_check(mean.x < 0.0, "a forward TriWave transports the fluid forward (%s)" % str(mean))
	# Broken: the same segments in the opposite order, so the field differs but
	# the transport across the wave does not reverse.
	var broken_mean := Vector2.ZERO
	for index in 32:
		broken_mean += Math.rd_tri_wave(Vector2(float(index) / 32.0 * wavelength, 0.05), epsilon,
				Vector2.RIGHT, wavelength, amplitude, true, 10.0, 0.1) / 32.0
	var broken := Math.rd_tri_wave(here, epsilon, Vector2.RIGHT, wavelength, amplitude, true,
			10.0, 0.1)
	_check(broken.distance_to(wave) > 1.0e-4 and broken_mean.x < 0.0,
			"a broken TriWave reorders its strokes (%s vs %s)" % [str(broken), str(wave)])


func _test_gallery_physical_reverse_order() -> void:
	var solver := Solver.new()
	var config := Config.new()
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	solver.set_preset(Gallery.CIRCLE_GRID)
	var logical := solver.get_segments()
	var physical := solver.get_segments_physical_order()
	_check(logical.size() == physical.size() and logical.size() > 1,
			"preset exposes logical and physical segment lists")
	for index in logical.size():
		_check(physical[index] == logical[logical.size() - 1 - index],
				"RDF composition dispatches segments in physical inverse order")


# A comb's reverse drift averages -pi epsilon^2 / pitch along its direction;
# compensation must cancel that transport, not double it. Measured on the comb
# itself: Mean leaves no average drift over a pitch, Minimum none between tines.
func _test_gallery_mean_compensation() -> void:
	var epsilon := 0.25
	var expected := PI * epsilon * epsilon / 2.0
	_check(absf(Gallery.compensation_value(2, epsilon, 2.0) - expected) <= 1.0e-12,
			"mean drift compensation is +pi epsilon^2/pitch")
	_check(Gallery.compensation_vector(2, epsilon, 2.0, Vector2.RIGHT).distance_to(
			Vector2(expected, 0.0)) <= 1.0e-6, "mean compensation follows tine direction")
	var comb: Array[Dictionary] = [Gallery._comb(Vector2.ZERO, Vector2.RIGHT, 0.2, 0.0)]
	for mode in [Config.DriftCompensation.MEAN, Config.DriftCompensation.MINIMUM]:
		var mean := 0.0
		for index in 400:
			var point := Vector2(0.0, (float(index) + 0.5) / 400.0 * 0.2)
			mean += (Diagnostics.cpu_advect(point, comb, false, Vector2(2.0, 2.0), 9.0,
					Vector2i(640, 360), -1, 180.0, 0.65, 10.0, mode, 0.1).x - point.x) / 400.0
		var between := Diagnostics.cpu_advect(Vector2(0.0, 0.1), comb, false, Vector2(2.0, 2.0),
				9.0, Vector2i(640, 360), -1, 180.0, 0.65, 10.0, mode, 0.1).x
		var cancelled := absf(mean) if mode == Config.DriftCompensation.MEAN else absf(between)
		print("MIXWELL COMPENSATION mode=%d mean=%.6f between_tines=%.6f" % [mode, mean, between])
		_check(cancelled <= 2.0e-4, "compensation mode %d cancels the comb's transport" % mode)


func _test_gallery_published_passes() -> void:
	var feather: Array[Dictionary] = Gallery.preset_pattern(Gallery.FEATHER).render_operations()
	var bird_wing: Array[Dictionary] = Gallery.preset_pattern(Gallery.BIRD_WING).render_operations()
	var peacock: Array[Dictionary] = Gallery.preset_pattern(Gallery.PEACOCK).render_operations()
	var frog_foot: Array[Dictionary] = Gallery.preset_pattern(Gallery.FROG_FOOT).render_operations()
	_check(feather.size() == 3 and bird_wing.size() == 4
			and int(feather[0].type) == Gallery.TRI_WAVE and int(feather[2].type) == Gallery.GEL_GIT_PASS,
		"Feather is Gel-Git, a comb and a TriWave, rendered last pass first")
	_check(peacock.size() == frog_foot.size() and peacock.size() == 4,
		"Peacock and FrogFoot share published pass count")
	_check(Gallery.all_preset_names().size() == 18,
		"gallery exposes affine, pattern and paint-spread entries")


func _test_gallery_retained_stroke_passes() -> void:
	var solver := Solver.new()
	var config := Config.new()
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	var first := Stroke.new()
	first.points_px = PackedVector2Array([
		Vector2(24.0, 72.0), Vector2(48.0, 50.0), Vector2(72.0, 28.0),
	])
	first.points_px.append(Vector2(104.0, 36.0))
	solver.set_strokes([first], Gallery.FREEHAND_LAB)
	var descriptor: Dictionary = solver.get_pattern_descriptor()
	var operations: Array = descriptor.get("operations", [])
	var pass_groups := {}
	for operation in operations:
		pass_groups[operation.curve_group] = true
	_check(operations.size() == 3 and pass_groups.size() == 1,
		"live freehand segments share one GPU pass")


func _line_stroke(y: float, segments: int) -> MixwellStroke:
	var stroke := Stroke.new()
	for index in segments + 1:
		stroke.points_px.append(Vector2(20.0 + float(index) * 0.5, y))
	return stroke


func _test_baked_stroke_prefix() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(256, 256), Config.new(), Vector2i(256, 256))
	var limit := solver.get_live_segment_limit()
	var first := _line_stroke(40.0, 10)
	var second := _line_stroke(200.0, 10)
	solver.set_strokes([first, second], Gallery.FREEHAND_LAB)
	_check(limit == Solver.LIVE_SEGMENT_LIMIT and limit >= 20 and limit < 30
			and solver.get_baked_segment_count() == 0 and solver.get_segment_count() == 20,
		"recent strokes stay live while they fit the window")
	var third := _line_stroke(120.0, 10)
	solver.set_strokes([first, second, third], Gallery.FREEHAND_LAB)
	var operations: Array = solver.create_render_snapshot().operations
	_check(solver.get_baked_segment_count() == 10 and solver.get_segment_count() == 30,
		"the oldest stroke is baked whole once the live window overflows")
	_check(operations.size() == 21 and int(operations[0].type) == Gallery.SEGMENT
			and int(operations[20].type) == Gallery.BAKED_MAP,
		"live segments run before the baked map in RDF order")
	var baked: PackedFloat32Array = solver.create_render_snapshot().baked_segments
	var scale := 2.0 / 256.0
	_check(baked.size() == 80 and is_equal_approx(baked[0], (20.0 - 128.0) * scale)
			and is_equal_approx(baked[8], (20.5 - 128.0) * scale)
			and is_equal_approx(baked[4], first.radius_px * scale),
		"baked segments keep physical order and their stroke epsilon")
	var generation: int = solver.create_render_snapshot().bake_generation
	solver.set_strokes([first, second], Gallery.FREEHAND_LAB)
	_check(solver.create_render_snapshot().bake_generation == generation
			and solver.get_baked_segment_count() == 10 and solver.get_segment_count() == 20,
		"undo of a live stroke keeps the baked prefix")
	solver.set_strokes([first, second, _line_stroke(160.0, 20)], Gallery.FREEHAND_LAB)
	_check(solver.create_render_snapshot().bake_generation == generation
			and solver.get_baked_segment_count() == 20,
		"appending strokes extends the bake without restarting it")
	solver.set_strokes([first], Gallery.FREEHAND_LAB)
	_check(solver.create_render_snapshot().bake_generation == generation
			and solver.get_baked_segment_count() == 10 and solver.get_segment_count() == 10,
		"undo of the newest baked stroke rewinds instead of restarting")
	solver.set_strokes([second], Gallery.FREEHAND_LAB)
	var replaced = solver.create_render_snapshot()
	_check(replaced.bake_generation == generation and replaced.bake_rewinds.back().y == 0
			and solver.get_baked_segment_count() == 0 and solver.get_segment_count() == 10,
		"replacing the first baked stroke rewinds to the empty map")
	solver.set_strokes([_line_stroke(128.0, 300)], Gallery.FREEHAND_LAB)
	_check(solver.get_segment_count() == 300
			and solver.get_baked_segment_count() == 300 - limit / 2,
		"a stroke longer than the live window bakes its head")
	var anchor := _line_stroke(20.0, 10)
	var long_tail := _line_stroke(60.0, 30)
	solver.set_strokes([anchor, long_tail], Gallery.FREEHAND_LAB)
	var snapshot = solver.create_render_snapshot()
	_check(solver.get_baked_segment_count() == 10 + 30 - limit / 2
			and snapshot.bake_starts == PackedInt32Array([0, 10]),
		"every baked stroke records where it starts")
	var third_stroke := _line_stroke(100.0, 30)
	solver.set_strokes([anchor, long_tail, third_stroke], Gallery.FREEHAND_LAB)
	solver.set_strokes([anchor], Gallery.FREEHAND_LAB)
	var rewound = solver.create_render_snapshot()
	_check(rewound.bake_generation == snapshot.bake_generation
			and rewound.bake_revision == snapshot.bake_revision + 1
			and rewound.bake_rewinds.back() == Vector2i(rewound.bake_revision, 10)
			and solver.get_baked_segment_count() == 10 and solver.get_segment_count() == 10,
		"undo of several baked strokes rewinds to the first one removed")


func _test_pattern_round_trip() -> void:
	var pattern = Gallery.preset_pattern(Gallery.GEL_GIT)
	var descriptor: Dictionary = pattern.serialize()
	_check(descriptor.name == "Gel-Git" and descriptor.operations.size() == 1,
		"gallery exposes a named ordered pattern")
	_check(descriptor.source.preset_id == Gallery.GEL_GIT,
		"pattern metadata identifies its gallery source")
	var rebuilt = Pattern.new()
	rebuilt.id = descriptor.id
	rebuilt.name = descriptor.name
	rebuilt.source_metadata = descriptor.source
	rebuilt.set_operations(descriptor.operations)
	_check(rebuilt.serialize().operations == descriptor.operations,
		"pattern operations survive dictionary serialization")


func _test_pattern_physical_order() -> void:
	var pattern = Gallery.preset_pattern(Gallery.FEATHER)
	var logical: Array[Dictionary] = pattern.to_render_operations()
	var physical: Array[Dictionary] = pattern.physical_operations()
	_check(logical.size() == physical.size() and not logical.is_empty(),
		"pattern has both logical and physical operation views")
	_check(physical[0] == logical[logical.size() - 1]
			and physical[-1] == logical[0],
		"physical order is the explicit reverse of artistic order")


func _test_pattern_curve_and_transform_expansion() -> void:
	var pattern = Gallery.preset_pattern(Gallery.CIRCLE_GRID)
	var logical: Array[Dictionary] = pattern.to_render_operations()
	var physical: Array[Dictionary] = pattern.physical_operations()
	var expanded: Array[Dictionary] = pattern.render_operations()
	_check(logical[0].kind == "CURVE" and logical[0].curve_mode == "CIRCLE"
			and logical[0].points.size() == 13,
		"Circle Grid is represented by oriented curve passes")
	_check(expanded.size() == 240 and physical.size() == 20,
		"curve passes expand to ordered segment render operations")
	_check(absf(expanded[0].segment.x) > 0.3,
		"curve transform is applied before shader operations")
	var noisy = Gallery.preset_pattern(Gallery.NONPAREIL_NOISY).serialize()
	_check(is_equal_approx(noisy.operations[0].phase, 0.0175)
			and is_equal_approx(noisy.operations[0].noise, 0.035),
		"comb pattern carries phase and noise parameters")


func _test_pattern_snapshot_carries_pattern() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(320, 180), null, Vector2i(640, 360))
	solver.set_preset(Gallery.BIRD_WING)
	var snapshot = solver.create_render_snapshot()
	# Every BirdWing pass is a closed-form pattern function, rendered as itself.
	_check(snapshot.pattern.name == "BirdWing"
			and snapshot.pattern.operations.size() == snapshot.operations.size(),
		"render snapshot carries the pattern and its render operations")
	_check(snapshot.pattern.operations[0].kind in ["LINE", "COMB", "GEL_GIT", "TRI_WAVE",
			"SEGMENT_CHAIN", "CURVE"],
		"snapshot operation exposes a scientific operation kind")
	# BirdWing opens with a Gel-Git pass: a line family, not a segment chain.
	_check(snapshot.pattern.operations[0].kind == "GEL_GIT",
		"a Gel-Git operation is labelled GEL_GIT, not SEGMENT_CHAIN")


func _test_affine_preset_keeps_stroke_radius() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(320, 180), null, Vector2i(640, 360))
	solver.set_preset(Gallery.TWIST)
	var snapshot = solver.create_render_snapshot()
	_check(snapshot.affine_mode >= 0, "Twist renders in affine mode")
	var stroke := {"type": Gallery.SEGMENT, "radius_px": 18.0}
	_check(is_equal_approx(solver._operation_radius(stroke, snapshot), 18.0),
		"a user stroke keeps its brush radius under an affine preset (the bake uses it)")
	_check(is_equal_approx(solver._operation_radius({"type": Gallery.LINE}, snapshot),
			snapshot.affine_radius_px),
		"the affine brush itself still uses the affine radius")


func _test_pattern_steps() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(320, 180), null, Vector2i(640, 360))
	solver.set_preset(Gallery.BIRD_WING)
	var full = solver.create_render_snapshot()
	var total := solver.get_pattern_operation_count()
	solver.set_pattern_step(1)
	var first = solver.create_render_snapshot()
	_check(total > 1 and first.pattern.active_operations == 1
			and first.operations.size() < full.operations.size(),
		"construction step renders only active artistic passes")
	solver.set_pattern_step(-1)
	_check(solver.create_render_snapshot().operations.size() == full.operations.size(),
		"show-all construction step restores full pattern")


func _test_pattern_diagnostics_are_standalone() -> void:
	var colour := Diagnostics.cpu_pigment(Vector2.ZERO, 3, Vector2i(640, 360))
	_check(is_finite(colour.x) and is_finite(colour.y) and is_finite(colour.z),
		"CPU pigment diagnostic stays finite outside the solver")
	var operation := {"type": Gallery.LINE, "origin": Vector2.ZERO,
		"direction": Vector2.RIGHT}
	var expected := Diagnostics.oracle_expected(operation, Vector2(0.0, 1.0), 1.0, 0.1)
	_check(expected.size() == 2 and is_finite(expected[0]) and is_finite(expected[1]),
		"CPU oracle is callable without solver state")


func _test_progressivity_r2_sequence() -> void:
	var first := Periodicity.r2_sample(0)
	var second := Periodicity.r2_sample(1)
	_check(first == Vector2(0.5, 0.5), "R2 sequence starts at common pixel centre")
	_check(first != second and second.x > 0.0 and second.y > 0.0,
		"R2 sequence advances deterministically for every pixel")
	_check(Periodicity.r2_sample(-1) == first, "negative R2 index is clamped")


func _test_progressivity_spp_targets() -> void:
	for target in [1, 4, 16, 64, 256]:
		var config := Config.new()
		config.target_spp = target
		_check(config.validate() == "", "canonical spp target validates: %d" % target)
	var invalid := Config.new()
	invalid.target_spp = 8
	_check(invalid.validate() != "", "non-canonical spp target is rejected")
	_check(Config.nearest_spp_target(10) == 4, "nearest spp target is deterministic")


func _test_progressivity_fixed_composite_period() -> void:
	var fixed := Periodicity.composite_period_fixed([
		Vector2(0.5, 1.0), Vector2(1.25, 0.5)])
	_check(fixed == Vector2i(25000, 10000),
		"component-wise period LCM uses fixed scale 10000")
	var canonical := Periodicity.canonical_period(Vector2i(1920, 1080))
	_check(Periodicity.quantize_period(canonical) == Vector2i(35556, 20000),
			"canonical display period is quantized once")
	var components := Periodicity.composite_period_components_fixed([
		Vector2i(0, 2000), Vector2i(1333, 0), Vector2i(1333, 20000)])
	_check(components == Vector2i(1333, 20000),
			"component-wise fixed LCM preserves invariant axes")


func _test_progressivity_periodic_coordinates() -> void:
	var period := Vector2(2.0, 2.0)
	_check(Periodicity.wrap_coordinate(Vector2(1.1, -1.1), period).distance_to(
		Vector2(-0.9, 0.9)) <= 1.0e-6, "canonical wrapping stays in centred domain")
	_check(Periodicity.shortest_delta(Vector2(0.95, 0.0), Vector2(-0.95, 0.0), period).x \
			<= -0.09, "periodic shortest path crosses boundary")


# A periodic pass runs on one period and is tiled with pixel % domain, which is
# exact only when the period is a whole number of pixels. At 1280x720 the
# Nonpareil pitch (0.1778) is 64 px and tiles; the Gel-Git period (0.2370) is
# 85.33 px and is evaluated directly -- rounded up to 86 px, every tile would
# shift a further third of a pixel.
func _test_periodic_tiling_needs_whole_pixels() -> void:
	var size := Vector2i(1280, 720)
	var config := Config.new()
	config.boundary_mode = Config.BoundaryMode.PERIODIC
	var solver := Solver.new()
	solver.initialize(size, config, size)
	solver.set_preset(Gallery.NONPAREIL)
	var plan: Array[Dictionary] = solver.create_render_snapshot().periodic_plan
	_check(plan[0].current == Vector2i(1, 64), "Nonpareil tiles its 64 px pitch (%s)" % str(plan[0].current))
	solver.set_preset(Gallery.GEL_GIT)
	var snapshot = solver.create_render_snapshot()
	plan = snapshot.periodic_plan
	_check(plan[0].current == Vector2i(1, 720),
			"Gel-Git's 85.33 px period is not tiled (%s)" % str(plan[0].current))
	var operations: Array[Dictionary] = snapshot.operations
	var rounded: Array[Dictionary] = [{"current": Vector2i(1, 86), "previous": Vector2i(1, 86)}]
	var jitter := Periodicity.r2_sample(0)
	var tiled_error := 0.0
	var rounded_error := 0.0
	for y in range(5, 720, 37):
		var pixel := Vector2i(640, y)
		var direct := Diagnostics.cpu_advect(Diagnostics.display_coordinate(pixel, size, jitter),
				operations, false, Vector2.ZERO, config.brush_radius_px, size, -1, 0.0, 0.0,
				config.cutoff_gamma, config.drift_compensation, config.midpoint_alpha)
		tiled_error = maxf(tiled_error, direct.distance_to(Diagnostics.cpu_tiled_advect(pixel, plan,
				operations, size, jitter, config.brush_radius_px, size, config.cutoff_gamma,
				config.drift_compensation, config.midpoint_alpha)))
		rounded_error = maxf(rounded_error, direct.distance_to(Diagnostics.cpu_tiled_advect(pixel,
				rounded, operations, size, jitter, config.brush_radius_px, size, config.cutoff_gamma,
				config.drift_compensation, config.midpoint_alpha)))
	print("MIXWELL TILING gel_git planned=%s rounded_to_86px=%s" % [str(tiled_error), str(rounded_error)])
	_check(tiled_error <= 1.0e-6 and rounded_error > 1.0e-3,
			"Gel-Git tiled on 86 px seams (%s), evaluated directly it does not (%s)"
			% [str(rounded_error), str(tiled_error)])
	for preset in [Gallery.NONPAREIL, Gallery.GEL_GIT, Gallery.FEATHER, Gallery.BIRD_WING,
			Gallery.PEACOCK, Gallery.SUPER_TORNADO]:
		for render_size in [Vector2i(640, 360), Vector2i(1280, 720)]:
			var periodic := Solver.new()
			periodic.initialize(render_size, config, render_size)
			periodic.set_preset(preset)
			var comparison: Dictionary = periodic.get_periodic_comparison()
			print("MIXWELL TILING %s %s max=%s conditioned=%d" % [Gallery.preset_name(preset),
					str(render_size), str(comparison.get("max_displacement")),
					int(comparison.get("conditioned", -1))])
			_check(comparison.get("passes", false)
					and float(comparison.get("max_displacement", 1.0)) <= 1.0e-5,
					"%s tiles exactly at %s (%s)" % [Gallery.preset_name(preset), str(render_size),
					str(comparison.get("max_displacement"))])


func _test_progressivity_path_comparison() -> void:
	var periodic := PackedFloat32Array([1.9, 0.0, 0.2, 0.0])
	var fullscreen := PackedFloat32Array([-0.1, 0.0, 0.2, 0.0])
	var result := Periodicity.compare_paths(periodic, fullscreen, Vector2(2.0, 2.0))
	_check(result.passes and result.max_displacement <= 5.0e-4,
		"periodic/fullscreen A/B accepts equivalent wrapped paths")


func _test_progressivity_budget_progression() -> void:
	var solver := Solver.new()
	var config := Config.new()
	config.target_spp = 16
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	var batch := solver.get_samples_for_budget(0, config.target_spp)
	_check(batch >= 1 and batch <= config.target_spp,
		"GPU budget always schedules bounded refinement")
	var state := solver.get_refinement_state(config.target_spp)
	_check(state.target == 16 and is_equal_approx(state.progress, 0.0),
		"refinement state exposes target and progress")


func _test_progressivity_render_snapshot() -> void:
	var solver := Solver.new()
	var config := Config.new()
	solver.initialize(Vector2i(320, 180), config, Vector2i(640, 360))
	solver.set_preset(6)
	var snapshot = solver.create_render_snapshot()
	var operation_count: int = snapshot.operations.size()
	_check(operation_count > 0 and snapshot.periodic_plan.size() == operation_count,
			"render snapshot copies operations and periodic plan")
	_check(snapshot.periodic_plan[0].has("operation_period_fixed")
			and snapshot.periodic_plan[0].has("composite_period_fixed")
			and snapshot.periodic_dispatch_pixels > 0
			and snapshot.fullscreen_dispatch_pixels >= snapshot.periodic_dispatch_pixels,
			"snapshot exposes fixed periods and effective dispatch work")
	solver.set_preset(0)
	_check(snapshot.operations.size() == operation_count,
		"render snapshot stays immutable after preset change")
	_check(not solver.diagnostics_enabled(), "diagnostics are disabled on Result path")
	solver.set_diagnostics_enabled(true)
	_check(solver.diagnostics_enabled(), "diagnostics enable explicitly")


func _test_affine_extensions() -> void:
	var names := Gallery.all_preset_names()
	_check(names.size() == 18 and names[Gallery.TWIST].contains("Twist") \
			and names[Gallery.PINCH].contains("Pinch"),
			"gallery identifies Twist and Pinch extensions")
	for id in [Gallery.TWIST, Gallery.PINCH]:
		var matrix := Gallery.affine_matrix(id)
		_check(absf(matrix.x + matrix.w) <= 1.0e-12,
			"affine extension is divergence-free: %s" % names[id])
		_check(Gallery.affine_drift(id, Vector2.ZERO, Vector2.ZERO, 1.0, 0.5, 10.0) == Vector2.ZERO,
			"affine extension is finite at its centre: %s" % names[id])
	var twist_point := Vector2(0.22, -0.14)
	var twisted := Gallery.affine_advect(Gallery.TWIST, twist_point, Vector2.ZERO,
			0.65, 0.5, 10.0)
	_check(is_finite(twisted.x) and is_finite(twisted.y)
			and absf(twisted.length() - twist_point.length()) < 0.01,
		"Twist midpoint integration preserves its radial support")
	# The reverse drift is the flow of -u: carrying the result forward along u
	# for the same unit time returns the point, and a gentle Twist turns the
	# point back against u (a strong one wraps past half a turn).
	var returned := Gallery.affine_advect(Gallery.TWIST, twisted, Vector2.ZERO, 0.65, 0.5, 10.0,
			0.1, 1.0)
	var gentle := Gallery.affine_advect(Gallery.TWIST, twist_point, Vector2.ZERO, 0.05, 0.5, 10.0)
	var forward := Gallery.affine_drift(Gallery.TWIST, twist_point, Vector2.ZERO, 0.05, 0.5, 10.0)
	_check(returned.distance_to(twist_point) <= 1.0e-3
			and twist_point.angle_to(gentle) * twist_point.cross(forward) < 0.0,
		"Twist's reverse drift undoes its flow (%s, turn %s)" % [str(returned.distance_to(twist_point)),
		str(twist_point.angle_to(gentle))])
	# User strokes still apply on top of an affine preset.
	var stroke_operations: Array[Dictionary] = [{"type": Gallery.LINE, "kind": "AFFINE"},
		{"type": Gallery.SEGMENT, "segment": Vector4(0.1, -0.3, 0.1, 0.3), "radius_px": 9.0}]
	var affine_only: Array[Dictionary] = [stroke_operations[0]]
	var probe := Vector2(0.12, 0.05)
	_check(Diagnostics.cpu_advect(probe, stroke_operations, false, Vector2.ZERO, 9.0,
			Vector2i(640, 360), Gallery.TWIST, 180.0, 0.65, 10.0, 0, 0.1).distance_to(
			Diagnostics.cpu_advect(probe, affine_only, false, Vector2.ZERO, 9.0,
			Vector2i(640, 360), Gallery.TWIST, 180.0, 0.65, 10.0, 0, 0.1)) > 1.0e-3,
		"the CPU twin applies user strokes in affine mode")
	var solver := Solver.new()
	solver.initialize(Vector2i(128, 128), Config.new(), Vector2i(128, 128))
	solver.set_preset(Gallery.TWIST)
	_check(solver.get_preset_id() == Gallery.TWIST and solver.get_segment_count() == 0,
		"Twist uses affine dispatch without fake tine segments")
	solver.set_preset(Gallery.PINCH)
	_check(solver.get_preset_id() == Gallery.PINCH,
		"Pinch selects affine dispatch")


func _test_slip_images() -> void:
	_check(Boundaries.EDGE_IMAGES.size() == 4 and Boundaries.CORNER_IMAGES.size() == 4,
		"slip boundary declares four edge and four corner images")
	var half_extent := Vector2(16.0 / 9.0, 1.0)
	var point := Vector2(0.25, -0.3)
	var mirrored := Boundaries.mirror_point(point, Vector2i(-1, 0), half_extent)
	_check(is_equal_approx(mirrored.x, -2.0 * half_extent.x - point.x)
			and is_equal_approx(mirrored.y, point.y),
		"slip edge image reflects across left wall")
	# A comb's tines run through the walls across its motion: its images are
	# across the two walls it runs along only, each a full mirrored comb.
	var comb := {"type": Gallery.LINE_COMB, "origin": Vector2.ZERO, "direction": Vector2.RIGHT,
		"pitch": 0.2, "noise": 0.0}
	var combs: Array[Dictionary] = [comb]
	var inside := Vector2(0.3, 0.83)
	var walled := Diagnostics.cpu_advect(inside, combs, false, Vector2.ZERO, 9.0,
			Vector2i(640, 360), -1, 180.0, 0.65, 10.0, 0, 0.1, half_extent)
	var expected := inside
	for image in [inside, Vector2(inside.x, 2.0 - inside.y), Vector2(inside.x, -2.0 - inside.y)]:
		expected += Math.rd_nonpareil(image, 0.05, Vector2.RIGHT, 0.2, 0.0, 10.0)
	_check(walled.distance_to(expected) <= 1.0e-6,
		"a comb in slip walls adds its images across the two walls it runs along")
	var config := Config.new()
	config.boundary_mode = Config.BoundaryMode.SLIP_WALLS
	_check(config.validate() == "", "slip wall configuration validates")
	var solver := Solver.new()
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	solver.set_boundary_mode(Config.BoundaryMode.SLIP_WALLS)
	_check(solver.get_active_boundary_mode() == Config.BoundaryMode.SLIP_WALLS,
		"solver activates slip-wall images")
	var periodic_config := Config.new()
	periodic_config.boundary_mode = Config.BoundaryMode.PERIODIC
	var periodic_solver := Solver.new()
	periodic_solver.initialize(Vector2i(640, 360), periodic_config, Vector2i(640, 360))
	periodic_solver.set_preset(Gallery.BIRD_WING)
	_check(periodic_solver.get_periodic_domain_size().x < 640
			and periodic_solver.get_periodic_domain_size().y <= 360,
		"periodic BirdWing uses a reduced composite domain")


func _test_diagnostics_contract() -> void:
	var solver := Solver.new()
	solver.initialize(Vector2i(64, 64), Config.new(), Vector2i(64, 64))
	var metrics := solver.get_metrics()
	_check(metrics.has("area_error") and metrics.has("max_area_error")
			and metrics.has("area_wall") and metrics.has("convergence_error")
			and metrics.has("convergence_p99"),
		"solver exposes area and convergence diagnostics before GPU init")
	_check(solver.readback_diagnostics().is_empty(),
		"diagnostic readback is empty before RenderingDevice initialization")


func _test_controller_contract() -> void:
	var controller_script := load("res://scripts/demos/mixwell_controller.gd")
	var constants: Dictionary = controller_script.get_script_constant_map()
	var chapters: Array = constants.get("CHAPTER_NAMES", [])
	var comparisons: Array = constants.get("COMPARISON_NAMES", [])
	_check(chapters.size() == 3 and chapters[0] == "Principle"
			and chapters[2] == "Validation",
		"controller exposes three exhibit chapters")
	_check(comparisons.has("Source | Result") and comparisons.has("Fullscreen | Periodic")
			and comparisons.has("Open walls | Slip walls"),
		"controller exposes source, boundary and periodic comparison workflows")
	var display_shader := FileAccess.get_file_as_string(
			"res://shaders/mixwell/mixwell_display.gdshader")
	_check(display_shader.contains("comparison_mode")
			and display_shader.contains("UV.x * 2.0"),
		"display shader implements source/result split view")
	var controller_source := FileAccess.get_file_as_string(
			"res://scripts/demos/mixwell_controller.gd")
	_check(controller_source.contains("Load source texture")
			and controller_source.contains("solver input remains procedural"),
		"controller keeps a user texture preview with procedural fallback")


func _test_cpu_preset_matrix() -> void:
	var names := Gallery.all_preset_names()
	_check(names.size() == 18, "CPU golden matrix covers all 18 presets")
	for preset in names.size():
		var pattern = Gallery.preset_pattern(preset)
		var operations: Array[Dictionary] = pattern.render_operations()
		var affine_mode := preset if Gallery.is_affine(preset) else -1
		var first := Diagnostics.cpu_advect(GOLDEN_COORDINATE, operations, false,
				Vector2(2.0, 2.0), 18.0, Vector2i(640, 360), affine_mode,
				180.0, 0.65, 10.0, Config.DriftCompensation.NONE, 0.1)
		var second := Diagnostics.cpu_advect(GOLDEN_COORDINATE, operations, false,
				Vector2(2.0, 2.0), 18.0, Vector2i(640, 360), affine_mode,
				180.0, 0.65, 10.0, Config.DriftCompensation.NONE, 0.1)
		var golden: Array = CPU_GOLDENS[preset]
		_check(first == second and is_finite(first.x) and is_finite(first.y)
				and absf(first.x - golden[0]) <= 1.0e-6
				and absf(first.y - golden[1]) <= 1.0e-6,
				"CPU golden is finite and deterministic: %s" % names[preset])
		print("CPU GOLDEN %02d %s %.12f %.12f" % [preset, names[preset], first.x, first.y])


func _test_stress_and_export_contract() -> void:
	_check(Config.SPP_TARGETS.has(256), "stress target retains 256 spp")
	var solver := Solver.new()
	solver.initialize(Vector2i(320, 180), Config.new(), Vector2i(640, 360))
	var stroke := Stroke.new()
	stroke.radius_px = 2.0
	for point_index in 257:
		stroke.points_px.append(Vector2(float(point_index), float(point_index % 17)))
	solver.set_strokes([stroke])
	_check(solver.get_segment_count() == 256,
			"stress keeps every segment past the GPU buffer size")
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	for preset_name in ["Windows Desktop", "Linux", "Android"]:
		var start := presets.find("name=\"%s\"" % preset_name)
		var next := presets.find("\n[preset.", start + 1)
		var section := presets.substr(start, presets.length() if next < 0 else next - start)
		_check(start >= 0 and section.contains("include_filter=\"*.comp\""),
				"%s export keeps raw compute shaders" % preset_name)
	_check(FileAccess.get_file_as_string("res://project.godot").contains(
				"renderer/rendering_method.mobile=\"forward_plus\""),
			"mobile profile keeps Forward+")


func _test_zone_metrics_contract() -> void:
	var diagnostic_values := PackedFloat32Array([
		0.0, 0.0, 0.0, 0.001,
		0.0, 0.0, 0.0, 0.002,
		0.0, 0.0, 0.0, 0.100,
		0.0, 0.0, 0.0, 0.200,
	])
	var zone_values := PackedByteArray([0, 0, 2, 4])
	var metrics := Diagnostics.analyse_zone_metrics(diagnostic_values, zone_values, Vector2i(2, 2))
	_check(metrics.area_valid_count == 2 and absf(metrics.area_core_mean - 0.0015) <= 1.0e-6,
		"diagnostics separate valid core pixels from cutoff and wall zones")
	_check(absf(metrics.area_valid_p99 - 0.002) <= 1.0e-6,
		"diagnostics expose a percentile for valid core pixels")

func _segment_map(value: PackedFloat64Array, start: PackedFloat64Array,
		end: PackedFloat64Array) -> PackedFloat64Array:
	return Math.add_point(value, Math.rd_segment(value, 1.0, start, end, 0.1))


func _oracle_segment_map(value: PackedFloat64Array, start: PackedFloat64Array,
		end: PackedFloat64Array) -> PackedFloat64Array:
	return Math.add_point(value, Math.rd_segment(value, 1.0, start, end, 0.05))


func _point_distance(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	if a.size() != 2 or b.size() != 2:
		return INF
	return Math.length_point(Math.subtract_point(a, b))


func _point_is_finite(value: PackedFloat64Array) -> bool:
	return value.size() == 2 and is_finite(value[0]) and is_finite(value[1])
