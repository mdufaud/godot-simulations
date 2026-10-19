extends Node3D

const BreakerProbe := preload("res://tests/ocean_breaker_probe.gd")
const FluidRenderer := preload("res://scripts/fluid/screen_space_fluid_renderer.gd")

@export_range(0.06, 0.36, 0.01) var spacing_m := 0.18
@export_enum("sph", "apic") var candidate := "sph"
@export_enum("Gather", "Scatter CAS") var p2g_transfer := 0
@export_range(0.0, 0.48, 0.01) var apic_grid_cell_size_m := 0.0
@export var apic_free_surface_cut_cells := false
@export var apic_conservative_amount_tracking := false
@export var apic_conservative_surface_reconstruction := false
@export_range(1, 2, 1) var apic_amount_transport_order := 1
@export_range(1, 256, 1) var apic_interface_distance_max_iterations := 64
@export var apic_geometric_surface := false
@export_range(0.0, 1.0, 0.01) var apic_flip_velocity_fraction := 0.0
@export_range(0, 512, 1) var apic_pressure_iterations := 256
@export_range(0, 12, 1) var apic_substeps := 0
@export var still_water := false
@export var include_rock := true
@export_range(0.01, 0.25, 0.001) var bed_slope := 1.0 / 8.0
@export_range(1.0, 900.0, 1.0) var sph_pressure_stiffness_m2_s2 := 180.0

var solver
var renderer: ScreenSpaceFluidRenderer
var camera: Camera3D
var _accumulator := 0.0
var _fixed_delta := 1.0 / 60.0
var _requested_fixed_delta := 0.0
var _frozen := false
var _requested_spacing := 0.18
var _init_queued := false
var _view := "profile"
var _scheduled_time := 0.0
var _ready_to_simulate := false
var _viewport_guard: ViewportGuard
var _capture_profiling := false
var _profile_tick_us := 0
var _profile_frames := 0
var _frame_samples := PackedFloat64Array()
var _simulation_samples := PackedFloat64Array()
var _reconstruction_samples := PackedFloat64Array()
var _active_wall_elapsed_us := 0
var _active_wall_started_us := 0
var _simulation_clock_us := 0


func _ready() -> void:
	_requested_spacing = spacing_m
	if not is_finite(bed_slope) or bed_slope <= 0.0:
		push_error("Ocean breaker bed slope must be finite and positive.")
		return
	if candidate == "apic" and apic_substeps < 0:
		push_error("Ocean breaker APIC substeps must be nonnegative; zero keeps the reference budget.")
		return
	if candidate == "sph" and (not is_finite(sph_pressure_stiffness_m2_s2) or sph_pressure_stiffness_m2_s2 <= 0.0):
		push_error("Ocean breaker SPH pressure stiffness must be finite and positive.")
		return
	if not GpuPreflight.available():
		push_warning("Ocean breaker validation requires GPU compute.")
		return
	_build_environment()
	_build_camera()
	_viewport_guard = ViewportGuard.attach(self)
	solver = BreakerProbe.build_apic_solver(spacing_m, p2g_transfer, apic_grid_cell_size_m, apic_free_surface_cut_cells, still_water, apic_substeps, apic_conservative_amount_tracking or apic_conservative_surface_reconstruction, apic_conservative_surface_reconstruction, apic_amount_transport_order, apic_interface_distance_max_iterations, apic_geometric_surface, apic_flip_velocity_fraction, apic_pressure_iterations, include_rock, bed_slope) if candidate == "apic" else BreakerProbe.build_solver(spacing_m, sph_pressure_stiffness_m2_s2, still_water, include_rock, bed_slope)
	_build_obstacles()
	_build_renderer()
	_init_queued = true
	RenderingServer.call_on_render_thread(solver.init_render)
	for _frame in 120:
		await RenderingServer.frame_post_draw
		if solver.initialized:
			break
	if not solver.initialized:
		push_error("Ocean breaker %s solver failed to initialize." % candidate)
		return
	RenderingServer.call_on_render_thread(BreakerProbe._set_seed_velocities.bind(
		solver, solver._seed_data, still_water, bed_slope))
	await RenderingServer.frame_post_draw
	_scheduled_time = solver._sim_time
	renderer.update(solver.get_position_tex_rid(), solver.live_count())
	_ready_to_simulate = true
	_active_wall_elapsed_us = 0
	_active_wall_started_us = 0 if _frozen else Time.get_ticks_usec()
	_simulation_clock_us = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	if not _ready_to_simulate:
		return
	_collect_profile()
	if not _frozen:
		var clock_us := Time.get_ticks_usec()
		var elapsed_wall_s := float(clock_us - _simulation_clock_us) / 1000000.0
		_simulation_clock_us = clock_us
		_accumulator += _requested_fixed_delta if _requested_fixed_delta > 0.0 else elapsed_wall_s
		var iterations := 0
		while _accumulator >= _fixed_delta and iterations < 8:
			RenderingServer.call_on_render_thread(solver.step_render.bind(_fixed_delta))
			_accumulator -= _fixed_delta
			_scheduled_time += _fixed_delta
			iterations += 1
	renderer.update(solver.get_position_tex_rid(), solver.live_count())


