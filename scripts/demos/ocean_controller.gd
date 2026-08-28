extends Node3D
## FFT ocean demo. OceanSolver keeps the whole Tessendorf pipeline on the GPU;
## this controller owns the clipmap mesh that follows the camera, bridges the compute
## textures into the surface material and wires the rest together.

const SKIRT_RADIUS := 9000.0
const MAX_CRATES := 8
const OceanSpraySystem := preload("res://scripts/ocean/ocean_spray.gd")

const PRESETS := [
	preload("res://resources/ocean/presets/calm.tres"),
	preload("res://resources/ocean/presets/breeze.tres"),
	preload("res://resources/ocean/presets/swell.tres"),
	preload("res://resources/ocean/presets/storm.tres"),
]
const LOOKS := [
	preload("res://resources/ocean/looks/golden_hour.tres"),
	preload("res://resources/ocean/looks/tropical_day.tres"),
	preload("res://resources/ocean/looks/storm_overcast.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var ocean_mesh: MeshInstance3D = $Ocean
@onready var main_camera: Camera3D = $CameraPivot/Camera3D
@onready var rocks: Node3D = $Rocks
@onready var underwater_layer: CanvasLayer = $UnderwaterLayer
@onready var underwater_tint: ColorRect = $UnderwaterLayer/Tint
@onready var _viewport := ViewportGuard.attach(self)

var solver := OceanSolver.new()
var config: OceanConfig = OceanConfig.new()
var surface_mat: ShaderMaterial
var disp_texture: Texture2DArrayRD
var norm_texture: Texture2DArrayRD
var foam_texture_a: Texture2DArrayRD
var foam_texture_b: Texture2DArrayRD
var texture_bound := false
var time_scale := 1.0
var sun_elevation := 32.0
var sun_azimuth := 140.0
var current_preset_index := 1
var current_look_index := 0
var sky_material := ShaderMaterial.new()

var waves := OceanHeightSampler.new()
var storm := OceanStorm.new()
var profiler := SimProfiler.new()
var foam_window := OceanFoamWindow.new()
var spray := OceanSpraySystem.new()
var cloudscape := OceanCloudscape.new()

var _menu_builder := OceanMenu.new()
var _sim_time := 0.0
var _frozen := false
var _underwater := false
var _crates: Array[OceanBuoy] = []
var _rng := RandomNumberGenerator.new()
var _capture_profiling := false
var _capture_interaction_foam := true
var _capture_debug_view := 0
var _capture_fixed_delta := -1.0
var _capture_view_name := ""
var _profile_viewport_samples: Array[float] = []
var _profile_cloud_samples: Array[float] = []
var _profile_simulation_samples: Array[float] = []
var _profile_foam_samples: Array[float] = []
var _profile_interaction_capture_samples: Array[float] = []
var _profile_interaction_feedback_samples: Array[float] = []


func _ready() -> void:
	solver.config = config
	solver.map_size = config.map_size
	waves.solver = solver

	orbit_cam.target = Vector3(0, 1.8, 0)
	orbit_cam.distance = 50.0
	orbit_cam.pitch = -1.0
	orbit_cam.yaw = 0.0
	orbit_cam.min_distance = 2.0
	orbit_cam.max_distance = 600.0
	orbit_cam.min_pitch = -80.0
	# Positive pitch swings the camera below the target: diving is allowed.
	orbit_cam.max_pitch = 75.0
	orbit_cam.move_speed = 30.0

	# TAA ghosts on per-pixel-moving displacement; MSAA doesn't. The guard hands both
	# back to the root viewport when the demo exits.
	_viewport.set_msaa(Viewport.MSAA_2X)
	_viewport.set_taa(false)

	_setup_sky()
	_setup_ocean_mesh()
	cloudscape.camera = main_camera
	cloudscape.sun = sun
	add_child(cloudscape)
	cloudscape.build()
	surface_mat.set_shader_parameter("cloud_reflection", cloudscape.reflection_texture())

	storm.sun = sun
	storm.world_env = world_env
	storm.sky_material = sky_material
	storm.cloudscape = cloudscape
	storm.overlay_layer = underwater_layer
	storm.build(self)
	add_child(foam_window)
	foam_window.build(surface_mat, main_camera, rocks)
	add_child(spray)
	set_backend(solver.backend)

	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(func(on: bool):
		solver.profiling = on
		foam_window.set_profiling(on)
		cloudscape.set_profiling(on)
	)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid())

	_setup_ui()
	apply_look(0)
	apply_preset(1)
	RenderingServer.call_on_render_thread(solver.init_render)


func _exit_tree() -> void:
	_release_textures()
	RenderingServer.call_on_render_thread(solver.free_render)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		_bind_textures()
		return
	surface_mat.set_shader_parameter("foam_history_indices", solver.get_foam_read_indices())
	var simulation_delta := _capture_fixed_delta if _capture_fixed_delta > 0.0 else delta
	var step_scale := 0.0 if _frozen else time_scale
	_sim_time += simulation_delta * step_scale
	solver.sim_time = _sim_time

	var cam := get_viewport().get_camera_3d()
	storm.update(simulation_delta, cam)

	# World-space UVs anchor the wave field to the world. Continuous recentering
	# avoids a whole clipmap lattice changing triangles on the same frame.
	if cam != null:
		var p := cam.global_position
		ocean_mesh.global_position = Vector3(p.x, 0.0, p.z)
		waves.poll(delta)
		_update_underwater(p)
		foam_window.update(simulation_delta, p)
		surface_mat.set_shader_parameter("storm_mood", storm.current_mood())
		storm.set_rain_wind(Vector3(cos(solver.wind_direction), 0.0,
			sin(solver.wind_direction)))
		storm.set_rain_time(_sim_time)
		surface_mat.set_shader_parameter("wind_direction", Vector2(
			sin(solver.wind_direction), cos(solver.wind_direction)))
		_sync_wave_filter_uniforms()
		spray.set_wind_direction(Vector2(cos(solver.wind_direction),
			sin(solver.wind_direction)))
		spray.update_state(p, storm.current_mood(), _sim_time)

	if step_scale > 0.0:
		RenderingServer.call_on_render_thread(solver.step_render.bind(simulation_delta * step_scale))
	profiler.poll(delta)
	_collect_profile_sample()


func apply_preset(index: int) -> void:
	if index < 0 or index >= PRESETS.size():
		return
	var preset: OceanPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Ocean preset '%s': %s" % [preset.display_name, error])
		return
	# Sliders first, preset second: the panel shows the preset, the solver gets
	# the unquantised values rather than whatever the sliders snapped to.
	_menu_builder.sync_to_preset(preset)
	preset.apply_to(solver)
	current_preset_index = index
	_sync_wave_filter_uniforms()
	_sync_foam_material_strength()
	set_spray_amount(preset.spray_amount)
	solver.mark_spectrum_dirty()


func _sync_foam_material_strength() -> void:
	if surface_mat == null:
		return
	surface_mat.set_shader_parameter("foam_strength",
		clampf(0.2 + solver.foam_amount * 0.24, 0.2, 2.0))


func apply_look(index: int) -> void:
	if index < 0 or index >= LOOKS.size():
		return
	var look: OceanLookPreset = LOOKS[index]
	var error := look.validate()
	if error != "":
		push_error("Ocean look '%s': %s" % [look.display_name, error])
		return
	current_look_index = index
	sun_elevation = look.sun_elevation
	sun_azimuth = look.sun_azimuth
	sun.light_color = look.sun_color
	sun.light_energy = look.sun_energy
	sun.light_angular_distance = look.sun_angular_distance
	_apply_sun()
	var env := world_env.environment
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = look.exposure
	env.tonemap_white = look.white_point
	env.glow_intensity = look.glow_intensity
	env.glow_bloom = look.glow_bloom
	env.glow_hdr_threshold = look.glow_hdr_threshold
	env.fog_density = look.fog_density
	env.fog_light_color = look.fog_color
	env.fog_aerial_perspective = look.fog_aerial_perspective
	surface_mat.set_shader_parameter("water_color", look.deep_color)
	surface_mat.set_shader_parameter("color_shallow", look.shallow_color)
	surface_mat.set_shader_parameter("foam_color", look.foam_color)
	surface_mat.set_shader_parameter("roughness_base", look.roughness)
	surface_mat.set_shader_parameter("sss_strength", look.sss_strength)
	surface_mat.set_shader_parameter("sun_path_width", look.sun_path_width)
	surface_mat.set_shader_parameter("sun_glitter_strength", look.sun_glitter_strength)
	surface_mat.set_shader_parameter("sky_reflection_strength", look.sky_reflection_strength)
	surface_mat.set_shader_parameter("sky_zenith", look.sky_zenith)
	surface_mat.set_shader_parameter("sky_horizon", look.sky_horizon)
	surface_mat.set_shader_parameter("micro_normal_strength", look.micro_normal_strength)
	surface_mat.set_shader_parameter("micro_normal_scales", look.micro_normal_scales)
	surface_mat.set_shader_parameter("micro_normal_fade_start", look.micro_normal_fade_start)
	surface_mat.set_shader_parameter("micro_normal_fade_end", look.micro_normal_fade_end)
	surface_mat.set_shader_parameter("aerial_density", look.aerial_density)
	storm.apply_look(look)
	_menu_builder.sync_to_look(look)


func set_time_scale(value: float) -> void:
	time_scale = value


func set_frozen(on: bool) -> void:
	_frozen = on


func set_storm_mood(value: float) -> void:
	storm.mood_target = clampf(value, 0.0, 1.0)


func set_capture_storm(value: float, lightning: bool = false) -> void:
	storm.set_mood_immediate(value)
	storm.lightning_enabled = lightning
	storm.set_capture_rain(true)


func set_backend(value: int) -> void:
	solver.set_backend(value)
	var styled := value == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT
	surface_mat.set_shader_parameter("style_mode", 1 if styled else 0)
	surface_mat.set_shader_parameter("foam_pattern", load(
		"res://resources/ocean/foam_pattern_sot.png" if styled
		else "res://resources/ocean/foam_pattern.png"))
	surface_mat.set_shader_parameter("foam_breakup", load(
		"res://resources/ocean/foam_breakup_sot.png" if styled
		else "res://resources/ocean/foam_breakup.png"))
	surface_mat.set_shader_parameter("micro_normal", load(
		"res://resources/ocean/micro_normal_sot.png" if styled
		else "res://resources/ocean/micro_normal.png"))
	foam_window.set_enabled(styled and _capture_interaction_foam)
	spray.set_enabled(styled)


func set_spray_amount(value: float) -> void:
	spray.amount = value


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func set_capture_view(view: String) -> void:
	# Fixed views keep visual captures comparable while still framing distinct
	# water questions: crest, sun path and distant horizon.
	_capture_view_name = view.to_lower()
	orbit_cam.set_enabled(false)
	rocks.visible = false
	_capture_interaction_foam = false
	foam_window.set_enabled(false)
	match _capture_view_name:
		"overhead", "low_water":
			_capture_view_name = "overhead"
			orbit_cam.target = Vector3(0.0, 2.0, 0.0)
			orbit_cam.distance = 28.0
			orbit_cam.pitch = -22.0
			orbit_cam.yaw = 12.0
		"low_crest", "crest":
			_capture_view_name = "low_crest"
			orbit_cam.target = Vector3(0.0, 2.8, 0.0)
			orbit_cam.distance = 32.0
			orbit_cam.pitch = -5.0
			orbit_cam.yaw = 18.0
		"sun":
			_capture_view_name = "sun"
			orbit_cam.target = Vector3(0.0, 1.8, 0.0)
			orbit_cam.distance = 50.0
			orbit_cam.pitch = -1.0
			orbit_cam.yaw = 0.0
		"horizon":
			_capture_view_name = "horizon"
			orbit_cam.target = Vector3(0.0, 4.0, 0.0)
			orbit_cam.distance = 72.0
			orbit_cam.pitch = -1.0
			orbit_cam.yaw = 90.0
		_:
			push_warning("Unknown ocean capture view '%s'" % view)
			return
	orbit_cam.call_deferred("_update_transform")
	_sim_time = 20.0
	solver.sim_time = _sim_time


func set_capture_ui(visible: bool) -> void:
	$UI.visible = visible


func set_capture_time(value: float) -> void:
	_sim_time = maxf(value, 0.0)
	solver.sim_time = _sim_time


func set_capture_fixed_delta(value: float) -> void:
	_capture_fixed_delta = maxf(value, 0.0)


## Fix plan 0.6 (trap M1): advance the LIVE simulation by `seconds` before the
## first captured frame so the foam feedback (persistence ~4 s in storm) sits at
## equilibrium instead of its zero-initialised transient. The spectral phase
## time keeps flowing from the capture time; nothing renders in between. Steps
## are flushed to the render thread in batches so every step completes before
## the await returns.
func warmup_foam(seconds: float) -> void:
	var steps := int(ceil(seconds / 0.06))
	for i in steps:
		_sim_time += 0.06
		solver.sim_time = _sim_time
		RenderingServer.call_on_render_thread(solver.step_render.bind(0.06))
		if i % 60 == 59:
			await RenderingServer.frame_post_draw
	# Let the last foam state land in the read texture before any capture.
	await RenderingServer.frame_post_draw


func set_capture_wind_direction(value: float) -> void:
	solver.wind_direction = fposmod(value, TAU)
	solver.mark_spectrum_dirty()


func set_capture_debug(value: int) -> void:
	_capture_debug_view = clampi(value, 0, 7)
	if surface_mat != null:
		surface_mat.set_shader_parameter("debug_view", _capture_debug_view)


func set_capture_cascade(value: int) -> void:
	var selected := value if value >= 0 and value < solver.num_cascades() else -1
	if surface_mat != null:
		surface_mat.set_shader_parameter("geometry_cascade", selected)


func set_sun_elevation(value: float) -> void:
	sun_elevation = value
	_apply_sun()


func set_sun_azimuth(value: float) -> void:
	sun_azimuth = value
	_apply_sun()


func set_map_size(n: int) -> void:
	if n == solver.map_size:
		return
	_release_textures()
	RenderingServer.call_on_render_thread(solver.free_render)
	solver.map_size = n
	GameManager.set_setting("ocean_map_size", n)
	RenderingServer.call_on_render_thread(solver.init_render)


## Tossed from the camera; buoyancy runs off the same height sampler the
## underwater toggle uses, so crates ride the rendered swell.
func throw_crate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var crate := OceanBuoy.new()
	crate.height_sampler = waves.sampler()
	add_child(crate)
	var fwd := -cam.global_transform.basis.z
	crate.global_position = cam.global_position + fwd * 4.0 + Vector3.UP
	crate.linear_velocity = fwd * 14.0 + Vector3.UP * 4.0
	crate.angular_velocity = Vector3(
		_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0)
	)
	_crates.append(crate)
	foam_window.track_body(crate)
	if _crates.size() > MAX_CRATES:
		_crates.pop_front().queue_free()


