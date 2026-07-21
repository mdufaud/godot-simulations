extends Node3D
## GPU N-body galaxy demo. The solver runs leapfrog on compute and never hands
## particles back to the CPU: positions go compute -> rgba32f image ->
## Texture2DRD -> the star impostor's vertex shader.
## Add a scene by subclassing NBodySceneDef and appending it to SCENE_TYPES; its
## params() become sliders automatically.

# G = 1, M_bh = 1: the inner disk orbits in ~33 time units, so a 0.016 step would
# take minutes per revolution. Energy stays conserved up to ~0.22 per substep.
const TIME_STEP := 0.15
# O(N^2): 32k costs ~24 ms/frame on a 760M iGPU, 16k ~6 ms. See TODO.md.
const SELF_GRAVITY_MAX := 16384

# Not a const: a class reference is not a constant expression in GDScript.
static var SCENE_TYPES: Array = [
	BlackHoleScene, PulsarScene, GalaxyCollisionScene, PlanetRingsScene,
	VortexScene, FireworkScene,
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var horizon: MeshInstance3D = $EventHorizon
@onready var orbit_cam: OrbitCamera = $CameraPivot

var solver := NBodySolver.new()
var scene_def: NBodySceneDef
var attractor_list: Array = []
var horizon_nodes: Array[MeshInstance3D] = []
var time_scale := 1.0

var pos_texture: Texture2DRD
var texture_bound := false
var mm: MultiMesh
var star_mat: ShaderMaterial

var status_label: Label
var profiler_label: Label
var param_group: VBoxContainer
var star_size_slider: HSlider
var brightness_slider: HSlider
var self_gravity_toggle: CheckButton
var _sim_time := 0.0
var _profile_accum := 0.0


func _ready() -> void:
	scene_def = SCENE_TYPES[0].new()
	solver.particle_count = GameManager.get_setting("nbody_particle_count", 262144)
	solver.tex_width = _tex_width_for(solver.particle_count)
	solver.self_gravity = GameManager.get_setting("nbody_self_gravity", false)

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
	_setup_profiler()
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


func _build_multimesh() -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	m.mesh = quad
	# The GPU moves every vertex, so the mesh AABB is meaningless: cover the domain.
	m.custom_aabb = AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))
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
	solver.respawn_mode = 0
	solver.force_mode = 0
	solver.sim_time = 0.0
	scene_def.apply_defaults(solver)
	solver.dt = TIME_STEP * time_scale / float(solver.substeps)
	attractor_list = scene_def.attractors()
	solver.set_attractors(attractor_list)
	_sync_horizon()
	# The disk can be resized from 10 to 160 units, so let the camera follow suit.
	orbit_cam.max_distance = solver.disk_r_max * 8.0
	var s := scene_def.seed(solver.particle_count, solver)
	solver.set_seed(s.positions, s.velocities)
	_sim_time = 0.0
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


func _restart() -> void:
	_teardown_solver()
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solver() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _setup_ui() -> void:
	var titles := []
	for scene_type in SCENE_TYPES:
		titles.append(scene_type.new().title())

	menu.add_section("Scene")
	menu.add_option_button("Preset", titles, 0, _on_scene_selected)
	menu.add_action("↺", "Reset", _restart)
	status_label = menu.add_label("")
	_build_scene_params()
	menu.add_separator()

	menu.add_section("Simulation")
	self_gravity_toggle = menu.add_toggle(
		"Self-gravity O(N²)", solver.self_gravity, _on_self_gravity
	)
	menu.add_slider("Time scale", 0.0, 3.0, time_scale, _on_time_scale)
	menu.add_slider("Substeps", 1.0, 4.0, float(solver.substeps), _on_substeps)
	menu.add_slider("Softening", 0.02, 0.5, solver.softening, func(v): solver.softening = v)
	menu.add_separator()

	menu.add_section("Render")
	star_size_slider = menu.add_slider("Star size", 0.02, 0.3, scene_def.star_size(),
		func(v): star_mat.set_shader_parameter("sprite_size", v))
	brightness_slider = menu.add_slider("Brightness", 0.1, 3.0, scene_def.brightness(),
		func(v): star_mat.set_shader_parameter("brightness", v))
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, _on_profiler_toggled)
	menu.add_label("Particles")
	menu.add_button("65k", func(): _set_particle_count(65536))
	menu.add_button("262k", func(): _set_particle_count(262144))
	menu.add_button("1M", func(): _set_particle_count(1048576))
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, _set_render_scale)
	_update_status()


