extends Node3D
## FFT ocean demo. OceanSolver keeps the whole Tessendorf pipeline on the GPU;
## this controller owns the clipmap mesh that follows the camera (snapped to
## the finest cell so the sampling lattice never swims), bridges the compute
## textures into the surface material and wires the rest together.

const CELL0 := 0.5
const RING_LEVELS := 7
const SKIRT_RADIUS := 9000.0
const MAX_CRATES := 8

const PRESETS := [
	preload("res://resources/ocean/presets/calm.tres"),
	preload("res://resources/ocean/presets/breeze.tres"),
	preload("res://resources/ocean/presets/swell.tres"),
	preload("res://resources/ocean/presets/storm.tres"),
]

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var ocean_mesh: MeshInstance3D = $Ocean
@onready var underwater_layer: CanvasLayer = $UnderwaterLayer
@onready var underwater_tint: ColorRect = $UnderwaterLayer/Tint
@onready var _viewport := ViewportGuard.attach(self)

var solver := OceanSolver.new()
var config: OceanConfig = OceanConfig.new()
var surface_mat: ShaderMaterial
var disp_texture: Texture2DArrayRD
var norm_texture: Texture2DArrayRD
var texture_bound := false
var time_scale := 1.0
var sun_elevation := 32.0
var sun_azimuth := 140.0

var waves := OceanHeightSampler.new()
var storm := OceanStorm.new()
var profiler := SimProfiler.new()

var _menu_builder := OceanMenu.new()
var _sim_time := 0.0
var _frozen := false
var _underwater := false
var _crates: Array[OceanBuoy] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	solver.config = config
	solver.map_size = GameManager.get_setting("ocean_map_size", 256)
	waves.solver = solver

	orbit_cam.target = Vector3(0, 2, 0)
	orbit_cam.distance = 45.0
	orbit_cam.pitch = -12.0
	orbit_cam.min_distance = 2.0
	orbit_cam.max_distance = 600.0
	orbit_cam.min_pitch = -80.0
	# Positive pitch swings the camera below the target: diving is allowed.
	orbit_cam.max_pitch = 75.0
	orbit_cam.move_speed = 30.0

	# TAA ghosts on per-pixel-moving displacement; MSAA doesn't. The guard hands both
	# back to the root viewport when the demo exits.
	_viewport.set_msaa(Viewport.MSAA_2X)
	_viewport.set_taa(false)

	_apply_sun()
	_setup_ocean_mesh()

	storm.sun = sun
	storm.world_env = world_env
	storm.overlay_layer = underwater_layer
	storm.build(self)

	profiler.lines_provider = _profiler_lines
	profiler.enabled_changed.connect(func(on: bool): solver.profiling = on)
	profiler.build(menu.get_parent(), get_viewport().get_viewport_rid())

	_setup_ui()
	RenderingServer.call_on_render_thread(solver.init_render)


func _exit_tree() -> void:
	_release_textures()
	RenderingServer.call_on_render_thread(solver.free_render)


func _process(delta: float) -> void:
	if not solver.initialized:
		return
	if not texture_bound:
		_bind_textures()
		return
	var step_scale := 0.0 if _frozen else time_scale
	_sim_time += delta * step_scale
	solver.sim_time = _sim_time

	var cam := get_viewport().get_camera_3d()
	storm.update(delta, cam)

	# World-space UVs anchor the wave field to the world; snapping only keeps
	# the near-field sampling lattice aligned (no vertex swimming).
	if cam != null:
		var p := cam.global_position
		ocean_mesh.global_position = Vector3(
			snappedf(p.x, CELL0 * 2.0), 0.0, snappedf(p.z, CELL0 * 2.0)
		)
		waves.poll(delta)
		_update_underwater(p)

	RenderingServer.call_on_render_thread(solver.step_render.bind(delta * step_scale))
	profiler.poll(delta)


func apply_preset(index: int) -> void:
	var preset: OceanPreset = PRESETS[index]
	var error := preset.validate()
	if error != "":
		push_error("Ocean preset '%s': %s" % [preset.display_name, error])
		return
	# Sliders first, preset second: the panel shows the preset, the solver gets
	# the unquantised values rather than whatever the sliders snapped to.
	_menu_builder.sync_to_preset(preset)
	preset.apply_to(solver)
	solver.mark_spectrum_dirty()


