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
const FOAM_TEXTURES := [
	{"name": "1 - Airy bubbles", "path": "res://resources/ocean/foam_variant_01_microbubbles.png"},
	{"name": "2 - Dense froth", "path": "res://resources/ocean/foam_variant_02_dense_froth.png"},
	{"name": "3 - Filaments", "path": "res://resources/ocean/foam_variant_03_flowing_filaments.png"},
	{"name": "4 - Torn patches", "path": "res://resources/ocean/foam_variant_04_torn_patches.png"},
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
var coast_texture: Texture2DRD
var wake_texture: Texture2DRD
var shore_texture: Texture2DRD
var shore_foam_texture: Texture2DRD
var shore_breaker_texture: Texture2DRD
var shore_contact_texture: Texture2DRD
var island: OceanIsland
var current_scene_index := 0
var texture_bound := false
var _allocated_foam_near_size := 0
var _allocated_physical_tier := -1
var time_scale := 1.0
var sun_elevation := 32.0
var sun_azimuth := 140.0
var current_preset_index := 1
var current_look_index := 0
var current_foam_texture_index := 0
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
var _profiling := OceanProfiling.new()
var _capture := OceanCapture.new()
var _capture_interaction_foam := true
var _capture_debug_view := 0
var _capture_fixed_delta := -1.0
var _capture_view_name := ""
# GPU point queries: crate -> first result slot as submitted last physics tick,
# the camera slot (or -1 when no camera existed at submission time), and the
# camera slot's (height, nx, nz, valid) for underwater/capture reads.
var _query_snapshots: Dictionary = {}
var _water_frames: Dictionary = {}
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

	LoadingPump.stage("Applying quality profile")
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
	_viewport.set_screen_space_aa(Viewport.SCREEN_SPACE_AA_FXAA)

	LoadingPump.stage("Building sky")
	_setup_sky()
	LoadingPump.tick()
	LoadingPump.stage("Building ocean mesh")
	_setup_ocean_mesh()
	LoadingPump.tick()
	LoadingPump.stage("Building clouds")
	cloudscape.camera = main_camera
	cloudscape.sun = sun
	add_child(cloudscape)
	cloudscape.build()
	LoadingPump.tick()
	surface_mat.set_shader_parameter("cloud_reflection", cloudscape.reflection_texture())

	LoadingPump.stage("Building storm effects")
	storm.sun = sun
	storm.world_env = world_env
	storm.sky_material = sky_material
	storm.cloudscape = cloudscape
	storm.overlay_layer = underwater_layer
	storm.build(self)
	LoadingPump.tick()
	LoadingPump.stage("Building foam and spray")
	add_child(foam_window)
	foam_window.build(surface_mat, main_camera, rocks)
	foam_window.set_enabled(true)
	add_child(spray)
	spray.set_enabled(true)

	_profiling.setup(solver, spray, foam_window, cloudscape, quality,
		get_viewport().get_viewport_rid(), _viewport)
	_capture.setup(solver, _profiling, cloudscape, get_tree(), get_viewport(),
		world_env, ocean_mesh, underwater_tint)
	profiler.lines_provider = _profiling.overlay_lines
	profiler.enabled_changed.connect(_profiling.set_overlay_enabled)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)

	LoadingPump.stage("Building menu")
	_setup_ui()
	LoadingPump.stage("Applying look")
	apply_look(0)
	LoadingPump.stage("Applying sea state")
	apply_preset(1)
	set_scene_mode(int(GameManager.get_setting("ocean_scene_mode", 0)), false)
	LoadingPump.stage("Initializing wave solver (GPU)")
	RenderingServer.call_on_render_thread(solver.init_render)


