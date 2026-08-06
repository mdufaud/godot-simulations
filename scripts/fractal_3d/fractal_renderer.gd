class_name FractalRenderer extends RefCounted

var material: ShaderMaterial
var post_material: ShaderMaterial


func setup(fractal_box: MeshInstance3D, post_process: ColorRect) -> void:
	material = fractal_box.get_active_material(0) as ShaderMaterial
	if not material:
		material = fractal_box.material_override as ShaderMaterial
	post_material = post_process.material as ShaderMaterial


func push_params(params: Dictionary) -> void:
	for key in params:
		if key == "iterations" or key == "max_steps":
			continue
		material.set_shader_parameter(key, params[key])


func apply_quality(viewport: Viewport, viewport_guard: ViewportGuard, scale: float,
		steps: int, iterations: int, profile: Dictionary, adaptive: bool, fov: float) -> void:
	if material == null:
		return
	material.set_shader_parameter("iterations", iterations)
	material.set_shader_parameter("max_steps", steps)
	material.set_shader_parameter("ao_samples", int(profile["ao_samples"]) if adaptive else 5)
	material.set_shader_parameter("pixel_tolerance",
		float(profile["pixel_tolerance"]) if adaptive else 0.08)
	viewport_guard.set_render_scale(Viewport.SCALING_3D_MODE_FSR, scale)
	var internal_height := maxf(viewport.get_visible_rect().size.y * scale, 1.0)
	var pixel_angle := 2.0 * tan(deg_to_rad(fov) * 0.5) / internal_height
	material.set_shader_parameter("pixel_angle", pixel_angle)


func set_post(values: Dictionary, enabled: bool) -> void:
	if post_material == null:
		return
	var factor := 1.0 if enabled else 0.0
	for key in values:
		post_material.set_shader_parameter(key, values[key] * factor)
