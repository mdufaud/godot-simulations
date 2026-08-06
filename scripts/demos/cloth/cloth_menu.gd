class_name ClothMenu extends RefCounted

var status_label: Label
var wind_label: Label


func build(menu: SimMenu, solvers: Array[ClothSolver], state: Dictionary,
		callbacks: Dictionary, profiler: SimProfiler) -> void:
	menu.add_section("Scene")
	menu.add_action("↺", "Reset", callbacks.reset)
	status_label = menu.add_label("")
	menu.add_separator()
	menu.add_action_toggle("🌬", "Wind", state.wind_enabled, callbacks.wind_toggled)
	menu.add_action("✂", "Unpin", callbacks.unpin)

	menu.add_section("Wind")
	wind_label = menu.add_label("")
	menu.add_slider("Speed", 0.0, 25.0, state.wind_speed, callbacks.wind_speed)
	menu.add_slider("Gustiness", 0.0, 1.0, state.gustiness, callbacks.gustiness)
	menu.add_slider("Turbulence", 0.05, 0.9, state.turbulence, callbacks.turbulence)
	menu.add_toggle("Direction wanders", state.wind_wander, callbacks.wind_wander)
	menu.add_slider("Direction °", 0.0, 360.0, state.wind_dir_deg, callbacks.wind_dir)
	menu.add_separator()

	menu.add_section("Fabric")
	menu.add_slider("Drag", 0.0, 3.0, solvers[0].drag, callbacks.set_all.bind("drag"))
	menu.add_slider("Stretch", 0.0, 6.0, 1.0, callbacks.stretch)
	menu.add_slider("Bending", 0.0, 6.0, 1.0, callbacks.bending)
	menu.add_slider("Damping", 0.97, 1.0, solvers[0].damping,
		callbacks.set_all.bind("damping"))
	menu.add_separator()

	menu.add_section("Solver")
	menu.add_slider("Iterations", 2.0, 20.0, float(solvers[0].iterations),
		callbacks.set_all_int.bind("iterations"))
	menu.add_slider("Substeps", 1.0, 6.0, float(solvers[0].substeps),
		callbacks.set_all_int.bind("substeps"))
	menu.add_slider("Relaxation", 1.0, 1.9, solvers[0].relaxation,
		callbacks.set_all.bind("relaxation"))
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, callbacks.render_scale)


func update_status(solvers: Array[ClothSolver]) -> void:
	if status_label == null or solvers.is_empty():
		return
	var total := 0
	for solver in solvers:
		total += solver.vertex_count()
	status_label.text = "%d sheets · %d vertices · %d substeps × %d iters" % [
		solvers.size(), total, solvers[0].substeps, solvers[0].iterations,
	]


func update_wind(wind: Vector3) -> void:
	if wind_label != null:
		wind_label.text = "%.1f m/s @ %d°" % [wind.length(),
			wrapi(int(rad_to_deg(atan2(wind.z, wind.x))), 0, 360)]