func _exit_tree() -> void:
	_capture.stop()
	profiler.lines_provider = Callable()
	if profiler.enabled_changed.is_connected(_profiling.set_overlay_enabled):
		profiler.enabled_changed.disconnect(_profiling.set_overlay_enabled)
	_profiling.stop()
	_release_textures()
	for helper in [foam_window, spray, cloudscape]:
		if helper.get_parent() == null:
			helper.free()
	var retired_solver := solver
	RenderingServer.call_on_render_thread(func(): retired_solver.free_render())


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
	var local_centers: Vector4 = solver.local_centers()
	surface_mat.set_shader_parameter("local_centers", local_centers)
	surface_mat.set_shader_parameter("local_domains",
		Vector2(OceanLocalSolver.COAST_DOMAIN_M, OceanLocalSolver.WAKE_DOMAIN_M))
	var simulation_delta := _capture_fixed_delta if _capture_fixed_delta > 0.0 else delta
	var step_scale := 0.0 if _frozen else time_scale
	if not _warmup_active:
		_sim_time += simulation_delta * step_scale
	solver.sim_time = _sim_time
	surface_mat.set_shader_parameter("sim_time", _sim_time)
	surface_mat.set_shader_parameter("foam_feedback_enabled",
		solver.foam_feedback_enabled and solver.foam_amount > 0.0)
	if island != null:
		island.set_foam_enabled(solver.foam_feedback_enabled and solver.foam_amount > 0.0)
		island.set_foam_amount(solver.foam_amount)

	var cam := get_viewport().get_camera_3d()
	if not _capture.measurement_active:
		storm.update(simulation_delta, cam, simulation_delta * step_scale)

	# World-space UVs anchor the wave field to the world. Continuous recentering
	# avoids a whole clipmap lattice changing triangles on the same frame.
	if cam != null:
		var p := cam.global_position
		ocean_mesh.global_position = Vector3(p.x, 0.0, p.z)
		solver.near_center = Vector2(p.x, p.z)
		_update_underwater(p)
		foam_window.update(simulation_delta * step_scale, p)
		surface_mat.set_shader_parameter("storm_mood", storm.current_mood())
		surface_mat.set_shader_parameter("sky_zenith", sky_material.get_shader_parameter("zenith_color"))
		surface_mat.set_shader_parameter("sky_horizon", sky_material.get_shader_parameter("horizon_color"))
		_sync_island_reflection()
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
		RenderingServer.call_on_render_thread(_render_step.bind(
			simulation_delta * step_scale, _sim_time, solver.near_center))
	profiler.poll(delta)
	_profiling.collect_sample()


func _render_step(delta: float, time_s: float, center: Vector2) -> void:
	solver.step_render(delta, time_s, center)
	if solver.initialized and solver.physical_features_enabled:
		var state := solver.foam_state()
		var rd := RenderingServer.get_rendering_device()
		if solver.profiling:
			rd.capture_timestamp("ocean_spray/start")
		spray.step_render(delta, time_s, center,
			Vector2(cos(solver.wind_direction), sin(solver.wind_direction)) * solver.wind_speed,
			solver.current_velocity_m_s, state.center, solver.foam_field_domains(),
			state.index, solver.whitecap, solver.local_centers(), solver.shore_enabled, solver.shore_solver.config.domain_m,
			solver.shore_solver.config.visual_breakers_enabled)
		if solver.profiling:
			rd.capture_timestamp("ocean_spray/end")


## Physics ticks ride the GPU: apply last tick's query results (one frame of
## latency, never blocking), then submit this tick's probes — the camera first,
## then the four buoyancy corners of every crate (33 points worst case).
func _physics_process(_delta: float) -> void:
	if not solver.initialized:
		return
	var batch := solver.take_query_batch()
	if batch != null:
		_consume_query_results(batch)
	for crate in _crates:
		if not is_instance_valid(crate):
			continue
		var frame: Dictionary = _water_frames.get(crate.get_instance_id(), {})
		if frame.is_empty() or Time.get_ticks_msec() - frame.time_msec > 1000:
			solver.set_body_pressure(crate.get_instance_id(), Vector2.ZERO, 0.0)
			continue
		var depths: PackedFloat32Array = frame.depths.duplicate()
		var elapsed := clampf(_sim_time - float(frame.simulation_time_s), 0.0, 0.25)
		for i in depths.size():
			depths[i] += frame.velocities[i].dot(frame.normal) \
				/ maxf(frame.normal.y, 0.001) * elapsed
		crate.apply_water_frame(depths, frame.normal, frame.valid_mask,
			frame.velocities, frame.positions, _delta)
		solver.set_body_pressure(crate.get_instance_id(),
			Vector2(crate.global_position.x, crate.global_position.z),
			crate.last_support_force_n.y if solver.physical_features_enabled else 0.0)
		if solver.physical_features_enabled and not crate.last_water_impulse.is_zero_approx():
			solver.add_wake_impulse(crate.get_instance_id(),
				Vector2(crate.global_position.x, crate.global_position.z),
				Vector2(crate.last_water_impulse.x, crate.last_water_impulse.z))
	var points := PackedVector2Array()
	var slots: Array = []
	var camera_slot := -1
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		camera_slot = points.size()
		points.append(Vector2(cam.global_position.x, cam.global_position.z))
	for crate in _crates:
		if not is_instance_valid(crate):
			continue
		var positions := PackedVector3Array()
		var first_slot := points.size()
		for probe in OceanBuoy.PROBES:
			var wp := crate.global_transform * probe
			positions.append(wp)
			points.append(Vector2(wp.x, wp.z))
		slots.append({"owner": weakref(crate), "slot": first_slot, "positions": positions})
	var id := solver.submit_queries(points)
	_query_snapshots[id] = {"camera_slot": camera_slot, "crates": slots}
	for replaced_id in solver.take_replaced_query_ids():
		_query_snapshots.erase(replaced_id)
	if _frozen or is_zero_approx(time_scale):
		RenderingServer.call_on_render_thread(solver.query_render)


