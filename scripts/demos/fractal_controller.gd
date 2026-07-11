extends Control
## 2D Fractal Explorer — deep-zoom fractal viewer.
##
## Two-pass rendering:
##   Pass 1 (fractal.gdshader, in SubViewports) computes iteration data
##   only when the view changes. Low viewport = half-res live preview
##   while moving; high viewport = full-res refinement in bands.
##   Pass 2 (fractal_colorize.gdshader) maps data to color every frame.
##
## Deep zoom via perturbation theory: the reference orbit is iterated
## here in float64 (GDScript floats) and uploaded as an RGF32 texture.
## Coordinates are NEVER stored in Vector2 (float32) — always separate
## float64 scalars.
##
## Interaction: drag = pan (content follows cursor), wheel = smooth
## zoom anchored at cursor, auto mode = cinematic dives into curated
## points of interest.

enum RState { MOVING, REFINING, IDLE }
enum AutoPhase { DIVE, HOLD, RISE }

const LN10 := 2.302585092994046
const VIEW_BASE := 1.75
const PERT_ZOOM_THRESHOLD := 1.0e3
const INTERACT_ITER_CAP := 1200
const REFINE_BAND_ROWS := 256
const SETTLE_TIME := 0.25
const ORBIT_TEX_W := 4096
const DRAG_DEADZONE := 3.0
const ZOOM_STEP := 0.22314355131  # ln(1.25)
const ZOOM_SMOOTHING := 12.0

# [x, y, max_zoom] — float64 literals
const POIS_MANDEL := [
	[-0.743643887037151, 0.131825904205330, 1.0e10],
	[-0.77568377, 0.13646737, 3.0e6],
	[-1.7548776662466927, 0.0, 1.0e7],
	[0.001643721971153, -0.822467633298876, 1.0e10],
	[0.285, 0.01, 3.0e4],
]
const POIS_JULIA := [[0.0, 0.0, 30.0]]
const POIS_SHIP := [[-1.7595, -0.0285, 8.0e3], [-1.625, -0.028, 5.0e3]]
const POIS_TRICORN := [[-0.85, 0.0, 3.0e3], [0.0, 0.8, 3.0e3]]

@onready var _view_low: SubViewport = $ViewLow
@onready var _view_high: SubViewport = $ViewHigh
@onready var _rect_low: ColorRect = $ViewLow/Rect
@onready var _rect_high: ColorRect = $ViewHigh/Rect
@onready var _display: ColorRect = $Display
@onready var _menu: SimMenu = $UI/SimMenu

var _mat_low: ShaderMaterial
var _mat_high: ShaderMaterial
var _mat_display: ShaderMaterial

# --- View state (float64 scalars) ---
var _cx := -0.6
var _cy := 0.0
var _log_zoom := 0.0
var _t_log_zoom := 0.0

# --- Zoom anchor (point under cursor stays fixed while easing) ---
var _anchor_active := false
var _anchor_wx := 0.0
var _anchor_wy := 0.0
var _anchor_u := 0.5
var _anchor_v := 0.5

# --- Fractal parameters ---
var _fractal_type := 0
var _julia_re := -0.7269
var _julia_im := 0.1889
var _julia_morph := false
var _julia_theta := 0.0
var _trap_shape := 0
var _trap_scale := 1.0
var _aa_quality := 2
var _auto_iters := true
var _manual_iters := 2000

# --- Reference orbit cache ---
var _orbit_tex: ImageTexture
var _ref_x := 0.0
var _ref_y := 0.0
var _orbit_len := 0
var _orbit_escaped := false
var _orbit_type := -1
var _orbit_jre := 0.0
var _orbit_jim := 0.0

# --- Render state machine ---
var _state := RState.MOVING
var _settle := 0.0
var _refine_row := 0
var _last_hash := 0
var _blend_tween: Tween

# --- Auto exploration ---
var _auto_on := false
var _auto_speed := 0.45
var _auto_phase := AutoPhase.DIVE
var _auto_hold := 0.0
var _poi_idx := 0
var _poi_x := 0.0
var _poi_y := 0.0
var _poi_max_lz := 0.0

# --- Mouse ---
var _mouse_down := false
var _is_dragging := false
var _drag_start := Vector2.ZERO

# --- Touch ---
var _touch_points := {}       # index → position (Vector2)
var _prev_pinch_distance := 0.0

# --- UI ---
var _lbl_zoom: Label
var _lbl_iters: Label
var _lbl_state: Label
var _label_timer := 0.0


