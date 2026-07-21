extends Node3D
## Heightfield sand demo. The solver relaxes a GPU grid of column heights
## toward the angle of repose; this scene renders it as a displaced surface
## (heights never leave the GPU: compute image -> Texture2DRD -> vertex
## shader) and drives the brush tools. Grain-scale detail is the surface
## shader's job, so the sim resolution and the visual grain are decoupled.

const HeightfieldSand := preload("res://scripts/sand/heightfield_sand.gd")

const SCENE_SANDBOX := 0
const SCENE_DUNES := 1
const SCENE_POUR := 2

const SCENES: Array[Dictionary] = [
	{title = "Sandbox dig", tool = HeightfieldSand.TOOL_DIG},
	{title = "Dunes", tool = HeightfieldSand.TOOL_SMOOTH},
	{title = "Pouring", tool = HeightfieldSand.TOOL_POUR},
]

const WORLD := 4.0
const MESH_N := 512

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D

var solver := HeightfieldSand.new()
var scene_idx := 0
var tool_choice := HeightfieldSand.TOOL_DIG
var auto_pour := true

var height_texture: Texture2DRD
var texture_bound := false
var sand_mat: ShaderMaterial
var terrain: MeshInstance3D
var ground: MeshInstance3D
var walls: Node3D
var marker: MeshInstance3D
var dust: GPUParticles3D

var status_label: Label
var profiler_label: Label
var _time := 0.0
var _profile_accum := 0.0
var _dragging := false
var _aim := Vector2.ZERO
var _strength := 1.2


func _ready() -> void:
	solver.grid_n = GameManager.get_setting("sand_grid_n", 512)
	solver.world_size = WORLD

	orbit_cam.pitch = -30.0
	orbit_cam.yaw = 35.0
	orbit_cam.min_distance = 0.5
	orbit_cam.max_distance = 40.0
	orbit_cam.move_speed = 2.0

	_build_world()
	_setup_ui()
	_setup_profiler()
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


# ── Scene setup ──────────────────────────────────────────────────────────────

func _apply_scene() -> void:
	tool_choice = SCENES[scene_idx].tool
	solver.tool_mode = HeightfieldSand.TOOL_NONE
	match scene_idx:
		SCENE_SANDBOX:
			solver.set_seed(_seed_flat(0.35))
			orbit_cam.target = Vector3(0.0, 0.3, 0.0)
			orbit_cam.distance = 4.5
		SCENE_DUNES:
			solver.set_seed(_seed_dunes())
			orbit_cam.target = Vector3(0.0, 0.35, 0.0)
			orbit_cam.distance = 5.5
		SCENE_POUR:
			solver.set_seed(_seed_flat(0.02))
			orbit_cam.target = Vector3(0.0, 0.5, 0.0)
			orbit_cam.distance = 5.0
	walls.visible = scene_idx != SCENE_DUNES
	sand_mat.set_shader_parameter("grid_n", float(solver.grid_n))
	_time = 0.0
	_sync_tool_ui()
	if status_label != null:
		_update_status()


func _seed_flat(h: float) -> PackedFloat32Array:
	var n := solver.grid_n
	var out := PackedFloat32Array()
	out.resize(n * n)
	out.fill(h)
	return out


func _seed_dunes() -> PackedFloat32Array:
	var n := solver.grid_n
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.55
	noise.fractal_octaves = 4
	var out := PackedFloat32Array()
	out.resize(n * n)
	var cell := WORLD / float(n)
	for j in n:
		var z := (float(j) + 0.5) * cell - WORLD * 0.5
		var row := j * n
		for i in n:
			var x := (float(i) + 0.5) * cell - WORLD * 0.5
			out[row + i] = 0.12 + 0.45 * (noise.get_noise_2d(x, z) * 0.5 + 0.5)
	return out


# ── World geometry ───────────────────────────────────────────────────────────

