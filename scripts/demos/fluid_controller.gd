extends Node3D
## GPU Position Based Fluids demo (Macklin & Müller 2013) with screen-space
## surface rendering (narrow-range filter, Truong 2018). Switchable water/lava.
## Solver + prepass/filter/composite chain are built in code; the scene supplies
## the camera rig, environment, ground and UI.

const PARTICLE_RADIUS := 0.12
const LAYER_DEPTH := 2
const LAYER_THICK := 4

@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var menu: SimMenu = $UI/SimMenu

var render_scale := 0.5
var sim_mode := 0.0
var solver := PbfFluidSolver.new()
var pos_texture: Texture2DRD
var texture_bound := false
var mm: MultiMesh

var depth_cam: Camera3D
var thick_cam: Camera3D
var depth_vp: SubViewport
var thick_vp: SubViewport
var filter_h_vp: SubViewport
var filter_v_vp: SubViewport
var depth_mat: ShaderMaterial
var thick_mat: ShaderMaterial
var filter_h_mat: ShaderMaterial
var filter_v_mat: ShaderMaterial
var composite_mat: ShaderMaterial

var profiler_label: Label
var _profile_accum := 0.0


func _ready() -> void:
	main_cam.cull_mask = 0xFFFFF & ~(LAYER_DEPTH | LAYER_THICK)
	main_cam.current = true
	_configure_solver()
	mm = _build_multimesh()
	var vp_size: Vector2i = get_viewport().size
	_setup_prepass(mm, vp_size)
	_setup_filters(vp_size)
	_setup_composite()
	_setup_ui()
	_setup_profiler()
	_apply_env()
	solver.set_seed_positions(_build_dam_seed())
	RenderingServer.call_on_render_thread(solver.init_render)


func _configure_solver() -> void:
	solver.mode = sim_mode
	if sim_mode > 0.5:
		solver.xsph_c = 0.35
		solver.vorticity_eps = 0.0
	else:
		solver.xsph_c = 0.05
		solver.vorticity_eps = 0.02


func _build_dam_seed() -> PackedFloat32Array:
	var n := solver.particle_count
	var s := solver.spacing
	var w := ceili(pow(float(n), 1.0 / 3.0))
	var seed := PackedFloat32Array()
	seed.resize(n * 4)
	var origin := Vector3(-7.7, 0.1, -7.7)
	for i in n:
		var x := i % w
		@warning_ignore("integer_division")
		var y := (i / w) % w
		@warning_ignore("integer_division")
		var z := i / (w * w)
		var p := origin + Vector3(x, y, z) * s
		seed[i * 4] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		seed[i * 4 + 3] = sim_mode
	return seed


func _build_multimesh() -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	m.mesh = quad
	m.custom_aabb = AABB(Vector3(-8.0, 0.0, -8.0), Vector3(16.0, 16.0, 16.0))
	_fill_mm(m)
	return m


func _fill_mm(m: MultiMesh) -> void:
	m.instance_count = solver.particle_count
	var buf := PackedFloat32Array()
	buf.resize(solver.particle_count * 12)
	for i in solver.particle_count:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	m.buffer = buf


func _make_prepass_cam(mask: int) -> Camera3D:
	var cam := Camera3D.new()
	cam.cull_mask = mask
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	cam.environment = env
	return cam


