extends Node3D

const PRESETS: Array[SmokePreset] = [
	preload("res://resources/smoke/presets/smoke_flares.tres"),
	preload("res://resources/smoke/presets/sunset_stacks.tres"),
	preload("res://resources/smoke/presets/vortex_cannon.tres"),
	preload("res://resources/smoke/presets/wind_tunnel.tres"),
	preload("res://resources/smoke/presets/concert_stage.tres"),
]
const RAYS_PER_AXIS := 2
const FLARE_FLIGHT_S := 1.2
const VirtualJoystickScript := preload("res://scripts/ui/virtual_joystick.gd")

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var torch: SpotLight3D = $CameraPivot/Camera3D/Torch
@onready var sun: DirectionalLight3D = $Sun
@onready var world: WorldEnvironment = $WorldEnvironment
@onready var volume: SmokeRenderer = $SmokeVolume
@onready var props: SmokeProps = $Props
@onready var _viewport := ViewportGuard.attach(self)

var solver := SmokeSolver.new()
var quality := SimQualityState.new()
var pointer := SmokePointer.new()
var profiler := SimProfiler.new()
var smoke_menu := SmokeMenu.new()
var preset_idx := 0
var paused := false
var emitters_on := true
var rate_scale := 1.0
var heat_scale := 1.0
var speed_scale := 1.0
var time_scale := 1.0
var sun_elevation_deg := 35.0
var sun_azimuth_deg := 0.0
var _time := 0.0
var _action_s := -INF
var _clock := SimStepClock.new()
var _rebuild_pending := false
var _capture_dt := -1.0


func _ready() -> void:
	# No RenderingDevice means every dispatch silently no-ops: say so instead of a
	# black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return
	_clock.max_quanta_per_frame = 2
	preset_idx = clampi(int(menu.stored_value("Scene", "Preset", 0)), 0, PRESETS.size() - 1)
	solver.config = PRESETS[preset_idx].config.duplicate()
	quality.setup(SmokeQualityProfile, "smoke_quality_profile", _apply_quality)
	if VirtualJoystickScript.is_touch_ui():
		quality.fallback_tier = SmokeQualityProfile.Tier.LOW
	quality.restore()
	pointer.camera = camera
	pointer.props = props
	add_child(pointer)
	props.shadow_material = volume.shadow_material
	profiler.lines_provider = smoke_menu.profiler_lines.bind(self)
	profiler.enabled_changed.connect(func(on: bool) -> void: solver.profiling = on)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	smoke_menu.build(menu, self, PRESETS)
	apply_preset(preset_idx)


## The boot path and the capture harness (preset=N) both land here.
func apply_preset(index: int) -> void:
	preset_idx = clampi(index, 0, PRESETS.size() - 1)
	var preset := PRESETS[preset_idx]
	var error := preset.validate()
	if error != "":
		push_error("Smoke preset '%s': %s" % [preset.display_name, error])
		return
	solver.config = preset.config.duplicate()
	quality.reapply()
	world.environment = preset.environment
	orbit_cam.target = preset.camera_target_m
	orbit_cam.distance = preset.camera_distance_m
	orbit_cam.pitch = preset.camera_pitch_deg
	orbit_cam.yaw = preset.camera_yaw_deg
	sun.light_color = preset.sun_color
	sun.light_energy = preset.sun_energy
	sun_elevation_deg = preset.sun_elevation_deg
	sun_azimuth_deg = preset.sun_azimuth_deg
	_apply_sun()
	props.build(preset)
	pointer.focus_m = preset.camera_target_m
	smoke_menu.refresh(self, preset)
	_time = 0.0
	_action_s = -INF
	_clock.reset()
	_rebuild()


func _rebuild() -> void:
	_rebuild_pending = false
	volume.release()
	solver.stop()
	var config := solver.config
	_clock.reference_step = 1.0 / config.sim_rate_hz
	solver.set_static_occupancy(SmokeVoxelizer.voxelize(props.static_faces(),
		config.domain_origin_m, config.cell_size_m(), config.grid_dims(), RAYS_PER_AXIS))
	volume.configure(config)
	var error := solver.start()
	if error != "":
		push_error("Smoke: %s" % error)


