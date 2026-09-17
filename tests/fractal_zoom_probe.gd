extends SceneTree

## F-FR2-1 probe: Julia perturbation vs Mandelbrot rebasing at deep zoom.
##
## Boots the real fractal_demo scene, drives the real FractalCamera to fixed
## deep-zoom targets, saves the displayed frame, then reads back the high
## viewport iteration data and compares it against a float64 CPU reference
## evaluated at the same pixel centers. Deviations beyond float32 boundary
## fuzz mean the perturbation path misrenders (glitch blobs).
##
## Run under tools/capture.sh-style virtual display env; output lines start
## with "FR2 " and PNGs land in res://tmp/fr2/.

const VIEW_BASE := 1.75
const BAILOUT2 := 65536.0
const VIEW_W := 1280
const VIEW_H := 720
const SAMPLE_STEP := 12
const JULIA_RE := -0.7269
const JULIA_IM := 0.1889

var _targets: Array = []


func _initialize() -> void:
	call_deferred("_run")


static func _f32(v: float) -> float:
	var p := PackedFloat32Array([v])
	return p[0]


static func _complex_sqrt(x: float, y: float) -> Vector2:
	var r := sqrt(x * x + y * y)
	return Vector2(
		sqrt(maxf((r + x) * 0.5, 0.0)),
		signf(y) * sqrt(maxf((r - x) * 0.5, 0.0))
	)


