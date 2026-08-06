class_name FractalView extends RefCounted
## Two-pass fractal render pipeline.
##
## Pass 1 ([code]fractal.gdshader[/code], in the two SubViewports) computes
## iteration data only when the view changes: the low viewport is a half-res
## live preview while moving, the high viewport refines at full res in bands.
## Pass 2 ([code]fractal_colorize.gdshader[/code], on the display rect) maps
## that data to colour every frame.
##
## The host must assign every field above [method start], which asserts them:
##
## [codeblock]
## var view := FractalView.new()
## view.camera = camera
## view.view_low = $ViewLow
## view.view_high = $ViewHigh
## view.rect_low = $ViewLow/Rect
## view.rect_high = $ViewHigh/Rect
## view.display = $Display
## view.host = self
## view.start()
## [/codeblock]

enum State { MOVING, REFINING, IDLE }

## Beyond this zoom float32 runs out and the shader switches to perturbation.
const PERT_ZOOM_THRESHOLD := 1.0e3
## Iteration ceiling of the live preview, so dragging stays responsive.
const INTERACT_ITER_CAP := 1200
const REFINE_BAND_ROWS := 256
## Seconds of stillness before the full-res refinement starts.
const SETTLE_TIME := 0.25

var camera: FractalCamera
var view_low: SubViewport
var view_high: SubViewport
var rect_low: ColorRect
var rect_high: ColorRect
var display: ColorRect
## Node the blend tween is created on.
var host: Node

var julia_re := -0.7269
var julia_im := 0.1889
var julia_morph := false
var trap_shape := 0
var trap_scale := 1.0
var aa_quality := 2

var state := State.MOVING

var _orbit := FractalOrbit.new()
var _material_low: ShaderMaterial
var _material_high: ShaderMaterial
var _material_display: ShaderMaterial
var _settle := 0.0
var _refine_row := 0
var _last_hash := 0
var _julia_theta := 0.0
var _blend_tween: Tween


func start() -> void:
	assert(camera != null, "FractalView: camera is required")
	assert(view_low != null and view_high != null, "FractalView: both SubViewports are required")
	assert(rect_low != null and rect_high != null, "FractalView: both pass-1 rects are required")
	assert(display != null and host != null, "FractalView: display rect and host are required")

	_material_low = rect_low.material as ShaderMaterial
	_material_high = rect_high.material as ShaderMaterial
	_material_display = display.material as ShaderMaterial

	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view_high.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	view_low.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view_high.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_material_display.set_shader_parameter("tex_low", view_low.get_texture())
	_material_display.set_shader_parameter("tex_high", view_high.get_texture())


func resize(window_size: Vector2i) -> void:
	view_high.size = Vector2i(maxi(window_size.x, 8), maxi(window_size.y, 8))
	view_low.size = Vector2i(maxi(window_size.x / 2, 4), maxi(window_size.y / 2, 4))
	rect_high.size = Vector2(view_high.size)
	rect_low.size = Vector2(view_low.size)


func set_julia_morph(enabled: bool) -> void:
	julia_morph = enabled
	if enabled:
		_julia_theta = atan2(julia_im, julia_re)


func set_display_parameter(parameter: StringName, value: Variant) -> void:
	_material_display.set_shader_parameter(parameter, value)


## Drops the cached reference orbit, forcing a recompute on the next frame.
func invalidate_orbit() -> void:
	_orbit.invalidate()


## 0 while the refinement starts, 1 when the last band is done.
func refine_progress() -> float:
	return float(_refine_row) / maxf(float(view_high.size.y), 1.0)


func update(delta: float) -> void:
	_advance_morph(delta)

	var view_hash := _params_hash()
	var dirty := view_hash != _last_hash
	_last_hash = view_hash

	if dirty:
		_settle = 0.0
		state = State.MOVING
		_render_preview()
		_set_blend(0.0)
		return

	match state:
		State.MOVING:
			_settle += delta
			if _settle >= SETTLE_TIME:
				_begin_refine()
		State.REFINING:
			_refine_step()
		State.IDLE:
			pass


func _advance_morph(delta: float) -> void:
	if not julia_morph or camera.fractal_type != 1:
		return
	_julia_theta += delta * 0.08
	julia_re = 0.7885 * cos(_julia_theta)
	julia_im = 0.7885 * sin(_julia_theta)


func _params_hash() -> int:
	return hash([
		camera.center_x, camera.center_y, camera.log_zoom, camera.fractal_type,
		julia_re, julia_im, camera.iterations_full(), aa_quality,
		trap_shape, trap_scale, view_high.size.x, view_high.size.y,
	])


func _render_preview() -> void:
	_apply_view_uniforms(_material_low, mini(camera.iterations_full(), INTERACT_ITER_CAP), 1)
	_material_low.set_shader_parameter("band_y_min", 0)
	_material_low.set_shader_parameter("band_y_max", 1000000)
	view_low.render_target_update_mode = SubViewport.UPDATE_ONCE


func _begin_refine() -> void:
	state = State.REFINING
	_refine_row = 0
	_apply_view_uniforms(_material_high, camera.iterations_full(), aa_quality)
	_refine_step()


func _refine_step() -> void:
	_material_high.set_shader_parameter("band_y_min", _refine_row)
	_material_high.set_shader_parameter("band_y_max", _refine_row + REFINE_BAND_ROWS)
	view_high.render_target_update_mode = SubViewport.UPDATE_ONCE
	_refine_row += REFINE_BAND_ROWS
	if _refine_row >= view_high.size.y:
		state = State.IDLE
		_fade_blend_to_high()


func _set_blend(value: float) -> void:
	if _blend_tween:
		_blend_tween.kill()
		_blend_tween = null
	_material_display.set_shader_parameter("refine_blend", value)


func _fade_blend_to_high() -> void:
	if _blend_tween:
		_blend_tween.kill()
	_blend_tween = host.create_tween()
	var from: float = _material_display.get_shader_parameter("refine_blend")
	_blend_tween.tween_method(
		func(value: float) -> void:
			_material_display.set_shader_parameter("refine_blend", value),
		from, 1.0, 0.15
	)


func _apply_view_uniforms(material: ShaderMaterial, iterations: int, aa: int) -> void:
	var zoom := camera.zoom()
	var perturbed := camera.fractal_type <= 1 and zoom > PERT_ZOOM_THRESHOLD
	if perturbed:
		_orbit.ensure(camera, julia_re, julia_im, iterations)
	material.set_shader_parameter("fractal_type", camera.fractal_type)
	material.set_shader_parameter("julia_c", Vector2(julia_re, julia_im))
	material.set_shader_parameter("max_iterations", iterations)
	material.set_shader_parameter("view_center", Vector2(camera.center_x, camera.center_y))
	material.set_shader_parameter("view_half", FractalCamera.VIEW_BASE / zoom)
	material.set_shader_parameter("use_perturbation", perturbed)
	if perturbed:
		material.set_shader_parameter("dc_origin",
			Vector2(camera.center_x - _orbit.origin_x, camera.center_y - _orbit.origin_y))
		material.set_shader_parameter("ref_orbit", _orbit.texture)
		material.set_shader_parameter("ref_len", _orbit.length)
	material.set_shader_parameter("trap_shape", trap_shape)
	material.set_shader_parameter("trap_scale", trap_scale)
	material.set_shader_parameter("aa_quality", aa)
