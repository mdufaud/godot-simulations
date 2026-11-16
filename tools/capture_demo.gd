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
var _shots := PackedInt32Array()
var _out := ""
var _size := Vector2i(1280, 720)
var _scene_path := ""
var _demo: Node = null
var _preset := -1
var _pool := -1
var _height_gain := -1.0
var _height_after_frame := -1
var _height_after_gain := 0.0
var _look := -1
var _mood := -1.0
var _profile := false
var _quality := -1
var _render_scale := -1.0
var _features := true
var _clouds := true
var _view := ""
var _hide_ui := true
var _show_panel := false
var _freeze := false
var _nbody_seed := -1
var _nbody_time_scale := -1.0
var _capture_time := -1.0
var _fixed_delta := -1.0
var _warmup := 90
var _wind_direction := -1.0
var _sun_elevation := -1.0
var _sun_azimuth := -1.0
var _debug_view := -1
var _jet := -1
var _wcomp := -1
var _fuel := ""
var _torch := false
var _windx := 1e9
var _travel_speed := -1.0
var _smoketaps := -1
var _cascade := -1
var _scene := -1
var _taa := -1
var _scenario := -1
var _medium := -1
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
var _ab_modes := PackedInt32Array()
var _ab_at := -1
var _ab_shader := ""
var _ab_debug := false
var _ab_param := ""
var _ab_values := PackedFloat64Array()
var _ab_scale := false
var _ab_linear := false
var _ab_floor := -1.0
var _ab_trans := -1.0
var _ab_debug_mode := 1
var _ab_pre_filter := false
var _ab_billow: Array[Vector2] = []
var _ab_tags: Array[String] = []
var _gpu_samples: Array[float] = []
var _solver_samples: Array[float] = []
var _display_samples: Array[float] = []
var _timing_solver: Object = null
var _param_overrides: Dictionary = {}
var _nbody_render_overrides: Dictionary = {}
var _diag_tiles := false
var _vol_debug := -1
var _diag_tile_log: Array[Vector2i] = []


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
			"shots":
				for frame_text in value.split(","):
					var frame := int(frame_text.strip_edges())
					if frame > 0 and not _shots.has(frame):
						_shots.append(frame)
			"param":
				var assignment := value.split(":", true, 1)
				if assignment.size() == 2:
					_param_overrides[String(assignment[0])] = float(assignment[1])
				else:
					push_error("CAPTURE FAIL: param must be key:value")
					quit(1)
					return
			"ab":
				for mode_text in value.split(","):
					_ab_modes.append(int(mode_text))
			"ab_at": _ab_at = maxi(0, int(value))
			"ab_shader": _ab_shader = value
			"ab_param": _ab_param = value
			"ab_values":
				for value_text in value.split(","):
					_ab_values.append(float(value_text))
			"ab_scale": _ab_scale = value == "1" or value.to_lower() == "true"
			"ab_linear": _ab_linear = value == "1" or value.to_lower() == "true"
			"ab_floor": _ab_floor = float(value)
			"ab_trans": _ab_trans = float(value)
			"ab_pre_filter": _ab_pre_filter = value == "1"
			"ab_debug_mode": _ab_debug_mode = int(value)
			"ab_billow":
				for pair_text in value.split(",", false):
					var pair := pair_text.split(":")
					_ab_billow.append(Vector2(float(pair[0]), float(pair[1])))
			"ab_tags":
				for tag_text in value.split(",", false):
					_ab_tags.append(tag_text)
			"vol_debug": _vol_debug = int(value)
			"diag_tiles": _diag_tiles = value == "1"
			"ab_debug": _ab_debug = value == "1" or value.to_lower() == "true"
			"nbody_star_size": _nbody_render_overrides.star_size = float(value)
			"nbody_brightness": _nbody_render_overrides.brightness = float(value)
			"nbody_min_pixel_size": _nbody_render_overrides.min_pixel_size = float(value)
			"nbody_seed": _nbody_seed = int(value)
			"nbody_time_scale": _nbody_time_scale = float(value)
			"out": _out = value
			"preset": _preset = int(value)
			"pool": _pool = int(value)
			"height": _height_gain = float(value)
			"height_after":
				var change := value.split(":", true, 1)
				if change.size() != 2:
					push_error("CAPTURE FAIL: height_after must be frame:gain")
					quit(1)
					return
				_height_after_frame = int(change[0])
				_height_after_gain = float(change[1])
			"look": _look = int(value)
			"mood": _mood = float(value)
			"profile": _profile = value == "1" or value.to_lower() == "true"
			"quality": _quality = _quality_tier(value)
			"render_scale": _render_scale = float(value)
			"features": _features = value != "0" and value.to_lower() != "false"
			"clouds": _clouds = value != "0" and value.to_lower() != "false"
			"view": _view = value
			"ui": _hide_ui = value == "0" or value.to_lower() == "false"
			"panel": _show_panel = value == "1" or value.to_lower() == "true"
			"freeze": _freeze = value == "1" or value.to_lower() == "true"
			"time": _capture_time = float(value)
			"dt": _fixed_delta = maxf(float(value), 0.0)
			"warmup": _warmup = maxi(0, int(value))
			"wind": _wind_direction = float(value)
			"sun_elevation": _sun_elevation = float(value)
			"sun_azimuth": _sun_azimuth = float(value)
			"debug": _debug_view = int(value)
			"jet": _jet = int(value)
			"wcomp": _wcomp = int(value)
			"fuel": _fuel = value
			"torch": _torch = value == "1" or value.to_lower() == "true"
			"windx": _windx = float(value)
			"travel": _travel_speed = float(value)
			"smoketaps": _smoketaps = int(value)
			"cascade": _cascade = int(value)
			"scene": _scene = int(value)
			"taa": _taa = int(value)
			"scenario": _scenario = clampi(int(value), 0, 4)
			"medium": _medium = clampi(int(value), 0, 4)
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
	if _ab_at >= 0:
		_frames = maxi(_frames, _ab_at + 1)
	# Unique default so concurrent captures never overwrite each other.
	if not _shots.is_empty():
		for frame in _shots:
			_frames = maxi(_frames, frame)
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
	if _scene >= 0 and _demo.has_method("set_capture_scene"):
		await _demo.set_capture_scene(_scene)
	if _scenario >= 0:
		if not _demo.has_method("set_capture_scenario"):
			push_error("CAPTURE FAIL: target does not support scenario selection")
			quit(1)
			return
		_demo.set_capture_scenario(_scenario)
	if _medium >= 0:
		if not _demo.has_method("set_capture_medium"):
			push_error("CAPTURE FAIL: target does not support medium selection")
			quit(1)
			return
		_demo.set_capture_medium(_medium)
	if _preset >= 0 and _demo.has_method("apply_preset"):
		_demo.apply_preset(_preset)
	# Pool last: it is the explicit atlas override and wins over a preset's own
	# pool key.
	if _pool >= 0 and _demo.has_method("set_pool_budget"):
		_demo.set_pool_budget(_pool)
	if _render_scale > 0.0 and _demo.has_method("set_render_scale"):
		_demo.set_render_scale(_render_scale)
	ready_deadline = Time.get_ticks_msec() + 20000
	while _demo.has_method("capture_ready") and not _demo.capture_ready() and Time.get_ticks_msec() < ready_deadline:
		await process_frame
	if _demo.has_method("capture_ready") and not _demo.capture_ready():
		push_error("CAPTURE FAIL: quality resources did not become ready")
		quit(1)
		return
	if not _param_overrides.is_empty():
		if not _demo.has_method("set_capture_params"):
			push_error("CAPTURE FAIL: target does not support parameter overrides")
			quit(1)
			return
		if _param_overrides.has("march_step") and _demo.get("presentation") != null:
			_demo.presentation.set_volume_parameter("march_step", float(_param_overrides["march_step"]))
		await _demo.set_capture_params(_param_overrides)
		ready_deadline = Time.get_ticks_msec() + 20000
		while _demo.has_method("capture_ready") and not _demo.capture_ready() \
				and Time.get_ticks_msec() < ready_deadline:
			await process_frame
		if _demo.has_method("capture_ready") and not _demo.capture_ready():
			push_error("CAPTURE FAIL: parameter overrides did not become ready")
			quit(1)
			return
	if not _nbody_render_overrides.is_empty():
		if not _demo.has_method("set_capture_render"):
			push_error("CAPTURE FAIL: target does not support N-body render overrides")
			quit(1)
			return
		_demo.set_capture_render(_nbody_render_overrides)
	if _nbody_seed >= 0:
		if not _demo.has_method("set_capture_seed"):
			push_error("CAPTURE FAIL: target does not support N-body seed overrides")
			quit(1)
			return
		_demo.set_capture_seed(_nbody_seed)
		ready_deadline = Time.get_ticks_msec() + 20000
		while _demo.has_method("capture_ready") and not _demo.capture_ready() \
				and Time.get_ticks_msec() < ready_deadline:
			await process_frame
		if _demo.has_method("capture_ready") and not _demo.capture_ready():
			push_error("CAPTURE FAIL: N-body seed override did not become ready")
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
	if _jet >= 0 and _demo.has_method("set_capture_jet"):
		_demo.set_capture_jet(_jet)
	if _wcomp >= 0 and _demo.has_method("set_water_depth_composite"):
		_demo.set_water_depth_composite(_wcomp == 1)
	if not _fuel.is_empty() and _demo.has_method("set_capture_fuel"):
		_demo.set_capture_fuel(_fuel == "gas")
	if _torch and _demo.has_method("set_flamethrower"):
		_demo.set_flamethrower(true)
	if _travel_speed >= 0.0 and _demo.has_method("set_capture_travel_speed"):
		_demo.set_capture_travel_speed(_travel_speed)
	if _windx < 1e8 and _demo.has_method("set_capture_wind_x"):
		_demo.set_capture_wind_x(_windx)
	if _smoketaps >= 0 and _demo.has_method("set_smoke_light_taps"):
		_demo.set_smoke_light_taps(_smoketaps)
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
	_timing_solver = _find_solver()
	if _timing_solver != null:
		_timing_solver.set("profiling", true)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if _taa >= 0:
		if _demo.get("viewport_guard") != null:
			_demo.viewport_guard.set_taa(_taa >= 1)
		if _demo.get("presentation") != null:
			_demo.presentation.set_volume_taa(_taa == 1)
	for frame in _warmup:
		await process_frame
		_sample_timings()
	if _capture_time >= 0.0 and _demo.has_method("set_capture_time"):
		_demo.set_capture_time(_capture_time)
	# Foam equilibrium warmup (fix plan 0.6): live steps between the spectral
	# time re-anchor and the unfreeze, so captured foam is stationary.
	var foam_warmed := _foam_warmup > 0.0 and _demo.has_method("warmup_foam")
	if foam_warmed:
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
		if not foam_warmed and _capture_time >= 0.0 and _demo.has_method("set_capture_time"):
			_demo.set_capture_time(_capture_time)
	if _profile and _demo.has_method("set_capture_profiling"):
		_demo.set_capture_profiling(true)
	if _nbody_time_scale >= 0.0:
		if not _demo.has_method("set_capture_time_scale"):
			push_error("CAPTURE FAIL: target does not support N-body time-scale overrides")
			quit(1)
			return
		_demo.set_capture_time_scale(_nbody_time_scale)
	if _demo.has_method("set_frozen"):
		_demo.set_frozen(_freeze)
	if _show_panel:
		var capture_menu := _demo.get_node_or_null("UI/SimMenu")
		if capture_menu == null or not capture_menu.has_method("toggle_panel"):
			push_error("CAPTURE FAIL: target has no SimMenu panel")
			quit(1)
			return
		if not capture_menu.is_panel_open():
			capture_menu.toggle_panel()
	print("CAPTURE CONFIG preset=%d look=%d view=%s quality=%s time=%.6f dt=%.6f warmup=%d foam_warmup=%.1f foam_distance=%.1f wind=%.6f sun_elevation=%.3f sun_azimuth=%.3f frames=%d every=%d size=%dx%d foam=%s micro=%s reflection=%s debug=%d scene=%d cascade=%d jet=%d" % [
		_preset, _look, _view,
		OceanQualityProfile.tier_name(_quality) if _quality >= 0 else "default",
		_capture_time, _fixed_delta, _warmup,
		_foam_warmup, _foam_distance, _wind_direction, _sun_elevation, _sun_azimuth, _frames,
		_every, _size.x, _size.y, _foam_feedback, _micro_normals, _reflection,
		_debug_view, _scene, _cascade, _jet])
	if _vol_debug >= 0 and _demo.get("presentation") != null:
		_demo.presentation.set_volume_parameter("debug_mode", _vol_debug)
	var waited := 0
	var toss_frame := maxi(1, int(_frames / 3))
	while waited < _frames:
		if waited == _height_after_frame:
			if not _demo.has_method("set_capture_height_gain"):
				push_error("CAPTURE FAIL: target does not support a wave-height change")
				quit(1)
				return
			_demo.set_capture_height_gain(_height_after_gain)
			print("CAPTURE HEIGHT_CHANGE frame=%d gain=%.4f" % [waited, _height_after_gain])
		if _camera_speed != 0.0 and _demo.has_method("move_capture_camera"):
			_demo.move_capture_camera(Vector3(_camera_speed * maxf(_fixed_delta, 1.0 / 60.0), 0.0, 0.0))
		if _interaction and _demo.has_method("throw_crate") and waited == toss_frame:
			_demo.throw_crate()
		if waited == _ab_at:
			await _run_temperature_ab()
			return
		var capture_frame := waited + 1
		if _shots.is_empty() and _every > 0 and waited > 0 and waited % _every == 0:
			await _grab(_numbered(waited))
		elif not _shots.is_empty() and capture_frame < _frames \
				and _shots.has(capture_frame):
			await _grab(_numbered(capture_frame))
		await process_frame
		_sample_timings()
		if _diag_tiles and _timing_solver != null:
			var pool_stats: Dictionary = _timing_solver.get_debug_pool_stats()
			_diag_tile_log.append(Vector2i(int(pool_stats.get("resident", 0)), int(pool_stats.get("exhausted", 0))))
			print("CAPTURE DIAGTILE frame=%d resident=%d exhausted=%d budget=%d" % [waited + 1,
				_diag_tile_log[-1].x, _diag_tile_log[-1].y, int(pool_stats.get("budget", 0))])
		waited += 1
	var final_numbered := _out if _every <= 0 and _shots.is_empty() else _numbered(waited)
	if _demo.has_method("set_frozen"):
		_demo.set_frozen(true)
	if _demo.has_method("capture_metadata_async"):
		var metadata: String = await _demo.capture_metadata_async(final_numbered)
		print(metadata + _timing_suffix())
		if metadata.begins_with("CAPTURE FAIL"):
			await create_timer(0.1, true, false, true).timeout
			quit(1)
			return
	elif _demo.has_method("capture_metadata"):
		print(_demo.capture_metadata(final_numbered) + _timing_suffix())
	await _grab(final_numbered)
	print("CAPTURE DONE target=%s frames=%d" % [_scene_path, waited])
	quit(0)


