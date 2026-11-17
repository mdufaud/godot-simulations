extends RefCounted

const SHADER := preload("res://shaders/explosion/dust_puff.gdshader")
const AMOUNT := 56
const LIFE_S := 0.7
const DAMPING := 6.0
const REACH_PER_BLAST := 1.2
const RISE_MPS2 := 0.8
const PUFF_PER_BLAST := 0.45
const LIFT_PER_BLAST := 0.12
const GROWTH := 2.2
const START_ALPHA := 0.8

static var _material: ShaderMaterial
static var _mesh: QuadMesh
static var _ramp: GradientTexture1D
static var _growth: CurveTexture


## Self-freeing radial burst of soft dust puffs thrown out along the ground, strongly damped so it settles at the blast radius.
static func burst(parent: Node3D, origin: Vector3, charge: ExplosionCharge) -> void:
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	material.emission_ring_axis = Vector3.UP
	material.emission_ring_radius = maxf(charge.radius_m, 0.3)
	material.emission_ring_inner_radius = 0.0
	material.emission_ring_height = 0.0
	material.direction = Vector3.ZERO
	material.spread = 0.0
	var speed_mps := REACH_PER_BLAST * charge.blast_radius_m * DAMPING
	material.radial_velocity_min = 0.35 * speed_mps
	material.radial_velocity_max = speed_mps
	material.damping_min = DAMPING * 0.8
	material.damping_max = DAMPING * 1.2
	material.gravity = Vector3(0.0, RISE_MPS2, 0.0)
	material.scale_min = PUFF_PER_BLAST * charge.blast_radius_m * 0.6
	material.scale_max = PUFF_PER_BLAST * charge.blast_radius_m
	material.scale_curve = _shared_growth()
	material.lifetime_randomness = 0.3
	material.color_ramp = _shared_ramp()
	var particles := GPUParticles3D.new()
	particles.process_material = material
	particles.draw_pass_1 = _shared_mesh()
	particles.amount = AMOUNT
	particles.lifetime = LIFE_S
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.fixed_fps = 60
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var extent_m := REACH_PER_BLAST * charge.blast_radius_m * 1.5 + 1.0
	particles.visibility_aabb = AABB(Vector3(-extent_m, -1.0, -extent_m), Vector3(2.0 * extent_m, 2.0 * extent_m, 2.0 * extent_m))
	particles.position = origin + Vector3(0.0, LIFT_PER_BLAST * charge.blast_radius_m, 0.0)
	parent.add_child(particles)
	particles.emitting = true
	particles.create_tween().tween_interval(LIFE_S * 1.4 + 0.2).finished.connect(particles.queue_free)


static func _shared_mesh() -> QuadMesh:
	if _mesh == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		_mesh = QuadMesh.new()
		_mesh.size = Vector2.ONE
		_mesh.material = _material
	return _mesh


static func _shared_ramp() -> GradientTexture1D:
	if _ramp == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.12, 1.0])
		gradient.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, START_ALPHA), Color(1, 1, 1, 0.0)])
		_ramp = GradientTexture1D.new()
		_ramp.gradient = gradient
	return _ramp


static func _shared_growth() -> CurveTexture:
	if _growth == null:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 1.0 / GROWTH))
		curve.add_point(Vector2(1.0, 1.0))
		_growth = CurveTexture.new()
		_growth.curve = curve
	return _growth
