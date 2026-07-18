extends Node3D
## GPU XPBD cloth in an open-air gusty wind. Several sheets run at once — three
## flags, a clothesline and a tarp draped over a boulder — each with its own
## ClothSolver instance (the SPIR-V is compiled once and shared). The CPU
## animates the slow wind (direction wander + gust envelope); the compute shader
## layers fast spatial turbulence on top, so no two sheets flap in unison.
## Vertices go compute -> rgba32f image -> the surface shader's vertex stage.

const CLOTHS: Array[Dictionary] = [
	{pin = "edge", size = Vector2(4.0, 2.6), pos = Vector3(-7.0, 0.0, 0.5), yaw = 0.0,
		top = 5.8, color = Color(0.75, 0.15, 0.12), stripes = true},
	{pin = "edge", size = Vector2(3.0, 2.0), pos = Vector3(-2.5, 0.0, -3.0), yaw = 0.5,
		top = 4.6, color = Color(0.16, 0.32, 0.68), stripes = false},
	{pin = "edge", size = Vector2(3.4, 2.2), pos = Vector3(2.8, 0.0, 1.8), yaw = -0.4,
		top = 6.6, color = Color(0.88, 0.62, 0.12), stripes = false},
	{pin = "top", size = Vector2(2.1, 2.4), pos = Vector3(-6.2, 0.0, -6.0), yaw = 0.35,
		top = 3.1, color = Color(0.92, 0.9, 0.85), stripes = false},
	{pin = "top", size = Vector2(2.1, 2.4), pos = Vector3(-3.6, 0.0, -6.9), yaw = 0.35,
		top = 3.1, color = Color(0.72, 0.78, 0.88), stripes = false},
	{pin = "corners", size = Vector2(4.4, 4.4), pos = Vector3(0.5, 0.0, 7.5), yaw = 0.2,
		top = 2.4, color = Color(0.27, 0.42, 0.3), stripes = false, boulder = 1.3},
]

const REST_SPACING := 0.055
const WOOD := Color(0.35, 0.3, 0.26)

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot

var wind_enabled := true
var wind_speed := 9.0
var gustiness := 0.6
var turbulence := 0.3
var wind_wander := true
var wind_dir_deg := 200.0

var solvers: Array[ClothSolver] = []
var cloth_mats: Array[ShaderMaterial] = []
var pos_textures: Array[Texture2DRD] = []
var textures_bound := false

var status_label: Label
var wind_label: Label
var profiler_label: Label
var _time := 0.0
var _profile_accum := 0.0


func _ready() -> void:
	orbit_cam.target = Vector3(0.0, 3.0, 1.0)
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -14.0
	orbit_cam.yaw = 30.0
	orbit_cam.min_distance = 3.0
	orbit_cam.max_distance = 60.0

	_build_cloths()
	_build_props()
	_setup_ui()
	_setup_profiler()
	_init_solvers()


# ── Cloth setup ──────────────────────────────────────────────────────────────

func _build_cloths() -> void:
	var surface_shader: Shader = load("res://shaders/cloth/cloth_surface.gdshader")
	for ci in CLOTHS.size():
		var cfg: Dictionary = CLOTHS[ci]
		var solver := ClothSolver.new()
		solver.profile_key = "cloth%d" % ci
		solver.rest_spacing = REST_SPACING
		# One vertex per rest_spacing, so a bigger sheet gets more vertices rather
		# than longer springs — stiffness stays comparable across sheets.
		var size: Vector2 = cfg.size
		solver.grid_w = clampi(int(size.x / REST_SPACING), 8, 160)
		solver.grid_h = clampi(int(size.y / REST_SPACING), 8, 160)
		solver.set_seed(_seed_sheet(cfg, solver.grid_w, solver.grid_h))
		if cfg.has("boulder"):
			solver.sphere_center = cfg.pos + Vector3(0.0, cfg.boulder * 0.72, 0.0)
			solver.sphere_radius = cfg.boulder
		solvers.append(solver)

		var mat := ShaderMaterial.new()
		mat.shader = surface_shader
		mat.set_shader_parameter("grid_size", Vector2(solver.grid_w, solver.grid_h))
		mat.set_shader_parameter("cloth_color", cfg.color)
		mat.set_shader_parameter("stripe_mix", 1.0 if cfg.stripes else 0.0)
		cloth_mats.append(mat)

		var mi := MeshInstance3D.new()
		mi.mesh = _build_grid_mesh(solver.grid_w, solver.grid_h)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		# The GPU moves every vertex out of the mesh's own bounds: cover the domain.
		mi.custom_aabb = AABB(Vector3(-30, -1, -30), Vector3(60, 30, 60))
		add_child(mi)


