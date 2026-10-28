class_name RiverWaterfallSpray
extends Node3D
## Impact effects at the foot of a waterfall: a churning foam boil, a rising mist
## cloud that shows a rainbow when the sun is behind the viewer, elongated splash
## sheets and a volumetric mist volume. Emitters follow the landing points of the
## waterfall transport; its rock impacts get their own splash and puffs. The volume only renders when the host Environment has
## volumetric fog enabled; keep its base density at 0 so only this volume adds fog.
##
##   var spray := RiverWaterfallSpray.new()
##   spray.noise_texture = seamless_noise           # tileable 2D noise
##   add_child(spray)
##   spray.start()
##   spray.set_impacts(landing_points, downstream, across, width_m)
##   spray.set_rock_impacts(rock_hits, downstream)           # Vector4(x, y, z, rate)
##   spray.tick(intensity, false)                    # every frame, intensity in [0, 1]

const BOIL_COUNT := [36, 60, 96, 144]
const MIST_COUNT := [10, 16, 24, 32]
const SPLASH_COUNT := [48, 128, 192, 288]
const ROCK_SPLASH_COUNT := [16, 40, 64, 96]
const ROCK_PUFF_COUNT := [10, 20, 32, 48]
const ROCK_PUFF_OPACITY := 0.45
const BOIL_LIFETIME_S := 2.6
const MIST_LIFETIME_S := 8.0
const SPLASH_LIFETIME_S := 0.7
# A droplet streaks over one 1/60 s exposure at its top speed; wider or longer it reads as a white stick.
const SPLASH_STREAK_M := Vector2(0.012, 0.1)
const ROCK_SPLASH_STREAK_M := Vector2(0.01, 0.05)
const BOIL_OFFSETS_M := [0.0, 0.35, 0.8]
const BOIL_INSET := 0.95
const MIST_OFFSETS_M := [0.6, 2.0]
const BOIL_OPACITY := 0.5
const MIST_OPACITY := 0.2
const FOG_DENSITY := 1.0
const FOG_MARGIN_M := Vector3(4.0, 4.5, 6.0)
const VISIBILITY_MARGIN_M := 6.0
const ACTIVE_INTENSITY := 0.08

var noise_texture: Texture2D
var _boil: GPUParticles3D
var _mist: GPUParticles3D
var _splash: GPUParticles3D
var _rock_splash: GPUParticles3D
var _rock_puff: GPUParticles3D
var _fog: FogVolume
var _mist_material: ShaderMaterial
var _fog_material: ShaderMaterial
var _mist_density := 0.6
var _splash_count := 0
var _rock_count := 0


