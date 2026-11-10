class_name FractalReference extends RefCounted
## Camera orbit of the 3D fractal distance estimators, for camera-relative
## raymarching.
##
## A float32 shader cannot hold a world position finer than ~1e-7, which ends
## the zoom three decades in. Instead the camera's own orbit through the
## estimator is iterated here in float64 and uploaded; the shader carries only
## the offset of each ray point from the camera through the same maps (every
## step is a translation, a reflection or a sphere inversion, all of which have
## a cancellation-free offset form), so its precision is relative to the ray
## length at any depth. Same idea as the 2D explorer's perturbation orbit.
##
## The maps are those of FractalDE; [method relative_distance] is the CPU
## mirror of the shader's offset form, which tests/fractal_reference_test.gd
## holds equal to FractalDE.
##
## Rows per iteration i (the shader's uniform arrays ref_a..ref_e):
##   Apollonian  a = (folded Z, |folded Z|^2)   e = (Z before the fold, 0)
##   Menger      a = fraction, b = cell (0..5) of 3 * (Z * 3^i mod 2)
##   Kleinian    a = (sheared wrapped x, wrapped z, flipped 0/1, |V|^2)
##               b = W (after the wrap)   c = C - 2W   d = V (after the flip)
##               e = (Z before the step, a - Z.y)
## with one more e row for the value after the last iteration.
##
## [codeblock]
## reference.update(camera_x, camera_y, camera_z, params)
## material.set_shader_parameter("ref_a", reference.a)
## [/codeblock]

const ROWS := 65

var a := PackedVector4Array()
var b := PackedVector4Array()
var c := PackedVector4Array()
var d := PackedVector4Array()
var e := PackedVector4Array()

# Float64 copies of the rows, which the float32 arrays above cannot stand in
# for in the mirror.
var _a := PackedFloat64Array()
var _b := PackedFloat64Array()
var _c := PackedFloat64Array()
var _d := PackedFloat64Array()
var _e := PackedFloat64Array()


func _init() -> void:
	for rows: PackedVector4Array in [a, b, c, d, e]:
		rows.resize(ROWS)
	for rows: PackedFloat64Array in [_a, _b, _c, _d, _e]:
		rows.resize(ROWS * 4)


func update(x: float, y: float, z: float, params: Dictionary) -> void:
	match int(params.get("fractal_type", 0)):
		0:
			_update_apollonian(x, y, z, params.get("apollonian_scale", 1.3))
		1:
			_update_menger(x, y, z)
		_:
			_update_kleinian(x, y, z, params.get("klein_r", 1.95859103011179),
				params.get("klein_i", 0.0112785606117658), params.get("klein_box_x", 1.0),
				params.get("klein_box_z", 1.0))
	for i in ROWS:
		var k := i * 4
		a[i] = Vector4(_a[k], _a[k + 1], _a[k + 2], _a[k + 3])
		b[i] = Vector4(_b[k], _b[k + 1], _b[k + 2], _b[k + 3])
		c[i] = Vector4(_c[k], _c[k + 1], _c[k + 2], _c[k + 3])
		d[i] = Vector4(_d[k], _d[k + 1], _d[k + 2], _d[k + 3])
		e[i] = Vector4(_e[k], _e[k + 1], _e[k + 2], _e[k + 3])


## Distance at the camera plus (dx, dy, dz), through the offset form the shader
## uses. Same iteration counts and stops as FractalDE.evaluate_at.
func relative_distance(dx: float, dy: float, dz: float, params: Dictionary) -> float:
	var iterations: int = params.get("iterations", 12)
	var detail_iterations: int = params.get("detail_iterations", 0)
	match int(params.get("fractal_type", 0)):
		0:
			return _relative_apollonian(dx, dy, dz, iterations, detail_iterations,
				params.get("apollonian_scale", 1.3))
		1:
			return _relative_menger(dx, dy, dz, iterations + detail_iterations)
		_:
			return _relative_kleinian(dx, dy, dz, iterations + detail_iterations,
				params.get("klein_r", 1.95859103011179),
				params.get("klein_i", 0.0112785606117658), params.get("klein_box_x", 1.0),
				params.get("klein_box_z", 1.0))


static func _put(rows: PackedFloat64Array, i: int, x: float, y: float, z: float,
		w: float) -> void:
	rows[i * 4] = x
	rows[i * 4 + 1] = y
	rows[i * 4 + 2] = z
	rows[i * 4 + 3] = w


