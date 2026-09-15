class_name ProceduralFireAtlas extends RefCounted
## CPU fallback generator for the game-fire flipbook atlases — the documented
## fallback when the Fire-X bake is not available (docs/game_fire_rdr2_model.md),
## also used at runtime when the baked atlas file is missing. Each flame frame
## is one main tongue plus wandering side licks — narrow fbm-eroded teardrops
## on a blackbody ramp, so a single billboard reads as a flame lick and the
## live particle ensemble builds the campfire cone. Smoke is soft eroded puffs.

const RAMP_EMBER := Color(0.55, 0.05, 0.01)
const RAMP_LOW := Color(1.0, 0.3, 0.02)
const RAMP_MID := Color(1.0, 0.82, 0.42)
const RAMP_HOT := Color(1.0, 0.98, 0.9)

var _lick_cx: Array[float] = []
var _lick_lean: Array[float] = []
var _lick_w: Array[float] = []
var _lick_tip: Array[float] = []
var _lick_strength: Array[float] = []


static func flame_image(frames: Vector2i, cell_px: int,
		seed_value := 20260915) -> Image:
	var noise := _noise(seed_value)
	var image := Image.create(frames.x * cell_px, frames.y * cell_px, false,
		Image.FORMAT_RGBA8)
	for frame in frames.x * frames.y:
		var t := float(frame) / float(frames.x * frames.y)
		_write_flame_frame(image, frame, frames, cell_px, noise, t)
	return image


static func smoke_image(frames: Vector2i, cell_px: int,
		seed_value := 20260916) -> Image:
	var noise := _noise(seed_value)
	var image := Image.create(frames.x * cell_px, frames.y * cell_px, false,
		Image.FORMAT_RGBA8)
	for frame in frames.x * frames.y:
		var t := float(frame) / float(frames.x * frames.y)
		_write_smoke_frame(image, frame, frames, cell_px, noise, t)
	return image


