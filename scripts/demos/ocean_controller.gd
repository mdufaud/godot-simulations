extends Node3D
## FFT ocean demo. OceanSolver keeps the whole Tessendorf pipeline on the GPU;
## this controller owns the clipmap mesh that follows the camera (snapped to
## the finest cell so the sampling lattice never swims), bridges the compute
## textures into the surface material and exposes the sea state through SimMenu.

const CELL0 := 0.5
const RING_LEVELS := 7
const SKIRT_RADIUS := 9000.0

## Sea-state params + mood (sky darkening / lightning) per preset.
const PRESETS := {
	"Calm": {
		wind_speed = 4.0, fetch_km = 40.0, swell = 0.35, spread = 0.35,
		choppiness = 0.95, whitecap = 0.68, foam_amount = 2.0,
		height_gain = 1.0, mood = 0.0,
	},
	"Breeze": {
		wind_speed = 11.0, fetch_km = 120.0, swell = 0.8, spread = 0.2,
		choppiness = 1.15, whitecap = 0.82, foam_amount = 3.5,
		height_gain = 1.0, mood = 0.15,
	},
	"Swell": {
		wind_speed = 16.0, fetch_km = 350.0, swell = 1.6, spread = 0.12,
		choppiness = 1.2, whitecap = 0.86, foam_amount = 4.0,
		height_gain = 1.25, mood = 0.5,
	},
	"Storm": {
		wind_speed = 33.0, fetch_km = 300.0, swell = 1.0, spread = 0.08,
		choppiness = 1.5, whitecap = 0.9, foam_amount = 6.0,
		height_gain = 1.7, mood = 1.0,
	},
}
const SPECTRUM_KEYS := [
	"wind_speed", "wind_direction", "fetch_km", "swell", "spread", "detail", "height_gain",
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var ocean_mesh: MeshInstance3D = $Ocean
@onready var underwater_tint: ColorRect = $UnderwaterLayer/Tint

var solver := OceanSolver.new()
var surface_mat: ShaderMaterial
var disp_texture: Texture2DArrayRD
var norm_texture: Texture2DArrayRD
var texture_bound := false
var time_scale := 1.0
var sun_elevation := 32.0
var sun_azimuth := 140.0

var profiler_label: Label
var _sim_time := 0.0
var _profile_accum := 0.0
var _param_sliders := {}
var _underwater := false
var _disp_readback := PackedByteArray()
var _readback_accum := 1e9
var _surface_fog_density := 0.0004
var _surface_fog_color := Color(0.62, 0.72, 0.78)

var _crates: Array[OceanBuoy] = []

var _mood := 0.0
var _mood_target := 0.15
var _cloud_mat: ShaderMaterial
var _lightning_light: OmniLight3D
var _flash_rect: ColorRect
var _bolt: MeshInstance3D
var _bolt_mesh: ImmediateMesh
var _lightning_timer := 4.0
var _flash_energy := 0.0
var _flash_pos := Vector3.ZERO
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	solver.map_size = GameManager.get_setting("ocean_map_size", 256)

	orbit_cam.target = Vector3(0, 2, 0)
	orbit_cam.distance = 45.0
	orbit_cam.pitch = -12.0
	orbit_cam.min_distance = 2.0
	orbit_cam.max_distance = 600.0
	orbit_cam.min_pitch = -80.0
	# Positive pitch swings the camera below the target: diving is allowed.
	orbit_cam.max_pitch = 75.0
	orbit_cam.move_speed = 30.0
	_surface_fog_density = world_env.environment.fog_density
	_surface_fog_color = world_env.environment.fog_light_color

	# TAA ghosts on per-pixel-moving displacement; MSAA doesn't.
	get_viewport().msaa_3d = Viewport.MSAA_2X
	get_viewport().use_taa = false

	_apply_sun()
	_setup_ocean_mesh()
	_setup_storm_sky()
	_setup_ui()
	_setup_profiler()
	RenderingServer.call_on_render_thread(solver.init_render)


func _setup_ocean_mesh() -> void:
	ocean_mesh.mesh = OceanClipmap.build(CELL0, RING_LEVELS, SKIRT_RADIUS)
	# GPU-displaced vertices invalidate the flat mesh AABB: cover the domain.
	ocean_mesh.custom_aabb = AABB(
		Vector3(-SKIRT_RADIUS, -60.0, -SKIRT_RADIUS),
		Vector3(SKIRT_RADIUS * 2.0, 120.0, SKIRT_RADIUS * 2.0)
	)
	surface_mat = ShaderMaterial.new()
	surface_mat.shader = load("res://shaders/ocean/ocean_surface.gdshader")
	var scales := PackedVector4Array()
	for i in solver.num_cascades():
		var inv := 1.0 / solver.tile_lengths[i]
		scales.append(Vector4(inv, inv, 1.0, 1.0))
	surface_mat.set_shader_parameter("map_scales", scales)
	surface_mat.set_shader_parameter("num_cascades", solver.num_cascades())
	ocean_mesh.material_override = surface_mat


func _setup_ui() -> void:
	menu.add_section("Sea state")
	menu.add_option_button("Preset", PRESETS.keys(), 1, _on_preset_selected)
	_add_solver_slider("Wind speed (m/s)", 0.5, 35.0, "wind_speed")
	_add_solver_slider("Wind direction", 0.0, TAU, "wind_direction")
	_add_solver_slider("Fetch (km)", 5.0, 1000.0, "fetch_km")
	_add_solver_slider("Swell", 0.0, 2.0, "swell")
	_add_solver_slider("Spread", 0.0, 1.0, "spread")
	_add_solver_slider("Detail", 0.5, 1.0, "detail")
	menu.add_separator()

	menu.add_section("Waves")
	_add_solver_slider("Choppiness", 0.0, 1.8, "choppiness")
	_add_solver_slider("Wave height", 0.0, 5.0, "height_gain")
	menu.add_slider("Time scale", 0.0, 2.0, time_scale, func(v): time_scale = v)
	menu.add_separator()

	menu.add_section("Objects")
	menu.add_button("Throw crate", _throw_crate)
	menu.add_separator()

	menu.add_section("Foam")
	_add_solver_slider("Whitecap", 0.0, 2.0, "whitecap")
	_add_solver_slider("Foam amount", 0.0, 10.0, "foam_amount")
	menu.add_slider("Foam strength", 0.0, 3.0, 1.0,
		func(v): surface_mat.set_shader_parameter("foam_strength", v))
	menu.add_separator()

	menu.add_section("Environment")
	_param_sliders["mood_slider"] = menu.add_slider(
		"Storm mood", 0.0, 1.0, _mood_target, func(v): _mood_target = v
	)
	menu.add_slider("Sun elevation", 2.0, 80.0, sun_elevation, _on_sun_elevation)
	menu.add_slider("Sun azimuth", 0.0, 360.0, sun_azimuth, _on_sun_azimuth)
	menu.add_toggle("SSR", false, func(on): world_env.environment.ssr_enabled = on)
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_toggle("Amortize cascades", false, func(on): solver.amortize = on)
	menu.add_toggle("Profiler overlay", false, _on_profiler_toggled)
	menu.add_label("FFT map size")
	menu.add_button("128", func(): _set_map_size(128))
	menu.add_button("256", func(): _set_map_size(256))
	menu.add_button("512", func(): _set_map_size(512))


## Spectrum-shaping sliders flip the dirty flag: regeneration is one cheap
## dispatch per cascade and the fixed seeds keep phases continuous.
func _add_solver_slider(label: String, lo: float, hi: float, key: String) -> void:
	var slider := menu.add_slider(label, lo, hi, solver.get(key), func(v: float):
		solver.set(key, v)
		if key in SPECTRUM_KEYS:
			solver.mark_spectrum_dirty()
	)
	_param_sliders[key] = slider


func _on_preset_selected(idx: int) -> void:
	var preset: Dictionary = PRESETS[PRESETS.keys()[idx]]
	for key in preset:
		if key == "mood":
			if _param_sliders.has("mood_slider"):
				_param_sliders["mood_slider"].value = preset[key]
			else:
				_mood_target = preset[key]
		elif _param_sliders.has(key):
			_param_sliders[key].value = preset[key]
		else:
			solver.set(key, preset[key])
	solver.mark_spectrum_dirty()


func _on_sun_elevation(v: float) -> void:
	sun_elevation = v
	_apply_sun()


func _on_sun_azimuth(v: float) -> void:
	sun_azimuth = v
	_apply_sun()


func _apply_sun() -> void:
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth, 0.0)


