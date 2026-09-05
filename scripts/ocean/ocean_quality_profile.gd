class_name OceanQualityProfile
extends RefCounted
## Coherent quality tiers for the whole ocean pipeline. A tier bundles the FFT
## resolution, the near-foam texture size, cascade rotation and the near
## feedback cadence, so "Performance / High / Ultra" always describes one
## reproducible configuration instead of five loose toggles. Switching tier
## recreates the GPU resources (clearing foam history) but keeps the preset,
## wind and simulation time.

enum Tier { PERFORMANCE, HIGH, ULTRA }

const DEFAULT_TIER := Tier.ULTRA

const TIER_NAMES := ["Performance", "High", "Ultra"]

## FFT cascade resolution (square).
const FFT_SIZE := {
	Tier.PERFORMANCE: 256,
	Tier.HIGH: 512,
	Tier.ULTRA: 1024,
}

## Camera-centred near foam texture resolution (square).
const FOAM_NEAR_SIZE := {
	Tier.PERFORMANCE: 512,
	Tier.HIGH: 1024,
	Tier.ULTRA: 2048,
}

## PERFORMANCE rotates the cascades (one per frame); HIGH/ULTRA step all of
## them every frame.
const AMORTIZE := {
	Tier.PERFORMANCE: true,
	Tier.HIGH: false,
	Tier.ULTRA: false,
}

## Near feedback dispatch cadence: every other frame on PERFORMANCE (its dt
## compensation scales the rates), every frame otherwise.
const FOAM_NEAR_STRIDE := {
	Tier.PERFORMANCE: 2,
	Tier.HIGH: 1,
	Tier.ULTRA: 1,
}


static func tier_name(tier: int) -> String:
	return TIER_NAMES[clampi(tier, 0, TIER_NAMES.size() - 1)]


## Largest 2D texture dimension the active GPU supports; -1 when unavailable
## (headless/unsupported), in which case no clamping happens.
static func max_texture_dimension() -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return -1
	return rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)


## Highest tier at or below [param requested] whose textures fit the GPU.
## ULTRA that does not fit degrades to HIGH (never silently: the caller shows
## "requested / active" and warns).
static func effective_tier(requested: int) -> int:
	var limit := max_texture_dimension()
	if limit <= 0:
		return requested
	for tier: int in [Tier.ULTRA, Tier.HIGH, Tier.PERFORMANCE]:
		if tier <= requested and FFT_SIZE[tier] <= limit \
				and FOAM_NEAR_SIZE[tier] <= limit:
			return tier
	return Tier.PERFORMANCE


## True when the menu must show the "requested / active" degraded label.
static func is_degraded(requested: int, effective: int) -> bool:
	return requested != effective


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
	var foam_tex := 4 * n * n * cascades * 2
	var foam_near := 4 * f * f * 2
	return butterfly + fft_data + spectrum_tex + displacement_tex \
		+ normal_tex + foam_tex + foam_near


static func estimate_vram_bytes(tier: int) -> int:
	return estimate_vram_bytes_for(FFT_SIZE[tier], FOAM_NEAR_SIZE[tier])
