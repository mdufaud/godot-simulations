extends Node3D
## GPU N-body gallery. The solver runs DKD leapfrog on compute and never hands
## particles back to the CPU: positions go compute -> rgba32f image ->
## Texture2DRD -> the star impostor's vertex shader.
## Add a scene by subclassing NBodySceneDef and appending it to SCENE_TYPES; its
## params() become sliders automatically.

# G = 1, M_bh = 1: a circular orbit at r = 6 takes about 92.35 simulation units.
const TIME_STEP := 0.15
const SPEED_STEPS := [0.25, 1.0, 2.0, 3.0]

# Not a const: a class reference is not a constant expression in GDScript.
static var SCENE_TYPES: Array = [
	BlackHoleScene, PulsarScene, GalaxyCollisionScene, PlanetRingsScene,
	VortexScene, FireworkScene, PlanetarySystemScene, GlobularClusterScene,
	TrojanSwarmScene, TidalStreamScene,
]

const PRESETS: Array[NBodyPreset] = [
	preload("res://resources/nbody/presets/black_hole.tres"),
	preload("res://resources/nbody/presets/pulsar.tres"),
	preload("res://resources/nbody/presets/collision.tres"),
	preload("res://resources/nbody/presets/rings.tres"),
	preload("res://resources/nbody/presets/vortex.tres"),
	preload("res://resources/nbody/presets/firework.tres"),
	preload("res://resources/nbody/presets/planetary_system.tres"),
	preload("res://resources/nbody/presets/globular_cluster.tres"),
	preload("res://resources/nbody/presets/trojan_swarms.tres"),
	preload("res://resources/nbody/presets/tidal_stream.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var horizon: MeshInstance3D = $EventHorizon
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var _viewport := ViewportGuard.attach(self)

var solver := NBodySolver.new()
var config: NBodyConfig = NBodyConfig.new()
var quality := SimQualityState.new()
var scene_def: NBodySceneDef = SCENE_TYPES[0].new()
var active_preset: NBodyPreset = PRESETS[0]
var attractor_list: Array = []
var horizon_nodes: Array[MeshInstance3D] = []
var time_scale := 1.0
var gravity_constant := 1.0
var integration_dt := TIME_STEP
var random_seed := 0
var requested_self_gravity := false

var pos_texture: Texture2DRD
var texture_bound := false
var mm: MultiMesh
var star_mat: ShaderMaterial

var status_label: Label
var profiler := SimProfiler.new()
var param_group: VBoxContainer
var advanced_param_group: VBoxContainer
var scene_param_parent: Control
var advanced_param_parent: Control
var scene_param_slot := -1
var advanced_param_slot := -1
var star_size_slider: HSlider
var brightness_slider: HSlider
var min_pixel_size_slider: HSlider
var gravity_toggle: CheckButton
var scene_action: Button
var speed_action: Button
var pause_toggle: Button
var step_action: Button
var seed_action: Button
var defaults_button: Button
var frame_button: Button
var scene_option: OptionButton
var particle_count_option: OptionButton
var pair_softening_slider: HSlider
var attractor_softening_slider: HSlider
var time_scale_slider: HSlider
var gravity_constant_slider: HSlider
var integration_dt_slider: HSlider
var substeps_slider: HSlider
var scene_param_sliders: Dictionary = {}
var advanced_param_sliders: Dictionary = {}
var _scene_defs: Dictionary = {}
var _scene_self_gravity: Dictionary = {}
var _scene_solver_values: Dictionary = {}
var _scene_render_values: Dictionary = {}
var _preferred_particle_count := -1
var _paused := false
var _sim_time := 0.0
var _step_clock := SimStepClock.new()
var _last_view_distance := 70.0


func _ready() -> void:
	# No RenderingDevice means every compute dispatch silently no-ops: say so
	# instead of booting into a black screen.
	if not GpuPreflight.available():
		menu.add_label("This demo needs GPU compute (Forward+ / Vulkan) and none is available.")
		return

	solver.config = config
	scene_def = SCENE_TYPES[active_preset.scene_type].new()
	_scene_defs[active_preset.scene_type] = scene_def
	quality.setup(NBodyQualityProfile, "nbody_quality_profile", _apply_quality)
	quality.restore()
	_scene_self_gravity[active_preset.scene_type] = requested_self_gravity
	# Keep pair-gravity catch-up conservative; cheap scene paths get one extra
	# quantum so 3x playback still holds near 50 FPS.
	_step_clock.max_quanta_per_frame = 4

	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 70.0
	orbit_cam.pitch = -25.0
	orbit_cam.min_distance = 3.0
	orbit_cam.max_distance = 400.0
	orbit_cam.move_speed = 25.0

	horizon_nodes.append(horizon)
	mm = _build_multimesh()
	_setup_stars()
	_setup_ui()
	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(_on_profiler_enabled)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid(), _viewport)
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


func capture_ready() -> bool:
	return solver.initialized and texture_bound


func apply_preset(index: int) -> void:
	_on_scene_selected(clampi(index, 0, PRESETS.size() - 1))


func set_capture_seed(value: int) -> void:
	_set_seed(value)


func set_capture_time_scale(value: float) -> void:
	var target := clampf(value, 0.25, 3.0)
	if time_scale_slider != null:
		time_scale_slider.value = target
	else:
		_set_time_scale(target)


func set_capture_profiling(on: bool) -> void:
	profiler.set_enabled(on)


func set_capture_params(values: Dictionary) -> void:
	var supported: Dictionary = {}
	for parameter in scene_def.params() + scene_def.advanced_params():
		supported[parameter.key] = true
	for key in values:
		if not supported.has(key):
			push_error("N-body capture parameter is not declared: %s" % key)
			return
		scene_def.set(key, float(values[key]))
	scene_def.normalize_params()
	_sync_scene_param_sliders()
	_restart(true)


func set_capture_render(values: Dictionary) -> void:
	if values.has("star_size"):
		_set_star_size(clampf(float(values.star_size), 0.02, 0.3))
	if values.has("brightness"):
		_set_brightness(clampf(float(values.brightness), 0.1, 3.0))
	if values.has("min_pixel_size"):
		_set_min_pixel_size(clampf(float(values.min_pixel_size), 0.5, 4.0))
	_sync_render_controls()


func set_frozen(frozen: bool) -> void:
	_on_pause_toggled(frozen)


func set_capture_time(value: float) -> void:
	if not solver.initialized or solver.force_mode != 2:
		return
	_sim_time = value - integration_dt
	solver.sim_time = _sim_time
	_step_clock.reset()
	_run_quantum()
	_on_pause_toggled(true)


func set_capture_view(view: String) -> void:
	var framed_distance := scene_def.view_distance(solver)
	match view:
		"near": orbit_cam.distance = framed_distance * 0.65
		"far": orbit_cam.distance = framed_distance * 1.3
		"default": orbit_cam.distance = framed_distance
	_sync_camera_clip_range()


func _build_multimesh() -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	m.mesh = quad
	# The GPU moves every vertex, so use the active scene's simulation bounds.
	m.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	_fill_mm(m)
	return m


# The instances carry no data — they exist so INSTANCE_ID can index the position
# texture. Built by doubling a 48-byte identity transform: a per-instance GDScript
# loop takes seconds at 1M.
func _fill_mm(m: MultiMesh) -> void:
	m.instance_count = solver.particle_count
	var identity := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
	var bytes := identity.to_byte_array()
	var total := solver.particle_count * 48
	while bytes.size() < total:
		bytes.append_array(bytes.duplicate())
	bytes.resize(total)
	m.buffer = bytes.to_float32_array()


func _setup_stars() -> void:
	star_mat = ShaderMaterial.new()
	star_mat.shader = load("res://shaders/nbody/star_impostor.gdshader")
	star_mat.set_shader_parameter("tex_width", solver.tex_width)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = star_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mmi)


