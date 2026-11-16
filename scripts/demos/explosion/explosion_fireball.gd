class_name ExplosionFireball extends RefCounted

const FLAME_SHADER := preload("res://shaders/wildfire/flame.gdshader")
const SPRITE_SHADER := preload("res://shaders/wildfire/fire_sprite.gdshader")
const CORE_SHADER := preload("res://shaders/explosion/fireball_core.gdshader")
## Look radius; the collision sphere stays the preset's radius.
const VISUAL_RADIUS_M := 0.3
const LIGHT_COLOR := Color(1.0, 0.55, 0.2)
const LIGHT_ENERGY := 6.0
const LIGHT_RANGE_M := 12.0
const FLAME_COUNT := 60
const FLAME_LIFETIME_S := 0.3
const FLAME_SIZE_M := 0.55
const SHEATH_COUNT := 10
const SHEATH_SIZE_M := 0.4
const TAIL_SPEED_MPS := Vector2(4.0, 7.0)
const TAIL_DAMPING := 2.5
const SMOKE_COUNT := 400
const SMOKE_LIFETIME_S := 1.5
const SMOKE_SIZE_M := 0.9
const EMBER_COUNT := 24
const EMBER_LIFETIME_S := 0.9
const EMBER_SIZE_M := 0.07
const VISIBILITY_M := 30.0

static var _noise: NoiseTexture2D
static var _flame_material: ShaderMaterial
static var _smoke_material: ShaderMaterial
static var _grow: CurveTexture
static var _shrink: CurveTexture
static var _core_material: ShaderMaterial
static var _ember_material: StandardMaterial3D


## Dresses a freshly spawned projectile: a white-hot core, flame licks and a short smoke trail left in world space, and a light that travels with it.
static func attach(ball: RigidBody3D, preset: ProjectilePreset) -> void:
	var back := -(ball.get_meta("launch_velocity", Vector3.FORWARD) as Vector3).normalized()
	for child in ball.get_children():
		var core := child as MeshInstance3D
		if core != null:
			var sphere := core.mesh as SphereMesh
			sphere.radius = VISUAL_RADIUS_M
			sphere.height = VISUAL_RADIUS_M * 2.0
			sphere.material = _core()
	var tail := _particles(_flame_process(back), FLAME_SIZE_M, _flames(), FLAME_COUNT, FLAME_LIFETIME_S)
	tail.local_coords = true
	ball.add_child(tail)
	var sheath := _particles(_sheath_process(), SHEATH_SIZE_M, _flames(), SHEATH_COUNT, FLAME_LIFETIME_S)
	sheath.local_coords = true
	ball.add_child(sheath)
	ball.add_child(_particles(_smoke_process(), SMOKE_SIZE_M, _smoke(), SMOKE_COUNT, SMOKE_LIFETIME_S))
	var embers := _particles(_ember_process(back), EMBER_SIZE_M, _embers(), EMBER_COUNT, EMBER_LIFETIME_S)
	ball.add_child(embers)
	var light := OmniLight3D.new()
	light.light_color = LIGHT_COLOR
	light.light_energy = LIGHT_ENERGY
	light.omni_range = LIGHT_RANGE_M
	ball.add_child(light)
	ball.body_entered.connect(_burn_out.bind(ball), CONNECT_ONE_SHOT)


## First contact: the flames and the light go out, so a ball resting on the ground adds no cost.
static func _burn_out(_other: Node, ball: RigidBody3D) -> void:
	for child in ball.get_children():
		if child is GPUParticles3D:
			child.emitting = false
		elif child is OmniLight3D:
			child.queue_free()


static func _core() -> ShaderMaterial:
	if _core_material == null:
		_core_material = ShaderMaterial.new()
		_core_material.shader = CORE_SHADER
		_core_material.render_priority = 0
		_core_material.set_shader_parameter("noise_tex", _noise_texture())
	return _core_material


static func _particles(process: ParticleProcessMaterial, size_m: float, material: Material,
		count: int, lifetime_s: float) -> GPUParticles3D:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * size_m
	quad.material = material
	var particles := GPUParticles3D.new()
	particles.process_material = process
	particles.draw_pass_1 = quad
	particles.amount = count
	particles.lifetime = lifetime_s
	particles.fixed_fps = 60
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3.ONE * -VISIBILITY_M, Vector3.ONE * VISIBILITY_M * 2.0)
	return particles


static func _flame_process(back: Vector3) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	process.emission_sphere_radius = VISUAL_RADIUS_M
	process.direction = back
	process.spread = 8.0
	process.initial_velocity_min = TAIL_SPEED_MPS.x
	process.initial_velocity_max = TAIL_SPEED_MPS.y
	process.gravity = Vector3(0.0, 1.5, 0.0)
	process.damping_min = TAIL_DAMPING
	process.damping_max = TAIL_DAMPING
	process.scale_min = 0.6
	process.scale_max = 1.1
	process.scale_curve = _shrink_curve()
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.anim_offset_max = 1.0
	process.lifetime_randomness = 0.3
	return process


