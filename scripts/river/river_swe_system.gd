extends Node3D

const Solver := preload("res://scripts/river/river_swe_solver.gd")
const WINDOW_SNAP_M := 4.0
const BLEND_RATE_HZ := 1.0
const WARMUP_S := 0.5
const WET_PROBE_M := 2.0

signal state_changed

var config: RiverConfig
var field: RiverField
var camera: Camera3D
var window_m := Vector2.ZERO
var range_m := 0.0
var region_m := Rect2()
var cell_m := Solver.CELL_M
var blend := 1.0
var active: bool:
	get: return enabled and initialized
var live: bool:
	get: return active and _running
var materials: Array[ShaderMaterial] = []
var available := false
## A spilling field always runs live: its falls are drawn from the particles this solver runs.
var enabled := true:
	set(value):
		enabled = value or (field != null and field.spills)
var profiling := false
var initialized := false
var solver := Solver.new()
var surface_texture := Texture2DRD.new()
var foam_texture := Texture2DRD.new()
var terrain_texture := Texture2DRD.new()
var spill_texture := Texture2DRD.new()
var corners_texture := Texture2DRD.new()
var _spray: GPUParticles3D
var _spray_material: ShaderMaterial
var _reset := true
var _running := true
var _warmup_s := 0.0
var _probe_region := Rect2()
var _wet_points := PackedVector2Array()
var _submitted_region := Rect2()


func start() -> void:
	if not available:
		state_changed.emit()
		return
	solver.cell_m = cell_m
	solver.grid = grid_for(window_m if _windowed() else field.domain_m, cell_m)
	region_m = _region()
	solver.region_m = region_m
	if not field.obstacles.is_empty():
		_build_spray()
	solver.start(field, config)


func move_domain() -> void:
	if not available:
		return
	solver.move_source(field)
	_probe_region = Rect2()


static func grid_for(size_m: Vector2, cell_m: float) -> Vector2i:
	return Vector2i((size_m / cell_m).ceil())


func _windowed() -> bool:
	return window_m != Vector2.ZERO and not field.spills


func _region() -> Rect2:
	var size := Vector2(solver.grid) * cell_m
	var domain := field.domain_rect()
	if not _windowed():
		return Rect2(domain.position, size)
	var center := _focus().snapped(Vector2.ONE * WINDOW_SNAP_M)
	var corner := (center - size * 0.5).clamp(domain.position, domain.end - size)
	return Rect2((corner / cell_m).round() * cell_m, size)


func _focus() -> Vector2:
	if camera == null:
		return field.origin_m
	var eye := camera.global_position
	var direction := -camera.global_basis.z
	var height := field.sample_height(Vector2(eye.x, eye.z), config.water_level_m)
	var reach := clampf((height - eye.y) / minf(direction.y, -0.05), 0.0, minf(window_m.x, window_m.y) * 0.25)
	var target := eye + direction * reach
	return Vector2(target.x, target.z)


func _update_lod(frame_s: float) -> void:
	var region := _region()
	if region != region_m:
		region_m = region
		solver.region_m = region
		_bind()
	var near := range_m <= 0.0 or field.spills or _water_within_range()
	if near and not _running:
		_running = true
		_reset = true
		_warmup_s = WARMUP_S
		_bind()
	_warmup_s = maxf(_warmup_s - frame_s, 0.0)
	var next := move_toward(blend, 1.0 if near and _warmup_s <= 0.0 else 0.0, frame_s * BLEND_RATE_HZ)
	if next != blend:
		blend = next
		for material in materials:
			material.set_shader_parameter("swe_blend", blend)
	if blend <= 0.0 and not near and _running:
		_running = false
		_bind()


func _water_within_range() -> bool:
	if camera == null:
		return true
	if _probe_region != region_m:
		_probe_region = region_m
		_wet_points.clear()
		for y in range(ceili(region_m.size.y / WET_PROBE_M)):
			for x in range(ceili(region_m.size.x / WET_PROBE_M)):
				var point := region_m.position + (Vector2(x, y) + Vector2.ONE * 0.5) * WET_PROBE_M
				if field.sample(point, config.water_level_m).a > 0.5:
					_wet_points.append(point)
	var eye := Vector2(camera.global_position.x, camera.global_position.z)
	for point in _wet_points:
		if eye.distance_to(point) <= range_m:
			return true
	return false


func add_obstacles(meshes: Array[MeshInstance3D], time_s: float) -> void:
	if available and not _windowed():
		solver.add_obstacles(field, meshes, solver.parameters(config, time_s))


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
		spill_texture.texture_rd_rid = status.spill
		corners_texture.texture_rd_rid = status.corners
		_bind()
		state_changed.emit()
	if not initialized:
		return
	if active:
		_update_lod(frame_s)
	if _spray != null:
		_spray.speed_scale = step_s / maxf(frame_s, 0.0001)
		_spray_material.set_shader_parameter("strength", config.whitewater_strength * config.foam_amount)
	if live and (step_s > 0.0 or _reset or region_m != _submitted_region):
		RenderingServer.call_on_render_thread(solver.advance_render.bind(step_s,
			solver.parameters(config, time_s), _reset, profiling))
		_reset = false
		_submitted_region = region_m


func gpu_ms() -> float:
	return float(solver.snapshot().get("gpu_ms", 0.0)) if active else 0.0


func cpu_ms() -> float:
	return float(solver.snapshot().get("cpu_ms", 0.0)) if active else 0.0


func stop() -> void:
	initialized = false
	for material in materials:
		material.set_shader_parameter("swe_enabled", false)
		material.set_shader_parameter("swe_spill_enabled", false)
		for parameter: String in ["swe_surface", "swe_foam", "swe_terrain", "swe_spill", "swe_corners"]:
			material.set_shader_parameter(parameter, null)
	if _spray_material != null:
		for parameter: String in ["swe_surface", "swe_foam", "swe_terrain", "swe_spill"]:
			_spray_material.set_shader_parameter(parameter, null)
	surface_texture.texture_rd_rid = RID()
	foam_texture.texture_rd_rid = RID()
	terrain_texture.texture_rd_rid = RID()
	spill_texture.texture_rd_rid = RID()
	corners_texture.texture_rd_rid = RID()
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
		material.set_shader_parameter("swe_spill", spill_texture)
		material.set_shader_parameter("swe_corners", corners_texture)
		material.set_shader_parameter("swe_spill_enabled", field.spills and active)
		material.set_shader_parameter("swe_region_m", Vector4(region.position.x, region.position.y, region.size.x, region.size.y))
		if material != _spray_material:
			material.set_shader_parameter("swe_enabled", active)
			material.set_shader_parameter("swe_blend", blend)
	if _spray != null:
		_spray.visible = live
		_spray.emitting = live


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
	_spray.visibility_aabb = AABB(Vector3(field.domain_rect().position.x, -3.0, field.domain_rect().position.y), Vector3(field.domain_m.x, 12.0, field.domain_m.y))
	_spray.process_material = _spray_material
	_spray.draw_pass_1 = droplet
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spray.visible = false
	_spray.emitting = false
	add_child(_spray)
