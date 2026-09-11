extends SceneTree

const SAMPLE_FRAMES := [60, 180, 600, 1800, 3600]
const FIXED_DT := 1.0 / 30.0
const READBACK_TIMEOUT_MS := 10000


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
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store", state, data)
		)
	)
	var deadline := Time.get_ticks_msec() + READBACK_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if state.done:
			if expected_bytes > 0 and state.data.size() != expected_bytes:
				push_error("FOAM PROBE FAIL: readback size mismatch (%d != %d)" % [
					state.data.size(), expected_bytes])
				return PackedByteArray()
			return state.data
	push_error("FOAM PROBE FAIL: texture readback timed out")
	return PackedByteArray()


func _store(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


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


func _source_stats(data: PackedByteArray, size: int) -> Dictionary:
	var finite := 0
	var active := 0
	var sum := 0.0
	for i in size * size:
		var value := _half(data.decode_u16(i * 8 + 6))
		if is_nan(value) or is_inf(value):
			continue
		finite += 1
		sum += value
		if value > 0.035:
			active += 1
	return {
		"mean": sum / maxf(float(finite), 1.0),
		"coverage": float(active) / maxf(float(finite), 1.0),
		"finite": finite,
		"expected": size * size,
	}


func _foam_stats(data: PackedByteArray, size: int) -> Dictionary:
	var finite := 0
	var persistent_sum := 0.0
	var fresh_sum := 0.0
	var maximum := 0.0
	var minimum := 0.0
	for i in size * size:
		var persistent := data.decode_float(i * 8)
		var fresh := data.decode_float(i * 8 + 4)
		if is_nan(persistent) or is_inf(persistent) \
				or is_nan(fresh) or is_inf(fresh):
			continue
		finite += 1
		persistent_sum += persistent
		fresh_sum += fresh
		maximum = maxf(maximum, maxf(persistent, fresh))
		minimum = minf(minimum, minf(persistent, fresh))
	var divisor := maxf(float(finite), 1.0)
	return {
		"persistent": persistent_sum / divisor,
		"fresh": fresh_sum / divisor,
		"max": maximum,
		"min": minimum,
		"finite": finite,
		"expected": size * size,
	}


func _run() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline \
			and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("FOAM PROBE FAIL: ocean did not initialize before deadline")
		demo.queue_free()
		quit(1)
		return
	demo.set_quality_profile(OceanQualityProfile.Tier.HIGH)
	deadline = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and not (demo.solver.initialized and demo.texture_bound):
		await process_frame
	if not demo.solver.initialized or not demo.texture_bound:
		push_error("FOAM PROBE FAIL: quality did not initialize")
		quit(1)
		return
	demo.apply_preset(3)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(FIXED_DT)
	demo.set_capture_ui(false)
	demo.set_capture_interaction(false)
	demo.set_frozen(false)
	var elapsed := 0
	var map_size: int = demo.solver.map_size
	var near_size: int = demo.solver.foam_near_size
	print("FOAM PROBE preset=Storm quality=High seed=1000,31337 domains=%s map_size=%d near_size=%d" % [
		demo.solver.foam_field_domains(), map_size, near_size])
	for target in SAMPLE_FRAMES:
		while elapsed < target:
			demo.move_capture_camera(Vector3(0.5, 0.0, 0.0))
			await process_frame
			elapsed += 1
		demo.set_frozen(true)
		var lines: Array[String] = []
		for layer in 3:
			var normal := await _read_texture(demo.solver.get_normal_tex_rid(), layer,
				map_size * map_size * 8)
			var foam := _foam_base(await _read_texture(
				demo.solver.get_foam_near_read_tex_rid(), layer), near_size)
			if normal.is_empty() or foam.is_empty():
				push_error("FOAM PROBE FAIL: empty layer %d at frame %d" % [layer, target])
				demo.queue_free()
				quit(1)
				return
			var source := _source_stats(normal, map_size)
			var field := _foam_stats(foam, near_size)
			if source.finite != source.expected or field.finite != field.expected or field.max > 1.0 or field.min < 0.0:
				push_error("FOAM PROBE FAIL: non-finite or unbounded field")
				quit(1)
				return
			lines.append("layer=%d cascade_source_mean=%.6f cascade_source_cov=%.6f persistent_mean=%.6f fresh_mean=%.6f max=%.6f source_finite=%d/%d foam_finite=%d/%d" % [
				layer, source.mean, source.coverage, field.persistent, field.fresh,
				field.max, source.finite, source.expected, field.finite, field.expected])
		print("FOAM CONVERGENCE frame=%d seconds=%.1f state=%s %s" % [
			target, float(target) * FIXED_DT, JSON.stringify(demo.solver.foam_state()), " | ".join(lines)])
		demo.set_frozen(false)
	demo.queue_free()
	await process_frame
	print("FOAM CONVERGENCE DONE")
	quit(0)
