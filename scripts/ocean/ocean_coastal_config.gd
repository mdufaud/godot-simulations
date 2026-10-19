class_name OceanCoastalConfig
extends Resource

const DEFAULT_DOMAIN_M := 160.0
const DEFAULT_GRID_SIZES_CELLS: Array[int] = [128, 256, 384, 384]
const DEFAULT_MACRO_STEP_S := 1.0 / 30.0
const DEFAULT_MIN_SUBSTEPS_PER_RENDER := 8
const DEFAULT_MAX_SUBSTEPS_PER_RENDER := 24
const DEFAULT_OFFSHORE_DEPTH_M := 16.0
const DEFAULT_BOUNDARY_DEPTH_M := 4.0
const DEFAULT_SPONGE_WIDTH_M := 16.0
const DEFAULT_MINIMUM_WAVELENGTH_M := 32.0
const DEFAULT_GRAVITY_M_S2 := 9.81
const DEFAULT_DRY_DEPTH_M := 0.002
const DEFAULT_FOAM_RETENTION_S := 20.0
const DISPERSIVE_COEFFICIENT_B := 1.0 / 15.0
const DISPERSIVE_COEFFICIENT_C := 1.0 / 3.0 + DISPERSIVE_COEFFICIENT_B
const DEFAULT_DISPERSIVE_ITERATIONS := 6
const DEFAULT_DISPERSIVE_TOLERANCE := 0.0001
const DEFAULT_DISPERSIVE_RELATIVE_DEPTH := 0.2
const DISPERSIVE_VALID_KH_MAX := 3.0
const DEFAULT_BREAK_FROUDE_START := 0.85
const DEFAULT_BREAK_FROUDE_END := 0.5
const DEFAULT_EDDY_COEFFICIENT := 0.9
const DEFAULT_MAX_SUPPORTED_GRID := 384
const BREAKER_MIN_PROFILE_CELLS := 3.0

@export var domain_m := DEFAULT_DOMAIN_M
@export var grid_sizes_cells: Array[int] = DEFAULT_GRID_SIZES_CELLS.duplicate()
@export var visual_grid_sizes_cells: Array[int] = [128, 160, 384, 384]
@export var selected_resolution_cells := 256
@export var bathymetry_elevation_m := PackedFloat32Array()
@export var offshore_depth_m := DEFAULT_OFFSHORE_DEPTH_M
@export var boundary_depth_m := DEFAULT_BOUNDARY_DEPTH_M
@export var open_boundaries_enabled := true
@export var macro_step_s := DEFAULT_MACRO_STEP_S
@export var min_substeps_per_render := DEFAULT_MIN_SUBSTEPS_PER_RENDER
@export var max_substeps_per_render := DEFAULT_MAX_SUBSTEPS_PER_RENDER
@export var sponge_width_m := DEFAULT_SPONGE_WIDTH_M
@export var minimum_wavelength_m := DEFAULT_MINIMUM_WAVELENGTH_M
@export var gravity_m_s2 := DEFAULT_GRAVITY_M_S2
@export var dry_depth_m := DEFAULT_DRY_DEPTH_M
@export var foam_retention_s := DEFAULT_FOAM_RETENTION_S
@export var contact_retention_s := 6.0
@export var dispersive_iterations := DEFAULT_DISPERSIVE_ITERATIONS
@export var dispersive_tolerance := DEFAULT_DISPERSIVE_TOLERANCE
@export var dispersive_relative_depth := DEFAULT_DISPERSIVE_RELATIVE_DEPTH
@export var break_froude_start := DEFAULT_BREAK_FROUDE_START
@export var break_froude_end := DEFAULT_BREAK_FROUDE_END
@export var eddy_coefficient := DEFAULT_EDDY_COEFFICIENT
@export var max_supported_grid := DEFAULT_MAX_SUPPORTED_GRID
@export var visual_breakers_enabled := false
@export var visual_blend_width_m := 40.0
@export var visual_surface_depth_blend_m := Vector2(2.0, 8.0)
@export var visual_foam_texture_sizes_px: Array[int] = [512, 512, 2048, 2048]
@export var breaker_max_radius_m := 2.0