func _consume_query_results(batch: OceanQueryBatch) -> void:
	var snapshot: Dictionary = _query_snapshots.get(batch.id, {})
	_query_snapshots.erase(batch.id)
	var results := batch.results
	if results.is_empty() or snapshot.is_empty():
		return
	var camera_slot: int = snapshot.camera_slot
	if camera_slot >= 0 and camera_slot < results.size() \
			and results[camera_slot].w > 0.5:
		_camera_water = results[camera_slot]
		_camera_water_valid = true
	else:
		_camera_water_valid = false
	for entry in snapshot.crates:
		var crate: OceanBuoy = entry.owner.get_ref()
		var slot: int = entry.slot
		if not is_instance_valid(crate) \
				or slot + OceanBuoy.PROBES.size() > results.size():
			continue
		var depths := PackedFloat32Array()
		var valid_mask := PackedByteArray()
		var velocities := PackedVector3Array()
		var normal := Vector3.ZERO
		for i in OceanBuoy.PROBES.size():
			var r := results[slot + i]
			depths.append(r.x - entry.positions[i].y if r.w > 0.5 else 0.0)
			valid_mask.append(1 if r.w > 0.5 else 0)
			velocities.append(batch.velocities[slot + i] if slot + i < batch.velocities.size()
				else Vector3.ZERO)
			if r.w > 0.5:
				normal += Vector3(-r.y, 1.0, -r.z)
		if normal.length_squared() > 0.0:
			normal = normal.normalized()
		else:
			normal = Vector3.UP
		_water_frames[crate.get_instance_id()] = {"depths": depths, "normal": normal,
			"valid_mask": valid_mask, "velocities": velocities, "positions": entry.positions,
			"time_msec": Time.get_ticks_msec(), "simulation_time_s": batch.simulation_time_s}


func apply_preset(index: int) -> void:
	if index < 0 or index >= PRESETS.size():
		return
	if apply_sea_state(PRESETS[index]):
		current_preset_index = index


func apply_sea_state(preset: OceanPreset) -> bool:
	var error := preset.validate()
	if error != "":
		push_error("Ocean preset '%s': %s" % [preset.display_name, error])
		return false
	# Sliders first, preset second: the panel shows the preset, the solver gets
	# the unquantised values rather than whatever the sliders snapped to.
	_menu_builder.sync_to_preset(preset)
	preset.apply_to(solver)
	solver.mark_spectrum_dirty()
	_sync_wave_filter_uniforms()
	_sync_foam_material_strength()
	set_spray_amount(preset.spray_amount)
	set_storm_mood(preset.storm_mood)
	return true


func _sync_foam_material_strength() -> void:
	if surface_mat == null:
		return
	# The panel slider owns "foam_strength" once the user touches it; until then
	# presets drive the derived value (docs/ocean_foam_injection_fix.md §5.3).
	var derived := 1.0
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
	if _capture_view_name.begins_with("island_"):
		set_scene_mode(1, false)
		_apply_island_camera(_capture_view_name)
		orbit_cam.set_enabled(false)
		return
	if _capture_view_name == "beach_reference":
		set_scene_mode(0, false)
		var reference := OceanIsland.new()
		var framing := reference.camera_view("island_beach")
		reference.free()
		orbit_cam.target = framing.target
		orbit_cam.distance = framing.distance
		orbit_cam.pitch = framing.pitch
		orbit_cam.yaw = framing.yaw
		orbit_cam.set_enabled(false)
		orbit_cam.call_deferred("_update_transform")
		rocks.visible = false
		return
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
		"coast":
			rocks.visible = true
			orbit_cam.target = Vector3(OceanLocalSolver.COAST_CENTER.x, 0.8, OceanLocalSolver.COAST_CENTER.y)
			orbit_cam.distance = 45.0
			orbit_cam.pitch = -32.0
			orbit_cam.yaw = 35.0
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
		RenderingServer.call_on_render_thread(_render_step.bind(step_delta, _sim_time, solver.near_center))
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
	solver.foam_near_size = solver.shore_solver.config.foam_texture_size_px(quality.effective, values.foam_near_size)
	if _menu_builder.sync_foam_distance(values.foam_near_distance):
		solver.set_foam_distance(values.foam_near_distance)
	if _menu_builder.sync_detail_distance(values.detail_distance_m):
		set_detail_distance(values.detail_distance_m)
	solver.quality_tier = quality.effective
	if surface_mat != null:
		surface_mat.set_shader_parameter("ultra_detail", values.surface_detail)
	_menu_builder.sync_foam_layout()