func _set_map_size(n: int) -> void:
	if n == solver.map_size:
		return
	_teardown_solver()
	solver.map_size = n
	GameManager.set_setting("ocean_map_size", n)
	RenderingServer.call_on_render_thread(solver.init_render)


func _teardown_solver() -> void:
	if disp_texture != null:
		disp_texture.texture_rd_rid = RID()
	if norm_texture != null:
		norm_texture.texture_rd_rid = RID()
	texture_bound = false
	RenderingServer.call_on_render_thread(solver.free_render)


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
	if t.has("spectrum"):
		lines.append("  spectrum %.2f | fft %.2f | assemble %.2f" % [
			t.get("spectrum", 0.0), t.get("fft", 0.0), t.get("assemble", 0.0),
		])
	lines.append("viewport GPU %.2f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
		get_viewport().get_viewport_rid()
	))
	profiler_label.text = "\n".join(lines)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		disp_texture = Texture2DArrayRD.new()
		disp_texture.texture_rd_rid = solver.get_displacement_tex_rid()
		norm_texture = Texture2DArrayRD.new()
		norm_texture.texture_rd_rid = solver.get_normal_tex_rid()
		surface_mat.set_shader_parameter("displacements", disp_texture)
		surface_mat.set_shader_parameter("normals", norm_texture)
		texture_bound = true
		return
	_sim_time += delta * time_scale
	solver.sim_time = _sim_time
	_update_storm(delta)

	# World-space UVs anchor the wave field to the world; snapping only keeps
	# the near-field sampling lattice aligned (no vertex swimming).
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var p := cam.global_position
		ocean_mesh.global_position = Vector3(
			snappedf(p.x, CELL0 * 2.0), 0.0, snappedf(p.z, CELL0 * 2.0)
		)
		_update_underwater(p, delta)

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta * time_scale))

	_profile_accum += delta
	if profiler_label.visible and _profile_accum >= 0.25:
		_profile_accum = 0.0
		_update_overlay()


