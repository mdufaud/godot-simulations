class_name ExplosiveBarrel extends RigidBody3D

const RADIUS_M := 0.3
const HEIGHT_M := 0.9
const MASS_KG := 40.0
const ARM_SPEED_MPS := 4.0
const FUSE_MIN_S := 0.2
const FUSE_MAX_S := 0.6
## Added to the blast direction so barrels are lifted instead of only slid.
const UPWARD_BIAS := 0.35

static var _paint: StandardMaterial3D
static var _band: StandardMaterial3D

var system: ExplosionSystem
var charge: ExplosionCharge
var rng := RandomNumberGenerator.new()
var armed := false
var detonated := false

var _fuse_left_s := 0.0


static func blast_speed_share(offset: Vector3, radius_m: float, speed_mps: float) -> float:
	return speed_mps * maxf(1.0 - offset.length() / radius_m, 0.0)


static func blast_impulse(offset: Vector3, radius_m: float, speed_mps: float, mass_kg: float) -> Vector3:
	var share := blast_speed_share(offset, radius_m, speed_mps)
	if share <= 0.0:
		return Vector3.ZERO
	var direction := offset.normalized() if offset.length() > 1e-3 else Vector3.BACK
	direction.y += UPWARD_BIAS
	return direction.normalized() * share * mass_kg


func _init() -> void:
	mass = MASS_KG
	continuous_cd = true
	var material := PhysicsMaterial.new()
	material.friction = 0.6
	material.bounce = 0.1
	physics_material_override = material
	var shape := CylinderShape3D.new()
	shape.radius = RADIUS_M
	shape.height = HEIGHT_M
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)
	add_child(_make_mesh(RADIUS_M, HEIGHT_M, 0.0, _paint_material()))
	for y in [-0.27, 0.27]:
		add_child(_make_mesh(RADIUS_M * 1.04, 0.07, y, _band_material()))


func _physics_process(delta: float) -> void:
	if not armed or detonated:
		return
	_fuse_left_s -= delta
	if _fuse_left_s <= 0.0:
		detonate()


func apply_blast(origin: Vector3, radius_m: float, speed_mps: float) -> void:
	if detonated:
		return
	var offset := global_position - origin
	apply_central_impulse(blast_impulse(offset, radius_m, speed_mps, mass))
	if not armed and blast_speed_share(offset, radius_m, speed_mps) >= ARM_SPEED_MPS:
		armed = true
		_fuse_left_s = rng.randf_range(FUSE_MIN_S, FUSE_MAX_S)


func detonate() -> void:
	if detonated:
		return
	detonated = true
	var origin := global_position
	origin.y = maxf(origin.y, charge.radius_m)
	system.detonate(origin, charge)
	BarrelDebris.spawn(get_parent(), global_transform, system.blast_speed_mps(charge), rng)
	queue_free()


static func _make_mesh(radius_m: float, height_m: float, y: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius_m
	mesh.bottom_radius = radius_m
	mesh.height = height_m
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position.y = y
	return instance


static func _paint_material() -> StandardMaterial3D:
	if _paint == null:
		_paint = StandardMaterial3D.new()
		_paint.albedo_color = Color(0.62, 0.07, 0.05)
		_paint.metallic = 0.55
		_paint.roughness = 0.42
	return _paint


static func _band_material() -> StandardMaterial3D:
	if _band == null:
		_band = StandardMaterial3D.new()
		_band.albedo_color = Color(0.3, 0.04, 0.03)
		_band.metallic = 0.7
		_band.roughness = 0.35
	return _band