func _update_apollonian(x: float, y: float, z: float, scale: float) -> void:
	for i in ROWS:
		_put(_e, i, x, y, z, 0.0)
		x = -1.0 + 2.0 * FractalDE._fract(0.5 * x + 0.5)
		y = -1.0 + 2.0 * FractalDE._fract(0.5 * y + 0.5)
		z = -1.0 + 2.0 * FractalDE._fract(0.5 * z + 0.5)
		var r2 := maxf(x * x + y * y + z * z, 1e-9)
		_put(_a, i, x, y, z, r2)
		var k := scale / r2
		x *= k
		y *= k
		z *= k


func _relative_apollonian(dx: float, dy: float, dz: float, iterations: int,
		detail_iterations: int, scale: float) -> float:
	var s := 1.0
	var x1 := _e[0] + dx + 1.0
	var y1 := _e[1] + dy + 1.0
	var z1 := _e[2] + dz + 1.0
	var x2 := x1 - 2.0
	var y2 := y1 - 2.0
	var z2 := z1 - 2.0
	var total := mini(iterations + detail_iterations, FractalDE.APOLLONIAN_MAX_ITERATIONS)
	var last := 0
	for i in total:
		var k4 := i * 4
		var px := _e[k4] + dx
		var py := _e[k4 + 1] + dy
		var pz := _e[k4 + 2] + dz
		if i >= iterations and ((i - iterations) & 1) == 0:
			var mx := px - x2
			var my := py - y2
			var mz := pz - z2
			if mx * mx + my * my + mz * mz < FractalDE.CYCLE_EPSILON2:
				break
		x2 = x1
		y2 = y1
		z2 = z1
		x1 = px
		y1 = py
		z1 = pz
		# Fold: the offset only changes by the cell the point lands in.
		var fx := _a[k4]
		var fy := _a[k4 + 1]
		var fz := _a[k4 + 2]
		var r2_ref := _a[k4 + 3]
		dx -= 2.0 * floor(0.5 * (fx + dx) + 0.5)
		dy -= 2.0 * floor(0.5 * (fy + dy) + 0.5)
		dz -= 2.0 * floor(0.5 * (fz + dz) + 0.5)
		var wx := fx + dx
		var wy := fy + dy
		var wz := fz + dz
		var r2 := maxf(wx * wx + wy * wy + wz * wz, 1e-9)
		# Inversion: k w - K Z without subtracting two near-equal vectors.
		var cross := 2.0 * (fx * dx + fy * dy + fz * dz) + dx * dx + dy * dy + dz * dz
		var scale_over := scale / (r2_ref * r2)
		dx = scale_over * (dx * r2_ref - fx * cross)
		dy = scale_over * (dy * r2_ref - fy * cross)
		dz = scale_over * (dz * r2_ref - fz * cross)
		s *= scale / r2
		last = i + 1
	return 0.25 * absf(_e[last * 4 + 1] + dy) / absf(s)


func _update_menger(x: float, y: float, z: float) -> void:
	var s := 1.0
	for i in FractalDE.MENGER_MAX_ITERATIONS:
		var ux := 3.0 * fposmod(x * s, 2.0) - 3.0
		var uy := 3.0 * fposmod(y * s, 2.0) - 3.0
		var uz := 3.0 * fposmod(z * s, 2.0) - 3.0
		_put(_a, i, ux - roundf(ux), uy - roundf(uy), uz - roundf(uz), 0.0)
		_put(_b, i, fposmod(roundf(ux), 6.0), fposmod(roundf(uy), 6.0), fposmod(roundf(uz), 6.0), 0.0)
		s *= 3.0


# |1 - |u|| - 1 for u = cell + f (cell in 0..5, period 6), with no subtraction
# between cell-sized terms: every wall of the sponge sits on an integer u.
static func _menger_axis(cell: float, f: float) -> float:
	if cell < 0.5:
		return -absf(f)
	if cell < 1.5 or cell > 4.5:
		return absf(f) - 1.0
	if cell < 2.5:
		return f
	if cell < 3.5:
		return 1.0 - absf(f)
	return -f


# Reads the float32 rows the shader gets: their rounding is part of the check.
func _relative_menger(dx: float, dy: float, dz: float, iterations: int) -> float:
	var dist := -1e10
	var s := 1.0
	for i in mini(iterations, FractalDE.MENGER_MAX_ITERATIONS):
		var fx := a[i].x + 3.0 * dx * s
		var fy := a[i].y + 3.0 * dy * s
		var fz := a[i].z + 3.0 * dz * s
		var gx := _menger_axis(fposmod(b[i].x + roundf(fx), 6.0), fx - roundf(fx))
		var gy := _menger_axis(fposmod(b[i].y + roundf(fy), 6.0), fy - roundf(fy))
		var gz := _menger_axis(fposmod(b[i].z + roundf(fz), 6.0), fz - roundf(fz))
		s *= 3.0
		dist = maxf(dist, minf(maxf(gx, gy), minf(maxf(gy, gz), maxf(gz, gx))) / s)
	return dist


