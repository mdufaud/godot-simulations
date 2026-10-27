class_name TornadoWindField
extends RefCounted

## Analytical tornado wind field.
## Single source of truth for the vortex math — shaders/tornado/tornado_wind.gdshaderinc
## mirrors wind_at() line-for-line and must stay in sync (tests/tornado_wind_parity_test.gd).
##
## Tangential profiles: Burgers-Rott (Burgers 1948 / Rott 1958), Sullivan two-cell
## (Sullivan 1959) and Vatistas n=1 (Vatistas et al. 1991), each normalised to u_max at
## the radius of maximum wind (r_bar = 1). Model review: Gillmeier, Sterling, Hemida &
## Baker, JWEIA 174 (2018).
##
## The radial and vertical winds come from a Stokes stream function, so the flow
## conserves mass exactly (div u = 0) for every model, flare and height:
##   psi = u_max * s(y)^2 * a_bar * Phi(rho) * T(rho) * L(y),  rho = r / s(y)
##   v_z =  (1/r) dpsi/dr,  v_r = -(1/r) dpsi/dy
## with s(y) the flared core radius. Phi carries the published near-core structure:
## Burgers-Rott rho^2 (v_r = -a rho, v_z = 2 a z near the axis and ground, with
## a = a_bar * INFLOW_ONSET), Sullivan's
## two-cell rho^2 - (3/R^2)(1 - e^-R^2 rho^2) (axial downdraft inside rho ~ 0.42) and
## Vatistas' rho^2/(1 + rho^2); away from the core it decays like Baker & Sterling's
## (2017) model, so the inflow peaks at INFLOW_PEAK_R and fades outward. L(y) replaces
## the published models' unbounded linear z: it rises at INFLOW_ONSET per core radius
## at the ground (the near-ground corner flow that lofts debris), saturates at
## UPDRAFT_DEPTH, and closes to zero at the funnel top, where the updraft turns into
## outflow. T(rho) closes the circulation between OUTER_TAPER_R and INFLUENCE_FACTOR
## instead of cutting the field off.
##
## Optimisation: bake_wind_grid() precomputes (v_r, v_t, v_z) on a 2D (r_bar, y)
## grid once per parameter change. Debris then call sample_wind_grid() — a cheap
## bilinear lookup instead of evaluating the field per body per tick.

enum Model { VATISTAS, BURGERS_ROTT, SULLIVAN }

const NUM_SLICES := 8
const SULLIVAN_B := 3.0
## Similarity peak of the Sullivan tangential profile (2*eta*H'(eta) = H(eta) at
## eta = 6.238): the raw profile peaks 2.4976 viscous core radii out, so the bake
## rescales r_bar by this to keep "core radius = radius of maximum wind" for all models.
const SULLIVAN_RMW := 2.4976
## Peak of (1-exp(-a*r^2))/r sits at a*r^2 = root of (2x+1)*e^-x = 1, so u_max is
## the tangential speed at r_bar = 1 (the RMW convention of tornado literature).
const BR_ALPHA := 1.2564312
const BR_NORM := 1.3979525
const SULLIVAN_TABLE_SIZE := 256
const SULLIVAN_TABLE_SPAN := 8.0
## Radius (in core radii) where the radial flow peaks: just outside the RMW, as in
## tornado LES. Phi = rho^2 / (1 + (rho / INFLOW_PEAK_R)^2) has Phi/rho maximal here.
const INFLOW_PEAK_R := 1.5
## dL/dy at the ground, per core radius: the surface inflow is a_bar * INFLOW_ONSET *
## Phi/rho, i.e. 0.75 * INFLOW_ONSET * a_bar * u_max at INFLOW_PEAK_R.
const INFLOW_ONSET := 5.3
## Height (in core radii) of L's plateau: bounds the updraft at 2 a_bar UPDRAFT_DEPTH
## u_max on the axis for Burgers-Rott (twice that, downward, for Sullivan's eye).
const UPDRAFT_DEPTH := 3.0
## psi closes to zero from this fraction of the funnel height to the top.
const TOP_CLOSE_START := 0.6
## psi closes to zero between these radii (core radii); the field is 0 beyond.
const OUTER_TAPER_R := 6.0
const INFLUENCE_FACTOR := 8.0