static func _noise(seed_value: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_octaves = 4
	noise.frequency = 1.0
	return noise


static func _write_flame_frame(image: Image, frame: int, frames: Vector2i,
		cell_px: int, noise: FastNoiseLite, t: float) -> void:
	var ox := (frame % frames.x) * cell_px
	var oy := (frame / frames.x) * cell_px
	var generator := new()
	generator._layout_licks(t)
	for y in cell_px:
		var v := 1.0 - 2.0 * (float(y) + 0.5) / float(cell_px)
		var h := clampf((v + 1.0) * 0.5, 0.0, 1.0)
		for x in cell_px:
			var u := -1.0 + 2.0 * (float(x) + 0.5) / float(cell_px)
			var cov := 0.0
			for lick in generator._lick_count():
				var prof := _tongue_profile(h, generator._lick_tip[lick])
				if prof <= 0.004:
					continue
				var center := generator._lick_cx[lick] \
					+ generator._lick_lean[lick] * pow(h, 1.35)
				var d := absf(u - center) \
					/ maxf(generator._lick_w[lick] * prof, 0.012)
				if d >= 1.0:
					continue
				cov = maxf(cov, (1.0 - pow(d, 1.7)) * generator._lick_strength[lick])
			# FBM erosion scrolling upward with t so consecutive frames crawl.
			var n := noise.get_noise_2d((u * 2.0 + h) * 2.3 + 7.0,
				(v * 1.15 - t * 0.9) * 2.3)
			var flicker := clampf(0.75 + 0.5 * n, 0.0, 1.3)
			var intensity := clampf(cov * flicker, 0.0, 1.0)
			if intensity <= 0.012:
				image.set_pixel(ox + x, oy + y, Color(0, 0, 0, 0))
				continue
			var core := pow(intensity, 3.0) * (1.25 - 0.8 * h)
			var temp := clampf(intensity * 0.92 * (1.0 - 0.35 * h) + core, 0.0, 1.0)
			var color := _blackbody(temp)
			var alpha := smoothstep(0.06, 0.42, intensity) \
				* clampf(intensity * 1.8, 0.0, 1.0)
			if alpha < 0.04:
				image.set_pixel(ox + x, oy + y, Color(0, 0, 0, 0))
				continue
			image.set_pixel(ox + x, oy + y, Color(color.r, color.g, color.b, alpha))


## One main tongue plus up to two side licks; every parameter is a period-1
## function of the frame phase t, so the 64-frame loop is seamless.
func _layout_licks(t: float) -> void:
	_lick_cx.clear()
	_lick_lean.clear()
	_lick_w.clear()
	_lick_tip.clear()
	_lick_strength.clear()
	_push_lick(0.12 * sin(t * TAU + 0.6), 0.34 * sin(t * TAU + 1.9),
		0.4, 1.0, 1.0)
	var side_a := smoothstep(0.05, 0.45, sin(t * TAU + 2.4))
	if side_a > 0.01:
		_push_lick(-0.44 + 0.1 * sin(t * TAU * 2.0 + 0.3),
			0.3 * sin(t * TAU + 4.1), 0.2, 0.68, 0.95 * side_a)
	var side_b := smoothstep(0.05, 0.45, sin(t * TAU + 5.3))
	if side_b > 0.01:
		_push_lick(0.42 + 0.1 * sin(t * TAU * 2.0 + 2.9),
			0.3 * sin(t * TAU + 0.8), 0.19, 0.6, 0.9 * side_b)


func _push_lick(cx: float, lean: float, width: float, tip: float,
		strength: float) -> void:
	_lick_cx.append(cx)
	_lick_lean.append(lean)
	_lick_w.append(width)
	_lick_tip.append(tip)
	_lick_strength.append(strength)


func _lick_count() -> int:
	return _lick_cx.size()


## Teardrop half-width across a tongue of tip height: rounded-but-present
## base, widest at ~22% of the tongue, long tapering tip.
static func _tongue_profile(h: float, tip: float) -> float:
	var hn := h / maxf(tip, 0.05)
	if hn >= 1.0:
		return 0.0
	var rise := lerpf(0.9, 1.0, smoothstep(0.0, 0.24, hn))
	var fall := 1.0 - smoothstep(0.2, 1.0, pow(hn, 1.15))
	return rise * fall


static func _write_smoke_frame(image: Image, frame: int, frames: Vector2i,
		cell_px: int, noise: FastNoiseLite, t: float) -> void:
	var ox := (frame % frames.x) * cell_px
	var oy := (frame / frames.x) * cell_px
	var grow := 0.52 + 0.2 * sin(t * TAU)
	for y in cell_px:
		var v := 1.0 - 2.0 * (float(y) + 0.5) / float(cell_px)
		for x in cell_px:
			var u := -1.0 + 2.0 * (float(x) + 0.5) / float(cell_px)
			var d := Vector2(u, v * 0.92).length() / grow
			var n := noise.get_noise_2d(u * 2.4 + 31.0,
				v * 2.4 - t * 1.5)
			var a := pow(clampf(1.0 - d, 0.0, 1.0), 1.4) \
				* clampf(0.55 + 0.9 * n, 0.0, 1.0)
			var shade := 0.68 + 0.32 * n
			image.set_pixel(ox + x, oy + y,
				Color(shade, shade * 0.98, shade * 0.96, clampf(a, 0.0, 1.0)))


## Ember red through orange and yellow to a near-white core.
static func _blackbody(x: float) -> Color:
	if x < 0.3:
		return RAMP_EMBER.lerp(RAMP_LOW, smoothstep(0.0, 0.3, x))
	if x < 0.65:
		return RAMP_LOW.lerp(RAMP_MID, smoothstep(0.3, 0.65, x))
	return RAMP_MID.lerp(RAMP_HOT, smoothstep(0.65, 1.0, x))
