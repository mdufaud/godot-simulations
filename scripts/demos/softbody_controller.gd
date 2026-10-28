extends Node3D

const PRESETS: Array[SoftBodyPreset] = [
	preload("res://resources/softbody/presets/jelly_drop.tres"),
	preload("res://resources/softbody/presets/bouncy_balls.tres"),
	preload("res://resources/softbody/presets/wobbly_tower.tres"),
	preload("res://resources/softbody/presets/squish_press.tres"),
	preload("res://resources/softbody/presets/rock_rain.tres"),
]
const VirtualJoystickScript := preload("res://scripts/ui/virtual_joystick.gd")
const THROW_SPEED_MPS := 9.0
const DROP_HEIGHT_M := 2.2
const ROCKS_PER_RAIN := 8

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var bodies: SoftBodyRenderer = $SoftBodies
@onready var props: SoftBodyProps = $Props
@onready var _viewport := ViewportGuard.attach(self)

var solver := SoftBodySolver.new()
var quality := SimQualityState.new()
var profiler := SimProfiler.new()
var softbody_menu := SoftBodyMenu.new()
var grab := SoftBodyGrab.new()
var preset_idx := 0
var paused := false
var press_on := false
var _rebuild_pending := false
var _next_drop := 0


func _ready() -> void:
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return
	preset_idx = clampi(int(menu.stored_value("Scene", "Preset", 0)), 0, PRESETS.size() - 1)
	solver.config = PRESETS[preset_idx].config.duplicate()
	quality.setup(SoftBodyQualityProfile, "softbody_quality_profile", _apply_quality)
	if VirtualJoystickScript.is_touch_ui():
		quality.fallback_tier = SoftBodyQualityProfile.Tier.LOW
	quality.restore()
	grab.camera = camera
	grab.solver = solver
	add_child(grab)
	profiler.lines_provider = softbody_menu.profiler_lines.bind(self)
	profiler.enabled_changed.connect(func(on: bool) -> void: solver.profiling = on)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	softbody_menu.build(menu, self, PRESETS)
	apply_preset(preset_idx)


## The boot path and the capture harness (preset=N) both land here.
func apply_preset(index: int) -> void:
	preset_idx = clampi(index, 0, PRESETS.size() - 1)
	var preset := PRESETS[preset_idx]
	var error := preset.validate()
	if error != "":
		push_error("Soft body preset '%s': %s" % [preset.display_name, error])
		return
	solver.config = preset.config.duplicate()
	quality.reapply()
	orbit_cam.target = preset.camera_target_m
	orbit_cam.distance = preset.camera_distance_m
	orbit_cam.pitch = preset.camera_pitch_deg
	orbit_cam.yaw = preset.camera_yaw_deg
	press_on = false
	props.build(preset)
	softbody_menu.refresh(self, preset)
	_rebuild()


func _rebuild() -> void:
	_rebuild_pending = false
	grab.release()
	bodies.release()
	solver.stop()
	solver.clear_bodies()
	var preset := PRESETS[preset_idx]
	for shape in preset.bodies:
		solver.add_body(shape, true)
	while solver.body_count() < solver.config.max_bodies:
		solver.add_body(preset.drop_shape, false)
	_next_drop = preset.bodies.size()
	solver.config.sim_rate_hz = Engine.physics_ticks_per_second
	var error := solver.start()
	if error != "":
		push_error("Soft bodies: %s" % error)
	bodies.build(solver)


func _process(delta: float) -> void:
	if _rebuild_pending:
		_rebuild()
		return
	bodies.sync(solver)
	profiler.poll(delta)


## One solver step per Jolt tick, so both stay in step whatever the frame rate.
func _physics_process(delta: float) -> void:
	if paused or _rebuild_pending or not solver.is_ready():
		return
	props.animate_press(delta, press_on)
	props.apply_reactions(solver.reactions(), delta)
	solver.set_colliders(props.pack_colliders())
	solver.advance(1)


func next_preset() -> void:
	apply_preset((preset_idx + 1) % PRESETS.size())


func reset_scene() -> void:
	apply_preset(preset_idx)


## Freezes Jolt's bodies too: the props leave the physics world while paused.
func set_paused(on: bool) -> void:
	paused = on
	props.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT


func set_press(on: bool) -> void:
	press_on = on


## Spawns the preset's drop body above the camera target, recycling the oldest.
func drop_body() -> void:
	var preset := PRESETS[preset_idx]
	var first := preset.bodies.size()
	if not solver.is_ready() or solver.body_count() <= first:
		return
	if _next_drop >= solver.body_count():
		_next_drop = first
	var yaw := randf() * TAU
	var origin := Vector3(orbit_cam.target.x + randf_range(-0.3, 0.3), DROP_HEIGHT_M,
		orbit_cam.target.z + randf_range(-0.3, 0.3))
	solver.spawn_body(_next_drop, Transform3D(Basis.from_euler(Vector3(0.3, yaw, 0.2)), origin))
	_next_drop += 1


func throw_ball() -> void:
	var origin := camera.global_position - camera.global_basis.z * 0.5
	props.throw_ball(origin, (orbit_cam.target - origin).normalized() * THROW_SPEED_MPS)


func rock_rain() -> void:
	for i in ROCKS_PER_RAIN:
		props.drop_rock(orbit_cam.target)


## Material sliders: shared by every body, uploaded without a rebuild.
func set_material(key: String, value: float) -> void:
	match key:
		"stiffness_scale":
			solver.config.stiffness_scale = value
		"poisson_ratio":
			solver.config.poisson_ratio = value
		"density_kg_m3":
			solver.config.density_kg_m3 = value
		"damping_s":
			solver.config.damping_s = value
	solver.refresh_materials()


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
		"lattice_cell_m":
			_rebuild_pending = _rebuild_pending or not is_equal_approx(config.lattice_cell_m,
				float(value))
			config.lattice_cell_m = float(value)
		"max_bodies":
			_rebuild_pending = _rebuild_pending or config.max_bodies != int(value)
			config.max_bodies = int(value)
		"substeps":
			config.substeps = int(value)
		"iterations":
			config.iterations = int(value)
		"msaa":
			_viewport.set_msaa(int(value) as Viewport.MSAA)


func _apply_quality(values: Dictionary) -> void:
	for key in values:
		set_quality_value(key, values[key])


func capture_ready() -> bool:
	return solver.is_ready() and bodies.is_bound() and not _rebuild_pending


## Capture harness (param=key:value): tier keys, through the menu's path.
func set_capture_params(params: Dictionary) -> void:
	for key in params:
		set_quality_value(key, params[key])


## Capture harness (interaction=1): a drop, a thrown ball and the press.
func set_capture_interaction(on: bool) -> void:
	if on:
		drop_body()
		throw_ball()
		press_on = props.press_available()


func _exit_tree() -> void:
	bodies.release()
	solver.stop()
