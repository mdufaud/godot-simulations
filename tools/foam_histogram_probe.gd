extends SceneTree

const TextureReadback := preload("res://scripts/core/texture_readback.gd")


func _initialize() -> void:
	call_deferred("_run")


func _half(bits: int) -> float:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return NAN
	var sign := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return sign * mantissa * pow(2.0, -24.0)
	return sign * (1.0 + mantissa / 1024.0) * pow(2.0, exponent - 15)


func _read_texture(rid: RID, layer: int, expected_bytes: int = 0) -> PackedByteArray:
	var data: PackedByteArray = await TextureReadback.new().read_layer(rid, layer,
		expected_bytes)
	if data.is_empty():
		push_error("HISTO FAIL: texture readback failed (timeout or size mismatch)")
	return data


func _foam_base(data: PackedByteArray, size: int) -> PackedByteArray:
	var base_bytes := size * size * 8
	var expected := 0
	var mip_size := size
	while mip_size > 0:
		expected += mip_size * mip_size * 8
		mip_size /= 2
	if data.size() != expected:
		return PackedByteArray()
	return data.slice(0, base_bytes)


func _field_stats(source: PackedByteArray, source_size: int,
		foam: PackedByteArray, foam_size: int) -> Dictionary:
	var source_texels := source_size * source_size
	var foam_texels := foam_size * foam_size
	var source_sum := 0.0
	var persistent_sum := 0.0
	var fresh_sum := 0.0
	var maximum := 0.0
	var source_finite := 0
	var foam_finite := 0
	var source_active := 0
	for i in source_texels:
		var source_value := _half(source.decode_u16(i * 8 + 6))
		if is_nan(source_value) or is_inf(source_value):
			continue
		source_finite += 1
		source_sum += source_value
		if source_value > 0.035:
			source_active += 1
	for i in foam_texels:
		var persistent := foam.decode_float(i * 8)
		var fresh := foam.decode_float(i * 8 + 4)
		if is_nan(persistent) or is_inf(persistent) \
				or is_nan(fresh) or is_inf(fresh):
			continue
		foam_finite += 1
		persistent_sum += persistent
		fresh_sum += fresh
		maximum = maxf(maximum, maxf(persistent, fresh))
	var source_divisor := maxf(float(source_finite), 1.0)
	var foam_divisor := maxf(float(foam_finite), 1.0)
	return {
		"source_mean": source_sum / source_divisor,
		"source_coverage": float(source_active) / source_divisor,
		"persistent_mean": persistent_sum / foam_divisor,
		"fresh_mean": fresh_sum / foam_divisor,
		"max": maximum,
		"finite": foam_finite,
		"expected": foam_texels,
		"source_finite": source_finite,
		"source_expected": source_texels,
	}


func _histogram(data: PackedByteArray, size: int, offset: int, stride: int) -> String:
	var bins := PackedInt32Array()
	bins.resize(21)
	var count := 0
	for i in range(0, size * size, stride):
		var value := _half(data.decode_u16(i * 8 + offset))
		if is_nan(value) or is_inf(value):
			continue
		bins[mini(int(clampf(value, 0.0, 1.0) * 20.0), 20)] += 1
		count += 1
	var line := ""
	for bin in 21:
		line += " %.0f" % (float(bins[bin]) * 100.0 / maxf(float(count), 1.0))
	return line


func _run() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline \
			and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("HISTO FAIL: ocean did not initialize before deadline")
		demo.queue_free()
		quit(1)
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(1.0 / 30.0)
	demo.set_frozen(false)
	for frame in 600:
		await process_frame
	demo.set_frozen(true)
	await process_frame
	var size: int = demo.solver.foam_near_size
	var map_size: int = demo.solver.map_size
	var normal_layers: Array[PackedByteArray] = []
	var foam_layers: Array[PackedByteArray] = []
	for layer in 3:
		normal_layers.append(await _read_texture(demo.solver.get_normal_tex_rid(), layer,
			map_size * map_size * 8))
		foam_layers.append(_foam_base(await _read_texture(
			demo.solver.get_foam_near_read_tex_rid(), layer), size))
		if normal_layers[layer].is_empty() or foam_layers[layer].is_empty():
			push_error("HISTO FAIL: empty layer %d readback" % layer)
			demo.queue_free()
			quit(1)
			return
		var stats := _field_stats(normal_layers[layer], map_size, foam_layers[layer], size)
		if stats.finite != stats.expected or stats.source_finite != stats.source_expected:
			push_error("HISTO FAIL: non-finite field")
			quit(1)
			return
		print("HISTO layer=%d cascade_source_mean=%.6f cascade_source_cov=%.6f persistent_mean=%.6f fresh_mean=%.6f max=%.6f finite=%d/%d source_finite=%d/%d" % [
			layer, stats.source_mean, stats.source_coverage, stats.persistent_mean,
			stats.fresh_mean, stats.max, stats.finite, stats.expected,
			stats.source_finite, stats.source_expected])
		print("HISTO layer=%d source_alpha:%s" % [layer,
			_histogram(normal_layers[layer], map_size, 6, 4)])
	demo.queue_free()
	await process_frame
	print("HISTO DONE")
	quit(0)
