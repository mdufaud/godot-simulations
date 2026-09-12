class_name OceanQualityProfile
extends SimQualityProfile
## Coherent quality tiers for the whole ocean pipeline. A tier bundles the FFT
## resolution, the near-foam texture size and reach, the cascade rotation and
## the feedback cadences, so "Low / Medium / High / Ultra" always describes one
## reproducible configuration instead of loose toggles. Switching tier
## recreates the GPU resources (clearing foam history) but keeps the preset,
## wind and simulation time. Higher tiers also widen the visible detail
## distance so the far water keeps readable relief.
##
## The FFT resolution is capped at 1024: the FFT pass compiles one workgroup
## row per invocation (local_size_x = MAP_SIZE), and 2048 exceeds every GPU's
## maxComputeWorkGroupSize. The near-foam pipeline is calibrated per texel
## density (its coverage contracts are pinned per tier), so Ultra keeps the
## High foam configuration and spends its budget where nothing is held back:
## the short cascade steps every frame and the ripple detail reaches its
## maximum distance. The default tier is High, the configuration the demo
## shipped with.
static func default_tier() -> int:
	return Tier.HIGH

## FFT cascade resolution (square). Hardware ceiling 1024.
const FFT_SIZE := {
	Tier.LOW: 256,
	Tier.MEDIUM: 512,
	Tier.HIGH: 1024,
	Tier.ULTRA: 1024,
}

## Camera-centred near foam texture resolution (square). The foam feedback is
## tuned for ~12.5 cm/texel, so the size tracks the reach instead of growing
## past it.
const FOAM_NEAR_SIZE := {
	Tier.LOW: 512,
	Tier.MEDIUM: 1024,
	Tier.HIGH: 2048,
	Tier.ULTRA: 2048,
}

## World-space radius the near foam texture covers (metres).
const FOAM_NEAR_DISTANCE := {
	Tier.LOW: 48.0,
	Tier.MEDIUM: 72.0,
	Tier.HIGH: 128.0,
	Tier.ULTRA: 128.0,
}

## Distance at which the fine ripple detail fades out.
const DETAIL_DISTANCE_M := {
	Tier.LOW: 900.0,
	Tier.MEDIUM: 1800.0,
	Tier.HIGH: 3600.0,
	Tier.ULTRA: 4000.0,
}

## LOW rotates the cascades (one per frame); the others step all of them every
## frame.
const AMORTIZE := {
	Tier.LOW: true,
	Tier.MEDIUM: false,
	Tier.HIGH: false,
	Tier.ULTRA: false,
}

## Near feedback dispatch cadence: every other frame on LOW (its dt
## compensation scales the rates), every frame otherwise.
const FOAM_NEAR_STRIDE := {
	Tier.LOW: 2,
	Tier.MEDIUM: 1,
	Tier.HIGH: 1,
	Tier.ULTRA: 1,
}

## Finest cascade steps every other frame on MEDIUM/HIGH (wave periods there
## are seconds long and phases stay continuous; the foam decay compensates).
## LOW already rotates all cascades, so the flag stays off; Ultra runs the
## short cascade at full rate.
const SHORT_CASCADE_HALF_RATE := {
	Tier.LOW: false,
	Tier.MEDIUM: true,
	Tier.HIGH: true,
	Tier.ULTRA: false,
}


## The tier's knob bundle, keyed for SimQualityState.
static func values(tier: int) -> Dictionary:
	return {
		fft_size = FFT_SIZE[tier],
		foam_near_size = FOAM_NEAR_SIZE[tier],
		foam_near_distance = FOAM_NEAR_DISTANCE[tier],
		detail_distance_m = DETAIL_DISTANCE_M[tier],
		amortize = AMORTIZE[tier],
		foam_near_stride = FOAM_NEAR_STRIDE[tier],
		short_cascade_half_rate = SHORT_CASCADE_HALF_RATE[tier],
	}


static func foam_near_distance(tier: int) -> float:
	return FOAM_NEAR_DISTANCE[tier]


static func detail_distance_m(tier: int) -> float:
	return DETAIL_DISTANCE_M[tier]


## Largest 2D texture dimension the active GPU supports; -1 when unavailable
## (headless/unsupported), in which case no clamping happens.
static func max_texture_dimension() -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return -1
	return rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)


## False when the tier's textures do not fit the GPU; SimQualityState then
## degrades the request (never silently: the menu shows "requested / active").
static func tier_supported(tier: int) -> bool:
	var limit := max_texture_dimension()
	if limit <= 0:
		return true
	return FFT_SIZE[tier] <= limit and FOAM_NEAR_SIZE[tier] <= limit


## Estimate the solver's VRAM footprint from the actual allocation sizes in
## OceanSolver.init_render: butterfly + fft_data storage buffers,
## spectrum/displacement/normal/foam image2DArrays, near foam ping-pong.
## Query buffers (~1.5 KB) are negligible and omitted.
static func estimate_vram_bytes_for(map_size: int, foam_near_size: int) -> int:
	var n := map_size
	var f := foam_near_size
	var cascades := 3
	var spectra := 4
	var butterfly := int(log(float(n)) / log(2.0) + 0.5) * n * 16
	var fft_data := cascades * 2 * spectra * n * n * 8
	var spectrum_tex := 16 * n * n * cascades
	var displacement_tex := 8 * n * n * cascades
	var normal_tex := 8 * n * n * cascades
	var mip_texels := 0
	var mip_size := f
	while mip_size > 0:
		mip_texels += mip_size * mip_size
		mip_size /= 2
	var foam_near := 8 * mip_texels * 3 * 2
	return butterfly + fft_data + spectrum_tex + displacement_tex \
		+ normal_tex * 2 + foam_near


static func estimate_vram_bytes(tier: int) -> int:
	return estimate_vram_bytes_for(FFT_SIZE[tier], FOAM_NEAR_SIZE[tier])
