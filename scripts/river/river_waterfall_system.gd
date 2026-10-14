extends Node3D

const INLET_M := 0.3
const REBUILD_DELAY_MS := 150
const COLUMNS := [16, 24, 32, 48]
const ROWS := [48, 72, 96, 128]

var config: RiverWaterfallConfig
var field: RiverField
var water: RiverConfig
var swe: Node3D
var turbulence_texture: Texture2D
var reflection_layer := 0
var material: ShaderMaterial
var quality_tier := 1
var _surface: MeshInstance3D
var _spray: GPUParticles3D
var _mist: GPUParticles3D
var _rebuild_at_ms := -1


func start() -> void:
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_waterfall.gdshader")
	material.set_shader_parameter("turbulence_texture", turbulence_texture)
	material.set_shader_parameter("free_fall", config.is_vertical())
	material.set_shader_parameter("fall_grid", Vector4(config.lane_count, config.film_cells, config.packet_capacity, config.emission_rate_hz))
	material.set_shader_parameter("film_length_m", config.length_m())
	material.set_shader_parameter("inlet_m", INLET_M)
	material.set_shader_parameter("reflection_layer", reflection_layer)
	_surface = MeshInstance3D.new()
	_surface.name = "WaterfallSheet"
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.layers = 1
	add_child(_surface)
	_spray = _particles(false)
	_mist = _particles(true)
	set_quality(quality_tier)
	apply_config(water)
	_rebuild()


func apply_config(value: RiverConfig) -> void:
	water = value
	if material == null:
		return
	material.set_shader_parameter("speed_m_s", water.speed_m_s)
	material.set_shader_parameter("landing_level_m", water.water_level_m)
	material.set_shader_parameter("reflection_heights_m", Vector2(water.water_level_m, water.water_level_m + config.height_m))
	material.set_shader_parameter("foam_amount", water.foam_amount)
	material.set_shader_parameter("deep_color", water.deep_color)
	material.set_shader_parameter("clarity", water.clarity)
	_rebuild_at_ms = Time.get_ticks_msec() + REBUILD_DELAY_MS


func set_quality(tier: int) -> void:
	quality_tier = clampi(tier, 0, 3)
	if _surface == null:
		return
	_spray.amount = [96, 256, 512, 1024][quality_tier]
	_mist.amount = [24, 48, 96, 160][quality_tier]
	_rebuild_at_ms = Time.get_ticks_msec()


func _rebuild() -> void:
	_rebuild_at_ms = -1
	var curtain := RiverWaterfallCurtain.new()
	curtain.ground = field.sample_ground_height
	var half := Vector3(config.width_m * 0.5, 0.0, 0.0)
	var crest := Vector3(0.0, 0.0, config.crest_z_m)
	curtain.crest_from = crest - half
	curtain.crest_to = crest + half
	curtain.surface_height_m = config.height_m + water.water_level_m
	curtain.speed_m_s = water.speed_m_s
	curtain.landing_level_m = water.water_level_m
	curtain.inlet_m = INLET_M
	curtain.columns = COLUMNS[quality_tier]
	curtain.rows = ROWS[quality_tier]
	_surface.mesh = curtain.build()
	_surface.mesh.surface_set_material(0, material)
	material.set_shader_parameter("across_direction", curtain.across)
	material.set_shader_parameter("width_m", curtain.width_m)
	var bounds := _surface.mesh.get_aabb()
	for particles: GPUParticles3D in [_spray, _mist]:
		var process := particles.process_material as ParticleProcessMaterial
		var points := curtain.impact_points if not curtain.impact_points.is_empty() else PackedVector3Array([crest])
		var image := Image.create(points.size(), 1, false, Image.FORMAT_RGBF)
		for i in points.size():
			image.set_pixel(i, 0, Color(points[i].x, points[i].y + 0.05, points[i].z))
		process.emission_point_texture = ImageTexture.create_from_image(image)
		process.emission_point_count = points.size()
		process.direction = (Vector3.UP + curtain.downstream * 0.5).normalized()
		particles.visibility_aabb = bounds.grow(3.0)
	var impact_speed := sqrt(water.speed_m_s * water.speed_m_s + 2.0 * 9.81 * config.height_m)
	(_spray.process_material as ParticleProcessMaterial).initial_velocity_max = clampf(impact_speed * 0.35, 1.0, 5.0)


func tick(time_s: float, frozen: bool) -> void:
	if _rebuild_at_ms >= 0 and Time.get_ticks_msec() >= _rebuild_at_ms:
		_rebuild()
	var live: bool = swe.active and swe.waterfall_surface.texture_rd_rid.is_valid()
	material.set_shader_parameter("simulation_time_s", time_s)
	material.set_shader_parameter("live_enabled", live)
	if live:
		material.set_shader_parameter("fall_surface", swe.waterfall_surface)
		material.set_shader_parameter("fall_clock", swe.waterfall_clock)
		material.set_shader_parameter("fall_boundary", swe.waterfall_boundary)
		material.set_shader_parameter("basin_surface", swe.surface_texture)
		var region: Rect2 = swe.region_m
		material.set_shader_parameter("basin_region", Vector4(region.position.x, region.position.y, region.size.x, region.size.y))
	var intensity := water.foam_amount * minf(water.speed_m_s / 0.85, 1.5)
	for particles: GPUParticles3D in [_spray, _mist]:
		particles.speed_scale = 0.0 if frozen else 1.0
		particles.emitting = intensity > 0.08
		particles.amount_ratio = clampf(intensity, 0.05, 1.0)


