class_name FirePresentation extends Node3D
## Everything the fire demo puts on screen: the volume raymarcher's bindings, the
## half-resolution volume pass and the screen-space water surface.
##
## Holds no simulation state — it reads the solver's textures and the SPH position
## texture and owns the Texture3DRD wrappers around them, which is why it also owns
## their teardown. The host must assign [member solver], [member water],
## [member fire_volume] and [member camera] before [method start].
##
##     var presentation := FirePresentation.new()
##     presentation.solver = solver
##     presentation.water = water
##     presentation.fire_volume = $FireVolume
##     presentation.camera = player.get_camera()
##     add_child(presentation)
##     presentation.start()

## Visual layer the volume mesh moves to when the half-res pass is on, so the main
## camera stops drawing it and only the half-res camera does. Bits 2/4/8 belong to
## ScreenSpaceFluidRenderer's prepasses.
const LAYER_FIRE_VOLUME := 16
const VOLUME_UPSAMPLE_SHADER := "res://shaders/fire/fire_volume_upsample.gdshader"

const FireSceneDistance = preload("res://scripts/fire/fire_scene_distance.gd")

var solver: FireGpuSolver
var water: FireWater
var fire_volume: MeshInstance3D
var camera: Camera3D
var fire_light: OmniLight3D
var sparks: GPUParticles3D

var volume_material: ShaderMaterial
var fluid_renderer: ScreenSpaceFluidRenderer
var texture_bound := false
var temporal_interpolation := false

var _volume_texture: Texture3DRD
var _previous_volume_texture: Texture3DRD
var _indir_texture: Texture3DRD
var _previous_indir_texture: Texture3DRD
var _visual_activity_texture: Texture3DRD
var _previous_visual_activity_texture: Texture3DRD

var _volume_half_res := false
var _volume_vp: SubViewport
var _volume_cam: Camera3D
var _volume_composite: MeshInstance3D
var _volume_composite_mat: ShaderMaterial
var _scene_distance: CompositorEffect
var _scene_distance_tex: Texture2DRD
var _volume_vp_size := Vector2i.ZERO
var _external_depth_bound := false
var _released := false
var _smooth_light_energy := 0.0
var _smooth_light_range := 8.0


func start() -> void:
	assert(solver != null and water != null, "FirePresentation: solver and water required")
	assert(fire_volume != null and camera != null, "FirePresentation: fire_volume and camera required")
	volume_material = fire_volume.material_override as ShaderMaterial
	if volume_material:
		_setup_volume_material()
	_setup_fluid_renderer()
	_setup_half_res_volume()


## Binds the solver's textures on the first frame they exist, then tracks the
## display proxy, which follows the resident tiles.
func update_volume() -> void:
	if not texture_bound:
		_bind_textures()
	if volume_material:
		_set_volume_proxy(solver.display_clip_box())


func update_water_surface() -> void:
	if water.initialized:
		fluid_renderer.update(water.sph_position_tex_rid(), water.particles_active)


## Drives the hearth light and the sparks off the solver's reduced stats.
func update_effects(stats: Dictionary, delta: float) -> void:
	if sparks != null:
		sparks.emitting = stats["max_reaction"] > 0.1
	if fire_light == null:
		return

	var light_blend := clampf(3.0 * delta, 0.0, 1.0)
	var temp_norm := clampf(
		(stats["max_temperature"] - solver.ambient_temperature)
			/ (solver.display_temperature - solver.ambient_temperature),
		0.0, 1.0
	)

	_smooth_light_energy = lerpf(_smooth_light_energy, temp_norm * 8.0, light_blend)
	_smooth_light_range = lerpf(_smooth_light_range, 8.0 + temp_norm * 14.0, light_blend)

	fire_light.light_energy = _smooth_light_energy
	fire_light.omni_range = _smooth_light_range

	# Planck-like mapping: dull red embers through to near-white at peak.
	var light_color := Color(1.0, 0.55, 0.15)
	if temp_norm > 0.7:
		light_color = light_color.lerp(Color(1.0, 0.9, 0.7), (temp_norm - 0.7) / 0.3)
	elif temp_norm < 0.3:
		light_color = light_color.lerp(Color(0.8, 0.3, 0.1), 1.0 - temp_norm / 0.3)
	fire_light.light_color = light_color

	var flicker := 1.0 - 0.02 * sin(Time.get_ticks_msec() * 0.01) * cos(Time.get_ticks_msec() * 0.017)
	fire_light.light_energy *= flicker


