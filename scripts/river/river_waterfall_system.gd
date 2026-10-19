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
var _spray: RiverWaterfallSpray
var _rebuild_at_ms := -1


func start() -> void:
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/river/river_waterfall.gdshader")
	material.render_priority = 1
	material.set_shader_parameter("turbulence_texture", turbulence_texture)
	material.set_shader_parameter("streak_texture", load("res://resources/river/waterfall_streaks.png"))
	material.set_shader_parameter("free_fall", config.is_vertical())
	material.set_shader_parameter("fall_grid", Vector4(config.lane_count, config.film_cells, config.packet_capacity, config.emission_rate_hz))
	material.set_shader_parameter("film_length_m", config.length_m())
	material.set_shader_parameter("max_film_m", RiverWaterfallCurtain.MAX_FILM_M)
	material.set_shader_parameter("reflection_layer", reflection_layer)
	_surface = MeshInstance3D.new()
	_surface.name = "WaterfallSheet"
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface.layers = 1
	add_child(_surface)
	_spray = RiverWaterfallSpray.new()
	_spray.name = "WaterfallSpray"
	_spray.noise_texture = turbulence_texture
	add_child(_spray)
	_spray.start()
	set_quality(quality_tier)
	apply_config(water)
	_rebuild()


func apply_config(value: RiverConfig) -> void:
	water = value
	if material == null:
		return
	material.set_shader_parameter("speed_m_s", water.speed_m_s)
	material.set_shader_parameter("landing_level_m", water.water_level_m)
	material.set_shader_parameter("source_height_m", source_height_m(field, config, water))
	material.set_shader_parameter("reflection_heights_m", Vector2(water.water_level_m, water.water_level_m + config.height_m))
	material.set_shader_parameter("foam_amount", water.foam_amount)
	material.set_shader_parameter("deep_color", water.deep_color)
	material.set_shader_parameter("clarity", water.clarity)
	_spray.set_mist_density(water.mist_density)
	_rebuild_at_ms = Time.get_ticks_msec() + REBUILD_DELAY_MS


func set_quality(tier: int) -> void:
	quality_tier = clampi(tier, 0, 3)
	if _surface == null:
		return
	_spray.set_quality(quality_tier)
	_rebuild_at_ms = Time.get_ticks_msec()


static func source_height_m(river_field: RiverField, profile: RiverWaterfallConfig, flow: RiverConfig) -> float:
	return river_field.sample_height(Vector2(0.0, profile.crest_z_m + INLET_M), flow.water_level_m)


static func build_curtain(river_field: RiverField, profile: RiverWaterfallConfig, flow: RiverConfig,
		columns: int, rows: int) -> RiverWaterfallCurtain:
	var curtain := RiverWaterfallCurtain.new()
	curtain.ground = river_field.sample_ground_height
	var half := Vector3(profile.width_m * 0.5, 0.0, 0.0)
	var crest := Vector3(0.0, 0.0, profile.crest_z_m)
	curtain.crest_from = crest - half
	curtain.crest_to = crest + half
	curtain.surface_height_m = source_height_m(river_field, profile, flow)
	curtain.speed_m_s = flow.speed_m_s
	curtain.landing_level_m = flow.water_level_m
	curtain.inlet_m = INLET_M
	curtain.columns = columns
	curtain.rows = rows
	return curtain


func _rebuild() -> void:
	_rebuild_at_ms = -1
	var curtain := build_curtain(field, config, water, COLUMNS[quality_tier], ROWS[quality_tier])
	_surface.mesh = curtain.build()
	_surface.mesh.surface_set_material(0, material)
	material.set_shader_parameter("across_direction", curtain.across)
	material.set_shader_parameter("width_m", curtain.width_m)
	var points := curtain.impact_points if not curtain.impact_points.is_empty() \
		else PackedVector3Array([Vector3(0.0, 0.0, config.crest_z_m)])
	_spray.set_impacts(points, curtain.downstream, curtain.across, curtain.width_m)


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
	_spray.tick(clampf(intensity, 0.0, 1.0), frozen)


func reset() -> void:
	if _spray != null:
		_spray.restart()


func stop() -> void:
	if material != null:
		for parameter: String in ["fall_surface", "fall_clock", "fall_boundary", "basin_surface"]:
			material.set_shader_parameter(parameter, null)
	if _spray != null:
		_spray.stop()
	for child in get_children():
		child.free()
	material = null
	_surface = null
	_spray = null


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
		thickness = (config.bed_depth_m + water.water_level_m) * water.speed_m_s / maxf(speed, 0.05)
		surface = Vector3(point.x, config.height_m - config.bed_depth_m, config.crest_z_m) + config.tangent() * along + normal * thickness
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
		thickness = (config.bed_depth_m + water.water_level_m) * water.speed_m_s / maxf(velocity.length(), 0.05)
		surface = Vector3(point.x, config.height_m + water.water_level_m - 0.5 * 9.81 * age * age, config.crest_z_m - water.speed_m_s * age)
		kind = 3.0
		if absf(point.z - surface.z) > 0.8:
			return []
	if absf(normal.dot(point - surface)) > thickness * 0.5 + 0.8:
		return []
	return [Vector4(surface.x, surface.y, surface.z, thickness), Vector4(velocity.x, velocity.y, velocity.z, kind), Vector4(normal.x, normal.y, normal.z, normal.dot(point - surface))]


func set_effects_enabled(enabled: bool) -> void:
	_spray.visible = enabled