## Wind-grid resolution: radial × vertical samples.
const WIND_GRID_R := 32
const WIND_GRID_Y := 64

## Bumped by every write to a wind input below, so the baked grid and the
## renderer's constant uniforms refresh only when a parameter actually changes.
var revision := 0
var model: int = Model.BURGERS_ROTT:
	set(value):
		model = value
		revision += 1
var u_max := 85.0:
	set(value):
		u_max = value
		revision += 1
var r_core0 := 45.0:
	set(value):
		r_core0 = value
		revision += 1
var height := 550.0:
	set(value):
		height = value
		revision += 1
var flare := 2.5:
	set(value):
		flare = value
		revision += 1
var a_bar := 0.15:
	set(value):
		a_bar = value
		revision += 1
var swirl_sign := 1.0:
	set(value):
		swirl_sign = value
		revision += 1
var base_pos := Vector3.ZERO
var slice_offsets := PackedVector2Array()

## Normalised Sullivan tangential profile, SULLIVAN_TABLE_SIZE samples over
## r_bar in [0, SULLIVAN_TABLE_SPAN]. The CPU interpolates these exact values and
## the GPU filters the same texels (half floats, filterable on every device).
var _sullivan_table := PackedFloat32Array()
var _sullivan_tex: ImageTexture
## The integral behind the table is the same for every field: built once.
static var _shared_sullivan_image: Image

## Precomputed wind grid: (v_r, v_t, v_z) in m/s at (r_bar, y) nodes.
## Layout: row-major, index = yi * WIND_GRID_R + ri.
var _wind_grid := PackedVector3Array()
var _baked_revision := -1


func _init() -> void:
	slice_offsets.resize(NUM_SLICES)
	if _shared_sullivan_image == null:
		_shared_sullivan_image = build_sullivan_image()
	var image := _shared_sullivan_image
	_sullivan_tex = ImageTexture.create_from_image(image)
	_sullivan_table.resize(SULLIVAN_TABLE_SIZE)
	for i in SULLIVAN_TABLE_SIZE:
		_sullivan_table[i] = image.get_pixel(i, 0).r
	_wind_grid.resize(WIND_GRID_R * WIND_GRID_Y)


## Bakes the normalised Sullivan tangential profile v_theta(r_bar), r_bar in
## [0, SULLIVAN_TABLE_SPAN], into a 1-row half-float image.
## H(x) = int_0^x exp(-x' + 3*int_0^x' (1-e^-t)/t dt) dx'; the raw profile peaks at
## SULLIVAN_RMW viscous core radii, so the bake samples H(SULLIVAN_RMW^2 * r_bar^2)
## and normalises by the value at r_bar = 1, like the other models.
##
## Texel i holds r_bar = SPAN * i / (SIZE - 1): the GLSL mirror reads it at
## u = (r_bar / SPAN) * (SIZE - 1) / SIZE + 0.5 / SIZE, i.e. exactly between texel
## centres, which is the interpolation sullivan_profile() does on the CPU.
static func build_sullivan_image() -> Image:
	var dx := 0.005
	# The integrand ~ x^3 e^-x is spent by x = 64: past it H is H(inf) to float precision.
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
	var v_peak := _sullivan_raw(1.0, h_samples, dx)
	var image := Image.create_empty(SULLIVAN_TABLE_SIZE, 1, false, Image.FORMAT_RH)
	for i in SULLIVAN_TABLE_SIZE:
		var r_bar := SULLIVAN_TABLE_SPAN * i / float(SULLIVAN_TABLE_SIZE - 1)
		image.set_pixel(i, 0, Color(_sullivan_raw(r_bar, h_samples, dx) / v_peak, 0.0, 0.0))
	return image


