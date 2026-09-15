class_name HeroFire extends Node3D
## The A/B hero campfire's Fire-X side: a private solver + sparse raymarch
## volume driven like the fire demo, parked at the campfire spot in solver
## coordinates. [member active] gates stepping, so the billboard mode measures
## the frame without paying Fire-X's GPU cost — the whole point of the toggle.

const SOLVER_SCRIPT := preload("res://scripts/fire/fire_gpu_solver.gd")
const VOLUME_SHADER := "res://shaders/fire/sparse/fire.gdshader"

## Where the fuel lands, in solver (local) coordinates.
const FUEL_POS := Vector3(0, 0.3, 0)
const FUEL_RADIUS := 0.8

var solver: FireGpuSolver
var active := false:
	set(value):
		active = value
		if _volume_node != null:
			_volume_node.visible = value and _started
		if _sparks != null:
			_sparks.emitting = value and _started
var wind_enabled := false
var wind := Vector3.ZERO
var _started := false

var _material: ShaderMaterial
var _volume_node: MeshInstance3D
var _box_mesh: BoxMesh
var _light: OmniLight3D
var _sparks: GPUParticles3D
var _ignited := false
var _flicker_time := 0.0


func start() -> bool:
	if not GpuPreflight.available():
		return false
	solver = SOLVER_SCRIPT.new()
	_build_volume()
	RenderingServer.call_on_render_thread(solver.init_render)
	var waited := 0
	while not solver.initialized:
		await get_tree().process_frame
		waited += 1
		if waited > 900:
			push_error("HeroFire: solver never initialized")
			return false
	FireVolumeBinding.bind(_material, solver)
	solver.profiling = true
	_volume_node.visible = active and _started
	_started = true
	return true


## Per-frame drive; returns the solver's reduced stats for the HUD.
func update_fire(delta: float) -> Dictionary:
	if solver == null or not solver.initialized:
		return {}
	_flicker_time += delta
	solver.wind = wind if wind_enabled else Vector3.ZERO
	var stats := solver.get_stats()
	if active:
		var step_count := solver.schedule_steps(delta)
		var sim_dt := float(step_count) * solver.timestep
		if step_count > 0:
			solver.push_event(FireGpuSolver.EVENT_FUEL, FUEL_POS, FUEL_RADIUS,
				0.2 * sim_dt)
			if not _ignited:
				_ignited = true
				solver.push_event(FireGpuSolver.EVENT_IGNITE, FUEL_POS, 1.0, 0.4)
		RenderingServer.call_on_render_thread(func() -> void:
			if step_count > 0:
				solver.capture_interpolation_state_render()
				solver.prepare_topology_render()
			solver.poll_render())
		if step_count > 0:
			solver.step_render(step_count)
		else:
			RenderingServer.call_on_render_thread(solver.poll_render)
	FireVolumeBinding.track_proxy(_material, _volume_node, _box_mesh, solver)
	_update_extras(stats)
	return stats


func _exit_tree() -> void:
	if solver == null:
		return
	if _material != null:
		FireVolumeBinding.unbind(_material)
	if _volume_node != null:
		_volume_node.visible = false
	RenderingServer.call_on_render_thread(solver.free_render)


func _build_volume() -> void:
	_box_mesh = BoxMesh.new()
	_box_mesh.size = Vector3.ONE
	_volume_node = MeshInstance3D.new()
	_volume_node.mesh = _box_mesh
	var noise := FastNoiseLite.new()
	noise.frequency = 0.08
	noise.fractal_octaves = 3
	var noise_tex := NoiseTexture3D.new()
	noise_tex.seamless = true
	noise_tex.width = 64
	noise_tex.height = 64
	noise_tex.depth = 64
	noise_tex.noise = noise
	_material = ShaderMaterial.new()
	_material.shader = load(VOLUME_SHADER)
	_material.set_shader_parameter("noise_tex", noise_tex)
	_material.set_shader_parameter("temporal_blend", 1.0)
	_volume_node.material_override = _material
	_volume_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_volume_node)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.18)
	_light.light_energy = 2.0
	_light.omni_range = 11.0
	_light.shadow_enabled = true
	_light.position = FUEL_POS + Vector3(0, 0.8, 0)
	add_child(_light)
	_sparks = _make_sparks()
	add_child(_sparks)


## Sparse ember rise above the flame, solver stats gate it via `active`.
func _make_sparks() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = 40
	particles.lifetime = 1.7
	particles.visibility_aabb = AABB(Vector3(-4, 0, -4), Vector3(8, 8, 8))
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 1, 0)
	process.spread = 22.0
	process.initial_velocity_min = 1.2
	process.initial_velocity_max = 2.8
	process.gravity = Vector3(0, 1.5, 0)
	process.scale_min = 0.4
	process.scale_max = 1.0
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_color = Color(1.0, 0.6, 0.25)
	# Radial falloff baked into RGB *and* alpha: plain additive quads render as
	# solid square sparks.
	var dot := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length() / 15.5
			var f := pow(clampf(1.0 - d, 0.0, 1.0), 1.6)
			dot.set_pixel(x, y, Color(f, f, f, f))
	material.albedo_texture = ImageTexture.create_from_image(dot)
	particles.draw_pass_1 = quad
	particles.material_override = material
	particles.position = FUEL_POS + Vector3(0, 0.5, 0)
	particles.emitting = false
	return particles


func _update_extras(stats: Dictionary) -> void:
	var temp_norm := clampf(
		(stats["max_temperature"] - solver.ambient_temperature) / 2000.0, 0.0, 1.0)
	var flicker := 0.82 + 0.13 * sin(_flicker_time * 11.0) \
		+ 0.05 * sin(_flicker_time * 23.0 + 1.7)
	_light.light_energy = 2.4 * (0.3 + 0.7 * temp_norm) * flicker
	_light.visible = active
