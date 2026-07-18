extends Node3D
## Procedural planet demo, ported from SebLague/Fluid-Planet ("Terra").
## A density field is marched into a mesh on the GPU, shaded by quantised height
## bands, and wrapped in a raymarched Rayleigh atmosphere.
##
## Generation is a GPU readback, so shape sliders debounce into one rebuild rather
## than rebuilding per tick.

const REGEN_DEBOUNCE := 0.25
const RESOLUTIONS: Array[int] = [64, 96, 128, 160]

## Shape plus palette per preset. Terra is Lague's tuned original.
const PRESETS: Array[Dictionary] = [
	{
		name = "Terra",
		radius = 23.0, num_layers = 8, lacunarity = 1.48, persistence = 0.68,
		noise_scale = 2.86, noise_strength = 2.41, noise_offset = -0.28,
		col_flat = Color(0.670, 0.465, 0.281), col_flat_deep = Color(0.434, 0.180, 0.166),
		col_steep = Color(0.368, 0.270, 0.227), col_steep_deep = Color(0.208, 0.153, 0.179),
		col_ambient = Color(0.500, 0.390, 0.389),
		height_min = 16.2, height_max = 28.3, height_bands = 5.2,
		wavelengths = Vector3(700.0, 530.0, 460.0), scattering_strength = 20.3,
	},
	{
		name = "Verdant",
		radius = 23.0, num_layers = 7, lacunarity = 1.9, persistence = 0.5,
		noise_scale = 2.2, noise_strength = 1.6, noise_offset = 0.1,
		col_flat = Color(0.32, 0.52, 0.24), col_flat_deep = Color(0.16, 0.30, 0.18),
		col_steep = Color(0.40, 0.36, 0.30), col_steep_deep = Color(0.20, 0.19, 0.18),
		col_ambient = Color(0.30, 0.36, 0.40),
		height_min = 20.0, height_max = 27.0, height_bands = 7.0,
		wavelengths = Vector3(700.0, 530.0, 440.0), scattering_strength = 22.0,
	},
	{
		name = "Glacier",
		radius = 24.0, num_layers = 8, lacunarity = 2.1, persistence = 0.55,
		noise_scale = 3.6, noise_strength = 1.8, noise_offset = 0.0,
		col_flat = Color(0.86, 0.92, 0.97), col_flat_deep = Color(0.42, 0.58, 0.72),
		col_steep = Color(0.55, 0.62, 0.70), col_steep_deep = Color(0.22, 0.30, 0.42),
		col_ambient = Color(0.42, 0.50, 0.60),
		height_min = 20.0, height_max = 29.0, height_bands = 9.0,
		wavelengths = Vector3(640.0, 540.0, 470.0), scattering_strength = 26.0,
	},
	{
		name = "Asteroid",
		radius = 18.0, num_layers = 8, lacunarity = 1.35, persistence = 0.78,
		noise_scale = 4.5, noise_strength = 3.4, noise_offset = -0.35,
		col_flat = Color(0.38, 0.35, 0.32), col_flat_deep = Color(0.19, 0.17, 0.16),
		col_steep = Color(0.28, 0.26, 0.25), col_steep_deep = Color(0.12, 0.11, 0.11),
		col_ambient = Color(0.30, 0.29, 0.30),
		height_min = 12.0, height_max = 24.0, height_bands = 4.0,
		wavelengths = Vector3(700.0, 560.0, 500.0), scattering_strength = 6.0,
	},
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var planet_mesh: MeshInstance3D = $Planet
@onready var atmosphere_quad: MeshInstance3D = $Atmosphere
@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_env: WorldEnvironment = $WorldEnvironment

var generator := PlanetGenerator.new()
var lut := AtmosphereLut.new()

var surface_mat: ShaderMaterial
var atmosphere_mat: ShaderMaterial
var sky_mat: ShaderMaterial

var atmosphere_scale := 0.405
var density_falloff := 4.6
var scattering_strength := 20.3
## The original writes straight to an LDR target; Godot tonemaps, so the same
## radiance reads as a milky ball. A quarter of it restores the thin blue limb.
var atmosphere_intensity := 0.25
var wavelengths := Vector3(700.0, 530.0, 460.0)
var sun_yaw := 30.0
var sun_auto_rotate := false
var sun_rotate_speed := 6.0

var _mobile := false
var _regen_timer: Timer
var _regen_pending := false
var _status_label: Label
## Height range of the active preset, kept so the colour bands can be rescaled when
## the radius slider moves; otherwise a small planet falls entirely below the
## gradient and renders in a single flat colour.
var _preset_radius := 23.0
var _preset_height_min := 16.2
var _preset_height_max := 28.3

var fluid: FluidSystem
var fluid_enabled := true
## Surface gravity. SebLague's planet works out to ~2.6 at this scale; the terrain
## is what fluid has to negotiate, so weak gravity keeps streams readable.
var fluid_gravity := 2.6
var _crosshair: Control
## True once the fluid has been built against a generated density field. Any change
## that resizes the volume has to tear it down and rebuild.
var _fluid_started := false
## Mirrored onto the fluid composite; see _apply_atmosphere_params().
var _atmosphere_params := {}

var _render_scale := 0.75
var _shape_sliders := {}
var _palette_pickers := {}
## Set while a preset pushes its values into the widgets, so their callbacks do not
## write the quantised slider value back over the preset.
var _updating_ui := false


func _ready() -> void:
	_mobile = VirtualJoystick.is_touch_ui()

	var stored_resolution: int = GameManager.get_setting("planet_resolution", 0)
	generator.resolution = stored_resolution if stored_resolution > 0 else (64 if _mobile else 128)

	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 95.0
	orbit_cam.pitch = -20.0
	orbit_cam.min_distance = 26.0
	orbit_cam.max_distance = 400.0
	# The default upper bound forbids looking up, which is wrong for an orbit.
	orbit_cam.min_pitch = -89.0
	orbit_cam.max_pitch = 89.0
	orbit_cam.move_speed = 30.0

	_set_render_scale(_render_scale)

	_setup_materials()
	_setup_environment()
	_setup_crosshair()
	_setup_ui()

	_regen_timer = Timer.new()
	_regen_timer.one_shot = true
	_regen_timer.wait_time = REGEN_DEBOUNCE
	_regen_timer.timeout.connect(_start_generation)
	add_child(_regen_timer)

	_apply_preset(0)
	RenderingServer.call_on_render_thread(generator.init_render)
	RenderingServer.call_on_render_thread(lut.init_render)
	RenderingServer.call_on_render_thread(_bake_lut)
	_start_generation()


func _set_render_scale(v: float) -> void:
	_render_scale = v
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = v


func _exit_tree() -> void:
	# The root viewport outlives the scene, so hand it back at full resolution.
	var vp := get_viewport()
	if vp:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 1.0
	RenderingServer.call_on_render_thread(generator.free_render)
	RenderingServer.call_on_render_thread(lut.free_render)


func _setup_materials() -> void:
	surface_mat = ShaderMaterial.new()
	surface_mat.shader = load("res://shaders/planet/planet_surface.gdshader")
	surface_mat.set_shader_parameter("detail_octaves", 3 if _mobile else 8)
	planet_mesh.material_override = surface_mat

	atmosphere_mat = ShaderMaterial.new()
	atmosphere_mat.shader = load("res://shaders/planet/planet_atmosphere.gdshader")
	_atmosphere_params["num_in_scattering_points"] = 6 if _mobile else 10
	_atmosphere_params["dither_tex"] = _make_dither_texture()
	_apply_atmosphere_params()

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = atmosphere_mat
	atmosphere_quad.mesh = quad
	# The quad is pinned to the near plane in the shader, so its real bounds are
	# meaningless: make them big enough never to be culled.
	atmosphere_quad.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))


