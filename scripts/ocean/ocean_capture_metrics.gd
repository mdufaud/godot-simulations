extends RefCounted


static func measure(displacement: Array[PackedFloat32Array],
		derivative: Array[PackedFloat32Array], size: int,
		tiles: PackedFloat32Array, onset: float) -> Dictionary:
	var band_variance: Array[float] = []
	for layer in 3:
		if displacement[layer].size() != size * size * 4 or derivative[layer].size() != size * size * 4:
			return {"error": "incomplete wave field"}
		var square := 0.0
		var mean := 0.0
		for i in displacement[layer].size():
			if not is_finite(displacement[layer][i]) or not is_finite(derivative[layer][i]):
				return {"error": "non-finite wave field"}
			if i % 4 == 1:
				mean += displacement[layer][i]
				square += displacement[layer][i] * displacement[layer][i]
		var count := float(size * size)
		band_variance.append(maxf(square / count - pow(mean / count, 2.0), 0.0))
	var heights := 0.0
	var height_squares := 0.0
	var slopes := 0.0
	var sources := 0.0
	var stretches: Array[float] = []
	var folded := 0
	for i in range(1, 2049):
		var position := Vector2(_radical_inverse(i, 2), _radical_inverse(i, 3)) * tiles[0]
		var d := Vector4.ZERO
		var height := 0.0
		var dz := 0.0
		for layer in 3:
			d += sample(derivative[layer], position, size, tiles[layer])
			var h := sample(displacement[layer], position, size, tiles[layer])
			height += h.y
			dz += h.w
		var stretch := 0.5 * (2.0 + d.x + d.y - sqrt(pow(d.x - d.y, 2.0) + 4.0 * d.z * d.z))
		stretches.append(stretch)
		folded += int(stretch <= 0.0)
		heights += height
		height_squares += height * height
		slopes += d.w * d.w + dz * dz
		sources += smoothstep(0.0, 0.2, onset - stretch)
	stretches.sort()
	return {"samples": 2048, "height_rms_m": sqrt(maxf(height_squares / 2048.0 - pow(heights / 2048.0, 2.0), 0.0)),
		"band_variance_m2": band_variance, "slope_rms": sqrt(slopes / 2048.0),
		"stretch_min": stretches[0], "stretch_p05": stretches[102], "stretch_p50": stretches[1024],
		"stretch_p95": stretches[1945], "folded_fraction": float(folded) / 2048.0,
		"source_mean": sources / 2048.0}


static func sample(field: PackedFloat32Array, position: Vector2, size: int, tile: float) -> Vector4:
	var p := position / tile * float(size) - Vector2(0.5, 0.5)
	var at := Vector2i(floori(p.x), floori(p.y))
	var weight := Vector2(p.x - floorf(p.x), p.y - floorf(p.y))
	var result := Vector4.ZERO
	for y in 2:
		for x in 2:
			var index := (posmod(at.y + y, size) * size + posmod(at.x + x, size)) * 4
			var w := (weight.x if x == 1 else 1.0 - weight.x) * (weight.y if y == 1 else 1.0 - weight.y)
			result += Vector4(field[index], field[index + 1], field[index + 2], field[index + 3]) * w
	return result


static func _radical_inverse(index: int, base: int) -> float:
	var result := 0.0
	var weight := 1.0 / base
	while index > 0:
		result += float(index % base) * weight
		index /= base
		weight /= base
	return result