func _apply_scene() -> void:
	# Modal solver fields survive a preset switch, so reset before defaults.
	scene_def.normalize_params()
	solver.gravity_constant = gravity_constant
	solver.random_seed = random_seed
	solver.respawn_mode = 0
	solver.force_mode = 0
	solver.sim_time = 0.0
	scene_def.apply_defaults(solver)
	star_mat.set_shader_parameter("firework_mode", solver.force_mode == 2)
	star_mat.set_shader_parameter("firework_groups", maxi(1, int(solver.firework_rocket_groups)))
	mm.visible_instance_count = mini(solver.particle_count,
		maxi(1, int(solver.firework_rocket_groups)) * 2048) if solver.force_mode == 2 else -1
	solver.gravity_constant = gravity_constant
	solver.random_seed = random_seed
	var scene_type: int = active_preset.scene_type
	if _scene_solver_values.has(scene_type):
		var tuning: Dictionary = _scene_solver_values[scene_type]
		solver.softening = tuning.softening
		solver.attractor_softening = tuning.attractor_softening
	else:
		_scene_solver_values[scene_type] = {
			softening = solver.softening,
			attractor_softening = solver.attractor_softening,
		}
	solver.self_gravity = requested_self_gravity and scene_def.supports_self_gravity()
	solver.substeps = clampi(solver.substeps, 1, NBodySolver.MAX_SUBSTEPS)
	solver.dt = integration_dt / float(solver.substeps)
	_sim_time = 0.0
	solver.sim_time = 0.0
	attractor_list = scene_def.attractors(solver)
	solver.set_attractors(attractor_list)
	_sync_horizon()
	_sync_horizon_appearance()
	mm.custom_aabb = scene_def.render_bounds(solver, attractor_list)
	_fit_scene_camera()
	var s := scene_def.seed(solver.particle_count, solver, random_seed)
	solver.set_seed(s.positions, s.velocities)
	_sync_seed_appearance()
	_sync_physics_controls()
	if status_label != null:
		_update_status()


