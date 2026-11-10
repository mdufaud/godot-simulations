class_name FractalDE
## CPU distance estimators of shaders/fractal_3d/fractal_3d.gdshader (distance
## only, no trap), in float64: the flight of FreeFlyCamera and the collision
## bound stay exact down to scales a float32 position cannot hold.
## Do NOT diverge from the GLSL, from FractalReference (the same maps, taken
## relative to the camera) or from FractalKernels (the C++ port, bit-identical).
## fractal_type: 0 Apollonian, 1 Menger (infinite), 2 Kleinian (Jos Leys).
##
## params: "iterations" is the base count, "detail_iterations" what the shader
## may add where the features are larger than a pixel; the estimators here run
## them all, the shader's level-of-detail cut only drops sub-pixel features.

const APOLLONIAN_MAX_ITERATIONS := 64
const MENGER_MAX_ITERATIONS := 26
const KLEIN_MAX_ITERATIONS := 64
## Squared move of z over two iterations under which the Apollonian orbit sits
## on its 2-cycle: the point is in a void and further iterations add nothing.
const CYCLE_EPSILON2 := 1e-10

static var _native := Native.kernel(&"FractalKernels")


static func evaluate(p: Vector3, params: Dictionary) -> float:
	return evaluate_at(p.x, p.y, p.z, params)


static func evaluate_at(x: float, y: float, z: float, params: Dictionary) -> float:
	var fractal_type: int = params.get("fractal_type", 0)
	var iterations: int = params.get("iterations", 12)
	var detail_iterations: int = params.get("detail_iterations", 0)
	var scale: float = params.get("apollonian_scale", 1.3)
	var klein_r: float = params.get("klein_r", 1.95859103011179)
	var klein_i: float = params.get("klein_i", 0.0112785606117658)
	var klein_box_x: float = params.get("klein_box_x", 1.0)
	var klein_box_z: float = params.get("klein_box_z", 1.0)
	if Native.enabled and _native != null and _native.has_method(&"evaluate_at"):
		return _native.evaluate_at(x, y, z, fractal_type, iterations, detail_iterations,
			scale, klein_r, klein_i, klein_box_x, klein_box_z)

	match fractal_type:
		0:
			return _apollonian(x, y, z, iterations, detail_iterations, scale)
		1:
			return _menger(x, y, z, iterations + detail_iterations)
		_:
			return _jos_kleinian(x, y, z, iterations + detail_iterations, klein_r, klein_i,
				klein_box_x, klein_box_z)


static func _apollonian(x: float, y: float, z: float, iterations: int,
		detail_iterations: int, scale: float) -> float:
	var s := 1.0
	var x1 := x + 1.0
	var y1 := y + 1.0
	var z1 := z + 1.0
	var x2 := x - 1.0
	var y2 := y - 1.0
	var z2 := z - 1.0
	var total := mini(iterations + detail_iterations, APOLLONIAN_MAX_ITERATIONS)

	for i in total:
		# Left on the parity of the base count, whose estimate it keeps.
		if i >= iterations and ((i - iterations) & 1) == 0:
			var dx := x - x2
			var dy := y - y2
			var dz := z - z2
			if dx * dx + dy * dy + dz * dz < CYCLE_EPSILON2:
				break
		x2 = x1
		y2 = y1
		z2 = z1
		x1 = x
		y1 = y
		z1 = z
		x = -1.0 + 2.0 * _fract(0.5 * x + 0.5)
		y = -1.0 + 2.0 * _fract(0.5 * y + 0.5)
		z = -1.0 + 2.0 * _fract(0.5 * z + 0.5)
		var r2 := maxf(x * x + y * y + z * z, 1e-9)
		var k := scale / r2
		x *= k
		y *= k
		z *= k
		s *= k

	return 0.25 * absf(y) / absf(s)


static func _menger(x: float, y: float, z: float, iterations: int) -> float:
	var d := -1e10
	var s := 1.0
	var total := mini(iterations, MENGER_MAX_ITERATIONS)

	for i in total:
		var ax := fposmod(x * s, 2.0) - 1.0
		var ay := fposmod(y * s, 2.0) - 1.0
		var az := fposmod(z * s, 2.0) - 1.0
		s *= 3.0
		var rx := absf(1.0 - 3.0 * absf(ax))
		var ry := absf(1.0 - 3.0 * absf(ay))
		var rz := absf(1.0 - 3.0 * absf(az))
		var c := (minf(maxf(rx, ry), minf(maxf(ry, rz), maxf(rz, rx))) - 1.0) / s
		d = maxf(d, c)

	return d


static func _jos_kleinian(x: float, y: float, z: float, iterations: int, a: float, b: float,
		bx: float, bz: float) -> float:
	var lx := x + 1.0
	var ly := y + 1.0
	var lz := z + 1.0
	var llx := x - 1.0
	var lly := y - 1.0
	var llz := z - 1.0
	var df := 1.0
	var f := signf(b)
	var total := mini(iterations, KLEIN_MAX_ITERATIONS)

	for i in total:
		x += b / a * y
		x = fposmod(x + bx, 2.0 * bx) - bx
		z = fposmod(z + bz, 2.0 * bz) - bz
		x -= b / a * y
		if y >= a * 0.5 + f * (2.0 * a - 1.95) / 4.0 * signf(x + b * 0.5) \
				* (1.0 - exp(-(7.2 - (1.95 - a) * 15.0) * absf(x + b * 0.5))):
			x = -b - x
			y = a - y
			z = -z
		var ir := 1.0 / maxf(x * x + y * y + z * z, 1e-12)
		x *= -ir
		y *= -ir
		z *= -ir
		x = -b - x
		y = a + y
		df *= maxf(1.0, ir)
		var ex := x - llx
		var ey := y - lly
		var ez := z - llz
		if ex * ex + ey * ey + ez * ez < 1e-5:
			break
		llx = lx
		lly = ly
		llz = lz
		lx = x
		ly = y
		lz = z

	var top := minf(y, a - y)
	return minf(top, 0.3) / maxf(df, 2.0)


static func _fract(x: float) -> float:
	return x - floor(x)