func _setup_environment() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/planet/planet_sky.gdshader")

	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = false
	world_env.environment = env


## White-noise dither. The original ships a blue-noise PNG; at this amplitude the
## difference is not visible and this costs no asset.
func _setup_crosshair() -> void:
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 28)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.visible = false
	$UI.add_child(_crosshair)


func _make_dither_texture() -> ImageTexture:
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_R8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for y in size:
		for x in size:
			image.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return ImageTexture.create_from_image(image)


func _process(delta: float) -> void:
	if sun_auto_rotate:
		sun_yaw = fmod(sun_yaw + sun_rotate_speed * delta, 360.0)
	_update_sun()

	if generator.poll():
		var mesh := generator.take_mesh()
		if mesh != null:
			planet_mesh.mesh = mesh
		_update_status()
		if _regen_pending:
			_regen_pending = false
			_start_generation()
		else:
			# Only once the field has settled: the volume size, hence the whole fluid
			# grid, is derived from the shape parameters.
			_rebuild_fluid()

	if _fluid_started:
		fluid.set_sky_up_axis((camera.global_position - Vector3.ZERO).normalized())


## Where the camera is looking, on a sphere enclosing the tallest peak. Always
## outside the terrain, so poured fluid starts in the air and falls -- which means
## no mesh raycast, no collision body, and identical behaviour on touch.
func aim_point() -> Vector3:
	var origin := camera.global_position
	var dir := -camera.global_transform.basis.z
	var r := generator.max_surface_radius()
	var b := origin.dot(dir)
	var c := origin.length_squared() - r * r
	var disc := b * b - c
	if disc <= 0.0:
		# Looking past the planet: fall back to the closest approach.
		return (origin - dir * b).normalized() * r
	return origin + dir * (-b - sqrt(disc))


