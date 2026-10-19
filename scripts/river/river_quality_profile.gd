class_name RiverQualityProfile
extends SimQualityProfile

const WATER_CELL_SIZE_M := [1.0, 0.5, 0.35, 0.12]
const FOAM_SIZE_PX := [Vector2i(192, 256), Vector2i(512, 1024), Vector2i(768, 1536), Vector2i(1152, 2560)]
const FOAM_DETAIL := [false, true, true, true]
const REFLECTION_SCALE := [0.0, 0.5, 0.75, 1.0]
const REFLECTION_PLANES := [1, 1, 1, 4]
const SURFACE_DETAIL := [0.0, 0.0, 0.55, 1.0]
const RAPIDS_REFLECTION := [false, false, true, true]
const GRASS_DENSITY := [0.15, 0.5, 0.75, 1.0]
const GRASS_DISTANCE_M := [20.0, 38.0, 55.0, 80.0]
const GRASS_DETAIL := [false, false, true, true]
const GRASS_SHADOWS := [false, false, false, true]
const MSAA := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X, Viewport.MSAA_8X]
const SSAO := [false, true, true, true]
const VOLUMETRIC_MIST := [false, false, true, true]


static func values(tier: int) -> Dictionary:
	return {
		water_cell_size_m = WATER_CELL_SIZE_M[tier],
		foam_size_px = FOAM_SIZE_PX[tier],
		foam_detail = FOAM_DETAIL[tier],
		reflection_scale = REFLECTION_SCALE[tier],
		reflection_planes = REFLECTION_PLANES[tier],
		surface_detail = SURFACE_DETAIL[tier],
		rapids_reflection = RAPIDS_REFLECTION[tier],
		grass_density = GRASS_DENSITY[tier],
		grass_distance_m = GRASS_DISTANCE_M[tier],
		grass_detail = GRASS_DETAIL[tier],
		grass_shadows = GRASS_SHADOWS[tier],
		msaa = MSAA[tier],
		ssao = SSAO[tier],
		volumetric_mist = VOLUMETRIC_MIST[tier],
	}
