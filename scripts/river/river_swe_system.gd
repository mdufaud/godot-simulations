extends Node3D

const Solver := preload("res://scripts/river/river_swe_solver.gd")

signal state_changed

var config: RiverConfig
var field: RiverField
var region_m := Rect2()
var cell_m := Solver.CELL_M
var active: bool:
	get: return enabled and initialized
var materials: Array[ShaderMaterial] = []
var available := false
var enabled := true
var profiling := false
var initialized := false
var solver := Solver.new()
var surface_texture := Texture2DRD.new()
var foam_texture := Texture2DRD.new()
var terrain_texture := Texture2DRD.new()
var _spray: GPUParticles3D
var _spray_material: ShaderMaterial
var _reset := true


func start() -> void:
	if not available:
		state_changed.emit()
		return
	region_m = Rect2(-field.domain_m * 0.5, field.domain_m)
	solver.cell_m = cell_m
	solver.grid = Vector2i((field.domain_m / cell_m).ceil())
	region_m.size = Vector2(solver.grid) * cell_m
	solver.region_m = region_m
	_build_spray()
	solver.start(field, config)


func set_enabled(value: bool) -> void:
	enabled = value
	reset()
	_bind()
	state_changed.emit()


func reset() -> void:
	_reset = true
	if _spray != null:
		_spray.restart(true)


func tick(step_s: float, frame_s: float, time_s: float) -> void:
	if not available:
		return
	if not initialized and bool(solver.snapshot().get("ready", false)):
		initialized = true
		var status := solver.snapshot()
		surface_texture.texture_rd_rid = status.surface
		foam_texture.texture_rd_rid = status.foam
		terrain_texture.texture_rd_rid = status.terrain
		_bind()
		state_changed.emit()
	if not initialized:
		return
	_spray.speed_scale = step_s / maxf(frame_s, 0.0001)
	_spray_material.set_shader_parameter("strength", config.whitewater_strength * config.foam_amount)
	if active and (step_s > 0.0 or _reset):
		RenderingServer.call_on_render_thread(solver.advance_render.bind(step_s,
			solver.parameters(config, time_s), _reset, profiling))
		_reset = false


func gpu_ms() -> float:
	return float(solver.snapshot().get("gpu_ms", 0.0)) if active else 0.0


func stop() -> void:
	initialized = false
	for material in materials:
		material.set_shader_parameter("swe_enabled", false)
		for parameter: String in ["swe_surface", "swe_foam", "swe_terrain"]:
			material.set_shader_parameter(parameter, null)
	if _spray_material != null:
		for parameter: String in ["swe_surface", "swe_foam", "swe_terrain"]:
			_spray_material.set_shader_parameter(parameter, null)
	surface_texture.texture_rd_rid = RID()
	foam_texture.texture_rd_rid = RID()
	terrain_texture.texture_rd_rid = RID()
	solver.stop()
	for child in get_children():
		child.free()
	_spray = null
	_spray_material = null


func _bind() -> void:
	var region := region_m
	for material in materials + [_spray_material]:
		if material == null:
			continue
		material.set_shader_parameter("swe_surface", surface_texture)
		material.set_shader_parameter("swe_foam", foam_texture)
		material.set_shader_parameter("swe_terrain", terrain_texture)
		material.set_shader_parameter("swe_region_m", Vector4(region.position.x, region.position.y, region.size.x, region.size.y))
		if material != _spray_material:
			material.set_shader_parameter("swe_enabled", active)
	if _spray != null:
		_spray.visible = active
		_spray.emitting = active


func _build_spray() -> void:
	var emitters: Array[Vector4] = []
	for rock in field.obstacles:
		var point := Vector2(rock.x, rock.y) + Vector2(0.0, rock.z * 1.08)
		if emitters.size() < 13:
			emitters.append(Vector4(point.x, point.y, rock.z * 0.25, 0.0))
	_spray_material = ShaderMaterial.new()
	_spray_material.shader = load("res://shaders/river/river_splash.gdshader")
	_spray_material.set_shader_parameter("emitters", emitters)
	_spray_material.set_shader_parameter("emitter_count", emitters.size())
	_spray_material.set_shader_parameter("gravity_m_s2", Solver.GRAVITY_M_S2)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.78, 0.84, 0.82)
	material.roughness = 0.35
	var droplet := SphereMesh.new()
	droplet.radius = 0.014
	droplet.height = 0.028
	droplet.radial_segments = 8
	droplet.rings = 3
	droplet.material = material
	_spray = GPUParticles3D.new()
	_spray.name = "RockSplashes"
	_spray.amount = 1536
	_spray.lifetime = 0.65
	_spray.fixed_fps = 60
	_spray.use_fixed_seed = true
	_spray.seed = 41927
	_spray.local_coords = false
	_spray.visibility_aabb = AABB(Vector3(-field.domain_m.x * 0.5, -3.0, -field.domain_m.y * 0.5), Vector3(field.domain_m.x, 12.0, field.domain_m.y))
	_spray.process_material = _spray_material
	_spray.draw_pass_1 = droplet
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spray.visible = false
	_spray.emitting = false
	add_child(_spray)