func _setup_prepass(mm: MultiMesh, vp_size: Vector2i) -> void:
	depth_mat = ShaderMaterial.new()
	depth_mat.shader = load("res://shaders/fluid_impostor.gdshader")
	depth_mat.set_shader_parameter("tex_width", solver.tex_width)
	depth_mat.set_shader_parameter("particle_radius", PARTICLE_RADIUS)
	thick_mat = ShaderMaterial.new()
	thick_mat.shader = load("res://shaders/fluid_thickness.gdshader")
	thick_mat.set_shader_parameter("tex_width", solver.tex_width)
	thick_mat.set_shader_parameter("particle_radius", PARTICLE_RADIUS)

	var depth_mmi := MultiMeshInstance3D.new()
	depth_mmi.multimesh = mm
	depth_mmi.material_override = depth_mat
	depth_mmi.layers = LAYER_DEPTH
	depth_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(depth_mmi)
	var thick_mmi := MultiMeshInstance3D.new()
	thick_mmi.multimesh = mm
	thick_mmi.material_override = thick_mat
	thick_mmi.layers = LAYER_THICK
	thick_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(thick_mmi)

	var scaled := _scaled_size(vp_size)
	depth_vp = SubViewport.new()
	depth_vp.size = scaled
	depth_vp.use_hdr_2d = true
	depth_vp.own_world_3d = false
	depth_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	depth_vp.positional_shadow_atlas_size = 0
	depth_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(depth_vp)
	depth_cam = _make_prepass_cam(LAYER_DEPTH)
	depth_vp.add_child(depth_cam)
	depth_cam.current = true

	thick_vp = SubViewport.new()
	thick_vp.size = _thick_size(scaled)
	thick_vp.use_hdr_2d = true
	thick_vp.own_world_3d = false
	thick_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	thick_vp.positional_shadow_atlas_size = 0
	thick_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(thick_vp)
	thick_cam = _make_prepass_cam(LAYER_THICK)
	thick_vp.add_child(thick_cam)
	thick_cam.current = true


func _make_filter_vp(vp_size: Vector2i, dir: Vector2, src: Texture2D, proj_scale: float) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = vp_size
	vp.disable_3d = true
	vp.use_hdr_2d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/fluid_depth_filter.gdshader")
	mat.set_shader_parameter("depth_tex", src)
	mat.set_shader_parameter("direction", dir)
	mat.set_shader_parameter("particle_radius", PARTICLE_RADIUS)
	mat.set_shader_parameter("proj_scale", proj_scale)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)
	return vp


func _setup_filters(vp_size: Vector2i) -> void:
	var scaled := _scaled_size(vp_size)
	var proj_scale := float(scaled.y) * 0.5 / tan(deg_to_rad(main_cam.fov) * 0.5)
	filter_h_vp = _make_filter_vp(scaled, Vector2(1, 0), depth_vp.get_texture(), proj_scale)
	filter_v_vp = _make_filter_vp(scaled, Vector2(0, 1), filter_h_vp.get_texture(), proj_scale)
	filter_h_mat = (filter_h_vp.get_child(0) as ColorRect).material
	filter_v_mat = (filter_v_vp.get_child(0) as ColorRect).material


func _setup_composite() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	composite_mat = ShaderMaterial.new()
	composite_mat.shader = load("res://shaders/fluid_composite.gdshader")
	composite_mat.set_shader_parameter("fluid_depth_tex", filter_v_vp.get_texture())
	composite_mat.set_shader_parameter("thickness_tex", thick_vp.get_texture())
	composite_mat.set_shader_parameter("mode", sim_mode)
	quad.material = composite_mat
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	add_child(mi)


func _setup_ui() -> void:
	menu.title = "🌊 Fluid Simulation (PBF)"
	menu.add_section("Simulation")
	menu.add_toggle("Lava mode", sim_mode > 0.5, _on_lava_toggled)
	menu.add_button("Reset drop", _on_reset)
	menu.add_separator()
	menu.add_section("Parameters")
	menu.add_slider("Viscosity", 0.0, 0.5, solver.xsph_c, func(v): solver.xsph_c = v)
	menu.add_slider("Vorticity", 0.0, 0.1, solver.vorticity_eps, func(v): solver.vorticity_eps = v)
	menu.add_slider("Cohesion", 0.0, 0.01, solver.scorr_k, func(v): solver.scorr_k = v)
	menu.add_slider("Iterations", 1.0, 6.0, float(solver.solver_iterations),
		func(v): solver.solver_iterations = int(round(v)))
	menu.add_separator()
	menu.add_section("Performance")
	menu.add_toggle("Profiler overlay", false, _on_profiler_toggled)
	menu.add_slider("Render scale", 0.25, 1.0, render_scale, _set_render_scale)
	menu.add_label("Particles")
	menu.add_button("16k", func(): _set_particle_count(16384))
	menu.add_button("32k", func(): _set_particle_count(32768))
	menu.add_button("64k", func(): _set_particle_count(65536))


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
	solver.profiling = on
	profiler_label.visible = on
	for vp in [depth_vp, thick_vp, filter_h_vp, filter_v_vp, get_viewport()]:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), on)


