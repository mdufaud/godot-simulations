class_name BarrelDebris extends RefCounted

const PLATE_COUNT := 9
const PLATE_ARC_MIN_RAD := 0.5
const PLATE_ARC_MAX_RAD := 1.0
const PLATE_HEIGHT_MIN_M := 0.2
const PLATE_HEIGHT_MAX_M := 0.4
const PLATE_SEGMENTS := 4
const LID_THICKNESS_M := 0.03
const MASS_KG := 0.8
const MAX_SPEED_MPS := 14.0
const MIN_SPEED_SHARE := 0.4
const SPIN_MAX_RAD_S := 8.0
const LIFE_MIN_S := 3.0
const LIFE_MAX_S := 5.0
const SHRINK_S := 0.5
## Own layer, so fragments hit the world but never pile into each other.
const FRAGMENT_LAYER := 1 << 7
const WORLD_MASK := 1

static var _material: StandardMaterial3D


static func spawn(parent: Node, barrel: Transform3D, blast_speed_mps: float, rng: RandomNumberGenerator) -> void:
	for i in PLATE_COUNT:
		var angle := TAU * (float(i) + rng.randf_range(-0.3, 0.3)) / float(PLATE_COUNT)
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var height := rng.randf_range(PLATE_HEIGHT_MIN_M, PLATE_HEIGHT_MAX_M)
		var arc := rng.randf_range(PLATE_ARC_MIN_RAD, PLATE_ARC_MAX_RAD)
		var offset := radial * _plate_centre_m(arc) + Vector3.UP * rng.randf_range(-0.2, 0.2)
		var local := Transform3D(Basis(Vector3.UP, -angle), offset)
		_throw(parent, _plate_mesh(arc, height), barrel * local, barrel.basis * radial, blast_speed_mps, rng)
	for sign_y in [-1.0, 1.0]:
		var mesh := CylinderMesh.new()
		mesh.top_radius = ExplosiveBarrel.RADIUS_M
		mesh.bottom_radius = ExplosiveBarrel.RADIUS_M
		mesh.height = LID_THICKNESS_M
		mesh.material = _fragment_material()
		var local := Transform3D(Basis.IDENTITY, Vector3.UP * sign_y * ExplosiveBarrel.HEIGHT_M * 0.5)
		_throw(parent, mesh, barrel * local, barrel.basis * Vector3.UP * sign_y, blast_speed_mps, rng)


static func _throw(parent: Node, mesh: Mesh, xform: Transform3D, direction: Vector3,
		blast_speed_mps: float, rng: RandomNumberGenerator) -> void:
	var body := RigidBody3D.new()
	body.mass = MASS_KG
	body.continuous_cd = true
	body.collision_layer = FRAGMENT_LAYER
	body.collision_mask = WORLD_MASK
	var bounds := mesh.get_aabb()
	var shape := BoxShape3D.new()
	shape.size = bounds.size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = bounds.get_center()
	body.add_child(collision)
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	body.add_child(visual)
	parent.add_child(body)
	body.global_transform = xform
	var heading := (direction + Vector3.UP * ExplosiveBarrel.UPWARD_BIAS).normalized()
	var speed := minf(blast_speed_mps * rng.randf_range(MIN_SPEED_SHARE, 1.0), MAX_SPEED_MPS)
	body.linear_velocity = heading * speed
	body.angular_velocity = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0),
		rng.randf_range(-1.0, 1.0)) * SPIN_MAX_RAD_S
	var life_s := rng.randf_range(LIFE_MIN_S, LIFE_MAX_S)
	var tween := body.create_tween()
	tween.tween_interval(life_s)
	tween.tween_property(visual, "scale", Vector3.ONE * 0.01, SHRINK_S)
	tween.finished.connect(body.queue_free)


static func _plate_centre_m(arc_rad: float) -> float:
	return ExplosiveBarrel.RADIUS_M * sin(arc_rad * 0.5) / (arc_rad * 0.5)


static func _plate_mesh(arc_rad: float, height_m: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := ExplosiveBarrel.RADIUS_M
	var centre_x := _plate_centre_m(arc_rad)
	for s in PLATE_SEGMENTS:
		var a0 := lerpf(-arc_rad * 0.5, arc_rad * 0.5, float(s) / float(PLATE_SEGMENTS))
		var a1 := lerpf(-arc_rad * 0.5, arc_rad * 0.5, float(s + 1) / float(PLATE_SEGMENTS))
		var p00 := Vector3(cos(a0) * radius - centre_x, -height_m * 0.5, sin(a0) * radius)
		var p01 := Vector3(cos(a0) * radius - centre_x, height_m * 0.5, sin(a0) * radius)
		var p10 := Vector3(cos(a1) * radius - centre_x, -height_m * 0.5, sin(a1) * radius)
		var p11 := Vector3(cos(a1) * radius - centre_x, height_m * 0.5, sin(a1) * radius)
		for tri: Array in [[p00, p10, p01, a0, a1, a0], [p01, p10, p11, a0, a1, a1]]:
			for k in 3:
				var a: float = tri[3 + k]
				surface.set_normal(Vector3(cos(a), 0.0, sin(a)))
				surface.add_vertex(tri[k])
	var mesh := surface.commit()
	mesh.surface_set_material(0, _fragment_material())
	return mesh


static func _fragment_material() -> StandardMaterial3D:
	if _material == null:
		_material = ExplosiveBarrel._paint_material().duplicate() as StandardMaterial3D
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _material