## Profile switch: keep existing GPU resources when the texture sizes match.
func _rebuild_quality_resources(force: bool = false) -> void:
	var target_map_size: int = OceanQualityProfile.FFT_SIZE[quality.effective]
	if not force and solver.initialized and solver.map_size == target_map_size \
			and _allocated_foam_near_size == solver.foam_near_size \
			and _allocated_physical_tier == quality.effective:
		return
	if solver.shore_enabled and island != null:
		solver.shore_bathymetry = island.create_bathymetry(
			solver.shore_solver.config.resolution_cells(quality.effective), solver.shore_solver.config.domain_m)
	solver.initialized = false
	_capture.invalidate()
	_release_textures()
	RenderingServer.call_on_render_thread(spray.free_render)
	RenderingServer.call_on_render_thread(solver.free_render)
	solver.map_size = target_map_size
	_allocated_foam_near_size = solver.foam_near_size
	RenderingServer.call_on_render_thread(solver.init_render)


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


func set_scene_mode(index: int, persist: bool = true) -> void:
	index = clampi(index, 0, 1)
	if index == current_scene_index:
		return
	clear_crates()
	_query_snapshots.clear()
	_camera_water_valid = false
	current_scene_index = index
	solver.shore_enabled = index == 1
	solver.shore_solver.config.visual_breakers_enabled = solver.shore_enabled
	solver.foam_near_size = solver.shore_solver.config.foam_texture_size_px(
		quality.effective, OceanQualityProfile.FOAM_NEAR_SIZE[quality.effective])
	if solver.shore_enabled:
		solver.shore_solver.config.foam_retention_s = 1.5
		solver.shore_solver.config.contact_retention_s = 2.5
		island = OceanIsland.new()
		island.name = "Island"
		add_child(island)
		solver.shore_bathymetry = island.create_bathymetry(
			solver.shore_solver.config.resolution_cells(quality.effective), solver.shore_solver.config.domain_m)
		_apply_island_camera("island_overview")
	else:
		solver.shore_bathymetry = PackedFloat32Array()
		if island != null:
			island.queue_free()
			island = null
		orbit_cam.target = Vector3(0.0, 1.8, 0.0)
		orbit_cam.distance = 50.0
		orbit_cam.pitch = -1.0
		orbit_cam.yaw = 0.0
		orbit_cam.call_deferred("_update_transform")
	rocks.visible = index == 0
	foam_window.set_enabled(index == 0 and solver.foam_feedback_enabled
		and _capture_interaction_foam)
	_menu_builder.sync_scene_mode(index)
	surface_mat.set_shader_parameter("shore_enabled", false)
	if persist:
		GameManager.set_setting("ocean_scene_mode", index)
	if solver.initialized or texture_bound:
		_rebuild_quality_resources(true)


func set_capture_scene(index: int) -> void:
	set_scene_mode(index, false)


func set_capture_params(values: Dictionary) -> void:
	if values.has("swell_height_m"):
		solver.swell_height_m = clampf(float(values.swell_height_m), 0.0, 12.0)
		solver.mark_spectrum_dirty()
	if values.has("water_depth"):
		solver.water_depth = clampf(float(values.water_depth), 0.01, 1000.0)
		solver.mark_spectrum_dirty()
	if values.has("foam_texture"):
		set_foam_texture(int(values.foam_texture))


func set_foam_texture(index: int) -> void:
	current_foam_texture_index = clampi(index, 0, FOAM_TEXTURES.size() - 1)
	if surface_mat != null:
		surface_mat.set_shader_parameter("foam_pattern",
			load(FOAM_TEXTURES[current_foam_texture_index].path))
	_menu_builder.sync_foam_texture(current_foam_texture_index)


