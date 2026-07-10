class_name TornadoWindField
extends RefCounted

## Analytical tornado wind field (Gillmeier & Sterling, J. Wind Eng. 2018).
## Single source of truth for the vortex math — shaders/tornado_wind.gdshaderinc
## mirrors wind_at() line-for-line and must stay in sync.

enum Model { RANKINE, BURGERS_ROTT, SULLIVAN }

const NUM_SLICES := 8
const SULLIVAN_B := 3.0
const BR_ALPHA := 1.256643
const BR_NORM := 1.397948  # 1 / peak of (1-exp(-BR_ALPHA*r^2))/r, so u_max is the true peak speed
const R_BAR_MAX := 4.0
const Z_BAR_CAP := 6.0
const INFLUENCE_FACTOR := 8.0

var model: int = Model.BURGERS_ROTT
var u_max := 85.0
var r_core0 := 45.0
var height := 550.0
var flare := 2.5
var a_bar := 0.15
var swirl_sign := 1.0
var base_pos := Vector3.ZERO
var slice_offsets := PackedVector2Array()

var _sullivan_curve: Curve
var _sullivan_tex: CurveTexture


func _init() -> void:
	slice_offsets.resize(NUM_SLICES)
	_sullivan_curve = build_sullivan_profile()
	_sullivan_tex = CurveTexture.new()
	_sullivan_tex.texture_mode = CurveTexture.TEXTURE_MODE_RED
	_sullivan_tex.width = 256
	_sullivan_tex.curve = _sullivan_curve


## Bakes normalized Sullivan tangential profile v_theta(r_bar) for r_bar in [0, 8].
## H(x) = int_0^x exp(-x' + 3*int_0^x' (1-e^-t)/t dt) dx', v_theta = H(r^2)/(r*H(inf)).
static func build_sullivan_profile() -> Curve:
	var dx := 0.01
	var x_max := 64.0
	var n := int(x_max / dx)
	var g := 0.0
	var h := 0.0
	var h_samples := PackedFloat64Array()
	h_samples.resize(n + 1)
	h_samples[0] = 0.0
	for i in n:
		var x := (i + 0.5) * dx
		g += 3.0 * (1.0 - exp(-x)) / x * dx
		h += exp(-x + g) * dx
		h_samples[i + 1] = h
	var h_inf := h
	var points := 128
	var values := PackedFloat64Array()
	values.resize(points + 1)
	var v_peak := 0.0
	for i in points + 1:
		var r_bar := 8.0 * i / points
		var v := 0.0
		if r_bar > 1e-4:
			var idx := clampi(int(r_bar * r_bar / dx), 0, n)
			v = h_samples[idx] / (r_bar * h_inf)
		values[i] = v
		v_peak = maxf(v_peak, v)
	var curve := Curve.new()
	curve.min_value = 0.0
	curve.max_value = 1.0
	curve.max_domain = 8.0
	curve.bake_resolution = 256
	for i in points + 1:
		curve.add_point(Vector2(8.0 * i / points, values[i] / v_peak))
	return curve


func get_sullivan_texture() -> CurveTexture:
	return _sullivan_tex


func core_radius_at(y: float) -> float:
	return r_core0 * (1.0 + flare * pow(clampf(y / height, 0.0, 1.0), 1.5))


func centerline_at(y: float) -> Vector3:
	var t := clampf(y / height, 0.0, 1.0) * (NUM_SLICES - 1)
	var i := clampi(int(t), 0, NUM_SLICES - 2)
	var off := slice_offsets[i].lerp(slice_offsets[i + 1], t - i)
	return base_pos + Vector3(off.x, y, off.y)


func influence_radius(y: float) -> float:
	return INFLUENCE_FACTOR * core_radius_at(y)


func update_centerline(time: float, s_amount: float, noise: FastNoiseLite) -> void:
	for i in NUM_SLICES:
		var z01 := float(i) / (NUM_SLICES - 1)
		var s := Vector2(sin(z01 * PI * 1.5), 0.35 * sin(z01 * PI * 0.9)) * 0.12 * height * s_amount
		var amp := 0.05 * height * z01
		var w := Vector2(
			noise.get_noise_2d(time * 12.0, z01 * 80.0),
			noise.get_noise_2d(time * 12.0 + 137.0, z01 * 80.0)
		) * amp
		slice_offsets[i] = s + w


func get_shader_centerline() -> PackedVector3Array:
	var arr := PackedVector3Array()
	arr.resize(NUM_SLICES)
	for i in NUM_SLICES:
		var y := height * i / (NUM_SLICES - 1)
		arr[i] = centerline_at(y)
	return arr


func wind_at(p: Vector3) -> Vector3:
	if p.y > height or p.y < 0.0:
		return Vector3.ZERO
	var c := centerline_at(p.y)
	var r_core := core_radius_at(p.y)
	var rel := Vector2(p.x - c.x, p.z - c.z)
	var r := rel.length()
	var r_bar := r / r_core
	if r_bar > INFLUENCE_FACTOR:
		return Vector3.ZERO
	var z_bar := minf(p.y / r_core, Z_BAR_CAP)
	# Fast near-ground onset saturating at Z_BAR_CAP: the papers' v_z ~ z is too weak
	# in the corner-flow region to ever loft debris (models are inviscid, no boundary layer).
	var z_eff := Z_BAR_CAP * (1.0 - exp(-0.8 * z_bar))
	var rb := minf(r_bar, R_BAR_MAX)
	var r_safe := maxf(r_bar, 1e-3)

	var v_t := 0.0
	var v_r := 0.0
	var v_z := 0.0
	match model:
		Model.RANKINE:
			v_t = 2.0 * r_bar / (1.0 + r_bar * r_bar)
		Model.BURGERS_ROTT:
			v_t = BR_NORM * (1.0 - exp(-BR_ALPHA * r_bar * r_bar)) / r_safe
			v_r = -a_bar * rb
			v_z = 2.0 * a_bar * z_eff * exp(-0.25 * r_bar * r_bar)
		Model.SULLIVAN:
			var e := exp(-r_bar * r_bar)
			v_t = _sullivan_curve.sample_baked(r_bar)
			v_r = a_bar * (-rb + (SULLIVAN_B / r_safe) * (1.0 - e))
			v_z = 2.0 * a_bar * z_eff * (1.0 - SULLIVAN_B * e) * exp(-0.15 * r_bar * r_bar)

	# Corner flow (Lewellen): annular near-ground updraft jet at the core wall plus
	# intensified surface inflow — this is what lofts debris; absent from the inviscid models.
	if model != Model.RANKINE:
		var dr := (r_bar - 1.0) / 0.45
		v_z += 2.5 * a_bar * exp(-dr * dr) * (1.0 - exp(-8.0 * z_bar)) * exp(-0.5 * z_bar)
		v_r *= 1.0 + 0.75 * exp(-1.5 * z_bar)

	v_z *= 1.0 - smoothstep(0.85 * height, height, p.y)
	var fade := 1.0 - smoothstep(6.0, 8.0, r_bar)
	v_t *= fade
	v_r *= fade
	v_z *= fade

	var r_dir := Vector3.ZERO
	if r > 1e-4:
		r_dir = Vector3(rel.x, 0.0, rel.y) / r
	var t_dir := swirl_sign * Vector3.UP.cross(r_dir)
	return (r_dir * v_r + t_dir * v_t + Vector3.UP * v_z) * u_max
