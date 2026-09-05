class_name OceanBuoy
extends RigidBody3D
## Floating crate riding the FFT ocean. The controller submits the crate's
## four corner probes (plus every other crate and the camera) as GPU point
## queries against the rendered surface and hands the results back here:
## buoyancy and righting torque from the probe depths, downhill push from the
## sampled surface normal. No CPU wave sampling anywhere.

const PROBES: Array[Vector3] = [
	Vector3(-0.45, 0.0, -0.45), Vector3(0.45, 0.0, -0.45),
	Vector3(-0.45, 0.0, 0.45), Vector3(0.45, 0.0, 0.45),
]
const BUOYANCY := 32.0
const MAX_DEPTH := 1.4
## The old CPU path pushed along the finite-difference slope over a 4 m
## baseline; the query normal encodes the same gradient, so the force keeps
## the original span (SLOPE_PUSH x 4 m) for identical ride behaviour.
const SLOPE_PUSH := 1.2
const SLOPE_BASELINE_M := 4.0


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


## One frame of query results for this crate: one depth (water height minus
## probe y, <= 0 = dry) per corner probe and the averaged surface normal.
func apply_water_frame(probe_depths: PackedFloat32Array, surface_normal: Vector3) -> void:
	if probe_depths.size() < PROBES.size():
		return
	var submerged := 0
	for i in PROBES.size():
		var depth: float = probe_depths[i]
		if depth <= 0.0:
			continue
		submerged += 1
		var p := global_transform * PROBES[i]
		apply_force(
			Vector3.UP * mass * BUOYANCY * clampf(depth, 0.0, MAX_DEPTH) / PROBES.size(),
			p - global_position
		)
	if submerged > 0:
		var slope := Vector2(
			surface_normal.x / maxf(surface_normal.y, 0.25),
			surface_normal.z / maxf(surface_normal.y, 0.25))
		apply_central_force(Vector3(-slope.x, 0.0, -slope.y)
			* (mass * SLOPE_PUSH * SLOPE_BASELINE_M))
		linear_damp = 1.4
		angular_damp = 1.6
	else:
		linear_damp = 0.05
		angular_damp = 0.05