func start() -> void:
	assert(noise_texture != null, "RiverWaterfallSpray needs a noise texture.")
	_boil = _particles("Boil", BOIL_LIFETIME_S, _puff_material(BOIL_OPACITY, 0.1, 0.0), Vector2.ONE)
	var boil := _boil.process_material as ParticleProcessMaterial
	boil.spread = 30.0
	boil.initial_velocity_min = 0.5
	boil.initial_velocity_max = 1.2
	boil.gravity = Vector3.ZERO
	boil.damping_min = 0.9
	boil.damping_max = 1.3
	boil.scale_min = 0.8
	boil.scale_max = 1.2
	boil.scale_curve = _curve([Vector2(0.0, 0.6), Vector2(0.4, 1.0), Vector2(1.0, 1.3)])
	boil.color_ramp = _fade([Vector2(0.2, 0.9), Vector2(0.6, 0.6)])
	_mist_material = _puff_material(MIST_OPACITY, 0.05, 1.2)
	_mist_material.set_shader_parameter("glow", 0.2)
	_mist = _particles("Mist", MIST_LIFETIME_S, _mist_material, Vector2.ONE)
	var mist := _mist.process_material as ParticleProcessMaterial
	mist.spread = 50.0
	mist.initial_velocity_min = 0.3
	mist.initial_velocity_max = 0.8
	mist.gravity = Vector3(0.0, 0.12, 0.0)
	mist.damping_min = 0.05
	mist.damping_max = 0.15
	mist.scale_min = 2.0
	mist.scale_max = 3.0
	mist.scale_curve = _curve([Vector2(0.0, 0.6), Vector2(0.5, 1.0), Vector2(1.0, 1.4)])
	mist.color_ramp = _fade([Vector2(0.25, 0.8), Vector2(0.6, 0.6)])
	var droplet := ShaderMaterial.new()
	droplet.shader = load("res://shaders/river/river_waterfall_droplet.gdshader")
	droplet.render_priority = 2
	droplet.set_shader_parameter("noise_texture", noise_texture)
	_splash = _particles("Splash", SPLASH_LIFETIME_S, droplet, SPLASH_STREAK_M)
	var splash := _splash.process_material as ParticleProcessMaterial
	splash.spread = 50.0
	splash.initial_velocity_min = 3.0
	splash.initial_velocity_max = 6.0
	splash.gravity = Vector3(0.0, -9.81, 0.0)
	splash.scale_min = 0.6
	splash.scale_max = 1.4
	splash.particle_flag_align_y = true
	splash.color_ramp = _fade([Vector2(0.05, 0.9), Vector2(0.7, 0.6)])
	_rock_splash = _particles("RockSplash", SPLASH_LIFETIME_S, droplet, ROCK_SPLASH_STREAK_M)
	var rock_splash := _rock_splash.process_material as ParticleProcessMaterial
	rock_splash.spread = 55.0
	rock_splash.initial_velocity_min = 1.0
	rock_splash.initial_velocity_max = 3.0
	rock_splash.gravity = Vector3(0.0, -9.81, 0.0)
	rock_splash.scale_min = 0.5
	rock_splash.scale_max = 1.2
	rock_splash.particle_flag_align_y = true
	rock_splash.color_ramp = splash.color_ramp
	_rock_puff = _particles("RockPuff", 1.2, _puff_material(ROCK_PUFF_OPACITY, 0.1, 0.0), Vector2.ONE * 0.8)
	var rock_puff := _rock_puff.process_material as ParticleProcessMaterial
	rock_puff.spread = 60.0
	rock_puff.initial_velocity_min = 0.4
	rock_puff.initial_velocity_max = 1.1
	rock_puff.gravity = Vector3(0.0, -1.5, 0.0)
	rock_puff.damping_min = 0.8
	rock_puff.damping_max = 1.2
	rock_puff.scale_curve = _curve([Vector2(0.0, 0.5), Vector2(0.5, 1.0), Vector2(1.0, 1.4)])
	rock_puff.color_ramp = _fade([Vector2(0.15, 0.8), Vector2(0.5, 0.5)])
	var noise := FastNoiseLite.new()
	noise.seed = 913
	noise.frequency = 0.06
	noise.fractal_octaves = 3
	var volume := NoiseTexture3D.new()
	volume.width = 64
	volume.height = 64
	volume.depth = 64
	volume.seamless = true
	volume.noise = noise
	_fog_material = ShaderMaterial.new()
	_fog_material.shader = load("res://shaders/river/river_waterfall_mist.gdshader")
	_fog_material.set_shader_parameter("density_texture", volume)
	_fog = FogVolume.new()
	_fog.name = "MistVolume"
	_fog.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_fog.material = _fog_material
	add_child(_fog)
	set_quality(1)
	set_mist_density(_mist_density)


func stop() -> void:
	for child in get_children():
		child.free()
	_boil = null
	_mist = null
	_splash = null
	_rock_splash = null
	_rock_puff = null
	_fog = null
	_mist_material = null
	_fog_material = null


func set_quality(tier: int) -> void:
	if _boil == null:
		return
	_boil.amount = BOIL_COUNT[tier]
	_mist.amount = MIST_COUNT[tier]
	_splash_count = SPLASH_COUNT[tier]
	_splash.amount = maxi(_splash_count, 1)
	_splash.visible = _splash_count > 0
	_rock_splash.amount = ROCK_SPLASH_COUNT[tier]
	_rock_puff.amount = ROCK_PUFF_COUNT[tier]


func set_mist_density(value: float) -> void:
	_mist_density = value
	if _mist_material != null:
		_mist_material.set_shader_parameter("opacity", MIST_OPACITY * value)


func set_impacts(points: PackedVector3Array, downstream: Vector3, across: Vector3, width_m: float) -> void:
	var center := (points[0] + points[points.size() - 1]) * 0.5
	var inset := PackedVector3Array()
	for point in points:
		inset.append(center + (point - center) * BOIL_INSET)
	_emit_from(_boil, _band(inset, downstream, BOIL_OFFSETS_M, 0.1))
	_emit_from(_mist, _band(points, downstream, MIST_OFFSETS_M, 0.3))
	_emit_from(_splash, _band(points, downstream, [0.0], 0.05))
	(_boil.process_material as ParticleProcessMaterial).direction = (Vector3.UP + downstream * 0.9).normalized()
	(_mist.process_material as ParticleProcessMaterial).direction = (Vector3.UP + downstream * 0.6).normalized()
	(_splash.process_material as ParticleProcessMaterial).direction = (Vector3.UP + downstream * 0.6).normalized()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	var surface := 0.0
	for point in points:
		surface += point.y / points.size()
	for particles: GPUParticles3D in [_boil, _mist, _splash]:
		particles.visibility_aabb = bounds.grow(VISIBILITY_MARGIN_M)
	for particles: GPUParticles3D in [_boil, _mist]:
		((particles.draw_pass_1 as QuadMesh).material as ShaderMaterial).set_shader_parameter("surface_m", surface)
	_fog.transform = Transform3D(Basis(across, Vector3.UP, across.cross(Vector3.UP)),
		bounds.get_center() + downstream * 1.5 + Vector3.UP * 1.5)
	_fog.size = Vector3(width_m, 0.0, 0.0) + FOG_MARGIN_M