func set_capture_profiling(enabled: bool) -> void:
	_capture_profiling = enabled
	_profile_frames = 0
	_profile_tick_us = Time.get_ticks_usec()
	_frame_samples.clear()
	_simulation_samples.clear()
	_reconstruction_samples.clear()
	_viewport_guard.set_measure_render_time(enabled)
	for viewport: SubViewport in renderer.profiled_viewports():
		if viewport != null:
			RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), enabled)


func _collect_profile() -> void:
	if not _capture_profiling or _frozen:
		return
	var tick := Time.get_ticks_usec()
	var wall_ms := float(tick - _profile_tick_us) / 1000.0
	_profile_tick_us = tick
	_profile_frames += 1
	if _profile_frames <= 60:
		return
	_frame_samples.append(wall_ms)
	var timings: Dictionary = solver.get_timings()
	if timings.has("total"):
		_simulation_samples.append(float(timings.total))
	var reconstruction_ms := 0.0
	for viewport: SubViewport in renderer.profiled_viewports():
		if viewport != null:
			reconstruction_ms += RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	_reconstruction_samples.append(reconstruction_ms)
	if _frame_samples.size() > 240:
		_frame_samples.remove_at(0)
	if _simulation_samples.size() > 240:
		_simulation_samples.remove_at(0)
	if _reconstruction_samples.size() > 240:
		_reconstruction_samples.remove_at(0)


func _p95(values: PackedFloat64Array) -> String:
	if values.is_empty():
		return "unavailable"
	var sorted := values.duplicate()
	sorted.sort()
	return "%.4f" % sorted[ceili(float(sorted.size()) * 0.95) - 1]


func set_capture_fixed_delta(value: float) -> void:
	_requested_fixed_delta = maxf(value, 0.0)
	_fixed_delta = 1.0 / 60.0


func capture_ready() -> bool:
	return _ready_to_simulate


func set_frozen(value: bool) -> void:
	if value == _frozen:
		return
	if _ready_to_simulate:
		if value and _active_wall_started_us > 0:
			var clock_us := Time.get_ticks_usec()
			_active_wall_elapsed_us += clock_us - _active_wall_started_us
			if _requested_fixed_delta <= 0.0:
				_accumulator += float(clock_us - _simulation_clock_us) / 1000000.0
			_simulation_clock_us = clock_us
			_active_wall_started_us = 0
		elif not value:
			_active_wall_started_us = Time.get_ticks_usec()
			_simulation_clock_us = _active_wall_started_us
	_frozen = value