func validate() -> String:
	if not visual_surface_depth_blend_m.is_finite() or visual_surface_depth_blend_m.x < 0.0 \
			or visual_surface_depth_blend_m.y <= visual_surface_depth_blend_m.x:
		return "visual surface depth blend must be finite and ordered"
	if visual_foam_texture_sizes_px.size() != 4:
		return "visual foam texture tier count must be four"
	for size in visual_foam_texture_sizes_px:
		if size < 16 or size > 2048 or (size & (size - 1)) != 0:
			return "visual foam texture sizes must be powers of two in [16, 2048]"
	if not is_finite(visual_blend_width_m) or visual_blend_width_m <= 0.0 \
			or visual_blend_width_m > domain_m * 0.5:
		return "visual_blend_width_m must be positive and no wider than half the domain"
	if not is_finite(breaker_max_radius_m) or breaker_max_radius_m <= 0.0:
		return "visual breaker dimensions must be finite and positive"
	if not is_finite(domain_m) or domain_m <= 0.0:
		return "domain_m must be finite and positive"
	if not is_finite(offshore_depth_m) or offshore_depth_m <= 0.0:
		return "offshore_depth_m must be finite and positive"
	if not is_finite(boundary_depth_m) or boundary_depth_m <= 0.0:
		return "boundary_depth_m must be finite and positive"
	if not is_finite(macro_step_s) or macro_step_s <= 0.0:
		return "macro_step_s must be finite and positive"
	if not is_finite(gravity_m_s2) or gravity_m_s2 <= 0.0:
		return "gravity_m_s2 must be finite and positive"
	if not is_finite(dry_depth_m) or dry_depth_m <= 0.0:
		return "dry_depth_m must be finite and positive"
	if not is_finite(sponge_width_m) or sponge_width_m <= 0.0 \
			or sponge_width_m > domain_m * 0.5:
		return "sponge_width_m must be positive and no wider than half the domain"
	if not is_finite(minimum_wavelength_m) or minimum_wavelength_m <= 0.0:
		return "minimum_wavelength_m must be finite and positive"
	if not is_finite(foam_retention_s) or foam_retention_s <= 0.0:
		return "foam_retention_s must be finite and positive"
	if not is_finite(contact_retention_s) or contact_retention_s <= 0.0:
		return "contact_retention_s must be finite and positive"
	if not is_finite(eddy_coefficient) or eddy_coefficient < 0.0:
		return "eddy_coefficient must be finite and non-negative"
	if min_substeps_per_render <= 0 or max_substeps_per_render < min_substeps_per_render:
		return "render substep limits are invalid"
	if dispersive_iterations <= 0:
		return "dispersive_iterations must be positive"
	if not is_finite(dispersive_tolerance) or dispersive_tolerance <= 0.0:
		return "dispersive_tolerance must be finite and positive"
	if not is_finite(dispersive_relative_depth) or dispersive_relative_depth <= 0.0 or dispersive_relative_depth > 1.0:
		return "dispersive_relative_depth must be finite and in (0, 1]"
	if max_supported_grid <= 0 or max_supported_grid % 8 != 0 \
			or max_supported_grid > DEFAULT_MAX_SUPPORTED_GRID or grid_sizes_cells.size() != 4 \
			or visual_grid_sizes_cells.size() != 4:
		return "grid tier count or maximum supported resolution is invalid"
	var active_grid_sizes := visual_grid_sizes_cells if visual_breakers_enabled else grid_sizes_cells
	if not active_grid_sizes.has(selected_resolution_cells):
		return "selected_resolution_cells is not in the active grid sizes"
	for size in grid_sizes_cells + visual_grid_sizes_cells:
		if size <= 0 or size > max_supported_grid or size % 8 != 0:
			return "grid_sizes_cells must be positive, divisible by 8, and within max_supported_grid"
	if selected_resolution_cells <= 0 or selected_resolution_cells > max_supported_grid \
			or selected_resolution_cells % 8 != 0:
		return "selected_resolution_cells is invalid"
	if bathymetry_elevation_m.size() != selected_resolution_cells * selected_resolution_cells:
		return "bathymetry_elevation_m length does not match selected_resolution_cells"
	for elevation in bathymetry_elevation_m:
		if not is_finite(elevation):
			return "bathymetry_elevation_m contains a non-finite elevation"
	if not is_finite(break_froude_start) or not is_finite(break_froude_end) \
			or break_froude_start > 1.0 or break_froude_start <= break_froude_end \
			or break_froude_end < 0.0:
		return "break Froude thresholds must be finite, ordered start > end, and in [0, 1]"
	return ""


func surface_blend_width_m() -> float:
	return visual_blend_width_m if visual_breakers_enabled else 12.0


func foam_texture_size_px(tier: int, offshore_size_px: int) -> int:
	return mini(offshore_size_px, visual_foam_texture_sizes_px[tier]) if visual_breakers_enabled else offshore_size_px


func resolution_cells(tier: int) -> int:
	return visual_grid_sizes_cells[tier] if visual_breakers_enabled else grid_sizes_cells[tier]


func surface_depth_blend_m() -> Vector2:
	return visual_surface_depth_blend_m if visual_breakers_enabled else Vector2.ZERO