## Frozen-field A/B of the raymarcher's temperature reconstruction: the simulation
## stops at this frame and every mode is rendered from the same field in this one
## process, noise and jitter off so the only difference is the filter. `ab_shader`
## adds a "pre" capture with another shader on the same material; `ab_debug` adds
## debug_mode 1 (peak temperature along the ray) for each mode.
func _run_temperature_ab() -> void:
	var presentation: Object = _demo.get("presentation")
	if presentation == null or not presentation.has_method("set_temperature_filter"):
		push_error("CAPTURE FAIL: target has no temperature_filter")
		quit(1)
		return
	_demo.set_frozen(true)
	paused = true
	presentation.set_volume_parameter("noise_detail", 0.0)
	presentation.set_volume_parameter("scroll_speed", 0.0)
	presentation.set_volume_parameter("animated_jitter", false)
	if _ab_floor >= 0.0:
		presentation.set_volume_parameter("temperature_filter_floor", _ab_floor)
	if _ab_trans >= 0.0:
		presentation.set_volume_parameter("temperature_filter_min_transmittance", _ab_trans)
	var base := _out.get_basename()
	var volume_rid := RID()
	var volume_viewport: SubViewport = presentation.get("_volume_vp")
	if volume_viewport != null:
		volume_rid = volume_viewport.get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(volume_rid, true)
	var variants: Array[String] = []
	variants.append("novol")
	if not _ab_shader.is_empty():
		variants.append("pre")
	var param_values := {}
	var param_base := 1.0
	if not _ab_param.is_empty() and _ab_scale:
		var current: Variant = presentation.volume_material.get_shader_parameter(_ab_param)
		if current == null:
			current = RenderingServer.shader_get_parameter_default(
				presentation.volume_material.shader.get_rid(), _ab_param)
		param_base = float(current)
		print("AB base %s=%s" % [_ab_param, String.num(param_base)])
	for value in _ab_values:
		var label: String = ("e" if _ab_param == "emission_strength" else _ab_param) \
			+ _num(value * param_base)
		param_values[label] = value * param_base
		variants.append(label)
	var original_filter: int = presentation.get("temperature_filter")
	var environments: Array[Node] = root.find_children("*", "WorldEnvironment", true, false)
	if not environments.is_empty():
		var env: Environment = environments[0].environment
		if _ab_linear:
			env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
			env.tonemap_exposure = 1.0
			env.glow_enabled = false
			env.adjustment_enabled = false
		print("AB env tonemap_mode=%d exposure=%.2f glow=%s intensity=%.2f hdr_threshold=%.2f bloom=%.2f adjustment=%s contrast=%.2f saturation=%.2f" % [
			env.tonemap_mode, env.tonemap_exposure, env.glow_enabled, env.glow_intensity,
			env.glow_hdr_threshold, env.glow_bloom, env.adjustment_enabled,
			env.adjustment_contrast, env.adjustment_saturation])
	var billow_labels := {}
	for pair in _ab_billow:
		var billow_label := "m%s_s%s" % [_num(pair.x), _num(pair.y)]
		billow_labels[billow_label] = pair
		variants.append(billow_label)
	for mode in _ab_modes:
		var label := str(mode)
		while variants.has(label):
			label += "r"
		variants.append(label)
	for tag in _ab_tags:
		variants.append(tag)
	var original_shader: Shader = presentation.volume_material.shader
	for variant: String in variants:
		presentation.set_volume_parameter("animated_jitter", variant == "anim")
		if presentation.has_method("set_half_res") and (variant == "half" or presentation.get("_volume_half_res")):
			presentation.set_half_res(variant == "half")
		presentation.fire_volume.visible = variant != "novol"
		if variant == "novol":
			presentation.set_temperature_filter(0)
		elif variant == "pre":
			presentation.volume_material.shader = load(_ab_shader)
			presentation.set_temperature_filter(original_filter if _ab_pre_filter else 0)
		elif billow_labels.has(variant):
			presentation.volume_material.shader = original_shader
			presentation.set_temperature_filter(original_filter)
			presentation.set_volume_parameter("billow_mode", int(billow_labels[variant].x))
			presentation.set_volume_parameter("billow_strength", billow_labels[variant].y)
		elif _ab_tags.has(variant):
			presentation.volume_material.shader = original_shader
			presentation.set_temperature_filter(original_filter)
		elif param_values.has(variant):
			presentation.volume_material.shader = original_shader
			presentation.set_temperature_filter(original_filter)
			if _ab_param == "debug_mode":
				presentation.set_volume_parameter(_ab_param, int(param_values[variant]))
			else:
				presentation.set_volume_parameter(_ab_param, float(param_values[variant]))
		else:
			presentation.volume_material.shader = original_shader
			presentation.set_temperature_filter(int(variant.replace("r", "")))
		var debug_passes: Array[int] = [0]
		if _ab_debug:
			debug_passes.append(1)
		for debug_pass: int in debug_passes:
			if not (param_values.has(variant) and _ab_param == "debug_mode"):
				presentation.set_volume_parameter("debug_mode",
					_ab_debug_mode if debug_pass == 1 else 0)
			for settle in 6:
				await process_frame
			var root_ms: Array[float] = []
			var volume_ms: Array[float] = []
			for sample in 20:
				await process_frame
				root_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
				if volume_rid.is_valid():
					volume_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(volume_rid))
			var suffix := "_dbg%d" % _ab_debug_mode if debug_pass == 1 else ""
			var file_variant := variant if param_values.has(variant) or billow_labels.has(variant) or _ab_tags.has(variant) \
				else "m" + variant
			await _grab("%s_%s%s.png" % [base, file_variant, suffix])
			print("AB mode=%s debug=%d gpu_root_ms=%.3f gpu_volume_ms=%.3f" % [
				variant, 1 if suffix != "" else 0, _median(root_ms), _median(volume_ms)])
	print("CAPTURE DONE target=%s ab=%d" % [_scene_path, variants.size()])
	quit(0)


