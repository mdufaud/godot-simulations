extends "res://tests/test_case.gd"

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const LOW_TIER := OceanQualityProfile.Tier.LOW
const IMPULSE := Vector4(0.0, 0.0, 1000.0, 0.0)
const HALF_QUANTUM_TOLERANCE := 0.000004

var _demo
var _local_solver: OceanLocalSolver
var _rd: RenderingDevice
var _restore_tier := OceanQualityProfile.default_tier()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game_manager: Variant = root.get_node_or_null("/root/GameManager")
	if game_manager != null:
		_restore_tier = int(game_manager.get_setting(
			"ocean_quality_profile", OceanQualityProfile.default_tier()))
		game_manager.set_setting("ocean_quality_profile", LOW_TIER)
	_demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(_demo)
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _demo.solver.initialized and _demo.texture_bound:
			break
	_check(_demo.solver.initialized and _demo.texture_bound,
		"Low ocean scene did not initialize with bound textures")
	if not _demo.solver.initialized or not _demo.texture_bound:
		await _finish_scene(game_manager)
		_finish("ocean_physics")
		return
	_check(_demo.solver.quality_tier == LOW_TIER
		and _demo.solver.map_size == OceanQualityProfile.FFT_SIZE[LOW_TIER],
		"ocean scene did not boot at Low quality")
	_demo.set_frozen(true)
	_demo.process_mode = Node.PROCESS_MODE_DISABLED
	_local_solver = _demo.solver.local_solver
	_rd = RenderingServer.get_rendering_device()
	_check(_local_solver != null and _local_solver.state().initialized and _rd != null,
		"local coast/wake solver is not initialized on the GPU")
	if _local_solver == null or not _local_solver.state().initialized or _rd == null:
		await _finish_scene(game_manager)
		_finish("ocean_physics")
		return
	var deep_residual := await _deep_offshore_case()
	_check(absf(deep_residual) < 0.00001,
		"80 m coast cell developed a residual against its identical offshore field")
	print("OCEAN PHYSICS deep-residual-corner=%.9f" % deep_residual)
	var zero := await _run_case(60, false)
	_check(_max_abs_height(zero.coast) < 1.0e-7
		and _max_abs_height(zero.wake) < 1.0e-7,
		"zero offshore state drifted in coast or wake fields")
	print("OCEAN PHYSICS zero-height coast=%.9f wake=%.9f" % [
		_max_abs_height(zero.coast), _max_abs_height(zero.wake)])
	var at_30 := await _run_case(30, true)
	var at_60 := await _run_case(60, true)
	var at_120 := await _run_case(120, true)
	_check(_max_abs_height(at_30.wake) > 0.00001,
		"1000 Ns wake impulse produced no measurable local wave")
	print("OCEAN PHYSICS impulse-max-height 30=%.9f 60=%.9f 120=%.9f" % [
		_max_abs_height(at_30.wake), _max_abs_height(at_60.wake),
		_max_abs_height(at_120.wake)])
	for result in [at_30, at_60, at_120]:
		_check(_max_abs_height(result.coast) < 1.0e-7,
			"wake impulse contaminated the coast field")
	var equal_60 := _near_outputs(at_30.wake, at_60.wake)
	var equal_120 := _near_outputs(at_30.wake, at_120.wake)
	_check(equal_60 and equal_120,
		"local wake evolution changed with render rate (30/60/120 Hz)")
	var pressure_height := await _pressure_case()
	_check(pressure_height < -0.000001,
		"positive support pressure did not launch a negative local height pulse")
	print("OCEAN PHYSICS pressure-center-height=%.9f" % pressure_height)
	await _check_recenter()
	await _check_runtime_crates_and_equilibrium()
	await _check_spray_persistence()
	await _finish_scene(game_manager)
	_finish("ocean_physics")


