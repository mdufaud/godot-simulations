extends "res://tests/test_case.gd"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_surface_mesh()
	root.size = Vector2i(1280, 720)
	var initial_msaa := root.msaa_3d
	var initial_taa := root.use_taa
	var initial_render_scale := root.scaling_3d_scale
	await process_frame
	var manager := root.get_node("GameManager")
	manager.call("set_setting", "river_quality_profile", 1)
	manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	var demo := current_scene as Node3D
	_check(demo.preset_index == 1, "Player boot must select Natural Flow")
	_check(is_equal_approx(demo.config.water_level_m, 0.06), "Player boot must apply the natural water level")
	_check(demo.river.water_material.get_shader_parameter("flow_map") != null, "Player boot must bind the flow map")
	_check(demo.river.water_material.get_shader_parameter("bed_height_texture") != null, "Player boot must bind the riverbed depth fallback")
	_check(demo.river.water_material.get_shader_parameter("reflection_texture") != null, "Player boot must bind the planar reflection")
	_check(demo.river.water_material.get_shader_parameter("foam_detail") == true
		and demo.river.water_material.get_shader_parameter("surface_detail") == 0.0,
		"Normal Medium boot must enable detailed foam independently of Ultra surface effects")
	var actions: GridContainer = demo.menu.get_node("BottomRight/ActionBar")
	var action: Button = demo._menu_builder.preset_action
	_check(actions.get_child_count() == 3 and action.get_parent() == actions
		and demo._menu_builder.flow_action.get_parent() == actions
		and demo._menu_builder.impulse_action.get_parent() == actions,
		"River preset, flow comparison and impulse must use native actions")
	_check(demo.river.swe.enabled and demo.river.swe.available == GpuPreflight.available(),
		"Player boot must request the live SWE system with an explicit GPU availability check")
	_check((demo._menu_builder.flow_action.find_child("ActionCaption", true, false) as Label).text
		== ("SWE" if GpuPreflight.available() else "Guided flow"), "Flow action must identify the active system")
	demo.river.swe.set_enabled(false)
	demo.apply_preset(2)
	_check(not demo.river.swe.enabled, "Water presets must preserve guided flow selection")
	demo.river.swe.set_enabled(true)
	demo.apply_preset(1)
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
		_check(demo.river._surface_mesh.subdivide_width == ceili(RiverField.DOMAIN_M.x / values.water_cell_size_m) - 1,
			"Quality tier must change the water mesh resolution")
		_check(is_equal_approx(demo.river.reflection_scale, values.reflection_scale), "Quality tier must set reflection resolution")
		_check(demo.river._reflections.views.size() == values.reflection_planes,
			"Ultra must render a separate reflection for each water terrace")
		_check(is_equal_approx(float(demo.river.water_material.get_shader_parameter("surface_detail")), values.surface_detail),
			"Quality tier must enable the detailed water and foam shader")
		_check(is_equal_approx(float(demo._scenery.materials[0].get_shader_parameter("water_detail")), values.surface_detail),
			"Quality tier must enable the underwater caustics through the runtime scenery")
		_check(root.use_taa == (tier == 3), "Ultra must apply temporal antialiasing")
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
	manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	demo = current_scene as Node3D
	_check(demo.quality.requested == 0 and demo._menu_builder.quality_option.selected == 0
		and demo.river.reflection_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Player re-entry must restore Low quality before rendering and building controls")
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
	_check(is_equal_approx(time_s, demo.river.simulation_time_s), "Pause must freeze water time")
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
	manager.call("load_demo", "river_demo")
	await process_frame
	await process_frame
	demo = current_scene as Node3D
	_check(demo.quality.requested == 3 and demo.quality.effective == 3
		and demo.river._reflections.views.size() == 4,
		"Normal Ultra boot must restore every terrace reflection without capture setup")
	_check(demo.preset_index == 1 and root.use_taa
		and is_equal_approx(float(demo.river.water_material.get_shader_parameter("surface_detail")), 1.0)
		and is_equal_approx(float(demo._scenery.materials[0].get_shader_parameter("water_detail")), 1.0),
		"Normal Ultra boot must apply detailed water, caustics and temporal antialiasing")
	manager.call("go_to_menu")
	await process_frame
	await process_frame
	_finish("river_boot")


func _check_surface_mesh() -> void:
	var base := PlaneMesh.new()
	base.size = RiverField.DOMAIN_M
	base.subdivide_width = 143
	base.subdivide_depth = 319
	var mesh := preload("res://scripts/river/river_swe_system.gd").surface_mesh(base) as ArrayMesh
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var area_m2 := 0.0
	var valid := true
	for index in range(0, indices.size(), 3):
		var a := vertices[indices[index]]
		var b := vertices[indices[index + 1]]
		var c := vertices[indices[index + 2]]
		var area := (b - a).cross(c - a).y * 0.5
		valid = valid and area > 0.00000001
		area_m2 += area
	_check(valid and absf(area_m2 - RiverField.DOMAIN_M.x * RiverField.DOMAIN_M.y) < 0.1,
		"Continuous SWE mesh must cover the river once without degenerate triangles or gaps")
	var bounds := mesh.get_aabb()
	_check(Vector2(bounds.size.x, bounds.size.z).is_equal_approx(RiverField.DOMAIN_M),
		"Continuous SWE mesh must preserve the full river bounds")
	base.subdivide_width = 599
	base.subdivide_depth = 1333
	_check(preload("res://scripts/river/river_swe_system.gd").surface_mesh(base) == base,
		"Ultra must reuse its already dense surface")
