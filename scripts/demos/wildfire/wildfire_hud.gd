class_name WildfireHud extends RefCounted
## Debug overlay for the wildfire demo: frame cost, fire system cost and
## occupancy, and propagation grid state.

var overlay: Label


func build(ui_layer: CanvasLayer) -> void:
	overlay = Label.new()
	overlay.position = Vector2(16.0, 16.0)
	overlay.custom_minimum_size = Vector2(560.0, 0.0)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_theme_font_size_override("font_size", 15)
	overlay.add_theme_color_override("font_color", Color(1.0, 0.9, 0.8, 0.96))
	overlay.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	overlay.add_theme_constant_override("outline_size", 6)
	ui_layer.add_child(overlay)


func update(frame_ms: float, gpu_ms: float, quality_label: String,
		system: WildfireSystem, grid: CellPropagation) -> void:
	if overlay == null:
		return
	var lines := [
		"WILDFIRE DEBUG | quality %s" % quality_label,
		"frame %.2f ms | FPS %.1f | viewport GPU %.2f ms" % [
			frame_ms, Engine.get_frames_per_second(), gpu_ms],
		"fires %.2f ms | %d fires | %d particles live" % [
			system.last_update_ms, system.fire_count(), system.live_particles()],
		"grid burning %d | burned %d" % [grid.burning_count(), grid.burned_count()],
	]
	overlay.text = "\n".join(lines)