func _rebuild_fluid() -> void:
	_teardown_fluid()
	if not fluid_enabled or not generator.density_texture().is_valid():
		return
	fluid = FluidSystem.new()
	fluid.camera = camera
	fluid.method = FluidSystem.Method.SPH
	fluid.particle_count = 16384 if _mobile else 65536
	fluid.foam_enabled = not _mobile
	fluid.planet_field = generator.density_texture()
	fluid.planet_field_world_size = generator.world_size()
	fluid.planet_radius = generator.radius
	fluid.planet_gravity = fluid_gravity
	fluid.planet_grid_dim = 96 if _mobile else 144
	add_child(fluid)
	fluid.start()
	# Both the atmosphere and the fluid composite are full-screen quads reading
	# SCREEN_TEXTURE, and they share one pre-transparent copy of it -- so whichever
	# draws last paints over the other entirely. The fluid has to be last or it is
	# invisible. The cost is that the atmosphere is not applied over water, which
	# barely shows: the water sits on the surface, under the whole air column.
	fluid.set_composite_priority(1)
	_fluid_started = true
	_apply_atmosphere_params()


## Freed immediately rather than queued: a resolution change reallocates the density
## texture on the render thread, and freeing a texture invalidates every uniform set
## that references it. queue_free() defers past that point, so the solver would keep
## dispatching against dead sets. Freeing now keeps the render-thread order
## free_render -> reallocate.
func _teardown_fluid() -> void:
	if fluid == null:
		return
	remove_child(fluid)
	fluid.free()
	fluid = null
	_fluid_started = false


func _update_sun() -> void:
	sun_light.rotation_degrees = Vector3(-35.0, sun_yaw, 0.0)
	# A DirectionalLight3D emits along its local -Z, so +Z points back at the sun.
	var dir_to_sun := sun_light.global_transform.basis.z.normalized()
	surface_mat.set_shader_parameter("sun_direction", dir_to_sun)
	_atmosphere_params["dir_to_sun"] = dir_to_sun
	_apply_atmosphere_params()
	sky_mat.set_shader_parameter("sun_direction", dir_to_sun)


func _start_generation() -> void:
	# The fluid is bound to the field being replaced, and a resolution change frees
	# the texture its uniform sets point at. Drop it now; poll() rebuilds it once the
	# new field exists.
	_teardown_fluid()
	if not generator.request_generate():
		_regen_pending = true
		return
	if _status_label != null:
		_status_label.text = "Generating…"


func _queue_regen() -> void:
	_regen_timer.start()


func _bake_lut() -> void:
	lut.bake(1.0 + atmosphere_scale, density_falloff, 100)
	_atmosphere_params["baked_optical_depth"] = lut.texture
	_apply_atmosphere_params()


func _update_atmosphere_params() -> void:
	var planet_radius := generator.radius
	_atmosphere_params["planet_radius"] = planet_radius
	_atmosphere_params["atmosphere_radius"] = planet_radius * (1.0 + atmosphere_scale)
	_atmosphere_params["density_falloff"] = density_falloff
	_atmosphere_params["intensity"] = atmosphere_intensity
	# Rayleigh scattering goes as 1/wavelength^4, normalised at 400 nm.
	var coefficients := Vector3(
		pow(400.0 / wavelengths.x, 4.0),
		pow(400.0 / wavelengths.y, 4.0),
		pow(400.0 / wavelengths.z, 4.0),
	) * scattering_strength
	_atmosphere_params["scattering_coefficients"] = coefficients
	_apply_atmosphere_params()


## The atmosphere quad and the fluid composite are both full-screen transparent
## quads sharing one pre-transparent screen copy, so the later one overwrites the
## earlier rather than blending. The fluid draws last and scatters its own output,
## which means it needs the same parameters the atmosphere quad has.
func _apply_atmosphere_params() -> void:
	for key in _atmosphere_params:
		atmosphere_mat.set_shader_parameter(key, _atmosphere_params[key])
	if _fluid_started:
		fluid.set_atmosphere(_atmosphere_params)


