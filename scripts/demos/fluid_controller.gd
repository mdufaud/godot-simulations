extends Node3D
## Fluid simulation demo: material and scene actions configure one SPH simulation.

@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun_light: DirectionalLight3D = $DirectionalLight3D
@onready var menu: SimMenu = $UI/SimMenu
@onready var _viewport := ViewportGuard.attach(self)

var fluid: FluidSystem
var fluid_config: FluidConfig = FluidConfig.new()
var quality := SimQualityState.new()
# True once fluid.start() has run and the runtime setters are safe to call;
# the launch restore only lands config fields that start() seeds from.
var _fluid_ready := false
var flow_group: VBoxContainer
var flow_slider: HSlider
var scene_action: Button
var material_action: Button
var pool_add_action: Button
var scene_decor: Array[Node3D] = []
var _parameter_pairs: Array = []

var profiler := SimProfiler.new()

const MATERIAL_NAMES := ["Water", "Lava", "Mercury", "Honey", "Water + Oil"]
const MATERIAL_ICONS := ["💧", "🌋", "Hg", "🍯", "⚗"]
const MATERIAL_BUTTON_NAMES := ["Water", "Lava", "Hg", "Honey", "Oil"]


func _ready() -> void:
	# No RenderingDevice means every compute dispatch silently no-ops: say so
	# instead of booting into a black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return

	main_cam.current = true
	fluid = FluidSystem.new()
	fluid.config = fluid_config
	fluid.camera = main_cam
	quality.setup(FluidQualityProfile, "fluid_quality_profile", _apply_quality)
	quality.restore()
	add_child(fluid)
	fluid.start()
	_fluid_ready = true
	_apply_quality(FluidQualityProfile.values(quality.effective))
	_build_scene_decor()
	_setup_ui()
	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(_on_profiler_enabled)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	_apply_env()


func _setup_ui() -> void:
	_update_title()
	menu.add_section("Simulation")
	scene_action = menu.add_action("🗺", "Scene", _cycle_scenario)
	material_action = menu.add_action(MATERIAL_ICONS[int(fluid.mode)],
		MATERIAL_BUTTON_NAMES[int(fluid.mode)], _cycle_material)
	pool_add_action = menu.add_action("＋", "Add", _add_pool_liquid)
	menu.add_action("↺", "Reset", _reset_fluid)
	flow_group = menu.add_group()
	flow_slider = menu.add_slider("Flow", fluid_config.flow_min, fluid_config.flow_max,
		fluid.flow_rate, fluid.set_flow)
	menu.end_group()
	menu.add_separator()
	menu.add_section("Parameters")
	_parameter_pairs = [
		[menu.add_slider("Pressure", 50.0, 600.0, fluid.get_sph_pressure(),
			fluid.set_sph_pressure), fluid.get_sph_pressure],
		[menu.add_slider("Near pressure", 0.0, 80.0, fluid.get_sph_near_pressure(),
			fluid.set_sph_near_pressure), fluid.get_sph_near_pressure],
		[menu.add_slider("Viscosity", 0.0, 2.0, fluid.get_sph_viscosity(),
			fluid.set_sph_viscosity, false, 0.01), fluid.get_sph_viscosity],
		[menu.add_slider("Cohesion", 0.0, 10000.0, fluid.get_sph_cohesion(),
			fluid.set_sph_cohesion, false, 10.0), fluid.get_sph_cohesion],
		[menu.add_slider("Bounce", 0.0, 0.95, fluid.get_sph_bounce(),
			fluid.set_sph_bounce, false), fluid.get_sph_bounce],
		[menu.add_slider("Sub-steps", 1.0, 6.0, float(fluid.get_sph_substeps()),
			fluid.set_sph_substeps), fluid.get_sph_substeps],
		# Foam tuning rides the per-material preset too: these resync on every
		# material/scene switch because _configure_solver rewrites the values.
		[menu.add_slider("Foam amount", 0.0, 300.0, fluid.get_sph_foam_amount(),
			fluid.set_sph_foam_amount, false), fluid.get_sph_foam_amount],
		[menu.add_slider("Foam threshold", 0.5, 12.0, fluid.get_sph_foam_threshold(),
			fluid.set_sph_foam_threshold, false), fluid.get_sph_foam_threshold],
		[menu.add_slider("Foam life", 2.0, 30.0, fluid.get_sph_foam_life(),
			fluid.set_sph_foam_life, false), fluid.get_sph_foam_life],
	]
	menu.add_separator()
	menu.add_section("Performance")
	quality.attach_menu_option(menu)
	menu.add_debug_toggle("🫧", "Foam", fluid.foam_enabled, func(on): fluid.set_foam_enabled(on), false)
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	var water_scale := menu.add_slider("Water render scale", 0.25, 1.0, fluid.render_scale,
		func(v): fluid.set_render_scale(v))
	quality.bind("water_scale", water_scale, fluid.set_render_scale)
	var scale_slider := menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	quality.bind("render_scale", scale_slider, _set_render_scale)
	var count_labels: Array = []
	for count in FluidQualityProfile.PARTICLE_COUNTS:
		count_labels.append("%dk" % int(count / 1000))
	var count_option := menu.add_option_button("Particles", count_labels,
		FluidQualityProfile.PARTICLE_COUNTS.find(fluid.particle_count),
		_set_particle_count_index, false)
	quality.bind("particle_count", count_option,
		func(count): fluid.set_particle_count(count),
		func(count): return FluidQualityProfile.PARTICLE_COUNTS.find(count))
	_sync_scene_ui()

