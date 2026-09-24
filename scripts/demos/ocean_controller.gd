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
# Shared quality-tier state: the persisted requested tier may differ from the
# active one when the GPU cannot host the pick — the menu shows
# "requested / active" then.
var quality := SimQualityState.new()
var detail_distance_m: float = OceanQualityProfile.detail_distance_m(
	OceanQualityProfile.default_tier())
var surface_mat: ShaderMaterial
var disp_texture: Texture2DArrayRD
var norm_texture: Texture2DArrayRD
var derivative_texture: Texture2DArrayRD
var foam_near_texture_a: Texture2DArrayRD
var foam_near_texture_b: Texture2DArrayRD
var texture_bound := false
var _allocated_foam_near_size := 0
var time_scale := 1.0
var sun_elevation := 32.0
var sun_azimuth := 140.0
var current_preset_index := 1
var current_look_index := 0
var sky_material := ShaderMaterial.new()

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
var _capture_measurement := false
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
# GPU point queries: crate -> first result slot as submitted last physics tick,
# the camera slot (or -1 when no camera existed at submission time), and the
# camera slot's (height, nx, nz, valid) for underwater/capture reads.
var _query_crate_slots: Array = []
var _camera_query_slot := -1
var _camera_water := Vector4.ZERO
var _camera_water_valid := false
# Set by warmup_foam: _process pauses its own time advance and step queue so
# the warmup steps are the only ones advancing the simulation.
var _warmup_active := false


func _ready() -> void:
	# No RenderingDevice means every compute dispatch silently no-ops: say so
	# instead of booting into a black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return
	if not OceanQualityProfile.tier_supported(OceanQualityProfile.Tier.LOW):
		menu.add_label("This GPU cannot run the minimum ocean quality profile.")
		return

	solver.config = config
	quality.setup(OceanQualityProfile, "ocean_quality_profile",
		_apply_quality, _rebuild_quality_resources)
	quality.restore()
	solver.map_size = OceanQualityProfile.FFT_SIZE[quality.effective]
	_allocated_foam_near_size = solver.foam_near_size

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
	foam_window.set_enabled(true)
	add_child(spray)
	spray.set_enabled(true)

	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(func(on: bool):
		solver.profiling = on
		foam_window.set_profiling(on)
		cloudscape.set_profiling(on)
	)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)

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
	var near_active := solver.foam_near_active()
	surface_mat.set_shader_parameter("fft_surface", solver.wave_model == OceanSolver.WaveModel.FFT)
	surface_mat.set_shader_parameter("foam_near_enabled", near_active)
	if near_active:
		var state := solver.foam_state()
		surface_mat.set_shader_parameter("foam_near_index", float(state.index))
		surface_mat.set_shader_parameter("foam_near_center", state.center)
		surface_mat.set_shader_parameter("foam_domains", solver.foam_field_domains())
		spray.set_foam_state(state.center, solver.foam_field_domains(), float(state.index))
	var simulation_delta := _capture_fixed_delta if _capture_fixed_delta > 0.0 else delta
	var step_scale := 0.0 if _frozen else time_scale
	if not _warmup_active:
		_sim_time += simulation_delta * step_scale
	solver.sim_time = _sim_time
	surface_mat.set_shader_parameter("sim_time", _sim_time)

	var cam := get_viewport().get_camera_3d()
	if not _capture_measurement:
		storm.update(simulation_delta, cam)

	# World-space UVs anchor the wave field to the world. Continuous recentering
	# avoids a whole clipmap lattice changing triangles on the same frame.
	if cam != null:
		var p := cam.global_position
		ocean_mesh.global_position = Vector3(p.x, 0.0, p.z)
		solver.near_center = Vector2(p.x, p.z)
		_update_underwater(p)
		foam_window.update(simulation_delta * step_scale, p)
		surface_mat.set_shader_parameter("storm_mood", storm.current_mood())
		storm.set_rain_wind(Vector3(cos(solver.wind_direction), 0.0,
			sin(solver.wind_direction)))
		storm.set_rain_time(_sim_time)
		# Waves travel world (cos θ, sin θ): the FFT texture axes swap into
		# world axes (asserted by ocean_fft_test), matching rain and spray.
		surface_mat.set_shader_parameter("wind_direction", Vector2(
			cos(solver.wind_direction), sin(solver.wind_direction)))
		_sync_wave_filter_uniforms()
		spray.set_wind_direction(Vector2(cos(solver.wind_direction),
			sin(solver.wind_direction)))
		spray.update_state(p, storm.current_mood(), _sim_time)

	var refresh_requested := solver.take_render_refresh_request()
	if not _warmup_active and (step_scale > 0.0 or refresh_requested):
		RenderingServer.call_on_render_thread(solver.step_render.bind(
			simulation_delta * step_scale, _sim_time, solver.near_center))
	profiler.poll(delta)
	_collect_profile_sample()


