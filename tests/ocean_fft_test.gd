extends "res://tests/test_case.gd"

const LOOP_PERIOD := 200.0
const PRESETS := [0, 1, 3]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.set_frozen(true)
	demo.apply_preset(0)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.initialized and demo.texture_bound, "ocean did not initialize")
	if not demo.solver.initialized or not demo.texture_bound:
		demo.queue_free()
		_finish("ocean_fft")
		return

	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	var states: Array[Dictionary] = []
	for preset_index in PRESETS:
		demo.apply_preset(preset_index)
		demo._sim_time = 12.0
		demo.solver.sim_time = 12.0
		demo.set_frozen(false)
		await _frames(45)
		demo.set_frozen(true)
		states.append(await _state_metrics(demo))

	for state in states:
		_check(state.non_finite == 0, "ocean produced NaN or Inf")
		for energy in state.band_rms:
			_check(energy > 0.001, "one FFT band has no measurable energy")
	_check(states[0].height_rms < states[1].height_rms
		and states[1].height_rms < states[2].height_rms,
		"wave height is not monotonic from Calm to Storm")
	_check(states[0].slope_rms < states[1].slope_rms
		and states[1].slope_rms < states[2].slope_rms,
		"wave slope is not monotonic from Calm to Storm")
	_check(states[0].crest_mean < states[1].crest_mean
		and states[1].crest_mean < states[2].crest_mean,
		"crest compression is not monotonic from Calm to Storm")
	_check(states[0].foam_mean < 0.0001
		and states[0].foam_mean < states[1].foam_mean
		and states[1].foam_mean < states[2].foam_mean,
		"simulated ocean foam is not monotonic from Calm to Storm")
	_check(demo.PRESETS[0].foam_amount == 0.0
		and demo.PRESETS[0].spray_amount == 0.0
		and demo.PRESETS[0].foam_amount < demo.PRESETS[1].foam_amount
		and demo.PRESETS[1].foam_amount < demo.PRESETS[3].foam_amount,
		"foam presets do not progress from Calm to Storm")

	demo.set_frozen(false)
	await _frames(240)
	demo.set_frozen(true)
	var settled_storm := await _state_metrics(demo)
	_check(settled_storm.foam_coverage < 0.25,
		"storm foam history saturated %.1f%% of the long-wave tile"
		% (settled_storm.foam_coverage * 100.0))

	var loop_start: float = demo._sim_time
	var at_start := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	demo.solver.mark_spectrum_dirty()
	await _frames(8)
	var regenerated := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(at_start == regenerated, "fixed seeds are not deterministic")
	demo._sim_time = loop_start + LOOP_PERIOD
	demo.solver.sim_time = loop_start + LOOP_PERIOD
	await _frames(8)
	var looped := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	var loop_error := _texture_difference_rms(at_start, looped)
	_check(loop_error < 0.001, "ocean 200-second loop RMS error is %f" % loop_error)

	demo.set_backend(OceanSolver.Backend.JONSWAP_TMA)
	await _frames(12)
	var jonswap := await _read_texture(demo.solver.get_displacement_tex_rid(), 0)
	_check(_height_rms(jonswap).rms > 0.001, "JONSWAP backend lost all energy")
	demo.set_backend(OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	demo.set_map_size(256)
	for frame in 360:
		await process_frame
		if demo.solver.initialized and demo.texture_bound:
			break
	_check(demo.solver.initialized and demo.texture_bound and demo.solver.map_size == 256,
		"256 performance mode did not reinitialize")

	demo.queue_free()
	await process_frame
	_finish("ocean_fft")


func _state_metrics(demo) -> Dictionary:
	var height_sq := 0.0
	var height_count := 0
	var non_finite := 0
	var band_rms: Array[float] = []
	for layer in 3:
		var data := await _read_texture(demo.solver.get_displacement_tex_rid(), layer)
		var metrics := _height_rms(data)
		band_rms.append(metrics.rms)
		height_sq += metrics.sum_sq
		height_count += metrics.count
		non_finite += metrics.non_finite
	var normal := await _read_texture(demo.solver.get_normal_tex_rid(), 0)
	var normal_metrics := _normal_metrics(normal)
	non_finite += normal_metrics.non_finite
	return {
		"height_rms": sqrt(height_sq / maxf(height_count, 1)),
		"slope_rms": normal_metrics.slope_rms,
		"crest_mean": normal_metrics.crest_mean,
		"foam_mean": normal_metrics.foam_mean,
		"foam_coverage": normal_metrics.foam_coverage,
		"band_rms": band_rms,
		"non_finite": non_finite,
	}


func _height_rms(data: PackedByteArray) -> Dictionary:
	var sum_sq := 0.0
	var count := 0
	var non_finite := 0
	for i in data.size() / 8:
		var decoded := _half(data.decode_u16(i * 8 + 2))
		if not decoded.finite:
			non_finite += 1
			continue
		sum_sq += decoded.value * decoded.value
		count += 1
	return {"rms": sqrt(sum_sq / maxf(count, 1)), "sum_sq": sum_sq,
		"count": count, "non_finite": non_finite}


func _normal_metrics(data: PackedByteArray) -> Dictionary:
	var slope_sq := 0.0
	var crest_sum := 0.0
	var foam_sum := 0.0
	var foam_active := 0
	var count := 0
	var non_finite := 0
	for i in data.size() / 8:
		var x := _half(data.decode_u16(i * 8))
		var y := _half(data.decode_u16(i * 8 + 2))
		var crest := _half(data.decode_u16(i * 8 + 4))
		var foam := _half(data.decode_u16(i * 8 + 6))
		if not x.finite or not y.finite or not crest.finite or not foam.finite:
			non_finite += 1
			continue
		slope_sq += x.value * x.value + y.value * y.value
		crest_sum += crest.value
		foam_sum += foam.value
		if foam.value > 0.15:
			foam_active += 1
		count += 1
	return {"slope_rms": sqrt(slope_sq / maxf(count, 1)),
		"crest_mean": crest_sum / maxf(count, 1),
		"foam_mean": foam_sum / maxf(count, 1),
		"foam_coverage": float(foam_active) / maxf(count, 1), "non_finite": non_finite}


func _texture_difference_rms(a: PackedByteArray, b: PackedByteArray) -> float:
	if a.size() != b.size() or a.is_empty():
		return INF
	var sum_sq := 0.0
	var count := 0
	for i in range(0, a.size() / 8, 4):
		var av := _half(a.decode_u16(i * 8 + 2))
		var bv := _half(b.decode_u16(i * 8 + 2))
		if not av.finite or not bv.finite:
			return INF
		var difference: float = av.value - bv.value
		sum_sq += difference * difference
		count += 1
	return sqrt(sum_sq / maxf(count, 1))


func _half(bits: int) -> Dictionary:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return {"value": 0.0, "finite": false}
	var sign_value := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return {"value": sign_value * mantissa * pow(2.0, -24), "finite": true}
	return {"value": sign_value * (1.0 + mantissa / 1024.0)
		* pow(2.0, exponent - 15), "finite": true}


func _read_texture(rid: RID, layer: int) -> PackedByteArray:
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store_readback", state, data)
		)
	)
	for frame in 360:
		await process_frame
		if state.done:
			return state.data
	_check(false, "ocean texture readback timed out")
	return PackedByteArray()


func _store_readback(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
