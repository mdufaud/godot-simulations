class_name FractalDD extends RefCounted
## Double-double arithmetic: a value held as a float64 plus the float64 error
## its rounding left behind (hi + lo, |lo| <= ulp(hi) / 2), about 31 significant
## digits. Error-free transforms after Dekker and Knuth; no FMA, so the C++
## kernels (FractalKernels, built with -ffp-contract=off) round the same.
##
## [codeblock]
## var sum := FractalDD.add(a_hi, a_lo, b_hi, b_lo)   # [hi, lo]
## [/codeblock]

## 2^27 + 1: splits a float64 into two 26-bit halves.
const SPLITTER := 134217729.0
## Orbit bailout, squared: far past any escape radius the shader tests.
const ORBIT_ESCAPE2 := 1.0e10

## Orbit step: 0 z^2 + c, 2 burning ship (|x|, |y| first), 3 tricorn (conjugate).
enum Step { QUADRATIC = 0, BURNING_SHIP = 2, TRICORN = 3 }

static var _native := Native.kernel(&"FractalKernels")


static func add(a: float, a_lo: float, b: float, b_lo: float) -> PackedFloat64Array:
	var s := a + b
	var bb := s - a
	var e := (a - (s - bb)) + (b - bb)
	e += a_lo + b_lo
	var hi := s + e
	return PackedFloat64Array([hi, e - (hi - s)])


## Orbit of z0 under the [param step] map, iterated in double-double and
## returned as float32 (x, y) pairs: [param count] points at most, cut after
## the first one past the bailout.
static func orbit(step: int, z0: PackedFloat64Array, c: PackedFloat64Array,
		count: int) -> PackedFloat32Array:
	if Native.enabled and _native != null and _native.has_method(&"orbit"):
		return _native.orbit(step, z0, c, count)

	var points := PackedFloat32Array()
	points.resize(count * 2)
	var x := z0[0]
	var xl := z0[1]
	var y := z0[2]
	var yl := z0[3]
	var cx := c[0]
	var cxl := c[1]
	var cy := c[2]
	var cyl := c[3]
	var used := 0
	for i in count:
		points[i * 2] = x
		points[i * 2 + 1] = y
		used = i + 1
		if x * x + y * y > ORBIT_ESCAPE2:
			break
		if step == Step.BURNING_SHIP:
			if x < 0.0:
				x = -x
				xl = -xl
			if y < 0.0:
				y = -y
				yl = -yl

		# x^2, y^2 and x*y as double-doubles (Dekker products).
		var t := SPLITTER * x
		var xh := t - (t - x)
		var xt := x - xh
		t = SPLITTER * y
		var yh := t - (t - y)
		var yt := y - yh

		var xx := x * x
		var xx_lo := ((xh * xh - xx) + 2.0 * xh * xt) + xt * xt
		xx_lo += 2.0 * x * xl
		var yy := y * y
		var yy_lo := ((yh * yh - yy) + 2.0 * yh * yt) + yt * yt
		yy_lo += 2.0 * y * yl
		var xy := x * y
		var xy_lo := ((xh * yh - xy) + xh * yt + xt * yh) + xt * yt
		xy_lo += x * yl + xl * y

		# re = x^2 - y^2 + cx
		var s := xx - yy
		var bb := s - xx
		var e := (xx - (s - bb)) + (-yy - bb)
		e += xx_lo - yy_lo
		var re := s + e
		var re_lo := e - (re - s)
		s = re + cx
		bb = s - re
		e = (re - (s - bb)) + (cx - bb)
		e += re_lo + cxl
		var nx := s + e
		var nxl := e - (nx - s)

		# im = +-2xy + cy
		var im := 2.0 * xy
		var im_lo := 2.0 * xy_lo
		if step == Step.TRICORN:
			im = -im
			im_lo = -im_lo
		s = im + cy
		bb = s - im
		e = (im - (s - bb)) + (cy - bb)
		e += im_lo + cyl
		var ny := s + e
		var nyl := e - (ny - s)

		x = nx
		xl = nxl
		y = ny
		yl = nyl
	points.resize(used * 2)
	return points
