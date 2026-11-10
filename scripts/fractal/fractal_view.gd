class_name FractalView extends RefCounted
## Progressive full-resolution fractal renderer.
##
## The sample pass ([code]fractal.gdshader[/code]) evaluates one sample per
## texel of a buffer 1/stride the window size: texel (i, j) is one full-res
## pixel of its stride x stride cell, a different one each frame so stride²
## frames cover every pixel (fractal_slots.gdshaderinc), and every texel is
## dense GPU work. The accumulation pass
## ([code]fractal_accumulate.gdshader[/code], full resolution, ping-pong)
## resamples the previous result through the exact float64 view transform and
## blends the fresh samples in: a zoom magnifies real pixels, which are then
## replaced at full resolution, never a stretched low-res preview. Once the view
## is still, every pass adds one jittered sample per pixel until
## [member aa_samples], then nothing renders. The colorize pass
## ([code]fractal_colorize.gdshader[/code], on the display rect) maps the data
## to colour every frame.
##
## The stride follows the GPU time of the sample pass against
## [member FractalConfig.sample_budget_ms]: a costly view is paid in refresh
## latency, never in resolution or iterations.
##
## With [member FractalCamera.auto_iterations] the iteration count also follows
## the picture: a coarse grid of the sample pass, run at twice the count, is
## read back a few times a second, and while a visible share of it only escapes
## past the count (pixels the screen wrongly shows as inside the set),
## [member FractalCamera.iteration_boost] raises it.
##
## The host assigns the fields below; [method start] builds the buffers under
## [member host]:
##
## [codeblock]
## var view := FractalView.new()
## view.camera = camera
## view.display = $Display
## view.host = self
## view.start()
## view.resize(get_window().size)
## [/codeblock]

enum State { MOVING, REFINING, IDLE }

const SAMPLE_SHADER := preload("res://shaders/fractal/fractal.gdshader")
const ACCUMULATE_SHADER := preload("res://shaders/fractal/fractal_accumulate.gdshader")
## Weight of a fresh sample while the view moves slowly: the history then
## averages about three samples (temporal anti-aliasing in motion).
const MOTION_ALPHA := 0.5
## Zoom change over one refresh cycle (stride² frames), in log units, past which
## the history is too magnified to average with and fresh samples replace it.
const MOTION_MAGNIFY_LO := 0.08
const MOTION_MAGNIFY_HI := 0.4
## Stride hysteresis: coarser after 3 frames over budget, finer after 12 frames
## in which the finer stride is expected to fit under 80 % of it.
const STRIDE_OVER_FRAMES := 3
const STRIDE_UNDER_FRAMES := 12
const STRIDE_UNDER_MARGIN := 0.8
## Cost of the finer stride relative to the current one when it was not measured
## recently. A pass with few texels leaves the GPU underused (fewer waves to hide
## latency, lower clocks), so 4x the texels costs far less than 4x the time:
## moving tries the optimistic guess and falls back within 3 frames, refining
## only takes the pessimistic one so the accumulation is not disturbed.
const STRIDE_GUESS_MOVING := 2.0
const STRIDE_GUESS_REFINING := 4.0
## Frames a measured stride cost stays trusted.
const STRIDE_COST_TTL := 240
## Frames the GPU timer may still report the previous stride after a change.
const STRIDE_SETTLE_FRAMES := 4
## Step of the two-channel mu encoding (R = floor(mu / step), G = remainder) in
## the RGBA16F buffers: half floats hold integers exactly up to 2048, so R stays
## exact up to 2048 * 16 iterations, while G keeps ~0.008 resolution through the
## per-frame re-encode of resampled pixels. A coarser step lets that rounding
## drift with pixel age, which the colorize emboss shows as stride-periodic stripes.
const MU_SPLIT := 16.0
## Grid of the iteration probe, and the seconds between two probes.
const PROBE_SIZE := Vector2i(64, 36)
const PROBE_INTERVAL_S := 0.25
## The probe iterates this many times the current count.
const PROBE_REACH := 2.0
## Share of the probe escaping only past the count above which the count is
## raised by [constant PROBE_BOOST_STEP]; it is lowered by the same step once
## less than [constant PROBE_LOWER_SHARE] escapes past the lowered count.
const PROBE_RAISE_SHARE := 0.004
const PROBE_LOWER_SHARE := 0.001
const PROBE_BOOST_STEP := 1.5
## Zoom decades over which the palette switches from the absolute iteration
## count to the count above the lowest one in view. Deep in, every pixel takes
## thousands of iterations and differs from its neighbours by a few: on the
## absolute (log) scale the whole screen is one colour.
const FLOOR_FROM_DECADE := 12.0
const FLOOR_FULL_DECADE := 15.0
## Seconds the palette takes to follow the lowest count in view.
const FLOOR_SMOOTH_S := 0.4
## R2 low-discrepancy sequence, the sub-pixel jitter of successive samples.
const R2_A1 := 0.7548776662466927
const R2_A2 := 0.5698402909980532