func set_time_scale(value: float) -> void:
	time_scale = value


func set_frozen(on: bool) -> void:
	_frozen = on


func set_render_scale(value: float) -> void:
	_viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, value)


func set_sun_elevation(value: float) -> void:
	sun_elevation = value
	_apply_sun()


func set_sun_azimuth(value: float) -> void:
	sun_azimuth = value
	_apply_sun()


func set_map_size(n: int) -> void:
	if n == solver.map_size:
		return
	_release_textures()
	RenderingServer.call_on_render_thread(solver.free_render)
	solver.map_size = n
	GameManager.set_setting("ocean_map_size", n)
	RenderingServer.call_on_render_thread(solver.init_render)


## Tossed from the camera; buoyancy runs off the same height sampler the
## underwater toggle uses, so crates ride the rendered swell.
func throw_crate() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var crate := OceanBuoy.new()
	crate.height_sampler = waves.sampler()
	add_child(crate)
	var fwd := -cam.global_transform.basis.z
	crate.global_position = cam.global_position + fwd * 4.0 + Vector3.UP
	crate.linear_velocity = fwd * 14.0 + Vector3.UP * 4.0
	crate.angular_velocity = Vector3(
		_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0)
	)
	_crates.append(crate)
	if _crates.size() > MAX_CRATES:
		_crates.pop_front().queue_free()


func clear_crates() -> void:
	for crate in _crates:
		if is_instance_valid(crate):
			crate.queue_free()
	_crates.clear()


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
	_menu_builder.solver = solver
	_menu_builder.surface_mat = surface_mat
	_menu_builder.world_env = world_env
	_menu_builder.storm = storm
	_menu_builder.profiler = profiler
	_menu_builder.host = self
	_menu_builder.build(menu, PRESETS, sun_elevation, sun_azimuth, time_scale)


func _apply_sun() -> void:
	sun.rotation_degrees = Vector3(-sun_elevation, sun_azimuth, 0.0)


func _bind_textures() -> void:
	disp_texture = Texture2DArrayRD.new()
	disp_texture.texture_rd_rid = solver.get_displacement_tex_rid()
	norm_texture = Texture2DArrayRD.new()
	norm_texture.texture_rd_rid = solver.get_normal_tex_rid()
	surface_mat.set_shader_parameter("displacements", disp_texture)
	surface_mat.set_shader_parameter("normals", norm_texture)
	texture_bound = true


## Dropping the RIDs before the solver frees them keeps the Texture2DArrayRD
## wrappers from pointing at dead GPU memory for a frame.
func _release_textures() -> void:
	if disp_texture != null:
		disp_texture.texture_rd_rid = RID()
	if norm_texture != null:
		norm_texture.texture_rd_rid = RID()
	texture_bound = false


## Solver stage timings, under the overlay's frame line.
func _profiler_lines() -> PackedStringArray:
	var t := solver.get_timings()
	var lines := PackedStringArray()
	if t.has("total"):
		lines.append("sim GPU %.2f ms" % t["total"])
	if t.has("spectrum"):
		lines.append("  spectrum %.2f | fft %.2f | assemble %.2f" % [
			t.get("spectrum", 0.0), t.get("fft", 0.0), t.get("assemble", 0.0),
		])
	return lines


## Camera vs water surface. The choppy xz offset is ignored: metre-level error,
## fine for a fullscreen toggle.
func _update_underwater(cam_pos: Vector3) -> void:
	var below := cam_pos.y < waves.sample(Vector2(cam_pos.x, cam_pos.z))
	if below == _underwater:
		return
	_underwater = below
	storm.underwater = below
	underwater_tint.visible = below
	# Single source of truth: the surface shader picks its interface side from
	# this, so the overlay and the water shading can never disagree.
	surface_mat.set_shader_parameter("camera_underwater", below)
	world_env.environment.fog_density = 0.03 if below else storm.surface_fog_density
	world_env.environment.fog_light_color = \
		Color(0.05, 0.19, 0.24) if below else storm.surface_fog_color