## Storm dressing: FBM cloud deck dished to the horizon (shader derived from
## the tornado demo) + camera-facing lightning bolt, fullscreen flash and
## point light, all gated by the 0-1 mood that presets drive.
func _setup_storm_sky() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	var ntex := NoiseTexture3D.new()
	ntex.noise = noise
	ntex.width = 128
	ntex.height = 128
	ntex.depth = 32
	ntex.seamless = true

	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = load("res://shaders/ocean/ocean_clouds.gdshader")
	_cloud_mat.set_shader_parameter("noise_tex", ntex)
	_cloud_mat.set_shader_parameter("cover", 0.0)

	var plane := PlaneMesh.new()
	plane.size = Vector2(10000, 10000)
	plane.subdivide_width = 48
	plane.subdivide_depth = 48
	var deck := MeshInstance3D.new()
	deck.mesh = plane
	deck.material_override = _cloud_mat
	deck.position = Vector3(0, 420, 0)
	deck.extra_cull_margin = 2000.0
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(deck)

	_lightning_light = OmniLight3D.new()
	_lightning_light.light_energy = 0.0
	_lightning_light.omni_range = 500.0
	_lightning_light.omni_attenuation = 1.4
	_lightning_light.light_color = Color(0.82, 0.87, 1.0)
	_lightning_light.shadow_enabled = false
	add_child(_lightning_light)

	_flash_rect = ColorRect.new()
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(0.8, 0.85, 1.0, 0.0)
	$UnderwaterLayer.add_child(_flash_rect)

	_bolt_mesh = ImmediateMesh.new()
	_bolt = MeshInstance3D.new()
	_bolt.mesh = _bolt_mesh
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(0.85, 0.9, 1.0)
	mat.emission_energy_multiplier = 8.0
	_bolt.material_override = mat
	_bolt.visible = false
	add_child(_bolt)


