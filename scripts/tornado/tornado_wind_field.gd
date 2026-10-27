class_name TornadoWindField
extends RefCounted

## Analytical tornado wind field.
## Single source of truth for the vortex math — shaders/tornado/tornado_wind.gdshaderinc
## mirrors wind_at() line-for-line and must stay in sync.
##
## Profiles: Burgers-Rott (Burgers 1948 / Rott 1958), Sullivan two-cell (Sullivan 1959)
## and a Vatistas n=1 tangential core (Vatistas et al. 1991; same shape as Burnham-Hallock).
## Radial inflow peaks just outside the core radius and is ground-weighted; the near-ground
## annular updraft jet follows the corner-flow picture of Lewellen & Lewellen (2007).
## For the model family review see Gillmeier, Sterling, Hemida & Baker, JWEIA 174 (2018).
##
## Optimisation: bake_wind_grid() precomputes (v_r, v_t, v_z) on a 2D (r_bar, y)
## grid once per frame.  Debris then calls sample_wind_grid() — a cheap bilinear
## lookup instead of evaluating exp/smoothstep per-body per-tick.

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
const R_BAR_MAX := 4.0
const SULLIVAN_TABLE_SIZE := 256
const SULLIVAN_TABLE_SPAN := 8.0
## Inflow shape: (r/1.5)*exp(1 - r/1.5) peaks at INFLOW_PEAK_R (just outside the RMW,
## as in tornado LES) with magnitude a_bar * R_BAR_MAX at the surface, then decays.
const INFLOW_PEAK_R := 1.5
## Aloft the inflow relaxes to this fraction of its surface value (LES: near-ground max).
const INFLOW_GROUND_FLOOR := 0.45
const Z_BAR_CAP := 6.0
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
		var r_core := core_radius_at(y)
		var z_bar := minf(y / r_core, Z_BAR_CAP)
		var z_eff := Z_BAR_CAP * (1.0 - exp(-0.8 * z_bar))
		var inflow_z := INFLOW_GROUND_FLOOR \
			+ (1.0 - INFLOW_GROUND_FLOOR) * exp(-0.9 * z_bar)
		var top_fade := 1.0 - smoothstep(0.85 * height, height, y)

		for ri in WIND_GRID_R:
			var r_bar := INFLUENCE_FACTOR * ri * inv_gr
			var r_safe := maxf(r_bar, 1e-3)
			var inflow_r := (r_bar / INFLOW_PEAK_R) * exp(1.0 - r_bar / INFLOW_PEAK_R)

			var v_t := 0.0
			var v_r := 0.0
			var v_z := 0.0
			match model:
				Model.VATISTAS:
					v_t = 2.0 * r_bar / (1.0 + r_bar * r_bar)
				Model.BURGERS_ROTT:
					v_t = BR_NORM * (1.0 - exp(-BR_ALPHA * r_bar * r_bar)) / r_safe
					v_r = -a_bar * R_BAR_MAX * inflow_r * inflow_z
					v_z = 2.0 * a_bar * z_eff * exp(-0.25 * r_bar * r_bar)
				Model.SULLIVAN:
					var e := exp(-SULLIVAN_RMW * SULLIVAN_RMW * r_bar * r_bar)
					v_t = sullivan_profile(r_bar)
					v_r = a_bar * (-R_BAR_MAX * inflow_r * inflow_z
						+ (SULLIVAN_B / (SULLIVAN_RMW * r_safe)) * (1.0 - e))
					v_z = 2.0 * a_bar * z_eff * (1.0 - SULLIVAN_B * e) \
						* exp(-0.15 * SULLIVAN_RMW * SULLIVAN_RMW * r_bar * r_bar)

			# Corner flow (Lewellen): annular near-ground updraft jet at the RMW.
			if model != Model.VATISTAS:
				var dr := (r_bar - 1.0) / 0.45
				v_z += 2.5 * a_bar * exp(-dr * dr) * (1.0 - exp(-8.0 * z_bar)) * exp(-0.5 * z_bar)

			var fade := top_fade * (1.0 - smoothstep(6.0, 8.0, r_bar))
			v_t *= fade
			v_r *= fade
			v_z *= fade

			_wind_grid[yi * WIND_GRID_R + ri] = Vector3(v_r, v_t, v_z) * u_max


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
	# Ground-weighted inflow: full surface strength, relaxing aloft (LES corner region).
	var inflow_z := INFLOW_GROUND_FLOOR + (1.0 - INFLOW_GROUND_FLOOR) * exp(-0.9 * z_bar)
	var r_safe := maxf(r_bar, 1e-3)
	var inflow_r := (r_bar / INFLOW_PEAK_R) * exp(1.0 - r_bar / INFLOW_PEAK_R)
	var sv2 := SULLIVAN_RMW * SULLIVAN_RMW * r_bar * r_bar

	var v_t := 0.0
	var v_r := 0.0
	var v_z := 0.0
	match model:
		# Vatistas n=1 tangential core, radial/vertical both zero: debris orbit but
		# never loft under this profile.
		Model.VATISTAS:
			v_t = 2.0 * r_bar / (1.0 + r_bar * r_bar)
		Model.BURGERS_ROTT:
			v_t = BR_NORM * (1.0 - exp(-BR_ALPHA * r_bar * r_bar)) / r_safe
			v_r = -a_bar * R_BAR_MAX * inflow_r * inflow_z
			v_z = 2.0 * a_bar * z_eff * exp(-0.25 * r_bar * r_bar)
		Model.SULLIVAN:
			var e := exp(-sv2)
			v_t = sullivan_profile(r_bar)
			v_r = a_bar * (-R_BAR_MAX * inflow_r * inflow_z + (SULLIVAN_B / (SULLIVAN_RMW * r_safe)) * (1.0 - e))
			v_z = 2.0 * a_bar * z_eff * (1.0 - SULLIVAN_B * e) * exp(-0.15 * sv2)

	# Corner flow (Lewellen): annular near-ground updraft jet at the core wall —
	# this is what lofts debris; absent from the inviscid models.
	if model != Model.VATISTAS:
		var dr := (r_bar - 1.0) / 0.45
		v_z += 2.5 * a_bar * exp(-dr * dr) * (1.0 - exp(-8.0 * z_bar)) * exp(-0.5 * z_bar)

	var fade := (1.0 - smoothstep(0.85 * height, height, p.y)) * (1.0 - smoothstep(6.0, 8.0, r_bar))
	v_t *= fade
	v_r *= fade
	v_z *= fade

	var r_dir := Vector3.ZERO
	if r > 1e-4:
		r_dir = Vector3(rel.x, 0.0, rel.y) / r
	var t := tangent_from_radial(r_dir.x, r_dir.z, swirl_sign)
	var t_dir := Vector3(t.x, 0.0, t.y)
	return (r_dir * v_r + t_dir * v_t + Vector3.UP * v_z) * u_max
