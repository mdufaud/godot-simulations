class_name FractalOrbit extends RefCounted
## Reference orbit for perturbation-theory deep zoom.
##
## The orbit of the view centre is iterated here in float64 and uploaded as an
## RGF32 texture; the shader then only ever works with small float32 deltas.
## It is recomputed when the view drifts away from it, when it runs out of
## iterations, or when the fractal changes.
##
## [codeblock]
## orbit.ensure(camera, julia_re, julia_im, iterations)
## material.set_shader_parameter("ref_orbit", orbit.texture)
## [/codeblock]

const TEX_WIDTH := 4096

var texture: ImageTexture
## Iterations actually stored, 0 when nothing is cached.
var length := 0
var origin_x := 0.0
var origin_y := 0.0

var _escaped := false
var _fractal_type := -1
var _julia_re := 0.0
var _julia_im := 0.0


func invalidate() -> void:
	length = 0


func ensure(camera: FractalCamera, julia_re: float, julia_im: float,
		iterations: int) -> void:
	var span := camera.span_x()
	var dx := camera.center_x - origin_x
	var dy := camera.center_y - origin_y
	var stale := length == 0 \
		or _fractal_type != camera.fractal_type \
		or (camera.fractal_type == 1 and (_julia_re != julia_re or _julia_im != julia_im)) \
		or (not _escaped and iterations + 2 > length) \
		or (dx * dx + dy * dy) > (4.0 * span) * (4.0 * span)
	if stale:
		_compute(camera, julia_re, julia_im, iterations)


func _compute(camera: FractalCamera, julia_re: float, julia_im: float,
		iterations: int) -> void:
	origin_x = camera.center_x
	origin_y = camera.center_y
	var n := int(float(iterations) * 1.25) + 64
	var points := PackedFloat32Array()
	points.resize(n * 2)

	var zx := 0.0
	var zy := 0.0
	var ccx := origin_x
	var ccy := origin_y
	if camera.fractal_type == 1:
		zx = origin_x
		zy = origin_y
		ccx = julia_re
		ccy = julia_im

	var count := 0
	var escaped := false
	for i in n:
		points[i * 2] = zx
		points[i * 2 + 1] = zy
		count = i + 1
		if zx * zx + zy * zy > 1.0e10:
			escaped = true
			break
		var t := zx * zx - zy * zy + ccx
		zy = 2.0 * zx * zy + ccy
		zx = t

	var rows := maxi(int(ceil(float(count) / TEX_WIDTH)), 1)
	points.resize(TEX_WIDTH * rows * 2)
	var img := Image.create_from_data(TEX_WIDTH, rows, false, Image.FORMAT_RGF,
		points.to_byte_array())

	if texture != null and texture.get_size() == Vector2(TEX_WIDTH, rows):
		texture.update(img)
	else:
		texture = ImageTexture.create_from_image(img)

	length = count
	_escaped = escaped
	_fractal_type = camera.fractal_type
	_julia_re = julia_re
	_julia_im = julia_im
