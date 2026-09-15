class_name FireGameHud extends RefCounted
## Debug overlay for the wildfire demo: frame cost, billboard system cost and
## occupancy, propagation grid state, and which renderer the hero fire is on.

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


func update(frame_ms: float, system: FireBillboardSystem, grid: CellPropagation,
		hero_mode: String, hero_running: bool, hero_ms: float) -> void:
	if overlay == null:
		return
	var lines := [
		"WILDFIRE DEBUG",
		"frame %.2f ms | FPS %.1f" % [frame_ms, Engine.get_frames_per_second()],
		"billboards %.2f ms | fires %d | %d particles live" % [
			system.last_update_ms, system.fire_count(), system.live_particles()],
		"grid burning %d | burned %d | spreading points %d" % [
			grid.burning_count(), grid.burned_count(), grid.points_left],
		"hero %s%s | fire-x last frame %s" % [
			hero_mode, " running" if hero_running else " idle",
			"%.2f ms" % hero_ms if hero_running else "--"],
	]
	overlay.text = "\n".join(lines)