## 4 floats per vertex: rest position + pin flag (1 = kinematic). Flags and the
## clothesline hang vertically; the tarp starts as a horizontal sheet whose four
## pinned corners hold it above the boulder it drapes over.
func _seed_sheet(cfg: Dictionary, w: int, h: int) -> PackedFloat32Array:
	var size: Vector2 = cfg.size
	var basis := Basis(Vector3.UP, float(cfg.yaw))
	var out := PackedFloat32Array()
	out.resize(w * h * 4)
	for y in h:
		for x in w:
			var i := y * w + x
			var u := float(x) / (w - 1)
			var v := float(y) / (h - 1)
			var local: Vector3
			if cfg.pin == "corners":
				local = Vector3((u - 0.5) * size.x, cfg.top, (v - 0.5) * size.y)
			else:
				local = Vector3((u - 0.5) * size.x, cfg.top - v * size.y, 0.0)
			var pos: Vector3 = cfg.pos + basis * local
			out[i * 4] = pos.x
			out[i * 4 + 1] = pos.y
			out[i * 4 + 2] = pos.z
			out[i * 4 + 3] = 1.0 if _is_pinned(cfg.pin, x, y, w, h) else 0.0
	return out


func _is_pinned(pin: String, x: int, y: int, w: int, h: int) -> bool:
	match pin:
		"edge":
			return x == 0
		"top":
			return y == 0
		"corners":
			return (x == 0 or x == w - 1) and (y == 0 or y == h - 1)
	return false