func _set_render_scale(v: float) -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


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


func _update_status() -> void:
	var mode := "self-gravity O(N²)" if solver.self_gravity else "attractors O(N·K)"
	status_label.text = "%s particles · %s" % [_count_text(solver.particle_count), mode]


func _count_text(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	return "%dk" % (n / 1000)


# The scene declares its own tweakables, so switching scenes swaps the sliders.
# add_group() appends at the end of the menu, hence the move_child back into place.
func _build_scene_params() -> void:
	var slot := -1
	if param_group != null:
		slot = param_group.get_index()
		param_group.free()
	param_group = menu.add_group()
	for p in scene_def.params():
		var slider := menu.add_slider(p.label, p.min, p.max, scene_def.get(p.key),
			_param_setter(p.key))
		slider.drag_ended.connect(_on_param_drag_ended)
	menu.end_group()
	if slot >= 0:
		param_group.get_parent().move_child(param_group, slot)


func _param_setter(key: String) -> Callable:
	return func(v: float) -> void:
		scene_def.set(key, v)


# Re-seeding on every value_changed would rebuild the buffers dozens of times per
# drag, so scene params land on release.
func _on_param_drag_ended(changed: bool) -> void:
	if changed:
		_restart()


# Setting a slider's value fires its value_changed callback, which pushes the
# shader parameter — no separate material update needed.
func _on_scene_selected(idx: int) -> void:
	scene_def = SCENE_TYPES[idx].new()
	_build_scene_params()
	star_size_slider.value = scene_def.star_size()
	brightness_slider.value = scene_def.brightness()
	if scene_def.view_distance() > 0.0:
		orbit_cam.distance = scene_def.view_distance()
	_restart()


# Only the pipeline picked at dispatch changes, so no rebuild — but O(N^2) at 1M
# particles would hang the GPU, so the count comes down with it.
func _on_self_gravity(on: bool) -> void:
	solver.self_gravity = on
	GameManager.set_setting("nbody_self_gravity", on)
	if on and solver.particle_count > SELF_GRAVITY_MAX:
		_set_particle_count(SELF_GRAVITY_MAX)
	else:
		_update_status()


func _on_time_scale(v: float) -> void:
	time_scale = v
	solver.dt = TIME_STEP * time_scale / float(solver.substeps)


func _on_substeps(v: float) -> void:
	solver.substeps = int(round(v))
	solver.dt = TIME_STEP * time_scale / float(solver.substeps)


func _set_particle_count(n: int) -> void:
	var target := mini(n, SELF_GRAVITY_MAX) if solver.self_gravity else n
	if target == solver.particle_count:
		_update_status()
		return
	_teardown_solver()
	solver.particle_count = target
	solver.tex_width = _tex_width_for(target)
	GameManager.set_setting("nbody_particle_count", target)
	_fill_mm(mm)
	star_mat.set_shader_parameter("tex_width", solver.tex_width)
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


func _tex_width_for(n: int) -> int:
	var w := 256
	while w * w < n:
		w *= 2
	return w


func _on_profiler_toggled(on: bool) -> void:
	solver.profiling = on
	profiler_label.visible = on
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func _update_overlay() -> void:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("step"):
		lines.append("  merged step %.2f ms" % t["step"])
	if t.has("force"):
		lines.append("  force %.2f | integrate %.2f" % [
			t.get("force", 0.0), t.get("integrate", 0.0),
		])
	lines.append("viewport GPU %.2f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	))
	profiler_label.text = "\n".join(lines)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		pos_texture = Texture2DRD.new()
		pos_texture.texture_rd_rid = solver.get_position_tex_rid()
		star_mat.set_shader_parameter("position_tex", pos_texture)
		texture_bound = true
		return
	_sim_time += TIME_STEP * time_scale
	solver.sim_time = _sim_time
	if scene_def.update_attractors(_sim_time, attractor_list):
		solver.set_attractors(attractor_list)
		_sync_horizon()
	scene_def.update_frame(_sim_time, solver)
	RenderingServer.call_on_render_thread(solver.step_render)
	_profile_accum += delta
	if profiler_label.visible and _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()


func _exit_tree() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
