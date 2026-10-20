extends "res://tests/test_case.gd"

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
const Island := preload("res://scripts/demos/ocean/ocean_island.gd")
const STEPS_PER_FRAME := 8
var _demo


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_rock_sampling()
	var manager := root.get_node("GameManager")
	var old_tier: int = manager.get_setting("ocean_quality_profile", 2)
	var old_scene: int = manager.get_setting("ocean_scene_mode", 0)
	manager.set_setting("ocean_quality_profile", 0)
	manager.set_setting("ocean_scene_mode", 1)
	_demo = load("res://scenes/ocean_demo.tscn").instantiate()
	root.add_child(_demo)
	await _wait_ready()
	if not _demo.solver.initialized:
		_demo.queue_free()
		await process_frame
		manager.set_setting("ocean_quality_profile", old_tier)
		manager.set_setting("ocean_scene_mode", old_scene)
		_finish("ocean_island")
		return
	_check(_demo.current_scene_index == 1 and _demo.solver.shore_enabled,
		"restored scene did not enter Island Beach through runtime boot")
	_check(_demo.solver.shore_solver.config.foam_retention_s <= 2.0
		and _demo.solver.shore_solver.config.contact_retention_s <= 3.0,
		"normal boot did not enable short reflux traces")
	_check(_demo.island != null and is_equal_approx(_demo.solver.water_depth, 80.0),
		"island bathymetry was not initialized and the offshore spectrum depth moved")
	_check(_demo.surface_mat.get_shader_parameter("shore_enabled") == true,
		"normal boot did not bind the shoreline surface")
	_check(_demo.island.terrain_material.get_shader_parameter("shore_contact") == _demo.shore_contact_texture
		and _demo.island.terrain_material.get_shader_parameter("shore_breaker") == _demo.shore_breaker_texture
		and _demo.solver.shore_solver._displacement_rid == _demo.solver.get_displacement_tex_rid()
		and _demo.solver.shore_solver._velocity_rid == _demo.solver.velocity_solver.get_texture_rid(),
		"normal boot did not share the offshore carrier with the island water and terrain")
	_check(_demo.island.terrain_material.get_shader_parameter("cloud_reflection")
		== _demo.surface_mat.get_shader_parameter("cloud_reflection")
		and _demo.island.terrain_material.get_shader_parameter("sky_zenith")
		== _demo.surface_mat.get_shader_parameter("sky_zenith")
		and _demo.island.terrain_material.get_shader_parameter("sky_energy")
		== _demo.sky_material.get_shader_parameter("energy"),
		"normal boot did not share the visible ocean sky with the wet-sand film")
	_check(_demo.solver.shore_bathymetry.size() == 128 * 128,
		"Low shoreline bathymetry has the wrong resolution")
	_demo.set_frozen(true)
	_demo.set_process(false)
	_demo.set_physics_process(false)
	_demo.apply_preset(0)
	for frame in 60:
		RenderingServer.call_on_render_thread(_demo.solver.step_render.bind(
			1.0 / 30.0, float(frame + 1) / 30.0, Vector2(0.0, 30.0)))
		# Steps carry their own dt, so several share one rendered frame.
		if frame % STEPS_PER_FRAME == STEPS_PER_FRAME - 1 or frame == 59:
			await RenderingServer.frame_post_draw
	var surface := await _read(_demo.solver.get_shore_texture_rid(), 128)
	var foam := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var max_foam := 0.0
	var dry_count := 0
	for index in range(0, surface.size(), 4):
		_check(is_finite(surface[index]) and is_finite(surface[index + 3])
			and surface[index + 3] >= 0.0, "non-finite or negative shoreline depth")
		if surface[index + 3] <= 0.002:
			dry_count += 1
		max_foam = maxf(max_foam, maxf(foam[index], foam[index + 1]))
	_check(dry_count > 300, "island contains no dry rock/sand cells")
	_check(max_foam < 0.02, "Calm sea spontaneously produced shoreline foam")
	var points := PackedVector2Array([Vector2(-3.5, -3.0), Vector2(0.0, 30.0)])
	var id: int = _demo.solver.submit_queries(points)
	RenderingServer.call_on_render_thread(_demo.solver.query_render)
	var batch: OceanQueryBatch
	for frame in 120:
		await process_frame
		batch = _demo.solver.take_query_batch()
		if batch != null and batch.id == id:
			break
	_check(batch != null and batch.id == id, "island query batch was not returned")
	if batch != null:
		_check(batch.results[0].w == 0.0, "rock footprint was reported as wet water")
		_check(batch.results[1].w > 0.5, "offshore beach query was reported dry")
	await _check_fft_carrier()
	await _check_sand_history()
	await _check_transition_composition()
	_demo.set_capture_foam(false)
	_check(_demo.surface_mat.get_shader_parameter("foam_feedback_enabled") == false
		and _demo.island.terrain_material.get_shader_parameter("foam_amount") == 0.0
		and _demo.island.rock_wet_material.get_shader_parameter("foam_amount") == 0.0,
		"Foam off did not hide water, sand deposits and rock residue")
	var wind: float = _demo.solver.wind_speed
	var look: int = _demo.current_look_index
	_demo.set_process(true)
	_demo.set_scene_mode(0, false)
	await _wait_ready()
	_check(not _demo.solver.shore_enabled and _demo.island == null
		and is_equal_approx(_demo.solver.water_depth, 80.0),
		"return to Open Ocean did not release the island and restore depth")
	var rock_position: Vector3 = _demo.get_node("Rocks/NearRock").global_position
	_check(Vector2(rock_position.x, rock_position.z).is_equal_approx(OceanLocalSolver.COAST_CENTER)
		and rock_position.distance_to(_demo.main_camera.global_position) < 40.0,
		"Open Ocean rock and its coastal field are not near the default spawn")
	_check(_demo.solver.wind_speed == wind and _demo.current_look_index == look
		and _demo.quality.effective == 0, "scene switch changed sea/look/quality settings")
	_demo.set_scene_mode(1, false)
	await _wait_ready()
	_check(_demo.solver.shore_enabled and _demo.texture_bound,
		"second Island Beach initialization failed")
	print("OCEAN ISLAND boot=restored dry_cells=%d calm_foam_max=%.7f visible_queries=checked lifecycle=roundtrip" % [dry_count, max_foam])
	_demo.queue_free()
	await process_frame
	await RenderingServer.frame_post_draw
	manager.set_setting("ocean_quality_profile", old_tier)
	manager.set_setting("ocean_scene_mode", old_scene)
	_finish("ocean_island")


