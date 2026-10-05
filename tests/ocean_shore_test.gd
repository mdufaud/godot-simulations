extends "res://tests/test_case.gd"

const ShoreSolver := preload("res://scripts/ocean/ocean_shore_solver.gd")
const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const N := 128
const DOMAIN := 160.0
const TILES: PackedFloat32Array = [2039.0, 111.0, 25.0]

var _solver: OceanShoreSolver
var _spectrum := RID()
var _rd: RenderingDevice
var _bed := PackedFloat32Array()
var _result := {"ready": false, "ok": false}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	await process_frame
	RenderingServer.call_on_render_thread(_create_render)
	for frame in 120:
		await process_frame
		if _result.ready:
			break
	_check(_result.ready and _result.ok, "shore solver did not initialize on the GPU")
	if not _result.ok:
		_finish("ocean_shore")
		return
	await _lake_at_rest()
	await _uniform_flow_foam()
	await _mass_and_positivity()
	await _runup_and_rock()
	await _render_rate_parity()
	await _backlog_retention()
	await _wave_propagation()
	await _boundary_velocity()
	await _forced_render_rate_parity()
	await _open_water_budget()
	await _tier_sizing()
	RenderingServer.call_on_render_thread(func():
		_solver.free_render()
		if _spectrum.is_valid():
			_rd.free_rid(_spectrum)
		_spectrum = RID()
	)
	await RenderingServer.frame_post_draw
	_finish("ocean_shore")


func _create_render() -> void:
	_rd = GpuPreflight.device("OceanShoreTest")
	if _rd == null:
		_result.ready = true
		return
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	format.width = N
	format.height = N
	format.array_layers = 3
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_spectrum = _rd.texture_create(format, RDTextureView.new(), [])
	_rd.texture_clear(_spectrum, Color(0, 0, 0, 0), 0, 1, 0, 3)
	_solver = ShoreSolver.new()
	_bed.resize(N * N)
	for y in N:
		for x in N:
			var p := _world(x, y)
			_bed[y * N + x] = -4.0 + 5.5 * exp(-p.length_squared() / 350.0)
	_result.ok = _solver.init_render(_spectrum, N, TILES, 0, _bed)
	_result.ready = true


func _lake_at_rest() -> void:
	await _advance(0.6, 30)
	var surface := await _surface()
	var foam := await _foam()
	var max_height := 0.0
	var max_speed := 0.0
	var max_foam := 0.0
	for i in N * N:
		if surface[i * 4 + 3] > ShoreSolver.DRY_DEPTH_M:
			max_height = maxf(max_height, absf(surface[i * 4]))
		max_speed = maxf(max_speed, Vector2(surface[i * 4 + 1], surface[i * 4 + 2]).length())
		max_foam = maxf(max_foam, maxf(foam[i * 4], foam[i * 4 + 1]))
	_check(max_height < 0.00002 and max_speed < 0.0001,
		"lake at rest drifted (height %.9f, speed %.9f)" % [max_height, max_speed])
	_check(max_foam < 0.00001, "still water generated shoreline foam")
	print("OCEAN SHORE lake height=%.9f speed=%.9f foam=%.9f" % [max_height, max_speed, max_foam])


func _mass_and_positivity() -> void:
	var bed := _closed_bed(false)
	await _reset_bed(bed)
	var initial := _initial_water(bed, false)
	await _seed(initial)
	var before := _mass(initial)
	await _advance(1.0, 30, PackedVector4Array([Vector4(-10.0, 0.0, 7000.0, 1500.0)]))
	var surface := await _surface()
	var after := _mass_surface(surface)
	var minimum := INF
	var invalid := 0
	for i in N * N:
		minimum = minf(minimum, surface[i * 4 + 3])
		for channel in 4:
			if not is_finite(surface[i * 4 + channel]):
				invalid += 1
	var error := absf(after - before) / before
	_check(minimum >= 0.0 and invalid == 0, "wet/dry solver produced negative or non-finite water")
	_check(error < 0.00002, "closed shoreline mass drifted by %.9f" % error)
	print("OCEAN SHORE mass relative-error=%.9f minimum-depth=%.9f invalid=%d" % [error, minimum, invalid])