func _num(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else String.num(value)


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
	print("CAPTURE TIMING shot=%s%s" % [path, _timing_suffix()])


func _numbered(frame: int) -> String:
	return "%s_%04d.png" % [_out.get_basename(), frame]


func _find_solver() -> Object:
	var solver: Object = _demo.get("solver")
	if solver == null:
		var system: Object = _demo.get("explosion")
		if system != null:
			solver = system.get("solver")
	return solver if solver != null and solver.has_method("get_timings") else null


func _sample_timings() -> void:
	_gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	if _timing_solver != null:
		var timings: Dictionary = _timing_solver.get_timings()
		if timings.has("total"):
			_solver_samples.append(float(timings["total"]))
		if timings.has("display"):
			_display_samples.append(float(timings["display"]))
	if _gpu_samples.size() > 30:
		_gpu_samples.remove_at(0)
	if _solver_samples.size() > 30:
		_solver_samples.remove_at(0)
	if _display_samples.size() > 30:
		_display_samples.remove_at(0)


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _timing_suffix() -> String:
	var suffix := " gpu_ms=%.2f" % _median(_gpu_samples)
	if _timing_solver != null:
		suffix += " solver_ms=%.2f display_ms=%.3f" % [_median(_solver_samples), _median(_display_samples)]
	return suffix