static func _sheath_process() -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = VISUAL_RADIUS_M * 0.9
	process.direction = Vector3.UP
	process.spread = 180.0
	process.initial_velocity_min = 0.2
	process.initial_velocity_max = 0.8
	process.scale_min = 0.7
	process.scale_max = 1.1
	process.scale_curve = _shrink_curve()
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.anim_offset_max = 1.0
	return process


static func _smoke_process() -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = VISUAL_RADIUS_M * 0.5
	process.direction = Vector3.UP
	process.spread = 60.0
	process.initial_velocity_min = 0.1
	process.initial_velocity_max = 0.4
	process.gravity = Vector3(0.0, 0.5, 0.0)
	process.scale_min = 0.5
	process.scale_max = 0.8
	process.scale_curve = _grow_curve()
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.anim_offset_max = 1.0
	process.color = Color(1.0, 1.0, 1.0, 0.7)
	return process


static func _ember_process(back: Vector3) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	process.emission_sphere_radius = VISUAL_RADIUS_M
	process.direction = back
	process.spread = 70.0
	process.initial_velocity_min = 1.0
	process.initial_velocity_max = 3.0
	process.gravity = Vector3(0.0, -3.0, 0.0)
	process.scale_min = 0.5
	process.scale_max = 1.5
	return process


static func _embers() -> StandardMaterial3D:
	if _ember_material == null:
		_ember_material = StandardMaterial3D.new()
		_ember_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ember_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		_ember_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ember_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		var dot := GradientTexture2D.new()
		dot.width = 32
		dot.height = 32
		dot.fill = GradientTexture2D.FILL_RADIAL
		dot.fill_from = Vector2(0.5, 0.5)
		dot.fill_to = Vector2(1.0, 0.5)
		dot.gradient = Gradient.new()
		dot.gradient.set_color(0, Color(1.0, 0.7, 0.25, 1.0))
		dot.gradient.set_color(1, Color(1.0, 0.3, 0.05, 0.0))
		_ember_material.albedo_texture = dot
		_ember_material.albedo_color = Color(2.0, 1.4, 0.6)
	return _ember_material


static func _flames() -> ShaderMaterial:
	if _flame_material == null:
		_flame_material = ShaderMaterial.new()
		_flame_material.shader = FLAME_SHADER
		_flame_material.render_priority = 1
		_flame_material.set_shader_parameter("noise_tex", _noise_texture())
		_flame_material.set_shader_parameter("puff", 1.0)
		_flame_material.set_shader_parameter("emission_energy", 0.65)
		_flame_material.set_shader_parameter("heat_bias", -0.2)
		_flame_material.set_shader_parameter("opacity", 0.8)
	return _flame_material


static func _smoke() -> ShaderMaterial:
	if _smoke_material == null:
		_smoke_material = ShaderMaterial.new()
		_smoke_material.shader = SPRITE_SHADER
		_smoke_material.render_priority = -1
		_smoke_material.set_shader_parameter("noise_tex", _noise_texture())
		_smoke_material.set_shader_parameter("tint_young", Vector3(0.55, 0.52, 0.5))
		_smoke_material.set_shader_parameter("tint_old", Vector3(0.3, 0.3, 0.3))
		_smoke_material.set_shader_parameter("opacity", 0.7)
		_smoke_material.set_shader_parameter("erosion", 0.45)
		_smoke_material.set_shader_parameter("edge_softness", 0.5)
		_smoke_material.set_shader_parameter("light_ceiling", 1.0)
		_smoke_material.set_shader_parameter("flow_speed", 0.25)
		_smoke_material.set_shader_parameter("fade_in", 0.25)
		_smoke_material.set_shader_parameter("fade_out_start", 0.5)
	return _smoke_material


static func _noise_texture() -> NoiseTexture2D:
	if _noise == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.012
		noise.fractal_octaves = 4
		_noise = NoiseTexture2D.new()
		_noise.width = 256
		_noise.height = 256
		_noise.seamless = true
		_noise.generate_mipmaps = true
		_noise.noise = noise
	return _noise


static func _shrink_curve() -> CurveTexture:
	if _shrink == null:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, 0.15))
		_shrink = CurveTexture.new()
		_shrink.curve = curve
	return _shrink


static func _grow_curve() -> CurveTexture:
	if _grow == null:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 0.5))
		curve.add_point(Vector2(0.4, 1.0))
		curve.add_point(Vector2(1.0, 0.6))
		_grow = CurveTexture.new()
		_grow.curve = curve
	return _grow