func _set_render_scale(v: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, v)


## Sets the fields a quality tier bundles. Before fluid.start() only the config
## changes (start() seeds the count and the solver reads texture_width); after,
## the same setters the menu uses apply the tier, rebuilding on a count change.
## particle_count, water_scale and render_scale are widget-bound: absent from
## values on a tier push (the widget callbacks already applied them). The count
## fallback must be the tier table's own count for `effective`, never the live
## one: the live count still belongs to the previous tier, and pairing it with
## this tier's texture_width fails config validation, which strands the solver
## uninitialized on every downshift from Ultra.
func _apply_quality(values: Dictionary) -> void:
	var count := int(values.get("particle_count",
		FluidQualityProfile.PARTICLE_COUNT[quality.effective]))
	fluid_config.default_particle_count = count
	fluid_config.texture_width = values.texture_width
	if not _fluid_ready:
		return
	fluid.set_particle_count(count)
	fluid.set_render_scale(values.get("water_scale", fluid.render_scale))
	_set_render_scale(values.get("render_scale", _viewport.render_scale()))
	_resync_parameter_widgets()


func _update_title() -> void:
	var scene_names := ["Pool", "Cascade", "Basin"]
	menu.title = "🌊 %s · %s" % [MATERIAL_NAMES[int(fluid.mode)], scene_names[int(fluid.scenario)]]


func configure_fluid(next_mode: int, next_scene: int) -> void:
	var selected_mode := clampi(next_mode, FluidSystem.FluidKind.WATER, FluidSystem.FluidKind.WATER_OIL)
	var selected_scene := clampi(next_scene, FluidSystem.Scenario.POOL, FluidSystem.Scenario.BASIN)
	fluid.set_configuration(selected_mode as FluidSystem.FluidKind,
		selected_scene as FluidSystem.Scenario)
	_sync_scene_ui()
	_apply_env()
	_resync_parameter_widgets()


func _sync_scene_ui() -> void:
	var scene := int(fluid.scenario)
	flow_group.visible = scene != FluidSystem.Scenario.POOL
	if flow_slider != null:
		var honey_cascade := scene == FluidSystem.Scenario.CASCADE and \
			fluid.mode == FluidSystem.FluidKind.HONEY
		flow_slider.step = 0.01 if honey_cascade else \
			(fluid_config.flow_max - fluid_config.flow_min) / 100.0
		flow_slider.max_value = FluidSystem.HONEY_CASCADE_FLOW_MAX if honey_cascade else fluid_config.flow_max
		flow_slider.value = fluid.flow_rate
	pool_add_action.visible = scene == FluidSystem.Scenario.POOL
	_sync_material_action()
	_sync_pool_add_action()
	for i in scene_decor.size():
		if scene_decor[i] != null:
			scene_decor[i].visible = i == scene
	var camera_rig: OrbitCamera = $CameraPivot
	match scene:
		FluidSystem.Scenario.CASCADE:
			camera_rig.target = Vector3(0.0, 7.0, 0.0)
			camera_rig.distance = 30.0
			camera_rig.pitch = -22.0
			camera_rig.yaw = 10.0
		FluidSystem.Scenario.BASIN:
			camera_rig.target = Vector3(0.0, 2.0, 0.0)
			camera_rig.distance = 16.0
			camera_rig.pitch = -25.0
			camera_rig.yaw = 35.0
		_:
			camera_rig.target = Vector3(0.0, 1.8, 0.0)
			camera_rig.distance = 34.0
			camera_rig.pitch = -35.0
			camera_rig.yaw = 35.0
	var scene_names := ["Pool", "Cascade", "Basin"]
	menu.set_action_label(scene_action, scene_names[scene])
	scene_action.tooltip_text = "Click to cycle scenes. Current: %s." % scene_names[scene]
	_update_title()