func _update_overlay() -> void:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("grid"):
		lines.append("  grid %.2f | lambda %.2f | delta %.2f | apply %.2f | post %.2f" % [
			t.get("grid", 0.0), t.get("lambda", 0.0), t.get("delta", 0.0),
			t.get("apply", 0.0), t.get("post", 0.0),
		])
	var vps := [["depth", depth_vp], ["thick", thick_vp], ["fH", filter_h_vp],
		["fV", filter_v_vp], ["root", get_viewport()]]
	var parts := PackedStringArray()
	for entry in vps:
		var rid: RID = entry[1].get_viewport_rid()
		parts.append("%s %.2f" % [entry[0], RenderingServer.viewport_get_measured_render_time_gpu(rid)])
	lines.append("viewport GPU ms: " + " | ".join(parts))
	profiler_label.text = "\n".join(lines)


func _set_render_scale(v: float) -> void:
	render_scale = v
	var scaled := _scaled_size(get_viewport().size)
	depth_vp.size = scaled
	thick_vp.size = _thick_size(scaled)
	filter_h_vp.size = scaled
	filter_v_vp.size = scaled
	var proj_scale := float(scaled.y) * 0.5 / tan(deg_to_rad(main_cam.fov) * 0.5)
	filter_h_mat.set_shader_parameter("proj_scale", proj_scale)
	filter_v_mat.set_shader_parameter("proj_scale", proj_scale)


func _set_particle_count(n: int) -> void:
	if n == solver.particle_count:
		return
	_teardown_solver()
	solver.particle_count = n
	_fill_mm(mm)
	solver.set_seed_positions(_build_dam_seed())
	RenderingServer.call_on_render_thread(solver.init_render)


func _scaled_size(vp_size: Vector2i) -> Vector2i:
	var s := Vector2(vp_size) * render_scale
	return Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))


# Thickness is low-frequency and sampled with filter_linear: half the prepass res
func _thick_size(scaled: Vector2i) -> Vector2i:
	return Vector2i(maxi(scaled.x / 2, 1), maxi(scaled.y / 2, 1))


func _apply_env() -> void:
	if world_env.environment == null:
		return
	world_env.environment.glow_enabled = sim_mode > 0.5


func _on_lava_toggled(on: bool) -> void:
	sim_mode = 1.0 if on else 0.0
	_teardown_solver()
	_configure_solver()
	composite_mat.set_shader_parameter("mode", sim_mode)
	_apply_env()
	solver.set_seed_positions(_build_dam_seed())
	RenderingServer.call_on_render_thread(solver.init_render)


func _on_reset() -> void:
	_teardown_solver()
	solver.set_seed_positions(_build_dam_seed())
	RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solver() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _sync_cams() -> void:
	for cam in [depth_cam, thick_cam]:
		cam.global_transform = main_cam.global_transform
		cam.fov = main_cam.fov
		cam.near = main_cam.near
		cam.far = main_cam.far


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		pos_texture = Texture2DRD.new()
		pos_texture.texture_rd_rid = solver.get_position_tex_rid()
		depth_mat.set_shader_parameter("position_tex", pos_texture)
		thick_mat.set_shader_parameter("position_tex", pos_texture)
		texture_bound = true
		return
	_sync_cams()
	RenderingServer.call_on_render_thread(solver.step_render.bind(1.0 / 60.0))
	_profile_accum += delta
	if profiler_label.visible and _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()


func _exit_tree() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
