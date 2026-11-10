extends "res://tests/test_case.gd"
## Flight law of FreeFlyCamera against the 3D fractal distance estimators: ten
## seconds of full forward thrust from every preset, along two look directions.

const FractalDEScript := preload("res://scripts/fractal_3d/fractal_de.gd")
const Controller := preload("res://scripts/demos/fractal_3d_controller.gd")

const DT := 1.0 / 60.0
const FRAMES := 600
const LOOKS: Array[Vector2] = [Vector2(0.0, 0.0), Vector2(-39.0, -17.5)]  # yaw, pitch
## Frame-to-frame speed change, in decades, counted as a lurch.
const LURCH_DECADES := 0.15
const MAX_LURCH_RATIO := 0.01
## Longest acceptable median time to reach what the view centre shows, at the
## default speed: the flight follows the scale of what is on screen.
const MAX_MEDIAN_CONTACT_S := 10.0

var _camera_script: GDScript = load("res://scripts/camera/free_fly_camera.gd")
var _params: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("camera="):
			_camera_script = load(arg.trim_prefix("camera="))
	_run.call_deferred()


func _run() -> void:
	# Nodes only become ready once the main loop runs.
	await process_frame
	Input.action_press("move_forward")
	var lurches := 0
	var frames := 0
	for fractal_type: int in Controller.PRESETS:
		for preset: Dictionary in Controller.PRESETS[fractal_type]:
			_params = Controller.BASE_PARAMS.duplicate(true)
			for key in preset:
				_params[key] = preset[key]
			_params["fractal_type"] = fractal_type
			for look in LOOKS:
				var result := _fly(str(preset["name"]), preset["cam"], look)
				lurches += result.x
				frames += result.y
	Input.action_release("move_forward")
	var ratio := float(lurches) / float(maxi(frames, 1))
	print("FLIGHT lurch frames %d / %d (%.2f%%)" % [lurches, frames, 100.0 * ratio])
	_check(ratio <= MAX_LURCH_RATIO, "flight speed lurches on %.2f%% of the frames" % (100.0 * ratio))
	_finish("free_fly_camera")


func _de(p: Vector3) -> float:
	return FractalDEScript.evaluate(p, _params)


func _de_at(x: float, y: float, z: float) -> float:
	return FractalDEScript.evaluate_at(x, y, z, _params)


func _ray(from: Vector3, direction: Vector3) -> float:
	var t := 0.0
	for i in 64:
		var d := _de(from + direction * t)
		if d <= t * 1e-3:
			break
		t += d
	return t


## Returns (lurch frames, moving frames).
func _fly(name: String, start: Vector3, look: Vector2) -> Vector2i:
	var camera: Node3D = _camera_script.new()
	camera.add_child(Camera3D.new())
	root.add_child(camera)
	camera.de_query = _de_at
	camera.set_pose(start, look.x, look.y)
	var lurches := 0
	var moving := 0
	var previous_speed := 0.0
	var travelled := 0.0
	var blocked := false
	var contact_s: Array[float] = []
	for frame in FRAMES:
		var from := camera.position
		camera._process(DT)
		var step := camera.position - from
		var speed := step.length() / DT
		travelled += step.length()
		for sample in 4:
			if _de(from + step * (float(sample + 1) / 4.0)) <= 0.0:
				blocked = true
		# The first second is the acceleration ramp from rest.
		if frame > 60 and previous_speed > 0.0 and speed > 0.0:
			moving += 1
			if absf(log(speed / previous_speed)) / log(10.0) > LURCH_DECADES:
				lurches += 1
		previous_speed = speed
		if frame % 10 == 0 and speed > 0.0:
			var forward := -camera.global_transform.basis.z
			contact_s.append(_ray(camera.position, forward) / speed)
	_check(not blocked, "%s look %s: the camera crossed a surface" % [name, look])
	_check(travelled > 0.0, "%s look %s: the camera never moved" % [name, look])
	contact_s.sort()
	var median_s: float = contact_s[contact_s.size() / 2] if not contact_s.is_empty() else INF
	_check(median_s <= MAX_MEDIAN_CONTACT_S,
		"%s look %s: %.1f s median to reach the view centre" % [name, look, median_s])
	print("FLIGHT %s look=%s travelled %.4f lurches %d contact %.1f s final log10 DE %.2f" % [
		name, look, travelled, lurches, median_s,
		log(maxf(_de(camera.position), 1e-30)) / log(10.0)])
	camera.free()
	return Vector2i(lurches, moving)
