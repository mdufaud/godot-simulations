class_name ScreenSpaceFluidRenderer
extends Node3D
## Reusable screen-space fluid surface. Given a solver's position texture (xyz =
## world pos, w = speed for water / temperature for lava) it reconstructs a smooth
## liquid surface: sphere-impostor depth prepass -> separable bilateral depth
## filter -> thickness -> full-screen composite (dielectric Fresnel + Snell
## refraction + Beer absorption + sky/sun reflection, lava blackbody branch).
##
## Solver-agnostic: the owner feeds the position texture RID and the visible
## particle count each frame through update(). Optional white-particle (foam)
## coverage is built when build_foam is set and its texture fed alongside.
##
## Instance it, set the config vars, add_child, call start(); then call update()
## once per frame from the owner's _process. The owner keeps the camera rig,
## environment and simulation; this node owns only the surface rendering.

const LAYER_DEPTH := 2
const LAYER_THICK := 4
const LAYER_FOAM := 8

# --- Configuration (set before start()). ---
var camera: Camera3D # REQUIRED: the main camera the prepass cameras track.
var particle_count := 0
var tex_width := 256
var radius := 0.16
var mode := 0.0 # 0 = water, 1 = lava
var render_scale := 0.5
var domain_aabb := AABB(Vector3(-8.0, 0.0, -8.0), Vector3(16.0, 16.0, 16.0))
## Build the foam coverage pass. When false the composite gets a black foam
## texture (no coverage) and no foam MultiMesh is allocated.
var build_foam := false
var foam_cap := 0
var foam_tex_width := 1024
var foam_billboard_size := 0.05

var mm: MultiMesh
var foam_mm: MultiMesh
var foam_mmi: MultiMeshInstance3D
var depth_cam: Camera3D
var thick_cam: Camera3D
var foam_cam: Camera3D
var depth_vp: SubViewport
var thick_vp: SubViewport
var foam_vp: SubViewport
var filter_h_vp: SubViewport
var filter_v_vp: SubViewport
var depth_mat: ShaderMaterial
var thick_mat: ShaderMaterial
var filter_h_mat: ShaderMaterial
var filter_v_mat: ShaderMaterial
var composite_mat: ShaderMaterial
var foam_mat: ShaderMaterial

var pos_texture: Texture2DRD
var foam_pos_texture: Texture2DRD
var _tex_bound := false
var _foam_bound := false
var _foam_visible := false


func start() -> void:
	assert(camera != null, "ScreenSpaceFluidRenderer.camera must be set before start()")
	camera.cull_mask = 0xFFFFF & ~(LAYER_DEPTH | LAYER_THICK | LAYER_FOAM)
	mm = _build_multimesh()
	_setup_prepass()
	_setup_filters()
	_setup_foam_render()
	_setup_composite()


func composite_material() -> ShaderMaterial:
	return composite_mat


func profiled_viewports() -> Array:
	return [depth_vp, thick_vp, filter_h_vp, filter_v_vp, foam_vp]


# --- Runtime control -------------------------------------------------------

func set_radius(r: float) -> void:
	radius = r
	depth_mat.set_shader_parameter("particle_radius", radius)
	thick_mat.set_shader_parameter("particle_radius", radius)
	filter_h_mat.set_shader_parameter("particle_radius", radius)
	filter_v_mat.set_shader_parameter("particle_radius", radius)


func set_mode(m: float) -> void:
	mode = m
	composite_mat.set_shader_parameter("mode", mode)


func set_particle_count(n: int) -> void:
	particle_count = n
	_fill_mm(mm)


func set_visible_count(n: int) -> void:
	if mm != null:
		mm.visible_instance_count = n


## Whether the foam billboards draw. Hiding foam_mmi leaves the foam viewport
## clearing to black, i.e. no coverage. No-op when build_foam is false.
func set_foam_visible(on: bool) -> void:
	_foam_visible = on
	if foam_mmi != null:
		foam_mmi.visible = on and _foam_bound


func set_render_scale(v: float) -> void:
	render_scale = v
	var scaled := _scaled_size()
	depth_vp.size = scaled
	thick_vp.size = _thick_size(scaled)
	filter_h_vp.size = scaled
	filter_v_vp.size = scaled
	var proj_scale := _proj_scale(scaled)
	filter_h_mat.set_shader_parameter("proj_scale", proj_scale)
	filter_v_mat.set_shader_parameter("proj_scale", proj_scale)


## Drop the bound position/foam textures so a re-initialised solver rebinds its
## fresh RIDs on the next update(). Call when the owner tears the solver down.
func rebind() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	if foam_pos_texture != null:
		foam_pos_texture.texture_rd_rid = RID()
	_tex_bound = false
	_foam_bound = false
	if foam_mmi != null:
		foam_mmi.visible = false


# --- Per-frame -------------------------------------------------------------

## pos_tex_rid: the solver's live position texture. visible_count: particles to
## draw. foam_tex_rid: the SPH foam pool texture (only when build_foam).
func update(pos_tex_rid: RID, visible_count: int, foam_tex_rid: RID = RID()) -> void:
	if not _tex_bound and pos_tex_rid.is_valid():
		pos_texture = Texture2DRD.new()
		pos_texture.texture_rd_rid = pos_tex_rid
		depth_mat.set_shader_parameter("position_tex", pos_texture)
		thick_mat.set_shader_parameter("position_tex", pos_texture)
		_tex_bound = true
	if build_foam and not _foam_bound and foam_tex_rid.is_valid():
		foam_pos_texture = Texture2DRD.new()
		foam_pos_texture.texture_rd_rid = foam_tex_rid
		foam_mat.set_shader_parameter("foam_tex", foam_pos_texture)
		_foam_bound = true
		foam_mmi.visible = _foam_visible
	set_visible_count(visible_count)
	_sync_cams()