func _update_storm(delta: float) -> void:
	_mood = move_toward(_mood, _mood_target, delta * 0.25)
	_cloud_mat.set_shader_parameter("cover", _mood)
	sun.light_energy = lerpf(1.6, 0.45, _mood)
	sun.light_color = Color(1, 0.98, 0.95).lerp(Color(0.72, 0.78, 0.9), _mood)
	# Darken the sky itself (it drives ambient + reflections): black-storm feel.
	var sky_mat: PhysicalSkyMaterial = world_env.environment.sky.sky_material
	sky_mat.energy_multiplier = lerpf(1.0, 0.35, _mood)
	# Storm light is an overcast dome, not a dimmed clear sky. Wave faces point
	# at the viewer (measured NdotV ~0.5), so they show albedo, not reflection:
	# with only the dimmed PhysicalSky left the sea goes black under a cloud
	# deck that never dims. Fading the sky ambient out for a flat storm grey
	# keeps it readable. sky_contribution 1.0 ignores ambient_light_color, so
	# this is a no-op at mood 0.
	world_env.environment.ambient_light_sky_contribution = lerpf(1.0, 0.2, _mood)
	world_env.environment.tonemap_exposure = lerpf(1.2, 1.05, _mood)
	_surface_fog_density = lerpf(0.0004, 0.0006, _mood)
	# Storm murk must approach the SEA tone (~0.06 lum), not a sky grey: fog on
	# the sea at 1-2 km blends 50%+, and anything brighter than the water reads
	# as a pale band floating over the waves ("horizon through the sea").
	# aerial_perspective pulls fog colour toward the sky, so it must drop too.
	_surface_fog_color = Color(0.62, 0.72, 0.78).lerp(Color(0.12, 0.14, 0.17), _mood)
	if not _underwater:
		world_env.environment.fog_density = _surface_fog_density
		world_env.environment.fog_light_color = _surface_fog_color
	world_env.environment.fog_aerial_perspective = lerpf(0.5, 0.1, _mood)

	# Lightning, tornado-demo style: random strikes, flickery decay.
	if _mood > 0.65:
		_lightning_timer -= delta
		if _lightning_timer <= 0.0:
			_trigger_lightning()
			_lightning_timer = _rng.randf_range(1.2, 5.0) / maxf(_mood, 0.1)
	_flash_energy = maxf(_flash_energy - delta * 6.0, 0.0)
	if _flash_energy > 0.0 and _rng.randf() < 0.2:
		_flash_energy = minf(_flash_energy + _rng.randf() * 0.4, 1.0)
	_lightning_light.light_energy = _flash_energy * 30.0
	_cloud_mat.set_shader_parameter("flash_intensity", _flash_energy * 5.0)
	_cloud_mat.set_shader_parameter("flash_pos", _flash_pos)
	_flash_rect.color.a = _flash_energy * _flash_energy * 0.3
	_bolt.visible = _flash_energy > 0.55


func _trigger_lightning() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var ang := _rng.randf_range(0.0, TAU)
	var rad := _rng.randf_range(120.0, 420.0)
	_flash_pos = cam.global_position + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	_flash_pos.y = _rng.randf_range(280.0, 380.0)
	_flash_energy = 1.0
	_lightning_light.global_position = Vector3(_flash_pos.x, 140.0, _flash_pos.z)
	_build_bolt_mesh(cam)


