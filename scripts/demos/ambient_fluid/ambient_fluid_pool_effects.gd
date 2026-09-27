extends Node3D

const FOAM_SHADER := preload("res://shaders/ambient_fluid/pool_foam.gdshader")
const PARTICLE_SHADER := preload("res://shaders/ambient_fluid/pool_particle.gdshader")

var _foam_material: ShaderMaterial
var _foam_shader: Shader
var _particle_material: ShaderMaterial
var _particle_shader: Shader
var _body_effects: Dictionary = {}
var _effects_enabled := true


func configure() -> void:
	_foam_shader = FOAM_SHADER
	_particle_shader = PARTICLE_SHADER
	_foam_material = ShaderMaterial.new()
	_foam_material.shader = _foam_shader
	_particle_material = ShaderMaterial.new()
	_particle_material.shader = _particle_shader
	reset_effects()


func set_liquid_effects_enabled(enabled: bool) -> void:
	if _effects_enabled == enabled:
		return
	_effects_enabled = enabled
	reset_effects()


func reset_effects() -> void:
	for value in _body_effects.values():
		var effect: Dictionary = value
		var foam := effect.foam as Node3D
		var particles := effect.particles as GPUParticles3D
		if is_instance_valid(foam):
			foam.queue_free()
		if is_instance_valid(particles):
			particles.queue_free()
	_body_effects.clear()


func update_bodies(bodies: Array[AmbientFluidBody3D]) -> void:
	if not _effects_enabled:
		return
	var now := Time.get_ticks_msec() * 0.001
	var active_bodies := {}
	for body: AmbientFluidBody3D in bodies:
		if not is_instance_valid(body) or not body.pool_buoyancy_enabled \
				or body.pool_buoyancy_faces_local.is_empty():
			continue
		var instance_id := body.get_instance_id()
		active_bodies[instance_id] = true
		var effect: Dictionary = _body_effects.get(instance_id, {})
		if effect.is_empty():
			effect = _create_body_effect()
			_body_effects[instance_id] = effect
		var previous_fraction: float = effect.previous_fraction
		var current_fraction := body.submerged_fraction
		_update_foam(effect, body, now)
		if previous_fraction < 0.02 and current_fraction >= 0.02 \
				and body.linear_velocity.length() > 0.6:
			_spawn_splash(effect, body, now)
		effect.previous_fraction = current_fraction
		_body_effects[instance_id] = effect
	for instance_id in _body_effects.keys():
		if active_bodies.has(instance_id):
			continue
		var stale_effect: Dictionary = _body_effects[instance_id]
		(stale_effect.foam as Node3D).queue_free()
		(stale_effect.particles as GPUParticles3D).queue_free()
		_body_effects.erase(instance_id)


func _create_body_effect() -> Dictionary:
	var ring_mesh := ImmediateMesh.new()
	var ring_instance := MeshInstance3D.new()
	ring_instance.name = "WaterlineFoam"
	ring_instance.mesh = ring_mesh
	var ring_material := _foam_material.duplicate() as ShaderMaterial
	ring_instance.material_override = ring_material
	add_child(ring_instance)
	var particles := GPUParticles3D.new()
	particles.name = "SplashParticles"
	particles.amount = 28
	particles.lifetime = 0.9
	particles.explosiveness = 1.0
	particles.one_shot = true
	particles.emitting = false
	particles.local_coords = false
	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3.UP
	process_material.spread = 42.0
	process_material.initial_velocity_min = 0.8
	process_material.initial_velocity_max = 3.4
	process_material.gravity = Vector3(0.0, -4.0, 0.0)
	process_material.scale_min = 0.035
	process_material.scale_max = 0.105
	particles.process_material = process_material
	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)
	var particle_material := _particle_material.duplicate() as ShaderMaterial
	quad.material = particle_material
	particles.draw_pass_1 = quad
	add_child(particles)
	return {
		foam = ring_instance,
		particles = particles,
		previous_fraction = 0.0,
		last_splash = -INF,
	}


func _update_foam(effect: Dictionary, body: AmbientFluidBody3D, _now: float) -> void:
	var foam := effect.foam as MeshInstance3D
	var mesh := foam.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var points: PackedVector3Array = body.waterline_points_local
	if points.size() < 3:
		foam.visible = false
		return
	var opacity := clampf((body.linear_velocity.length() - 0.2) * 0.14, 0.0, 0.55)
	foam.visible = opacity > 0.02
	if not foam.visible:
		return
	(foam.material_override as ShaderMaterial).set_shader_parameter("foam_opacity", opacity)
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in points.size():
		var start := body.global_transform * points[index]
		var finish := body.global_transform * points[(index + 1) % points.size()]
		start.y = body.pool_surface_height_world + 0.012
		finish.y = body.pool_surface_height_world + 0.012
		var tangent := finish - start
		if tangent.length_squared() <= 1.0e-10:
			continue
		var side := Vector3.UP.cross(tangent.normalized()).normalized() * 0.025
		var a := start - side
		var b := start + side
		var c := finish + side
		var d := finish - side
		mesh.surface_add_vertex(a)
		mesh.surface_add_vertex(b)
		mesh.surface_add_vertex(c)
		mesh.surface_add_vertex(a)
		mesh.surface_add_vertex(c)
		mesh.surface_add_vertex(d)
	mesh.surface_end()


func _spawn_splash(effect: Dictionary, body: AmbientFluidBody3D, now: float) -> void:
	if now - float(effect.last_splash) < 0.15:
		return
	var particles := effect.particles as GPUParticles3D
	particles.global_position = Vector3(body.global_position.x,
		body.pool_surface_height_world + 0.015, body.global_position.z)
	particles.emitting = true
	particles.restart()
	effect.last_splash = now