func _run() -> void:
	for i in 2:
		await process_frame

	var c := Vector2(JULIA_RE, JULIA_IM)
	# Repelling fixed point of z^2 + c: always on the Julia set boundary.
	var fp := (Vector2.ONE + _complex_sqrt(1.0 - 4.0 * c.x, -4.0 * c.y)) * 0.5
	# Preimage of the critical point: the orbit passes through ~0.
	var pc := _complex_sqrt(-c.x, -c.y)
	# Depth-3 preimage of the fixed point, principal branch each time.
	var p3 := fp
	for i in 3:
		var d := p3 - c
		p3 = _complex_sqrt(d.x, d.y)

	var ln10 := 2.302585092994046
	_targets = [
		["mandel_1e6", 0, -0.743643887037151, 0.131825904205330, 6.0 * ln10],
		["mandel_1e9", 0, -0.743643887037151, 0.131825904205330, 9.0 * ln10],
		["julia_fp_1e6", 1, fp.x, fp.y, 6.0 * ln10],
		["julia_fp_1e9", 1, fp.x, fp.y, 9.0 * ln10],
		["julia_fp_1e10", 1, fp.x, fp.y, 10.0 * ln10],
		["julia_pc_1e6", 1, pc.x, pc.y, 6.0 * ln10],
		["julia_pc_1e9", 1, pc.x, pc.y, 9.0 * ln10],
		["julia_pc_1e10", 1, pc.x, pc.y, 10.0 * ln10],
		["julia_p3fp_1e9", 1, p3.x, p3.y, 9.0 * ln10],
	]

	root.size = Vector2i(VIEW_W, VIEW_H)
	var demo: Node = load("res://scenes/fractal_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	root.size = Vector2i(VIEW_W, VIEW_H)

	var cam: FractalCamera = demo._camera
	var view: FractalView = demo._view
	view.resize(root.size)
	demo._autopilot.enabled = false
	view.aa_quality = 1

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp/fr2"))

	for target in _targets:
		await _run_target(cam, view, target)

	print("FR2 PROBE DONE")
	quit(0)


func _run_target(cam: FractalCamera, view: FractalView, target: Array) -> void:
	var tname: String = target[0]
	cam.fractal_type = target[1]
	cam.center_x = target[2]
	cam.center_y = target[3]
	cam.log_zoom = target[4]
	cam.target_log_zoom = target[4]
	cam.update_motion(1.0)
	view.invalidate_orbit()

	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if view.state == FractalView.State.IDLE:
			break
	if view.state != FractalView.State.IDLE:
		print("FR2 %s TIMEOUT state=%d" % [tname, view.state])
	# The display fades from the low-res preview to the refined high viewport;
	# grab only once the fade completed so the PNG matches the readback.
	var display_mat: ShaderMaterial = view.display.material
	deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var blend: float = display_mat.get_shader_parameter("refine_blend")
		if blend >= 0.999:
			break

	var shot := root.get_texture().get_image()
	shot.save_png(ProjectSettings.globalize_path("res://tmp/fr2/%s.png" % tname))
	var data: Image = view.view_high.get_texture().get_image()

	var iters: int = cam.iterations_full()
	var half := VIEW_BASE / cam.zoom()
	var metric := _compare(
		data, _f32(cam.center_x), _f32(cam.center_y), target[1], iters,
		VIEW_BASE * 2.0 * half * (float(VIEW_W) / float(VIEW_H)), 2.0 * half, tname
	)
	print("FR2 %s type=%d iters=%d total=%d cls_mismatch=%d big_mu=%d avg_dmu=%.4f" % [
		tname, target[1], iters, metric.total, metric.mismatch, metric.big_mu, metric.avg_dmu,
	])


func _compare(img: Image, seed_x: float, seed_y: float, ftype: int, iters: int,
		wsx: float, wsy: float, tname: String) -> Dictionary:
	var gx := 0
	var gy := 0
	for px in range(0, VIEW_W, SAMPLE_STEP):
		gx += 1
	for py in range(0, VIEW_H, SAMPLE_STEP):
		gy += 1
	var gpu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var cpu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var mask_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var dmu_img := Image.create(gx, gy, false, Image.FORMAT_RGB8)
	var total := 0
	var mismatch := 0
	var gpu_only := 0
	var cpu_only := 0
	var big_mu := 0
	var dmu_sum := 0.0
	var dmu_signed := 0.0
	var dmu_n := 0
	var iy := 0
	for py in range(0, VIEW_H, SAMPLE_STEP):
		var off_y := ((float(py) + 0.5) / float(VIEW_H) - 0.5) * wsy
		var ix := 0
		for px in range(0, VIEW_W, SAMPLE_STEP):
			var off_x := ((float(px) + 0.5) / float(VIEW_W) - 0.5) * wsx
			var ref := _reference(ftype, seed_x + off_x, seed_y + off_y, iters)
			var g := img.get_pixel(px, py)
			var gpu_escaped := g.a > 0.5
			total += 1
			var gpu_mu := floorf(g.r) * 64.0 + g.g
			gpu_img.set_pixel(ix, iy, _dbg_color(gpu_escaped, gpu_mu, iters))
			cpu_img.set_pixel(ix, iy, _dbg_color(ref.escaped, ref.mu, iters))
			var bad: bool = gpu_escaped != ref.escaped
			if bad:
				mismatch += 1
				if gpu_escaped:
					gpu_only += 1
				else:
					cpu_only += 1
				mask_img.set_pixel(ix, iy, Color(1.0, 0.0, 0.0))
			else:
				mask_img.set_pixel(ix, iy, Color(0.0, 1.0, 0.0))
				if ref.escaped:
					var d := absf(gpu_mu - ref.mu)
					var signed: float = gpu_mu - ref.mu
					dmu_sum += d
					dmu_signed += signed
					dmu_n += 1
					var t := clampf(absf(signed) / 200.0, 0.0, 1.0)
					dmu_img.set_pixel(ix, iy,
						Color(1.0 - t if signed < 0.0 else 0.0, 1.0 - t if signed > 0.0 else 0.0, 0.0))
					if d > 1.0:
						big_mu += 1
				else:
					dmu_img.set_pixel(ix, iy, Color(0.0, 0.0, 0.0))
			ix += 1
		iy += 1
	var base := ProjectSettings.globalize_path("res://tmp/fr2/%s" % tname)
	gpu_img.save_png(base + "_gpu.png")
	cpu_img.save_png(base + "_cpu.png")
	mask_img.save_png(base + "_mask.png")
	dmu_img.save_png(base + "_dmu.png")
	print("FR2 %s gpu_only=%d cpu_only=%d signed_dmu=%.3f" % [tname, gpu_only, cpu_only,
		dmu_signed / maxf(float(dmu_n), 1.0)])
	return {
		"total": total,
		"mismatch": mismatch,
		"big_mu": big_mu,
		"avg_dmu": dmu_sum / maxf(float(dmu_n), 1.0),
	}


func _dbg_color(escaped: bool, mu: float, iters: int) -> Color:
	if not escaped:
		return Color(0.0, 0.0, 0.0)
	var t := clampf(mu / float(iters), 0.0, 1.0)
	return Color(t, t, t)


func _reference(ftype: int, x0: float, y0: float, iters: int) -> Dictionary:
	var zx := 0.0
	var zy := 0.0
	var cx := x0
	var cy := y0
	if ftype == 1:
		zx = x0
		zy = y0
		cx = JULIA_RE
		cy = JULIA_IM
	var n := 0.0
	var escaped := false
	for i in iters:
		var t := zx * zx - zy * zy + cx
		zy = 2.0 * zx * zy + cy
		zx = t
		n += 1.0
		if zx * zx + zy * zy > BAILOUT2:
			escaped = true
			break
	var mu := float(iters)
	if escaped:
		var log_zn := log(zx * zx + zy * zy) * 0.5
		var nu := log(log_zn / 5.545177444479562) / 0.6931471805599453
		mu = n + 1.0 - nu
	return {"escaped": escaped, "mu": mu}
