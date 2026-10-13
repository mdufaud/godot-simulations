extends RigidBody3D

const PROBES := [Vector3(-0.25, 0.0, -0.25), Vector3(0.25, 0.0, -0.25),
	Vector3(-0.25, 0.0, 0.25), Vector3(0.25, 0.0, 0.25)]

@export var size_m := Vector3(0.7, 0.7, 0.7)
@export var body_density_kg_m3 := 350.0
@export var water_density_kg_m3 := 1000.0
@export var drag_coefficient := 0.8

var _samples := PackedVector4Array()
var last_support_force_n := Vector3.ZERO


func _ready() -> void:
	mass = body_density_kg_m3 * size_m.x * size_m.y * size_m.z
	can_sleep = false
	continuous_cd = true
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size_m
	mesh.mesh = box
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.42, 0.25, 0.12)
	wood.roughness = 0.85
	mesh.material_override = wood
	add_child(mesh)
	var shape := CollisionShape3D.new()
	var collision := BoxShape3D.new()
	collision.size = size_m
	shape.shape = collision
	add_child(shape)


func set_water_samples(samples: PackedVector4Array) -> void:
	_samples = samples


func probe_positions() -> PackedVector3Array:
	var result := PackedVector3Array()
	for probe: Vector3 in PROBES:
		result.append(global_transform * (probe * size_m / Vector3(0.7, 0.7, 0.7)))
	return result


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	last_support_force_n = Vector3.ZERO
	if _samples.size() != PROBES.size():
		return
	var area := size_m.x * size_m.z / PROBES.size()
	var vertical_span := absf(state.transform.basis.x.y) * size_m.x + absf(state.transform.basis.y.y) * size_m.y + absf(state.transform.basis.z.y) * size_m.z
	for index in PROBES.size():
		var sample := _samples[index]
		if sample.w <= 0.015:
			continue
		var offset: Vector3 = state.transform.basis * (PROBES[index] * size_m / Vector3(0.7, 0.7, 0.7))
		var fraction := clampf((sample.x - state.transform.origin.y - offset.y) / vertical_span + 0.5, 0.0, 1.0)
		var immersion := fraction * size_m.y
		if immersion <= 0.0:
			continue
		var buoyancy := -state.total_gravity * water_density_kg_m3 * area * immersion
		last_support_force_n += buoyancy
		state.apply_force(buoyancy, offset)
		var relative := state.linear_velocity + state.angular_velocity.cross(offset) - Vector3(sample.y, 0.0, sample.z)
		var gain := 0.5 * water_density_kg_m3 * drag_coefficient * area * immersion / size_m.y * relative.length()
		state.apply_force(-relative * gain / (1.0 + gain * state.step * PROBES.size() / mass), offset)