func _update_status() -> void:
	if _status_label == null:
		return
	_status_label.text = "%s triangles · %.0f ms" % [
		String.num_uint64(generator.triangle_count), generator.last_generate_ms,
	]


func _apply_preset(index: int) -> void:
	var p: Dictionary = PRESETS[index]

	generator.radius = p.radius
	generator.num_layers = p.num_layers
	generator.lacunarity = p.lacunarity
	generator.persistence = p.persistence
	generator.noise_scale = p.noise_scale
	generator.noise_strength = p.noise_strength
	generator.noise_offset = p.noise_offset

	surface_mat.set_shader_parameter("col_flat", p.col_flat)
	surface_mat.set_shader_parameter("col_flat_deep", p.col_flat_deep)
	surface_mat.set_shader_parameter("col_steep", p.col_steep)
	surface_mat.set_shader_parameter("col_steep_deep", p.col_steep_deep)
	surface_mat.set_shader_parameter("col_ambient", p.col_ambient)
	surface_mat.set_shader_parameter("height_bands", p.height_bands)

	_preset_radius = p.radius
	_preset_height_min = p.height_min
	_preset_height_max = p.height_max
	_update_height_range()

	wavelengths = p.wavelengths
	scattering_strength = p.scattering_strength
	_update_atmosphere_params()
	_sync_widgets_to_preset(p)


func _update_height_range() -> void:
	var scale := generator.radius / _preset_radius
	surface_mat.set_shader_parameter("height_min", _preset_height_min * scale)
	surface_mat.set_shader_parameter("height_max", _preset_height_max * scale)


func _sync_widgets_to_preset(p: Dictionary) -> void:
	_updating_ui = true
	for key in _shape_sliders:
		_shape_sliders[key].value = float(p[key])
	for key in _palette_pickers:
		_palette_pickers[key].color = p[key]
	_updating_ui = false