func _build_world() -> void:
	ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(WORLD * 3.0, WORLD * 3.0)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.30, 0.28, 0.26)
	gm.roughness = 1.0
	plane.material = gm
	ground.mesh = plane
	ground.position.y = -0.002
	add_child(ground)

	sand_mat = ShaderMaterial.new()
	sand_mat.shader = load("res://shaders/sand/sand_surface.gdshader")
	sand_mat.set_shader_parameter("world_size", WORLD)
	terrain = MeshInstance3D.new()
	terrain.mesh = _build_terrain_mesh()
	terrain.material_override = sand_mat
	terrain.custom_aabb = AABB(
		Vector3(-WORLD * 0.5, -0.1, -WORLD * 0.5), Vector3(WORLD, 3.0, WORLD)
	)
	add_child(terrain)

	walls = Node3D.new()
	add_child(walls)
	_build_box_walls()

	marker = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.2
	cyl.radial_segments = 32
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.9, 0.45, 0.2, 0.15)
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.no_depth_test = false
	cyl.material = mm
	marker.mesh = cyl
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.position.y = 0.6
	add_child(marker)
	_scale_marker()

	dust = _build_dust()
	add_child(dust)

	sun.shadow_enabled = true


# Flat vertex grid displaced by the shader. One extra ring around the border
# sits on the domain edge with COLOR.r = 0, so its verts stay on the floor and
# the border quads become the sheet's side walls — no open underside visible.
func _build_terrain_mesh() -> ArrayMesh:
	var n := MESH_N
	var side := n + 2
	var verts := PackedVector3Array()
	verts.resize(side * side)
	var uvs := PackedVector2Array()
	uvs.resize(side * side)
	var colors := PackedColorArray()
	colors.resize(side * side)
	var cell := WORLD / float(n)
	for j in range(-1, n + 1):
		for i in range(-1, n + 1):
			var ci := clampi(i, 0, n - 1)
			var cj := clampi(j, 0, n - 1)
			var inner := i == ci and j == cj
			var x := (float(ci) + 0.5) * cell - WORLD * 0.5
			var z := (float(cj) + 0.5) * cell - WORLD * 0.5
			if not inner:
				x += signf(float(i - ci)) * 0.5 * cell
				z += signf(float(j - cj)) * 0.5 * cell
			var idx := (j + 1) * side + (i + 1)
			verts[idx] = Vector3(x, 0.0, z)
			uvs[idx] = Vector2((float(ci) + 0.5) / float(n), (float(cj) + 0.5) / float(n))
			colors[idx] = Color.WHITE if inner else Color.BLACK
	var quads := side - 1
	var indices := PackedInt32Array()
	indices.resize(quads * quads * 6)
	var k := 0
	for j in quads:
		for i in quads:
			var a := j * side + i
			indices[k] = a
			indices[k + 1] = a + side
			indices[k + 2] = a + side + 1
			indices[k + 3] = a
			indices[k + 4] = a + side + 1
			indices[k + 5] = a + 1
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Low sandbox rim on the domain boundary the flow already treats as a wall.
func _build_box_walls() -> void:
	var thickness := 0.1
	var height := 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.32, 0.22)
	mat.roughness = 0.95
	var half := WORLD * 0.5
	var sides := [
		[Vector3(0, height * 0.5, half + thickness * 0.5), Vector3(WORLD + thickness * 2.0, height, thickness)],
		[Vector3(0, height * 0.5, -half - thickness * 0.5), Vector3(WORLD + thickness * 2.0, height, thickness)],
		[Vector3(half + thickness * 0.5, height * 0.5, 0), Vector3(thickness, height, WORLD)],
		[Vector3(-half - thickness * 0.5, height * 0.5, 0), Vector3(thickness, height, WORLD)],
	]
	for s in sides:
		var box := BoxMesh.new()
		box.size = s[1]
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = s[0]
		walls.add_child(mi)


func _build_dust() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 220
	p.lifetime = 1.1
	p.emitting = false
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.2
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3(0, -1.2, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 0.72, 0.52, 0.0))
	ramp.add_point(0.15, Color(0.85, 0.72, 0.52, 0.30))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.85, 0.72, 0.52, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color.WHITE
	# Soft radial falloff — an untextured quad reads as a hard square.
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(0.5, 0.0)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	soft.gradient = g
	dm.albedo_texture = soft
	dm.vertex_color_use_as_albedo = true
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material = dm
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