## Physics ticks ride the GPU: apply last tick's query results (one frame of
## latency, never blocking), then submit this tick's probes — the camera first,
## then the four buoyancy corners of every crate (33 points worst case).
func _physics_process(_delta: float) -> void:
	if not solver.initialized:
		return
	if solver.query_results_valid():
		_consume_query_results(solver.latest_results())
	var points := PackedVector2Array()
	_query_crate_slots.clear()
	_camera_query_slot = -1
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_camera_query_slot = points.size()
		points.append(Vector2(cam.global_position.x, cam.global_position.z))
	for crate in _crates:
		if not is_instance_valid(crate):
			continue
		_query_crate_slots.append([crate, points.size()])
		for probe in OceanBuoy.PROBES:
			var wp := crate.global_transform * probe
			points.append(Vector2(wp.x, wp.z))
	solver.submit_queries(points)


func _consume_query_results(results: PackedVector4Array) -> void:
	if results.is_empty():
		return
	if _camera_query_slot >= 0 and _camera_query_slot < results.size() \
			and results[_camera_query_slot].w > 0.5:
		_camera_water = results[_camera_query_slot]
		_camera_water_valid = true
	for entry in _query_crate_slots:
		var crate: OceanBuoy = entry[0]
		var slot: int = entry[1]
		if not is_instance_valid(crate) \
				or slot + OceanBuoy.PROBES.size() > results.size():
			continue
		var depths := PackedFloat32Array()
		var normal := Vector3.ZERO
		for i in OceanBuoy.PROBES.size():
			var r := results[slot + i]
			depths.append(r.x - (crate.global_transform * OceanBuoy.PROBES[i]).y)
			if r.w > 0.5:
				normal += Vector3(r.y, 1.0, r.z)
		if normal.length_squared() > 0.0:
			normal = normal.normalized()
		else:
			normal = Vector3.UP
		crate.apply_water_frame(depths, normal)


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
	solver.mark_spectrum_dirty()
	current_preset_index = index
	_sync_wave_filter_uniforms()
	_sync_foam_material_strength()
	set_spray_amount(preset.spray_amount)
	set_storm_mood(preset.storm_mood)


func _sync_foam_material_strength() -> void:
	if surface_mat == null:
		return
	# The panel slider owns "foam_strength" once the user touches it; until then
	# presets drive the derived value (docs/ocean_foam_injection_fix.md §5.3).
	var derived := clampf(0.25 + solver.foam_amount * 0.13, 0.25, 1.0)
	if _menu_builder.sync_foam_strength(derived):
		surface_mat.set_shader_parameter("foam_strength", derived)


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


func set_spray_amount(value: float) -> void:
	spray.amount = value


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func set_foam_distance(value: float) -> void:
	solver.set_foam_distance(value)
	if surface_mat != null:
		surface_mat.set_shader_parameter("foam_domains", solver.foam_field_domains())


