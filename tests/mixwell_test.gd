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
	[0.202904567122, -0.209999993443],
	[0.281788051128, -0.209999993443],
	[0.244730785489, 0.037602756172],
	[0.331145524979, 0.015012499876],
	[0.419651836157, -0.329145014286],
	[0.454952865839, -0.026333246380],
	[-0.397537738085, 0.154076203704],
	[0.814242064953, -0.383117645979],
	[0.696609914303, -0.057071477175],
	[0.341940313578, -0.209272474051],
	[0.480739802122, -0.156950622797],
	[0.159733921289, -0.209999993443],
	[0.321938484907, -0.224071413279],
	[0.381899595261, -0.190166831017],
	[0.337046623230, -0.369618535042],
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
	_test_oracle_jacobian_grid_is_finite()
	_test_gallery_names_and_counts()
	_test_gallery_chained_tri_wave()
	_test_gallery_physical_reverse_order()
	_test_gallery_mean_compensation()
	_test_gallery_published_passes()
	_test_gallery_retained_stroke_passes()
	_test_pattern_round_trip()
	_test_pattern_physical_order()
	_test_pattern_curve_and_transform_expansion()
	_test_pattern_steps()
	_test_pattern_snapshot_carries_pattern()
	_test_pattern_diagnostics_are_standalone()
	_test_progressivity_r2_sequence()
	_test_progressivity_spp_targets()
	_test_progressivity_fixed_composite_period()
	_test_progressivity_periodic_coordinates()
	_test_progressivity_path_comparison()
	_test_progressivity_budget_progression()
	_test_progressivity_render_snapshot()
	_test_affine_extensions()
	_test_slip_images_and_calibration()
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
	_check(Gallery.preset_operations(Gallery.NONPAREIL).size() == 1
			and Gallery.preset_operations(Gallery.NONPAREIL)[0].type == Gallery.LINE_COMB,
		"Nonpareil is one rdLine comb pass")
	_check(Gallery.preset_operations(Gallery.GEL_GIT).size() == 2,
		"Gel-Git is two opposed comb passes")


func _test_gallery_chained_tri_wave() -> void:
	var segments := Gallery.tri_wave(Vector2(-0.8, 0.0), Vector2(0.8, 0.0), 0.1, 6)
	_check(segments.size() == 12, "TriWave uses two chained segments per cycle")
	for index in range(segments.size() - 1):
		_check(Vector2(segments[index].z, segments[index].w).distance_to(
				Vector2(segments[index + 1].x, segments[index + 1].y)) <= 1.0e-6,
			"TriWave segment chain is continuous")


func _test_gallery_physical_reverse_order() -> void:
	var solver := Solver.new()
	var config := Config.new()
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	solver.set_preset(Gallery.FROG_FOOT)
	var logical := solver.get_segments()
	var physical := solver.get_segments_physical_order()
	_check(logical.size() == physical.size() and logical.size() > 1,
			"preset exposes logical and physical segment lists")
	for index in logical.size():
		_check(physical[index] == logical[logical.size() - 1 - index],
				"RDF composition dispatches segments in physical inverse order")


func _test_gallery_mean_compensation() -> void:
	var epsilon := 0.25
	var expected := -PI * epsilon * epsilon / 2.0
	_check(absf(Gallery.compensation_value(2, epsilon, 2.0) - expected) <= 1.0e-12,
			"mean drift compensation follows -pi epsilon^2/pitch")
	var h := 2.0 / epsilon
	var minimum := epsilon * (-37.7829 + 1.01689 * h) \
			/ (1.09635 + h * (12.2129 + h * (1.59101 + h)))
	_check(absf(Gallery.compensation_value(1, epsilon, 2.0) - minimum) <= 1.0e-12,
			"minimum drift compensation follows Padé approximation")
	_check(Gallery.compensation_vector(2, epsilon, 2.0, Vector2.RIGHT).distance_to(
			Vector2(expected, 0.0)) <= 1.0e-6, "mean compensation follows tine direction")


