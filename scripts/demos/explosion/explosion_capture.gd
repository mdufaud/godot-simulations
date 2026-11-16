class_name ExplosionCapture extends RefCounted

var soot_fraction := -1.0


## Capture overrides: charge_scale, camera_scale, soot_fraction and the billow keys of
## [method FireBillowConfig.apply_overrides]. The preset's billow resource is never mutated.
func apply(controller: Node, values: Dictionary) -> void:
	controller.charge_scale = minf(float(values.get("charge_scale", controller.charge_scale)),
		controller._menu_builder.charge_slider.max_value)
	ExplosionScenery.scale_distance(controller.orbit_cam, float(values.get("camera_scale", 1.0)))
	soot_fraction = float(values.get("soot_fraction", -1.0))
	var billow_values := {}
	for key: String in values:
		if key.begins_with("billow_"):
			billow_values[key] = values[key]
	if billow_values.is_empty():
		return
	var explosion: ExplosionSystem = controller.explosion
	var billow := explosion.config.billow.duplicate() as FireBillowConfig
	billow.apply_overrides(billow_values)
	controller.presentation.apply_billow(billow, explosion.config.cell_size_m)
	explosion.solver.blast_rest_period_s = billow.reset_s if billow.rest_active() else 0.0


static func metadata(solver: FireGpuSolver, peak_tiles: int, path: String) -> String:
	var stats := solver.get_stats()
	return "CAPTURE META temp=%d reaction=%.3f div=%.4f peak_tiles=%d path=%s" % [
		int(stats["max_temperature"]), stats["total_reaction"], stats["max_divergence"], peak_tiles, path]