func _exit_tree() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	if foam_pos_texture != null:
		foam_pos_texture.texture_rd_rid = RID()


# --- Render chain (built once) --------------------------------------------

func _build_multimesh() -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	m.mesh = quad
	m.custom_aabb = domain_aabb
	_fill_mm(m)
	return m


func _fill_mm(m: MultiMesh) -> void:
	m.instance_count = particle_count
	var buf := PackedFloat32Array()
	buf.resize(particle_count * 12)
	for i in particle_count:
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


func _setup_prepass() -> void:
	depth_mat = ShaderMaterial.new()
	depth_mat.shader = load("res://shaders/fluid/fluid_impostor.gdshader")
	depth_mat.set_shader_parameter("tex_width", tex_width)
	depth_mat.set_shader_parameter("particle_radius", radius)
	thick_mat = ShaderMaterial.new()
	thick_mat.shader = load("res://shaders/fluid/fluid_thickness.gdshader")
	thick_mat.set_shader_parameter("tex_width", tex_width)
	thick_mat.set_shader_parameter("particle_radius", radius)

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

	var scaled := _scaled_size()
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
	mat.shader = load("res://shaders/fluid/fluid_depth_filter.gdshader")
	mat.set_shader_parameter("depth_tex", src)
	mat.set_shader_parameter("direction", dir)
	mat.set_shader_parameter("particle_radius", radius)
	mat.set_shader_parameter("proj_scale", proj_scale)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)
	return vp


func _setup_filters() -> void:
	var scaled := _scaled_size()
	var proj_scale := _proj_scale(scaled)
	filter_h_vp = _make_filter_vp(scaled, Vector2(1, 0), depth_vp.get_texture(), proj_scale)
	filter_v_vp = _make_filter_vp(scaled, Vector2(0, 1), filter_h_vp.get_texture(), proj_scale)
	filter_h_mat = (filter_h_vp.get_child(0) as ColorRect).material
	filter_v_mat = (filter_v_vp.get_child(0) as ColorRect).material


func _setup_composite() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	composite_mat = ShaderMaterial.new()
	composite_mat.shader = load("res://shaders/fluid/fluid_composite.gdshader")
	composite_mat.set_shader_parameter("fluid_depth_tex", filter_v_vp.get_texture())
	composite_mat.set_shader_parameter("thickness_tex", thick_vp.get_texture())
	if build_foam:
		composite_mat.set_shader_parameter("foam_tex", foam_vp.get_texture())
	else:
		composite_mat.set_shader_parameter("foam_tex", _black_texture())
	composite_mat.set_shader_parameter("mode", mode)
	quad.material = composite_mat
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	add_child(mi)


## Zero-coverage stand-in for the foam texture when foam is not built: the
## composite's default sampler2D is opaque white, which would read as full foam.
func _black_texture() -> Texture2D:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	img.set_pixel(0, 0, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


func _setup_foam_render() -> void:
	if not build_foam:
		return
	foam_mm = MultiMesh.new()
	foam_mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	foam_mm.mesh = quad
	foam_mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	foam_mm.instance_count = foam_cap
	# A per-instance loop takes seconds at a million instances: build one identity
	# transform and double the byte pattern instead (memcpy speed).
	var one := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]).to_byte_array()
	var bytes := one
	while bytes.size() < foam_cap * 48:
		bytes.append_array(bytes.duplicate())
	bytes.resize(foam_cap * 48)
	foam_mm.buffer = bytes.to_float32_array()

	foam_mat = ShaderMaterial.new()
	foam_mat.shader = load("res://shaders/foam/foam_billboard.gdshader")
	foam_mat.set_shader_parameter("foam_tex_width", foam_tex_width)
	foam_mat.set_shader_parameter("billboard_size", foam_billboard_size)

	foam_mmi = MultiMeshInstance3D.new()
	foam_mmi.multimesh = foam_mm
	foam_mmi.material_override = foam_mat
	foam_mmi.layers = LAYER_FOAM
	foam_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	foam_mmi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	foam_mmi.visible = false
	add_child(foam_mmi)

	# Foam renders to its own coverage buffer instead of over the finished image,
	# so the composite can treat it as opaque white and occlude it correctly.
	# Hiding foam_mmi leaves this viewport clearing to black, i.e. no coverage.
	foam_vp = SubViewport.new()
	foam_vp.size = _foam_size()
	foam_vp.use_hdr_2d = true
	foam_vp.own_world_3d = false
	foam_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	foam_vp.positional_shadow_atlas_size = 0
	foam_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(foam_vp)
	foam_cam = _make_prepass_cam(LAYER_FOAM)
	foam_vp.add_child(foam_cam)
	foam_cam.current = true


# --- Sizing helpers --------------------------------------------------------

func _scaled_size() -> Vector2i:
	var s := Vector2(camera.get_viewport().size) * render_scale
	return Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))


# Foam sprites are small and high-frequency, so the coverage buffer stays at full
# resolution regardless of render_scale — at half res they magnify into squares.
func _foam_size() -> Vector2i:
	var s := Vector2(camera.get_viewport().size)
	return Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))


# Thickness is low-frequency and sampled with filter_linear: half the prepass res.
func _thick_size(scaled: Vector2i) -> Vector2i:
	return Vector2i(maxi(scaled.x / 2, 1), maxi(scaled.y / 2, 1))


func _proj_scale(scaled: Vector2i) -> float:
	return float(scaled.y) * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)


func _sync_cams() -> void:
	for cam in [depth_cam, thick_cam, foam_cam]:
		if cam == null:
			continue
		cam.global_transform = camera.global_transform
		cam.fov = camera.fov
		cam.near = camera.near
		cam.far = camera.far