var camera: FractalCamera
var config: FractalConfig = FractalConfig.new()
var display: ColorRect
## Node the render buffers are built under.
var host: Node

var julia_re := -0.7269
var julia_im := 0.1889
var julia_morph := false
var trap_shape := 0
var trap_scale := 1.0
## Jittered samples each pixel accumulates once the view is still.
var aa_samples := 9

var state := State.MOVING

var _orbit := FractalOrbit.new()
var _sample_material: ShaderMaterial
var _material_display: ShaderMaterial
var _accum: Array[SubViewport] = []
var _accum_rects: Array[ColorRect] = []
var _accum_materials: Array[ShaderMaterial] = []
var _samples: Array[SubViewport] = []
var _sample_rects: Array[ColorRect] = []
var _full_size := Vector2i(8, 8)
var _stride := 2
var _frame := 0
## Accumulation buffer the last render went to; the next one reads it as history.
var _current := 0
var _history_valid := false
# View the history buffer was rendered for.
var _hist_cx := 0.0
var _hist_cx_lo := 0.0
var _hist_cy := 0.0
var _hist_cy_lo := 0.0
var _hist_half := 1.0
var _hist_log_zoom := 0.0
## Samples every history pixel holds, as a blend weight.
var _history_weight := 0.0
## Frames left in which fresh samples replace the history instead of averaging.
var _replace_frames := 0
var _pass_frame := 0
var _passes_done := 0
var _view_key := 0
var _soft_key := 0
var _hard_key := 0
var _julia_theta := 0.0
var _over_frames := 0
var _under_frames := 0
var _stride_settle := 0
# Last measured sample-pass cost per stride, and the frame it was measured at.
var _stride_cost := {}
var _stride_cost_frame := {}
var _rendered := false
# Names of the GPU timestamps the renderer captures around each sample viewport.
var _sample_begin_names: Array[String] = []
var _sample_end_names: Array[String] = []
var _probe: SubViewport
var _probe_material: ShaderMaterial
var _probe_timer := 0.0
var _probe_pending := false
var _probe_iterations := 0
var _probe_key := 0
var _mu_floor := 0.0
var _mu_floor_target := 0.0


func start() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Fractal config: %s" % config_error)
		return
	assert(camera != null, "FractalView: camera is required")
	assert(display != null and host != null, "FractalView: display rect and host are required")

	_material_display = display.material as ShaderMaterial
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sample_material = ShaderMaterial.new()
	_sample_material.shader = SAMPLE_SHADER

	# Each sample viewport is a child of the accumulation viewport reading it:
	# child viewports render first, so a frame's samples land the same frame.
	for i in 2:
		var accum := _make_viewport()
		host.add_child(accum)
		var sample := _make_viewport()
		accum.add_child(sample)
		var sample_rect := ColorRect.new()
		sample_rect.material = _sample_material
		sample.add_child(sample_rect)
		var accum_material := ShaderMaterial.new()
		accum_material.shader = ACCUMULATE_SHADER
		var accum_rect := ColorRect.new()
		accum_rect.material = accum_material
		accum.add_child(accum_rect)
		var sample_rid := sample.get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(sample_rid, true)
		_sample_begin_names.append("vp_begin_%d" % sample_rid.get_id())
		_sample_end_names.append("vp_end_%d" % sample_rid.get_id())
		_accum.append(accum)
		_accum_rects.append(accum_rect)
		_accum_materials.append(accum_material)
		_samples.append(sample)
		_sample_rects.append(sample_rect)
	for i in 2:
		_accum_materials[i].set_shader_parameter("tex_history", _accum[1 - i].get_texture())
		_accum_materials[i].set_shader_parameter("tex_sample", _samples[i].get_texture())
		_accum_materials[i].set_shader_parameter("mu_split", MU_SPLIT)
	_sample_material.set_shader_parameter("mu_split", MU_SPLIT)
	_material_display.set_shader_parameter("mu_split", MU_SPLIT)
	_material_display.set_shader_parameter("tex_accum", _accum[0].get_texture())
	_set_stride(mini(_stride, config.max_sample_stride))

	_probe = _make_viewport()
	_probe.size = PROBE_SIZE
	host.add_child(_probe)
	_probe_material = ShaderMaterial.new()
	_probe_material.shader = SAMPLE_SHADER
	_probe_material.set_shader_parameter("mu_split", MU_SPLIT)
	var probe_rect := ColorRect.new()
	probe_rect.material = _probe_material
	probe_rect.size = Vector2(PROBE_SIZE)
	_probe.add_child(probe_rect)