func set_capture_view(value: String) -> void:
	_view = value if value in ["sky", "section", "section_close", "section_breaker", "particles"] else "profile"
	if camera == null:
		return
	if _view == "sky":
		camera.position = Vector3(1.0, 28.0, 0.01)
		camera.look_at(Vector3(1.0, -0.5, 0.0), Vector3.FORWARD)
	elif _view == "section_close":
		var center_x := BreakerProbe.DEPTH / bed_slope - 1.0
		camera.position = Vector3(center_x, 0.6, 7.0)
		camera.look_at(Vector3(center_x, 0.5, 0.0), Vector3.UP)
	elif _view == "section_breaker":
		var center_x := BreakerProbe.DEPTH / bed_slope - 7.0
		camera.position = Vector3(center_x, 0.6, 6.0)
		camera.look_at(Vector3(center_x, 0.5, 0.0), Vector3.UP)
	else:
		camera.position = Vector3(5.0, 0.2, 18.0)
		camera.look_at(Vector3(5.0, -0.5, 0.0), Vector3.UP)
	if renderer != null:
		var limits := Vector2(-spacing_m * 0.75, spacing_m * 0.75) if _view in ["section", "section_close", "section_breaker", "particles"] else Vector2(-1e20, 1e20)
		var show_particles := _view == "particles"
		renderer.set_radius(spacing_m * (0.45 if show_particles else 4.0 / 3.0))
		renderer.composite_mi.visible = not show_particles
		renderer.depth_mat.set_shader_parameter("diagnostic_color_enabled", show_particles)
		camera.cull_mask = (camera.cull_mask & ~FluidRenderer.LAYER_DEPTH) | (FluidRenderer.LAYER_DEPTH if show_particles else 0)
		renderer.depth_mat.set_shader_parameter("clip_z_m", limits)
		renderer.thick_mat.set_shader_parameter("clip_z_m", limits)
		renderer.composite_mat.set_shader_parameter("absorption_scale", 30.0 if _view in ["section", "section_close", "section_breaker"] else 0.5)
		renderer.composite_mat.set_shader_parameter("refraction_strength", 0.0 if _view in ["section", "section_close", "section_breaker"] else 0.35)
		renderer._sync_cams()


func capture_metadata_async(path: String) -> String:
	if candidate != "apic" or solver == null:
		return capture_metadata(path)
	var snapshot := {}
	RenderingServer.call_on_render_thread(_read_capture_snapshot_render.bind(snapshot))
	await RenderingServer.frame_post_draw
	return capture_metadata(path) + " physical_snapshot=" + str(snapshot)


func _read_capture_snapshot_render(result: Dictionary) -> void:
	result["projection"] = solver.get_diagnostics()
	result["volume_state"] = BreakerProbe._apic_volume_diagnostics(solver) if solver.free_surface_cut_cells else "unavailable"


func capture_metadata(path: String) -> String:
	var elapsed: float = solver._sim_time if solver != null else 0.0
	var particles: int = solver.live_count() if solver != null else 0
	var timings: Dictionary = solver.get_timings() if solver != null else {}
	var backlog := _accumulator + maxf(_scheduled_time - elapsed, 0.0)
	var memory_report := str(solver.get_gpu_memory_bytes()) if solver != null and candidate == "apic" else "unavailable"
	var grid_report := " requested_grid_cell_size_m=%.6f applied_grid_cell_size_m=%.6f pressure_relaxation=%.3f free_surface_cut_cells=%s solid_cut_cells=%s surface_min_fraction=%.9f" % [apic_grid_cell_size_m, solver.grid_dx, solver.pressure_relaxation, str(solver.free_surface_cut_cells), str(solver.free_surface_cut_cells and solver.solid_cut_cells), solver.surface_min_fraction] if solver != null and candidate == "apic" else ""
	var eos_report := " requested_stiffness_m2_s2=%.3f applied_stiffness_m2_s2=%.3f near_stiffness_m2_s2=%.3f substeps=%d substep_dt_s=%.9f" % [sph_pressure_stiffness_m2_s2, solver.pressure_mult, solver.near_pressure_mult, solver.substeps, _fixed_delta / solver.substeps] if solver != null and candidate == "sph" else ""
	var clock_mode := "fixed_capture" if _requested_fixed_delta > 0.0 else "realtime"
	var wall_us := _active_wall_elapsed_us
	if _active_wall_started_us > 0:
		wall_us += Time.get_ticks_usec() - _active_wall_started_us
	var active_wall_s := float(wall_us) / 1000000.0
	var report := "BREAKER CAPTURE path=%s scenario=%s seed=0 seed_layout=world_vertical candidate=%s view=%s simulation_clock=%s realtime_verified=false incident_velocity_profile=quadratic_depth_conservative requested_spacing=%.3f applied_spacing=%.3f physical_time=%.6f state_revision=%d requested_dt=%.6f applied_dt=%.6f backlog=%.6f particles=%d gpu_timings=%s solver_gpu_memory_bytes=%s render_radius_m=%.3f render_scale=%.3f frame_p95_ms=%s simulation_p95_ms=%s reconstruction_p95_ms=%s profile_samples=%d" % [
		path, "solitary_slope_rock" if include_rock else "solitary_unobstructed_slope", candidate, _view, clock_mode, _requested_spacing, solver.spacing if solver != null else 0.0,
		elapsed, solver._frame if solver != null else 0, _requested_fixed_delta, _fixed_delta, backlog, particles,
		JSON.stringify(timings), memory_report, renderer.radius, renderer.render_scale,
		_p95(_frame_samples), _p95(_simulation_samples), _p95(_reconstruction_samples), _frame_samples.size()]
	report += grid_report
	report += " camera_position_m=%s camera_fov_deg=%.3f" % [str(camera.position), camera.fov]
	if candidate == "apic" and solver != null:
		report += " requested_substeps=%d applied_substeps=%d" % [apic_substeps, solver.substeps]
		report += " amount_transport_order_requested=%d amount_transport_order_applied=%d geometric_surface_requested=%s geometric_flux_applied=%s volume_plane_pressure_applied=%s geometric_split_applied=%s flip_velocity_fraction_requested=%.6f flip_velocity_fraction_applied=%.6f" % [
			apic_amount_transport_order, solver.amount_transport_order, str(apic_geometric_surface), str(solver.amount_geometric_full_cell_flux), str(solver.pressure_surface_from_volume_planes), str(solver.amount_geometric_split_transport), apic_flip_velocity_fraction, solver.flip_velocity_fraction]
		report += " flux_plane_cache=%s" % str(solver.amount_geometric_full_cell_flux and solver.amount_geometric_flux_cache)
		report += " pressure_iteration_budget_requested=%d pressure_iteration_budget_applied=%d" % [apic_pressure_iterations, mini(maxi(solver.pressure_iterations, 0), solver.PRESSURE_MAX_ITERATIONS)]
		report += " dry_cut_face_pressure=zero_water_flux_with_extrapolated_velocity" if solver.free_surface_cut_cells and solver.solid_cut_cells else " dry_cut_face_pressure=unavailable"
		report += " detached_particle_dynamics=outside_interface_without_pressure_support" if solver.free_surface_cut_cells else " detached_particle_dynamics=grid_only"
	report += eos_report
	report += " still_water=%s" % str(still_water)
	report += " requested_bed_slope=%.9f applied_bed_slope=%.9f domain=%s" % [
		bed_slope, bed_slope, str(AABB(solver.config.domain_origin, solver.config.domain_size_m))]
	report += " active_wall_time_s=%.6f physical_rate_x=%.6f" % [
		active_wall_s, elapsed / active_wall_s if active_wall_s > 0.0 else 0.0]
	print(report)
	return report


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 55.0
	add_child(camera)
	camera.position = Vector3(5.0, 0.2, 18.0)
	camera.look_at(Vector3(5.0, -0.5, 0.0), Vector3.UP)