func set_detail_distance(value: float) -> void:
	detail_distance_m = clampf(value, 250.0, 4000.0)
	if surface_mat != null:
		surface_mat.set_shader_parameter("detail_distance_m", detail_distance_m)


func set_capture_height_gain(value: float) -> void:
	solver.height_gain = value
	solver.mark_spectrum_dirty()


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
		"tutorial", "close":
			_capture_view_name = "tutorial"
			orbit_cam.target = Vector3(0.0, 0.4, 0.0)
			# ~10 m wide crop of the five-wave field (refonte plan §7).
			orbit_cam.distance = 5.5
			orbit_cam.pitch = -18.0
			orbit_cam.yaw = 22.0
		"storm_foam":
			orbit_cam.target = Vector3(0.0, 0.8, 0.0)
			orbit_cam.distance = 13.0
			orbit_cam.pitch = -18.0
			orbit_cam.yaw = 22.0
		"foam_aerial":
			# Oblique aerial framing: high enough to read the foam field over
			# hundreds of metres, pitched so the big storm swells keep their
			# shaded relief; yaw puts the sun cross-wise so crests and trails
			# separate.
			_capture_view_name = "foam_aerial"
			orbit_cam.target = Vector3(0.0, 1.0, 0.0)
			orbit_cam.distance = 100.0
			orbit_cam.pitch = -55.0
			orbit_cam.yaw = 90.0
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
		"interaction":
			# Storm splash-zone framing for crate-interaction captures. The
			# interaction foam window is (re-)enabled by set_capture_interaction
			# right after this, and capture_demo tosses a crate into frame.
			_capture_interaction_foam = true
			_capture_view_name = "interaction"
			orbit_cam.target = Vector3(0.0, 1.0, 0.0)
			orbit_cam.distance = 11.0
			orbit_cam.pitch = -14.0
			orbit_cam.yaw = 18.0
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
## first captured frame so the foam feedback reaches equilibrium instead of its
## zero-initialised transient. The spectral phase
## time keeps flowing from the capture time; nothing renders in between. Steps
## are flushed to the render thread in batches so every step completes before
## the await returns.
func move_capture_camera(offset: Vector3) -> void:
	orbit_cam.target += offset
	orbit_cam._update_transform()


func warmup_foam(seconds: float) -> void:
	var steps := maxi(1, int(ceil(seconds * 60.0)))
	var step_delta := maxf(seconds, 0.0) / float(steps)
	_warmup_active = true
	for i in steps:
		_sim_time += step_delta
		solver.sim_time = _sim_time
		RenderingServer.call_on_render_thread(solver.step_render.bind(step_delta, _sim_time, solver.near_center))
		if i % 4 == 3:
			await RenderingServer.frame_post_draw
	# Let the last foam state land in the read texture before any capture.
	await RenderingServer.frame_post_draw
	_warmup_active = false


func set_capture_wind_direction(value: float) -> void:
	solver.wind_direction = fposmod(value, TAU)
	solver.mark_spectrum_dirty()


func set_capture_debug(value: int) -> void:
	_capture_debug_view = clampi(value, 0, 8)
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


## Sets the solver fields a quality tier bundles (the state hands over the
## tier's values). The foam and detail distances honour their menu overrides,
## and the effective tier degrades when the GPU cannot host the pick (the menu
## reports "requested / active"; never a silent fallback).
func _apply_quality(values: Dictionary) -> void:
	solver.amortize = values.amortize
	solver.short_cascade_half_rate = values.short_cascade_half_rate
	solver.foam_near_stride = values.foam_near_stride
	solver.foam_near_size = values.foam_near_size
	if _menu_builder.sync_foam_distance(values.foam_near_distance):
		solver.set_foam_distance(values.foam_near_distance)
	if _menu_builder.sync_detail_distance(values.detail_distance_m):
		set_detail_distance(values.detail_distance_m)
	solver.quality_tier = quality.effective
	if surface_mat != null:
		surface_mat.set_shader_parameter("ultra_detail", values.surface_detail)
	_menu_builder.sync_foam_layout()


