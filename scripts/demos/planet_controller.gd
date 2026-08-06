extends Node3D
## Procedural planet demo, ported from SebLague/Fluid-Planet ("Terra").
## A density field is marched into a mesh on the GPU, shaded by quantised height
## bands, and wrapped in a raymarched Rayleigh atmosphere.
##
## Generation is a GPU readback, so shape sliders debounce into one rebuild rather
## than rebuilding per tick.

const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")

const REGEN_DEBOUNCE := 0.25
const PRESETS := [
	preload("res://resources/planet/presets/terra.tres"),
	preload("res://resources/planet/presets/verdant.tres"),
	preload("res://resources/planet/presets/glacier.tres"),
	preload("res://resources/planet/presets/asteroid.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var planet_mesh: MeshInstance3D = $Planet
@onready var atmosphere_quad: MeshInstance3D = $Atmosphere
@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var _viewport := ViewportGuard.attach(self)

var generator := PlanetGenerator.new()

var sun_yaw := 30.0
var sun_auto_rotate := false
var sun_rotate_speed := 6.0
var render_scale := 0.75

var view := PlanetPresentation.new()

var _atmosphere := PlanetAtmosphere.new()
var _fluid := PlanetFluid.new()
var _menu_builder := PlanetMenu.new()

var _mobile := false
var _regen_timer: Timer
var _regen_pending := false
## The preset the height gradient is quoted against, so the radius slider can
## rescale it without losing the preset's tuning.
var _preset: PlanetPreset = PRESETS[0]


func _ready() -> void:
	_mobile = VirtualJoystickScript.is_touch_ui()

	var stored_resolution: int = GameManager.get_setting("planet_resolution", 0)
	generator.resolution = stored_resolution if stored_resolution > 0 else (64 if _mobile else 128)
	generator.density_texture_changed.connect(_on_density_texture_changed)

	orbit_cam.target = Vector3.ZERO
	orbit_cam.distance = 95.0
	orbit_cam.pitch = -20.0
	orbit_cam.min_distance = 26.0
	orbit_cam.max_distance = 400.0
	# The default upper bound forbids looking up, which is wrong for an orbit.
	orbit_cam.min_pitch = -89.0
	orbit_cam.max_pitch = 89.0
	orbit_cam.move_speed = 30.0

	set_render_scale(render_scale)
	view.build(planet_mesh, atmosphere_quad, world_env, $UI, _mobile)

	_atmosphere.mobile = _mobile
	_atmosphere.changed.connect(_on_atmosphere_changed)
	_atmosphere.start()

	_fluid.host = self
	_fluid.camera = camera
	_fluid.generator = generator
	_fluid.mobile = _mobile
	# Live from the first generation, while the 🌊 toggle starts unpressed: the toggle
	# gates the crosshair and the pour/reset actions, not the solver's first build.
	_fluid.enabled = true

	_setup_ui()

	_regen_timer = Timer.new()
	_regen_timer.one_shot = true
	_regen_timer.wait_time = REGEN_DEBOUNCE
	_regen_timer.timeout.connect(start_generation)
	add_child(_regen_timer)

	apply_preset(0)
	RenderingServer.call_on_render_thread(generator.init_render)
	RenderingServer.call_on_render_thread(_atmosphere.init_render)
	RenderingServer.call_on_render_thread(_atmosphere.bake_render)
	start_generation()


func _exit_tree() -> void:
	# The root viewport outlives the scene; ViewportGuard hands it back as it was.
	RenderingServer.call_on_render_thread(generator.free_render)
	RenderingServer.call_on_render_thread(_atmosphere.free_render)


func _process(delta: float) -> void:
	if sun_auto_rotate:
		sun_yaw = fmod(sun_yaw + sun_rotate_speed * delta, 360.0)
	_update_sun()

	if generator.poll():
		var mesh := generator.take_mesh()
		if mesh != null:
			planet_mesh.mesh = mesh
		_menu_builder.set_status("%s triangles · %.0f ms" % [
			String.num_uint64(generator.triangle_count), generator.last_generate_ms,
		])
		if _regen_pending:
			_regen_pending = false
			start_generation()

	_fluid.track_sky(camera.global_position)


func set_render_scale(value: float) -> void:
	render_scale = value
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func apply_preset(index: int) -> void:
	var preset: PlanetPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Planet preset '%s': %s" % [preset.display_name, error])
		return

	_preset = preset
	preset.apply_shape_to(generator)
	preset.apply_palette_to(view.surface)
	update_height_range()

	_atmosphere.wavelengths_nm = preset.wavelengths_nm
	_atmosphere.scattering_strength = preset.scattering_strength
	_atmosphere.planet_radius_m = generator.radius
	_atmosphere.refresh()
	_menu_builder.sync_to_preset(preset)


func update_height_range() -> void:
	view.set_height_range(_preset, generator.radius)


func start_generation() -> void:
	# The fluid is bound to the field being replaced, and a resolution change frees
	# the texture its uniform sets point at. Drop it now; density_texture_changed
	# rebuilds it once the new field exists.
	_fluid.teardown()
	if not generator.request_generate():
		_regen_pending = true
		return
	_menu_builder.set_status("Generating…")


func queue_regen() -> void:
	_regen_timer.start()


func rebuild_fluid() -> void:
	_fluid.rebuild(_atmosphere.params())


func set_fluid_enabled(on: bool) -> void:
	_fluid.enabled = on
	view.crosshair.visible = on
	rebuild_fluid()


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


func _on_density_texture_changed() -> void:
	# A regeneration queued while this one ran replaces the field immediately, so
	# building now would bind uniform sets to a texture about to be freed.
	if _regen_pending:
		return
	rebuild_fluid()


## The atmosphere quad and the fluid composite are both full-screen transparent
## quads sharing one pre-transparent screen copy, so the later one overwrites the
## earlier rather than blending. The fluid draws last and scatters its own output,
## which means it needs the same parameters the atmosphere quad has.
func _on_atmosphere_changed(params: Dictionary) -> void:
	view.set_atmosphere_params(params)
	_fluid.apply_atmosphere(params)


func _setup_ui() -> void:
	_menu_builder.generator = generator
	_menu_builder.surface = view.surface
	_menu_builder.atmosphere = _atmosphere
	_menu_builder.fluid = _fluid
	_menu_builder.orbit_cam = orbit_cam
	_menu_builder.atmosphere_quad = atmosphere_quad
	_menu_builder.host = self
	_menu_builder.build(menu, PRESETS)


func _update_sun() -> void:
	sun_light.rotation_degrees = Vector3(-35.0, sun_yaw, 0.0)
	# A DirectionalLight3D emits along its local -Z, so +Z points back at the sun.
	var dir_to_sun := sun_light.global_transform.basis.z.normalized()
	view.set_sun_direction(dir_to_sun)
	_atmosphere.sun_direction = dir_to_sun
	_atmosphere.refresh()
