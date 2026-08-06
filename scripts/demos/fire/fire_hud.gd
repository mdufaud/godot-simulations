class_name FireHud extends RefCounted
## The fire demo's debug overlay: solver clock, tile pool, reduced stats and the
## GPU stage timings of both the grid and the water.
##
## Read-only over the solver. The host assigns [member solver] and [member water],
## calls [method build] once and [method update] every frame.

## GPU timestamps come back a frame or more late and jitter frame to frame, so the
## overlay latches them at this interval instead of flickering every frame.
const TIMING_REFRESH_FRAMES := 15

var solver: FireGpuSolver
var water: FireWater
var overlay: Label

var _timing_frame := 0
var _fire_timings := {}
var _sph_timings := {}
var _water_timings := {}


func build(ui_layer: CanvasLayer) -> void:
	overlay = Label.new()
	overlay.position = Vector2(16.0, 16.0)
	overlay.custom_minimum_size = Vector2(620.0, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_theme_font_size_override("font_size", 15)
	overlay.add_theme_color_override("font_color", Color(0.9, 0.96, 1.0, 0.96))
	overlay.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	overlay.add_theme_constant_override("outline_size", 6)
	ui_layer.add_child(overlay)


func update(frame_ms: float, quality_text: String, temporal_on: bool) -> void:
	if overlay == null or solver == null:
		return
	_timing_frame += 1
	var stats := solver.get_stats()
	if _timing_frame % TIMING_REFRESH_FRAMES == 0:
		var latest_timings := solver.get_timings()
		if not latest_timings.is_empty():
			_fire_timings = latest_timings
	var timings: Dictionary = _fire_timings
	var proxy := solver.display_clip_box()
	var clock := solver.get_clock_stats()
	var pool := solver.get_debug_pool_stats()
	var lines := [
		"FIRE DEBUG",
		"quality %s" % quality_text,
		"frame %.2f ms | FPS %.1f | steps %d" % [
			frame_ms, Engine.get_frames_per_second(), solver.last_substeps],
		"clock %d Hz | sim %.2f s | wall %.2f s | ratio %.3f" % [
			int(clock["simulation_hz"]), float(clock["simulation_time"]),
			float(clock["wall_time"]), float(clock["ratio"])],
		"temporal %s | blend %.2f" % [
			"linear" if temporal_on else "off",
			float(clock["interpolation_alpha"]) if temporal_on else 1.0],
		"backlog %.1f ms | dropped %.1f ms" % [
			float(clock["accumulator"]) * 1000.0, float(clock["dropped_time"]) * 1000.0],
		"GPU %s | stages %s" % [
			"%.2f ms" % timings["total"] if timings.has("total") else "--",
			_format_timings(timings) if not timings.is_empty() else "--"],
	]
	# Cores are the tiles that cleared the keep threshold on their own; the rest
	# are only resident because they fell in some core's dilation band. The split
	# is what says whether the pool is holding fire or margin.
	lines.append("pool %d/%d resident (%d core / %d band) | %d free | %d new | %d exhausted" % [
		int(pool.get("resident", 0)), int(pool.get("budget", solver.pool_budget)),
		int(pool.get("cores", 0)),
		int(pool.get("resident", 0)) - int(pool.get("cores", 0)),
		int(pool.get("free", 0)), int(pool.get("allocated_this_frame", 0)),
		int(pool.get("exhausted", 0))])
	lines.append("proxy (%.1f, %.1f, %.1f) size (%.1f, %.1f, %.1f)" % [
		proxy.position.x, proxy.position.y, proxy.position.z,
		proxy.size.x, proxy.size.y, proxy.size.z])
	lines.append("T %d K | reaction %.3f | div %.4f | ΣY %.4f" % [
		int(stats["max_temperature"]), stats["total_reaction"],
		stats["max_divergence"], stats["mass_fraction_sum"]])
	if water != null:
		if _timing_frame % TIMING_REFRESH_FRAMES == 0:
			var latest_water_timings := water.get_coupling_timings()
			if not latest_water_timings.is_empty():
				_water_timings = latest_water_timings
			var latest_sph_timings := water.sph.get_timings() if water.sph != null else {}
			if not latest_sph_timings.is_empty():
				_sph_timings = latest_sph_timings
		var has_water_timings := water.particles_active > 0 and (
			_sph_timings.has("total") or not _water_timings.is_empty())
		var water_total := float(_sph_timings.get("total", 0.0))
		for key in _water_timings:
			water_total += float(_water_timings[key])
		lines.append("water %d active | total %s ms | grid %s ms | scatter %s | gather %s" % [
			water.particles_active,
			"%.2f" % water_total if has_water_timings else "--",
			"%.2f" % _sph_timings["grid"] if has_water_timings and _sph_timings.has("grid") else "--",
			"%.2f ms" % _water_timings["scatter"] if has_water_timings and _water_timings.has("scatter") else "--",
			"%.2f ms" % _water_timings["gather"] if has_water_timings and _water_timings.has("gather") else "--"])
	overlay.text = "\n".join(lines)


## The five costliest stages, so the pressure loop's share of the frame is
## visible before the grid gets any bigger.
func _format_timings(timings: Dictionary) -> String:
	if timings.is_empty():
		return ""
	var rows := []
	for key in timings:
		if key != "total":
			rows.append([key, timings[key]])
	rows.sort_custom(func(a, b): return a[1] > b[1])

	var parts := []
	for i in mini(5, rows.size()):
		parts.append("%s %.1f" % [rows[i][0], rows[i][1]])
	return " · ".join(parts) + " ms"