# ── UI ───────────────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	var titles := []
	for s in SCENES:
		titles.append(s.title)

	menu.add_section("Scene")
	menu.add_option_button("Preset", titles, scene_idx, _on_scene_selected)
	menu.add_action("↺", "Reset", _restart)
	status_label = menu.add_label("")
	menu.add_separator()

	menu.add_section("Tool")
	menu.add_option_button("Brush", ["Dig", "Pour", "Smooth"], tool_choice - 1,
		func(idx): tool_choice = idx + 1)
	menu.add_slider("Brush size", 0.08, 0.8, solver.tool_radius, _on_brush_size)
	menu.add_slider("Strength", 0.3, 3.0, _strength, func(v): _strength = v)
	menu.add_toggle("Auto pour (pouring scene)", auto_pour, func(on): auto_pour = on)
	menu.add_label("Right-click drag to sculpt")
	menu.add_separator()

	menu.add_section("Sand")
	menu.add_slider("Repose angle °", 20.0, 45.0, solver.repose_deg, _on_repose)
	menu.add_slider("Flow rate", 0.03, 0.12, solver.flow_rate,
		func(v): solver.flow_rate = v)
	menu.add_slider("Settle iterations", 2.0, 16.0, float(solver.iterations),
		func(v): solver.iterations = int(round(v)))
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("📊", "Profiler overlay", false, _on_profiler_toggled)
	menu.add_label("Grid resolution")
	menu.add_button("256²", func(): _set_grid_n(256))
	menu.add_button("512²", func(): _set_grid_n(512))
	menu.add_button("1024²", func(): _set_grid_n(1024))
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
	status_label.text = "%d² cells · %.1f mm/cell · repose %.0f°" % [
		solver.grid_n, solver.cell_size() * 1000.0, solver.repose_deg,
	]


func _sync_tool_ui() -> void:
	_scale_marker()


func _on_scene_selected(idx: int) -> void:
	scene_idx = idx
	_restart()


func _on_brush_size(v: float) -> void:
	solver.tool_radius = v
	_scale_marker()


func _on_repose(v: float) -> void:
	solver.repose_deg = v
	_update_status()


func _scale_marker() -> void:
	marker.scale = Vector3(solver.tool_radius, 1.0, solver.tool_radius)


func _set_grid_n(n: int) -> void:
	if n == solver.grid_n:
		return
	_teardown_solver()
	solver.grid_n = n
	GameManager.set_setting("sand_grid_n", n)
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)
	_update_status()


func _restart() -> void:
	_teardown_solver()
	_apply_scene()
	RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solver() -> void:
	if height_texture != null:
		height_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


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
	lines.append("viewport GPU %.2f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	))
	profiler_label.text = "\n".join(lines)


# ── Tool control ─────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = event.pressed
		if _dragging:
			_aim_tool(event.position)
	elif event is InputEventMouseMotion:
		_aim_tool(event.position)


func _aim_tool(screen_pos: Vector2) -> void:
	var origin := main_cam.project_ray_origin(screen_pos)
	var dir := main_cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-4:
		return
	var t := -origin.y / dir.y
	if t < 0.0:
		return
	var hit := origin + dir * t
	var limit := WORLD * 0.5
	_aim = Vector2(clampf(hit.x, -limit, limit), clampf(hit.z, -limit, limit))


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		height_texture = Texture2DRD.new()
		height_texture.texture_rd_rid = solver.get_height_tex_rid()
		sand_mat.set_shader_parameter("height_tex", height_texture)
		texture_bound = true
		return

	_time += delta

	var pouring := scene_idx == SCENE_POUR and auto_pour and not _dragging
	if _dragging:
		solver.tool_mode = tool_choice
		solver.tool_pos = _aim
		solver.tool_strength = _strength
	elif pouring:
		# A slow orbit leaves a ridge of overlapping cones — the repose angle
		# is what shapes it, so this doubles as the physics showcase.
		var r := 0.9
		solver.tool_mode = HeightfieldSand.TOOL_POUR
		solver.tool_pos = Vector2(cos(_time * 0.5) * r, sin(_time * 0.5) * r)
		solver.tool_strength = 1.8
	else:
		solver.tool_mode = HeightfieldSand.TOOL_NONE

	marker.position = Vector3(_aim.x, 0.6, _aim.y)
	marker.visible = not pouring or _dragging
	var active := solver.tool_mode != HeightfieldSand.TOOL_NONE
	dust.position = Vector3(solver.tool_pos.x, 0.45, solver.tool_pos.y)
	dust.emitting = active and solver.tool_mode != HeightfieldSand.TOOL_SMOOTH

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta))
	_profile_accum += delta
	if profiler_label.visible and _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()


func _exit_tree() -> void:
	if height_texture != null:
		height_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
