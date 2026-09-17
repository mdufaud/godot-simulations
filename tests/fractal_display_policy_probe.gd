extends SceneTree

## Display-policy probe: what the screen shows DURING zoom gestures.
##
## Boots the real fractal_demo scene with no harness and drives realistic
## wheel input (notched zoom with pauses) plus a continuous deep dive. The
## policy under test:
##   1. the preview pass always runs at the FULL iteration count the view
##      needs — a capped preview paints deep zooms black (blob) or false
##      structure; resolution, not iterations, is the cost knob;
##   2. the display follows the preview while moving (live current view, no
##      unbounded stretch of an older render);
##   3. after stillness the full-res refine lands and stays;
##   4. the autopilot (perpetual motion) keeps the same guarantees.
## Frame times are logged during gestures as a jank metric. PNGs land in
## res://tmp/policy/ for visual inspection.

const W := 1280
const H := 720
const LN10 := 2.302585092994046
const OUT_DIR := "res://tmp/policy"
const NOTCHES := 12
const NOTCH_FRAMES := 12

var _fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _fail(msg: String) -> void:
	_fails += 1
	print("POLICY FAIL: %s" % msg)


func _shot(name: String) -> float:
	var img := root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name]))
	var sum := 0.0
	var n := 0
	for py in range(0, H, 16):
		for px in range(0, W, 16):
			sum += img.get_pixel(px, py).get_luminance()
			n += 1
	var luma := sum / maxf(float(n), 1.0)
	print("POLICY SHOT %s luma=%.4f" % [name, luma])
	return luma


func _blend(view: FractalView) -> float:
	var raw: Variant = view.display.material.get_shader_parameter("refine_blend")
	return float(raw) if raw != null else 0.0


func _preview_iters(view: FractalView) -> int:
	return int(view._material_low.get_shader_parameter("max_iterations"))


func _wait_settled(view: FractalView, ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view.state == FractalView.State.IDLE and _blend(view) >= 0.999:
			return true
	return false


func _run() -> void:
	for i in 3:
		await process_frame
	root.size = Vector2i(W, H)
	var demo: Node = load("res://scenes/fractal_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(W, H)

	var cam: FractalCamera = demo._camera
	var view: FractalView = demo._view
	view.resize(root.size)
	demo._autopilot.enabled = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# ── Phase A: boot settles to the refined image ────────────────────────
	if not await _wait_settled(view, 10000):
		_fail("boot never settled (state=%d blend=%.3f)" % [view.state, _blend(view)])
		quit(1)
		return
	_shot("a_settled")

	# ── Phase B: realistic wheel scroll — notches with pauses ─────────────
	cam.fractal_type = 0
	cam.center_x = -0.743643887037151
	cam.center_y = 0.131825904205330
	cam.log_zoom = 3.0 * LN10
	cam.target_log_zoom = 3.0 * LN10
	view.invalidate_orbit()
	if not await _wait_settled(view, 10000):
		_fail("overview never settled before the gesture")
		quit(1)
		return
	var pre_luma := _shot("b_pre_zoom")

	var samples := 0
	var live := 0
	var capped := 0
	var max_delta := 0.0
	for notch in NOTCHES:
		cam.zoom_at(FractalCamera.ZOOM_STEP, Vector2(W * 0.5, H * 0.5), true)
		for f in NOTCH_FRAMES:
			var before := Time.get_ticks_usec()
			await process_frame
			max_delta = maxf(max_delta, float(Time.get_ticks_usec() - before) / 1.0e6)
			if f % 4 == 0:
				samples += 1
				var blend := _blend(view)
				var need := cam.iterations_full()
				var iters := _preview_iters(view)
				if iters < need:
					capped += 1
				if blend < 0.5:
					live += 1
				if notch >= NOTCHES - 3 and blend >= 0.5:
					_fail("wheel scroll end holds a stale image (blend=%.3f, need=%d)" % [
						blend, need])
				if iters != 0 and iters < need:
					_fail("preview runs capped: %d of %d iterations" % [iters, need])
	print("POLICY scroll live=%d/%d capped=%d/%d max_frame=%.3fs" % [
		live, samples, capped, samples, max_delta])
	if max_delta > 0.25:
		print("POLICY WARN: gesture frame spike %.3fs" % max_delta)
	_shot("b_scroll_late")

	# ── Phase C: continuous deep dive stays live and correct ──────────────
	if not await _wait_settled(view, 20000):
		_fail("post-scroll view never settled (state=%d)" % view.state)
	cam.target_log_zoom = 11.0 * LN10
	var became_live := false
	for f in 15:
		await process_frame
		if _blend(view) < 0.5:
			became_live = true
		if _preview_iters(view) < cam.iterations_full():
			_fail("dive preview capped at %d of %d iterations" % [
				_preview_iters(view), cam.iterations_full()])
	if not became_live:
		_fail("deep dive never switched to the live preview (blend=%.3f)" % _blend(view))
	print("POLICY dive live=%s blend=%.3f" % [became_live, _blend(view)])
	var mid_luma := _shot("c_dive_mid")
	if mid_luma < 0.25 * pre_luma:
		_fail("dive frame went dark (luma %.4f vs %.4f before)" % [mid_luma, pre_luma])

	# ── Phase D: stillness lands the refine ───────────────────────────────
	if not await _wait_settled(view, 20000):
		_fail("deep view never settled after the dive (state=%d)" % view.state)
	_shot("d_refined_deep")

	# ── Phase E: autopilot = perpetual motion ─────────────────────────────
	demo._autopilot.enabled = true
	demo._autopilot.restart()
	var saw_refined := false
	var auto_capped := false
	for f in 900:
		await process_frame
		if f % 90 == 0:
			print("POLICY auto f%03d blend=%.3f state=%d zoom=%.1f" % [
				f, _blend(view), view.state, cam.log_zoom / LN10])
		if f == 150:
			_shot("e_auto_moving")
		if view.state == FractalView.State.IDLE and _blend(view) >= 0.999:
			if not saw_refined:
				_shot("e_auto_hold")
			saw_refined = true
		if _preview_iters(view) != 0 and _preview_iters(view) < cam.iterations_full():
			auto_capped = true
	demo._autopilot.enabled = false
	if auto_capped:
		_fail("autopilot previews ran below the needed iteration count")
	if not saw_refined:
		_fail("autopilot never landed a refined image during its holds")
	else:
		print("POLICY autopilot reached a refined image during holds")

	if _fails == 0:
		print("POLICY PROBE PASS")
	else:
		print("POLICY PROBE FAIL (%d)" % _fails)
	quit(1 if _fails > 0 else 0)
