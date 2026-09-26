extends SceneTree
## Generic demo screenshot runner driven by tools/capture.sh, for visual inspection
## of any demo without opening a window on the desktop.
##
##   godot -s res://tools/capture_demo.gd -- ocean_demo frames=180
##   godot -s res://tools/capture_demo.gd -- res://scenes/ocean_demo.tscn out=res://tmp/x.png
##
## `target` is a GameManager.DEMOS key or a res:// scene path; with `every=N` a
## numbered PNG is written every N frames, including the final frame at
## `frames` — the numbered files are the whole sequence, `out` is only used as
## their basename. Grabs happen in
## frame_post_draw because a _process grab comes back one frame stale.

const DEFAULT_FRAMES := 120

var _frames := DEFAULT_FRAMES
var _every := 0
var _out := ""
var _size := Vector2i(1280, 720)
var _scene_path := ""
var _demo: Node = null
var _preset := -1
var _height_gain := -1.0
var _look := -1
var _mood := -1.0
var _profile := false
var _quality := -1
var _features := true
var _clouds := true
var _view := ""
var _hide_ui := true
var _freeze := false
var _capture_time := -1.0
var _fixed_delta := -1.0
var _warmup := 90
var _wind_direction := -1.0
var _sun_elevation := -1.0
var _sun_azimuth := -1.0
var _debug_view := -1
var _cascade := -1
var _scene := -1
var _flow := -1.0
var _foam_feedback := true
var _micro_normals := true
var _reflection := true
var _coverage := false
var _mood_snap := false
var _lightning := false
var _interaction := false
var _rain := true
var _spray := true
var _foam_warmup := 0.0
var _foam_distance := -1.0
var _detail_distance := -1.0
var _camera_speed := 0.0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var split: PackedStringArray = arg.split("=", true, 1)
		if split.size() == 1:
			_set_target(arg)
			continue
		var value: String = split[1]
		match String(split[0]):
			"target": _set_target(value)
			"frames": _frames = maxi(1, int(value))
			"every": _every = maxi(0, int(value))
			"out": _out = value
			"preset": _preset = int(value)
			"height": _height_gain = float(value)
			"look": _look = int(value)
			"mood": _mood = float(value)
			"profile": _profile = value == "1" or value.to_lower() == "true"
			"quality": _quality = _quality_tier(value)
			"features": _features = value != "0" and value.to_lower() != "false"
			"clouds": _clouds = value != "0" and value.to_lower() != "false"
			"view": _view = value
			"ui": _hide_ui = value == "0" or value.to_lower() == "false"
			"freeze": _freeze = value == "1" or value.to_lower() == "true"
			"time": _capture_time = float(value)
			"dt": _fixed_delta = maxf(float(value), 0.0)
			"warmup": _warmup = maxi(0, int(value))
			"wind": _wind_direction = float(value)
			"sun_elevation": _sun_elevation = float(value)
			"sun_azimuth": _sun_azimuth = float(value)
			"debug": _debug_view = int(value)
			"cascade": _cascade = int(value)
			"scene": _scene = int(value)
			"flow": _flow = float(value)
			"foam": _foam_feedback = value != "0" and value.to_lower() != "false"
			"micro": _micro_normals = value != "0" and value.to_lower() != "false"
			"reflection": _reflection = value != "0" and value.to_lower() != "false"
			"coverage": _coverage = value == "1" or value.to_lower() == "true"
			"mood_snap": _mood_snap = value == "1" or value.to_lower() == "true"
			"lightning": _lightning = value == "1" or value.to_lower() == "true"
			"interaction": _interaction = value == "1" or value.to_lower() == "true"
			"rain": _rain = value != "0" and value.to_lower() != "false"
			"spray": _spray = value != "0" and value.to_lower() != "false"
			"foam_warmup": _foam_warmup = maxf(float(value), 0.0)
			"foam_distance": _foam_distance = float(value)
			"detail_distance": _detail_distance = float(value)
			"camera_speed": _camera_speed = float(value)
			"size":
				var dims := value.split("x")
				if dims.size() == 2:
					_size = Vector2i(maxi(16, int(dims[0])), maxi(16, int(dims[1])))
	# Unique default so concurrent captures never overwrite each other.
	if _out.is_empty():
		_out = "res://tmp/capture-%d.png" % OS.get_process_id()
	if _scene_path == "":
		push_error("CAPTURE FAIL: no target given")
		quit(1)
		return
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("CAPTURE FAIL: cannot load %s" % _scene_path)
		quit(1)
		return
	root.size = _size
	_demo = packed.instantiate()
	root.add_child(_demo)
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var ready_deadline := Time.get_ticks_msec() + 20000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() and Time.get_ticks_msec() < ready_deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("CAPTURE FAIL: target did not become ready")
		quit(1)
		return
	if _look >= 0 and _demo.has_method("apply_look"):
		_demo.apply_look(_look)
	if _quality >= 0 and _demo.has_method("set_quality_profile"):
		_demo.set_quality_profile(_quality)
	if _preset >= 0 and _demo.has_method("apply_preset"):
		_demo.apply_preset(_preset)
	ready_deadline = Time.get_ticks_msec() + 20000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() and Time.get_ticks_msec() < ready_deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("CAPTURE FAIL: quality resources did not become ready")
		quit(1)
		return
	if _height_gain >= 0.0 and _demo.has_method("set_capture_height_gain"):
		_demo.set_capture_height_gain(_height_gain)
	if _wind_direction >= 0.0 and _demo.has_method("set_capture_wind_direction"):
		_demo.set_capture_wind_direction(_wind_direction)
	if _sun_elevation >= 0.0 and _demo.has_method("set_sun_elevation"):
		_demo.set_sun_elevation(_sun_elevation)
	if _sun_azimuth >= 0.0 and _demo.has_method("set_sun_azimuth"):
		_demo.set_sun_azimuth(_sun_azimuth)
	if _mood >= 0.0 and _demo.has_method("set_storm_mood"):
		_demo.set_storm_mood(_mood)
	if _mood_snap and _mood >= 0.0 and _demo.has_method("set_capture_storm"):
		_demo.set_capture_storm(_mood, _lightning)
	if _demo.has_method("set_capture_rain"):
		_demo.set_capture_rain(_rain)
	if _demo.has_method("set_capture_spray"):
		_demo.set_capture_spray(_spray)
	if not _view.is_empty() and _demo.has_method("set_capture_view"):
		_demo.set_capture_view(_view)
	if _demo.has_method("set_capture_interaction"):
		_demo.set_capture_interaction(_interaction)
	if _capture_time >= 0.0 and _demo.has_method("set_capture_time"):
		_demo.set_capture_time(_capture_time)
	if _demo.has_method("set_capture_ui"):
		_demo.set_capture_ui(not _hide_ui)
	if not _features and _demo.has_method("set_render_features"):
		_demo.set_render_features(false)
	elif not _clouds and _demo.has_method("set_clouds_enabled"):
		_demo.set_clouds_enabled(false)
	if _demo.has_method("set_capture_micro_normals"):
		_demo.set_capture_micro_normals(_micro_normals)
	if _demo.has_method("set_capture_reflection"):
		_demo.set_capture_reflection(_reflection)
	if _demo.has_method("set_capture_debug"):
		_demo.set_capture_debug(_debug_view if _debug_view >= 0 else 0)
	if _scene >= 0 and _demo.has_method("set_capture_scene"):
		_demo.set_capture_scene(_scene)
	if _demo.has_method("set_capture_cascade"):
		_demo.set_capture_cascade(_cascade)
	elif _cascade >= 0:
		# The fluid demo replaced its cascade hook with set_capture_scene
		# (pool/cascade/basin share the indices); fail loudly rather than
		# capturing the wrong scene silently.
		if _demo.has_method("set_capture_scene") and _cascade <= 2:
			_demo.set_capture_scene(_cascade)
		else:
			push_error("CAPTURE FAIL: cascade=%d has no hook on this demo" % _cascade)
			quit(1)
			return
	if _flow >= 0.0 and _demo.has_method("set_capture_flow"):
		_demo.set_capture_flow(_flow)
	if _demo.has_method("set_capture_foam"):
		_demo.set_capture_foam(_foam_feedback)
	if _foam_distance >= 0.0 and _demo.has_method("set_foam_distance"):
		_demo.set_foam_distance(_foam_distance)
	if _detail_distance >= 0.0 and _demo.has_method("set_detail_distance"):
		_demo.set_detail_distance(_detail_distance)
	# UserSettings restores the persisted window size once the autoloads are in;
	# force the requested size back so captures are deterministic.
	root.size = _size
	if _demo.has_method("set_capture_fixed_delta"):
		_demo.set_capture_fixed_delta(_fixed_delta)
	if _demo.has_method("set_frozen"):
		_demo.set_frozen(true)
	for frame in _warmup:
		await process_frame
	if _capture_time >= 0.0 and _demo.has_method("set_capture_time"):
		_demo.set_capture_time(_capture_time)
	# Foam equilibrium warmup (fix plan 0.6): live steps between the spectral
	# time re-anchor and the unfreeze, so captured foam is stationary.
	if _foam_warmup > 0.0 and _demo.has_method("warmup_foam"):
		await _demo.warmup_foam(_foam_warmup)
		_demo.set_frozen(true)
	if _coverage and _demo.has_method("set_capture_debug"):
		_demo.set_capture_debug(1)
		await process_frame
		await RenderingServer.frame_post_draw
		var coverage_image := root.get_texture().get_image()
		if _demo.has_method("capture_water_coverage"):
			print("CAPTURE COVERAGE water=%.4f" % _demo.capture_water_coverage(coverage_image))
		_demo.set_capture_debug(_debug_view if _debug_view >= 0 else 0)
		await process_frame
		if _capture_time >= 0.0 and _demo.has_method("set_capture_time"):
			_demo.set_capture_time(_capture_time)
	if _profile and _demo.has_method("set_capture_profiling"):
		_demo.set_capture_profiling(true)
	if _demo.has_method("set_frozen"):
		_demo.set_frozen(_freeze)
	print("CAPTURE CONFIG preset=%d look=%d view=%s quality=%s time=%.6f dt=%.6f warmup=%d foam_warmup=%.1f foam_distance=%.1f wind=%.6f sun_elevation=%.3f sun_azimuth=%.3f frames=%d every=%d size=%dx%d foam=%s micro=%s reflection=%s debug=%d scene=%d cascade=%d" % [
		_preset, _look, _view,
		OceanQualityProfile.tier_name(_quality) if _quality >= 0 else "default",
		_capture_time, _fixed_delta, _warmup,
		_foam_warmup, _foam_distance, _wind_direction, _sun_elevation, _sun_azimuth, _frames,
		_every, _size.x, _size.y, _foam_feedback, _micro_normals, _reflection,
		_debug_view, _scene, _cascade])
	var waited := 0
	var toss_frame := maxi(1, int(_frames / 3))
	while waited < _frames:
		if _camera_speed != 0.0 and _demo.has_method("move_capture_camera"):
			_demo.move_capture_camera(Vector3(_camera_speed * maxf(_fixed_delta, 1.0 / 60.0), 0.0, 0.0))
		if _interaction and _demo.has_method("throw_crate") and waited == toss_frame:
			_demo.throw_crate()
		if _every > 0 and waited > 0 and waited % _every == 0:
			await _grab(_numbered(waited))
		await process_frame
		waited += 1
	var final_numbered := _out if _every <= 0 else _numbered(waited)
	if _demo.has_method("set_frozen"):
		_demo.set_frozen(true)
	if _demo.has_method("capture_metadata_async"):
		print(await _demo.capture_metadata_async(final_numbered))
	elif _demo.has_method("capture_metadata"):
		print(_demo.capture_metadata(final_numbered))
	await _grab(final_numbered)
	print("CAPTURE DONE target=%s frames=%d" % [_scene_path, waited])
	quit(0)