func reset() -> void:
	if _spray != null:
		_spray.restart(true)
		_mist.restart(true)


func stop() -> void:
	if material != null:
		for parameter: String in ["fall_surface", "fall_clock", "fall_boundary", "basin_surface"]:
			material.set_shader_parameter(parameter, null)
	for child in get_children():
		child.free()
	material = null
	_surface = null
	_spray = null
	_mist = null


func guided_contact(point: Vector3) -> Array[Vector4]:
	var normal := config.normal()
	var surface: Vector3
	var velocity: Vector3
	var thickness := 0.0
	var kind := 2.0
	if absf(point.x) > config.width_m * 0.5 or water.speed_m_s <= 0.001:
		return []
	if not config.is_vertical():
		var along := clampf((config.crest_z_m - point.z) / cos(deg_to_rad(config.angle_degrees)), 0.0, config.length_m())
		if point.z > config.crest_z_m or point.z < config.crest_z_m - config.run_m():
			return []
		var speed := sqrt(water.speed_m_s * water.speed_m_s + 2.0 * 9.81 * along * sin(deg_to_rad(config.angle_degrees)))
		thickness = (0.64 + water.water_level_m) * water.speed_m_s / maxf(speed, 0.05)
		surface = Vector3(point.x, config.height_m - 0.65, config.crest_z_m) + config.tangent() * along + normal * thickness
		surface.y = maxf(surface.y, field.sample_ground_height(Vector2(surface.x, surface.z)) + 0.01)
		if surface.y <= water.water_level_m:
			return []
		velocity = config.tangent() * speed
	else:
		var age := sqrt(2.0 * maxf(config.height_m + water.water_level_m - point.y, 0.0) / 9.81)
		if point.y > config.height_m + water.water_level_m + 0.4 or point.y < water.water_level_m - 0.4:
			return []
		velocity = Vector3(0.0, -9.81 * age, -water.speed_m_s)
		normal = Vector3.RIGHT.cross(velocity).normalized()
		thickness = (0.64 + water.water_level_m) * water.speed_m_s / maxf(velocity.length(), 0.05)
		surface = Vector3(point.x, config.height_m + water.water_level_m - 0.5 * 9.81 * age * age, config.crest_z_m - water.speed_m_s * age)
		kind = 3.0
		if absf(point.z - surface.z) > 0.8:
			return []
	if absf(normal.dot(point - surface)) > thickness * 0.5 + 0.8:
		return []
	return [Vector4(surface.x, surface.y, surface.z, thickness), Vector4(velocity.x, velocity.y, velocity.z, kind), Vector4(normal.x, normal.y, normal.z, normal.dot(point - surface))]


func set_effects_enabled(enabled: bool) -> void:
	_spray.visible = enabled
	_mist.visible = enabled


func _particles(mist: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "WaterfallMist" if mist else "WaterfallSpray"
	particles.lifetime = 2.6 if mist else 0.9
	particles.randomness = 0.5
	particles.local_coords = false
	particles.layers = 2
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	process.spread = 55.0 if mist else 35.0
	process.initial_velocity_min = 0.2 if mist else 1.0
	process.initial_velocity_max = 0.9 if mist else 3.5
	process.gravity = Vector3(0.0, 0.25, 0.0) if mist else Vector3(0.0, -9.81, 0.0)
	process.damping_min = 0.4 if mist else 0.0
	process.damping_max = 0.8 if mist else 0.0
	process.scale_min = 0.9 if mist else 0.02
	process.scale_max = 1.8 if mist else 0.05
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 0.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	fade.add_point(0.2 if mist else 0.05, Color(1.0, 1.0, 1.0, 1.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp
	if mist:
		var growth := Curve.new()
		growth.add_point(Vector2(0.0, 0.4))
		growth.add_point(Vector2(1.0, 1.0))
		var growth_texture := CurveTexture.new()
		growth_texture.curve = growth
		process.scale_curve = growth_texture
	particles.process_material = process
	var quad := QuadMesh.new()
	var draw := StandardMaterial3D.new()
	draw.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw.vertex_color_use_as_albedo = true
	draw.cull_mode = BaseMaterial3D.CULL_DISABLED
	draw.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var disc := GradientTexture2D.new()
	disc.fill = GradientTexture2D.FILL_RADIAL
	disc.fill_from = Vector2(0.5, 0.5)
	disc.fill_to = Vector2(0.5, 0.0)
	var falloff := Gradient.new()
	falloff.set_color(0, Color(1.0, 1.0, 1.0, 1.0 if not mist else 0.22))
	falloff.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	disc.gradient = falloff
	draw.albedo_texture = disc
	draw.albedo_color = Color(0.86, 0.9, 0.92) if mist else Color(0.8, 0.86, 0.88)
	if mist:
		draw.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		draw.proximity_fade_enabled = true
		draw.proximity_fade_distance = 1.2
	quad.material = draw
	particles.draw_pass_1 = quad
	add_child(particles)
	return particles