## Puts the hearth light back where a fresh fire starts, so a fuel switch or a
## reset does not fade down from the old flame's brightness.
func reset_light() -> void:
	_smooth_light_energy = 0.0
	_smooth_light_range = 8.0


func refresh_temporal_blend() -> void:
	set_volume_parameter("temporal_blend",
		solver.interpolation_alpha() if temporal_interpolation else 1.0)


func set_temporal_interpolation(on: bool) -> void:
	temporal_interpolation = on
	refresh_temporal_blend()
	if on and solver.initialized:
		RenderingServer.call_on_render_thread(solver.capture_interpolation_state_render)


func set_volume_parameter(name: String, value: Variant) -> void:
	if volume_material != null:
		volume_material.set_shader_parameter(name, value)


func set_water_render_scale(value: float) -> void:
	if fluid_renderer != null:
		fluid_renderer.set_render_scale(value)


func set_water_radius(value: float) -> void:
	fluid_renderer.set_radius(value)


## Drops the display bindings so the solver may free and rebuild its textures.
func unbind_textures() -> void:
	_clear_volume_rids()
	fire_volume.visible = false
	texture_bound = false


func set_half_res(on: bool) -> void:
	if _volume_vp == null:
		return
	_volume_half_res = on
	fire_volume.layers = LAYER_FIRE_VOLUME if on else 1
	camera.cull_mask = (camera.cull_mask & ~LAYER_FIRE_VOLUME) if on \
		else (camera.cull_mask | LAYER_FIRE_VOLUME)
	_volume_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on \
		else SubViewport.UPDATE_DISABLED
	_scene_distance.enabled = on
	if not on:
		_external_depth_bound = false
		set_volume_parameter("external_scene_depth", false)
		_volume_composite.visible = false


## Track the window, the global render scale and the distance texture's RID, all
## three of which can change under a running demo.
func update_half_res() -> void:
	if not _volume_half_res:
		return
	_volume_cam.global_transform = camera.global_transform
	_volume_cam.fov = camera.fov
	_volume_cam.near = camera.near
	_volume_cam.far = camera.far
	# Half of what the main viewport actually renders at, not half of the window:
	# the global render scale already shrinks the main render, and the composite's
	# upsample assumes the two agree.
	var vp := get_viewport()
	var internal := Vector2(vp.size) * vp.scaling_3d_scale
	var half := Vector2i(maxi(int(internal.x) / 2, 1), maxi(int(internal.y) / 2, 1))
	if half != _volume_vp_size:
		_volume_vp_size = half
		_volume_vp.size = half
		_volume_composite_mat.set_shader_parameter("low_res_size", Vector2(half))
	# The effect allocates its texture on the render thread, so the first frames
	# after the toggle have no distance texture at all. Binding a Texture2DRD that
	# holds no RD texture yet builds a material uniform set the pipeline rejects
	# ("Uniforms supplied for set (3) are not the same format"), and marching
	# against the sampler's white fallback would truncate every ray at 1 m — so
	# both the parameter and the external-depth switch wait for a live RID.
	var dist: RID = _scene_distance.output_rid
	if not dist.is_valid():
		return
	if _scene_distance_tex == null:
		_scene_distance_tex = Texture2DRD.new()
	if _scene_distance_tex.texture_rd_rid != dist:
		# Assigning straight over a live RID goes through texture_replace, which frees
		# the RD texture underneath it — one the effect owns and recycles. Clearing
		# first only drops the wrapper, which is all that should happen here.
		_scene_distance_tex.texture_rd_rid = RID()
		_scene_distance_tex.texture_rd_rid = dist
		set_volume_parameter("scene_distance_tex", _scene_distance_tex)
		_volume_composite_mat.set_shader_parameter("scene_distance_tex", _scene_distance_tex)
		_external_depth_bound = false
	if not _external_depth_bound:
		_external_depth_bound = true
		set_volume_parameter("external_scene_depth", true)
	_volume_composite.visible = fire_volume.visible


## Idempotent: the host calls this before it frees the solver, and _exit_tree
## covers the paths that never reach the host.
func release() -> void:
	if _released:
		return
	_released = true
	if _scene_distance_tex != null:
		_scene_distance_tex.texture_rd_rid = RID()
	if _scene_distance != null:
		RenderingServer.call_on_render_thread(_scene_distance.free_render)
	_clear_volume_rids()


func _exit_tree() -> void:
	release()


func _bind_textures() -> void:
	_volume_texture = Texture3DRD.new()
	_volume_texture.texture_rd_rid = solver.get_display_tex_rid()
	_previous_volume_texture = Texture3DRD.new()
	_previous_volume_texture.texture_rd_rid = solver.get_previous_display_tex_rid()
	if volume_material:
		volume_material.set_shader_parameter("volume_tex", _volume_texture)
		volume_material.set_shader_parameter("volume_tex_prev", _previous_volume_texture)
		# The display field is an atlas of resident tiles, so the shader also needs
		# the map from virtual tile to atlas slot to read it.
		_indir_texture = Texture3DRD.new()
		_indir_texture.texture_rd_rid = solver.indirection_bytes_rid()
		volume_material.set_shader_parameter("indir_tex", _indir_texture)
		_previous_indir_texture = Texture3DRD.new()
		_previous_indir_texture.texture_rd_rid = solver.previous_indirection_bytes_rid()
		volume_material.set_shader_parameter("indir_tex_prev", _previous_indir_texture)
		_visual_activity_texture = Texture3DRD.new()
		_visual_activity_texture.texture_rd_rid = solver.get_visual_activity_tex_rid()
		volume_material.set_shader_parameter("visual_activity_tex", _visual_activity_texture)
		_previous_visual_activity_texture = Texture3DRD.new()
		_previous_visual_activity_texture.texture_rd_rid = \
			solver.get_previous_visual_activity_tex_rid()
		volume_material.set_shader_parameter("visual_activity_tex_prev",
			_previous_visual_activity_texture)
	fire_volume.visible = true
	texture_bound = true


func _clear_volume_rids() -> void:
	for texture in [_volume_texture, _previous_volume_texture, _indir_texture,
			_previous_indir_texture, _visual_activity_texture,
			_previous_visual_activity_texture]:
		if texture != null:
			texture.texture_rd_rid = RID()


## Point the raymarcher at the grid the solver runs on.
func _setup_volume_material() -> void:
	var box := Vector3(solver.sim_dims()) * solver.cell_size
	volume_material.set_shader_parameter("cell_size", solver.cell_size)
	volume_material.set_shader_parameter("atlas_cells", Vector3(FireTilePool.ATLAS_CELLS))
	volume_material.set_shader_parameter("atlas_tiles", FireTilePool.ATLAS_TILES)
	volume_material.set_shader_parameter("virtual_tiles", FireTilePool.VTILES)
	volume_material.set_shader_parameter("virtual_origin",
		Vector3(-box.x * 0.5, 0.0, -box.z * 0.5))
	_set_volume_proxy(solver.display_clip_box())
	# The blue reaction core fades over the height of a burner-sized domain; over
	# the virtual one it would never fade at all.
	volume_material.set_shader_parameter("blue_height", solver.dense_domain_size_m().y)
	# The volume stores temperature normalised against these, so the shader
	# needs them to turn the red channel back into kelvins.
	volume_material.set_shader_parameter("ambient_temperature", solver.ambient_temperature)
	volume_material.set_shader_parameter("display_temperature", solver.display_temperature)
	# Nothing to march until the solver's textures exist: an unbound sampler falls
	# back to Godot's default texture, which for the indirection volume is not even
	# the right format to read.
	fire_volume.visible = false