func _process(delta: float) -> void:
	if _rebuild_pending:
		_rebuild()
		return
	if not solver.is_ready():
		return
	if not volume.is_bound():
		volume.bind(solver)
	var quanta := 0 if paused else _clock.advance(_capture_dt if _capture_dt > 0.0 else delta,
		time_scale)
	_time += quanta * _clock.reference_step
	props.update(_time)
	var emitters: Array[SmokeEmitter] = PRESETS[preset_idx].emitters if emitters_on else []
	solver.set_sources(props.pack_sources(emitters, _time, _action_s, rate_scale, heat_scale,
		speed_scale) + pointer.pack_source())
	solver.set_obstacles(props.pack_obstacles())
	solver.light_direction = sun.global_basis.z
	solver.advance(quanta)
	volume.sync(solver.config, sun.global_basis.z, sun.light_color * sun.light_energy,
		world.environment.ambient_light_color * world.environment.ambient_light_energy)
	var lights: Array[Light3D] = [torch]
	lights.append_array(props.volume_lights())
	volume.set_lights(lights)
	profiler.poll(delta)


func next_preset() -> void:
	apply_preset((preset_idx + 1) % PRESETS.size())


func reset_scene() -> void:
	apply_preset(preset_idx)


func set_paused(on: bool) -> void:
	paused = on


func set_emitters_on(on: bool) -> void:
	emitters_on = on


## Fires the preset's triggered emitters.
func scene_action() -> void:
	_action_s = _time


## Lobbed from the camera to land under the orbit target, inside the smoke domain.
func throw_flare() -> void:
	var origin := camera.global_position - camera.global_basis.z * 0.6
	var landing := Vector3(orbit_cam.target.x, 0.0, orbit_cam.target.z)
	var gravity := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	props.throw_flare(origin, (landing - origin) / FLARE_FLIGHT_S - 0.5 * FLARE_FLIGHT_S * gravity,
		_time)


func set_sun_elevation(degrees: float) -> void:
	sun_elevation_deg = degrees
	_apply_sun()


func set_sun_azimuth(degrees: float) -> void:
	sun_azimuth_deg = degrees
	_apply_sun()


func _apply_sun() -> void:
	sun.rotation = Vector3(deg_to_rad(-sun_elevation_deg), deg_to_rad(sun_azimuth_deg), 0.0)


func render_scale() -> float:
	return _viewport.render_scale()


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func msaa_mode() -> int:
	return _viewport.msaa()


func set_quality_profile(tier: int) -> void:
	quality.set_tier(tier)


## Tier keys land here, from the tier itself or from the widget bound to them.
func set_quality_value(key: String, value: Variant) -> void:
	var config := solver.config
	match key:
		"grid_cell_budget":
			_rebuild_pending = _rebuild_pending or config.grid_cell_budget != int(value)
			config.grid_cell_budget = int(value)
		"light_downsample":
			_rebuild_pending = _rebuild_pending or config.light_downsample != int(value)
			config.light_downsample = int(value)
		"maccormack":
			_rebuild_pending = _rebuild_pending or config.maccormack != bool(value)
			config.maccormack = bool(value)
		"sim_rate_hz":
			config.sim_rate_hz = float(value)
			_clock.reference_step = 1.0 / config.sim_rate_hz
		"pressure_iterations":
			config.pressure_iterations = int(value)
		"march_step_cells":
			config.march_step_cells = float(value)
		"light_step_cells":
			config.light_step_cells = float(value)
		"scene_shadows":
			sun.shadow_enabled = bool(value)
		"msaa":
			_viewport.set_msaa(int(value) as Viewport.MSAA)


func _apply_quality(values: Dictionary) -> void:
	for key in values:
		set_quality_value(key, values[key])


func capture_ready() -> bool:
	return solver.is_ready() and volume.is_bound() and not _rebuild_pending


func set_capture_fixed_delta(dt: float) -> void:
	_capture_dt = dt


## Capture harness (interaction=1): a thrown flare, the torch, and the scene action
## 5 s later, once the scene has filled.
func set_capture_interaction(on: bool) -> void:
	if on:
		_action_s = _time + 5.0
		throw_flare()
		torch.visible = true


func _exit_tree() -> void:
	volume.release()
	solver.stop()