func _cycle_scenario() -> void:
	configure_fluid(int(fluid.mode), (int(fluid.scenario) + 1) % 3)


func _sync_material_action() -> void:
	if material_action == null:
		return
	var mode := int(fluid.mode)
	menu.set_action_icon(material_action, MATERIAL_ICONS[mode])
	menu.set_action_label(material_action, MATERIAL_BUTTON_NAMES[mode])
	material_action.tooltip_text = "Click to cycle liquids. Current: %s." % MATERIAL_NAMES[mode]


func _cycle_material() -> void:
	configure_fluid((int(fluid.mode) + 1) % MATERIAL_NAMES.size(), int(fluid.scenario))


func _add_pool_liquid() -> void:
	fluid.add_pool_liquid()
	_sync_pool_add_action()


## A rebuild (Reset, particle-count change) now restores preset tuning, so the
## parameter sliders must re-read the solver or they would display stale values.
func _reset_fluid() -> void:
	fluid.restart()
	_resync_parameter_widgets()


func _set_particle_count_index(idx: int) -> void:
	fluid.set_particle_count(FluidQualityProfile.PARTICLE_COUNTS[idx])
	_resync_parameter_widgets()


func _sync_pool_add_action() -> void:
	if pool_add_action == null:
		return
	var available := fluid.can_add_pool_liquid()
	var label := "Add" if available else "Full"
	var tooltip := "Add more liquid without restarting the Pool." if available else \
		"Pool capacity is full. Reset to add liquid again."
	var caption := pool_add_action.find_child("ActionCaption", true, false) as Label
	if caption == null or caption.text != label:
		menu.set_action_label(pool_add_action, label)
	if pool_add_action.disabled != (not available):
		pool_add_action.disabled = not available
	if pool_add_action.tooltip_text != tooltip:
		pool_add_action.tooltip_text = tooltip


func set_capture_scene(value: int) -> void:
	if value >= FluidSystem.Scenario.POOL and value <= FluidSystem.Scenario.BASIN:
		configure_fluid(int(fluid.mode), value)


func set_capture_flow(value: float) -> void:
	if value >= 0.0:
		fluid.set_flow(value)


func _build_scene_decor() -> void:
	scene_decor.resize(3)
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.42, 0.46, 0.48)
	stone.metallic = 0.12
	stone.roughness = 0.62
	var basin_wall := StandardMaterial3D.new()
	basin_wall.albedo_color = Color(0.68, 0.84, 0.92, 0.12)
	basin_wall.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	basin_wall.metallic = 0.12
	basin_wall.roughness = 0.06
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.08, 0.15, 0.22)
	floor_material.metallic = 0.22
	floor_material.roughness = 0.38
	var pool_frame_material := StandardMaterial3D.new()
	pool_frame_material.albedo_color = Color(0.46, 0.62, 0.68)
	pool_frame_material.metallic = 0.68
	pool_frame_material.roughness = 0.3
	var pool_decor := Node3D.new()
	pool_decor.name = "PoolFrame"
	add_child(pool_decor)
	_add_pool_frame(pool_decor, pool_frame_material)
	pool_decor.visible = false
	scene_decor[FluidSystem.Scenario.POOL] = pool_decor
	for scene_id in [FluidSystem.Scenario.CASCADE, FluidSystem.Scenario.BASIN]:
		var decor := Node3D.new()
		decor.name = "CascadeDecor" if scene_id == FluidSystem.Scenario.CASCADE else "BasinDecor"
		add_child(decor)
		var obstacles := fluid.obstacles_for_scene(scene_id as FluidSystem.Scenario)
		for obstacle_index in obstacles.size():
			var obstacle: Dictionary = obstacles[obstacle_index]
			var box := BoxMesh.new()
			box.size = obstacle.size
			box.material = floor_material if scene_id == FluidSystem.Scenario.BASIN \
				and obstacle_index == 0 else basin_wall if scene_id == FluidSystem.Scenario.BASIN else stone
			var mesh_instance := MeshInstance3D.new()
			mesh_instance.mesh = box
			mesh_instance.transform = obstacle.transform
			decor.add_child(mesh_instance)
		_add_scene_pipe(decor, scene_id as FluidSystem.Scenario)
		decor.visible = false
		scene_decor[scene_id] = decor