func clear_crates() -> void:
	for crate in _crates:
		if is_instance_valid(crate):
			crate.queue_free()
	_crates.clear()


func _setup_ocean_mesh() -> void:
	ocean_mesh.mesh = OceanClipmap.build(
		config.finest_cell_m, config.clipmap_levels, SKIRT_RADIUS)
	# GPU-displaced vertices invalidate the flat mesh AABB: cover the domain.
	ocean_mesh.custom_aabb = AABB(
		Vector3(-SKIRT_RADIUS, -60.0, -SKIRT_RADIUS),
		Vector3(SKIRT_RADIUS * 2.0, 120.0, SKIRT_RADIUS * 2.0)
	)
	surface_mat = ShaderMaterial.new()
	surface_mat.shader = load("res://shaders/ocean/ocean_surface.gdshader")
	var scales := PackedVector4Array()
	for i in solver.num_cascades():
		var inv := 1.0 / solver.tile_lengths[i]
		scales.append(Vector4(inv, inv, 1.0, 1.0))
	surface_mat.set_shader_parameter("map_scales", scales)
	surface_mat.set_shader_parameter("num_cascades", solver.num_cascades())
	surface_mat.set_shader_parameter("num_foam_cascades", solver.foam_cascade_count)
	surface_mat.set_shader_parameter("foam_pattern",
		load("res://resources/ocean/foam_pattern.png"))
	surface_mat.set_shader_parameter("foam_breakup",
		load("res://resources/ocean/foam_breakup.png"))
	surface_mat.set_shader_parameter("micro_normal",
		load("res://resources/ocean/micro_normal.png"))
	surface_mat.set_shader_parameter("clipmap_cell", config.finest_cell_m)
	surface_mat.set_shader_parameter("clipmap_half_extent",
		config.finest_cell_m * OceanClipmap.GRID * 0.5)
	surface_mat.set_shader_parameter("clipmap_ring_levels", float(config.clipmap_levels))
	_sync_wave_filter_uniforms()
	surface_mat.set_shader_parameter("geometry_cascade", -1)
	surface_mat.set_shader_parameter("sun_direction", sun.global_transform.basis.z.normalized())
	surface_mat.set_shader_parameter("sun_disk_radius",
		deg_to_rad(sun.light_angular_distance) * 0.5)
	ocean_mesh.material_override = surface_mat


