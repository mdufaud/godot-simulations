extends "res://tests/test_case.gd"

const TornadoWindFieldScript := preload("res://scripts/tornado/tornado_wind_field.gd")
const TornadoControllerScript := preload("res://scripts/demos/tornado_controller.gd")

const ALL_MODELS := [TornadoWindField.Model.VATISTAS, TornadoWindField.Model.BURGERS_ROTT,
	TornadoWindField.Model.SULLIVAN]


func _initialize() -> void:
	_test_bounds_and_centerline()
	_test_tangential_convention()
	_test_grid_matches_analytic_field()
	_test_models_return_finite_wind()
	_test_tangential_peaks_at_core_radius()
	_test_inflow_profile()
	_test_top_fade()
	_test_camera_framing()
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


## wind_at() must rotate swirl_sign * UP x r_dir (toward -Z at +X for +1), the
## convention shared by the GLSL mirror and TornadoDebrisPool's reconstruction.
func _test_tangential_convention() -> void:
	var field := _new_field()
	field.model = TornadoWindField.Model.BURGERS_ROTT
	for s in [1.0, -1.0]:
		field.swirl_sign = s
		var y := 30.0
		var r_core := field.core_radius_at(y)
		var v: Vector3 = field.wind_at(field.base_pos + Vector3(r_core, y, 0.0))
		var t := TornadoWindField.tangent_from_radial(1.0, 0.0, s)
		_check(v.x < 0.0, "radial inflow points toward the axis")
		_check(signf(v.z) == signf(t.y) and absf(v.z) > 0.5 * field.u_max,
			"tangential wind follows swirl_sign * UP x r_dir")


## Grid and analytic field must agree for every model, at an exact node and
## between nodes (bilinear vs analytic tolerance).
func _test_grid_matches_analytic_field() -> void:
	var radial_index := 10.0
	var vertical_index := 20.0
	var r_bar := TornadoWindField.INFLUENCE_FACTOR * radial_index \
		/ float(TornadoWindField.WIND_GRID_R - 1)
	var y := 120.0 * vertical_index / float(TornadoWindField.WIND_GRID_Y - 1)
	for model in ALL_MODELS:
		var field := _new_field()
		field.model = model
		field.bake_wind_grid()
		var point := field.centerline_at(y) + Vector3(field.core_radius_at(y) * r_bar, 0.0, 0.0)
		var analytic: Vector3 = field.wind_at(point)
		var sample: Vector3 = field.sample_wind_grid(r_bar, y)
		# Grid stores (v_r, v_t, v_z); at +X the tangent is -Z, hence -sample.y.
		var reconstructed := Vector3(sample.x, sample.z, -sample.y)
		_check(reconstructed.distance_to(analytic) < 0.01,
			"wind grid matches analytic field at grid node (model %d)" % model)
		# Half-node away: bilinear interpolation error, not exactness.
		var r_half := r_bar + 0.5 * TornadoWindField.INFLUENCE_FACTOR \
			/ float(TornadoWindField.WIND_GRID_R - 1)
		var y_half := y + 0.5 * field.height / float(TornadoWindField.WIND_GRID_Y - 1)
		var point2 := field.centerline_at(y_half) \
			+ Vector3(field.core_radius_at(y_half) * r_half, 0.0, 0.0)
		var analytic2: Vector3 = field.wind_at(point2)
		var sample2: Vector3 = field.sample_wind_grid(r_half, y_half)
		var reconstructed2 := Vector3(sample2.x, sample2.z, -sample2.y)
		_check(reconstructed2.distance_to(analytic2) < 1.5,
			"wind grid tracks analytic field between nodes (model %d)" % model)


func _test_models_return_finite_wind() -> void:
	var field := _new_field()
	var point := field.base_pos + Vector3(14.0, 45.0, 2.0)
	for model in ALL_MODELS:
		field.model = model
		field.bake_wind_grid()
		var value: Vector3 = field.wind_at(point)
		_check(is_finite(value.x) and is_finite(value.y) and is_finite(value.z),
			"wind model returned finite velocity")