func _add_pool_frame(parent: Node3D, frame_material: StandardMaterial3D) -> void:
	var origin := fluid.domain_origin
	var size := fluid.domain_size
	var thickness := 0.28
	var height := 0.55
	var center := origin + size * 0.5
	var rails: Array = [
		[Vector3(center.x, origin.y + height * 0.5, origin.z - thickness * 0.5),
			Vector3(size.x + thickness, height, thickness)],
		[Vector3(center.x, origin.y + height * 0.5, origin.z + size.z + thickness * 0.5),
			Vector3(size.x + thickness, height, thickness)],
		[Vector3(origin.x - thickness * 0.5, origin.y + height * 0.5, center.z),
			Vector3(thickness, height, size.z + thickness)],
		[Vector3(origin.x + size.x + thickness * 0.5, origin.y + height * 0.5, center.z),
			Vector3(thickness, height, size.z + thickness)],
	]
	for rail_data in rails:
		var box := BoxMesh.new()
		box.size = rail_data[1]
		box.material = frame_material
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = box
		mesh_instance.position = rail_data[0]
		parent.add_child(mesh_instance)


func _add_scene_pipe(parent: Node3D, scene: FluidSystem.Scenario) -> void:
	var outlet := fluid.emitter_origin_for_scene(scene)
	var pipe_material := StandardMaterial3D.new()
	pipe_material.albedo_color = Color(0.28, 0.34, 0.38)
	pipe_material.metallic = 0.7
	pipe_material.roughness = 0.3
	if scene == FluidSystem.Scenario.BASIN:
		var feed := CylinderMesh.new()
		feed.top_radius = 0.3
		feed.bottom_radius = 0.3
		feed.height = 1.25
		feed.material = pipe_material
		var feed_instance := MeshInstance3D.new()
		feed_instance.mesh = feed
		feed_instance.position = outlet + Vector3(-0.62, 0.8, 0.0)
		feed_instance.rotation.z = PI / 2.0
		parent.add_child(feed_instance)
	var nozzle := CylinderMesh.new()
	nozzle.top_radius = 0.34
	nozzle.bottom_radius = 0.28
	nozzle.height = 0.8
	nozzle.material = pipe_material
	var nozzle_instance := MeshInstance3D.new()
	nozzle_instance.mesh = nozzle
	nozzle_instance.position = outlet + Vector3(0.0, 0.4, 0.0)
	parent.add_child(nozzle_instance)


func _on_material_selected(idx: int) -> void:
	configure_fluid(idx, fluid.scenario)


func apply_look(idx: int) -> void:
	if idx >= 0 and idx < MATERIAL_NAMES.size():
		_on_material_selected(idx)


func _resync_parameter_widgets() -> void:
	for pair in _parameter_pairs:
		var slider: HSlider = pair[0]
		slider.set_value(float(pair[1].call()))


func _process(delta: float) -> void:
	profiler.poll(delta)
	_sync_pool_add_action()


func _apply_env() -> void:
	if world_env.environment != null:
		world_env.environment.glow_enabled = fluid.mode == FluidSystem.FluidKind.LAVA
		# The composite shades its own water: its sun and reflected sky must
		# match the scene's light and ProceduralSky, or the surface glints and
		# brightens against an environment nothing else agrees with.
		var sky_mat := world_env.environment.sky.sky_material as ProceduralSkyMaterial
		if sky_mat != null:
			fluid.set_sky_colors(sky_mat.sky_top_color, sky_mat.sky_horizon_color)
	fluid.set_light_direction(-sun_light.global_transform.basis.z)


func _on_profiler_enabled(on: bool) -> void:
	fluid.set_profiling(on)
	# The root viewport is measured by SimProfiler itself.
	for vp in fluid.profiled_viewports():
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), on)


func _profiler_lines() -> PackedStringArray:
	var t := fluid.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	var stages := PackedStringArray()
	for key in t:
		if key == "total":
			continue
		stages.append("%s %.2f" % [key, t[key]])
	if not stages.is_empty():
		lines.append("  " + " | ".join(stages))
	var parts := PackedStringArray()
	for entry in [["depth", 0], ["thick", 1], ["fH", 2], ["fV", 3], ["foam", 4],
			["tfH", 5], ["tfV", 6]]:
		var vp: SubViewport = fluid.profiled_viewports()[entry[1]]
		parts.append("%s %.2f" % [entry[0],
			RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())])
	lines.append("viewport GPU ms: " + " | ".join(parts))
	return lines