func _sync_wave_filter_uniforms() -> void:
	if surface_mat == null:
		return
	var middle_wavelength := solver.wind_wave_length_m
	if solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT \
		and solver.mid_wave_height_m > 0.01:
		middle_wavelength = solver.mid_wave_length_m
	surface_mat.set_shader_parameter("cascade_wavelengths", Vector3(
		solver.long_wave_length_m, middle_wavelength, 0.72))


func _setup_ui() -> void:
	_menu_builder.solver = solver
	_menu_builder.surface_mat = surface_mat
	_menu_builder.world_env = world_env
	_menu_builder.storm = storm
	_menu_builder.profiler = profiler
	_menu_builder.host = self
	_menu_builder.build(menu, PRESETS, LOOKS, sun_elevation, sun_azimuth, time_scale)


func _setup_sky() -> void:
	sky_material.shader = load("res://shaders/ocean/ocean_sky.gdshader")
	var sky := Sky.new()
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.sky_material = sky_material
	world_env.environment.sky = sky
	world_env.environment.background_mode = Environment.BG_SKY
	world_env.environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY


func _apply_sun() -> void:
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth, 0.0)
	var direction := sun.global_transform.basis.z.normalized()
	sky_material.set_shader_parameter("sun_direction", direction)
	sky_material.set_shader_parameter("sun_radius",
		deg_to_rad(sun.light_angular_distance) * 0.5)
	if cloudscape.is_inside_tree():
		cloudscape.set_sun_direction(direction)
	spray.set_sun_direction(direction)
	if surface_mat != null:
		surface_mat.set_shader_parameter("sun_direction", direction)
		surface_mat.set_shader_parameter("sun_disk_radius",
			deg_to_rad(sun.light_angular_distance) * 0.5)


