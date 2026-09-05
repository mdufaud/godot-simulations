extends SceneTree
## Generates resources/ocean/foam_detail.png: a seamless 2048² RGBA detail
## texture for the ocean foam, built locally (no third-party asset).
##   R = Worley lace web (two scales)   -> physical foam skeleton
##   G = FBM simplex                    -> soft breakup / shore clouds
##   B = eroded foam patches            -> lace eaten by the FBM
##   A = high-frequency breakup noise   -> geometry perturbation
##
## Everything is periodic: Worley runs on a torus and the simplex FBM uses the
## 4-corner bilinear blend, so the texture tiles with no visible seam.
##
## Run: godot --headless --path . -s res://tools/generate_foam_pattern.gd

const SIZE := 2048
const OUT_PATH := "res://resources/ocean/foam_detail.png"


func _initialize() -> void:
	var start := Time.get_ticks_msec()
	var lace_coarse := _worley_edges(28, 7311)
	print("lace coarse done (%d ms)" % (Time.get_ticks_msec() - start))
	var lace_fine := _worley_edges(84, 90217)
	print("lace fine done (%d ms)" % (Time.get_ticks_msec() - start))
	var fbm := _tile_fbm(1.6, 5, 4242)
	var breakup := _tile_fbm(5.0, 4, 99991)

	var bytes := PackedByteArray()
	bytes.resize(SIZE * SIZE * 4)
	for y in SIZE:
		var row := y * SIZE
		for x in SIZE:
			var i := row + x
			var coarse := lace_coarse[i]
			var fine := lace_fine[i]
			var web := maxf(coarse, fine * 0.78)
			var g := clampf(fbm[i] * 0.5 + 0.5, 0.0, 1.0)
			var eroded := smoothstep(0.28, 0.72, web * (0.55 + 0.9 * g))
			var a := clampf(breakup[i] * 0.5 + 0.5, 0.0, 1.0)
			var o := i * 4
			bytes[o] = int(round(clampf(web, 0.0, 1.0) * 255.0))
			bytes[o + 1] = int(round(g * 255.0))
			bytes[o + 2] = int(round(eroded * 255.0))
			bytes[o + 3] = int(round(a * 255.0))
		if y % 256 == 255:
			print("combine %d%% (%d ms)" % [(y + 1) * 100 / SIZE, Time.get_ticks_msec() - start])

	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, bytes)
	var err := image.save_png(OUT_PATH)
	if err != OK:
		push_error("save_png failed: %s" % error_string(err))
		quit(1)
		return
	print("foam_detail.png written in %d ms" % (Time.get_ticks_msec() - start))
	quit(0)


# Deterministic 0..1 hash of an integer lattice point.
func _hash01(x: int, y: int, seed: int) -> float:
	var h := (x * 374761393 + y * 668265263 + seed * 1274126177) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0x7FFFFFFF) / 2147483647.0


## F2-F1 Worley cell borders on a torus: bright along cell boundaries (the
## lace web), dark inside cells. One feature point per cell keeps the web
## connected; n is the cell count per side.
func _worley_edges(n: int, seed: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	var cell := float(SIZE) / float(n)
	var half := float(SIZE) * 0.5
	var px := PackedFloat32Array()
	var py := PackedFloat32Array()
	px.resize(n * n)
	py.resize(n * n)
	for cy in n:
		for cx in n:
			px[cy * n + cx] = (float(cx) + _hash01(cx, cy, seed)) * cell
			py[cy * n + cx] = (float(cy) + _hash01(cx, cy, seed + 1013)) * cell
	for y in SIZE:
		var fy := float(y)
		var cy0 := int(fy / cell)
		var row := y * SIZE
		for x in SIZE:
			var fx := float(x)
			var cx0 := int(fx / cell)
			var f1 := 1e12
			var f2 := 1e12
			for oy in range(-1, 2):
				var cy := (cy0 + oy + n) % n
				var row_base := cy * n
				for ox in range(-1, 2):
					var cx := cx0 + ox
					if cx < 0:
						cx += n
					elif cx >= n:
						cx -= n
					var dy := py[row_base + cx] - fy
					if dy > half:
						dy -= float(SIZE)
					elif dy < -half:
						dy += float(SIZE)
					var dx := px[row_base + cx] - fx
					if dx > half:
						dx -= float(SIZE)
					elif dx < -half:
						dx += float(SIZE)
					var d := dx * dx + dy * dy
					if d < f1:
						f2 = f1
						f1 = d
					elif d < f2:
						f2 = d
			var edge := sqrt(f2) - sqrt(f1)
			# Web line where the two nearest features are almost equidistant.
			out[row + x] = 1.0 - clampf(edge / (0.30 * cell), 0.0, 1.0)
	return out


## FBM simplex with the classic 4-corner bilinear blend so it tiles seamlessly.
func _tile_fbm(frequency: float, octaves: int, seed: int) -> PackedFloat32Array:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = seed
	noise.frequency = frequency / float(SIZE)
	noise.fractal_octaves = octaves
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	for y in SIZE:
		var bv := float(y) / float(SIZE)
		var row := y * SIZE
		for x in SIZE:
			var bu := float(x) / float(SIZE)
			var n00 := noise.get_noise_2d(x, y)
			var n10 := noise.get_noise_2d(x - SIZE, y)
			var n01 := noise.get_noise_2d(x, y - SIZE)
			var n11 := noise.get_noise_2d(x - SIZE, y - SIZE)
			out[row + x] = lerpf(lerpf(n00, n10, bu), lerpf(n01, n11, bu), bv)
	return out