# One sphere per attractor. The mesh is a shared unit sphere and the radius is
# node scale — moving attractors re-sync every frame, and a SphereMesh rebuild
# per frame would regenerate its vertex arrays.
func _sync_horizon() -> void:
	while horizon_nodes.size() < attractor_list.size():
		var n := horizon.duplicate() as MeshInstance3D
		add_child(n)
		horizon_nodes.append(n)
	for k in horizon_nodes.size():
		var node := horizon_nodes[k]
		if k >= attractor_list.size():
			node.visible = false
			continue
		var a: Dictionary = attractor_list[k]
		node.position = a.pos
		node.scale = Vector3.ONE * maxf(a.radius, 0.01)
		node.visible = a.radius > 0.0


func _sync_horizon_appearance() -> void:
	for i in attractor_list.size():
		var node := horizon_nodes[i]
		var color := scene_def.attractor_emission(i)
		if color.r + color.g + color.b <= 0.001:
			node.material_override = null
			continue
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 1.5
		node.material_override = material


func _restart(force_frame: bool = false) -> void:
	_teardown_solver()
	if force_frame:
		_last_view_distance = 0.0
	var desired_count := _preferred_particle_count if _preferred_particle_count > 0 \
		else solver.particle_count
	var effective_count := mini(desired_count, config.self_gravity_max_particles) \
		if requested_self_gravity and scene_def.supports_self_gravity() else desired_count
	if effective_count != solver.particle_count:
		solver.particle_count = effective_count
		solver.tex_width = _tex_width_for(effective_count)
		_fill_mm(mm)
		star_mat.set_shader_parameter("tex_width", solver.tex_width)
	if particle_count_option != null:
		particle_count_option.select(NBodyQualityProfile.PARTICLE_COUNTS.find(
			solver.particle_count))
	_apply_scene()
	_step_clock.reset()
	RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solver() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _setup_ui() -> void:
	var titles := []
	for preset in PRESETS:
		titles.append(preset.display_name)

	scene_action = menu.add_action("➡", "Scene", _next_scene)
	speed_action = menu.add_action("⏩", "1×", _cycle_speed)
	pause_toggle = menu.add_action_toggle("⏸", "Pause", false, _on_pause_toggled)
	step_action = menu.add_action("⏭", "Step", _step_once)
	step_action.tooltip_text = "Step one quantum while paused"
	step_action.disabled = true
	menu.add_action("↺", "Reset", _restart)

	scene_option = menu.add_option_button("Scene", titles, 0, _on_scene_selected, false)
	time_scale_slider = menu.add_slider("Time scale", 0.25, 3.0, time_scale,
		_set_time_scale, false, 0.25)
	brightness_slider = menu.add_slider("Brightness", 0.1, 3.0, active_preset.brightness,
		_set_brightness, false, 0.05)
	star_size_slider = menu.add_slider("Star size", 0.02, 0.3, active_preset.star_size,
		_set_star_size, false, 0.005)
	status_label = menu.add_label("")
	seed_action = menu.add_button("New seed (0)", _next_seed)
	menu.add_separator()

	menu.add_section("Scene settings")
	_build_scene_params()
	_build_advanced_params()
	defaults_button = menu.add_button("Scene defaults", _scene_defaults)

	menu.add_section("Appearance")
	min_pixel_size_slider = menu.add_slider("Minimum pixel size", 0.5, 4.0,
		active_preset.min_pixel_size, _set_min_pixel_size, false, 0.1)
	frame_button = menu.add_button("Frame scene", _frame_scene)

	menu.add_section("Advanced physics")
	gravity_toggle = menu.add_toggle("Particle self-gravity", requested_self_gravity,
		_on_self_gravity, false)
	gravity_constant_slider = menu.add_slider("Gravity G", 0.25, 2.0, gravity_constant,
		_ignore_slider_value, false, 0.01)
	gravity_constant_slider.drag_ended.connect(_on_physics_drag_ended)
	integration_dt_slider = menu.add_slider("Integration Δt", 0.015, 0.15, integration_dt,
		_ignore_slider_value, false, 0.005)
	integration_dt_slider.drag_ended.connect(_on_physics_drag_ended)
	substeps_slider = menu.add_slider("Substeps", 1.0, float(NBodySolver.MAX_SUBSTEPS),
		float(solver.substeps), _ignore_slider_value, false, 1.0)
	substeps_slider.drag_ended.connect(_on_physics_drag_ended)
	attractor_softening_slider = menu.add_slider("Attractor softening", 0.02, 0.5,
		solver.attractor_softening, _ignore_slider_value, false, 0.01)
	attractor_softening_slider.drag_ended.connect(_on_physics_drag_ended)
	pair_softening_slider = menu.add_slider("Pair softening", 0.02, 0.5,
		solver.softening, _ignore_slider_value, false, 0.01)
	pair_softening_slider.drag_ended.connect(_on_physics_drag_ended)

	menu.add_section("Performance")
	quality.attach_menu_option(menu)
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	var count_labels: Array = []
	for count in NBodyQualityProfile.PARTICLE_COUNTS:
		count_labels.append(_count_text(count))
	particle_count_option = menu.add_option_button("Particles", count_labels,
		NBodyQualityProfile.PARTICLE_COUNTS.find(solver.particle_count),
		func(idx: int): _set_particle_count(NBodyQualityProfile.PARTICLE_COUNTS[idx]))
	quality.bind("particle_count", particle_count_option,
		func(count): _set_particle_count(count),
		func(count): return NBodyQualityProfile.PARTICLE_COUNTS.find(count))
	menu.add_slider("Render scale", 0.4, 1.0,
		_viewport.render_scale(), _set_render_scale)
	_sync_physics_controls()
	_sync_render_controls()
	_sync_navigation_controls()
	_update_status()