func _bind_textures() -> void:
	disp_texture = Texture2DArrayRD.new()
	disp_texture.texture_rd_rid = solver.get_displacement_tex_rid()
	norm_texture = Texture2DArrayRD.new()
	norm_texture.texture_rd_rid = solver.get_normal_tex_rid()
	foam_texture_a = Texture2DArrayRD.new()
	foam_texture_a.texture_rd_rid = solver.get_foam_tex_rid(0)
	foam_texture_b = Texture2DArrayRD.new()
	foam_texture_b.texture_rd_rid = solver.get_foam_tex_rid(1)
	surface_mat.set_shader_parameter("displacements", disp_texture)
	surface_mat.set_shader_parameter("normals", norm_texture)
	surface_mat.set_shader_parameter("foam_history_a", foam_texture_a)
	surface_mat.set_shader_parameter("foam_history_b", foam_texture_b)
	surface_mat.set_shader_parameter("foam_history_indices", solver.get_foam_read_indices())
	foam_window.bind_ocean(disp_texture, solver.tile_lengths)
	spray.build(disp_texture, norm_texture, solver.tile_lengths, main_camera,
		foam_texture_a, foam_texture_b, solver.get_foam_read_indices())
	spray.set_sun_direction(sun.global_transform.basis.z.normalized())
	texture_bound = true


## Dropping the RIDs before the solver frees them keeps the Texture2DArrayRD
## wrappers from pointing at dead GPU memory for a frame.
func _release_textures() -> void:
	foam_window.release_ocean()
	if disp_texture != null:
		disp_texture.texture_rd_rid = RID()
	if norm_texture != null:
		norm_texture.texture_rd_rid = RID()
	if foam_texture_a != null:
		foam_texture_a.texture_rd_rid = RID()
	if foam_texture_b != null:
		foam_texture_b.texture_rd_rid = RID()
	spray.release_textures()
	texture_bound = false


## Solver stage timings, under the overlay's frame line.
func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var backend_name := "Sea of Thieves-inspired FFT" \
		if solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT else "JONSWAP/TMA"
	var lines := PackedStringArray(["backend %s" % backend_name])
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("spectrum"):
		lines.append("  spectrum %.2f | fft %.2f | generate %.2f | feedback %.2f" % [
			t.get("spectrum", 0.0), t.get("fft", 0.0), t.get("assemble", 0.0),
			t.get("foam", 0.0),
		])
	var interaction_capture_gpu := foam_window.get_capture_gpu_time()
	var interaction_feedback_gpu := foam_window.get_feedback_gpu_time()
	if interaction_capture_gpu > 0.0 or interaction_feedback_gpu > 0.0:
		lines.append("interaction capture %.2f | feedback %.2f" % [
			interaction_capture_gpu, interaction_feedback_gpu,
		])
	var cloud_gpu := cloudscape.get_gpu_time()
	if cloud_gpu > 0.0:
		lines.append("cloud GPU %.2f ms" % cloud_gpu)
	return lines


