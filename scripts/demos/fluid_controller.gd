extends Node3D
## Fluid simulation demo: a single FluidSystem switchable between a PBF and a
## dual-density SPH solver (Macklin & Müller 2013 vs SebLague/Clavet) for direct
## A/B comparison, plus water/lava and an SPH foam/spray layer. This controller
## only wires the scene camera into the reusable FluidSystem and drives the UI;
## the fluid itself lives in scripts/fluid/fluid_system.gd.

@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var menu: SimMenu = $UI/SimMenu
@onready var _viewport := ViewportGuard.attach(self)

var fluid: FluidSystem
var fluid_config: FluidConfig = FluidConfig.new()
var quality := SimQualityState.new()
# True once fluid.start() has run and the runtime setters are safe to call;
# the launch restore only lands config fields that start() seeds from.
var _fluid_ready := false
var pbf_group: VBoxContainer
var sph_group: VBoxContainer
var cascade_group: VBoxContainer
var scenario_option: OptionButton
var solver_option: OptionButton
var cascade_decor: Node3D

var profiler := SimProfiler.new()


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
	fluid.method = FluidSystem.Method.SPH
	quality.setup(FluidQualityProfile, "fluid_quality_profile", _apply_quality)
	quality.restore()
	add_child(fluid)
	fluid.start()
	_fluid_ready = true
	_apply_quality(FluidQualityProfile.values(quality.effective))
	_build_cascade_decor()
	_setup_ui()
	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(_on_profiler_enabled)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	_apply_env()


func _setup_ui() -> void:
	_update_title()
	menu.add_section("Simulation")
	scenario_option = menu.add_option_button("Preset", ["Dam", "Cascade"], fluid.scenario,
		_on_scenario_selected)
	solver_option = menu.add_option_button("Solver", ["PBF", "SPH"], fluid.method,
		_on_method_selected)
	menu.add_action("🗺", "Scene", _cycle_scenario)
	menu.add_action_toggle("🌋", "Lava", fluid.mode > 0.5, _on_lava_toggled)
	menu.add_action("↺", "Reset", func(): fluid.restart())
	cascade_group = menu.add_group()
	menu.add_slider("Flow", fluid_config.flow_min, fluid_config.flow_max,
		fluid.cascade_flow, fluid.set_cascade_flow)
	menu.end_group()
	menu.add_separator()
	menu.add_section("Parameters")

	pbf_group = menu.add_group()
	menu.add_slider("Viscosity", 0.0, 0.5, fluid.get_pbf_viscosity(), fluid.set_pbf_viscosity)
	menu.add_slider("Vorticity", 0.0, 0.1, fluid.get_pbf_vorticity(), fluid.set_pbf_vorticity)
	menu.add_slider("Cohesion", 0.0, 0.01, fluid.get_pbf_cohesion(), fluid.set_pbf_cohesion)
	menu.add_slider("Iterations", 1.0, 6.0, float(fluid.get_pbf_iterations()),
		fluid.set_pbf_iterations)
	menu.end_group()

	sph_group = menu.add_group()
	menu.add_slider("Pressure", 50.0, 600.0, fluid.get_sph_pressure(), fluid.set_sph_pressure)
	menu.add_slider("Near pressure", 0.0, 80.0, fluid.get_sph_near_pressure(),
		fluid.set_sph_near_pressure)
	menu.add_slider("Viscosity", 0.0, 0.4, fluid.get_sph_viscosity(),
		fluid.set_sph_viscosity)
	menu.add_slider("Bounce", 0.0, 0.95, fluid.get_sph_bounce(),
		fluid.set_sph_bounce)
	menu.add_slider("Sub-steps", 1.0, 6.0, float(fluid.get_sph_substeps()),
		fluid.set_sph_substeps)
	menu.add_slider("Foam amount", 0.0, 300.0, fluid.get_sph_foam_amount(),
		fluid.set_sph_foam_amount)
	menu.add_slider("Foam threshold", 0.5, 12.0, fluid.get_sph_foam_threshold(),
		fluid.set_sph_foam_threshold)
	menu.add_slider("Foam life", 2.0, 30.0, fluid.get_sph_foam_life(),
		fluid.set_sph_foam_life)
	menu.end_group()
	_update_param_groups()

	menu.add_separator()
	menu.add_section("Performance")
	quality.attach_menu_option(menu)
	menu.add_debug_toggle("🫧", "Foam", fluid.foam_enabled, func(on): fluid.set_foam_enabled(on))
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
		func(idx: int): fluid.set_particle_count(FluidQualityProfile.PARTICLE_COUNTS[idx]))
	quality.bind("particle_count", count_option,
		func(count): fluid.set_particle_count(count),
		func(count): return FluidQualityProfile.PARTICLE_COUNTS.find(count))
	_update_scenario_ui()