## Profile switch: keep existing GPU resources when the texture sizes match.
func _rebuild_quality_resources() -> void:
	var target_map_size: int = OceanQualityProfile.FFT_SIZE[quality.effective]
	if solver.initialized and solver.map_size == target_map_size and _allocated_foam_near_size == solver.foam_near_size:
		return
	_release_textures()
	solver.initialized = false
	RenderingServer.call_on_render_thread(solver.free_render)
	solver.map_size = target_map_size
	_allocated_foam_near_size = solver.foam_near_size
	RenderingServer.call_on_render_thread(solver.init_render)


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


func quality_profile_label() -> String:
	return quality.label()


## Tossed from the camera; the physics tick submits its probes as GPU point
## queries, so crates ride exactly the surface that is rendered.
func throw_crate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var crate := OceanBuoy.new()
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
	_sync_ocean_scales()
	surface_mat.set_shader_parameter("num_cascades", solver.num_cascades())
	_sync_foam_textures()
	surface_mat.set_shader_parameter("clipmap_cell", config.finest_cell_m)
	surface_mat.set_shader_parameter("clipmap_half_extent",
		config.finest_cell_m * OceanClipmap.GRID * 0.5)
	surface_mat.set_shader_parameter("clipmap_ring_levels", float(config.clipmap_levels))
	surface_mat.set_shader_parameter("detail_distance_m", detail_distance_m)
	surface_mat.set_shader_parameter("ultra_detail",
		OceanQualityProfile.values(quality.effective).surface_detail)
	_sync_wave_filter_uniforms()
	surface_mat.set_shader_parameter("geometry_cascade", -1)
	surface_mat.set_shader_parameter("sun_direction", sun.global_transform.basis.z.normalized())
	surface_mat.set_shader_parameter("sun_disk_radius",
		deg_to_rad(sun.light_angular_distance) * 0.5)
	ocean_mesh.material_override = surface_mat


func _sync_ocean_scales() -> void:
	var scales := PackedVector4Array()
	for i in solver.num_cascades():
		var inv := 1.0 / solver.tile_lengths[i]
		scales.append(Vector4(inv, inv, 1.0, 1.0))
	surface_mat.set_shader_parameter("map_scales", scales)


func _sync_foam_textures() -> void:
	if surface_mat == null:
		return
	surface_mat.set_shader_parameter("foam_detail", load(
		"res://resources/ocean/foam_detail.png"))
	surface_mat.set_shader_parameter("micro_normal", load(
		"res://resources/ocean/micro_normal.png"))


func _sync_wave_filter_uniforms() -> void:
	if surface_mat == null:
		return
	var references := solver.spectral_references()
	_menu_builder.sync_foam_layout()
	surface_mat.set_shader_parameter("cascade_wavelengths", Vector3(
		references[0].wavelength_m, references[1].wavelength_m, references[2].wavelength_m))
	surface_mat.set_shader_parameter("cascade_slope_variance", Vector3(
		references[0].slope_variance, references[1].slope_variance, references[2].slope_variance))


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
	derivative_texture = Texture2DArrayRD.new()
	derivative_texture.texture_rd_rid = solver.get_derivative_tex_rid()
	surface_mat.set_shader_parameter("displacements", disp_texture)
	surface_mat.set_shader_parameter("normals", norm_texture)
	surface_mat.set_shader_parameter("derivatives", derivative_texture)
	# Near textures bind unconditionally: foam_near_enabled is refreshed per
	# frame from foam_near_active(), and a preset switch must never enable
	# blending onto unbound (default-white) samplers.
	foam_near_texture_a = Texture2DArrayRD.new()
	foam_near_texture_a.texture_rd_rid = solver.get_foam_near_tex_rid(0)
	foam_near_texture_b = Texture2DArrayRD.new()
	foam_near_texture_b.texture_rd_rid = solver.get_foam_near_tex_rid(1)
	surface_mat.set_shader_parameter("foam_near_a", foam_near_texture_a)
	surface_mat.set_shader_parameter("foam_near_b", foam_near_texture_b)
	surface_mat.set_shader_parameter("foam_domains", solver.foam_field_domains())
	foam_window.bind_ocean(disp_texture, solver.tile_lengths)
	spray.build(disp_texture, norm_texture, solver.tile_lengths, main_camera)
	spray.bind_foam_fields(foam_near_texture_a, foam_near_texture_b)
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
	if derivative_texture != null:
		derivative_texture.texture_rd_rid = RID()
	if foam_near_texture_a != null:
		foam_near_texture_a.texture_rd_rid = RID()
	if foam_near_texture_b != null:
		foam_near_texture_b.texture_rd_rid = RID()
	surface_mat.set_shader_parameter("foam_near_enabled", false)
	spray.release_textures()
	texture_bound = false