static func _klein_flips(x: float, y: float, a_: float, b_: float) -> bool:
	return y >= a_ * 0.5 + signf(b_) * (2.0 * a_ - 1.95) / 4.0 * signf(x + b_ * 0.5) \
		* (1.0 - exp(-(7.2 - (1.95 - a_) * 15.0) * absf(x + b_ * 0.5)))


func _update_kleinian(x: float, y: float, z: float, a_: float, b_: float, bx: float,
		bz: float) -> void:
	for i in ROWS:
		_put(_e, i, x, y, z, a_ - y)
		var sheared := fposmod(x + b_ / a_ * y + bx, 2.0 * bx) - bx
		z = fposmod(z + bz, 2.0 * bz) - bz
		x = sheared - b_ / a_ * y
		_put(_b, i, x, y, z, 0.0)
		_put(_c, i, -b_ - 2.0 * x, a_ - 2.0 * y, -2.0 * z, 0.0)
		var flips := _klein_flips(x, y, a_, b_)
		if flips:
			x = -b_ - x
			y = a_ - y
			z = -z
		_put(_d, i, x, y, z, 0.0)
		var r2 := maxf(x * x + y * y + z * z, 1e-12)
		_put(_a, i, sheared, _b[i * 4 + 2], 1.0 if flips else 0.0, r2)
		var ir := 1.0 / r2
		x = -b_ + ir * x
		y = a_ - ir * y
		z = -ir * z


func _relative_kleinian(dx: float, dy: float, dz: float, iterations: int, a_: float,
		b_: float, bx: float, bz: float) -> float:
	var lx := _e[0] + dx + 1.0
	var ly := _e[1] + dy + 1.0
	var lz := _e[2] + dz + 1.0
	var llx := lx - 2.0
	var lly := ly - 2.0
	var llz := lz - 2.0
	var df := 1.0
	var last := 0
	for i in mini(iterations, FractalDE.KLEIN_MAX_ITERATIONS):
		var k4 := i * 4
		# Shear, wrap by whole cells, unshear: translations only.
		var sx := dx + b_ / a_ * dy
		sx -= 2.0 * bx * floor((_a[k4] + sx + bx) / (2.0 * bx))
		dz -= 2.0 * bz * floor((_a[k4 + 1] + dz + bz) / (2.0 * bz))
		dx = sx - b_ / a_ * dy
		# Point reflection about C / 2, on the point's own side of the line.
		var flips := _klein_flips(_b[k4] + dx, _b[k4 + 1] + dy, a_, b_)
		var reference_flips := _a[k4 + 2] > 0.5
		if flips and reference_flips:
			dx = -dx
			dy = -dy
			dz = -dz
		elif flips:
			dx = _c[k4] - dx
			dy = _c[k4 + 1] - dy
			dz = _c[k4 + 2] - dz
		elif reference_flips:
			dx -= _c[k4]
			dy -= _c[k4 + 1]
			dz -= _c[k4 + 2]
		# Inversion, then the mirror of x: offsets of -b + ir v.x, a - ir v.y, -ir v.z.
		var vx := _d[k4]
		var vy := _d[k4 + 1]
		var vz := _d[k4 + 2]
		var r2_ref := _a[k4 + 3]
		var wx := vx + dx
		var wy := vy + dy
		var wz := vz + dz
		var r2 := maxf(wx * wx + wy * wy + wz * wz, 1e-12)
		var cross := 2.0 * (vx * dx + vy * dy + vz * dz) + dx * dx + dy * dy + dz * dz
		var over := 1.0 / (r2_ref * r2)
		var qx := over * (dx * r2_ref - vx * cross)
		var qy := over * (dy * r2_ref - vy * cross)
		var qz := over * (dz * r2_ref - vz * cross)
		dx = qx
		dy = -qy
		dz = -qz
		df *= maxf(1.0, 1.0 / r2)
		last = i + 1
		var px := _e[last * 4] + dx
		var py := _e[last * 4 + 1] + dy
		var pz := _e[last * 4 + 2] + dz
		var ex := px - llx
		var ey := py - lly
		var ez := pz - llz
		if ex * ex + ey * ey + ez * ez < 1e-5:
			break
		llx = lx
		lly = ly
		llz = lz
		lx = px
		ly = py
		lz = pz
	var top := minf(_e[last * 4 + 1] + dy, _e[last * 4 + 3] - dy)
	return minf(top, 0.3) / maxf(df, 2.0)