func _run_case(fps: int, apply_impulse: bool) -> Dictionary:
	var displacement: RID = _demo.solver.get_displacement_tex_rid()
	var velocity: RID = _demo.solver.velocity_solver.get_texture_rid()
	var initial_force := PackedVector4Array([IMPULSE]) if apply_impulse \
		else PackedVector4Array()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			_rd.texture_clear(displacement, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(velocity, Color(0, 0, 0, 0), 0, 1, layer, 1)
		_local_solver.request_reset()
		_local_solver.step_render(0.0, 0.0, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var coast_size: int = OceanQualityProfile.COAST_SIZE[LOW_TIER]
	var wake_size: int = OceanQualityProfile.WAKE_SIZE[LOW_TIER]
	var coast_zero := await _read_output(_local_solver.get_coast_texture_rid(), coast_size)
	var wake_zero := await _read_output(_local_solver.get_wake_texture_rid(), wake_size)
	if coast_zero.is_empty() or wake_zero.is_empty():
		return {"coast": coast_zero, "wake": wake_zero}
	var delta := 1.0 / float(fps)
	for frame in fps:
		var forces := initial_force if frame == 0 else PackedVector4Array()
		RenderingServer.call_on_render_thread(_local_solver.step_render.bind(
			delta, float(frame + 1) * delta, Vector2.ZERO, Vector2.ZERO, forces))
		await RenderingServer.frame_post_draw
	var coast := await _read_output(_local_solver.get_coast_texture_rid(), coast_size)
	var wake := await _read_output(_local_solver.get_wake_texture_rid(), wake_size)
	return {"coast": coast, "wake": wake}


func _deep_offshore_case() -> float:
	var map_size: int = _demo.solver.map_size
	var displacement: RID = _demo.solver.get_displacement_tex_rid()
	var velocity: RID = _demo.solver.velocity_solver.get_texture_rid()
	var wave := Image.create(map_size, map_size, false, Image.FORMAT_RGBAH)
	for y in map_size:
		for x in map_size:
			var eta := 0.4 * cos(TAU * 10.0 * (float(x) + 0.5) / float(map_size))
			wave.set_pixel(x, y, Color(0.0, eta, 0.0, 0.0))
	var wave_bytes := wave.get_data()
	RenderingServer.call_on_render_thread(func():
		_rd.texture_update(displacement, 0, wave_bytes)
		for layer in 1:
			_rd.texture_clear(displacement, Color(0, 0, 0, 0), 0, 1, layer + 1, 1)
		for layer in 3:
			_rd.texture_clear(velocity, Color(0, 0, 0, 0), 0, 1, layer, 1)
		_local_solver.request_reset()
		_local_solver.step_render(0.0, 0.0, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var delta := 1.0 / 30.0
	for frame in 30:
		RenderingServer.call_on_render_thread(_local_solver.step_render.bind(
			delta, float(frame + 1) * delta, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array()))
		await RenderingServer.frame_post_draw
	var coast := await _read_output(_local_solver.get_coast_texture_rid(),
		OceanQualityProfile.COAST_SIZE[LOW_TIER])
	if coast.is_empty():
		return INF
	_check(_max_abs_height(coast) > 0.0001 and _max_abs_height(coast) < 0.8,
		"coastal bathymetry has no bounded effect on the offshore wave")
	var corner := ((OceanQualityProfile.COAST_SIZE[LOW_TIER] - 1)
		* OceanQualityProfile.COAST_SIZE[LOW_TIER]
		+ OceanQualityProfile.COAST_SIZE[LOW_TIER] - 1) * 4
	return coast[corner]


func _read_output(texture: RID, size: int) -> PackedFloat32Array:
	var expected_bytes := size * size * 8
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(
		texture, 0, expected_bytes)
	_check(not bytes.is_empty(), "local output readback was empty")
	if bytes.is_empty():
		return PackedFloat32Array()
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBAH, bytes)
	image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array()


func _pressure_case() -> float:
	var displacement: RID = _demo.solver.get_displacement_tex_rid()
	var velocity: RID = _demo.solver.velocity_solver.get_texture_rid()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			_rd.texture_clear(displacement, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(velocity, Color(0, 0, 0, 0), 0, 1, layer, 1)
		_local_solver.request_reset()
		_local_solver.step_render(0.0, 0.0, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var dt := 1.0 / 30.0
	var pressure := PackedVector4Array([Vector4(0.0, 0.0, 1000.0, 0.6)])
	for frame in 3:
		var forces := pressure if frame == 0 else PackedVector4Array()
		RenderingServer.call_on_render_thread(_local_solver.step_render.bind(
			dt, float(frame + 1) * dt, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array(), forces))
		await RenderingServer.frame_post_draw
	var coast := await _read_output(_local_solver.get_coast_texture_rid(),
		OceanQualityProfile.COAST_SIZE[LOW_TIER])
	_check(_max_abs_height(coast) < 1.0e-7,
		"wake pressure forcing contaminated the coast field")
	var wake := await _read_output(_local_solver.get_wake_texture_rid(),
		OceanQualityProfile.WAKE_SIZE[LOW_TIER])
	if wake.is_empty():
		return INF
	var n := OceanQualityProfile.WAKE_SIZE[LOW_TIER]
	var middle := int(n / 2)
	var height := 0.0
	for y in [middle - 1, middle]:
		for x in [middle - 1, middle]:
			height += wake[(y * n + x) * 4] * 0.25
	return height


func _max_abs_height(values: PackedFloat32Array) -> float:
	var maximum := 0.0
	for index in range(0, values.size(), 4):
		maximum = maxf(maximum, absf(values[index]))
	return maximum


func _near_outputs(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	if a.is_empty() or b.is_empty() or a.size() != b.size():
		return false
	var error_squared := 0.0
	var signal_squared := 0.0
	var count := 0
	for index in a.size():
		if index % 4 == 3:
			continue
		var difference := a[index] - b[index]
		error_squared += difference * difference
		signal_squared += a[index] * a[index]
		count += 1
	var error_rms := sqrt(error_squared / float(count))
	var signal_rms := sqrt(signal_squared / float(count))
	return error_rms <= signal_rms * 0.01 + HALF_QUANTUM_TOLERANCE


func _check_recenter() -> void:
	var delta := 1.0 / 30.0
	RenderingServer.call_on_render_thread(_local_solver.step_render.bind(
		delta, 1.0 + delta, Vector2(64.0, 0.0), Vector2.ZERO,
		PackedVector4Array()))
	await RenderingServer.frame_post_draw
	var wake := await _read_output(_local_solver.get_wake_texture_rid(),
		OceanQualityProfile.WAKE_SIZE[LOW_TIER])
	_check(not wake.is_empty() and _max_abs_height(wake) < 1.0e-7,
		"camera recenter wrapped old wake energy into the new window")


func _check_spray_persistence() -> void:
	var spray = _demo.spray
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and not spray._physical_ready:
		await process_frame
	var capacity: int = OceanQualityProfile.SPRAY_CAPACITY[LOW_TIER]
	_check(spray._physical_ready and spray._particle_capacity == capacity,
		"Low tier spray pool did not initialize at its configured capacity")
	if not spray._physical_ready or spray._particle_capacity != capacity:
		return
	spray.amount = 0.0
	spray.set_physical_enabled(true)
	var state := PackedFloat32Array()
	state.resize(capacity * 12)
	state[0] = 100.0
	state[1] = 100.0
	state[2] = 100.0
	state[3] = 0.0
	state[capacity * 4 + 3] = 10.0
	state[capacity * 8 + 1] = 0.1
	var state_bytes := state.to_byte_array()
	var displacement: RID = _demo.solver.get_displacement_tex_rid()
	var derivatives: RID = _demo.solver.get_derivative_tex_rid()
	var velocity: RID = _demo.solver.velocity_solver.get_texture_rid()
	var foam_a: RID = _demo.solver.get_foam_near_tex_rid(0)
	var foam_b: RID = _demo.solver.get_foam_near_tex_rid(1)
	var coast: RID = _local_solver.get_coast_texture_rid()
	var wake: RID = _local_solver.get_wake_texture_rid()
	var dt := 1.0 / 30.0
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			_rd.texture_clear(displacement, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(derivatives, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(velocity, Color(0, 0, 0, 0), 0, 1, layer, 1)
		_rd.texture_clear(foam_a, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(foam_b, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(coast, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(wake, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_update(spray._particle_state_rid, 0, state_bytes)
		spray.step_render(dt, dt, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
			Vector2.ZERO, Vector3(64.0, 128.0, 256.0), 0, _demo.solver.whitecap,
			Vector4.ZERO)
	)
	await RenderingServer.frame_post_draw
	var first := await _read_spray_state(capacity)
	_check(not first.is_empty(), "spray particle state readback was empty")
	if first.size() != capacity * 12:
		return
	var gravity_delta := first[1] - 100.0
	_check(gravity_delta < -0.009 and gravity_delta > -0.013,
		"persistent spray particle did not receive one 30 Hz gravity step")
	print("OCEAN SPRAY gravity-delta-y=%.6f pool=%d" % [gravity_delta, capacity])
	var x_before := first[0]
	var z_before := first[2]
	RenderingServer.call_on_render_thread(spray.step_render.bind(dt, 2.0 * dt,
		Vector2(400.0, -300.0), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		Vector3(64.0, 128.0, 256.0), 0, _demo.solver.whitecap, Vector4.ZERO))
	await RenderingServer.frame_post_draw
	var recentered := await _read_spray_state(capacity)
	_check(not recentered.is_empty()
		and absf(recentered[0] - x_before) < 0.0001
		and absf(recentered[2] - z_before) < 0.0001,
		"camera recenter moved a persistent particle in world space")
	state[0] = 0.0
	state[1] = -1.0
	state[2] = 0.0
	state[3] = 0.0
	var reentry_bytes := state.to_byte_array()
	RenderingServer.call_on_render_thread(func():
		_rd.texture_update(spray._particle_state_rid, 0, reentry_bytes)
		spray.step_render(dt, 3.0 * dt, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
			Vector2.ZERO, Vector3(64.0, 128.0, 256.0), 0,
			_demo.solver.whitecap, Vector4.ZERO)
	)
	await RenderingServer.frame_post_draw
	var reentered := await _read_spray_state(capacity)
	_check(not reentered.is_empty()
		and reentered[3] > reentered[capacity * 4 + 3],
		"spray particle below the surface was not retired on re-entry")


func _read_spray_state(capacity: int) -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(
		_demo.spray._particle_state_rid, 0, capacity * 3 * 16)
	if bytes.is_empty():
		return PackedFloat32Array()
	var image := Image.create_from_data(capacity, 3, false, Image.FORMAT_RGBAF, bytes)
	return image.get_data().to_float32_array()


func _check_runtime_crates_and_equilibrium() -> void:
	_demo.process_mode = Node.PROCESS_MODE_INHERIT
	var physical_enabled: bool = _demo.solver.physical_features_enabled
	_check(physical_enabled, "ocean runtime did not boot with physical features enabled")
	_check(OceanSolver.MAX_QUERY_POINTS >= 33,
		"GPU query buffer cannot fit the camera and eight four-probe crates")
	_check(OceanQualityProfile.SPRAY_CAPACITY[LOW_TIER] == 2048,
		"Low spray pool capacity changed")
	if not physical_enabled or OceanSolver.MAX_QUERY_POINTS < 33:
		return
	for crate_index in 8:
		_demo.throw_crate()
		var crate: OceanBuoy = _demo._crates.back()
		crate.freeze = true
		crate.global_position = Vector3(float(crate_index % 4) * 3.0, 2.0,
			float(crate_index / 4) * 3.0)
	_check(_demo._crates.size() == 8, "runtime did not retain all eight crates")
	for crate in _demo._crates:
		_check(crate.physical_model_enabled and absf(crate.mass - 777.6) < 0.001,
			"runtime crate is not using the 450 kg/m3 physical mass")
		_demo.solver.set_body_pressure(crate.get_instance_id(),
			Vector2(crate.global_position.x, crate.global_position.z), 1000.0)
	_check(_demo.solver._body_pressures.size() == 8,
		"body pressure exchange did not retain all eight active crates")
	await physics_frame
	await RenderingServer.frame_post_draw
	var crate_query_id := -1
	for query_id in _demo._query_snapshots:
		var snapshot: Dictionary = _demo._query_snapshots[query_id]
		if snapshot.crates.size() == 8:
			crate_query_id = int(query_id)
	await RenderingServer.frame_post_draw
	_check(_demo.solver._query_submitted_count == 33,
		"runtime did not submit one camera and 32 crate probes")
	_demo.clear_crates()
	_check(_demo._crates.is_empty() and _demo._water_frames.is_empty()
		and _demo.solver._body_pressures.is_empty(),
		"crate removal retained body pressure or water-frame state")
	_demo.set_quality_profile(OceanQualityProfile.Tier.MEDIUM)
	await _wait_for_runtime_quality(OceanQualityProfile.Tier.MEDIUM)
	var new_generation: int = _demo.solver._query_generation
	_check(new_generation > 0,
		"quality rebuild did not invalidate the prior query generation")
	for _frame in 4:
		await physics_frame
		await RenderingServer.frame_post_draw
	if crate_query_id >= 0:
		_check(not _demo._query_snapshots.has(crate_query_id),
			"removed-crate query snapshot survived quality rebuild")
	for snapshot in _demo._query_snapshots.values():
		_check(snapshot.crates.is_empty(),
			"a post-removal query retained crate callbacks")
	_demo.set_quality_profile(LOW_TIER)
	await _wait_for_runtime_quality(LOW_TIER)
	await _check_flat_water_equilibrium()


func _wait_for_runtime_quality(tier: int) -> void:
	var deadline := Time.get_ticks_msec() + 45000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _demo.solver.initialized \
				and _demo.solver.map_size == OceanQualityProfile.FFT_SIZE[tier]:
			if _demo.texture_bound and _demo.spray._physical_ready \
					and _demo.spray._particle_capacity == OceanQualityProfile.SPRAY_CAPACITY[tier]:
				ready = true
				break
	_check(ready, "ocean quality rebuild did not restore its solver and spray resources")


func _check_flat_water_equilibrium() -> void:
	_demo.apply_preset(0)
	await process_frame
	await RenderingServer.frame_post_draw
	var displacement: RID = _demo.solver.get_displacement_tex_rid()
	var derivatives: RID = _demo.solver.get_derivative_tex_rid()
	var velocity: RID = _demo.solver.velocity_solver.get_texture_rid()
	var foam_a: RID = _demo.solver.get_foam_near_tex_rid(0)
	var foam_b: RID = _demo.solver.get_foam_near_tex_rid(1)
	var coast: RID = _local_solver.get_coast_texture_rid()
	var wake: RID = _local_solver.get_wake_texture_rid()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			_rd.texture_clear(displacement, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(derivatives, Color(0, 0, 0, 0), 0, 1, layer, 1)
			_rd.texture_clear(velocity, Color(0, 0, 0, 0), 0, 1, layer, 1)
		_rd.texture_clear(foam_a, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(foam_b, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(coast, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_rd.texture_clear(wake, Color(0, 0, 0, 0), 0, 1, 0, 1)
		_local_solver.request_reset()
		_local_solver.step_render(0.0, 0.0, Vector2.ZERO, Vector2.ZERO,
			PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var crate := OceanBuoy.new()
	crate.physical_model_enabled = true
	crate.freeze = true
	_demo.add_child(crate)
	crate.global_position = Vector3(0.0,
		OceanBuoy.BOX_SIZE.y * (0.5 - OceanBuoy.BODY_DENSITY_KG_M3
			/ OceanBuoy.WATER_DENSITY_KG_M3), 0.0)
	_demo._crates.append(crate)
	await physics_frame
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline \
			and crate.last_support_force_n.y <= 0.0:
		await physics_frame
		await RenderingServer.frame_post_draw
	var expected_weight := OceanBuoy.BODY_DENSITY_KG_M3 \
		* OceanBuoy.BOX_SIZE.x * OceanBuoy.BOX_SIZE.y * OceanBuoy.BOX_SIZE.z \
		* OceanSolver.GRAVITY
	var support_error := absf(crate.last_support_force_n.y - expected_weight)
	_check(support_error < 1.0,
		"flat calm runtime query did not balance physical crate weight (error %.3f N)"
		% support_error)
	print("OCEAN PHYSICS calm-support=%.3f N weight=%.3f N" % [
		crate.last_support_force_n.y, expected_weight])
	_demo.clear_crates()
	await physics_frame


func _finish_scene(game_manager: Variant) -> void:
	if is_instance_valid(_demo):
		_demo.queue_free()
		await process_frame
	if game_manager != null:
		game_manager.set_setting("ocean_quality_profile", _restore_tier)