## Solver stage timings, under the overlay's frame line.
func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var backend_name := "Tutorial Gerstner" \
		if solver.wave_model == OceanSolver.WaveModel.TUTORIAL_GERSTNER else "JONSWAP/TMA"
	var lines := PackedStringArray(["backend %s | profile %s | VRAM ~%.0f MB" % [
		backend_name, quality_profile_label(),
		solver.estimate_vram_bytes() / 1048576.0]])
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("spectrum"):
		lines.append("  spectrum %.2f | fft %.2f | generate %.2f | feedback %.2f" % [
			t.get("spectrum", 0.0), t.get("fft", 0.0), t.get("assemble", 0.0),
			t.get("foam", 0.0),
		])
	if t.has("foam_near") or t.has("query"):
		lines.append("  foam_near %.2f | query %.2f ms" % [
			t.get("foam_near", 0.0), t.get("query", 0.0)])
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
	var water_height := _camera_water.x if _camera_water_valid else 0.0
	var timings := solver.get_timings()
	var simulation_gpu := _median(_profile_simulation_samples,
		timings.get("total", 0.0))
	var simulation_gpu_p95 := _percentile(_profile_simulation_samples, 0.95,
		timings.get("total", 0.0))
	var foam_gpu := _median(_profile_foam_samples,
		timings.get("foam", 0.0) + timings.get("foam_near", 0.0))
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
	var backend_name := "Tutorial Gerstner" \
		if solver.wave_model == OceanSolver.WaveModel.TUTORIAL_GERSTNER else "JONSWAP/TMA"
	return "CAPTURE META backend=%s profile=%s vram_mb=%.1f look=%s preset=%s view=%s frame=%d time=%.6f fixed_dt=%.6f wind=%.6f sun_elevation=%.3f sun_azimuth=%.3f camera=%s water=%.3f sim_gpu=%.3f sim_gpu_p95=%.3f foam_gpu=%.3f foam_gpu_p95=%.3f foam_near_gpu=%.3f query_gpu=%.3f interaction_capture_gpu=%.3f interaction_feedback_gpu=%.3f cloud_gpu=%.3f cloud_gpu_p95=%.3f viewport_gpu=%.3f viewport_gpu_p95=%.3f cloud_cov=%.4f path=%s" % [
		backend_name, quality_profile_label(),
		solver.estimate_vram_bytes() / 1048576.0,
		(LOOKS[current_look_index] as OceanLookPreset).display_name,
		(PRESETS[current_preset_index] as OceanPreset).display_name,
		_capture_view_name, solver._frame, _sim_time, _capture_fixed_delta,
		solver.wind_direction, sun_elevation, sun_azimuth, position, water_height,
		simulation_gpu, simulation_gpu_p95, foam_gpu, foam_gpu_p95,
		timings.get("foam_near", 0.0), timings.get("query", 0.0),
		interaction_capture_gpu, interaction_feedback_gpu, cloud_gpu, cloud_gpu_p95,
		viewport_gpu, viewport_gpu_p95, cloud_coverage, path,
	]