func resize(window_size: Vector2i) -> void:
	_full_size = Vector2i(maxi(window_size.x, 8), maxi(window_size.y, 8))
	for i in 2:
		_accum[i].size = _full_size
		_accum_rects[i].size = Vector2(_full_size)
	_resize_samples()


func set_julia_morph(enabled: bool) -> void:
	julia_morph = enabled
	if enabled:
		_julia_theta = atan2(julia_im, julia_re)


func set_display_parameter(parameter: StringName, value: Variant) -> void:
	_material_display.set_shader_parameter(parameter, value)


## Drops the cached reference orbit, forcing a recompute on the next frame.
func invalidate_orbit() -> void:
	_orbit.invalidate()


## 0 when the still view starts accumulating, 1 once every pixel holds
## [member aa_samples] samples.
func refine_progress() -> float:
	var cycle := _stride * _stride
	return float(_passes_done * cycle + _pass_frame) / float(maxi(aa_samples * cycle, 1))


## 1 pixel in stride² gets a fresh sample per frame.
func sample_stride() -> int:
	return _stride


func update(delta: float) -> void:
	_advance_morph(delta)
	_update_probe(delta)
	_mu_floor = lerpf(_mu_floor_target, _mu_floor, exp(-delta / FLOOR_SMOOTH_S))
	_material_display.set_shader_parameter("mu_floor", _mu_floor * smoothstep(
		FLOOR_FROM_DECADE, FLOOR_FULL_DECADE, camera.log_zoom / FractalCamera.LN10))

	var hard := _hard_hash()
	if hard != _hard_key:
		_hard_key = hard
		_history_valid = false
	var soft := _soft_hash()
	var soft_changed := soft != _soft_key
	_soft_key = soft
	if soft_changed or not _history_valid:
		# The history shows other content: fresh samples replace it, so the
		# screen dissolves into the new image within one refresh cycle.
		_replace_frames = _stride * _stride
	var view := _view_hash()
	var moving := view != _view_key or _replace_frames > 0
	_view_key = view

	_adapt_stride(moving)

	if moving:
		state = State.MOVING
		_pass_frame = 0
		_passes_done = 0
		var alpha := _motion_alpha()
		_history_weight = (1.0 - alpha) / alpha
		# No jitter in motion: the moving view already lands every frame's samples
		# elsewhere on the fractal, and pixels refreshed at different frames with
		# different jitters disagree on smooth gradients, which the colorize
		# emboss turns into diagonal stripes.
		_render(_frame % (_stride * _stride), alpha, Vector2.ZERO)
		return

	if state == State.MOVING:
		state = State.REFINING
		_history_weight = minf(_history_weight, 1.0)
	elif state == State.IDLE:
		_rendered = false
		if _passes_done >= aa_samples:
			return
		state = State.REFINING

	_render(_pass_frame, 1.0 / (_history_weight + 1.0), _r2(_passes_done))
	_pass_frame += 1
	if _pass_frame == _stride * _stride:
		_pass_frame = 0
		_passes_done += 1
		_history_weight += 1.0
		if _passes_done >= aa_samples:
			state = State.IDLE


## Reads the probe rendered last frame, then renders the next one when the view
## or the count has changed since.
func _update_probe(delta: float) -> void:
	if not camera.auto_iterations:
		camera.iteration_boost = 1.0
		_probe_pending = false
		return
	if _probe_pending:
		_probe_pending = false
		_apply_probe(_probe.get_texture().get_image())
	_probe_timer += delta
	if _probe_timer < PROBE_INTERVAL_S:
		return
	var key := hash([_view_hash(), _hard_hash(), julia_re, julia_im, camera.iterations_full()])
	if key == _probe_key:
		return
	_probe_key = key
	_probe_timer = 0.0
	_probe_iterations = camera.iterations_full()
	_apply_view_uniforms(_probe_material,
		mini(int(float(_probe_iterations) * PROBE_REACH), FractalCamera.MAX_ITERATIONS))
	_probe_material.set_shader_parameter("sample_stride", 1)
	_probe_material.set_shader_parameter("sample_phase", 0)
	_probe_material.set_shader_parameter("sample_jitter", Vector2.ZERO)
	_probe_material.set_shader_parameter("full_size", Vector2(PROBE_SIZE))
	_probe.render_target_update_mode = SubViewport.UPDATE_ONCE
	_probe_pending = true


