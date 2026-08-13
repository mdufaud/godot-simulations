class_name MixwellConfig
extends Resource

enum BoundaryMode { FULLSCREEN, PERIODIC, SLIP_WALLS }
enum DriftCompensation { NONE, MINIMUM, MEAN }

const SPP_TARGETS: Array[int] = [1, 4, 16, 64, 256]

@export_range(1.0, 256.0, 1.0) var brush_radius_px := 30.0
@export_range(0.01, 0.5, 0.01) var midpoint_alpha := 0.1
@export_range(1.0, 32.0, 0.1) var cutoff_gamma := 10.0
@export_range(1, 256, 1) var target_spp := 16
@export_range(0.25, 1.0, 0.05) var preview_scale := 0.5
@export_range(0.25, 1.0, 0.05) var final_scale := 0.75
@export_enum("Fullscreen", "Periodic", "Slip walls") var boundary_mode := 0
@export_enum("None", "Minimum", "Mean") var drift_compensation := 0
@export_range(0, 3, 1) var source_mode := 0
@export_range(0.5, 33.0, 0.5) var gpu_budget_ms := 8.0
@export_range(0.0, 16.0, 0.01) var periodic_period_x := 0.0
@export_range(0.0, 16.0, 0.01) var periodic_period_y := 0.0
@export_range(1.0, 1024.0, 1.0) var affine_radius_px := 180.0
@export_range(-4.0, 4.0, 0.01) var affine_strength := 0.65


static func nearest_spp_target(value: int) -> int:
	var best := SPP_TARGETS[0]
	for target in SPP_TARGETS:
		if abs(target - value) < abs(best - value):
			best = target
	return best


func validate() -> String:
	if not is_finite(brush_radius_px) or brush_radius_px <= 0.0:
		return "brush_radius_px must be positive and finite"
	if not is_finite(midpoint_alpha) or midpoint_alpha <= 0.0:
		return "midpoint_alpha must be positive and finite"
	if not is_finite(cutoff_gamma) or cutoff_gamma <= 0.0:
		return "cutoff_gamma must be positive and finite"
	if not SPP_TARGETS.has(target_spp):
		return "target_spp must be one of [1, 4, 16, 64, 256]"
	if not is_finite(preview_scale) or preview_scale <= 0.0 or preview_scale > 1.0:
		return "preview_scale must be in (0, 1]"
	if not is_finite(final_scale) or final_scale <= 0.0 or final_scale > 1.0:
		return "final_scale must be in (0, 1]"
	if boundary_mode < 0 or boundary_mode > 2:
		return "boundary_mode is invalid"
	if drift_compensation < 0 or drift_compensation > 2:
		return "drift_compensation is invalid"
	if source_mode < 0 or source_mode > 3:
		return "source_mode is invalid"
	if not is_finite(gpu_budget_ms) or gpu_budget_ms <= 0.0:
		return "gpu_budget_ms must be positive and finite"
	if not is_finite(periodic_period_x) or periodic_period_x < 0.0 \
			or not is_finite(periodic_period_y) or periodic_period_y < 0.0:
		return "periodic periods must be finite and non-negative"
	if not is_finite(affine_radius_px) or affine_radius_px <= 0.0:
		return "affine_radius_px must be positive and finite"
	if not is_finite(affine_strength):
		return "affine_strength must be finite"
	return ""
