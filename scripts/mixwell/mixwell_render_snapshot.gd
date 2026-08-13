class_name MixwellRenderSnapshot
extends RefCounted

var version := 0
var size := Vector2i.ZERO
var reference_size := Vector2i.ZERO
var source_mode := 0
var boundary_mode := 0
var active_boundary_mode := 0
var periodic_optimized := false
var drift_compensation := 0
var affine_mode := -1
var profiling := false
var diagnostics_enabled := false
var brush_radius_px := 18.0
var midpoint_alpha := 0.1
var cutoff_gamma := 10.0
var affine_radius_px := 180.0
var affine_strength := 0.65
var pattern := {}
var pattern_step := -1
var operations: Array[Dictionary] = []
var periodic_plan: Array[Dictionary] = []
var fullscreen_plan: Array[Dictionary] = []
var period_fixed := Vector2i.ZERO
var periodic_domain := Vector2i.ZERO
var fullscreen_domain := Vector2i.ZERO
var periodic_movement_dispatch_pixels := 0
var fullscreen_movement_dispatch_pixels := 0
var periodic_dispatch_pixels := 0
var fullscreen_dispatch_pixels := 0


func boundary_copy(next_boundary: int, optimized: bool):
	var result = get_script().new()
	result.version = version
	result.size = size
	result.reference_size = reference_size
	result.source_mode = source_mode
	result.boundary_mode = next_boundary
	result.active_boundary_mode = next_boundary
	result.periodic_optimized = optimized
	result.drift_compensation = drift_compensation
	result.affine_mode = affine_mode
	result.profiling = profiling
	result.diagnostics_enabled = diagnostics_enabled
	result.brush_radius_px = brush_radius_px
	result.midpoint_alpha = midpoint_alpha
	result.cutoff_gamma = cutoff_gamma
	result.affine_radius_px = affine_radius_px
	result.affine_strength = affine_strength
	result.pattern = pattern.duplicate(true)
	result.pattern_step = pattern_step
	result.operations = operations.duplicate(true)
	result.periodic_plan = periodic_plan.duplicate(true)
	result.fullscreen_plan = fullscreen_plan.duplicate(true)
	result.period_fixed = period_fixed
	result.periodic_domain = periodic_domain
	result.fullscreen_domain = fullscreen_domain
	result.periodic_movement_dispatch_pixels = periodic_movement_dispatch_pixels
	result.fullscreen_movement_dispatch_pixels = fullscreen_movement_dispatch_pixels
	result.periodic_dispatch_pixels = periodic_dispatch_pixels
	result.fullscreen_dispatch_pixels = fullscreen_dispatch_pixels
	return result