func _check_rock_sampling() -> void:
	var island := Island.new()
	_check(absf(island._terrain_height(Vector2.ZERO) - 2.45) < 0.01
		and is_equal_approx(island._center_elevation(Vector2(35.0, 0.0)), 0.0)
		and is_equal_approx(island._terrain_height(Vector2(90.0, 0.0)), -OceanShoreSolver.RING_DEPTH_M),
		"island elevation changed the beach/boundary or did not raise only the center")
	island._rock_heights.resize(Island.TERRAIN_SIZE * Island.TERRAIN_SIZE)
	island._rock_heights.fill(-1000.0)
	var x := Island.TERRAIN_SIZE / 2
	var z := Island.TERRAIN_SIZE / 2
	island._rock_heights[z * Island.TERRAIN_SIZE + x] = 4.0
	var grid_step := Island.TERRAIN_DOMAIN_M / float(Island.TERRAIN_SIZE - 1)
	var rock_point := Vector2(float(x), float(z)) * grid_step \
		- Vector2.ONE * Island.TERRAIN_DOMAIN_M * 0.5
	_check(is_equal_approx(island._sample_rock_height(rock_point + Vector2(0.2, 0.0)), 4.0),
		"sentinel samples diluted a nearby valid rock height")
	_check(is_equal_approx(island._sample_rock_height(rock_point, 0.5), 4.0),
		"coast-cell rock footprint missed a rasterized rock height")
	_check(island._sample_rock_height(rock_point + Vector2(0.76, 0.0), 0.5) == -1000.0,
		"coast-cell rock footprint widened beyond its local footprint")
	island._built = true
	island.position = Vector3(12.0, 2.0, -4.0)
	var translated := island.create_bathymetry(32, 32.0)
	_check(is_equal_approx(translated[12 * 32 + 27], 6.0),
		"translated island bathymetry did not preserve the rock footprint and elevation")
	island.free()


func _wait_ready() -> void:
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _demo.solver.initialized and _demo.texture_bound:
			return
	_check(false, "island scene initialization timed out")