func _ready() -> void:
	_mat_low = _rect_low.material as ShaderMaterial
	_mat_high = _rect_high.material as ShaderMaterial
	_mat_display = _display.material as ShaderMaterial

	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view_high.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_view_low.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_view_high.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_mat_display.set_shader_parameter("tex_low", _view_low.get_texture())
	_mat_display.set_shader_parameter("tex_high", _view_high.get_texture())

	get_window().size_changed.connect(_resize_viewports)
	_resize_viewports()
	_setup_ui()
	_pick_poi(0)
	_reset_view_for_type()


func _process(delta: float) -> void:
	_update_auto(delta)
	_update_julia_morph(delta)
	_update_motion(delta)
	_update_render_state(delta)
	_update_labels(delta)


# ============================================================
#  VIEW MATH (float64)
# ============================================================

func _zoom() -> float:
	return exp(_log_zoom)


func _view_half_h() -> float:
	return VIEW_BASE / _zoom()


func _world_x_at(u: float) -> float:
	var aspect := size.x / size.y
	return _cx + (u - 0.5) * 2.0 * _view_half_h() * aspect


func _world_y_at(v: float) -> float:
	return _cy + (v - 0.5) * 2.0 * _view_half_h()


func _min_log_zoom() -> float:
	return log(0.3)


func _max_log_zoom() -> float:
	match _fractal_type:
		0: return log(1.0e13)
		1: return log(1.0e10)
		_: return log(1.0e4)


func _iterations_full() -> int:
	if not _auto_iters:
		return _manual_iters
	var lz10 := maxf(_log_zoom / LN10, 0.0)
	return clampi(int(100.0 * pow(lz10 + 1.0, 1.6)), 128, 20000)


# ============================================================
#  INPUT
# ============================================================

