extends SceneTree

const FRAME_LIMIT := 240

var _demo: Control
var _output := "/tmp/mixwell_capture.png"
var _preset := -1
var _boundary := -1
var _verify_gpu_ab := false
var _gpu_ab_requested := false
var _verify_oracle := false
var _oracle_requested := false
var _diagnostics_requested := false
var _drag_requested := false
var _drag_applied := false
var _drag_settle_frames := 0
var _example := -1
var _drag_count := 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and not args[0].is_empty():
		_output = args[0]
	for index in range(1, args.size()):
		var argument: String = args[index]
		if argument == "gpu_ab":
			_verify_gpu_ab = true
		elif argument == "oracle":
			_verify_oracle = true
		elif argument == "diagnostics":
			_diagnostics_requested = true
		elif argument == "drag":
			_drag_requested = true
		elif argument.begins_with("example="):
			_example = int(argument.trim_prefix("example="))
		elif argument.begins_with("drag_count="):
			_drag_count = maxi(1, int(argument.trim_prefix("drag_count=")))
		elif argument.is_valid_int():
			if _preset < 0:
				_preset = int(argument)
			elif _boundary < 0:
				_boundary = int(argument)
	root.size = Vector2i(640, 360)
	_demo = load("res://scenes/mixwell_demo.tscn").instantiate()
	root.add_child(_demo)
	if _preset >= 0:
		_demo.solver.set_preset(_preset)
	if _boundary >= 0:
		_demo.solver.set_boundary_mode(_boundary)
	if _diagnostics_requested or _verify_oracle or _verify_gpu_ab:
		_demo.solver.set_diagnostics_enabled(true)
	call_deferred("_capture_when_ready")


func _capture_when_ready() -> void:
	if _preset >= 0 or _boundary >= 0 or _example >= 0:
		await process_frame
		if _example >= 0:
			_demo._select_official_example(_example)
		if _preset >= 0:
			_demo.solver.set_preset(_preset)
		if _boundary >= 0:
			_demo.solver.set_boundary_mode(_boundary)
		_demo._request_reset()
	for _frame in FRAME_LIMIT:
		await process_frame
		if _drag_requested and not _drag_applied and _demo.solver.is_initialized():
			_drag_applied = true
			var canvas_size: Vector2 = _demo.size
			_demo._begin_stroke(canvas_size * Vector2(0.5, 0.5))
			_demo._append_stroke_point(canvas_size * Vector2(0.61, 0.38))
			_demo._finish_stroke(canvas_size * Vector2(0.72, 0.26))
			if _drag_count > 1:
				_demo._begin_stroke(canvas_size * Vector2(0.38, 0.62))
				_demo._append_stroke_point(canvas_size * Vector2(0.55, 0.48))
				_demo._finish_stroke(canvas_size * Vector2(0.64, 0.42))
		if _drag_requested and _drag_applied and _drag_settle_frames < 45:
			_drag_settle_frames += 1
			continue
		if _verify_gpu_ab and not _gpu_ab_requested and _demo.solver.is_initialized():
			_gpu_ab_requested = true
			RenderingServer.call_on_render_thread(_demo.solver.verify_periodic_gpu_ab)
		if _verify_oracle and not _oracle_requested and _demo.solver.is_initialized() \
				and _demo.solver.get_sample_count() >= 1:
			_oracle_requested = true
			RenderingServer.call_on_render_thread(_demo.solver.verify_gpu_oracle)
		if _verify_gpu_ab and not _demo.solver.get_gpu_periodic_comparison().is_empty():
			var comparison: Dictionary = _demo.solver.get_gpu_periodic_comparison()
			print("MIXWELL GPU A/B %s" % comparison)
			quit(0 if comparison.get("passes", false) else 1)
			return
		if _diagnostics_requested and _demo.solver.is_initialized() \
				and _demo.solver.get_metrics().get("sample", 0) >= 3:
			var metrics: Dictionary = _demo.solver.get_metrics()
			print("MIXWELL DIAGNOSTICS %s" % metrics)
			var valid := metrics.has("area_wall") and metrics.has("convergence_rms") \
					and metrics.has("convergence_p99")
			quit(0 if valid else 1)
			return
		if _verify_oracle and not _demo.solver.get_gpu_oracle_comparison().is_empty():
			var comparison: Dictionary = _demo.solver.get_gpu_oracle_comparison()
			print("MIXWELL GPU ORACLE %s" % comparison)
			quit(0 if comparison.get("passes", false) else 1)
			return
		if _demo.solver.is_initialized() and _demo.solver.get_sample_count() >= 4:
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var error := image.save_png(_output)
			if error != OK:
				printerr("MIXWELL CAPTURE FAIL: %s" % error_string(error))
				quit(1)
				return
			print("MIXWELL CAPTURE %s %d bytes" % [_output, image.get_data().size()])
			print("MIXWELL CAPTURE DONE")
			quit(0)
			return
	printerr("MIXWELL CAPTURE FAIL: solver did not reach four samples")
	quit(1)
