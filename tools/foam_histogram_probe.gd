extends SceneTree
## Temporary diagnostic: histogram of layer-0 breaking (normal.a) and foam
## (foam.r) channels on the Storm preset after 20 s of live simulation.

func _initialize() -> void:
	call_deferred("_run")


func _half(bits: int) -> float:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return 0.0
	var sign := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return sign * mantissa * pow(2.0, -24.0)
	return sign * (1.0 + mantissa / 1024.0) * pow(2.0, exponent - 15)


func _read_texture(rid: RID, layer: int) -> PackedByteArray:
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store", state, data)
		)
	)
	for frame in 360:
		await process_frame
		if state.done:
			return state.data
	return PackedByteArray()


func _store(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


func _run() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	demo.apply_preset(3)
	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	demo.set_capture_time(20.0)
	demo.set_capture_fixed_delta(1.0 / 30.0)
	demo.set_frozen(false)
	for frame in 600:
		await process_frame
	demo.set_frozen(true)
	await process_frame
	var normal := await _read_texture(demo.solver.get_normal_tex_rid(), 0)
	var foam := await _read_texture(demo.solver.get_foam_read_tex_rid(0), 0)
	for channel_setup in 2:
		var bins := {}
		var size := (normal.size() / 8) if channel_setup == 0 else (foam.size() / 4)
		for i in size:
			var value: float
			if channel_setup == 0:
				value = _half(normal.decode_u16(i * 8 + 6))
			else:
				value = _half(foam.decode_u16(i * 4))
			var bin := int(clampf(value, 0.0, 1.0) * 20.0)
			bins[bin] = bins.get(bin, 0) + 1
		var label := "breaking" if channel_setup == 0 else "foam.r"
		var line := "HISTO %s:" % label
		for bin in 21:
			line += " %.0f" % (float(bins.get(bin, 0)) * 100.0 / float(size))
		print(line)
	demo.queue_free()
	await process_frame
	print("HISTO DONE")
	quit(0)