func _apply_island_camera(view: String) -> void:
	if island == null:
		return
	var framing := island.camera_view(view)
	if framing.is_empty():
		return
	orbit_cam.target = framing.target
	orbit_cam.distance = framing.distance
	orbit_cam.pitch = framing.pitch
	orbit_cam.yaw = framing.yaw
	orbit_cam.call_deferred("_update_transform")


func quality_profile_label() -> String:
	return quality.label()


## Tossed from the camera; the physics tick submits its probes as GPU point
## queries, so crates ride exactly the surface that is rendered.
func throw_crate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var crate := OceanBuoy.new()
	crate.physical_model_enabled = solver.physical_features_enabled
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
		var retired_crate: OceanBuoy = _crates.pop_front()
		_water_frames.erase(retired_crate.get_instance_id())
		solver.set_body_pressure(retired_crate.get_instance_id(), Vector2.ZERO, 0.0)
		retired_crate.queue_free()


func clear_crates() -> void:
	for crate in _crates:
		if is_instance_valid(crate):
			solver.set_body_pressure(crate.get_instance_id(), Vector2.ZERO, 0.0)
			crate.queue_free()
	_crates.clear()
	_water_frames.clear()


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
	set_foam_texture(current_foam_texture_index)
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
	coast_texture = Texture2DRD.new()
	coast_texture.texture_rd_rid = solver.local_solver.get_coast_texture_rid()
	wake_texture = Texture2DRD.new()
	wake_texture.texture_rd_rid = solver.local_solver.get_wake_texture_rid()
	surface_mat.set_shader_parameter("coast_field", coast_texture)
	surface_mat.set_shader_parameter("wake_field", wake_texture)
	surface_mat.set_shader_parameter("local_waves_enabled", solver.physical_features_enabled)
	shore_texture = Texture2DRD.new()
	shore_texture.texture_rd_rid = solver.get_shore_texture_rid()
	shore_foam_texture = Texture2DRD.new()
	shore_foam_texture.texture_rd_rid = solver.get_shore_foam_texture_rid()
	shore_breaker_texture = Texture2DRD.new()
	shore_breaker_texture.texture_rd_rid = solver.get_shore_breaker_texture_rid()
	shore_contact_texture = Texture2DRD.new()
	shore_contact_texture.texture_rd_rid = solver.get_shore_contact_texture_rid()
	surface_mat.set_shader_parameter("shore_field", shore_texture)
	surface_mat.set_shader_parameter("shore_foam", shore_foam_texture)
	surface_mat.set_shader_parameter("shore_breaker", shore_breaker_texture)
	surface_mat.set_shader_parameter("shore_contact", shore_contact_texture)
	surface_mat.set_shader_parameter("shore_enabled", solver.shore_enabled)
	surface_mat.set_shader_parameter("shore_domain", solver.shore_solver.config.domain_m)
	surface_mat.set_shader_parameter("shore_blend_width_m", solver.shore_solver.config.surface_blend_width_m())
	surface_mat.set_shader_parameter("shore_depth_blend_m", solver.shore_solver.config.surface_depth_blend_m())
	surface_mat.set_shader_parameter("shore_visual_breakers_enabled", solver.shore_enabled
		and solver.shore_solver.config.visual_breakers_enabled)
	if island != null:
		island.bind_shore(shore_texture, shore_foam_texture, solver.shore_solver.config.domain_m,
			shore_contact_texture, shore_breaker_texture)
		_sync_island_reflection()
	foam_window.bind_ocean(disp_texture, solver.tile_lengths)
	spray.build(disp_texture, norm_texture, solver.tile_lengths, main_camera)
	spray.bind_foam_fields(foam_near_texture_a, foam_near_texture_b)
	spray.set_sun_direction(sun.global_transform.basis.z.normalized())
	_allocated_physical_tier = quality.effective
	_allocated_foam_near_size = solver.foam_near_size
	RenderingServer.call_on_render_thread(_init_spray_render)
	texture_bound = true


func _sync_island_reflection() -> void:
	if island == null:
		return
	for parameter in ["sky_zenith", "sky_horizon", "cloud_reflection", "cloud_reflection_enabled"]:
		island.terrain_material.set_shader_parameter(parameter, surface_mat.get_shader_parameter(parameter))
	island.terrain_material.set_shader_parameter("sky_energy", sky_material.get_shader_parameter("energy"))