func _setup_ui() -> void:
	menu.add_section("Shape")
	menu.add_option_button(
		"Preset",
		PRESETS.map(func(p: Dictionary) -> String: return p.name),
		0,
		func(index: int) -> void:
			_apply_preset(index)
			_queue_regen()
	)

	_shape_sliders["radius"] = menu.add_slider("Radius", 8.0, 30.0, generator.radius,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.radius = v
			_update_height_range()
			_update_atmosphere_params()
			orbit_cam.min_distance = generator.max_surface_radius() * 1.15
			_queue_regen()
	)
	_shape_sliders["num_layers"] = menu.add_slider("Layers", 1.0, 8.0, float(generator.num_layers),
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.num_layers = int(v)
			_queue_regen()
	)
	_shape_sliders["lacunarity"] = menu.add_slider("Lacunarity", 1.0, 3.0, generator.lacunarity,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.lacunarity = v
			_queue_regen()
	)
	_shape_sliders["persistence"] = menu.add_slider("Persistence", 0.1, 0.9, generator.persistence,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.persistence = v
			_queue_regen()
	)
	_shape_sliders["noise_scale"] = menu.add_slider("Noise scale", 0.5, 8.0, generator.noise_scale,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.noise_scale = v
			_queue_regen()
	)
	_shape_sliders["noise_strength"] = menu.add_slider("Strength", 0.0, 6.0, generator.noise_strength,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.noise_strength = v
			_queue_regen()
	)
	_shape_sliders["noise_offset"] = menu.add_slider("Offset", -1.5, 1.5, generator.noise_offset,
		func(v: float) -> void:
			if _updating_ui:
				return
			generator.noise_offset = v
			_queue_regen()
	)

	menu.add_button("Randomize seed", func() -> void:
		generator.noise_position_offset = Vector3(
			randf_range(-500.0, 500.0), randf_range(-500.0, 500.0), randf_range(-500.0, 500.0)
		)
		_queue_regen()
	)

	menu.add_section("Surface")
	for entry in [
		["Flat high", "col_flat"], ["Flat low", "col_flat_deep"],
		["Steep high", "col_steep"], ["Steep low", "col_steep_deep"],
	]:
		var param: String = entry[1]
		_palette_pickers[param] = menu.add_color_picker(entry[0], PRESETS[0][param],
			func(color: Color) -> void:
				surface_mat.set_shader_parameter(param, color)
		)
	_shape_sliders["height_bands"] = menu.add_slider("Height bands", 1.0, 24.0, 5.2, func(v: float) -> void:
		surface_mat.set_shader_parameter("height_bands", v)
	)
	menu.add_slider("Steepness", 0.0, 1.0, 0.76, func(v: float) -> void:
		surface_mat.set_shader_parameter("flat_threshold", v)
	)
	menu.add_slider("Steep blend", 0.0, 0.4, 0.01, func(v: float) -> void:
		surface_mat.set_shader_parameter("flat_blend", v)
	)
	menu.add_slider("Shade power", 0.5, 4.0, 1.5, func(v: float) -> void:
		surface_mat.set_shader_parameter("shade_pow", v)
	)

	menu.add_section("Atmosphere")
	menu.add_toggle("Enabled", true, func(on: bool) -> void:
		atmosphere_quad.visible = on
	)
	menu.add_slider("Intensity", 0.0, 2.0, atmosphere_intensity, func(v: float) -> void:
		atmosphere_intensity = v
		_update_atmosphere_params()
	)
	menu.add_slider("Scattering", 0.0, 60.0, scattering_strength, func(v: float) -> void:
		scattering_strength = v
		_update_atmosphere_params()
	)
	menu.add_slider("Falloff", 0.5, 12.0, density_falloff, func(v: float) -> void:
		density_falloff = v
		_update_atmosphere_params()
		RenderingServer.call_on_render_thread(_bake_lut)
	)
	menu.add_slider("Thickness", 0.05, 1.0, atmosphere_scale, func(v: float) -> void:
		atmosphere_scale = v
		_update_atmosphere_params()
		RenderingServer.call_on_render_thread(_bake_lut)
	)
	menu.add_slider("Red nm", 500.0, 780.0, wavelengths.x, func(v: float) -> void:
		wavelengths.x = v
		_update_atmosphere_params()
	)
	menu.add_slider("Green nm", 450.0, 650.0, wavelengths.y, func(v: float) -> void:
		wavelengths.y = v
		_update_atmosphere_params()
	)
	menu.add_slider("Blue nm", 380.0, 560.0, wavelengths.z, func(v: float) -> void:
		wavelengths.z = v
		_update_atmosphere_params()
	)

	menu.add_section("Sun")
	menu.add_slider("Yaw", 0.0, 360.0, sun_yaw, func(v: float) -> void:
		sun_yaw = v
	)
	menu.add_toggle("Auto rotate", false, func(on: bool) -> void:
		sun_auto_rotate = on
	)

	menu.add_section("Fluid")
	menu.add_toggle("Enabled", false, func(on: bool) -> void:
		fluid_enabled = on
		_crosshair.visible = on
		_rebuild_fluid()
	)
	menu.add_button("Pour here", func() -> void:
		if _fluid_started:
			fluid.pour_at(aim_point())
	)
	menu.add_button("Reset fluid", _rebuild_fluid)
	menu.add_slider("Pour amount", 0.02, 0.5, 0.15, func(v: float) -> void:
		if _fluid_started:
			fluid.pour_fraction = v
	)
	menu.add_slider("Gravity", 0.5, 8.0, fluid_gravity, func(v: float) -> void:
		fluid_gravity = v
		if _fluid_started:
			fluid.sph_solver.planet_gravity = v
	)
	menu.add_slider("Viscosity", 0.0, 1.0, 0.14, func(v: float) -> void:
		if _fluid_started:
			fluid.sph_solver.viscosity_strength = v
	)
	# The normal component of velocity is removed outright, so this is how much
	# tangential speed survives a hit: near 1 sheets across rock, low values stick.
	menu.add_slider("Slip", 0.5, 1.0, 0.999, func(v: float) -> void:
		if _fluid_started:
			fluid.sph_solver.collision_damping = v
	)

	menu.add_section("Performance")
	menu.add_option_button(
		"Resolution",
		RESOLUTIONS.map(func(r: int) -> String: return "%d³" % r),
		RESOLUTIONS.find(generator.resolution),
		func(index: int) -> void:
			generator.resolution = RESOLUTIONS[index]
			GameManager.set_setting("planet_resolution", generator.resolution)
			_start_generation()
	)
	menu.add_slider("Render scale", 0.4, 1.0, _render_scale, _set_render_scale)
	menu.add_slider("Surface detail", 0.0, 8.0, float(3 if _mobile else 8), func(v: float) -> void:
		surface_mat.set_shader_parameter("detail_octaves", int(v))
	)
	_status_label = menu.add_label("Generating…")