func capture_metadata_async(path: String) -> String:
	await RenderingServer.frame_post_draw
	var profiling_was_enabled := solver.profiling
	var capture_profiling_was_enabled := _capture_profiling
	solver.profiling = false
	_capture_profiling = false
	var state := solver.foam_state()
	var fields: Array[Dictionary] = []
	for layer in 3:
		var data := await _capture_readback(solver.get_foam_near_read_tex_rid(), layer)
		var expected := 0
		var size := solver.foam_near_size
		while size > 0:
			expected += size * size * 8
			size /= 2
		if data.size() != expected:
			_restore_capture_profile_state(profiling_was_enabled,
				capture_profiling_was_enabled)
			_capture_fail("foam field %d has %d bytes, expected %d" % [layer, data.size(), expected])
			return "CAPTURE FAIL incomplete foam readback"
		var values := data.slice(0, solver.foam_near_size * solver.foam_near_size * 8).to_float32_array()
		var persistent := 0.0
		var fresh := 0.0
		var covered := 0
		var maximum := 0.0
		for i in range(0, values.size(), 2):
			if not is_finite(values[i]) or not is_finite(values[i + 1]):
				_restore_capture_profile_state(profiling_was_enabled,
					capture_profiling_was_enabled)
				_capture_fail("non-finite foam field %d" % layer)
				return "CAPTURE FAIL non-finite foam"
			persistent += values[i]
			fresh += values[i + 1]
			maximum = maxf(maximum, maxf(values[i], values[i + 1]))
			if maxf(values[i], values[i + 1]) > OceanConfig.MEASURE_FOAM_THRESHOLD:
				covered += 1
		var count := values.size() / 2
		fields.append({"layer": layer, "domain_m": solver.foam_field_domains()[layer],
			"texel_m": solver.foam_field_domains()[layer] / solver.foam_near_size,
			"persistent_mean": persistent / count, "fresh_mean": fresh / count,
			"coverage": float(covered) / count, "maximum": maximum})
	var rings := await _capture_foam_rings()
	var waves := await _capture_wave_metrics()
	_restore_capture_profile_state(profiling_was_enabled, capture_profiling_was_enabled)
	print("CAPTURE FOAM_FIELDS %s" % JSON.stringify(fields))
	print("CAPTURE FOAM_PIXELS %s" % JSON.stringify(rings))
	print("CAPTURE WAVES %s" % JSON.stringify(waves))
	return "%s state_time=%.6f state_step=%d seed=1000,31337 measure_version=%d" % [
		capture_metadata(path), state.time, state.step, OceanConfig.MEASURE_VERSION]


func _capture_wave_metrics() -> Dictionary:
	var displacement: Array[PackedFloat32Array] = []
	var derivative: Array[PackedFloat32Array] = []
	for layer in 3:
		for kind in 2:
			var rid := solver.get_displacement_tex_rid() if kind == 0 else solver.get_derivative_tex_rid()
			var data := await _capture_readback(rid, layer)
			if data.size() != solver.map_size * solver.map_size * 8:
				_capture_fail("incomplete wave field readback")
				return {}
			var image := Image.create_from_data(solver.map_size, solver.map_size, false, Image.FORMAT_RGBAH, data)
			image.convert(Image.FORMAT_RGBAF)
			if kind == 0:
				displacement.append(image.get_data().to_float32_array())
			else:
				derivative.append(image.get_data().to_float32_array())
	var metrics: Dictionary = preload("res://scripts/ocean/ocean_capture_metrics.gd").measure(
		displacement, derivative, solver.map_size, solver.tile_lengths, clampf(solver.whitecap, 0.05, 0.95))
	metrics["spectral_references"] = solver.spectral_references()
	if metrics.has("error"):
		_capture_fail(metrics.error)
	return metrics


func _restore_capture_profile_state(profiling_was_enabled: bool,
		capture_profiling_was_enabled: bool) -> void:
	solver.profiling = profiling_was_enabled
	_capture_profiling = capture_profiling_was_enabled