func capture_metadata(path: String) -> String:
	var cam := get_viewport().get_camera_3d()
	var position := cam.global_position if cam != null else Vector3.ZERO
	var water_height := waves.sample(Vector2(position.x, position.z))
	var timings := solver.get_timings()
	var simulation_gpu := _median(_profile_simulation_samples,
		timings.get("total", 0.0))
	var simulation_gpu_p95 := _percentile(_profile_simulation_samples, 0.95,
		timings.get("total", 0.0))
	var foam_gpu := _median(_profile_foam_samples, timings.get("foam", 0.0))
	var foam_gpu_p95 := _percentile(_profile_foam_samples, 0.95, foam_gpu)
	var interaction_capture_gpu := _median(_profile_interaction_capture_samples,
		foam_window.get_capture_gpu_time())
	var interaction_feedback_gpu := _median(_profile_interaction_feedback_samples,
		foam_window.get_feedback_gpu_time())
	var cloud_gpu := _median(_profile_cloud_samples, cloudscape.get_gpu_time())
	var cloud_gpu_p95 := _percentile(_profile_cloud_samples, 0.95, cloud_gpu)
	var viewport_gpu := _median(_profile_viewport_samples,
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	var viewport_gpu_p95 := _percentile(_profile_viewport_samples, 0.95, viewport_gpu)
	var cloud_coverage := cloudscape.capture_alpha_coverage()
	var backend_name := "Sea of Thieves-inspired FFT" \
		if solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT else "JONSWAP/TMA"
	return "CAPTURE META backend=%s look=%s preset=%s view=%s frame=%d time=%.6f fixed_dt=%.6f wind=%.6f sun_elevation=%.3f sun_azimuth=%.3f camera=%s water=%.3f sim_gpu=%.3f sim_gpu_p95=%.3f foam_gpu=%.3f foam_gpu_p95=%.3f interaction_capture_gpu=%.3f interaction_feedback_gpu=%.3f cloud_gpu=%.3f cloud_gpu_p95=%.3f viewport_gpu=%.3f viewport_gpu_p95=%.3f cloud_cov=%.4f path=%s" % [
		backend_name, (LOOKS[current_look_index] as OceanLookPreset).display_name,
		(PRESETS[current_preset_index] as OceanPreset).display_name,
		_capture_view_name, solver._frame, _sim_time, _capture_fixed_delta,
		solver.wind_direction, sun_elevation, sun_azimuth, position, water_height,
		simulation_gpu, simulation_gpu_p95, foam_gpu, foam_gpu_p95,
		interaction_capture_gpu, interaction_feedback_gpu, cloud_gpu, cloud_gpu_p95,
		viewport_gpu, viewport_gpu_p95, cloud_coverage, path,
	]


func capture_metadata_async(path: String) -> String:
	# Texture readback may take several frames. Do not keep appending GPU timestamp
	# queries while waiting: RenderingDevice has a finite per-frame timestamp ring.
	# Preserve the capture profiler state and restore it after both readbacks.
	var profiling_was_enabled := solver.profiling
	var capture_profiling_was_enabled := _capture_profiling
	if profiling_was_enabled:
		solver.profiling = false
	_capture_profiling = false
	var visibility := _capture_foam_visibility()
	var foam_strength := clampf(0.2 + solver.foam_amount * 0.24, 0.2, 2.0)
	var layer_metrics: Array[Dictionary] = []
	for cascade in solver.num_cascades():
		var normal: PackedByteArray = await _capture_readback(
			solver.get_normal_tex_rid(), cascade)
		var foam: PackedByteArray = await _capture_readback(
			solver.get_foam_read_tex_rid(cascade), cascade)
		layer_metrics.append(_capture_texture_metrics(normal, foam,
			visibility[cascade], foam_strength))
	if profiling_was_enabled:
		solver.profiling = true
	_capture_profiling = capture_profiling_was_enabled
	var crest_layers := PackedFloat32Array()
	var breaking_layers := PackedFloat32Array()
	var foam_layers := PackedFloat32Array()
	var fresh_layers := PackedFloat32Array()
	var visible_layers := PackedFloat32Array()
	var breaking_visible_layers := PackedFloat32Array()
	for metrics in layer_metrics:
		crest_layers.append(metrics.crest_coverage)
		breaking_layers.append(metrics.breaking_coverage)
		foam_layers.append(metrics.foam_coverage)
		fresh_layers.append(metrics.fresh_coverage)
		visible_layers.append(metrics.foam_cov_visible)
		breaking_visible_layers.append(metrics.breaking_cov_visible)
	var rendered := _rendered_layer_metrics(layer_metrics)
	return "%s crest_cov_layers=%s breaking_cov_layers=%s foam_cov_layers=%s fresh_cov_layers=%s foam_visible_layers=%s crest_cov=%.4f breaking_cov=%.4f foam_cov=%.4f foam_mean=%.4f fresh_mean=%.4f foam_cov_visible=%.4f breaking_cov_visible=%.4f measure_version=%d" % [
		capture_metadata(path), crest_layers, breaking_layers, foam_layers,
		fresh_layers, visible_layers, rendered.crest_coverage,
		rendered.breaking_coverage, rendered.foam_coverage, rendered.foam_mean,
		rendered.fresh_mean, _max_over_layers(visible_layers),
		_max_over_layers(breaking_visible_layers), OceanConfig.MEASURE_VERSION]


## Per-cascade foam visibility as the surface shader computes it (fix plan 0.1):
## cascade_fade * detail_filter * layer weight, plus the distance fade applied
## to the final foam factor. Camera-dependent, so this is the capture camera's
## distance to the water plane and its pixel footprint at that distance.
func _capture_foam_visibility() -> Array[float]:
	var cam := get_viewport().get_camera_3d()
	var position := cam.global_position if cam != null else Vector3.ZERO
	var dist := maxf(position.y, 1.0)
	var fov := 65.0
	if cam != null:
		fov = cam.fov
	var viewport_height := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var pixel_world := 2.0 * dist * tan(deg_to_rad(fov) * 0.5) / viewport_height
	var wavelengths := _cascade_wavelengths()
	var visibilities: Array[float] = []
	for cascade in solver.num_cascades():
		var tile := solver.tile_lengths[cascade]
		var cascade_fade := exp(-dist * 0.32 / tile)
		var wavelength := wavelengths[cascade]
		var detail_filter := 1.0 - smoothstep(wavelength * 0.22, wavelength * 0.55,
			pixel_world)
		var layer_weight := 0.85 if cascade == 0 else 1.0
		visibilities.append(cascade_fade * detail_filter * layer_weight
			* exp(-dist * 0.0015))
	return visibilities


## Same wavelengths as _sync_wave_filter_uniforms pushes to the material.
func _cascade_wavelengths() -> Array[float]:
	var middle := solver.wind_wave_length_m
	if solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT \
		and solver.mid_wave_height_m > 0.01:
		middle = solver.mid_wave_length_m
	return [solver.long_wave_length_m, middle, 0.72]


## The surface material reads max() over the simulated cascades with per-layer
## weights (0.85 for the long cascade) — not layer 1 alone (fix plan P0-A.3).
func _rendered_layer_metrics(layer_metrics: Array[Dictionary]) -> Dictionary:
	var simulated := mini(solver.foam_cascade_count, layer_metrics.size())
	var rendered := layer_metrics[0].duplicate()
	var crest := 0.0
	var breaking := 0.0
	var foam := 0.0
	var foam_mean := 0.0
	var fresh_mean := 0.0
	var fresh := 0.0
	for i in layer_metrics.size():
		var metrics := layer_metrics[i]
		crest = maxf(crest, metrics.crest_coverage)
		breaking = maxf(breaking, metrics.breaking_coverage)
		if i >= simulated:
			continue
		var weight := 0.85 if i == 0 else 1.0
		foam = maxf(foam, metrics.foam_coverage * weight)
		foam_mean = maxf(foam_mean, metrics.foam_mean * weight)
		fresh = maxf(fresh, metrics.fresh_coverage * weight)
		fresh_mean = maxf(fresh_mean, metrics.fresh_mean * weight)
	rendered.crest_coverage = crest
	rendered.breaking_coverage = breaking
	rendered.foam_coverage = foam
	rendered.foam_mean = foam_mean
	rendered.fresh_coverage = fresh
	rendered.fresh_mean = fresh_mean
	return rendered


func _max_over_layers(values: PackedFloat32Array) -> float:
	var best := 0.0
	for value in values:
		best = maxf(best, value)
	return best


func capture_image_metrics(image: Image) -> String:
	var sum := 0.0
	var sum_sq := 0.0
	var saturation_sum := 0.0
	var count := 0
	var y_start := int(float(image.get_height()) * 0.5)
	for y in range(y_start, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color := image.get_pixel(x, y)
			var luminance := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
			sum += luminance
			sum_sq += luminance * luminance
			var maximum := maxf(color.r, maxf(color.g, color.b))
			var minimum := minf(color.r, minf(color.g, color.b))
			saturation_sum += (maximum - minimum) / maxf(maximum, 1e-4)
			count += 1
	var mean := sum / maxf(float(count), 1.0)
	var variance := maxf(sum_sq / maxf(float(count), 1.0) - mean * mean, 0.0)
	var coverage := capture_water_coverage(image)
	return "CAPTURE IMAGE lower_luma=%.4f lower_luma_sd=%.4f lower_sat=%.4f water_cov=%.4f orient_coh=%.4f banding=%.4f" % [
		mean, sqrt(variance), saturation_sum / maxf(float(count), 1.0), coverage,
		capture_orientation_coherence(image), capture_banding_fraction(image)]


## Fix plan 0.3 (trap M3): mean orientation coherence of the lower half, from
## the structure tensor of the luminance gradients. This is the accepted
## short-wave metric — the raw HF energy ratio is banned as a quality signal.
func capture_orientation_coherence(image: Image) -> float:
	var y_start := int(float(image.get_height()) * 0.5)
	var block := 16
	var coherence_sum := 0.0
	var blocks := 0
	for by in range(y_start, image.get_height() - block, block * 2):
		for bx in range(0, image.get_width() - block, block * 2):
			var jxx := 0.0
			var jxy := 0.0
			var jyy := 0.0
			for y in range(by + 1, by + block - 1, 2):
				for x in range(bx + 1, bx + block - 1, 2):
					var gx := _luma_difference(image, x + 1, y) - _luma_difference(image, x - 1, y)
					var gy := _luma_difference(image, x, y + 1) - _luma_difference(image, x, y - 1)
					jxx += gx * gx
					jxy += gx * gy
					jyy += gy * gy
			var trace := jxx + jyy
			if trace < 1e-7:
				continue
			var discriminant := sqrt(maxf((jxx - jyy) * (jxx - jyy) + 4.0 * jxy * jxy, 0.0))
			coherence_sum += discriminant / trace
			blocks += 1
	return coherence_sum / maxf(float(blocks), 1.0)


## Fraction of exactly flat neighbour pairs in the 8-bit luminance: a proxy for
## quantisation banding, the non-structured HF the plan tells us to exclude.
func capture_banding_fraction(image: Image) -> float:
	var y_start := int(float(image.get_height()) * 0.5)
	var flat := 0
	var pairs := 0
	for y in range(y_start, image.get_height(), 4):
		for x in range(0, image.get_width() - 1, 4):
			var l0 := _luma_byte(image, x, y)
			var l1 := _luma_byte(image, x + 1, y)
			if l0 == l1:
				flat += 1
			pairs += 1
	return float(flat) / maxf(float(pairs), 1.0)


func _luma_difference(image: Image, x: int, y: int) -> float:
	x = clampi(x, 0, image.get_width() - 1)
	y = clampi(y, 0, image.get_height() - 1)
	return _luma_byte(image, x, y)


func _luma_byte(image: Image, x: int, y: int) -> float:
	var color := image.get_pixel(x, y)
	return floorf((color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722) * 255.0)


func capture_water_coverage(image: Image) -> float:
	if _capture_debug_view != 1:
		return -1.0
	var row_step := 4
	var previous := Vector3.ZERO
	var strongest_delta := 0.0
	var horizon_y := 0
	for y in range(0, image.get_height(), row_step):
		var row := Vector3.ZERO
		var samples := 0
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			row += Vector3(color.r, color.g, color.b)
			samples += 1
		row /= maxf(float(samples), 1.0)
		if y >= int(image.get_height() * 0.1) and y <= int(image.get_height() * 0.9):
			var delta := row.distance_to(previous)
			if delta > strongest_delta:
				strongest_delta = delta
				horizon_y = y
		previous = row
	if strongest_delta < 0.01:
		return 1.0
	return clampf(float(image.get_height() - horizon_y) / float(image.get_height()), 0.0, 1.0)


func _capture_readback(rid: RID, layer: int) -> PackedByteArray:
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store_capture_readback", state, data)
		)
	)
	for frame in 360:
		await get_tree().process_frame
		if state.done:
			return state.data
	return PackedByteArray()