func _apply_probe(image: Image) -> void:
	if image == null or image.is_empty():
		return
	var escaped := PackedFloat32Array()
	for y in image.get_height():
		for x in image.get_width():
			var texel := image.get_pixel(x, y)
			if texel.a > 0.5:
				escaped.append(texel.r * MU_SPLIT + texel.g)
	if not escaped.is_empty():
		var lowest := escaped[0]
		for mu in escaped:
			lowest = minf(lowest, mu)
		_mu_floor_target = lowest
	camera.iteration_boost = probe_boost(escaped, image.get_width() * image.get_height(),
		_probe_iterations, camera.iteration_boost, camera.iterations_for_zoom())


## Boost after a probe of [param total] orbits: [param escaped] holds the
## smooth iteration count of those that escaped, [param iterations] is the
## count on screen and [param base] the zoom-based count the boost multiplies.
static func probe_boost(escaped: PackedFloat32Array, total: int, iterations: int,
		boost: float, base: int) -> float:
	var past_count := 0
	var past_lowered := 0
	for mu in escaped:
		if mu > float(iterations):
			past_count += 1
		if mu > float(iterations) / PROBE_BOOST_STEP:
			past_lowered += 1
	if float(past_count) > PROBE_RAISE_SHARE * float(total):
		return minf(boost * PROBE_BOOST_STEP, float(FractalCamera.MAX_ITERATIONS) / float(base))
	if float(past_lowered) < PROBE_LOWER_SHARE * float(total):
		return maxf(boost / PROBE_BOOST_STEP, 1.0)
	return boost


func _make_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.use_hdr_2d = true
	viewport.size = _full_size
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return viewport


func _resize_samples() -> void:
	var sample_size := Vector2i(
		ceili(float(_full_size.x) / _stride), ceili(float(_full_size.y) / _stride))
	for i in 2:
		_samples[i].size = sample_size
		_sample_rects[i].size = Vector2(sample_size)


func _set_stride(stride: int) -> void:
	_stride = stride
	_pass_frame = 0
	_over_frames = 0
	_under_frames = 0
	_stride_settle = STRIDE_SETTLE_FRAMES
	_resize_samples()


## Sub-pixel jitter of the n-th sample, centred on the pixel for n = 0.
static func _r2(n: int) -> Vector2:
	return Vector2(fposmod(0.5 + n * R2_A1, 1.0), fposmod(0.5 + n * R2_A2, 1.0)) \
		- Vector2(0.5, 0.5)


## Coarser stride when the sample pass runs over budget, finer when the finer
## one is expected to fit with margin.
func _adapt_stride(moving: bool) -> void:
	if not _rendered:
		return
	if _stride_settle > 0:
		_stride_settle -= 1
		return
	var gpu_ms := _sample_gpu_ms()
	if gpu_ms <= 0.0:
		return
	_stride_cost[_stride] = gpu_ms
	_stride_cost_frame[_stride] = _frame
	var budget := config.sample_budget_ms
	if gpu_ms > budget:
		_over_frames += 1
		_under_frames = 0
	elif _stride > 1 and _finer_cost_ms(gpu_ms, moving) < budget * STRIDE_UNDER_MARGIN:
		_under_frames += 1
		_over_frames = 0
	else:
		_over_frames = 0
		_under_frames = 0
	if _over_frames >= STRIDE_OVER_FRAMES and _stride < config.max_sample_stride:
		_set_stride(_stride << 1)
	elif _under_frames >= STRIDE_UNDER_FRAMES:
		_set_stride(_stride >> 1)


func _finer_cost_ms(gpu_ms: float, moving: bool) -> float:
	var finer := _stride >> 1
	if _stride_cost.has(finer) and _frame - int(_stride_cost_frame[finer]) < STRIDE_COST_TTL:
		return _stride_cost[finer]
	return gpu_ms * (STRIDE_GUESS_MOVING if moving else STRIDE_GUESS_REFINING)


## GPU time of the latest sample pass the renderer has timestamps for, 0 when
## none is available (per-viewport measured times stay 0 for viewports that do
## not render every frame, so the raw timestamps are read instead).
func _sample_gpu_ms() -> float:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return 0.0
	var begin := -1
	for i in rd.get_captured_timestamps_count():
		var name := rd.get_captured_timestamp_name(i)
		if name in _sample_begin_names:
			begin = rd.get_captured_timestamp_gpu_time(i)
		elif begin >= 0 and name in _sample_end_names:
			return float(rd.get_captured_timestamp_gpu_time(i) - begin) / 1.0e6
	return 0.0


