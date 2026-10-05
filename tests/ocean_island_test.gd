extends "res://tests/test_case.gd"

const TextureReadback := preload("res://scripts/core/texture_readback.gd")
var _demo


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
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
	_check(_demo.island != null and is_equal_approx(_demo.solver.water_depth, 4.0),
		"island bathymetry and offshore depth were not initialized")
	_check(_demo.surface_mat.get_shader_parameter("shore_enabled") == true,
		"normal boot did not bind the shoreline surface")
	_check(_demo.solver.shore_bathymetry.size() == 128 * 128,
		"Low shoreline bathymetry has the wrong resolution")
	_demo.set_frozen(true)
	_demo.set_process(false)
	_demo.set_physics_process(false)
	_demo.apply_preset(0)
	for frame in 60:
		RenderingServer.call_on_render_thread(_demo.solver.step_render.bind(
			1.0 / 30.0, float(frame + 1) / 30.0, Vector2(0.0, 30.0)))
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
	var points := PackedVector2Array([Vector2(-3.5, -3.0), Vector2(0.0, 38.0)])
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
		var expected := _bilinear(surface, 128, points[1])
		_check(absf(expected.x - batch.results[1].x) < 0.0001,
			"query height differs from the rendered shoreline field")
	await _check_transition_composition()
	_demo.set_capture_foam(false)
	_check(_demo.surface_mat.get_shader_parameter("foam_feedback_enabled") == false
		and _demo.island.terrain_material.get_shader_parameter("foam_amount") == 0.0,
		"Foam off did not hide both water and deposited sand foam")
	var wind: float = _demo.solver.wind_speed
	var look: int = _demo.current_look_index
	_demo.set_process(true)
	_demo.set_scene_mode(0, false)
	await _wait_ready()
	_check(not _demo.solver.shore_enabled and _demo.island == null
		and is_equal_approx(_demo.solver.water_depth, 80.0),
		"return to Open Ocean did not release the island and restore depth")
	_check(_demo.solver.wind_speed == wind and _demo.current_look_index == look
		and _demo.quality.effective == 0, "scene switch changed sea/look/quality settings")
	_demo.set_scene_mode(1, false)
	await _wait_ready()
	_check(_demo.solver.shore_enabled and _demo.texture_bound,
		"second Island Beach initialization failed")
	print("OCEAN ISLAND boot=restored dry_cells=%d calm_foam_max=%.7f query_parity=checked lifecycle=roundtrip" % [dry_count, max_foam])
	_demo.queue_free()
	await process_frame
	await RenderingServer.frame_post_draw
	manager.set_setting("ocean_quality_profile", old_tier)
	manager.set_setting("ocean_scene_mode", old_scene)
	_finish("ocean_island")


func _wait_ready() -> void:
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _demo.solver.initialized and _demo.texture_bound:
			return
	_check(false, "island scene initialization timed out")


func _check_transition_composition() -> void:
	var rd := RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(func():
		for layer in 3:
			rd.texture_clear(_demo.solver.get_displacement_tex_rid(),
				Color(1.2, 0.4, -0.3, 0.0) if layer == 0 else Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.get_derivative_tex_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
			rd.texture_clear(_demo.solver.velocity_solver.get_texture_rid(), Color(0, 0, 0, 0), 0, 1, layer, 1)
		rd.texture_clear(_demo.solver.get_shore_texture_rid(), Color(0.6, 0.0, 0.0, 4.0), 0, 1, 0, 1)
		rd.texture_clear(_demo.solver.get_shore_derivative_texture_rid(), Color(0.0, 0.0, 0.0, -4.0), 0, 1, 0, 1)
	)
	await RenderingServer.frame_post_draw
	var point := Vector2(74.6, -0.15)
	var id: int = _demo.solver.submit_queries(PackedVector2Array([point]))
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
	_check(result.w > 0.5 and absf(result.x - 0.5) < 0.0001,
		"shore transition doubled wave amplitude or inverted untapered displacement")
	_check(absf(result.y + 0.025 / 1.15) < 0.0001 and absf(result.z) < 0.0001,
		"shore transition omitted the blend/Jacobian gradient")
	print("OCEAN ISLAND transition height=%.7f slope=(%.7f,%.7f)" % [result.x, result.y, result.z])


func _read(texture: RID, size: int) -> PackedFloat32Array:
	var bytes: PackedByteArray = await TextureReadback.new().read_layer(texture, 0, size * size * 16)
	_check(bytes.size() == size * size * 16, "incomplete shoreline readback")
	return bytes.to_float32_array()


func _bilinear(values: PackedFloat32Array, size: int, point: Vector2) -> Vector4:
	var grid := (point / 160.0 + Vector2.ONE * 0.5) * size - Vector2.ONE * 0.5
	var base := Vector2i(floor(grid.x), floor(grid.y))
	var fraction := grid - Vector2(base)
	var taps: Array[Vector4] = []
	for offset in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1), Vector2i.ONE]:
		var index: int = ((base.y + offset.y) * size + base.x + offset.x) * 4
		taps.append(Vector4(values[index], values[index + 1], values[index + 2], values[index + 3]))
	return taps[0].lerp(taps[1], fraction.x).lerp(taps[2].lerp(taps[3], fraction.x), fraction.y)
