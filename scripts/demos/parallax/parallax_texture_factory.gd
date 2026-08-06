class_name ParallaxTextureFactory extends RefCounted
## Generates the albedo / normal / height triplet of each parallax surface and
## keeps it, so switching back to a surface costs nothing.
##
## [codeblock]
## var factory := ParallaxTextureFactory.new()
## var maps := factory.maps_for(ParallaxConfig.Surface.BRICKS)
## material.set_shader_parameter("texture_height", maps.height)
## [/codeblock]

const TEX_SIZE := 1024


## One surface, named rather than an [code][albedo, normal, height][/code] array.
class Maps extends RefCounted:
	var albedo: Texture2D
	var normal: Texture2D
	var height: Texture2D

	func _init(albedo_map: Texture2D, normal_map: Texture2D, height_map: Texture2D) -> void:
		albedo = albedo_map
		normal = normal_map
		height = height_map


var _cache: Dictionary = {}


func maps_for(surface: ParallaxConfig.Surface) -> Maps:
	if not _cache.has(surface):
		_cache[surface] = _build(surface)
	return _cache[surface]


func _build(surface: ParallaxConfig.Surface) -> Maps:
	match surface:
		ParallaxConfig.Surface.BRICKS:
			return _build_bricks()
		ParallaxConfig.Surface.COBBLESTONE:
			return _from_noise(_cobble_albedo(), _cobble_height_noise(), true, 12.0)
		ParallaxConfig.Surface.DUNES:
			return _from_noise(_dune_albedo(), _dune_height_noise(), false, 8.0)
		_:
			return _from_noise(_rock_albedo(), _rock_height_noise(), true, 10.0)


# Normal map is derived from the SAME noise (and same invert) as the height map,
# so lighting cues match the parallax displacement.
func _from_noise(albedo: Texture2D, height_noise: FastNoiseLite, inv: bool,
		bump: float) -> Maps:
	var height_tex := NoiseTexture2D.new()
	height_tex.noise = height_noise
	height_tex.width = TEX_SIZE
	height_tex.height = TEX_SIZE
	height_tex.seamless = true
	height_tex.invert = inv

	var normal_tex := NoiseTexture2D.new()
	normal_tex.noise = height_noise
	normal_tex.width = TEX_SIZE
	normal_tex.height = TEX_SIZE
	normal_tex.seamless = true
	normal_tex.invert = inv
	normal_tex.as_normal_map = true
	normal_tex.bump_strength = bump

	return Maps.new(albedo, normal_tex, height_tex)


# ─── Rock ─────────────────────────────────────────

func _rock_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.02
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.25, 0.5, 0.7, 1.0], [
		Color(0.2, 0.18, 0.16),
		Color(0.3, 0.27, 0.24),
		Color(0.42, 0.38, 0.34),
		Color(0.36, 0.32, 0.28),
		Color(0.48, 0.45, 0.42),
	])
	return tex


func _rock_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.018
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.4
	return noise


# ─── Bricks ───────────────────────────────────────
# Real brick grid generated pixel-by-pixel: straight mortar lines give hard
# silhouettes that make the parallax offset clearly visible (unlike noise).

@warning_ignore("integer_division")
func _build_bricks() -> Maps:
	var size := 512
	var cols := 4
	var rows := 8
	var brick_w := size / cols
	var brick_h := size / rows
	var mortar_px := 3
	var bevel_px := 6

	var detail := FastNoiseLite.new()
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.06

	var height_img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var albedo_img := Image.create(size, size, false, Image.FORMAT_RGB8)

	var mortar_color := Color(0.62, 0.6, 0.57)
	var brick_colors: Array[Color] = [
		Color(0.55, 0.26, 0.16),
		Color(0.62, 0.32, 0.2),
		Color(0.48, 0.22, 0.14),
		Color(0.58, 0.3, 0.22),
	]

	for y in size:
		var row := y / brick_h
		var py := y % brick_h
		for x in size:
			# Alternate rows are offset by half a brick; wraps seamlessly
			# because size is divisible by brick_w
			var xs := x + (brick_w / 2 if row % 2 == 1 else 0)
			var col := xs / brick_w
			var px := xs % brick_w
			var dx := mini(px, brick_w - 1 - px)
			var dy := mini(py, brick_h - 1 - py)
			var d := mini(dx, dy)

			var n := detail.get_noise_2d(x, y) * 0.5 + 0.5
			var h := clampf(float(d - mortar_px) / float(bevel_px), 0.0, 1.0)
			h *= 0.85 + 0.15 * n
			height_img.set_pixel(x, y, Color(h, h, h))

			if d <= mortar_px:
				albedo_img.set_pixel(x, y, mortar_color.darkened(0.15 * n))
			else:
				var brick_col: Color = brick_colors[(row * 7 + col * 3) % brick_colors.size()]
				albedo_img.set_pixel(x, y, brick_col.darkened(0.2 * (1.0 - n)))

	var normal_img: Image = height_img.duplicate()
	normal_img.bump_map_to_normal_map(6.0)

	albedo_img.generate_mipmaps()
	normal_img.generate_mipmaps()
	height_img.generate_mipmaps()

	return Maps.new(
		ImageTexture.create_from_image(albedo_img),
		ImageTexture.create_from_image(normal_img),
		ImageTexture.create_from_image(height_img))


# ─── Cobblestone ──────────────────────────────────

func _cobble_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	noise.frequency = 0.025
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.4

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.3, 0.55, 0.75, 1.0], [
		Color(0.3, 0.3, 0.3),
		Color(0.4, 0.39, 0.38),
		Color(0.5, 0.49, 0.47),
		Color(0.45, 0.44, 0.42),
		Color(0.55, 0.54, 0.52),
	])
	return tex


func _cobble_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_HYBRID
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.025
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.3
	return noise


# ─── Dunes ────────────────────────────────────────

func _dune_albedo() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = TEX_SIZE
	tex.height = TEX_SIZE
	tex.seamless = true
	tex.color_ramp = _gradient([0.0, 0.3, 0.6, 0.8, 1.0], [
		Color(0.65, 0.52, 0.35),
		Color(0.72, 0.58, 0.4),
		Color(0.78, 0.65, 0.45),
		Color(0.74, 0.6, 0.42),
		Color(0.82, 0.7, 0.5),
	])
	return tex


func _dune_height_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.45
	noise.domain_warp_enabled = true
	noise.domain_warp_amplitude = 30.0
	noise.domain_warp_frequency = 0.008
	return noise


func _gradient(offsets: Array, colors: Array) -> Gradient:
	var g := Gradient.new()
	var off_pf := PackedFloat32Array()
	var col_pf := PackedColorArray()
	for o in offsets:
		off_pf.append(o)
	for c in colors:
		col_pf.append(c)
	g.offsets = off_pf
	g.colors = col_pf
	return g
