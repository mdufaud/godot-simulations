extends SceneTree
## Quality-tier fps probe, driven by tools/fps_probe.sh: loads a demo, applies
## a tier through its SimQualityState, and reports the average fps over a
## wall-clock window with vsync off. Read-only with respect to persistence —
## GameManager.set_setting only touches the in-memory dictionary, and the
## process quits without saving.
##
##   godot -s res://tools/fps_probe.gd -- nbody_demo tier=medium
##   godot -s res://tools/fps_probe.gd -- ocean_demo tier=3 seconds=6 size=1280x720

const TIER_NAMES := ["low", "medium", "high", "ultra"]

var _scene_path := ""
var _tier := -1
var _seconds := 5.0
var _size := Vector2i(1920, 1080)
var _warmup := 90
var _demo: Node = null


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var split: PackedStringArray = arg.split("=", true, 1)
		if split.size() == 1:
			_set_target(arg)
			continue
		var value: String = split[1]
		match String(split[0]):
			"target": _set_target(value)
			"tier":
				var lowered := value.to_lower()
				_tier = TIER_NAMES.find(lowered)
				if _tier < 0:
					_tier = clampi(int(value), 0, TIER_NAMES.size() - 1)
			"seconds": _seconds = clampf(float(value), 1.0, 60.0)
			"warmup": _warmup = maxi(0, int(value))
			"size":
				var dims := value.split("x")
				if dims.size() == 2:
					_size = Vector2i(maxi(16, int(dims[0])), maxi(16, int(dims[1])))
	if _scene_path == "" or _tier < 0:
		push_error("FPS PROBE FAIL: need a demo target and tier=" + str(TIER_NAMES))
		quit(1)
		return
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("FPS PROBE FAIL: cannot load %s" % _scene_path)
		quit(1)
		return
	root.size = _size
	_demo = packed.instantiate()
	root.add_child(_demo)
	call_deferred("_run")


func _run() -> void:
	await process_frame
	if not await _wait_ready():
		return
	if _demo.has_method("set_quality_profile"):
		_demo.set_quality_profile(_tier)
	elif "quality" in _demo and _demo.quality is SimQualityState:
		_demo.quality.set_tier(_tier)
	else:
		push_error("FPS PROBE FAIL: %s has no quality state" % _scene_path)
		quit(1)
		return
	if not await _wait_ready():
		return
	# UserSettings restores the persisted window size once the autoloads are in;
	# force the requested size back so the measurement is deterministic.
	root.size = _size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for frame in _warmup:
		await process_frame
	var frames := 0
	var t0 := Time.get_ticks_usec()
	var deadline := t0 + int(_seconds * 1_000_000.0)
	while Time.get_ticks_usec() < deadline:
		await process_frame
		frames += 1
	var elapsed := float(Time.get_ticks_usec() - t0) / 1_000_000.0
	print("FPS PROBE target=%s tier=%s fps=%.1f frames=%d seconds=%.2f size=%dx%d" % [
		_scene_path.get_file().get_basename(), TIER_NAMES[_tier],
		float(frames) / elapsed, frames, elapsed, _size.x, _size.y])
	quit(0)


## Same readiness contract as capture_demo: demos expose capture_ready() when
## their GPU resources are up, and a tier switch can rebuild them.
func _wait_ready() -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("FPS PROBE FAIL: target did not become ready")
		quit(1)
		return false
	return true


func _set_target(value: String) -> void:
	if "://" in value:
		_scene_path = value
		return
	for entry in GameManager.DEMOS:
		if entry.key == value:
			_scene_path = entry.scene
			return
	push_error("FPS PROBE FAIL: unknown demo key %s" % value)
	quit(1)
