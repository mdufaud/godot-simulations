class_name FractalView extends RefCounted
## Two-pass fractal render pipeline.
##
## Pass 1 ([code]fractal.gdshader[/code], in the two SubViewports) computes
## iteration data only when the view changes: the low viewport is the live
## preview while moving — always at the full iteration count the view needs,
## downscaled as far as the frame budget demands; the high viewport refines
## at full res in bands. Pass 2 ([code]fractal_colorize.gdshader[/code], on
## the display rect) maps that data to colour every frame, resampling each
## source through a view transform so the frames where a fresh render is not
## in yet still show the previous one at the right position.
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
## Seconds of the display crossfade toward whichever pass just finished.
const BLEND_FADE_S := 0.05
## Preview resolution levels: the preview renders at 2^-level of the window.
## The cost of motion is paid in resolution, never in iterations — a
## low-iteration preview paints deep zooms black, a low-resolution one is
## merely soft while moving.
const PREVIEW_MIN_LEVEL := 0
const PREVIEW_MAX_LEVEL := 3
## Frame-time hysteresis of the level: 3 slow frames drop one level, 30 fast
## frames climb back one.
const PREVIEW_DROP_S := 0.030
const PREVIEW_RAISE_S := 0.014

var camera: FractalCamera
var config: FractalConfig = FractalConfig.new()
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
## View each source viewport was last rendered for; the display transform
## resamples stale sources into the current view (see _source_xform).
var _low_cx := 0.0
var _low_cy := 0.0
var _low_half := 1.0
var _low_aspect := 1.0
var _high_cx := 0.0
var _high_cy := 0.0
var _high_half := 1.0
var _high_aspect := 1.0
var _settle := 0.0
var _refine_row := 0
var _last_hash := 0
var _julia_theta := 0.0
var _blend_tween: Tween
var _preview_level := PREVIEW_MIN_LEVEL
var _slow_frames := 0
var _fast_frames := 0


func start() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Fractal config: %s" % config_error)
		return
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
	_material_display.set_shader_parameter("refine_blend", 0.0)

	_store_low_view()
	_store_high_view()
	_update_display_xforms()


func resize(window_size: Vector2i) -> void:
	view_high.size = Vector2i(maxi(window_size.x, 8), maxi(window_size.y, 8))
	_apply_preview_level()
	rect_high.size = Vector2(view_high.size)


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
	_update_display_xforms()

	var view_hash := _params_hash()
	var dirty := view_hash != _last_hash
	_last_hash = view_hash

	if dirty:
		_settle = 0.0
		state = State.MOVING
		_adapt_preview(delta)
		_render_preview()
		# The preview holds the current view exactly (full iterations), so
		# the screen can follow it as soon as it lands; the view transform
		# covers the single frame it takes to arrive.
		_fade_blend(0.0, BLEND_FADE_S)
		return

	match state:
		State.MOVING:
			_settle += delta
			if _settle >= config.settle_time_s:
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
	_apply_view_uniforms(_material_low, camera.iterations_full(), 1)
	_material_low.set_shader_parameter("band_y_min", 0)
	_material_low.set_shader_parameter("band_y_max", 1000000)
	_store_low_view()
	view_low.render_target_update_mode = SubViewport.UPDATE_ONCE


## Keeps the preview inside the frame budget while moving by trading
## resolution (the iteration count stays exact). Delta is the previous
## frame's time — the frame that paid for the last preview.
func _adapt_preview(delta: float) -> void:
	if delta > PREVIEW_DROP_S:
		_slow_frames += 1
		_fast_frames = 0
	elif delta < PREVIEW_RAISE_S:
		_fast_frames += 1
		_slow_frames = 0
	else:
		_slow_frames = 0
		_fast_frames = 0
	var level := _preview_level
	if _slow_frames >= 3 and level < PREVIEW_MAX_LEVEL:
		level += 1
		_slow_frames = 0
	elif _fast_frames >= 30 and level > PREVIEW_MIN_LEVEL:
		level -= 1
		_fast_frames = 0
	if level != _preview_level:
		_preview_level = level
		_apply_preview_level()


func _apply_preview_level() -> void:
	view_low.size = Vector2i(
		maxi(view_high.size.x >> _preview_level, 4),
		maxi(view_high.size.y >> _preview_level, 4))
	rect_low.size = Vector2(view_low.size)


func _begin_refine() -> void:
	state = State.REFINING
	_refine_row = 0
	_apply_view_uniforms(_material_high, camera.iterations_full(), aa_quality)
	_store_high_view()
	_refine_step()


func _refine_step() -> void:
	_material_high.set_shader_parameter("band_y_min", _refine_row)
	_material_high.set_shader_parameter("band_y_max", _refine_row + config.refine_band_rows)
	view_high.render_target_update_mode = SubViewport.UPDATE_ONCE
	_refine_row += config.refine_band_rows
	if _refine_row >= view_high.size.y:
		state = State.IDLE
		_fade_blend_to_high()


func _store_low_view() -> void:
	_low_cx = camera.center_x
	_low_cy = camera.center_y
	_low_half = camera.view_half()
	_low_aspect = camera.aspect()


func _store_high_view() -> void:
	_high_cx = camera.center_x
	_high_cy = camera.center_y
	_high_half = camera.view_half()
	_high_aspect = camera.aspect()


## Screen-UV transform resampling a source rendered for an older view
## (cx0/cy0/half0/aspect0) into the current one. Computed in float64 here —
## the deltas are tiny at deep zoom, far under float32 resolution — and only
## the small result goes to the shader as float32.
func _source_xform(cx0: float, cy0: float, half0: float, aspect0: float) -> Vector4:
	var half := camera.view_half()
	var aspect := camera.aspect()
	var sx := (half * aspect) / (half0 * aspect0)
	var sy := half / half0
	return Vector4(
		sx, sy,
		0.5 + (camera.center_x - cx0) / (2.0 * half0 * aspect0) - 0.5 * sx,
		0.5 + (camera.center_y - cy0) / (2.0 * half0) - 0.5 * sy
	)


func _update_display_xforms() -> void:
	_material_display.set_shader_parameter("xform_low",
		_source_xform(_low_cx, _low_cy, _low_half, _low_aspect))
	_material_display.set_shader_parameter("xform_high",
		_source_xform(_high_cx, _high_cy, _high_half, _high_aspect))


func _fade_blend(value: float, duration: float) -> void:
	if _blend_tween:
		_blend_tween.kill()
		_blend_tween = null
	var raw: Variant = _material_display.get_shader_parameter("refine_blend")
	var from := float(raw) if raw != null else 0.0
	if absf(from - value) < 0.005:
		_material_display.set_shader_parameter("refine_blend", value)
		return
	_blend_tween = host.create_tween()
	_blend_tween.tween_method(
		func(blend: float) -> void:
			_material_display.set_shader_parameter("refine_blend", blend),
		from, value, duration
	)


func _fade_blend_to_high() -> void:
	_fade_blend(1.0, BLEND_FADE_S)


func _apply_view_uniforms(material: ShaderMaterial, iterations: int, aa: int) -> void:
	var zoom := camera.zoom()
	var perturbed := camera.fractal_type <= 1 and zoom > config.perturbation_zoom_threshold
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
		if camera.fractal_type == 1 and _orbit.crit_texture != null:
			material.set_shader_parameter("ref_orbit_crit", _orbit.crit_texture)
			material.set_shader_parameter("ref_len_crit", _orbit.crit_length)
	material.set_shader_parameter("trap_shape", trap_shape)
	material.set_shader_parameter("trap_scale", trap_scale)
	material.set_shader_parameter("aa_quality", aa)