func _set_volume_proxy(proxy: AABB) -> void:
	var extent := proxy.size
	(fire_volume.mesh as BoxMesh).size = extent
	fire_volume.position = proxy.position + extent * 0.5
	volume_material.set_shader_parameter("box_size", extent)
	volume_material.set_shader_parameter("volume_origin", proxy.position)
	volume_material.set_shader_parameter("volume_extent", extent)


## Screen-space fluid surface over the SPH position texture, reusing the fluid
## demo's render chain (ScreenSpaceFluidRenderer) instead of per-particle sphere
## impostors, so the droplets read as one connected body of water and a clean
## puddle rather than colored balls. The renderer binds the position texture
## lazily once the queued init_render has produced the RID (see its update()).
func _setup_fluid_renderer() -> void:
	fluid_renderer = ScreenSpaceFluidRenderer.new()
	fluid_renderer.camera = camera
	fluid_renderer.particle_count = water.particle_count
	fluid_renderer.tex_width = water.sph_tex_width()
	fluid_renderer.radius = 0.05
	fluid_renderer.mode = 0.0
	fluid_renderer.render_scale = 1.0
	# Matches the fire grid box so the surface MultiMesh is not frustum-culled.
	var domain_size := solver.dense_domain_size_m()
	fluid_renderer.domain_aabb = AABB(Vector3(-0.5, 0.0, -0.5) * domain_size, domain_size)
	# Foam deferred: land the clean surface + puddle first.
	fluid_renderer.build_foam = false
	add_child(fluid_renderer)
	fluid_renderer.start()

	var cm := fluid_renderer.composite_material()
	cm.render_priority = 0
	cm.set_shader_parameter("sky_zenith", Color(0.08, 0.28, 0.5))
	cm.set_shader_parameter("sky_horizon", Color(0.16, 0.5, 0.8))
	cm.set_shader_parameter("sun_intensity", 0.0)
	cm.set_shader_parameter("tint_color", Color(0.06, 0.38, 0.68))
	cm.set_shader_parameter("absorption_scale", 0.25)


## Phase 6 item 1: march the volume at half the linear resolution — a quarter of
## the rays — and put it back on screen with a depth-aware upsample.
##
## The volume mesh stays exactly where it is in the world; what moves is which
## camera is allowed to see it. On its own visual layer the main camera skips it
## and a half-res SubViewport camera draws it instead, so nothing about the march
## changes except how many fragments run it. The one thing a SubViewport cannot
## have is the main render's depth buffer, which is what the ray stops against —
## FireSceneDistance publishes it as a texture (see that class for the one-frame
## lag this implies).
func _setup_half_res_volume() -> void:
	_volume_vp = SubViewport.new()
	_volume_vp.own_world_3d = false
	_volume_vp.transparent_bg = true
	_volume_vp.use_hdr_2d = true
	_volume_vp.msaa_3d = Viewport.MSAA_DISABLED
	_volume_vp.positional_shadow_atlas_size = 0
	_volume_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_volume_vp.size = Vector2i(2, 2)
	add_child(_volume_vp)
	_volume_cam = Camera3D.new()
	_volume_cam.cull_mask = LAYER_FIRE_VOLUME
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	_volume_cam.environment = env
	_volume_vp.add_child(_volume_cam)
	_volume_cam.current = true

	_volume_composite_mat = ShaderMaterial.new()
	_volume_composite_mat.shader = load(VOLUME_UPSAMPLE_SHADER)
	_volume_composite_mat.set_shader_parameter("volume_tex", _volume_vp.get_texture())
	# Above the water composite, matching the volume mesh's own render priority.
	_volume_composite_mat.render_priority = 1
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = _volume_composite_mat
	_volume_composite = MeshInstance3D.new()
	_volume_composite.mesh = quad
	_volume_composite.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	_volume_composite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_volume_composite.visible = false
	add_child(_volume_composite)

	_scene_distance = FireSceneDistance.new()
	_scene_distance.enabled = false
	var compositor := Compositor.new()
	compositor.compositor_effects = [_scene_distance]
	camera.compositor = compositor