## Every model must put its tangential maximum at r_bar = 1 (core radius = RMW).
func _test_tangential_peaks_at_core_radius() -> void:
	var y := 36.0
	for model in ALL_MODELS:
		var field := _new_field()
		field.model = model
		var t_at := func(r_bar: float) -> float:
			var p := field.base_pos \
				+ Vector3(field.core_radius_at(y) * r_bar, y, 0.0)
			var v: Vector3 = field.wind_at(p)
			var t := TornadoWindField.tangent_from_radial(1.0, 0.0, field.swirl_sign)
			return Vector3(t.x, 0.0, t.y).dot(v)
		var inner: float = t_at.call(0.85)
		var peak: float = t_at.call(1.0)
		var outer: float = t_at.call(1.2)
		_check(peak > inner and peak > outer,
			"tangential wind peaks at the core radius (model %d)" % model)
		_check(absf(peak - field.u_max) < 0.01 * field.u_max,
			"peak tangential wind equals u_max (model %d)" % model)


## Inflow: |v_r| max near the surface ~0.5-0.65 u_max just outside the RMW, weaker aloft.
func _test_inflow_profile() -> void:
	var field := _new_field()
	field.model = TornadoWindField.Model.BURGERS_ROTT
	var y_low := 2.0
	var max_low := 0.0
	var r_peak := 0.0
	for i in 24:
		var r_bar := 0.25 + 0.25 * float(i)
		var p := field.base_pos + Vector3(field.core_radius_at(y_low) * r_bar, y_low, 0.0)
		var v: Vector3 = field.wind_at(p)
		if -v.x > max_low:
			max_low = -v.x
			r_peak = r_bar
	_check(max_low > 0.45 * field.u_max and max_low < 0.7 * field.u_max,
		"surface inflow magnitude is in the LES-calibrated band")
	_check(r_peak > 1.0 and r_peak < 2.5,
		"surface inflow peaks just outside the core radius")
	var p_in := field.base_pos + Vector3(field.core_radius_at(y_low) * 1.5, y_low, 0.0)
	var p_high := field.base_pos \
		+ Vector3(field.core_radius_at(0.5 * field.height) * 1.5, 0.5 * field.height, 0.0)
	_check(-field.wind_at(p_high).x < -field.wind_at(p_in).x,
		"inflow relaxes with height")


## The wind must fade to ~zero approaching the funnel top on ALL components
## (debris sample the grid, which clamps y — a missing fade would fling debris skyward).
func _test_top_fade() -> void:
	for model in ALL_MODELS:
		var field := _new_field()
		field.model = model
		var y := 0.97 * field.height
		var p := field.base_pos + Vector3(field.core_radius_at(y), y, 0.0)
		var v: Vector3 = field.wind_at(p)
		_check(v.length() < 0.2 * field.u_max,
			"wind fades near the funnel top (model %d)" % model)
		var grid_v: Vector3 = field.sample_wind_grid(1.0, y)
		_check(grid_v.length() < 0.2 * field.u_max,
			"baked grid fades near the funnel top (model %d)" % model)


## Framing gate: the spawn pose stays close to the storm (380 m, preset-scaled),
## portrait pulls back at most x1.5 (never the old unbounded ~x3.9), and the
## camera must never sit inside the dust skirt, for any preset.
func _test_camera_framing() -> void:
	var cases := [[45.0]]  # config default core radius
	for p in TornadoControllerScript.PRESETS:
		cases.append([p.r0])
	for case in cases:
		var r0: float = case[0]
		for aspect in [0.46, 0.74, 1.0, 1.78, 2.35]:
			var window := Vector2i(int(1080.0 * aspect), 1080)
			var dist: float = TornadoControllerScript.camera_distance(
				maxf(6.0 * r0, 380.0), window)
			_check(dist <= 1.5 * maxf(6.0 * r0, 380.0) + 0.01,
				"portrait pullback stays bounded (r0=%.0f aspect=%.2f)" % [r0, aspect])
			# Widest skirt slider setting with margin.
			var skirt := (3.2 + 1.2 * 2.0) * r0 * 1.05
			_check(dist > skirt,
				"camera outside the dust skirt (r0=%.0f aspect=%.2f)" % [r0, aspect])