func _set_render_scale(v: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, v)


## Sets the fields a quality tier bundles. Before fluid.start() only the config
## changes (start() seeds the count and the solvers read texture_width); after,
## the same setters the menu uses apply the tier, rebuilding on a count change.
## particle_count, water_scale and render_scale are widget-bound: absent from
## values on a tier push (the widget callbacks already applied them), so they
## fall back to the live values.
func _apply_quality(values: Dictionary) -> void:
	var count := int(values.get("particle_count", fluid.particle_count))
	fluid_config.default_particle_count = count
	fluid_config.texture_width = values.texture_width
	if not _fluid_ready:
		return
	fluid.set_particle_count(count)
	fluid.set_render_scale(values.get("water_scale", fluid.render_scale))
	_set_render_scale(values.get("render_scale", _viewport.render_scale()))


func _update_title() -> void:
	var preset := "Cascade" if fluid.scenario == FluidSystem.Scenario.CASCADE else "Dam"
	menu.title = "🌊 Fluid %s (%s)" % [preset,
		"SPH" if fluid.method == FluidSystem.Method.SPH else "PBF"]


func _update_param_groups() -> void:
	pbf_group.visible = fluid.method == FluidSystem.Method.PBF
	sph_group.visible = fluid.method == FluidSystem.Method.SPH


func _on_method_selected(idx: int) -> void:
	fluid.set_method(idx as FluidSystem.Method)
	_update_title()
	_update_param_groups()


func _on_scenario_selected(idx: int) -> void:
	fluid.set_scenario(idx as FluidSystem.Scenario)
	_update_scenario_ui()


func _cycle_scenario() -> void:
	var next := (scenario_option.selected + 1) % scenario_option.item_count
	scenario_option.select(next)
	scenario_option.item_selected.emit(next)


func _update_scenario_ui() -> void:
	var cascade := fluid.scenario == FluidSystem.Scenario.CASCADE
	solver_option.set_item_disabled(FluidSystem.Method.PBF, cascade)
	solver_option.select(fluid.method)
	cascade_group.visible = cascade
	cascade_decor.visible = cascade
	var camera_rig: OrbitCamera = $CameraPivot
	camera_rig.target = Vector3(0.0, 7.0, 0.0) if cascade else Vector3(-2.0, 2.0, -2.0)
	camera_rig.distance = 30.0 if cascade else 22.0
	camera_rig.pitch = -22.0 if cascade else -25.0
	camera_rig.yaw = 10.0 if cascade else 35.0
	_update_title()
	_update_param_groups()


func _build_cascade_decor() -> void:
	cascade_decor = Node3D.new()
	cascade_decor.name = "CascadeDecor"
	add_child(cascade_decor)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.46, 0.48)
	material.metallic = 0.12
	material.roughness = 0.62
	for obstacle in fluid.cascade_obstacles():
		var box := BoxMesh.new()
		box.size = obstacle.size
		box.material = material
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = box
		mesh_instance.transform = obstacle.transform
		cascade_decor.add_child(mesh_instance)
	var pipe := CylinderMesh.new()
	pipe.top_radius = 0.38
	pipe.bottom_radius = 0.38
	pipe.height = 1.6
	pipe.material = material
	var nozzle := MeshInstance3D.new()
	nozzle.mesh = pipe
	nozzle.position = Vector3(-3.0, 14.4, 0.0)
	cascade_decor.add_child(nozzle)
	cascade_decor.visible = false


func _on_lava_toggled(on: bool) -> void:
	fluid.set_mode(1.0 if on else 0.0)
	_apply_env()


func _process(delta: float) -> void:
	profiler.poll(delta)


func _apply_env() -> void:
	if world_env.environment != null:
		world_env.environment.glow_enabled = fluid.mode > 0.5


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
	for entry in [["depth", 0], ["thick", 1], ["fH", 2], ["fV", 3], ["foam", 4]]:
		var vp: SubViewport = fluid.profiled_viewports()[entry[1]]
		parts.append("%s %.2f" % [entry[0],
			RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())])
	lines.append("viewport GPU ms: " + " | ".join(parts))
	return lines
