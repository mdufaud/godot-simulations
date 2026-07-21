extends Node3D
## Fluid simulation demo: a single FluidSystem switchable between a PBF and a
## dual-density SPH solver (Macklin & Müller 2013 vs SebLague/Clavet) for direct
## A/B comparison, plus water/lava and an SPH foam/spray layer. This controller
## only wires the scene camera into the reusable FluidSystem and drives the UI;
## the fluid itself lives in scripts/fluid/fluid_system.gd.

@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var menu: SimMenu = $UI/SimMenu

var fluid: FluidSystem
var pbf_group: VBoxContainer
var sph_group: VBoxContainer

var profiler_label: Label
var _profile_accum := 0.0


func _ready() -> void:
	main_cam.current = true
	fluid = FluidSystem.new()
	fluid.camera = main_cam
	fluid.method = FluidSystem.Method.SPH
	add_child(fluid)
	fluid.start()
	_setup_ui()
	_setup_profiler()
	_apply_env()


func _setup_ui() -> void:
	_update_title()
	menu.add_section("Simulation")
	menu.add_option_button("Solver", ["PBF", "SPH"], fluid.method, _on_method_selected)
	menu.add_toggle("Lava mode", fluid.mode > 0.5, _on_lava_toggled)
	menu.add_action("↺", "Reset", func(): fluid.restart())
	menu.add_separator()
	menu.add_section("Parameters")

	pbf_group = menu.add_group()
	var pbf := fluid.pbf_solver
	menu.add_slider("Viscosity", 0.0, 0.5, pbf.xsph_c, func(v): pbf.xsph_c = v)
	menu.add_slider("Vorticity", 0.0, 0.1, pbf.vorticity_eps, func(v): pbf.vorticity_eps = v)
	menu.add_slider("Cohesion", 0.0, 0.01, pbf.scorr_k, func(v): pbf.scorr_k = v)
	menu.add_slider("Iterations", 1.0, 6.0, float(pbf.solver_iterations),
		func(v): pbf.solver_iterations = int(round(v)))
	menu.end_group()

	sph_group = menu.add_group()
	var sph := fluid.sph_solver
	menu.add_slider("Pressure", 50.0, 600.0, sph.pressure_mult, func(v): sph.pressure_mult = v)
	menu.add_slider("Near pressure", 0.0, 80.0, sph.near_pressure_mult,
		func(v): sph.near_pressure_mult = v)
	menu.add_slider("Viscosity", 0.0, 0.4, sph.viscosity_strength,
		func(v): sph.viscosity_strength = v)
	menu.add_slider("Bounce", 0.0, 0.95, sph.collision_damping, func(v): sph.collision_damping = v)
	menu.add_slider("Sub-steps", 1.0, 6.0, float(sph.substeps),
		func(v): sph.substeps = int(round(v)))
	menu.add_toggle("Foam", fluid.foam_enabled, func(on): fluid.set_foam_enabled(on))
	menu.add_slider("Foam amount", 0.0, 300.0, sph.foam_spawn_rate,
		func(v): sph.foam_spawn_rate = v)
	menu.add_slider("Foam threshold", 0.5, 12.0, sph.foam_trapped_min,
		func(v): sph.foam_trapped_min = v)
	menu.add_slider("Foam life", 2.0, 30.0, sph.foam_life_max,
		func(v): sph.foam_life_max = v)
	menu.end_group()
	_update_param_groups()

	menu.add_separator()
	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, _on_profiler_toggled)
	menu.add_slider("Render scale", 0.25, 1.0, fluid.render_scale, func(v): fluid.set_render_scale(v))
	menu.add_label("Particles")
	menu.add_button("16k", func(): fluid.set_particle_count(16384))
	menu.add_button("32k", func(): fluid.set_particle_count(32768))
	menu.add_button("64k", func(): fluid.set_particle_count(65536))


func _update_title() -> void:
	menu.title = "🌊 Fluid Simulation (%s)" % ("SPH" if fluid.method == FluidSystem.Method.SPH else "PBF")


func _update_param_groups() -> void:
	pbf_group.visible = fluid.method == FluidSystem.Method.PBF
	sph_group.visible = fluid.method == FluidSystem.Method.SPH


func _on_method_selected(idx: int) -> void:
	fluid.set_method(idx as FluidSystem.Method)
	_update_title()
	_update_param_groups()


func _on_lava_toggled(on: bool) -> void:
	fluid.set_mode(1.0 if on else 0.0)
	_apply_env()


func _apply_env() -> void:
	if world_env.environment != null:
		world_env.environment.glow_enabled = fluid.mode > 0.5


func _setup_profiler() -> void:
	profiler_label = Label.new()
	profiler_label.position = Vector2(8, 8)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["monospace"])
	profiler_label.add_theme_font_override("font", mono)
	profiler_label.add_theme_font_size_override("font_size", 13)
	profiler_label.add_theme_color_override("font_outline_color", Color.BLACK)
	profiler_label.add_theme_constant_override("outline_size", 4)
	profiler_label.visible = false
	menu.get_parent().add_child(profiler_label)


func _on_profiler_toggled(on: bool) -> void:
	fluid.set_profiling(on)
	profiler_label.visible = on
	for vp in fluid.profiled_viewports() + [get_viewport()]:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), on)


func _update_overlay() -> void:
	var t := fluid.get_timings()
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
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
	parts.append("root %.2f" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()))
	lines.append("viewport GPU ms: " + " | ".join(parts))
	profiler_label.text = "\n".join(lines)


func _process(delta: float) -> void:
	if not profiler_label.visible:
		return
	_profile_accum += delta
	if _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()
