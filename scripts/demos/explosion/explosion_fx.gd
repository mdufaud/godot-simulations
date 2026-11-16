class_name ExplosionFx extends Node3D

const RING_SHADER := preload("res://shaders/explosion/shock_ring.gdshader")
const FLASH_COLOR := Color(1.0, 0.72, 0.4)
const FLASH_BASE_S := 0.3
const FLASH_PER_M_S := 0.01
const FLASH_RANGE_GAIN := 1.5
const SPARK_GRAVITY := Vector3(0.0, -9.8, 0.0)
const SPARK_BARREL_RADIUS_M := 1.2
const SPARK_MIN_AMOUNT := 60
const SPARK_MAX_AMOUNT := 300
const SPARK_MAX_SPEED_MPS := 80.0

static var _ring_mesh: SphereMesh
static var _ring_material: ShaderMaterial
static var _spark_mesh: QuadMesh
static var _spark_material: StandardMaterial3D
static var _spark_ramp: GradientTexture1D


var system: ExplosionSystem
var _hearth: OmniLight3D


## Wires the effects to [param source]; [param hearth] is the light that follows each detonation.
func attach(source: ExplosionSystem, hearth: OmniLight3D) -> void:
	system = source
	_hearth = hearth
	source.detonated.connect(on_detonated)


func on_detonated(origin: Vector3, charge: ExplosionCharge) -> void:
	_hearth.position = origin
	_flash(origin, charge)
	_ring(origin, charge)
	_sparks(origin, charge)


func clear() -> void:
	for child in get_children():
		child.queue_free()


func _flash(origin: Vector3, charge: ExplosionCharge) -> void:
	if charge.flash_energy <= 0.0:
		return
	var light := OmniLight3D.new()
	light.light_color = FLASH_COLOR
	light.light_energy = charge.flash_energy
	light.omni_range = charge.blast_radius_m * FLASH_RANGE_GAIN
	light.position = origin
	add_child(light)
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, FLASH_BASE_S + FLASH_PER_M_S * charge.blast_radius_m) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.finished.connect(light.queue_free)


## The shell grows at the real blast speed from the charge radius to the blast radius.
func _ring(origin: Vector3, charge: ExplosionCharge) -> void:
	var span_m := charge.blast_radius_m - charge.radius_m
	var speed_mps := system.blast_speed_mps(charge)
	if speed_mps <= 0.0 or span_m <= 0.0:
		return
	var ring := MeshInstance3D.new()
	ring.mesh = _shared_ring_mesh()
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = origin
	ring.scale = Vector3.ONE * charge.radius_m
	add_child(ring)
	var tween := ring.create_tween()
	tween.tween_method(_step_ring.bind(ring, charge.radius_m, charge.blast_radius_m), 0.0, 1.0,
		span_m / speed_mps)
	tween.finished.connect(ring.queue_free)


func _step_ring(t: float, ring: MeshInstance3D, from_m: float, to_m: float) -> void:
	ring.scale = Vector3.ONE * lerpf(from_m, to_m, t)
	ring.set_instance_shader_parameter("progress", t)


func _sparks(origin: Vector3, charge: ExplosionCharge) -> void:
	var size := clampf(charge.radius_m / SPARK_BARREL_RADIUS_M, 0.5, 20.0)
	var speed_mps := clampf(system.blast_speed_mps(charge) * 1.2, 6.0, SPARK_MAX_SPEED_MPS)
	var life_s := 0.9 * sqrt(size)
	var material := ParticleProcessMaterial.new()
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	material.emission_sphere_radius = charge.radius_m * 0.3
	material.direction = Vector3.UP
	material.spread = 100.0
	material.initial_velocity_min = speed_mps * 0.35
	material.initial_velocity_max = speed_mps
	material.gravity = SPARK_GRAVITY
	material.damping_min = 0.3
	material.damping_max = 1.0
	material.scale_min = 0.6 * size
	material.scale_max = 1.4 * size
	material.color_ramp = _shared_spark_ramp()
	material.particle_flag_align_y = true
	var particles := GPUParticles3D.new()
	particles.process_material = material
	particles.draw_pass_1 = _shared_spark_mesh()
	particles.amount = clampi(int(SPARK_MIN_AMOUNT + 25.0 * size), SPARK_MIN_AMOUNT, SPARK_MAX_AMOUNT)
	particles.lifetime = life_s
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.fixed_fps = 0
	particles.local_coords = false
	var reach_m := speed_mps * life_s * 1.2
	particles.visibility_aabb = AABB(Vector3.ONE * -reach_m, Vector3.ONE * 2.0 * reach_m)
	particles.position = origin
	add_child(particles)
	particles.emitting = true
	particles.finished.connect(particles.queue_free)


static func _shared_ring_mesh() -> SphereMesh:
	if _ring_mesh == null:
		_ring_material = ShaderMaterial.new()
		_ring_material.shader = RING_SHADER
		_ring_mesh = SphereMesh.new()
		_ring_mesh.radius = 1.0
		_ring_mesh.height = 2.0
		_ring_mesh.radial_segments = 48
		_ring_mesh.rings = 24
		_ring_mesh.material = _ring_material
	return _ring_mesh


static func _shared_spark_mesh() -> QuadMesh:
	if _spark_mesh == null:
		_spark_material = StandardMaterial3D.new()
		_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_spark_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_spark_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_spark_material.billboard_keep_scale = true
		_spark_material.vertex_color_use_as_albedo = true
		_spark_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_spark_mesh = QuadMesh.new()
		_spark_mesh.size = Vector2(0.03, 0.3)
		_spark_mesh.material = _spark_material
	return _spark_mesh


static func _shared_spark_ramp() -> GradientTexture1D:
	if _spark_ramp == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
		gradient.colors = PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.45, 0.1, 1.0),
			Color(0.25, 0.04, 0.02, 0.0)])
		_spark_ramp = GradientTexture1D.new()
		_spark_ramp.gradient = gradient
	return _spark_ramp
