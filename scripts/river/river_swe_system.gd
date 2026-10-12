extends Node3D

const Solver := preload("res://scripts/river/river_swe_solver.gd")

signal state_changed

var config: RiverConfig
var field: RiverField
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
var _impulse := Vector4.ZERO


func start() -> void:
	if not available:
		state_changed.emit()
		return
	_build_spray()
	solver.start(field, config)


static func surface_mesh(base: PlaneMesh) -> Mesh:
	var steps := Vector2i(base.subdivide_width + 1, base.subdivide_depth + 1)
	if maxf(base.size.x / steps.x, base.size.y / steps.y) <= Solver.CELL_M:
		return base
	var x := _surface_axis(base.size.x, steps.x, Solver.REGION_M.position.x, Solver.REGION_M.end.x)
	var z := _surface_axis(base.size.y, steps.y, Solver.REGION_M.position.y, Solver.REGION_M.end.y)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	vertices.resize(x.size() * z.size())
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	for row in z.size():
		for column in x.size():
			var index := row * x.size() + column
			vertices[index] = Vector3(x[column], 0.0, z[row])
			if row < z.size() - 1 and column < x.size() - 1:
				indices.append_array(PackedInt32Array([index, index + x.size(), index + 1,
					index + 1, index + x.size(), index + x.size() + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _surface_axis(extent_m: float, steps: int, low_m: float, high_m: float) -> PackedFloat32Array:
	var points := PackedFloat32Array()
	for index in steps + 1:
		var point := -extent_m * 0.5 + index * extent_m / steps
		if point < low_m or point > high_m:
			points.append(point)
	for index in roundi((high_m - low_m) / Solver.CELL_M) + 1:
		points.append(low_m + index * Solver.CELL_M)
	points.sort()
	return points


func set_enabled(value: bool) -> void:
	enabled = value
	reset()
	_bind()
	state_changed.emit()


func reset() -> void:
	_reset = true
	_impulse = Vector4.ZERO
	if _spray != null:
		_spray.restart(true)


func disturb() -> void:
	_impulse = Vector4(2.0, 4.0, 1.2, 1.5)


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
	if enabled and (step_s > 0.0 or _reset):
		RenderingServer.call_on_render_thread(solver.advance_render.bind(step_s,
			solver.parameters(config, time_s, _impulse), _reset, profiling))
		_reset = false
		_impulse = Vector4.ZERO


func gpu_ms() -> float:
	return float(solver.snapshot().get("gpu_ms", 0.0)) if enabled else 0.0


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
	var active := enabled and initialized
	var region := Solver.REGION_M
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
		if Solver.REGION_M.grow(-2.0).has_point(point):
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
	_spray.visibility_aabb = AABB(Vector3(-8.0, -3.0, -9.0), Vector3(20.0, 12.0, 28.0))
	_spray.process_material = _spray_material
	_spray.draw_pass_1 = droplet
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spray.visible = false
	_spray.emitting = false
	add_child(_spray)
