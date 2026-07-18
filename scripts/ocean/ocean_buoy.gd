class_name OceanBuoy
extends RigidBody3D
## Floating crate riding the FFT ocean. The water surface is GPU-only, so the
## controller hands over its CPU height sampler (cascade-0 async readback);
## four corner probes provide buoyancy and righting torque, and the local
## surface slope pushes the crate along so waves visibly carry it.

const PROBES: Array[Vector3] = [
	Vector3(-0.45, 0.0, -0.45), Vector3(0.45, 0.0, -0.45),
	Vector3(-0.45, 0.0, 0.45), Vector3(0.45, 0.0, 0.45),
]
const BUOYANCY := 32.0
const MAX_DEPTH := 1.4
const SLOPE_PUSH := 1.2

var height_sampler := Callable()


func _ready() -> void:
	mass = 30.0
	can_sleep = false
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	var mesh := MeshInstance3D.new()
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.36, 0.2)
	mat.roughness = 0.85
	mesh.material_override = mat
	add_child(mesh)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	add_child(shape)


func _physics_process(_delta: float) -> void:
	if not height_sampler.is_valid():
		return
	var submerged := 0
	for offset in PROBES:
		var p := global_transform * offset
		var depth: float = height_sampler.call(Vector2(p.x, p.z)) - p.y
		if depth <= 0.0:
			continue
		submerged += 1
		apply_force(
			Vector3.UP * mass * BUOYANCY * clampf(depth, 0.0, MAX_DEPTH) / PROBES.size(),
			p - global_position
		)
	if submerged > 0:
		var c := global_position
		var hx: float = height_sampler.call(Vector2(c.x + 2.0, c.z)) \
			- height_sampler.call(Vector2(c.x - 2.0, c.z))
		var hz: float = height_sampler.call(Vector2(c.x, c.z + 2.0)) \
			- height_sampler.call(Vector2(c.x, c.z - 2.0))
		apply_central_force(Vector3(-hx, 0.0, -hz) * (mass * SLOPE_PUSH))
		linear_damp = 1.4
		angular_damp = 1.6
	else:
		linear_damp = 0.05
		angular_damp = 0.05