func _build_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.38, 0.55, 0.66)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.78, 0.82)
	environment.ambient_light_energy = 0.75
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -28.0, 0.0)
	sun.light_color = Color(1.0, 0.91, 0.78)
	sun.light_energy = 1.4
	add_child(sun)


func _build_obstacles() -> void:
	var material_sand := StandardMaterial3D.new()
	material_sand.albedo_color = Color(0.66, 0.49, 0.29)
	material_sand.roughness = 0.92
	var material_rock := StandardMaterial3D.new()
	material_rock.albedo_color = Color(0.3, 0.32, 0.33)
	material_rock.roughness = 0.88
	for index in solver.scene_obstacles.size():
		var obstacle: Dictionary = solver.scene_obstacles[index]
		var box := BoxMesh.new()
		box.size = obstacle.size
		var mesh := MeshInstance3D.new()
		mesh.mesh = box
		mesh.material_override = material_rock if index == 2 else material_sand
		mesh.transform = obstacle.transform
		add_child(mesh)


func _build_renderer() -> void:
	renderer = FluidRenderer.new()
	renderer.camera = camera
	renderer.config = solver.config
	renderer.particle_count = solver.particle_count
	renderer.tex_width = solver.tex_width
	renderer.radius = spacing_m * (4.0 / 3.0)
	renderer.render_scale = 0.5
	renderer.domain_aabb = AABB(solver.config.domain_origin, solver.config.domain_size_m)
	renderer.build_foam = false
	add_child(renderer)
	renderer.start()


func _exit_tree() -> void:
	if renderer != null:
		if _capture_profiling:
			for viewport: SubViewport in renderer.profiled_viewports():
				if viewport != null:
					RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), false)
		renderer.rebind()
	if _init_queued and solver != null:
		RenderingServer.call_on_render_thread(solver.free_render)
