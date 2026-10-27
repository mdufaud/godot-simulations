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
	_test_bake_follows_parameters()
	_test_divergence_free()
	_test_vertical_wind_bounded()
	_test_published_core_structure()
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


## Inflow: |v_r| max at the surface ~0.5-0.65 u_max just outside the RMW, weaker aloft.
func _test_inflow_profile() -> void:
	var field := _new_field()
	field.model = TornadoWindField.Model.BURGERS_ROTT
	# At the surface proper: the inflow layer is ~0.6 core radii deep.
	var y_low := 0.02 * field.r_core0
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


# The grid is rebuilt only when a wind input changes: a parameter edit must still
# reach it (including a direct field write, as apply_preset does for height), and
# moving the vortex must not invalidate it.
func _test_bake_follows_parameters() -> void:
	var field := _new_field()
	field.bake_wind_grid()
	var y := field.height * 0.4
	var before := field.sample_wind_grid(1.0, y)
	var revision := field.revision
	field.base_pos = Vector3(50.0, 0.0, 20.0)
	_check(field.revision == revision, "moving the vortex keeps the baked grid")
	field.u_max *= 2.0
	_check(field.revision != revision, "a wind parameter write bumps the revision")
	field.bake_wind_grid()
	var after := field.sample_wind_grid(1.0, y)
	_check(after.is_equal_approx(before * 2.0),
		"the grid rebakes after u_max doubles: %s -> %s" % [before, after])
	field.height = 200.0
	field.bake_wind_grid()
	_check(not field.sample_wind_grid(1.0, y).is_equal_approx(after),
		"a direct height write rebakes the grid")


## Cartesian divergence by central differences, of the full wind or of its
## meridional (radial + vertical) part only.
func _divergence(field: TornadoWindField, p: Vector3, h: float, meridional: bool) -> float:
	var at := func(q: Vector3) -> Vector3:
		return _meridional_wind(field, q) if meridional else field.wind_at(q)
	var dx: float = at.call(p + Vector3(h, 0.0, 0.0)).x - at.call(p - Vector3(h, 0.0, 0.0)).x
	var dy: float = at.call(p + Vector3(0.0, h, 0.0)).y - at.call(p - Vector3(0.0, h, 0.0)).y
	var dz: float = at.call(p + Vector3(0.0, 0.0, h)).z - at.call(p - Vector3(0.0, 0.0, h)).z
	return (dx + dy + dz) / (2.0 * h)


func _meridional_wind(field: TornadoWindField, p: Vector3) -> Vector3:
	var c := field.centerline_at(p.y)
	var rel := Vector2(p.x - c.x, p.z - c.z)
	var w := field.cylindrical_wind(rel.length() / field.core_radius_at(p.y), p.y)
	var r_dir := Vector3(rel.x, 0.0, rel.y).normalized()
	return (r_dir * w.x + Vector3.UP * w.z) * field.u_max


# Mass conservation: the radial and vertical winds come from a stream function, so
# div u must vanish everywhere inside the funnel, for every model and with a flared
# core. The old field's inflow and updraft did not match (|div| ~ u_max / r_core).
# The swirl is axisymmetric and divergence-free whatever its profile, but Sullivan's
# is a piecewise-linear table whose kinks a finite-difference stencil misreads, so
# the full field is checked on the two analytic profiles and the meridional flow on
# all three.
func _test_divergence_free() -> void:
	for model in ALL_MODELS:
		var field := _new_field()
		field.model = model
		field.flare = 2.0
		for meridional in [true, false]:
			if not meridional and model == TornadoWindField.Model.SULLIVAN:
				continue
			var rng := RandomNumberGenerator.new()
			rng.seed = 1234
			var worst := 0.0
			for i in 200:
				var y := rng.randf_range(0.02, 0.98) * field.height
				var r_bar := rng.randf_range(0.05, 7.8)
				var angle := rng.randf_range(0.0, TAU)
				var r_core := field.core_radius_at(y)
				var p := field.centerline_at(y) \
					+ Vector3(cos(angle), 0.0, sin(angle)) * r_bar * r_core
				# Relative to the field's own gradient scale u_max / r_core.
				worst = maxf(worst, absf(_divergence(field, p, 0.002 * r_core, meridional))
					* r_core / field.u_max)
			_check(worst < 2e-3, "wind field is divergence-free (model %d, %s): worst %s"
				% [model, "meridional" if meridional else "full", str(worst)])


# L(y) saturates, so the updraft stays bounded however tall the funnel: on the axis
# at most 2 a_bar UPDRAFT_DEPTH u_max (Burgers-Rott, Vatistas), twice that downward
# in Sullivan's eye.
func _test_vertical_wind_bounded() -> void:
	for model in ALL_MODELS:
		var field := _new_field()
		field.model = model
		field.height = 600.0
		var axial := 4.0 if model == TornadoWindField.Model.SULLIVAN else 2.0
		var bound := 1.05 * axial * field.a_bar * TornadoWindField.UPDRAFT_DEPTH * field.u_max
		var worst := 0.0
		for yi in 60:
			for ri in 40:
				var w := field.cylindrical_wind(0.2 * ri, field.height * (yi + 0.5) / 60.0)
				worst = maxf(worst, absf(w.z) * field.u_max)
		_check(worst <= bound, "vertical wind bounded (model %d): %.1f > %.1f m/s"
			% [model, worst, bound])


# Near the axis and the ground the secondary flow is the published model with
# strain a = a_bar * INFLOW_ONSET: Burgers-Rott's v_z / z = -2 v_r / r, and
# Sullivan's two cells (axial downdraft inside, updraft ring outside).
func _test_published_core_structure() -> void:
	var field := _new_field()
	field.flare = 0.0
	field.model = TornadoWindField.Model.BURGERS_ROTT
	var y := 0.01 * field.r_core0
	var w := field.cylindrical_wind(0.05, y)
	var strain := -w.x / 0.05
	var stretch := w.z / (y / field.r_core0)
	_check(absf(stretch - 2.0 * strain) < 0.03 * stretch,
		"Burgers-Rott core: v_z/z = -2 v_r/r (%.3f vs %.3f)" % [stretch, 2.0 * strain])
	_check(absf(strain - field.a_bar * TornadoWindField.INFLOW_ONSET) < 0.03 * strain,
		"Burgers-Rott strain is a_bar * INFLOW_ONSET")
	field.model = TornadoWindField.Model.SULLIVAN
	y = 0.3 * field.r_core0
	_check(field.cylindrical_wind(0.2, y).z < 0.0, "Sullivan: downdraft in the eye")
	_check(field.cylindrical_wind(0.9, y).z > 0.0, "Sullivan: updraft ring around the eye")
	_check(field.cylindrical_wind(0.2, y).x > 0.0 and field.cylindrical_wind(2.0, y).x < 0.0,
		"Sullivan: outflow from the eye, inflow outside")