func set_rock_impacts(impacts: PackedVector4Array, downstream: Vector3) -> void:
	var points := PackedVector3Array()
	for impact in impacts:
		points.append(Vector3(impact.x, impact.y, impact.z))
	_rock_count = points.size()
	if points.is_empty():
		return
	_emit_from(_rock_splash, _band(points, downstream, [0.0], 0.03))
	_emit_from(_rock_puff, _band(points, downstream, [0.0], 0.1))
	(_rock_splash.process_material as ParticleProcessMaterial).direction = (Vector3.UP + downstream * 0.8).normalized()
	(_rock_puff.process_material as ParticleProcessMaterial).direction = (Vector3.UP + downstream * 0.5).normalized()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	for particles: GPUParticles3D in [_rock_splash, _rock_puff]:
		particles.visibility_aabb = bounds.grow(VISIBILITY_MARGIN_M)


func tick(intensity: float, frozen: bool) -> void:
	var active := intensity > ACTIVE_INTENSITY
	for particles: GPUParticles3D in [_boil, _mist, _splash, _rock_splash, _rock_puff]:
		particles.speed_scale = 0.0 if frozen else 1.0
		particles.amount_ratio = clampf(intensity, 0.05, 1.0)
	_boil.emitting = active
	_rock_splash.emitting = active and _rock_count > 0
	_rock_puff.emitting = active and _rock_count > 0
	_splash.emitting = active and _splash_count > 0
	_mist.emitting = active and _mist_density > 0.0
	_fog.visible = active and _mist_density > 0.0
	_fog_material.set_shader_parameter("density", FOG_DENSITY * _mist_density * clampf(intensity, 0.0, 1.0))


func restart() -> void:
	if _boil == null:
		return
	for particles: GPUParticles3D in [_boil, _mist, _splash, _rock_splash, _rock_puff]:
		particles.restart(true)


func _puff_material(opacity: float, churn_per_s: float, rainbow_strength: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_waterfall_puff.gdshader")
	material.render_priority = 2
	material.set_shader_parameter("noise_texture", noise_texture)
	material.set_shader_parameter("opacity", opacity)
	material.set_shader_parameter("churn_per_s", churn_per_s)
	material.set_shader_parameter("rainbow_strength", rainbow_strength)
	return material


func _particles(label: String, lifetime_s: float, material: ShaderMaterial, size_m: Vector2) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = label
	particles.lifetime = lifetime_s
	particles.preprocess = lifetime_s
	particles.fixed_fps = 0
	particles.randomness = 0.3
	particles.local_coords = false
	particles.layers = 2
	particles.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = size_m
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
	return particles


static func _band(points: PackedVector3Array, downstream: Vector3, offsets_m: Array, lift_m: float) -> PackedVector3Array:
	var band := PackedVector3Array()
	for offset_m: float in offsets_m:
		for point in points:
			band.append(point + downstream * offset_m + Vector3.UP * lift_m)
	return band


func _emit_from(particles: GPUParticles3D, points: PackedVector3Array) -> void:
	var image := Image.create(points.size(), 1, false, Image.FORMAT_RGBF)
	for i in points.size():
		image.set_pixel(i, 0, Color(points[i].x, points[i].y, points[i].z))
	var process := particles.process_material as ParticleProcessMaterial
	process.emission_point_texture = ImageTexture.create_from_image(image)
	process.emission_point_count = points.size()


static func _curve(points: Array[Vector2]) -> CurveTexture:
	var curve := Curve.new()
	curve.max_value = 2.0
	for point in points:
		curve.add_point(point)
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


static func _fade(points: Array[Vector2]) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	gradient.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	for point in points:
		gradient.add_point(point.x, Color(1.0, 1.0, 1.0, point.y))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture
