class_name FractalDE
## CPU mirror of scene() in shaders/fractal_3d.gdshader (distance only, no trap).
## Used by FreeFlyCamera for adaptive speed / soft step-clamp.
## Do NOT diverge from the GLSL: any DE change in the shader must be echoed here.
## fractal_type: 0 Pseudo-Kleinian, 1 Apollonian, 2 Menger (infinite),
##               3 Kleinian (Jos Leys).

const ONE := Vector3(1.0, 1.0, 1.0)


static func evaluate(p: Vector3, params: Dictionary) -> float:
	var fractal_type: int = params.get("fractal_type", 0)
	var iterations: int = params.get("iterations", 12)

	match fractal_type:
		0:
			return _kleinian(p, iterations, params)
		1:
			return _apollonian(p, iterations, params)
		2:
			return _menger(p, iterations)
		_:
			return _jos_kleinian(p, iterations, params)


static func _kleinian(p: Vector3, iterations: int, params: Dictionary) -> float:
	var z := p
	var w := 1.0
	var csize: Vector3 = params.get("kleinian_csize", Vector3(0.808, 0.808, 1.167))
	var minrad2: float = params.get("kleinian_minrad2", 0.25)

	for i in range(40):
		if i >= iterations:
			break
		z = z.clamp(-csize, csize) * 2.0 - z
		var r2 := z.length_squared()
		var k := maxf(minrad2 / maxf(r2, 1e-9), 1.0)
		z *= k
		w *= k

	var rxy := sqrt(z.x * z.x + z.y * z.y)
	return maxf(rxy - 0.92784, absf(rxy * z.z - 0.5) / maxf(z.length(), 1e-9)) / w


static func _apollonian(p: Vector3, iterations: int, params: Dictionary) -> float:
	var z := p
	var s := 1.0
	var scale: float = params.get("apollonian_scale", 1.3)

	for i in range(40):
		if i >= iterations:
			break
		z = -ONE + 2.0 * _fract3(0.5 * z + Vector3(0.5, 0.5, 0.5))
		var r2 := maxf(z.length_squared(), 1e-9)
		var k := scale / r2
		z *= k
		s *= k

	return 0.25 * absf(z.y) / absf(s)


static func _menger(p: Vector3, iterations: int) -> float:
	var d := -1e10
	var s := 1.0

	for i in range(10):
		if i >= iterations:
			break
		var a := _mod3(p * s, 2.0) - ONE
		s *= 3.0
		var r := (ONE - 3.0 * a.abs()).abs()
		var c := (minf(maxf(r.x, r.y), minf(maxf(r.y, r.z), maxf(r.z, r.x))) - 1.0) / s
		d = maxf(d, c)

	return d


static func _jos_kleinian(p: Vector3, iterations: int, params: Dictionary) -> float:
	var a: float = params.get("klein_r", 1.95859103011179)
	var b: float = params.get("klein_i", 0.0112785606117658)
	var bx: float = params.get("klein_box_x", 1.0)
	var bz: float = params.get("klein_box_z", 1.0)
	var z := p
	var lz := z + ONE
	var llz := z - ONE
	var df := 1.0
	var f := signf(b)

	for i in range(40):
		if i >= iterations:
			break
		z.x += b / a * z.y
		z.x = fposmod(z.x + bx, 2.0 * bx) - bx
		z.z = fposmod(z.z + bz, 2.0 * bz) - bz
		z.x -= b / a * z.y
		if z.y >= a * 0.5 + f * (2.0 * a - 1.95) / 4.0 * signf(z.x + b * 0.5) \
				* (1.0 - exp(-(7.2 - (1.95 - a) * 15.0) * absf(z.x + b * 0.5))):
			z = Vector3(-b, a, 0.0) - z
		var ir := 1.0 / maxf(z.length_squared(), 1e-12)
		z *= -ir
		z.x = -b - z.x
		z.y = a + z.y
		df *= maxf(1.0, ir)
		if (z - llz).length_squared() < 1e-5:
			break
		llz = lz
		lz = z

	var y := minf(z.y, a - z.y)
	return minf(y, 0.3) / maxf(df, 2.0)


# --- helpers ---

static func _fract(x: float) -> float:
	return x - floor(x)


static func _fract3(v: Vector3) -> Vector3:
	return Vector3(_fract(v.x), _fract(v.y), _fract(v.z))


static func _mod3(v: Vector3, m: float) -> Vector3:
	return Vector3(fposmod(v.x, m), fposmod(v.y, m), fposmod(v.z, m))
