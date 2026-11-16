extends RefCounted

const TRAIL_SHADER := preload("res://shaders/explosion/spark_trail.gdshader")
const GRAVITY := Vector3(0.0, -9.8, 0.0)
const BIG_AMOUNT_MIN := 6
const BIG_AMOUNT_MAX := 28
const SMALL_AMOUNT_MIN := 30
const SMALL_AMOUNT_MAX := 150
const BREAK_AMOUNT := 5
const BIG_LIFE_S := 2.2
const SMALL_LIFE_S := 1.0
const BREAK_LIFE_S := 0.45
const TRAIL_LIFE_S := 0.09
const TRAIL_SECTIONS := 8
const BOUNCE := 0.38
const FRICTION := 0.55
const HDR_GAIN := 2.5
const COLLIDER_DEPTH_M := 10.0
const REACH_MARGIN := 1.2

static var _material: ShaderMaterial
static var _ramp: GradientTexture1D
static var _meshes: Dictionary = {}


## Spawns a self-freeing burst of trailed sparks: many small short ones and a few large long-lived embers that break up.
static func burst(parent: Node3D, origin: Vector3, size: float, speed_mps: float, emit_radius_m: float,
		ground_m: float, carry_velocity := Vector3.ZERO) -> void:
	var root := Node3D.new()
	root.position = origin
	parent.add_child(root)
	var life_scale := sqrt(size)
	var big_amount := clampi(int(BIG_AMOUNT_MIN + 1.2 * size), BIG_AMOUNT_MIN, BIG_AMOUNT_MAX)
	var small_amount := clampi(int(SMALL_AMOUNT_MIN + 6.0 * size), SMALL_AMOUNT_MIN, SMALL_AMOUNT_MAX)
	var small := _emitter("Small", small_amount, SMALL_LIFE_S * life_scale, 0.028, speed_mps, 0.3, 1.0,
		emit_radius_m, life_scale)
	var big := _emitter("Big", big_amount, BIG_LIFE_S * life_scale, 0.06, speed_mps * 0.6, 0.25, 0.8,
		emit_radius_m, life_scale)
	var pieces := _emitter("Break", big_amount * BREAK_AMOUNT, BREAK_LIFE_S * life_scale, 0.01, speed_mps * 0.25,
		0.2, 1.0, 0.0, life_scale)
	_lean(small.process_material, carry_velocity, speed_mps)
	_lean(big.process_material, carry_velocity, speed_mps)
	var big_material := big.process_material as ParticleProcessMaterial
	big_material.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_END
	big_material.sub_emitter_amount_at_end = BREAK_AMOUNT
	big_material.sub_emitter_keep_velocity = true
	pieces.one_shot = false
	for node: GPUParticles3D in [small, big, pieces]:
		root.add_child(node)
	big.sub_emitter = NodePath("../Break")
	root.add_child(_ground(Vector2(root.global_position.x, root.global_position.z), ground_m,
			burst_reach_m(speed_mps, life_scale)))
	big.emitting = true
	small.emitting = true
	var total_s := (BIG_LIFE_S + BREAK_LIFE_S) * life_scale + TRAIL_LIFE_S + 0.5
	root.create_tween().tween_interval(total_s).finished.connect(root.queue_free)


static func reach_m(speed_mps: float, life_s: float) -> float:
	return speed_mps * life_s * REACH_MARGIN + 1.0


static func burst_reach_m(speed_mps: float, life_scale: float) -> float:
	var small := reach_m(speed_mps, SMALL_LIFE_S * life_scale)
	var big := reach_m(speed_mps * 0.6, BIG_LIFE_S * life_scale)
	return maxf(small, big + reach_m(speed_mps * 0.25, BREAK_LIFE_S * life_scale))


static func _lean(material: ParticleProcessMaterial, carry_velocity: Vector3, speed_mps: float) -> void:
	var horizontal := Vector3(carry_velocity.x, 0.0, carry_velocity.z)
	if horizontal.length() < 0.5:
		return
	var share := clampf(horizontal.length() / speed_mps, 0.0, 1.0)
	material.direction = (Vector3.UP * 0.5 + horizontal.normalized() * (0.5 + share)).normalized()
	material.spread = lerpf(100.0, 50.0, share)


static func _emitter(node_name: String, amount: int, life_s: float, radius_m: float, speed_mps: float,
		min_ratio: float, max_ratio: float, emit_radius_m: float, scale: float) -> GPUParticles3D:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	material.emission_sphere_radius = maxf(emit_radius_m, 0.001)
	material.direction = Vector3.UP
	material.spread = 100.0
	material.initial_velocity_min = speed_mps * min_ratio
	material.initial_velocity_max = speed_mps * max_ratio
	material.gravity = GRAVITY
	material.damping_min = 0.2
	material.damping_max = 0.6
	material.scale_min = 0.7 * scale
	material.scale_max = 1.3 * scale
	material.lifetime_randomness = 0.4
	material.color_ramp = _shared_ramp()
	material.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	material.collision_bounce = BOUNCE
	material.collision_friction = FRICTION
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.process_material = material
	particles.draw_pass_1 = _shared_mesh(radius_m)
	particles.amount = amount
	particles.lifetime = life_s
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.fixed_fps = 60
	particles.local_coords = false
	particles.trail_enabled = true
	particles.trail_lifetime = TRAIL_LIFE_S
	particles.emitting = false
	var extent_m := reach_m(speed_mps, life_s)
	particles.visibility_aabb = AABB(Vector3.ONE * -extent_m, Vector3.ONE * 2.0 * extent_m)
	return particles


static func _ground(centre_m: Vector2, ground_m: float, reach: float) -> GPUParticlesCollisionBox3D:
	var collider := GPUParticlesCollisionBox3D.new()
	collider.size = Vector3(2.0 * reach, COLLIDER_DEPTH_M, 2.0 * reach)
	collider.top_level = true
	collider.position = Vector3(centre_m.x, ground_m - 0.5 * COLLIDER_DEPTH_M, centre_m.y)
	return collider


static func _shared_mesh(radius_m: float) -> TubeTrailMesh:
	if not _meshes.has(radius_m):
		if _material == null:
			_material = ShaderMaterial.new()
			_material.shader = TRAIL_SHADER
			_material.set_shader_parameter("gain", HDR_GAIN)
		var taper := Curve.new()
		taper.add_point(Vector2(0.0, 1.0))
		taper.add_point(Vector2(1.0, 0.0))
		var mesh := TubeTrailMesh.new()
		mesh.radius = radius_m
		mesh.radial_steps = 4
		mesh.sections = TRAIL_SECTIONS
		mesh.section_rings = 1
		mesh.curve = taper
		mesh.material = _material
		_meshes[radius_m] = mesh
	return _meshes[radius_m]


static func _shared_ramp() -> GradientTexture1D:
	if _ramp == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.18, 0.45, 0.75, 1.0])
		gradient.colors = PackedColorArray([Color(8.0, 7.2, 4.8), Color(7.0, 3.6, 1.0), Color(3.0, 0.9, 0.12),
			Color(0.9, 0.1, 0.02), Color(0.12, 0.01, 0.005)])
		_ramp = GradientTexture1D.new()
		_ramp.gradient = gradient
		_ramp.use_hdr = true
	return _ramp
