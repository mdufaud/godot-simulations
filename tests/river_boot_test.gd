extends "res://tests/test_case.gd"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	_check_reflection_crop()
	var initial_msaa := root.msaa_3d
	var initial_taa := root.use_taa
	var initial_render_scale := root.scaling_3d_scale
	await process_frame
	var manager := root.get_node("GameManager")
	manager.call("set_setting", "river_quality_profile", 1)
	await manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	var demo := current_scene as Node3D
	_check(demo.preset_index == 1, "Player boot must select Natural Flow")
	_check(is_equal_approx(demo.config.water_level_m, 0.06), "Player boot must apply the natural water level")
	_check(demo.river.water_material.get_shader_parameter("flow_map") != null, "Player boot must bind the flow map")
	var reference_flow: Color = demo.river.field.sample_solver(Vector2.ZERO, demo.config.water_level_m)
	_check(demo.river.water_material.get_shader_parameter("foam_reference_flow") == Vector2(reference_flow.r, reference_flow.g),
		"Player boot must bind the reference current for continuous foam transport")
	_check(demo.river.water_material.get_shader_parameter("bed_height_texture") != null, "Player boot must bind the riverbed depth fallback")
	_check(demo.river.water_material.get_shader_parameter("reflection_texture") != null, "Player boot must bind the planar reflection")
	_check(demo.river.water_material.get_shader_parameter("foam_detail") == true
		and demo.river.water_material.get_shader_parameter("surface_detail") == 0.0,
		"Normal Medium boot must enable detailed foam independently of Ultra surface effects")
	var actions: GridContainer = demo.menu.get_node("BottomRight/ActionBar")
	var action: Button = demo._menu_builder.preset_action
	_check(actions.get_child_count() == 4 and action.get_parent() == actions
		and demo._menu_builder.flow_action.get_parent() == actions
		and demo._menu_builder.crate_action.get_parent() == actions
		and demo._menu_builder.scene_action.get_parent() == actions,
		"River presets, flow, crates and scene switching must use native actions")
	_check(demo.river.swe.enabled and demo.river.swe.available == GpuPreflight.available(),
		"Player boot must request the live SWE system with an explicit GPU availability check")
	_check((demo._menu_builder.flow_action.find_child("ActionCaption", true, false) as Label).text
		== ("SWE" if demo.river.swe.active else "Guided flow"), "Flow action must identify the active system")
	demo.river.swe.set_enabled(false)
	demo.apply_preset(2)
	_check(not demo.river.swe.enabled, "Water presets must preserve guided flow selection")
	demo.river.swe.set_enabled(true)
	demo.apply_preset(1)
	var solver_enabled: bool = demo.river.swe.enabled
	demo.river.swe.set_enabled(false)
	var generation: int = demo.river.query_generation
	_check(demo.river.submit_body_queries(PackedVector3Array([Vector3(0.0, 0.1, 0.0)])),
		"River scene switch test must queue a CPU body-query batch")
	demo._menu_builder.scene_action.pressed.emit()
	_check(demo.scene_index == 1 and demo.river.field.waterfall.angle_degrees == 50.0
		and demo.river.waterfall != null,
		"Scene selector must install the 50-degree waterfall through the player controller")
	_check(demo.river.query_generation > generation and demo.river.take_query_batch().is_empty(),
		"Changing river scenes must cancel a pending body-query batch")
	var scene_key := InputEventKey.new()
	scene_key.physical_keycode = KEY_4
	scene_key.pressed = true
	demo.menu._unhandled_input(scene_key)
	_check(demo.scene_index == 2 and demo.river.field.waterfall.angle_degrees == 90.0
		and actions.get_child_count() == 4 and demo._menu_builder.scene_option.selected == 2,
		"Scene selector must install the vertical waterfall and retain the native action bar")
	var height: float = demo.config.water_level_m + 6.0
	var age := sqrt(2.0 * (height - 3.0) / 9.81)
	_check(demo.river.submit_body_queries(PackedVector3Array([Vector3(0.0, height, 8.0),
		Vector3(0.0, demo.config.water_level_m, -4.0), Vector3(0.0, 3.0, 4.0 - demo.config.speed_m_s * age),
		Vector3(0.0, 9.0, -4.0)])), "Guided waterfall must accept pool, curtain and air queries")
	var contacts: Dictionary = demo.river.take_query_batch()
	_check(contacts.values[7] == 1.0 and contacts.values[19] == 1.0 and contacts.values[31] == 3.0
		and contacts.values[43] == 0.0,
		"Guided waterfall must distinguish both pools, the detached sheet and dry air")
	demo._menu_builder.angle_slider.value = 67.5
	_check(is_equal_approx(demo.river.field.waterfall.angle_degrees, 67.5)
		and demo.river.waterfall.material.get_shader_parameter("free_fall") == false
		and demo._menu_builder.angle_slider.editable,
		"Runtime angle control must rebuild terrain, solver and material for an intermediate incline")
	demo._menu_builder.angle_slider.value = 90.0
	_check(demo.river.waterfall.material.get_shader_parameter("free_fall") == true,
		"Runtime angle control must restore ballistic transport at the vertical endpoint")
	demo._menu_builder.scene_action.pressed.emit()
	_check(demo.scene_index == 0 and demo.river.field is RiverLandscape
		and demo.river.waterfall == null and actions.get_child_count() == 4 and not demo._menu_builder.angle_slider.editable,
		"Scene action must cycle back to the river and retain all native actions")
	demo.river.swe.set_enabled(solver_enabled)
	_check(demo.menu.get_node_or_null("RiverPresets") == null, "Custom bottom-left preset bar must be removed")
	_check(action.is_visible_in_tree(), "Native River action must stay visible with settings closed")
	for index: int in [2, 3, 0, 1]:
		action.pressed.emit()
		_check(demo.preset_index == index, "River action must cycle all four runtime presets")
		_check(is_equal_approx(float(demo.river.water_material.get_shader_parameter("water_level_m")), demo.config.water_level_m),
			"Preset level must reach the runtime shader")
		_check(demo._menu_builder.preset_option.selected == index, "Preset UI must follow runtime state")
		_check(bool(demo.river.water_material.get_shader_parameter("reflection_enabled")) == (index != 2),
			"Rapids must skip the reflection pass while the other presets retain it")
		_check((action.find_child("ActionCaption", true, false) as Label).text == demo.config.display_name,
			"Action caption must identify the current river preset")
		for material: ShaderMaterial in demo._scenery.materials:
			var plane: Vector4 = material.get_shader_parameter("river_plane")
			_check(is_equal_approx(plane.w, -demo.config.water_level_m), "Wet margins and reflection clipping must follow the preset")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_1
	key.pressed = true
	demo.menu._unhandled_input(key)
	_check(demo.preset_index == 2, "Key 1 must activate the native River action")
	demo.apply_preset(1)
	_check(demo.quality.requested == 1 and demo._menu_builder.quality_option.selected == 1,
		"First launch must use the shared Medium quality default")
	demo.set_render_scale(0.8)
	for tier in 4:
		var option: OptionButton = demo._menu_builder.quality_option
		option.select(tier)
		option.item_selected.emit(tier)
		var values: Dictionary = RiverQualityProfile.values(tier)
		_check(demo.quality.effective == tier and manager.call("get_setting", "river_quality_profile") == tier,
			"Quality option must apply and persist the requested tier")
		_check(is_equal_approx(root.scaling_3d_scale, 0.8), "Quality tiers must preserve the manual render scale")
		_check(root.msaa_3d == values.msaa, "Quality tier must apply antialiasing")
		_check(demo.river._foam_views[0].size == values.foam_size_px and demo.river._foam_views[1].size == values.foam_size_px,
			"Quality tier must resize both foam textures")
		_check(demo.river.water_material.get_shader_parameter("foam_detail") == (tier > 0),
			"Medium and above must use textured foam while Low retains the simple pattern")
		_check(demo.river._surface_mesh.subdivide_width == ceili(RiverLandscape.DOMAIN_M.x / values.water_cell_size_m) - 1,
			"Quality tier must change the water mesh resolution")
		_check(is_equal_approx(demo.river.reflection_scale, values.reflection_scale), "Quality tier must set reflection resolution")
		_check(demo.river._reflections.views.size() == values.reflection_planes,
			"Ultra must render a separate reflection for each water terrace")
		_check(is_equal_approx(float(demo.river.water_material.get_shader_parameter("surface_detail")), values.surface_detail),
			"Quality tier must enable the detailed water and foam shader")
		_check(is_equal_approx(float(demo._scenery.materials[0].get_shader_parameter("water_detail")), values.surface_detail),
			"Quality tier must enable the underwater caustics through the runtime scenery")
		_check(not root.use_taa, "River quality must preserve moving foam without temporal history")
		if tier == 3:
			for slot in range(1, 4):
				_check(demo.river.water_material.get_shader_parameter("reflection_texture_%d" % slot) != null,
					"Ultra must bind every terrace reflection texture")
		for tile: MultiMeshInstance3D in demo._scenery._grass_tiles:
			_check(tile.multimesh.visible_instance_count == roundi(tile.multimesh.instance_count * values.grass_density),
				"Quality tier must change the drawn grass count")
		demo.apply_preset(2)
		_check(bool(demo.river.water_material.get_shader_parameter("reflection_enabled")) == values.rapids_reflection,
			"High and Ultra must enable the Rapids reflection pass")
	_check(demo.quality.requested == 3, "Water preset changes must retain the quality choice")
	demo.menu.settings_reset.emit()
	_check(demo.quality.requested == 1 and demo._menu_builder.quality_option.selected == 1,
		"Factory reset must restore the shared Medium quality")
	demo.set_quality_profile(0)
	manager.call("go_to_menu")
	await process_frame
	await process_frame
	await manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	demo = current_scene as Node3D
	_check(demo.quality.requested == 0 and demo._menu_builder.quality_option.selected == 0
		and demo.river.reflection_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Player re-entry must restore Low quality before rendering and building controls")
	_check((demo._menu_builder.flow_action.find_child("ActionCaption", true, false) as Label).text
		== ("SWE" if demo.river.swe.active else "Guided flow"),
		"Low quality must identify the active solver while retaining the SWE selection")
	demo.set_quality_profile(1)
	var original := load("res://resources/river/presets/natural_flow.tres") as RiverConfig
	demo.apply_preset(1)
	demo.set_speed(2.0)
	_check(is_equal_approx(original.speed_m_s, 0.85), "Editing runtime config must not mutate a shared preset")
	demo.set_foam(0.0)
	_check(is_zero_approx(float(demo.river.water_material.get_shader_parameter("foam_amount"))),
		"Foam control must disable both transported foam and whitewater")
	demo.set_grass_enabled(false)
	for tile: MultiMeshInstance3D in demo._scenery._grass_tiles:
		_check(not tile.visible and tile.layers == 4, "Grass control must hide geometry excluded from reflection")
	demo.set_grass_enabled(true)
	demo.set_frozen(true)
	var time_s: float = demo.river.simulation_time_s
	await process_frame
	await process_frame
	_check(is_equal_approx(time_s, demo.river.simulation_time_s)
		and is_equal_approx(float(demo.river.water_material.get_shader_parameter("simulation_time_s")), time_s),
		"Pause must freeze the physical and rendered foam clocks")
	demo.reset_river()
	_check(not demo.river.frozen and is_equal_approx(demo.config.speed_m_s, 0.85), "Reset must restore the current preset and resume")
	var fps_limit := Engine.max_fps
	demo.set_capture_profiling(true)
	demo.set_capture_profiling(true)
	demo.set_capture_profiling(false)
	_check(Engine.max_fps == fps_limit, "Profiling must restore the frame cap and be idempotent")
	demo.set_quality_profile(3)
	demo.river.stop()
	demo.river.stop()
	_check(demo.river.get_child_count() == 0, "Stop must release owned viewports and be idempotent")
	_check(demo.river.field.bed_texture == null, "Stop must release the baked riverbed texture")
	demo.river.start()
	_check(demo.river.water_material != null and demo.river.is_processing(), "Start after stop must restore rendering")
	manager.call("go_to_menu")
	await process_frame
	await process_frame
	_check(current_scene != null and current_scene.scene_file_path == "res://scenes/main_menu.tscn",
		"Back must load the actual main menu")
	_check(not is_instance_valid(demo), "Back must release the river scene")
	_check(root.msaa_3d == initial_msaa and root.use_taa == initial_taa
		and is_equal_approx(root.scaling_3d_scale, initial_render_scale),
		"Leaving Ultra must restore the original root viewport antialiasing and scale")
	await manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	demo = current_scene as Node3D
	_check(demo.quality.requested == 3 and demo.quality.effective == 3
		and demo.river._reflections.views.size() == 4,
		"Normal Ultra boot must restore every terrace reflection without capture setup")
	_check(demo.preset_index == 1 and not root.use_taa
		and is_equal_approx(float(demo.river.water_material.get_shader_parameter("surface_detail")), 1.0)
		and is_equal_approx(float(demo._scenery.materials[0].get_shader_parameter("water_detail")), 1.0),
		"Normal Ultra boot must apply detailed water and caustics without temporal foam trails")
	manager.call("go_to_menu")
	await process_frame
	await process_frame
	var portable := RiverSystem.new()
	portable.config = RiverConfig.new()
	portable.field = RiverField.new()
	portable.field.domain_m = Vector2(24.0, 40.0)
	portable.camera = Camera3D.new()
	root.add_child(portable.camera)
	portable.scene_world = portable.camera.get_world_3d()
	root.add_child(portable)
	portable.start()
	_check(portable.water_material.get_shader_parameter("domain_m") == Vector2(24.0, 40.0),
		"Standalone river must accept a custom field without demo assets or UI")
	_check(portable.submit_queries(PackedVector2Array([Vector2.ZERO])), "Standalone guided water must accept point queries")
	portable.swe.initialized = true
	var query := portable.take_query_batch()
	portable.swe.initialized = false
	_check(query.values[3] > 0.6 and query.values[2] < 0.0, "Standalone queries must return depth and downstream velocity")
	_check(portable.submit_queries(PackedVector2Array([Vector2.ZERO])),
		"Backend initialization between submission and retrieval must not strand the CPU batch")
	portable.take_query_batch()
	portable.field.solver_terrain_image = Image.create(2, 2, false, Image.FORMAT_RGBAF)
	portable.field.solver_terrain_image.fill(Color(0.0, 0.06, 1.0, -1.0))
	portable.config.water_level_m = 0.0
	for count: int in [1, 4, 32]:
		var points := PackedVector2Array()
		points.resize(count)
		points.fill(Vector2.ZERO)
		_check(portable.submit_queries(points), "Guided queries must accept supported batch sizes")
		_check(not portable.submit_queries(points), "An outstanding batch must reject another submission")
		points[0] = Vector2(100.0, 100.0)
		query = portable.take_query_batch()
		_check(query.values.size() == count * 4 and query.points[0] == Vector2.ZERO,
			"Query results must preserve submitted points and contain exactly four values per point")
		_check(absf(query.values[3] - 0.06) < 0.00001,
			"Shallow guided queries must return geometric depth without the visual wet fade")
	_check(portable.submit_queries(PackedVector2Array([Vector2(13.0, 0.0), Vector2(12.0, 0.0), Vector2(-12.0, 0.0)])),
		"Guided queries must accept points at and outside the field boundary")
	query = portable.take_query_batch()
	_check(query.values[1] == 0.0 and query.values[2] == 0.0 and query.values[3] == 0.0
		and query.values[7] == 0.0 and query.values[11] > 0.05,
		"Out-of-domain queries must be dry and stationary with a half-open domain boundary")
	portable.field.solver_terrain_image.fill(Color(0.12, 0.06, 1.0, -1.0))
	portable.submit_queries(PackedVector2Array([Vector2.ZERO]))
	query = portable.take_query_batch()
	_check(query.values[1] == 0.0 and query.values[2] == 0.0 and query.values[3] == 0.0,
		"Dry guided samples must have no depth or current")
	portable.field.solver_terrain_image.fill(Color(0.0, 0.06, 1.0, -1.0))
	portable.submit_queries(PackedVector2Array([Vector2.ZERO]))
	portable.config.water_level_m = 0.1
	query = portable.take_query_batch()
	_check(absf(query.values[0] - 0.06) < 0.00001 and absf(query.values[3] - 0.06) < 0.00001,
		"A submitted guided batch must retain its original water level")
	portable.submit_queries(PackedVector2Array([Vector2.ZERO]))
	portable.stop()
	_check(portable.take_query_batch().is_empty() and portable._query_guided.is_empty() and portable._query_weights.is_empty(),
		"Stopping the river must discard pending query data")
	portable.camera.queue_free()
	portable.queue_free()
	await process_frame
	_finish("river_boot")


func _check_reflection_crop() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0.0, 5.0, 10.0)
	camera.look_at(Vector3.ZERO)
	var field := RiverField.new()
	var reflections := preload("res://scripts/river/river_reflections.gd").new()
	reflections.field = field
	reflections.plane_count = 4
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_water.gdshader")
	reflections.build(host, camera, camera.get_world_3d(), material)
	for aspect: int in [Camera3D.KEEP_HEIGHT, Camera3D.KEEP_WIDTH]:
		camera.keep_aspect = aspect
		for side: float in [-1.0, 1.0]:
			var point := Vector3(side * 5.0, 0.0, 0.0)
			field.surface_points = PackedVector3Array([point])
			reflections.sync(root.size, 0.0, 0.0)
			var reflected: Camera3D = reflections.cameras[0]
			var local := reflected.to_local(point)
			var clip: Vector4 = reflected.get_camera_projection() * Vector4(local.x, local.y, local.z, 1.0)
			_check(clip.w > 0.0 and absf(clip.x / clip.w) < 1.0 and absf(clip.y / clip.w) < 1.0,
				"Cropped reflections must retain water points on both sides of the screen")
	reflections.stop()
	host.free()