## H(R^2 r^2) / (R r) from the tabulated H, interpolated linearly in x.
static func _sullivan_raw(r_bar: float, h_samples: PackedFloat64Array, dx: float) -> float:
	if r_bar < 1e-4:
		return 0.0
	var x := SULLIVAN_RMW * SULLIVAN_RMW * r_bar * r_bar / dx
	var h := h_samples[h_samples.size() - 1]
	if x < h_samples.size() - 1:
		var i := int(x)
		h = lerpf(h_samples[i], h_samples[i + 1], x - i)
	return h / (SULLIVAN_RMW * r_bar)


## Normalised Sullivan tangential speed at r_bar (peak 1 at r_bar = 1), the same
## linear interpolation the GPU's filtered lookup performs.
func sullivan_profile(r_bar: float) -> float:
	var x := clampf(r_bar / SULLIVAN_TABLE_SPAN, 0.0, 1.0) * (SULLIVAN_TABLE_SIZE - 1)
	var i := mini(int(x), SULLIVAN_TABLE_SIZE - 2)
	return lerpf(_sullivan_table[i], _sullivan_table[i + 1], x - i)


func get_sullivan_texture() -> Texture2D:
	return _sullivan_tex


func core_radius_at(y: float) -> float:
	return r_core0 * (1.0 + flare * pow(clampf(y / height, 0.0, 1.0), 1.5))


## d core_radius_at / dy (0 outside the funnel, where the radius is clamped).
func core_radius_slope_at(y: float) -> float:
	if y <= 0.0 or y >= height:
		return 0.0
	return r_core0 * flare * 1.5 * sqrt(y / height) / height


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


# ── Precomputed wind grid ────────────────────────────────────────────────────

## Rebuilds the cylindrical wind grid when a wind input (u_max, a_bar, model,
## etc.) changed since the last bake; otherwise returns at once, so calling it
## every frame costs nothing. A rebuild is ~2K vortex evaluations in GDScript.
## The grid does not depend on base_pos or the centerline.
func bake_wind_grid() -> void:
	if _baked_revision == revision:
		return
	_baked_revision = revision
	var inv_gr: float = 1.0 / (WIND_GRID_R - 1)
	var inv_gy: float = 1.0 / (WIND_GRID_Y - 1)
	for yi in WIND_GRID_Y:
		var y := height * yi * inv_gy
		for ri in WIND_GRID_R:
			var r_bar := INFLUENCE_FACTOR * ri * inv_gr
			_wind_grid[yi * WIND_GRID_R + ri] = cylindrical_wind(r_bar, y) * u_max


## Bilinear lookup in the precomputed grid.
## r_bar: 0 .. INFLUENCE_FACTOR   y: 0 .. height
func sample_wind_grid(r_bar: float, y: float) -> Vector3:
	var fx := clampi(int(r_bar * (WIND_GRID_R - 1) / INFLUENCE_FACTOR), 0, WIND_GRID_R - 2)
	var fy := clampi(int(clampf(y, 0.0, height) / height * (WIND_GRID_Y - 1)), 0, WIND_GRID_Y - 2)

	var tx := (r_bar * (WIND_GRID_R - 1) / INFLUENCE_FACTOR) - fx
	var ty := (clampf(y, 0.0, height) / height * (WIND_GRID_Y - 1)) - fy

	var y0 := fy * WIND_GRID_R
	var y1 := (fy + 1) * WIND_GRID_R

	var v00 := _wind_grid[y0 + fx]
	var v10 := _wind_grid[y0 + fx + 1]
	var v01 := _wind_grid[y1 + fx]
	var v11 := _wind_grid[y1 + fx + 1]

	return v00.lerp(v10, tx).lerp(v01.lerp(v11, tx), ty)


# ── Reference wind_at (CPU reference; the GLSL mirror and the grid follow it) ─

## World-space tangential (x, z) direction for a unit radial direction (x, z).
## Shared convention of wind_at(), the GLSL mirror and the debris pool:
## swirl_sign * UP.cross(r_dir) — counterclockwise seen from above for +1.
static func tangent_from_radial(r_dir_x: float, r_dir_z: float, vortex_sign: float) -> Vector2:
	return Vector2(vortex_sign * r_dir_z, -vortex_sign * r_dir_x)


