class_name FractalOrbit extends RefCounted
## Reference orbit for perturbation-theory deep zoom.
##
## The orbit of the view centre is iterated here and uploaded as an RGF32
## texture; the shader then only ever works with small float32 deltas. It is
## iterated in float64 up to [constant PRECISE_ZOOM] and in double-double past
## it: a float64 orbit lands on a point up to 1e-16 away from its origin, a
## different one at each recompute, which deeper than that makes the picture
## jump. It is recomputed when the view drifts away from it, when it runs out
## of iterations, or when the fractal changes.
##
## [codeblock]
## orbit.ensure(camera, julia_re, julia_im, iterations)
## material.set_shader_parameter("ref_orbit", orbit.texture)
## [/codeblock]

const TEX_WIDTH := 4096
## Zoom past which the orbit is iterated in double-double.
const PRECISE_ZOOM := 1.0e11

var texture: ImageTexture
## Iterations actually stored, 0 when nothing is cached.
var length := 0
## Reference point, a double-double like the camera centre.
var origin_x := 0.0
var origin_x_lo := 0.0
var origin_y := 0.0
var origin_y_lo := 0.0
## Julia only: orbit of 0 under z^2 + c, so a rebase (dz = z, ri = 0) is exact.
var crit_texture: ImageTexture
var crit_length := 0

var _escaped := false
var _crit_escaped := false
var _fractal_type := -1
var _julia_re := 0.0
var _julia_im := 0.0
var _precise := false


func invalidate() -> void:
	length = 0
	crit_length = 0


func ensure(camera: FractalCamera, julia_re: float, julia_im: float,
			iterations: int) -> void:
	var span := camera.span_x()
	var dx := camera.center_delta_x(origin_x, origin_x_lo)
	var dy := camera.center_delta_y(origin_y, origin_y_lo)
	var stale := length == 0 \
		or _fractal_type != camera.fractal_type \
		or _precise != (camera.zoom() > PRECISE_ZOOM) \
		or (camera.fractal_type == 1 and (_julia_re != julia_re or _julia_im != julia_im)) \
		or (not _escaped and iterations + 2 > length) \
		or (camera.fractal_type == 1 and not _crit_escaped and iterations + 2 > crit_length) \
		or (dx * dx + dy * dy) > (4.0 * span) * (4.0 * span)
	if stale:
		_compute(camera, julia_re, julia_im, iterations)


func _compute(camera: FractalCamera, julia_re: float, julia_im: float,
			iterations: int) -> void:
	origin_x = camera.center_x
	origin_x_lo = camera.center_x_lo
	origin_y = camera.center_y
	origin_y_lo = camera.center_y_lo
	_precise = camera.zoom() > PRECISE_ZOOM
	var n := int(float(iterations) * 1.25) + 64

	# Julia iterates the view centre under the constant; the others iterate 0
	# under the view centre.
	var z0 := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var c := PackedFloat64Array([origin_x, origin_x_lo, origin_y, origin_y_lo])
	if camera.fractal_type == 1:
		z0 = c
		c = PackedFloat64Array([julia_re, 0.0, julia_im, 0.0])
	var step := FractalDD.Step.QUADRATIC if camera.fractal_type <= 1 else camera.fractal_type
	var points := FractalDD.orbit(step, z0, c, n) if _precise \
		else _orbit_float64(step, z0[0], z0[2], c[0], c[2], n)
	var count := points.size() / 2
	var last := (count - 1) * 2
	var escaped := points[last] * points[last] + points[last + 1] * points[last + 1] \
		> FractalDD.ORBIT_ESCAPE2

	texture = _upload(points, count, texture)
	length = count
	_escaped = escaped

	crit_length = 0
	_crit_escaped = false
	if camera.fractal_type == 1:
		var crit := PackedFloat32Array()
		crit.resize(n * 2)
		var cx := 0.0
		var cy := 0.0
		var crit_count := 0
		for i in n:
			crit[i * 2] = cx
			crit[i * 2 + 1] = cy
			crit_count = i + 1
			if cx * cx + cy * cy > 1.0e10:
				_crit_escaped = true
				break
			var t2 := cx * cx - cy * cy + julia_re
			cy = 2.0 * cx * cy + julia_im
			cx = t2
		crit_texture = _upload(crit, crit_count, crit_texture)
		crit_length = crit_count

	_fractal_type = camera.fractal_type
	_julia_re = julia_re
	_julia_im = julia_im


## Same orbit as FractalDD.orbit, in plain float64.
static func _orbit_float64(step: int, zx: float, zy: float, cx: float, cy: float,
		count: int) -> PackedFloat32Array:
	var points := PackedFloat32Array()
	points.resize(count * 2)
	var used := 0
	for i in count:
		points[i * 2] = zx
		points[i * 2 + 1] = zy
		used = i + 1
		if zx * zx + zy * zy > FractalDD.ORBIT_ESCAPE2:
			break
		if step == FractalDD.Step.BURNING_SHIP:
			zx = absf(zx)
			zy = absf(zy)
		var t := zx * zx - zy * zy + cx
		zy = (-2.0 if step == FractalDD.Step.TRICORN else 2.0) * zx * zy + cy
		zx = t
	points.resize(used * 2)
	return points


func _upload(points: PackedFloat32Array, count: int, current: ImageTexture) -> ImageTexture:
	var rows := maxi(int(ceil(float(count) / TEX_WIDTH)), 1)
	points.resize(TEX_WIDTH * rows * 2)
	var img := Image.create_from_data(TEX_WIDTH, rows, false, Image.FORMAT_RGF,
		points.to_byte_array())

	if current != null and current.get_size() == Vector2(TEX_WIDTH, rows):
		current.update(img)
		return current
	return ImageTexture.create_from_image(img)