func _test_gallery_published_passes() -> void:
	var feather := Gallery.preset_operations(Gallery.FEATHER)
	var bird_wing := Gallery.preset_operations(Gallery.BIRD_WING)
	var peacock := Gallery.preset_operations(Gallery.PEACOCK)
	var frog_foot := Gallery.preset_operations(Gallery.FROG_FOOT)
	_check(feather.size() > 3 and bird_wing.size() > feather.size(),
		"Feather and BirdWing compose combs and TriWaves")
	_check(peacock.size() == frog_foot.size() and peacock.size() > 3,
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
	var second := Stroke.new()
	second.points_px = PackedVector2Array([Vector2(86.0, 84.0), Vector2(104.0, 36.0)])
	solver.set_strokes([first, second], Gallery.FREEHAND_LAB)
	var descriptor: Dictionary = solver.get_pattern_descriptor()
	var operations: Array = descriptor.get("operations", [])
	var pass_groups := {}
	for operation in operations:
		pass_groups[operation.curve_group] = true
	_check(operations.size() == 3 and pass_groups.size() == 3,
		"retained freehand segments use sequential GPU passes")


func _test_pattern_round_trip() -> void:
	var pattern = Gallery.preset_pattern(Gallery.GEL_GIT)
	var descriptor: Dictionary = pattern.serialize()
	_check(descriptor.name == "Gel-Git" and descriptor.operations.size() == 2,
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
	_check(snapshot.pattern.name == "BirdWing"
			and snapshot.pattern.operations.size() < snapshot.operations.size(),
		"render snapshot carries high-level pattern and expanded render operations")
	_check(snapshot.pattern.operations[0].kind == "LINE" or
			snapshot.pattern.operations[0].kind == "SEGMENT_CHAIN",
		"snapshot operation exposes a scientific operation kind")


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
	var solver := Solver.new()
	solver.initialize(Vector2i(128, 128), Config.new(), Vector2i(128, 128))
	solver.set_preset(Gallery.TWIST)
	_check(solver.get_preset_id() == Gallery.TWIST and solver.get_segment_count() == 0,
		"Twist uses affine dispatch without fake tine segments")
	solver.set_preset(Gallery.PINCH)
	_check(solver.get_preset_id() == Gallery.PINCH,
		"Pinch selects affine dispatch")


func _test_slip_images_and_calibration() -> void:
	_check(Boundaries.EDGE_IMAGES.size() == 4 and Boundaries.CORNER_IMAGES.size() == 4,
		"slip boundary declares four edge and four corner images")
	var half_extent := Vector2(16.0 / 9.0, 1.0)
	var point := Vector2(0.25, -0.3)
	var mirrored := Boundaries.mirror_point(point, Vector2i(-1, 0), half_extent)
	_check(is_equal_approx(mirrored.x, -2.0 * half_extent.x - point.x)
			and is_equal_approx(mirrored.y, point.y),
		"slip edge image reflects across left wall")
	var calibration := Boundaries.calibration_matrix(Vector2.ZERO, half_extent, 0.1)
	_check(calibration != Vector4.ZERO and is_finite(calibration.x)
			and is_finite(calibration.y) and is_finite(calibration.z) and is_finite(calibration.w),
		"slip calibration is a finite 2x2 inverse")
	var config := Config.new()
	config.boundary_mode = Config.BoundaryMode.SLIP_WALLS
	_check(config.validate() == "", "slip wall configuration validates")
	var solver := Solver.new()
	solver.initialize(Vector2i(128, 128), config, Vector2i(128, 128))
	solver.set_boundary_mode(Config.BoundaryMode.SLIP_WALLS)
	_check(solver.get_active_boundary_mode() == Config.BoundaryMode.SLIP_WALLS
			and solver.get_wall_calibration() == 1.0,
		"solver activates matrix-calibrated slip images")
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
	_check(solver.get_segment_count() == solver.get_segment_limit(),
			"stress fills the configured segment limit")
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	for preset_name in ["Windows Desktop", "Linux", "Android"]:
		var start := presets.find("name=\"%s\"" % preset_name)
		var next := presets.find("\n[preset.", start + 1)
		var section := presets.substr(start, presets.length() if next < 0 else next - start)
		_check(start >= 0 and section.contains("include_filter=\"*.comp"),
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
