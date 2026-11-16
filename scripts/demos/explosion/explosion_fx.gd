class_name ExplosionFx extends Node3D

const RING_SHADER := preload("res://shaders/explosion/shock_ring.gdshader")
const Sparks := preload("res://scripts/demos/explosion/explosion_sparks.gd")
const FLASH_COLOR := Color(1.0, 0.72, 0.4)
const FLASH_BASE_S := 0.3
const FLASH_PER_M_S := 0.01
const FLASH_RANGE_GAIN := 1.5
## A huge charge lights the ground around it, not the whole plain, and only briefly.
const FLASH_MAX_RANGE_M := 1800.0
const FLASH_MAX_S := 4.0
const SPARK_BARREL_RADIUS_M := 1.2
const SPARK_MAX_SPEED_MPS := 28.0

static var _ring_mesh: SphereMesh
static var _ring_material: ShaderMaterial


var system: ExplosionSystem
var _scenery: ExplosionScenery
var _hearth: OmniLight3D


## Wires the effects to [param source]; [param hearth] is the light that follows each detonation.
func attach(source: ExplosionSystem, hearth: OmniLight3D, scenery: ExplosionScenery) -> void:
	system = source
	_scenery = scenery
	_hearth = hearth
	source.detonated.connect(on_detonated)


func on_detonated(origin: Vector3, charge: ExplosionCharge, carry_velocity: Vector3) -> void:
	_hearth.position = origin
	_flash(origin, charge)
	_ring(origin, charge)
	_sparks(origin, charge, carry_velocity)


func clear() -> void:
	for child in get_children():
		child.queue_free()


func _flash(origin: Vector3, charge: ExplosionCharge) -> void:
	if charge.flash_energy <= 0.0:
		return
	var light := OmniLight3D.new()
	light.light_color = FLASH_COLOR
	light.light_energy = charge.flash_energy
	light.omni_range = minf(charge.blast_radius_m * FLASH_RANGE_GAIN, FLASH_MAX_RANGE_M)
	light.position = origin
	add_child(light)
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, minf(FLASH_BASE_S + FLASH_PER_M_S * charge.blast_radius_m, FLASH_MAX_S)) \
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


func _sparks(origin: Vector3, charge: ExplosionCharge, carry_velocity: Vector3) -> void:
	var size := clampf(charge.radius_m / SPARK_BARREL_RADIUS_M, 0.5, 20.0)
	var speed_mps := clampf(system.blast_speed_mps(charge) * 1.2, 6.0, SPARK_MAX_SPEED_MPS)
	Sparks.burst(self, origin, size, speed_mps, charge.radius_m * 0.3,
		_scenery.ground_height_m(), carry_velocity)


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