func _gui_input(event: InputEvent) -> void:
	# A live finger also emits emulated mouse events; without this guard a
	# one-finger drag pans twice on mobile, and pinching pans while zooming.
	if not _touch_points.is_empty() \
			and (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	if event is InputEventMouseButton:
		var btn := event as InputEventMouseButton
		if btn.button_index == MOUSE_BUTTON_LEFT:
			_mouse_down = btn.pressed
			if btn.pressed:
				_is_dragging = false
				_drag_start = btn.position
			else:
				_is_dragging = false
		elif btn.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and btn.pressed:
			accept_event()
			var dir := 1.0 if btn.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			_on_wheel(dir, btn.position)

	elif event is InputEventMouseMotion and _mouse_down:
		var motion := event as InputEventMouseMotion
		if not _is_dragging:
			if _drag_start.distance_squared_to(motion.position) < DRAG_DEADZONE * DRAG_DEADZONE:
				return
			_is_dragging = true
		_pan_by(motion.relative)

	# ── Touch: one finger = pan, two fingers = pinch-to-zoom ─────────────
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_points[touch.index] = touch.position
		else:
			_touch_points.erase(touch.index)
		if _touch_points.size() == 2:
			var pts := _touch_points.values()
			_prev_pinch_distance = (pts[0] as Vector2).distance_to(pts[1] as Vector2)

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_touch_points[drag.index] = drag.position

		if _touch_points.size() < 2:
			_pan_by(drag.relative)
		else:
			var pts := _touch_points.values()
			var a := pts[0] as Vector2
			var b := pts[1] as Vector2
			var cur := a.distance_to(b)
			# Spreading the fingers by a factor f zooms in by ln(f) in log space.
			if _prev_pinch_distance > 1.0 and cur > 1.0:
				_zoom_at(log(cur / _prev_pinch_distance), (a + b) * 0.5)
			_prev_pinch_distance = cur


func _pan_by(rel: Vector2) -> void:
	# Content follows the cursor 1:1
	var per_px := 2.0 * _view_half_h() / size.y
	_cx -= rel.x * per_px
	_cy -= rel.y * per_px
	_anchor_active = false


func _on_wheel(dir: float, pos: Vector2) -> void:
	_zoom_at(dir * ZOOM_STEP, pos)


func _zoom_at(d_log: float, pos: Vector2) -> void:
	var u := pos.x / size.x
	var v := pos.y / size.y
	_anchor_wx = _world_x_at(u)
	_anchor_wy = _world_y_at(v)
	_anchor_u = u
	_anchor_v = v
	_anchor_active = not _auto_on
	_t_log_zoom = clampf(_t_log_zoom + d_log, _min_log_zoom(), _max_log_zoom())


func _update_motion(delta: float) -> void:
	if absf(_t_log_zoom - _log_zoom) < 1e-9:
		return
	var s := 1.0 - exp(-ZOOM_SMOOTHING * delta)
	_log_zoom = lerpf(_log_zoom, _t_log_zoom, s)
	if absf(_t_log_zoom - _log_zoom) < 1e-4:
		_log_zoom = _t_log_zoom
	if _anchor_active:
		var vh := _view_half_h()
		var aspect := size.x / size.y
		_cx = _anchor_wx - (_anchor_u - 0.5) * 2.0 * vh * aspect
		_cy = _anchor_wy - (_anchor_v - 0.5) * 2.0 * vh
		if _log_zoom == _t_log_zoom:
			_anchor_active = false


# ============================================================
#  AUTO EXPLORATION
# ============================================================

func _poi_list() -> Array:
	match _fractal_type:
		1: return POIS_JULIA
		2: return POIS_SHIP
		3: return POIS_TRICORN
		_: return POIS_MANDEL


func _pick_poi(idx: int) -> void:
	var pois := _poi_list()
	_poi_idx = idx % pois.size()
	var poi: Array = pois[_poi_idx]
	_poi_x = poi[0]
	_poi_y = poi[1]
	_poi_max_lz = minf(log(float(poi[2])), _max_log_zoom())


func _overview_log_zoom() -> float:
	return log(0.8)


func _update_auto(delta: float) -> void:
	if not _auto_on or _mouse_down:
		return
	match _auto_phase:
		AutoPhase.DIVE:
			var head := clampf((_poi_max_lz - _log_zoom) / 1.5, 0.08, 1.0)
			var rate := _auto_speed * LN10 * head
			var prev_lz := _log_zoom
			_log_zoom = minf(_log_zoom + rate * delta, _poi_max_lz)
			_t_log_zoom = _log_zoom
			# Pin the POI on screen while zooming, with a gentle pull to center
			var ratio := exp(prev_lz - _log_zoom)
			var pull := exp(-delta * 0.8)
			_cx = _poi_x + (_cx - _poi_x) * ratio * pull
			_cy = _poi_y + (_cy - _poi_y) * ratio * pull
			if _log_zoom >= _poi_max_lz - 1e-6:
				_auto_phase = AutoPhase.HOLD
				_auto_hold = 0.0
		AutoPhase.HOLD:
			_auto_hold += delta
			if _auto_hold >= 2.0:
				_auto_phase = AutoPhase.RISE
		AutoPhase.RISE:
			var head := clampf((_log_zoom - _overview_log_zoom()) / 1.5, 0.08, 1.0)
			_log_zoom = maxf(_log_zoom - _auto_speed * LN10 * 2.5 * head * delta, _overview_log_zoom())
			_t_log_zoom = _log_zoom
			if _log_zoom <= _overview_log_zoom() + 1e-6:
				_pick_poi(_poi_idx + 1)
				_auto_phase = AutoPhase.DIVE


func _update_julia_morph(delta: float) -> void:
	if not _julia_morph or _fractal_type != 1:
		return
	_julia_theta += delta * 0.08
	_julia_re = 0.7885 * cos(_julia_theta)
	_julia_im = 0.7885 * sin(_julia_theta)


# ============================================================
#  RENDER STATE MACHINE
# ============================================================

func _params_hash() -> int:
	return hash([
		_cx, _cy, _log_zoom, _fractal_type, _julia_re, _julia_im,
		_iterations_full(), _aa_quality, _trap_shape, _trap_scale,
		_view_high.size.x, _view_high.size.y,
	])


func _update_render_state(_delta: float) -> void:
	var h := _params_hash()
	var dirty := h != _last_hash
	_last_hash = h

	if dirty:
		_settle = 0.0
		_state = RState.MOVING
		_render_live(_mat_low, _view_low, mini(_iterations_full(), INTERACT_ITER_CAP))
		_set_blend(0.0)
		return

	match _state:
		RState.MOVING:
			_settle += _delta
			if _settle >= SETTLE_TIME:
				_begin_refine()
		RState.REFINING:
			_refine_step()
		RState.IDLE:
			pass


func _render_live(mat: ShaderMaterial, viewport: SubViewport, iters: int) -> void:
	_apply_view_uniforms(mat, iters, 1)
	mat.set_shader_parameter("band_y_min", 0)
	mat.set_shader_parameter("band_y_max", 1000000)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _begin_refine() -> void:
	_state = RState.REFINING
	_refine_row = 0
	_apply_view_uniforms(_mat_high, _iterations_full(), _aa_quality)
	_refine_step()


func _refine_step() -> void:
	_mat_high.set_shader_parameter("band_y_min", _refine_row)
	_mat_high.set_shader_parameter("band_y_max", _refine_row + REFINE_BAND_ROWS)
	_view_high.render_target_update_mode = SubViewport.UPDATE_ONCE
	_refine_row += REFINE_BAND_ROWS
	if _refine_row >= _view_high.size.y:
		_state = RState.IDLE
		_fade_blend_to_high()


func _set_blend(v: float) -> void:
	if _blend_tween:
		_blend_tween.kill()
		_blend_tween = null
	_mat_display.set_shader_parameter("refine_blend", v)


func _fade_blend_to_high() -> void:
	if _blend_tween:
		_blend_tween.kill()
	_blend_tween = create_tween()
	var from: float = _mat_display.get_shader_parameter("refine_blend")
	_blend_tween.tween_method(
		func(v: float) -> void: _mat_display.set_shader_parameter("refine_blend", v),
		from, 1.0, 0.15
	)


# ============================================================
#  UNIFORMS + REFERENCE ORBIT
# ============================================================

func _apply_view_uniforms(mat: ShaderMaterial, iters: int, aa: int) -> void:
	var zoom := _zoom()
	var pert := _fractal_type <= 1 and zoom > PERT_ZOOM_THRESHOLD
	if pert:
		_ensure_ref_orbit(iters)
	mat.set_shader_parameter("fractal_type", _fractal_type)
	mat.set_shader_parameter("julia_c", Vector2(_julia_re, _julia_im))
	mat.set_shader_parameter("max_iterations", iters)
	mat.set_shader_parameter("view_center", Vector2(_cx, _cy))
	mat.set_shader_parameter("view_half", VIEW_BASE / zoom)
	mat.set_shader_parameter("use_perturbation", pert)
	if pert:
		mat.set_shader_parameter("dc_origin", Vector2(_cx - _ref_x, _cy - _ref_y))
		mat.set_shader_parameter("ref_orbit", _orbit_tex)
		mat.set_shader_parameter("ref_len", _orbit_len)
	mat.set_shader_parameter("trap_shape", _trap_shape)
	mat.set_shader_parameter("trap_scale", _trap_scale)
	mat.set_shader_parameter("aa_quality", aa)


func _ensure_ref_orbit(iters: int) -> void:
	var span := 2.0 * _view_half_h() * (size.x / size.y)
	var dx := _cx - _ref_x
	var dy := _cy - _ref_y
	var need := _orbit_len == 0 \
		or _orbit_type != _fractal_type \
		or (_fractal_type == 1 and (_orbit_jre != _julia_re or _orbit_jim != _julia_im)) \
		or (not _orbit_escaped and iters + 2 > _orbit_len) \
		or (dx * dx + dy * dy) > (4.0 * span) * (4.0 * span)
	if need:
		_compute_ref_orbit(iters)


func _compute_ref_orbit(iters: int) -> void:
	_ref_x = _cx
	_ref_y = _cy
	var n := int(float(iters) * 1.25) + 64
	var pts := PackedFloat32Array()
	pts.resize(n * 2)

	var zx := 0.0
	var zy := 0.0
	var ccx := _ref_x
	var ccy := _ref_y
	if _fractal_type == 1:
		zx = _ref_x
		zy = _ref_y
		ccx = _julia_re
		ccy = _julia_im

	var count := 0
	var escaped := false
	for i in n:
		pts[i * 2] = zx
		pts[i * 2 + 1] = zy
		count = i + 1
		if zx * zx + zy * zy > 1.0e10:
			escaped = true
			break
		var t := zx * zx - zy * zy + ccx
		zy = 2.0 * zx * zy + ccy
		zx = t

	var rows := maxi(int(ceil(float(count) / ORBIT_TEX_W)), 1)
	pts.resize(ORBIT_TEX_W * rows * 2)
	var img := Image.create_from_data(ORBIT_TEX_W, rows, false, Image.FORMAT_RGF, pts.to_byte_array())

	if _orbit_tex != null and _orbit_tex.get_size() == Vector2(ORBIT_TEX_W, rows):
		_orbit_tex.update(img)
	else:
		_orbit_tex = ImageTexture.create_from_image(img)

	_orbit_len = count
	_orbit_escaped = escaped
	_orbit_type = _fractal_type
	_orbit_jre = _julia_re
	_orbit_jim = _julia_im


# ============================================================
#  VIEWPORT SIZING
# ============================================================

func _resize_viewports() -> void:
	var win := get_window().size
	_view_high.size = Vector2i(maxi(win.x, 8), maxi(win.y, 8))
	_view_low.size = Vector2i(maxi(win.x / 2, 4), maxi(win.y / 2, 4))
	_rect_high.size = Vector2(_view_high.size)
	_rect_low.size = Vector2(_view_low.size)


# ============================================================
#  UI
# ============================================================

func _setup_ui() -> void:
	_menu.title = "2D Fractal Explorer"

	_menu.add_separator()
	_menu.add_section("Fractal")
	_menu.add_option_button("Type", ["Mandelbrot", "Julia", "Burning Ship", "Tricorn"], 0,
		func(idx: int) -> void:
			_fractal_type = idx
			_pick_poi(0)
			_reset_view_for_type()
	)

	_menu.add_separator()
	_menu.add_section("Julia")
	_menu.add_slider("Julia Re", -2.0, 2.0, _julia_re, func(v: float) -> void: _julia_re = v)
	_menu.add_slider("Julia Im", -2.0, 2.0, _julia_im, func(v: float) -> void: _julia_im = v)
	_menu.add_toggle("Animate Julia", _julia_morph, func(on: bool) -> void:
		_julia_morph = on
		if on:
			_julia_theta = atan2(_julia_im, _julia_re)
	)

	_menu.add_separator()
	_menu.add_section("Navigation")
	_menu.add_toggle("Auto Explore", _auto_on, func(on: bool) -> void:
		_auto_on = on
		if on:
			_auto_phase = AutoPhase.DIVE
			_anchor_active = false
			_t_log_zoom = _log_zoom
	)
	_menu.add_slider("Dive Speed", 0.1, 1.5, _auto_speed, func(v: float) -> void: _auto_speed = v)

	_menu.add_separator()
	_menu.add_section("Color")
	_menu.add_option_button("Mode", ["Cosmic", "Orbit Trap", "HSV Cycle", "Thermal"], 0,
		func(idx: int) -> void: _mat_display.set_shader_parameter("color_mode", idx))
	_menu.add_slider("Speed", 0.0, 5.0, 0.3,
		func(v: float) -> void: _mat_display.set_shader_parameter("color_speed", v))
	_menu.add_slider("Offset", 0.0, 1.0, 0.0,
		func(v: float) -> void: _mat_display.set_shader_parameter("color_offset", v))
	_menu.add_slider("Edge Shade", 0.0, 1.0, 0.35,
		func(v: float) -> void: _mat_display.set_shader_parameter("edge_strength", v))

	_menu.add_separator()
	_menu.add_section("Orbit Trap")
	_menu.add_option_button("Shape", ["Circle", "Line", "Cross", "Flower"], 0,
		func(idx: int) -> void: _trap_shape = idx)
	_menu.add_slider("Scale", 0.1, 5.0, _trap_scale, func(v: float) -> void: _trap_scale = v)

	_menu.add_separator()
	_menu.add_section("Quality")
	_menu.add_slider("Anti-Alias", 1, 3, float(_aa_quality),
		func(v: float) -> void: _aa_quality = int(v))
	_menu.add_toggle("Auto Iterations", _auto_iters, func(on: bool) -> void: _auto_iters = on)
	_menu.add_slider("Max Iterations", 100, 20000, float(_manual_iters),
		func(v: float) -> void: _manual_iters = int(v))

	_menu.add_separator()
	_menu.add_section("Info")
	_lbl_zoom = _menu.add_label("Zoom: 1.00e+00")
	_lbl_iters = _menu.add_label("Iterations: 0")
	_lbl_state = _menu.add_label("State: idle")

	_menu.add_separator()
	_menu.add_button("Reset View", _reset_view_for_type)


func _fmt_zoom(z: float) -> String:
	if z < 1000.0:
		return "%.1f" % z
	var e := int(floor(log(z) / LN10))
	var m := z / pow(10.0, e)
	return "%.2fe%d" % [m, e]


func _update_labels(delta: float) -> void:
	_label_timer += delta
	if _label_timer < 0.1:
		return
	_label_timer = 0.0
	_lbl_zoom.text = "Zoom: " + _fmt_zoom(_zoom())
	_lbl_iters.text = "Iterations: %d" % _iterations_full()
	match _state:
		RState.MOVING:
			_lbl_state.text = "State: rendering"
		RState.REFINING:
			var pct := int(100.0 * float(_refine_row) / maxf(float(_view_high.size.y), 1.0))
			_lbl_state.text = "State: refining %d%%" % mini(pct, 100)
		RState.IDLE:
			_lbl_state.text = "State: idle"


func _reset_view_for_type() -> void:
	match _fractal_type:
		1: _cx = 0.0; _cy = 0.0
		2: _cx = -1.72; _cy = -0.04
		3: _cx = 0.0; _cy = 0.0
		_: _cx = -0.6; _cy = 0.0
	_log_zoom = _overview_log_zoom()
	_t_log_zoom = _log_zoom
	_anchor_active = false
	_orbit_len = 0
	_auto_phase = AutoPhase.DIVE