func _uniform_flow_foam() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-0.1)
	await _reset_bed(bed)
	var water := PackedFloat32Array()
	water.resize(N * N * 4)
	for i in N * N:
		water[i * 4] = 0.1
		water[i * 4 + 1] = 0.05
	await _seed(water)
	for frame in 30:
		RenderingServer.call_on_render_thread(_solver.step_render.bind(
			1.0 / 30.0, float(frame + 1) / 30.0, Vector2(0.5, 0.0),
			1.0, 0.5, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var foam := await _foam()
	var maximum := 0.0
	for i in N * N:
		maximum = maxf(maximum, maxf(foam[i * 4], foam[i * 4 + 1]))
	_check(maximum < 0.00001, "uniform shallow flow generated a stationary foam sheet")
	print("OCEAN SHORE uniform-flow foam=%.9f" % maximum)


func _runup_and_rock() -> void:
	var bed := _closed_bed(true)
	await _reset_bed(bed)
	await _seed(_initial_water(bed, true))
	await _advance(3.0, 30)
	var surface := await _surface()
	var foam := await _foam()
	var inland_depth := 0.0
	var rock_depth := 0.0
	var wetness := 0.0
	var moving_foam := 0.0
	for y in N:
		for x in N:
			var i := y * N + x
			var p := _world(x, y)
			if p.x > 0.0 and p.x < 12.0 and absf(p.y) < 10.0:
				inland_depth = maxf(inland_depth, surface[i * 4 + 3])
				wetness = maxf(wetness, foam[i * 4 + 3])
			if bed[i] > 5.0:
				rock_depth = maxf(rock_depth, surface[i * 4 + 3])
			moving_foam = maxf(moving_foam, maxf(foam[i * 4], foam[i * 4 + 1]))
	_check(inland_depth > 0.01 and wetness > 0.2,
		"traveling pulse did not run up the positive sand bed (depth %.6f, wetness %.6f)" % [inland_depth, wetness])
	_check(rock_depth <= ShoreSolver.DRY_DEPTH_M, "water flowed through elevated rock bathymetry")
	_check(moving_foam > 0.001, "wet fronts generated no transported foam")
	print("OCEAN SHORE runup depth=%.6f wetness=%.6f rock-depth=%.9f foam=%.6f" % [inland_depth, wetness, rock_depth, moving_foam])
	await _advance(7.0, 30)
	var retreat := await _surface()
	var retained := await _foam()
	var retreat_depth := 0.0
	var backwash := 0.0
	var deposit := 0.0
	var retained_wetness := 0.0
	for y in N:
		for x in N:
			var i := y * N + x
			var p := _world(x, y)
			if p.x > 0.0 and p.x < 12.0 and absf(p.y) < 10.0:
				retreat_depth = maxf(retreat_depth, retreat[i * 4 + 3])
				deposit = maxf(deposit, retained[i * 4 + 2])
				retained_wetness = maxf(retained_wetness, retained[i * 4 + 3])
			if p.x > -15.0 and p.x < 10.0 and absf(p.y) < 10.0 \
					and retreat[i * 4 + 3] > ShoreSolver.DRY_DEPTH_M:
				backwash = minf(backwash, retreat[i * 4 + 1])
	_check(retreat_depth < inland_depth * 0.75 and backwash < -0.01,
		"runup pulse did not retreat with backwash (depth %.6f, velocity %.6f)" % [retreat_depth, backwash])
	_check(deposit > 0.001 and retained_wetness > 0.2,
		"retreating front did not leave persistent sand foam/wetness")
	print("OCEAN SHORE retreat depth=%.6f backwash=%.6f deposit=%.6f wetness=%.6f" % [retreat_depth, backwash, deposit, retained_wetness])


func _render_rate_parity() -> void:
	var bed := _closed_bed(false)
	var initial := _initial_water(bed, false)
	var outputs: Array[PackedFloat32Array] = []
	for fps: int in [30, 60, 120]:
		await _reset_bed(bed)
		await _seed(initial)
		await _advance(0.5, fps, PackedVector4Array([Vector4(-8.0, 0.0, 3000.0, 0.0)]))
		outputs.append(await _surface())
	var maximum := 0.0
	for rate in [1, 2]:
		for i in outputs[0].size():
			maximum = maxf(maximum, absf(outputs[0][i] - outputs[rate][i]))
	_check(maximum < 0.00001, "shoreline output changed at 30/60/120 Hz (max %.9f)" % maximum)
	print("OCEAN SHORE render-rate max-difference=%.9f" % maximum)


func _boundary_velocity() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-4.0)
	await _reset_bed(bed)
	var mode := 8
	var wave := PackedFloat32Array()
	wave.resize(N * N * 4)
	var positive := ((N / 2) * N + N / 2 + mode) * 4
	var negative := ((N / 2) * N + N / 2 - mode) * 4
	wave[positive] = 0.1
	wave[negative + 2] = 0.1
	var bytes := wave.to_byte_array()
	RenderingServer.call_on_render_thread(func():
		_rd.texture_update(_spectrum, 0, bytes)
		_solver.step_render(1.0 / 30.0, 1.0 / 30.0, Vector2.ZERO, 1.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var boundary_data: PackedByteArray = await TextureReadback.new().read_layer(_solver._boundary_rid, 0, N * N * 16)
	var boundary := boundary_data.to_float32_array()
	var height_max := 0.0
	var speed_max := 0.0
	for i in N * N:
		height_max = maxf(height_max, absf(boundary[i * 4]))
		speed_max = maxf(speed_max, absf(boundary[i * 4 + 2]))
	var k := TAU * float(mode) / TILES[0]
	var expected := sqrt(ShoreSolver.GRAVITY * k * tanh(k * 4.0)) / (k * 4.0)
	_check(height_max > 0.15 and absf(speed_max / height_max - expected) < 0.001,
		"FFT boundary velocity does not use omega/(k*d) paired modes")
	print("OCEAN SHORE boundary speed/height=%.6f expected=%.6f" % [speed_max / maxf(height_max, 0.000001), expected])


func _backlog_retention() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-4.0)
	await _reset_bed(bed)
	RenderingServer.call_on_render_thread(_solver.step_render.bind(1.0, 1.0,
		Vector2.ZERO, 1.0, 0.5, PackedVector4Array()))
	await RenderingServer.frame_post_draw
	var before := {"control": PackedByteArray()}
	RenderingServer.call_on_render_thread(func(): before.control = _rd.buffer_get_data(_solver._buffers.control))
	await RenderingServer.frame_post_draw
	var initial: PackedByteArray = before.control
	var accounted := initial.decode_float(0) + initial.decode_float(4) + initial.decode_float(8)
	_check(initial.decode_float(8) > 0.1 and absf(accounted - 1.0) < 0.00001,
		"24-substep cap discarded elapsed shoreline time")
	for frame in 10:
		RenderingServer.call_on_render_thread(_solver.step_render.bind(0.0, 1.0,
			Vector2.ZERO, 1.0, 0.5, PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var after := {"control": PackedByteArray()}
	RenderingServer.call_on_render_thread(func(): after.control = _rd.buffer_get_data(_solver._buffers.control))
	await RenderingServer.frame_post_draw
	var drained: PackedByteArray = after.control
	_check(absf(drained.decode_float(0) - 1.0) < 0.00001
		and drained.decode_u32(24) == 30 and drained.decode_float(8) < 0.00001,
		"retained GPU backlog did not finish its 30 macro steps")
	print("OCEAN SHORE backlog accounted=%.6f drained-time=%.6f macros=%d" % [accounted, drained.decode_float(0), drained.decode_u32(24)])


func _wave_propagation() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-4.0)
	await _reset_bed(bed)
	var wave := PackedFloat32Array()
	wave.resize(N * N * 4)
	var initial_amplitude := 0.0
	for y in N:
		for x in N:
			var i := y * N + x
			var z := _world(x, y).y + 25.0
			var eta := 0.1 * cos(TAU * z / 37.0) * exp(-pow(z / 28.0, 2.0))
			wave[i * 4] = 4.0 + eta
			wave[i * 4 + 2] = wave[i * 4] * sqrt(ShoreSolver.GRAVITY / 4.0) * eta
			initial_amplitude = maxf(initial_amplitude, absf(eta))
	await _seed(wave)
	await _advance(8.0, 30)
	var surface := await _surface()
	var propagated_amplitude := 0.0
	for y in N:
		for x in N:
			var p := _world(x, y)
			if absf(p.x) < 10.0 and p.y > 0.0 and p.y < 60.0:
				propagated_amplitude = maxf(propagated_amplitude, absf(surface[(y * N + x) * 4]))
	var retained := propagated_amplitude / initial_amplitude
	_check(retained > 0.75 and retained < 1.1,
		"37 m wave lost excessive amplitude over 50 m (retained %.4f)" % retained)
	print("OCEAN SHORE propagation wavelength=37m distance=50m amplitude-retained=%.6f" % retained)


func _open_water_budget() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-4.0)
	await _reset_bed(bed)
	await _advance(1.0, 30)
	var result := {"state": PackedByteArray(), "balance": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var control := _rd.buffer_get_data(_solver._buffers.control)
		var index := control.decode_u32(16)
		result.state = _rd.buffer_get_data(_solver._buffers.state, index * N * N * 16, N * N * 16)
		result.balance = _rd.buffer_get_data(_solver._buffers.balance)
	)
	await RenderingServer.frame_post_draw
	var state: PackedFloat32Array = result.state.to_float32_array()
	var balance: PackedFloat32Array = result.balance.to_float32_array()
	var boundary_volume := 0.0
	var sponge_volume := 0.0
	var clipping_volume := 0.0
	for i in N * N:
		boundary_volume += balance[i * 4]
		sponge_volume += balance[i * 4 + 1]
		clipping_volume += balance[i * 4 + 2]
	var initial_volume := 4.0 * DOMAIN * DOMAIN
	var volume := _mass(state)
	var error := absf(volume - initial_volume - boundary_volume - sponge_volume - clipping_volume)
	_check(absf(boundary_volume) + absf(sponge_volume) > 1.0,
		"open water budget did not exercise boundary or sponge exchange")
	_check(error / initial_volume < 0.00001 and clipping_volume < 0.001,
		"open water budget does not equal conservative boundary+sponge flux (error %.6f)" % error)
	print("OCEAN SHORE open-budget boundary=%.6f sponge=%.6f clipping=%.9f error=%.6f" % [boundary_volume, sponge_volume, clipping_volume, error])


func _tier_sizing() -> void:
	for tier in 4:
		var size: int = ShoreSolver.GRID_SIZES[tier]
		var bed := PackedFloat32Array()
		bed.resize(size * size)
		bed.fill(-4.0)
		var result := {"ok": false, "stable": false, "width": 0}
		RenderingServer.call_on_render_thread(func():
			result.ok = _solver.init_render(_spectrum, N, TILES, tier, bed)
			var surface := _solver.get_texture_rid()
			var foam := _solver.get_foam_texture_rid()
			var derivative := _solver.get_derivative_texture_rid()
			_solver.step_render(1.0 / 30.0, 1.0 / 30.0, Vector2.ZERO, 1.0, 0.5, PackedVector4Array())
			result.stable = surface == _solver.get_texture_rid() \
				and foam == _solver.get_foam_texture_rid() and derivative == _solver.get_derivative_texture_rid()
			result.width = _rd.texture_get_format(surface).width
		)
		await RenderingServer.frame_post_draw
		_check(result.ok and result.stable and result.width == size,
			"tier %d did not produce stable %d-square shore maps" % [tier, size])
		print("OCEAN SHORE tier=%d grid=%d stable=%s" % [tier, result.width, result.stable])


func _forced_render_rate_parity() -> void:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	bed.fill(-4.0)
	var outputs: Array[PackedFloat32Array] = []
	for fps: int in [30, 60, 120]:
		await _reset_bed(bed)
		await _advance(1.0, fps)
		outputs.append(await _surface())
	var maximum := 0.0
	for rate in [1, 2]:
		for i in outputs[0].size():
			maximum = maxf(maximum, absf(outputs[0][i] - outputs[rate][i]))
	_check(maximum < 0.00001,
		"FFT-forced shoreline changed at 30/60/120 Hz (max %.9f)" % maximum)
	print("OCEAN SHORE forced-render-rate max-difference=%.9f" % maximum)


func _closed_bed(rock: bool) -> PackedFloat32Array:
	var bed := PackedFloat32Array()
	bed.resize(N * N)
	for y in N:
		for x in N:
			var p := _world(x, y)
			var height := clampf(p.x * 0.045, -3.0, 3.0)
			if maxf(absf(p.x), absf(p.y)) > 62.0:
				height = 10.0
			if rock and p.distance_to(Vector2(-3.0, 8.0)) < 3.0:
				height = 10.0
			bed[y * N + x] = height
	return bed


func _initial_water(bed: PackedFloat32Array, traveling: bool) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(N * N * 4)
	for y in N:
		for x in N:
			var i := y * N + x
			var p := _world(x, y)
			var pulse := 0.6 * exp(-pow((p.x + 12.0) / 7.0, 2.0) - pow(p.y / 10.0, 2.0)) if traveling else 0.0
			var h := maxf(pulse - bed[i], 0.0)
			data[i * 4] = h
			data[i * 4 + 1] = h * pulse * sqrt(ShoreSolver.GRAVITY / maxf(h, 0.01)) if traveling else 0.0
	return data


func _reset_bed(bed: PackedFloat32Array) -> void:
	_bed = bed.duplicate()
	RenderingServer.call_on_render_thread(func():
		_solver.set_bathymetry(bed)
		_solver.step_render(0.0, 0.0, Vector2.ZERO, 1.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw


func _seed(data: PackedFloat32Array) -> void:
	var bytes := data.to_byte_array()
	var doubled := bytes.duplicate()
	doubled.append_array(bytes)
	RenderingServer.call_on_render_thread(func():
		for name in ["state", "completed_state"]:
			_rd.buffer_update(_solver._buffers[name], 0, doubled.size(), doubled)
		_solver.step_render(0.0, 0.0, Vector2.ZERO, 1.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw


func _advance(duration: float, fps: int, first_impulse := PackedVector4Array()) -> void:
	var frames := int(round(duration * float(fps)))
	var dt := 1.0 / float(fps)
	for frame in frames:
		var impulses := first_impulse if frame == 0 else PackedVector4Array()
		RenderingServer.call_on_render_thread(_solver.step_render.bind(dt, float(frame + 1) * dt,
			Vector2.ZERO, 1.0, 0.5, impulses))
		await RenderingServer.frame_post_draw


func _surface() -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(_solver.get_texture_rid(), 0, N * N * 16)
	_check(bytes.size() == N * N * 16, "shore surface readback failed")
	return bytes.to_float32_array()


func _foam() -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(_solver.get_foam_texture_rid(), 0, N * N * 16)
	_check(bytes.size() == N * N * 16, "shore foam readback failed")
	return bytes.to_float32_array()


func _mass(data: PackedFloat32Array) -> float:
	var mass := 0.0
	for i in range(0, data.size(), 4):
		mass += data[i]
	return mass * pow(DOMAIN / float(N), 2.0)


func _mass_surface(data: PackedFloat32Array) -> float:
	var mass := 0.0
	for i in range(0, data.size(), 4):
		mass += data[i + 3]
	return mass * pow(DOMAIN / float(N), 2.0)


func _world(x: int, y: int) -> Vector2:
	return (Vector2(x, y) + Vector2(0.5, 0.5)) * (DOMAIN / float(N)) - Vector2.ONE * DOMAIN * 0.5