# A flat UV grid: the vertex shader overwrites every position from the solver
# texture, so only the topology and the UVs here matter.
func _build_grid_mesh(w: int, h: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(w * h)
	uvs.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			verts[i] = Vector3(x, -y, 0) * REST_SPACING
			uvs[i] = Vector2(float(x) / (w - 1), float(y) / (h - 1))
	for y in h - 1:
		for x in w - 1:
			var i := y * w + x
			indices.append_array([i, i + w, i + 1, i + 1, i + w, i + w + 1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ── Props: poles, clothesline, tarp posts, boulders ──────────────────────────

func _build_props() -> void:
	for cfg in CLOTHS:
		var basis := Basis(Vector3.UP, float(cfg.yaw))
		var size: Vector2 = cfg.size
		match cfg.pin:
			"edge":
				var base: Vector3 = cfg.pos + basis * Vector3(-size.x * 0.5 - 0.04, 0.0, 0.0)
				_add_pole(base, cfg.top + 0.4, 0.06)
			"top":
				# The clothesline bar the top hem hangs from, plus its two posts.
				var l: Vector3 = cfg.pos + basis * Vector3(-size.x * 0.5 - 0.25, 0.0, 0.0)
				var r: Vector3 = cfg.pos + basis * Vector3(size.x * 0.5 + 0.25, 0.0, 0.0)
				_add_pole(l, cfg.top + 0.15, 0.05)
				_add_pole(r, cfg.top + 0.15, 0.05)
				_add_bar(l + Vector3(0.0, cfg.top, 0.0), r + Vector3(0.0, cfg.top, 0.0), 0.015)
			"corners":
				for sx in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						var c: Vector3 = cfg.pos + basis * Vector3(
							sx * size.x * 0.5, 0.0, sz * size.y * 0.5)
						_add_pole(c, cfg.top, 0.045)
		if cfg.has("boulder"):
			_add_boulder(cfg.pos + Vector3(0.0, cfg.boulder * 0.72, 0.0), cfg.boulder)

	# A few loose rocks so the ground plane reads as a place, not a void.
	for r in [[Vector3(-4.5, 0, 6.0), 0.5], [Vector3(9.0, 0, 2.5), 0.8],
			[Vector3(-9.0, 0, -5.0), 0.65], [Vector3(3.5, 0, -7.5), 0.45]]:
		_add_boulder(r[0] + Vector3(0.0, r[1] * 0.55, 0.0), r[1])


func _add_pole(base: Vector3, height: float, radius: float) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius * 0.85
	cyl.bottom_radius = radius
	cyl.height = height
	var pm := StandardMaterial3D.new()
	pm.albedo_color = WOOD
	pm.roughness = 0.75
	cyl.material = pm
	mi.mesh = cyl
	mi.position = base + Vector3(0.0, height * 0.5, 0.0)
	add_child(mi)


func _add_bar(from: Vector3, to: Vector3, radius: float) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = from.distance_to(to)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.2, 0.2, 0.21)
	pm.roughness = 0.5
	cyl.material = pm
	mi.mesh = cyl
	mi.position = (from + to) * 0.5
	var axis := (to - from).normalized()
	mi.basis = Basis(Quaternion(Vector3.UP, axis))
	add_child(mi)


func _add_boulder(center: Vector3, radius: float) -> void:
	var mi := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = radius
	sph.height = radius * 2.0
	var rm := StandardMaterial3D.new()
	rm.albedo_color = Color(0.45, 0.43, 0.4)
	rm.roughness = 0.95
	sph.material = rm
	mi.mesh = sph
	mi.position = center
	mi.scale = Vector3(1.0, 0.8, 0.92)
	add_child(mi)


# ── UI ───────────────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	menu.add_section("Scene")
	menu.add_button("↺ Reset", _restart)
	status_label = menu.add_label("")
	menu.add_separator()

	menu.add_section("Wind")
	menu.add_toggle("Wind", wind_enabled, _on_wind_toggled)
	wind_label = menu.add_label("")
	menu.add_slider("Speed", 0.0, 25.0, wind_speed, func(v): wind_speed = v)
	menu.add_slider("Gustiness", 0.0, 1.0, gustiness, func(v): gustiness = v)
	menu.add_slider("Turbulence", 0.05, 0.9, turbulence, func(v): turbulence = v)
	menu.add_toggle("Direction wanders", wind_wander, func(on): wind_wander = on)
	menu.add_slider("Direction °", 0.0, 360.0, wind_dir_deg, func(v): wind_dir_deg = v)
	menu.add_separator()

	menu.add_section("Fabric")
	menu.add_slider("Drag", 0.0, 3.0, solvers[0].drag, _set_all.bind("drag"))
	menu.add_slider("Stretch", 0.0, 6.0, 1.0, _on_stretch)
	menu.add_slider("Bending", 0.0, 6.0, 1.0, _on_bending)
	menu.add_slider("Damping", 0.97, 1.0, solvers[0].damping, _set_all.bind("damping"))
	menu.add_separator()

	menu.add_section("Solver")
	menu.add_slider("Iterations", 2.0, 20.0, float(solvers[0].iterations),
		_set_all_int.bind("iterations"))
	menu.add_slider("Substeps", 1.0, 6.0, float(solvers[0].substeps),
		_set_all_int.bind("substeps"))
	menu.add_slider("Relaxation", 1.0, 1.9, solvers[0].relaxation, _set_all.bind("relaxation"))
	menu.add_toggle("Profiler overlay", false, _on_profiler_toggled)
	_update_status()


func _on_wind_toggled(on: bool) -> void:
	wind_enabled = on
	for s in solvers:
		s.wind_enabled = on


func _set_all(v: float, property: String) -> void:
	for s in solvers:
		s.set(property, v)


func _set_all_int(v: float, property: String) -> void:
	for s in solvers:
		s.set(property, int(round(v)))
	_update_status()


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
	var total := 0
	for s in solvers:
		total += s.vertex_count()
	status_label.text = "%d sheets · %d vertices · %d substeps × %d iters" % [
		solvers.size(), total, solvers[0].substeps, solvers[0].iterations,
	]


# The compliance is in metres per newton: a decade of slider travel maps to five
# decades of compliance, which is the range where cloth goes from steel to jelly.
func _on_stretch(v: float) -> void:
	for s in solvers:
		s.stretch_compliance = pow(10.0, -9.0 + v)


func _on_bending(v: float) -> void:
	for s in solvers:
		s.bend_compliance = pow(10.0, -6.0 + v * 0.7)


func _restart() -> void:
	_teardown_solvers()
	for ci in CLOTHS.size():
		solvers[ci].set_seed(_seed_sheet(CLOTHS[ci], solvers[ci].grid_w, solvers[ci].grid_h))
	_time = 0.0
	_init_solvers()
	_update_status()


func _init_solvers() -> void:
	for s in solvers:
		RenderingServer.call_on_render_thread(s.init_render)


func _teardown_solvers() -> void:
	for t in pos_textures:
		t.texture_rd_rid = RID()
	pos_textures.clear()
	textures_bound = false
	for s in solvers:
		RenderingServer.call_on_render_thread(s.free_render)


func _on_profiler_toggled(on: bool) -> void:
	for s in solvers:
		s.profiling = on
	profiler_label.visible = on
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func _update_overlay() -> void:
	var total := 0.0
	var stages := {predict = 0.0, solve = 0.0, apply = 0.0}
	for s in solvers:
		var t := s.get_timings()
		total += t.get("total", 0.0)
		for k in stages:
			stages[k] += t.get(k, 0.0)
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	lines.append("sim GPU %.2f ms (%d sheets)" % [total, solvers.size()])
	lines.append("  predict %.2f | solve %.2f | apply %.2f" % [
		stages.predict, stages.solve, stages.apply,
	])
	lines.append("viewport GPU %.2f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	))
	profiler_label.text = "\n".join(lines)


# ── Frame loop ───────────────────────────────────────────────────────────────

# Slow wind on the CPU: the direction wanders through a couple of incommensurate
# sines and the speed breathes with a gust envelope; the shader adds the fast,
# spatially varying part on top of this vector.
func _current_wind() -> Vector3:
	var ang := deg_to_rad(wind_dir_deg)
	if wind_wander:
		ang += 0.8 * sin(_time * 0.13) + 1.1 * sin(_time * 0.047 + 1.7)
	var envelope := 1.0 + gustiness * (0.45 * sin(_time * 0.5)
		+ 0.35 * sin(_time * 1.13 + 2.0) + 0.2 * sin(_time * 2.9 + 0.7))
	return Vector3(cos(ang), 0.0, sin(ang)) * wind_speed * maxf(envelope, 0.0)


func _process(delta: float) -> void:
	for s in solvers:
		if not s.initialized:
			return
	if not textures_bound:
		for ci in solvers.size():
			var tex := Texture2DRD.new()
			tex.texture_rd_rid = solvers[ci].get_position_tex_rid()
			cloth_mats[ci].set_shader_parameter("position_tex", tex)
			pos_textures.append(tex)
		textures_bound = true
		return

	_time += delta
	var w := _current_wind()
	for s in solvers:
		s.wind = w
		s.wind_gust = gustiness
		s.wind_turb = turbulence
		s.time = _time
		RenderingServer.call_on_render_thread(s.step_render.bind(1.0 / 60.0))

	_profile_accum += delta
	if _profile_accum >= 0.25:
		_profile_accum = 0.0
		wind_label.text = "%.1f m/s @ %d°" % [w.length(),
			wrapi(int(rad_to_deg(atan2(w.z, w.x))), 0, 360)]
		if profiler_label.visible:
			_update_overlay()


func _exit_tree() -> void:
	for t in pos_textures:
		t.texture_rd_rid = RID()
	for s in solvers:
		RenderingServer.call_on_render_thread(s.free_render)