func _check_fft_carrier() -> void:
	var rd := RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			rd.texture_clear(_demo.solver.get_displacement_tex_rid(),
				Color(1.2, 4.0, -0.3, 0.0) if layer == 0 else Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.get_derivative_tex_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
		_demo.solver.shore_solver.step_render(0.0, 2.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(
		_demo.solver.get_shore_breaker_texture_rid(), 0, 128 * 128 * 8)
	_check(bytes.size() == 128 * 128 * 8, "FFT carrier readback failed")
	if bytes.size() != 128 * 128 * 8:
		return
	var maximum_error := 0.0
	for offset in range(0, bytes.size(), 8):
		maximum_error = maxf(maximum_error, absf(bytes.decode_half(offset + 2) - 4.0))
		_check(bytes.decode_half(offset + 2) >= 3.99 and bytes.decode_half(offset + 2) <= 4.01,
			"coastal water replaced the offshore crest with its independent water level")
	_check(maximum_error < 0.01, "coastal carrier lost the FFT height")
	var id: int = _demo.solver.submit_queries(PackedVector2Array([Vector2(0.0, 18.0)]))
	RenderingServer.call_on_render_thread(_demo.solver.query_render)
	var batch: OceanQueryBatch
	for frame in 120:
		await process_frame
		batch = _demo.solver.take_query_batch()
		if batch != null and batch.id == id:
			break
	_check(batch != null and batch.id == id, "visible FFT query was not returned")
	if batch != null:
		_check(batch.results[0].w > 0.5 and absf(batch.results[0].x - 4.0) < 0.0001,
			"camera/buoyancy queries used the independent coastal water level")
	print("OCEAN ISLAND FFT-carrier height=4.000 maximum-error=%.7f" % maximum_error)


func _set_visual_fields(height: float, strain: float) -> void:
	var rd := RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			rd.texture_clear(_demo.solver.get_displacement_tex_rid(),
				Color(0.0, height, 0.0, 0.0) if layer == 0 else Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.get_derivative_tex_rid(),
				Color(strain, strain, 0.0, 0.0) if layer == 0 else Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.velocity_solver.get_texture_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
	)
	await RenderingServer.frame_post_draw


func _check_sand_history() -> void:
	var shore: OceanShoreSolver = _demo.solver.shore_solver
	var threshold := shore.whitecap_threshold
	shore.whitecap_threshold = 0.8
	await _set_visual_fields(3.0, 0.0)
	RenderingServer.call_on_render_thread(shore.reset)
	for frame in 30:
		RenderingServer.call_on_render_thread(shore.step_render.bind(
			1.0 / 30.0, float(frame + 1) / 30.0, Vector2(0.5, 0.0), 8.0, 0.5, PackedVector4Array()))
		if frame % STEPS_PER_FRAME == STEPS_PER_FRAME - 1 or frame == 29:
			await RenderingServer.frame_post_draw
	var static_foam := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var maximum := 0.0
	for offset in range(0, static_foam.size(), 4):
		maximum = maxf(maximum, maxf(static_foam[offset], static_foam[offset + 1]))
	_check(maximum < 0.00001, "a flat FFT surface generated a separate shoreline foam ring")
	await _set_visual_fields(3.0, -0.45)
	for frame in 60:
		RenderingServer.call_on_render_thread(shore.step_render.bind(
			1.0 / 30.0, 1.0 + float(frame + 1) / 30.0, Vector2.ZERO, 8.0, 0.5, PackedVector4Array()))
		if frame % STEPS_PER_FRAME == STEPS_PER_FRAME - 1 or frame == 59:
			await RenderingServer.frame_post_draw
	var index := (int((18.0 / 160.0 + 0.5) * 128.0) * 128 + 64) * 4
	var incoming := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	_check(incoming[index] > 0.01 and incoming[index + 3] > 0.99,
		"the visible incoming water did not foam and wet the sand")
	var terrain := await _read(_demo.solver.get_shore_derivative_texture_rid(), 128)
	await _set_visual_fields(2.85, 0.0)
	RenderingServer.call_on_render_thread(shore.step_render.bind(
		1.0 / 30.0, 3.0 + 1.0 / 30.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array()))
	await RenderingServer.frame_post_draw
	var rock_retreat := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var steep_deposit := 0.0
	var flat_deposit := 0.0
	for z in range(1, 127):
		for x in range(1, 127):
			var offset := (z * 128 + x) * 4
			if terrain[offset + 3] >= 2.0:
				continue
			var gradient := Vector2(terrain[offset + 7] - terrain[offset - 1],
				terrain[offset + 128 * 4 + 3] - terrain[offset - 128 * 4 + 3]) / 2.5
			if gradient.length() > 0.8:
				steep_deposit = maxf(steep_deposit, rock_retreat[offset + 2])
			elif gradient.length() < 0.05:
				flat_deposit = maxf(flat_deposit, rock_retreat[offset + 2])
	_check(steep_deposit > 0.01 and flat_deposit < 0.00001,
		"reflux did not retain foam at steep rock contacts or deposited it in flat deep water")
	print("OCEAN ISLAND rock-reflux steep=%.6f flat=%.6f" % [steep_deposit, flat_deposit])
	var thin_incoming := incoming
	for frame in 33:
		await _set_visual_fields(terrain[index + 3] + 0.1 - float(frame) * 0.005, 0.0)
		RenderingServer.call_on_render_thread(shore.step_render.bind(
			1.0 / 30.0, 3.0 + float(frame + 1) / 30.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array()))
		await RenderingServer.frame_post_draw
		if frame == 10:
			thin_incoming = await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var retreat := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	_check(retreat[index] < 0.00001
		and retreat[index + 2] > 0.05 * maxf(thin_incoming[index], thin_incoming[index + 1])
		and retreat[index + 3] > 0.7,
		"gradually receding water erased the foam before stranding it on wet sand")
	RenderingServer.call_on_render_thread(func():
		shore.reset(false)
		shore.step_render(0.0, 3.0 + 1.0 / 30.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var preserved := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var preserve_error := 0.0
	for offset in retreat.size():
		preserve_error = maxf(preserve_error, absf(retreat[offset] - preserved[offset]))
	_check(preserve_error < 0.000001, "changing the sea state erased the wet sand and foam deposits")
	RenderingServer.call_on_render_thread(shore.step_render.bind(
		0.0, 3.0 + 1.0 / 30.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array()))
	await RenderingServer.frame_post_draw
	var frozen := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var freeze_error := 0.0
	for offset in retreat.size():
		freeze_error = maxf(freeze_error, absf(retreat[offset] - frozen[offset]))
	_check(freeze_error < 0.000001, "zero elapsed time advanced sand drying or stranded foam")
	var deposit_3s := 0.0
	var deposit_6s := 0.0
	for frame in 60:
		RenderingServer.call_on_render_thread(shore.step_render.bind(
			1.0 / 6.0, 3.0 + 1.0 / 30.0 + float(frame + 1) / 6.0,
			Vector2.ZERO, 0.0, 0.5, PackedVector4Array()))
		if frame % STEPS_PER_FRAME == STEPS_PER_FRAME - 1 or frame == 17 or frame == 35 or frame == 59:
			await RenderingServer.frame_post_draw
		if frame == 17 or frame == 35:
			var residue := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
			var ratio := residue[index + 2] / retreat[index + 2]
			if frame == 17:
				deposit_3s = ratio
				_check(ratio > 0.05 and ratio < 0.2,
					"stranded foam disappeared instantly or stayed too strong after three seconds")
			else:
				deposit_6s = ratio
				_check(ratio < 0.025 and residue[index + 3] < 0.15,
					"foam and sand wetness did not fade within a few seconds")
	var dried := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	_check(absf(dried[index + 3] / retreat[index + 3] - exp(-10.0 / shore.SAND_DRYING_S)) < 0.005,
		"exposed sand did not gradually dry after the visible wave passed")
	_check(dried[index + 2] < retreat[index + 2] * 0.002,
		"stranded foam remained visible ten seconds after reflux")
	var contact_bytes: PackedByteArray = await TextureReadback.new().read_layer(
		_demo.solver.get_shore_contact_texture_rid(), 0, 128 * 128 * 8)
	_check(contact_bytes.size() == 128 * 128 * 8, "sand-film contact readback was incomplete")
	if contact_bytes.size() == 128 * 128 * 8:
		var recent_water := contact_bytes.decode_half(index * 2 + 2)
		_check(recent_water < 0.05 and recent_water < dried[index + 3],
			"the reflective surface film lasted as long as the damp sand")
		print("OCEAN ISLAND film recent-water=%.6f damp-sand=%.6f" % [recent_water, dried[index + 3]])
	RenderingServer.call_on_render_thread(func():
		shore.reset()
		shore.step_render(0.0, 0.0, Vector2.ZERO, 0.0, 0.5, PackedVector4Array())
	)
	await RenderingServer.frame_post_draw
	var cleared := await _read(_demo.solver.get_shore_foam_texture_rid(), 128)
	var reset_maximum := 0.0
	for value in cleared:
		reset_maximum = maxf(reset_maximum, absf(value))
	_check(reset_maximum < 0.000001, "shore reset retained old sand wetness or foam deposits")
	print("OCEAN ISLAND swash static-foam=%.7f stranded=%.6f wet=%.6f dried=%.6f preserve=%.8f zero-dt=%.8f reset=%.8f" % [
		maximum, retreat[index + 2], retreat[index + 3], dried[index + 3], preserve_error, freeze_error, reset_maximum])
	print("OCEAN ISLAND residue remaining-3s=%.6f remaining-6s=%.6f" % [deposit_3s, deposit_6s])
	shore.whitecap_threshold = threshold


func _check_transition_composition() -> void:
	var rd := RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			rd.texture_clear(_demo.solver.get_displacement_tex_rid(),
				Color(1.2, 0.4, -0.3, 0.0) if layer == 0 else Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.get_derivative_tex_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.velocity_solver.get_texture_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
		rd.texture_clear(_demo.solver.get_shore_texture_rid(), Color(0.6, 0.0, 0.0, 2.0), 0, 1, 0, 1)
		rd.texture_clear(_demo.solver.get_shore_derivative_texture_rid(), Color(0.0, 0.0, 0.0, -4.0), 0, 1, 0, 1)
	)
	await RenderingServer.frame_post_draw
	var width: float = _demo.solver.shore_solver.config.surface_blend_width_m()
	var radius: float = _demo.solver.shore_solver.config.domain_m * 0.5 - width * 0.5
	var point := Vector2(radius + 1.2, -0.3)
	var direction := Vector2.ONE.normalized()
	var oblique := direction * radius + Vector2(1.2, -0.3)
	var id: int = _demo.solver.submit_queries(PackedVector2Array([point, oblique]))
	RenderingServer.call_on_render_thread(_demo.solver.query_render)
	var batch: OceanQueryBatch
	for frame in 120:
		await process_frame
		batch = _demo.solver.take_query_batch()
		if batch != null and batch.id == id:
			break
	_check(batch != null and batch.id == id, "shore transition query was not returned")
	if batch == null:
		return
	var result := batch.results[0]
	_check(result.w > 0.5 and absf(result.x - 0.4) < 0.0001,
		"shore transition doubled wave amplitude or inverted untapered displacement")
	_check(Vector2(result.y, result.z).length() < 0.0001,
		"the independent coastal level changed the visible FFT surface normal")
	print("OCEAN ISLAND transition height=%.7f slope=(%.7f,%.7f)" % [result.x, result.y, result.z])
	var radial := batch.results[1]
	_check(absf(radial.x - 0.4) < 0.0001 and Vector2(radial.y, radial.z).length() < 0.0001,
		"the oblique coastal transition changed the visible FFT surface")
	print("OCEAN ISLAND radial height=%.7f slope=(%.7f,%.7f)" % [radial.x, radial.y, radial.z])
	for depth in [5.0, 8.0]:
		RenderingServer.call_on_render_thread(func():
			rd.texture_clear(_demo.solver.get_shore_texture_rid(), Color(0.6, 0.0, 0.0, depth + 0.6), 0, 1, 0, 1)
		)
		await RenderingServer.frame_post_draw
		id = _demo.solver.submit_queries(PackedVector2Array([Vector2(0.0, 25.0)]))
		RenderingServer.call_on_render_thread(_demo.solver.query_render)
		batch = null
		for frame in 120:
			await process_frame
			batch = _demo.solver.take_query_batch()
			if batch != null and batch.id == id:
				break
		_check(batch != null and batch.id == id, "bathymetric transition query was not returned")
		if batch != null:
			var expected_height := 0.4
			_check(batch.results[0].w > 0.5 and absf(batch.results[0].x - expected_height) < 0.0001
				and Vector2(batch.results[0].y, batch.results[0].z).length() < 0.0001,
				"bathymetric transition changed height or introduced a radial seam in deep water")


func _read(texture: RID, size: int) -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(texture, 0, size * size * 16)
	_check(bytes.size() == size * size * 16, "incomplete shoreline readback")
	return bytes.to_float32_array()