func _capture_foam_rings() -> Array[Dictionary]:
	var old_debug := _capture_debug_view
	var original := world_env.environment
	var measurement: Environment = original.duplicate()
	measurement.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	measurement.tonemap_exposure = 1.0
	measurement.glow_enabled = false
	measurement.adjustment_enabled = false
	measurement.fog_enabled = false
	measurement.volumetric_fog_enabled = false
	measurement.background_mode = Environment.BG_COLOR
	measurement.background_color = Color.BLACK
	world_env.environment = measurement
	_capture_measurement = true
	var tint_visible := underwater_tint.visible
	underwater_tint.hide()
	set_capture_debug(8)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var rings: Array[Dictionary] = []
	var edges := [0.0, 50.0, 150.0, 500.0, 1500.0]
	for i in 4:
		rings.append({"from_m": edges[i], "to_m": edges[i + 1], "pixels": 0,
			"coverage_sum": 0.0, "active_pixels": 0})
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y).srgb_to_linear()
			if pixel.b < 0.98:
				continue
			var distance := pixel.g * 2000.0
			for ring in rings:
				if distance >= ring.from_m and distance < ring.to_m:
					ring.pixels += 1
					ring.coverage_sum += pixel.r
					if pixel.r > OceanConfig.MEASURE_FOAM_THRESHOLD:
						ring.active_pixels += 1
					break
	for ring in rings:
		ring["mean_coverage"] = ring.coverage_sum / ring.pixels if ring.pixels > 0 else -1.0
		ring["active_fraction"] = float(ring.active_pixels) / ring.pixels if ring.pixels > 0 else -1.0
		ring.erase("coverage_sum")
	world_env.environment = original
	_capture_measurement = false
	underwater_tint.visible = tint_visible
	set_capture_debug(old_debug)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return rings


func _capture_fail(message: String) -> void:
	push_error("CAPTURE FAIL: " + message)
	get_tree().quit(1)


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
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if state.done:
			return state.data
	_capture_fail("GPU readback timed out")
	return PackedByteArray()


func _store_capture_readback(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true


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
	_viewport.set_measure_render_time(on)


func set_capture_foam(enabled: bool) -> void:
	solver.foam_feedback_enabled = enabled
	foam_window.set_enabled(enabled and _capture_interaction_foam)
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
	foam_window.set_enabled(enabled)


func set_render_features(on: bool) -> void:
	cloudscape.set_enabled(on)
	storm.set_render_features(on)
	surface_mat.set_shader_parameter("cloud_reflection_enabled", on)
	var look: OceanLookPreset = LOOKS[current_look_index]
	surface_mat.set_shader_parameter("micro_normal_strength",
		look.micro_normal_strength if on else 0.0)
	surface_mat.set_shader_parameter("sky_reflection_strength",
		look.sky_reflection_strength if on else 0.0)
	surface_mat.set_shader_parameter("sun_glitter_strength",
		look.sun_glitter_strength if on else 0.0)


func set_clouds_enabled(on: bool) -> void:
	cloudscape.set_enabled(on)
	surface_mat.set_shader_parameter("cloud_reflection_enabled", on)


func set_capture_rain(enabled: bool) -> void:
	storm.set_capture_rain(enabled)


func set_capture_spray(enabled: bool) -> void:
	spray.set_enabled(enabled)


func _collect_profile_sample() -> void:
	if not _capture_profiling:
		return
	var simulation: float = solver.get_timings().get("total", 0.0)
	var foam: float = solver.get_timings().get("foam", 0.0) \
		+ solver.get_timings().get("foam_near", 0.0)
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


## Camera vs water surface, from the cached GPU point query (choppy xz already
## inverted on the GPU, so the height matches the rendered crest above us).
func _update_underwater(cam_pos: Vector3) -> void:
	var below := _camera_water_valid and cam_pos.y < _camera_water.x
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