## Camera-facing jittered triangle strip from cloud base to the water.
func _build_bolt_mesh(cam: Camera3D) -> void:
	var bottom := Vector3(
		_flash_pos.x + _rng.randf_range(-25.0, 25.0), 0.0,
		_flash_pos.z + _rng.randf_range(-25.0, 25.0)
	)
	var view := (cam.global_position - _flash_pos).normalized()
	var axis := bottom - _flash_pos
	var side := axis.cross(view).normalized() * 2.5
	var segs := 11
	_bolt_mesh.clear_surfaces()
	_bolt_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in segs + 1:
		var t := float(i) / segs
		var p := _flash_pos + axis * t
		if i > 0 and i < segs:
			p += side.normalized() * _rng.randf_range(-14.0, 14.0)
			p += view.cross(side).normalized() * _rng.randf_range(-6.0, 6.0)
		var w := side * (1.0 - 0.5 * t)
		_bolt_mesh.surface_add_vertex(p - w)
		_bolt_mesh.surface_add_vertex(p + w)
	_bolt_mesh.surface_end()


## Tossed from the camera; buoyancy runs off the same height readback the
## underwater toggle uses, so crates ride the rendered swell.
func _throw_crate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var crate := OceanBuoy.new()
	crate.height_sampler = _sample_ocean_height
	add_child(crate)
	var fwd := -cam.global_transform.basis.z
	crate.global_position = cam.global_position + fwd * 4.0 + Vector3.UP
	crate.linear_velocity = fwd * 14.0 + Vector3.UP * 4.0
	crate.angular_velocity = Vector3(
		_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0)
	)
	_crates.append(crate)
	if _crates.size() > 8:
		_crates.pop_front().queue_free()


## Camera vs water surface. The FFT height lives on the GPU, so cascade 0's
## displacement map is read back asynchronously (~7 Hz, no stall) and sampled
## on the CPU. Choppy xz offset is ignored: metre-level error, fine for a
## fullscreen toggle.
func _update_underwater(cam_pos: Vector3, delta: float) -> void:
	_readback_accum += delta
	if _readback_accum >= 0.15:
		_readback_accum = 0.0
		RenderingServer.call_on_render_thread(func():
			var rd := RenderingServer.get_rendering_device()
			rd.texture_get_data_async(solver.get_displacement_tex_rid(), 0, _store_readback)
		)
	var below := cam_pos.y < _sample_ocean_height(Vector2(cam_pos.x, cam_pos.z))
	if below == _underwater:
		return
	_underwater = below
	underwater_tint.visible = below
	# Single source of truth: the surface shader picks its interface side from
	# this, so the overlay and the water shading can never disagree.
	surface_mat.set_shader_parameter("camera_underwater", below)
	world_env.environment.fog_density = 0.03 if below else _surface_fog_density
	world_env.environment.fog_light_color = \
		Color(0.05, 0.19, 0.24) if below else _surface_fog_color


# Render thread (async readback callback): hop back to the main thread.
func _store_readback(data: PackedByteArray) -> void:
	call_deferred("_set_readback", data)


func _set_readback(data: PackedByteArray) -> void:
	_disp_readback = data


func _sample_ocean_height(world_xz: Vector2) -> float:
	var n := solver.map_size
	if _disp_readback.size() < n * n * 8:
		return 0.0
	var tile: float = solver.tile_lengths[0]
	var xi := int(fposmod(world_xz.x / tile, 1.0) * n) % n
	var yi := int(fposmod(world_xz.y / tile, 1.0) * n) % n
	# rgba16f texel = 8 bytes; height is the g channel.
	return _half_to_float(_disp_readback.decode_u16((yi * n + xi) * 8 + 2))


func _half_to_float(h: int) -> float:
	var sign := -1.0 if h & 0x8000 else 1.0
	var expo := (h >> 10) & 0x1F
	var mant := h & 0x3FF
	if expo == 0:
		return sign * mant * pow(2.0, -24)
	if expo == 31:
		return sign * 65504.0
	return sign * (1.0 + mant / 1024.0) * pow(2.0, expo - 15)


func _exit_tree() -> void:
	if disp_texture != null:
		disp_texture.texture_rd_rid = RID()
	if norm_texture != null:
		norm_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(solver.free_render)
