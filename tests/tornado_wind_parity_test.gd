extends "res://tests/test_case.gd"
## GPU gate: the GLSL wind (shaders/tornado/tornado_wind.gdshaderinc, which drives
## the funnel, cloud and dust) must match TornadoWindField.wind_at, the CPU field
## the debris fly in. Renders tw_wind at sample points through the same uniform
## push the demo uses (TornadoRenderer.push_wind) and reads the values back.

const PARITY_SHADER := preload("res://tests/tornado_wind_parity.gdshader")
const MAX_POINTS := 64
const ENCODE_SPAN := 10.0
## In units of u_max. The CPU runs in double precision and the GPU in float, and
## the readback quantises to 10/65535: anything above this is a real mismatch.
const TOLERANCE := 0.01


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(MAX_POINTS * 3, 1)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(viewport.size)
	var material := ShaderMaterial.new()
	material.shader = PARITY_SHADER
	rect.material = material
	viewport.add_child(rect)

	var field := TornadoWindField.new()
	field.u_max = 85.0
	field.r_core0 = 45.0
	field.height = 550.0
	field.flare = 2.5
	field.a_bar = 0.2
	field.base_pos = Vector3(12.0, 0.0, -7.0)
	var noise := FastNoiseLite.new()
	noise.seed = 7
	field.update_centerline(3.0, 0.6, noise)
	var renderer := TornadoRenderer.new()
	var materials: Array[ShaderMaterial] = []
	renderer.setup(material, material, materials)

	var points := _sample_points(field)
	material.set_shader_parameter("sample_points", points)
	for model in [TornadoWindField.Model.VATISTAS, TornadoWindField.Model.BURGERS_ROTT,
			TornadoWindField.Model.SULLIVAN]:
		for swirl in [1.0, -1.0]:
			field.model = model
			field.swirl_sign = swirl
			renderer.push_wind(field)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			var worst := 0.0
			var worst_index := -1
			for index in points.size():
				var gpu := _decode(image, index)
				var cpu := field.wind_at(points[index]) / field.u_max
				var error := (gpu - cpu).abs()
				var component_error := maxf(error.x, maxf(error.y, error.z))
				if component_error > worst:
					worst = component_error
					worst_index = index
			_check(worst <= TOLERANCE,
				"model %d swirl %+d: GPU wind differs from wind_at by %.3f u_max at %s (cpu %s gpu %s)"
					% [model, int(swirl), worst, points[worst_index],
						field.wind_at(points[worst_index]) / field.u_max,
						_decode(image, worst_index)])
			print("TORNADO PARITY model=%d swirl=%+d worst=%.5f u_max" % [model, int(swirl), worst])

	viewport.queue_free()
	await process_frame
	_finish("tornado_wind_parity")


## Points across the vortex: core, eye wall, inflow ring and far field, near the
## ground and aloft, around the wandering centreline.
func _sample_points(field: TornadoWindField) -> PackedVector3Array:
	var points := PackedVector3Array()
	var heights := [3.0, 25.0, 110.0, 300.0, 520.0]
	var radii := [0.15, 0.6, 1.0, 1.7, 3.5, 7.0]
	var index := 0
	for y: float in heights:
		var c := field.centerline_at(y)
		var r_core := field.core_radius_at(y)
		for r_bar: float in radii:
			if points.size() >= MAX_POINTS:
				break
			var angle := 0.7 * index
			index += 1
			points.append(c + Vector3(cos(angle), 0.0, sin(angle)) * r_bar * r_core)
	return points


func _decode(image: Image, index: int) -> Vector3:
	var out := Vector3.ZERO
	for component in 3:
		var color := image.get_pixel(index * 3 + component, 0)
		var q := roundf(color.r * 255.0) * 256.0 + roundf(color.g * 255.0)
		out[component] = (q / 65535.0 - 0.5) * ENCODE_SPAN
	return out