func _set_render_scale(v: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, v)


func _update_status() -> void:
	var mode := "test particles O(N·K)"
	if solver.force_mode == 1:
		mode = "stylized vortex flow"
	elif solver.force_mode == 2:
		mode = "analytic fireworks"
	elif solver.self_gravity:
		mode = "particle self-gravity O(N²)"
	var limited := " · rate limited" if _step_clock.rate_limited else ""
	status_label.text = "%s particles · %s%s" % [
		_count_text(solver.particle_count), mode, limited,
	]


func _count_text(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	return "%dk" % (n / 1000)


func _build_scene_params() -> void:
	if param_group != null:
		param_group.free()
	param_group = menu.add_group(scene_param_parent)
	if scene_param_slot >= 0:
		scene_param_parent.move_child(param_group, mini(scene_param_slot,
			scene_param_parent.get_child_count() - 1))
	else:
		scene_param_parent = param_group.get_parent()
		scene_param_slot = param_group.get_index()
	scene_param_sliders.clear()
	for p in scene_def.params():
		var slider := menu.add_slider(p.label, p.min, p.max, scene_def.get(p.key),
			_param_setter(p.key), false, float(p.get("step", 0.0)))
		slider.drag_ended.connect(_on_param_drag_ended)
		scene_param_sliders[p.key] = slider
	menu.end_group()


func _build_advanced_params() -> void:
	if advanced_param_group != null:
		advanced_param_group.free()
	advanced_param_group = menu.add_group(advanced_param_parent)
	if advanced_param_slot >= 0:
		advanced_param_parent.move_child(advanced_param_group, mini(advanced_param_slot,
			advanced_param_parent.get_child_count() - 1))
	else:
		advanced_param_parent = advanced_param_group.get_parent()
		advanced_param_slot = advanced_param_group.get_index()
	advanced_param_sliders.clear()
	for p in scene_def.advanced_params():
		var slider := menu.add_slider(p.label, p.min, p.max, scene_def.get(p.key),
			_param_setter(p.key), false, float(p.get("step", 0.0)))
		slider.drag_ended.connect(_on_param_drag_ended)
		advanced_param_sliders[p.key] = slider
	menu.end_group()


func _param_setter(key: String) -> Callable:
	return func(v: float) -> void:
		scene_def.set(key, v)


# Re-seeding on every value_changed would rebuild the buffers dozens of times per
# drag, so scene params land on release.
func _on_param_drag_ended(changed: bool) -> void:
	if changed:
		scene_def.normalize_params()
		_sync_scene_param_sliders()
		_restart()


func _sync_scene_param_sliders() -> void:
	for sliders in [scene_param_sliders, advanced_param_sliders]:
		for key in sliders:
			var slider: HSlider = sliders[key]
			slider.value = scene_def.get(key)


func _sync_physics_controls() -> void:
	if gravity_toggle != null:
		gravity_toggle.visible = scene_def.supports_self_gravity()
		gravity_toggle.set_pressed_no_signal(solver.self_gravity)
	if time_scale_slider != null:
		time_scale_slider.value = time_scale
		gravity_constant_slider.value = gravity_constant
		integration_dt_slider.value = integration_dt
		substeps_slider.value = solver.substeps
	if attractor_softening_slider != null:
		attractor_softening_slider.value = solver.attractor_softening
	if pair_softening_slider != null:
		pair_softening_slider.value = solver.softening
	if step_action != null:
		var can_step := _paused and solver.initialized
		step_action.disabled = not can_step
		step_action.modulate = Color.WHITE if can_step else Color(1.0, 1.0, 1.0, 0.45)


func _sync_navigation_controls() -> void:
	var idx := PRESETS.find(active_preset)
	if scene_option != null and scene_option.selected != idx:
		scene_option.select(idx)
	if scene_action != null:
		scene_action.tooltip_text = "Next scene: %s" % PRESETS[(idx + 1) % PRESETS.size()].display_name
	_set_time_scale(time_scale)


func _next_scene() -> void:
	_on_scene_selected((PRESETS.find(active_preset) + 1) % PRESETS.size())


func _cycle_speed() -> void:
	for value in SPEED_STEPS:
		if value > time_scale + 0.001:
			time_scale_slider.value = value
			return
	time_scale_slider.value = SPEED_STEPS[0]


func _set_time_scale(value: float) -> void:
	time_scale = value
	if speed_action != null:
		menu.set_action_label(speed_action, "%.2fx" % time_scale)
		speed_action.tooltip_text = "Time scale %.2fx · click to change" % time_scale


func _on_scene_selected(idx: int) -> void:
	if idx < 0 or idx >= PRESETS.size():
		return
	active_preset = PRESETS[idx]
	var scene_type: int = active_preset.scene_type
	if _scene_defs.has(scene_type):
		scene_def = _scene_defs[scene_type]
	else:
		scene_def = SCENE_TYPES[scene_type].new()
		_scene_defs[scene_type] = scene_def
	if not _scene_self_gravity.has(scene_type):
		_scene_self_gravity[scene_type] = scene_def.default_self_gravity()
	requested_self_gravity = bool(_scene_self_gravity[scene_type])
	_build_scene_params()
	_build_advanced_params()
	_sync_render_controls()
	_sync_navigation_controls()
	_restart(true)


# Only the pipeline picked at dispatch changes; direct self-gravity stays capped.
func _on_self_gravity(on: bool) -> void:
	requested_self_gravity = on
	_scene_self_gravity[active_preset.scene_type] = on
	solver.self_gravity = on and scene_def.supports_self_gravity()
	var desired_count := _preferred_particle_count if _preferred_particle_count > 0 \
		else solver.particle_count
	var effective_count := mini(desired_count, config.self_gravity_max_particles) \
		if solver.self_gravity else desired_count
	if effective_count != solver.particle_count:
		_set_particle_count(desired_count, false)
	else:
		_sync_physics_controls()
		_update_status()


func _ignore_slider_value(_value: float) -> void:
	pass


func _on_physics_drag_ended(changed: bool) -> void:
	if not changed:
		return
	var previous_gravity := gravity_constant
	gravity_constant = gravity_constant_slider.value
	integration_dt = integration_dt_slider.value
	solver.substeps = clampi(int(round(substeps_slider.value)), 1, NBodySolver.MAX_SUBSTEPS)
	solver.dt = integration_dt / float(solver.substeps)
	solver.softening = pair_softening_slider.value
	solver.attractor_softening = attractor_softening_slider.value
	var scene_values: Dictionary = _scene_solver_values.get(active_preset.scene_type, {})
	scene_values.softening = solver.softening
	scene_values.attractor_softening = solver.attractor_softening
	_scene_solver_values[active_preset.scene_type] = scene_values
	if not is_equal_approx(previous_gravity, gravity_constant):
		solver.gravity_constant = gravity_constant
		_restart()
	_update_status()


func _on_pause_toggled(paused: bool) -> void:
	_paused = paused
	menu.set_action_label(pause_toggle, "Resume" if paused else "Pause")
	menu.set_action_icon(pause_toggle, "▶" if paused else "⏸")
	if paused:
		_step_clock.reset()
	_sync_physics_controls()
	_update_status()


func _step_once() -> void:
	if not _paused or not solver.initialized:
		return
	_run_quantum()
	_update_status()
	profiler.poll(0.0)


func _next_seed() -> void:
	_set_seed(random_seed + 1)


func _set_seed(value: int) -> void:
	random_seed = posmod(value, 2147483647)
	seed_action.text = "New seed (%d)" % random_seed
	_restart()


func _sync_seed_appearance() -> void:
	var tints := [
		Color.WHITE,
		Color(0.68, 0.86, 1.18),
		Color(1.17, 0.84, 0.74),
		Color(0.80, 1.08, 0.90),
	]
	star_mat.set_shader_parameter("seed_tint", tints[random_seed % tints.size()])


func _scene_defaults() -> void:
	var scene_type: int = active_preset.scene_type
	scene_def = SCENE_TYPES[scene_type].new()
	_scene_defs[scene_type] = scene_def
	requested_self_gravity = scene_def.default_self_gravity()
	_scene_self_gravity[scene_type] = requested_self_gravity
	_scene_solver_values.erase(scene_type)
	_scene_render_values.erase(scene_type)
	_build_scene_params()
	_build_advanced_params()
	_restart(true)
	_sync_render_controls()


func _set_star_size(value: float) -> void:
	if star_mat != null:
		star_mat.set_shader_parameter("sprite_size", value)
	var values: Dictionary = _scene_render_values.get(active_preset.scene_type, {})
	values.star_size = value
	_scene_render_values[active_preset.scene_type] = values


func _set_brightness(value: float) -> void:
	if star_mat != null:
		star_mat.set_shader_parameter("brightness", value)
	var values: Dictionary = _scene_render_values.get(active_preset.scene_type, {})
	values.brightness = value
	_scene_render_values[active_preset.scene_type] = values


func _set_min_pixel_size(value: float) -> void:
	if star_mat != null:
		star_mat.set_shader_parameter("min_pixel_size", value)
	var values: Dictionary = _scene_render_values.get(active_preset.scene_type, {})
	values.min_pixel_size = value
	_scene_render_values[active_preset.scene_type] = values


func _sync_render_controls() -> void:
	if star_size_slider == null or brightness_slider == null \
			or min_pixel_size_slider == null:
		return
	var values: Dictionary = _scene_render_values.get(active_preset.scene_type, {
		star_size = active_preset.star_size,
		brightness = active_preset.brightness,
		min_pixel_size = active_preset.min_pixel_size,
	})
	star_size_slider.value = float(values.get("star_size", active_preset.star_size))
	brightness_slider.value = float(values.get("brightness", active_preset.brightness))
	min_pixel_size_slider.value = float(values.get("min_pixel_size",
		active_preset.min_pixel_size))
	star_mat.set_shader_parameter("sprite_size", star_size_slider.value)
	star_mat.set_shader_parameter("brightness", brightness_slider.value)
	star_mat.set_shader_parameter("min_pixel_size", min_pixel_size_slider.value)


func _fit_scene_camera() -> void:
	var fit_distance := maxf(scene_def.view_distance(solver), orbit_cam.min_distance)
	var zoom_ratio := 1.0
	if _last_view_distance > 0.0:
		zoom_ratio = orbit_cam.distance / _last_view_distance
	orbit_cam.target = scene_def.view_target(solver, _sim_time)
	orbit_cam.max_distance = maxf(400.0, fit_distance * 3.0)
	orbit_cam.distance = clampf(fit_distance * zoom_ratio,
		orbit_cam.min_distance, orbit_cam.max_distance)
	_last_view_distance = fit_distance
	_sync_camera_clip_range()


func _sync_camera_clip_range() -> void:
	var camera := orbit_cam.get_camera()
	if camera == null or mm == null:
		return
	var bounds_radius := mm.custom_aabb.size.length() * 0.5
	var target_offset := orbit_cam.target.length()
	camera.far = maxf(camera.far,
		orbit_cam.max_distance + target_offset + bounds_radius + 10.0)


func _frame_scene() -> void:
	orbit_cam.target = scene_def.view_target(solver, _sim_time)
	_last_view_distance = maxf(scene_def.view_distance(solver), orbit_cam.min_distance)
	orbit_cam.max_distance = maxf(400.0, _last_view_distance * 3.0)
	orbit_cam.distance = _last_view_distance
	_sync_camera_clip_range()


func _set_particle_count(n: int, remember: bool = true) -> void:
	if remember:
		_preferred_particle_count = n
	var target := mini(n, config.self_gravity_max_particles) if solver.self_gravity else n
	if target == solver.particle_count:
		_update_status()
		return
	var was_initialized := solver.initialized
	if was_initialized:
		_teardown_solver()
	solver.particle_count = target
	solver.tex_width = _tex_width_for(target)
	if particle_count_option != null:
		particle_count_option.select(NBodyQualityProfile.PARTICLE_COUNTS.find(target))
	_fill_mm(mm)
	star_mat.set_shader_parameter("tex_width", solver.tex_width)
	_apply_scene()
	if was_initialized:
		RenderingServer.call_on_render_thread(solver.init_render)


## Sets the solver fields a quality tier bundles. Before init (launch restore)
## the fields land directly; on a tier switch the count rebuilds through the
## same path as the Particles option.
func _apply_quality(values: Dictionary) -> void:
	requested_self_gravity = values.self_gravity
	_scene_self_gravity[active_preset.scene_type] = requested_self_gravity
	solver.self_gravity = requested_self_gravity and scene_def.supports_self_gravity()
	config.self_gravity_max_particles = values.self_gravity_max
	# Particle count is widget-bound: absent from values on a tier push, so fall
	# back to the live value.
	var count := int(values.get("particle_count",
		_preferred_particle_count if _preferred_particle_count > 0 else solver.particle_count))
	if solver.initialized:
		_set_particle_count(count)
	else:
		_preferred_particle_count = count
		var target := mini(count, config.self_gravity_max_particles) if solver.self_gravity else count
		if target != solver.particle_count:
			solver.particle_count = target
			solver.tex_width = _tex_width_for(target)
	_sync_physics_controls()


func _tex_width_for(n: int) -> int:
	var w := 256
	while w * w < n:
		w *= 2
	return w


func _on_profiler_enabled(on: bool) -> void:
	solver.profiling = on


func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("step"):
		lines.append("  merged step %.2f ms" % t["step"])
	if t.has("force"):
		lines.append("  force %.2f | integrate %.2f" % [
			t.get("force", 0.0), t.get("integrate", 0.0),
		])
	return lines


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		pos_texture = Texture2DRD.new()
		pos_texture.texture_rd_rid = solver.get_position_tex_rid()
		star_mat.set_shader_parameter("position_tex", pos_texture)
		texture_bound = true
		_sync_physics_controls()
		return
	if _paused:
		profiler.poll(delta)
		return
	_step_clock.max_quanta_per_frame = 3 if solver.self_gravity else 4
	var quanta := _step_clock.advance(delta, time_scale)
	_run_quanta(quanta)
	_update_status()
	profiler.poll(delta)


func _run_quanta(quanta: int) -> void:
	var remaining := quanta
	while remaining > 0:
		var batch_limit := remaining
		if solver.force_mode != 2:
			batch_limit = mini(batch_limit,
				maxi(1, NBodySolver.MAX_SUBSTEPS / solver.substeps))
		var batch := mini(remaining, batch_limit)
		_run_quantum(batch)
		remaining -= batch


func _run_quantum(quantum_count: int = 1) -> void:
	quantum_count = maxi(quantum_count, 1)
	var start_time := _sim_time
	var step_dt := integration_dt / float(solver.substeps)
	var samples: Array = []
	var axes: Array[Vector3] = []
	var total_substeps := solver.substeps
	if solver.force_mode != 2:
		total_substeps *= quantum_count
	_append_source_sample(start_time, samples, axes)
	for s in total_substeps:
		_append_source_sample(start_time + (float(s) + 0.5) * step_dt, samples, axes)
		_append_source_sample(start_time + float(s + 1) * step_dt, samples, axes)
	_sim_time = start_time + integration_dt * float(quantum_count)
	solver.sim_time = _sim_time
	if solver.force_mode == 2:
		orbit_cam.target = scene_def.view_target(solver, _sim_time)
	var step_time := _sim_time if solver.force_mode == 2 else start_time
	var constants := solver.make_step_constants(step_dt, step_time, total_substeps)
	var source_data := solver.pack_attractor_samples(samples, axes)
	if source_data.is_empty():
		push_error("N-body controller produced an invalid attractor timeline")
		return
	RenderingServer.call_on_render_thread(
		solver.step_render.bind(constants, source_data, quantum_count)
	)
	_sync_horizon()
	mm.custom_aabb = scene_def.render_bounds(solver, attractor_list)
	_sync_camera_clip_range()


func _append_source_sample(t: float, samples: Array, axes: Array[Vector3]) -> void:
	scene_def.update_attractors(t, attractor_list, solver)
	scene_def.update_frame(t, solver)
	var snapshot: Array = []
	for attractor: Dictionary in attractor_list:
		snapshot.append(attractor.duplicate())
	samples.append(snapshot)
	axes.append(solver.axis_dir)


func _exit_tree() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