func _motion_alpha() -> float:
	if _replace_frames > 0:
		return 1.0
	var cycle_zoom := absf(camera.log_zoom - _hist_log_zoom) * float(_stride * _stride)
	return lerpf(MOTION_ALPHA, 1.0, smoothstep(MOTION_MAGNIFY_LO, MOTION_MAGNIFY_HI, cycle_zoom))


func _advance_morph(delta: float) -> void:
	if not julia_morph or camera.fractal_type != 1:
		return
	_julia_theta += delta * 0.08
	julia_re = 0.7885 * cos(_julia_theta)
	julia_im = 0.7885 * sin(_julia_theta)


## Changes no history pixel can stand in for: start over from fresh samples.
func _hard_hash() -> int:
	return hash([camera.fractal_type, _full_size, camera.auto_iterations])


## Changes the history still roughly matches: dissolve it away.
func _soft_hash() -> int:
	return hash([julia_re, julia_im, trap_shape, trap_scale,
		camera.iteration_boost if camera.auto_iterations else float(camera.manual_iterations)])


func _view_hash() -> int:
	return hash([camera.center_x, camera.center_x_lo, camera.center_y, camera.center_y_lo,
		camera.log_zoom])


func _render(phase: int, alpha: float, jitter: Vector2) -> void:
	if _replace_frames > 0:
		alpha = 1.0
		_replace_frames -= 1
	var target := 1 - _current
	var iterations := camera.iterations_full()

	_apply_view_uniforms(_sample_material, iterations)
	_sample_material.set_shader_parameter("sample_stride", _stride)
	_sample_material.set_shader_parameter("sample_phase", phase)
	_sample_material.set_shader_parameter("sample_jitter", jitter)
	_sample_material.set_shader_parameter("full_size", Vector2(_full_size))

	var xform := _history_xform()
	var material := _accum_materials[target]
	material.set_shader_parameter("sample_stride", _stride)
	material.set_shader_parameter("sample_phase", phase)
	material.set_shader_parameter("sample_jitter", jitter)
	material.set_shader_parameter("history_valid", _history_valid)
	material.set_shader_parameter("history_identity", xform == Vector4(1.0, 1.0, 0.0, 0.0))
	material.set_shader_parameter("history_xform", xform)
	material.set_shader_parameter("blend_alpha", alpha)
	material.set_shader_parameter("mu_max", float(iterations + 64))

	_samples[target].render_target_update_mode = SubViewport.UPDATE_ONCE
	_accum[target].render_target_update_mode = SubViewport.UPDATE_ONCE
	_material_display.set_shader_parameter("tex_accum", _accum[target].get_texture())

	_current = target
	_hist_cx = camera.center_x
	_hist_cx_lo = camera.center_x_lo
	_hist_cy = camera.center_y
	_hist_cy_lo = camera.center_y_lo
	_hist_half = camera.view_half()
	_hist_log_zoom = camera.log_zoom
	_history_valid = true
	_frame += 1
	_rendered = true


## Screen-UV transform from the current view into the history's. Computed from
## the double-double centres here — the deltas are tiny at deep zoom, far under
## float32 resolution — and only the small result goes to the shader as float32.
func _history_xform() -> Vector4:
	var aspect := camera.aspect()
	var s := camera.view_half() / _hist_half
	return Vector4(
		s, s,
		0.5 + camera.center_delta_x(_hist_cx, _hist_cx_lo) / (2.0 * _hist_half * aspect)
			- 0.5 * s,
		0.5 + camera.center_delta_y(_hist_cy, _hist_cy_lo) / (2.0 * _hist_half) - 0.5 * s
	)


func _apply_view_uniforms(material: ShaderMaterial, iterations: int) -> void:
	var zoom := camera.zoom()
	var perturbed := zoom > config.perturbation_zoom_threshold
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
			Vector2(camera.center_delta_x(_orbit.origin_x, _orbit.origin_x_lo),
				camera.center_delta_y(_orbit.origin_y, _orbit.origin_y_lo)))
		material.set_shader_parameter("ref_orbit", _orbit.texture)
		material.set_shader_parameter("ref_len", _orbit.length)
		if camera.fractal_type == 1 and _orbit.crit_texture != null:
			material.set_shader_parameter("ref_orbit_crit", _orbit.crit_texture)
			material.set_shader_parameter("ref_len_crit", _orbit.crit_length)
	material.set_shader_parameter("trap_shape", trap_shape)
	material.set_shader_parameter("trap_scale", trap_scale)