func _store_capture_readback(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


## Raw texel counts use the shared MEASURE_* thresholds (fix plan 0.7). The
## *_cov_visible fields re-apply the surface shader's style_mode==1 composition
## chain to the raw signal so metadata becomes comparable to the rendered pixel
## (fix plan 0.1, trap M2). Documented drift risk: the ribbon/breakup texture
## multiplies live only in the shader, so visible coverage is an upper bound.
func _capture_texture_metrics(normal: PackedByteArray, foam: PackedByteArray,
		foam_visibility: float, foam_strength: float) -> Dictionary:
	var crest_active := 0
	var breaking_active := 0
	var breaking_visible_active := 0
	var normal_count := 0
	for i in normal.size() / 8:
		var crest := _capture_half(normal.decode_u16(i * 8 + 4))
		var breaking := _capture_half(normal.decode_u16(i * 8 + 6))
		if crest > OceanConfig.MEASURE_CREST_THRESHOLD:
			crest_active += 1
		if breaking > OceanConfig.MEASURE_BREAKING_THRESHOLD:
			breaking_active += 1
		if breaking * foam_visibility > OceanConfig.MEASURE_BREAKING_THRESHOLD:
			breaking_visible_active += 1
		normal_count += 1
	var foam_sum := 0.0
	var fresh_sum := 0.0
	var foam_active := 0
	var fresh_active := 0
	var foam_visible_active := 0
	var foam_count := 0
	for i in foam.size() / 4:
		var persistent := _capture_half(foam.decode_u16(i * 4))
		var fresh := _capture_half(foam.decode_u16(i * 4 + 2))
		foam_sum += persistent
		fresh_sum += fresh
		if persistent > OceanConfig.MEASURE_FOAM_THRESHOLD:
			foam_active += 1
		if fresh > OceanConfig.MEASURE_FRESH_THRESHOLD:
			fresh_active += 1
		# Same grid as the normal map: the fresh channel folds in the breaking
		# texel exactly like the shader's fresh_signal.
		var breaking := _capture_half(normal.decode_u16(i * 8 + 6))
		var composed := _composed_screen_foam(persistent, fresh, breaking, foam_strength)
		if composed * foam_visibility > OceanConfig.MEASURE_FOAM_THRESHOLD:
			foam_visible_active += 1
		foam_count += 1
	return {
		"crest_coverage": float(crest_active) / maxf(float(normal_count), 1.0),
		"breaking_coverage": float(breaking_active) / maxf(float(normal_count), 1.0),
		"foam_coverage": float(foam_active) / maxf(float(foam_count), 1.0),
		"fresh_coverage": float(fresh_active) / maxf(float(foam_count), 1.0),
		"foam_cov_visible": float(foam_visible_active) / maxf(float(foam_count), 1.0),
		"breaking_cov_visible": float(breaking_visible_active)
			/ maxf(float(normal_count), 1.0),
		"foam_mean": foam_sum / maxf(float(foam_count), 1.0),
		"fresh_mean": fresh_sum / maxf(float(foam_count), 1.0),
	}


## ocean_surface.gdshader's foam composition (style_mode 1), minus the breakup
## texture stage. Fresh foam folds in the rendered breaking contribution
## (foam_breaking * 0.45) so a live front counts before history accumulates.
func _composed_screen_foam(persistent: float, fresh: float, breaking: float,
		foam_strength: float) -> float:
	var persistent_source := clampf(persistent * foam_strength * 0.92, 0.0, 1.0)
	var fresh_signal := maxf(fresh, breaking * 0.45)
	var fresh_source := clampf(fresh_signal * foam_strength * 1.35, 0.0, 1.0)
	var persistent_foam := smoothstep(0.018, 0.16, persistent_source)
	var fresh_foam := smoothstep(0.006, 0.055, fresh_source)
	return 1.0 - (1.0 - persistent_foam * 0.92) * (1.0 - fresh_foam * 1.12)


func _capture_half(bits: int) -> float:
	var exponent := (bits >> 10) & 0x1f
	if exponent == 31:
		return 0.0
	var sign := -1.0 if bits & 0x8000 else 1.0
	var mantissa := bits & 0x3ff
	if exponent == 0:
		return sign * mantissa * pow(2.0, -24.0)
	return sign * (1.0 + mantissa / 1024.0) * pow(2.0, exponent - 15)


func capture_ready() -> bool:
	return solver.initialized and texture_bound


func set_capture_profiling(on: bool) -> void:
	_capture_profiling = on
	_profile_viewport_samples.clear()
	_profile_cloud_samples.clear()
	_profile_simulation_samples.clear()
	_profile_foam_samples.clear()
	_profile_interaction_capture_samples.clear()
	_profile_interaction_feedback_samples.clear()
	solver.profiling = on
	foam_window.set_profiling(on)
	cloudscape.set_profiling(on)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func set_capture_foam(enabled: bool) -> void:
	solver.foam_feedback_enabled = enabled
	foam_window.set_enabled(enabled and _capture_interaction_foam
		and solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)
	if surface_mat != null:
		surface_mat.set_shader_parameter("foam_feedback_enabled", enabled)


func set_capture_micro_normals(enabled: bool) -> void:
	var look: OceanLookPreset = LOOKS[current_look_index]
	if surface_mat != null:
		surface_mat.set_shader_parameter("micro_normal_strength",
			look.micro_normal_strength if enabled else 0.0)


func set_capture_reflection(enabled: bool) -> void:
	var look: OceanLookPreset = LOOKS[current_look_index]
	if surface_mat != null:
		surface_mat.set_shader_parameter("cloud_reflection_enabled", enabled)
		surface_mat.set_shader_parameter("sky_reflection_strength",
			look.sky_reflection_strength if enabled else 0.0)
		surface_mat.set_shader_parameter("sun_glitter_strength",
			look.sun_glitter_strength if enabled else 0.0)


func set_capture_interaction(enabled: bool) -> void:
	_capture_interaction_foam = enabled
	foam_window.set_enabled(enabled
		and solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)


func set_render_features(on: bool) -> void:
	cloudscape.set_enabled(on)
	storm.set_render_features(on)
	surface_mat.set_shader_parameter("cloud_reflection_enabled", on)
	var look: OceanLookPreset = LOOKS[current_look_index]
	surface_mat.set_shader_parameter("micro_normal_strength",
		look.micro_normal_strength if on else 0.0)
	surface_mat.set_shader_parameter("sky_reflection_strength",
		look.sky_reflection_strength if on else 0.0)


func set_clouds_enabled(on: bool) -> void:
	cloudscape.set_enabled(on)
	surface_mat.set_shader_parameter("cloud_reflection_enabled", on)


func set_capture_rain(enabled: bool) -> void:
	storm.set_capture_rain(enabled)


func set_capture_spray(enabled: bool) -> void:
	spray.set_enabled(enabled and solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT)


func _collect_profile_sample() -> void:
	if not _capture_profiling:
		return
	var simulation: float = solver.get_timings().get("total", 0.0)
	var foam: float = solver.get_timings().get("foam", 0.0)
	var viewport := RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid())
	if simulation > 0.0 and viewport > 0.0:
		_profile_simulation_samples.append(simulation)
		_profile_foam_samples.append(foam)
		_profile_interaction_capture_samples.append(foam_window.get_capture_gpu_time())
		_profile_interaction_feedback_samples.append(foam_window.get_feedback_gpu_time())
		_profile_cloud_samples.append(cloudscape.get_gpu_time())
		_profile_viewport_samples.append(viewport)
		if _profile_viewport_samples.size() > 240:
			_profile_simulation_samples.pop_front()
			_profile_foam_samples.pop_front()
			_profile_interaction_capture_samples.pop_front()
			_profile_interaction_feedback_samples.pop_front()
			_profile_cloud_samples.pop_front()
			_profile_viewport_samples.pop_front()


func _median(values: Array[float], fallback: float) -> float:
	if values.is_empty():
		return fallback
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	return sorted[middle] if sorted.size() % 2 == 1 \
		else (sorted[middle - 1] + sorted[middle]) * 0.5


func _percentile(values: Array[float], quantile: float, fallback: float) -> float:
	if values.is_empty():
		return fallback
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size()) * quantile)) - 1, 0, sorted.size() - 1)
	return sorted[index]


## Camera vs water surface. The choppy xz offset is ignored: metre-level error,
## fine for a fullscreen toggle.
func _update_underwater(cam_pos: Vector3) -> void:
	var below := cam_pos.y < waves.sample(Vector2(cam_pos.x, cam_pos.z))
	if below == _underwater:
		return
	_underwater = below
	storm.underwater = below
	underwater_tint.visible = below
	# Single source of truth: the surface shader picks its interface side from
	# this, so the overlay and the water shading can never disagree.
	surface_mat.set_shader_parameter("camera_underwater", below)
	world_env.environment.fog_density = 0.03 if below else storm.surface_fog_density
	world_env.environment.fog_light_color = \
		Color(0.05, 0.19, 0.24) if below else storm.surface_fog_color