## Normalised tangential speed of the active model at r_bar (peak 1 at r_bar = 1).
func tangential_profile(r_bar: float) -> float:
	match model:
		Model.VATISTAS:
			return 2.0 * r_bar / (1.0 + r_bar * r_bar)
		Model.SULLIVAN:
			return sullivan_profile(r_bar)
	return BR_NORM * (1.0 - exp(-BR_ALPHA * r_bar * r_bar)) / maxf(r_bar, 1e-3)


## (Phi/rho, Phi'/rho) of the active model: both finite on the axis.
func _radial_shape(r_bar: float) -> Vector2:
	var peak := 1.0 if model == Model.VATISTAS else INFLOW_PEAK_R
	var d := 1.0 + r_bar * r_bar / (peak * peak)
	var phi_over := r_bar / d
	var dphi_over := 2.0 / (d * d)
	if model == Model.SULLIVAN:
		var e := exp(-SULLIVAN_RMW * SULLIVAN_RMW * r_bar * r_bar)
		phi_over -= SULLIVAN_B / (SULLIVAN_RMW * SULLIVAN_RMW) * (1.0 - e) / maxf(r_bar, 1e-6)
		dphi_over -= 2.0 * SULLIVAN_B * e
	return Vector2(phi_over, dphi_over)


## (v_r, v_theta, v_z) / u_max at r_bar core radii from the axis, height y.
## v_r and v_z derive from psi (see the class doc), so they are exactly
## divergence-free; v_theta(r_bar, y) is axisymmetric and adds no divergence.
func cylindrical_wind(r_bar: float, y: float) -> Vector3:
	if y < 0.0 or y > height or r_bar > INFLUENCE_FACTOR:
		return Vector3.ZERO
	var s := core_radius_at(y)
	var ds := core_radius_slope_at(y)
	# Outer taper T(rho) and its derivative.
	var taper_t := clampf((r_bar - OUTER_TAPER_R) / (INFLUENCE_FACTOR - OUTER_TAPER_R), 0.0, 1.0)
	var taper := 1.0 - taper_t * taper_t * (3.0 - 2.0 * taper_t)
	var dtaper := -6.0 * taper_t * (1.0 - taper_t) / (INFLUENCE_FACTOR - OUTER_TAPER_R)
	# Height function L(y) and dL/dy.
	var rise := exp(-INFLOW_ONSET * y / (UPDRAFT_DEPTH * r_core0))
	var close_t := clampf((y - TOP_CLOSE_START * height) / ((1.0 - TOP_CLOSE_START) * height), 0.0, 1.0)
	var close := 1.0 - close_t * close_t * (3.0 - 2.0 * close_t)
	var dclose := -6.0 * close_t * (1.0 - close_t) / ((1.0 - TOP_CLOSE_START) * height)
	var level := UPDRAFT_DEPTH * (1.0 - rise) * close
	var dlevel := (INFLOW_ONSET / r_core0) * rise * close + UPDRAFT_DEPTH * (1.0 - rise) * dclose
	var shape := _radial_shape(r_bar)
	var v_z := a_bar * level * (shape.y * taper + shape.x * dtaper)
	var v_r := -a_bar * (ds * level * (2.0 * taper * shape.x - r_bar * taper * shape.y
		- r_bar * shape.x * dtaper) + s * dlevel * taper * shape.x)
	var fade := (1.0 - smoothstep(0.85 * height, height, y)) * taper
	return Vector3(v_r, tangential_profile(r_bar) * fade, v_z)


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
	var w := cylindrical_wind(r_bar, p.y)
	var r_dir := Vector3.ZERO
	if r > 1e-4:
		r_dir = Vector3(rel.x, 0.0, rel.y) / r
	var t := tangent_from_radial(r_dir.x, r_dir.z, swirl_sign)
	var t_dir := Vector3(t.x, 0.0, t.y)
	return (r_dir * w.x + t_dir * w.y + Vector3.UP * w.z) * u_max