func _init_spray_render() -> void:
	spray.init_render(solver.get_displacement_tex_rid(), solver.get_derivative_tex_rid(),
		solver.get_foam_near_tex_rid(0), solver.get_foam_near_tex_rid(1),
		solver.velocity_solver.get_texture_rid(), solver.map_size, solver.tile_lengths,
		OceanQualityProfile.SPRAY_CAPACITY[quality.effective],
		solver.local_solver.get_coast_texture_rid(), solver.local_solver.get_wake_texture_rid(),
		solver.get_shore_texture_rid(), solver.get_shore_foam_texture_rid(),
		solver.get_shore_derivative_texture_rid(), solver.get_breaking_settings_rid(), solver.shore_solver.config,
		solver.get_shore_breaker_texture_rid(), solver.get_shore_contact_texture_rid())
	spray.set_physical_enabled(solver.physical_features_enabled)


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
	if coast_texture != null:
		coast_texture.texture_rd_rid = RID()
	if wake_texture != null:
		wake_texture.texture_rd_rid = RID()
	if shore_texture != null:
		shore_texture.texture_rd_rid = RID()
	if shore_foam_texture != null:
		shore_foam_texture.texture_rd_rid = RID()
	for texture: Texture2DRD in [shore_breaker_texture, shore_contact_texture]:
		if texture != null:
			texture.texture_rd_rid = RID()
	if surface_mat != null:
		surface_mat.set_shader_parameter("shore_enabled", false)
		surface_mat.set_shader_parameter("foam_near_enabled", false)
	spray.release_textures()
	texture_bound = false


func _capture_metadata_context() -> OceanCapture.Metadata:
	var context := OceanCapture.Metadata.new()
	context.look = (LOOKS[current_look_index] as OceanLookPreset).display_name
	context.preset = (PRESETS[current_preset_index] as OceanPreset).display_name
	context.view = _capture_view_name
	context.simulation_time = _sim_time
	context.fixed_delta = _capture_fixed_delta
	context.sun_elevation = sun_elevation
	context.sun_azimuth = sun_azimuth
	context.water_height = _camera_water.x if _camera_water_valid else 0.0
	return context


func capture_metadata(path: String) -> String:
	return _capture.metadata(path, _capture_metadata_context())


func capture_metadata_async(path: String) -> String:
	return await _capture.metadata_async(path, _capture_metadata_context)


func capture_foam_rings() -> Array[Dictionary]:
	return await _capture.foam_rings()


func capture_image_metrics(image: Image) -> String:
	return OceanCapture.image_metrics(image, _capture_debug_view)


func capture_orientation_coherence(image: Image) -> float:
	return OceanCapture.orientation_coherence(image)


func capture_banding_fraction(image: Image) -> float:
	return OceanCapture.banding_fraction(image)


func capture_water_coverage(image: Image) -> float:
	return OceanCapture.water_coverage(image, _capture_debug_view)


func capture_ready() -> bool:
	return solver.initialized and texture_bound


func set_capture_profiling(on: bool) -> void:
	_profiling.set_capture_enabled(on)


func set_capture_foam(enabled: bool) -> void:
	solver.foam_feedback_enabled = enabled
	foam_window.set_enabled(enabled and _capture_interaction_foam and current_scene_index == 0)
	if surface_mat != null:
		surface_mat.set_shader_parameter("foam_feedback_enabled", enabled)
	if island != null:
		island.set_foam_enabled(enabled and solver.foam_amount > 0.0)


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
	foam_window.set_enabled(enabled and current_scene_index == 0)


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


## Camera vs water surface, from the cached GPU point query (choppy xz already
## inverted on the GPU, so the height matches the rendered crest above us).
func _update_underwater(cam_pos: Vector3) -> void:
	var below := _camera_water_valid and cam_pos.y < _camera_water.x
	if below == _underwater:
		return
	_underwater = below
	storm.underwater = below
	underwater_tint.visible = below and not _capture.measurement_active
	# Single source of truth: the surface shader picks its interface side from
	# this, so the overlay and the water shading can never disagree.
	surface_mat.set_shader_parameter("camera_underwater", below)
	world_env.environment.fog_density = 0.03 if below else storm.surface_fog_density
	world_env.environment.fog_light_color = \
		Color(0.05, 0.19, 0.24) if below else storm.surface_fog_color
	_capture.preserve_underwater_state(below, world_env.environment.fog_density,
		world_env.environment.fog_light_color)