func _set_target(value: String) -> void:
	if "://" in value:
		_scene_path = value
		for entry in GameManager.DEMOS:
			if entry.scene == value:
				root.get_node("GameManager").set("current_demo", entry.key)
				break
		return
	for entry in GameManager.DEMOS:
		if entry.key == value:
			_scene_path = entry.scene
			root.get_node("GameManager").set("current_demo", entry.key)
			return
	push_error("CAPTURE FAIL: unknown demo key %s" % value)
	quit(1)


## "low"/"medium"/"high"/"ultra" (the legacy "performance" name, or the raw
## tier index) -> SimQualityProfile tier.
func _quality_tier(value: String) -> int:
	var lowered := value.to_lower()
	if lowered == "performance":
		lowered = "low"
	for tier in OceanQualityProfile.TIER_NAMES.size():
		if lowered == OceanQualityProfile.TIER_NAMES[tier].to_lower():
			return tier
	return clampi(int(value), 0, OceanQualityProfile.TIER_NAMES.size() - 1)


func _grab(path: String, mirror_path: String = "") -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if _demo.has_method("capture_image_metrics"):
		print(_demo.capture_image_metrics(image))
	image.save_png(path)
	if not mirror_path.is_empty() and mirror_path != path:
		image.save_png(mirror_path)
	print("CAPTURE SHOT ", path)


func _numbered(frame: int) -> String:
	return "%s_%04d.png" % [_out.get_basename(), frame]
