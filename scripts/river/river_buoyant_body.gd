extends RigidBody3D

const PROBES := [Vector3(-0.25, 0.0, -0.25), Vector3(0.25, 0.0, -0.25),
	Vector3(-0.25, 0.0, 0.25), Vector3(0.25, 0.0, 0.25)]

@export var size_m := Vector3(0.7, 0.7, 0.7)
@export var body_density_kg_m3 := 350.0
@export var water_density_kg_m3 := 1000.0
@export var drag_coefficient := 0.8

var _samples := PackedVector4Array()
var _contacts := PackedFloat32Array()
var _contact_field: RiverField
var water_level_m := 0.06
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
	_contacts.clear()
	_contact_field = null


func set_water_contacts(samples: PackedFloat32Array, field: RiverField) -> void:
	_samples.clear()
	_contacts = samples
	_contact_field = field


func probe_positions() -> PackedVector3Array:
	var result := PackedVector3Array()
	for probe: Vector3 in PROBES:
		result.append(global_transform * (probe * size_m / Vector3(0.7, 0.7, 0.7)))
	return result


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	last_support_force_n = Vector3.ZERO
	if _contact_field != null and _contact_field.waterfall != null:
		_integrate_waterfall_contacts(state)
		return
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


func _integrate_waterfall_contacts(state: PhysicsDirectBodyState3D) -> void:
	if _contacts.size() != PROBES.size() * 12:
		return
	var area := size_m.x * size_m.z / PROBES.size()
	var vertical_span := absf(state.transform.basis.x.y) * size_m.x \
		+ absf(state.transform.basis.y.y) * size_m.y + absf(state.transform.basis.z.y) * size_m.z
	for index in PROBES.size():
		var base := index * 12
		var kind := roundi(_contacts[base + 7])
		if kind == 0:
			continue
		var surface := Vector3(_contacts[base], _contacts[base + 1], _contacts[base + 2])
		var depth := maxf(_contacts[base + 3], 0.0)
		var velocity := Vector3(_contacts[base + 4], _contacts[base + 5], _contacts[base + 6])
		var normal := Vector3(_contacts[base + 8], _contacts[base + 9], _contacts[base + 10]).normalized()
		if normal.length_squared() < 0.5:
			continue
		var offset: Vector3 = state.transform.basis * (PROBES[index] * size_m / Vector3(0.7, 0.7, 0.7))
		var point := state.transform.origin + offset
		var normal_extent := _half_extent(state.transform.basis, normal)
		var distance := (point - surface).dot(normal)
		if not _contact_is_current(kind, point, surface, normal, distance, depth, normal_extent,
				state.transform.basis):
			continue
		var relative := state.linear_velocity + state.angular_velocity.cross(offset) - velocity
		var immersion := 0.0
		if kind == 1 or kind == 2:
			if kind == 1:
				var fraction := clampf((_contacts[base + 1] - point.y) / vertical_span + 0.5, 0.0, 1.0)
				immersion = fraction * size_m.y
			else:
				immersion = maxf(minf(distance + normal_extent, 0.0) - maxf(distance - normal_extent, -depth), 0.0)
			if immersion <= 0.0:
				continue
			var support_acceleration := maxf(-state.total_gravity.dot(normal), 0.0)
			var support := normal * water_density_kg_m3 * area * immersion * support_acceleration
			last_support_force_n += support
			state.apply_force(support, offset)
			if kind == 2:
				relative -= normal * relative.dot(normal)
		else:
			immersion = minf(maxf(depth * 0.5 + normal_extent - absf(distance), 0.0), depth)
			if immersion <= 0.0:
				continue
		var drag_span := depth if kind == 1 else normal_extent * 2.0
		var gain := 0.5 * water_density_kg_m3 * drag_coefficient * area \
			* immersion / maxf(drag_span, 0.01) * relative.length()
		state.apply_force(-relative * gain / (1.0 + gain * state.step * PROBES.size() / mass), offset)


func _contact_is_current(kind: int, point: Vector3, surface: Vector3, normal: Vector3,
		distance: float, depth: float, normal_extent: float, basis: Basis) -> bool:
	var field := _contact_field
	var config: RiverWaterfallConfig = field.waterfall
	var xz := Vector2(point.x, point.z)
	if kind == 1:
		if not Rect2(-field.domain_m * 0.5, field.domain_m).has_point(xz):
			return false
		var receiver_run := 0.125 if config.is_vertical() else maxf((config.height_m - 0.65 - water_level_m) / tan(deg_to_rad(config.angle_degrees)), 0.125)
		if point.z < config.crest_z_m and point.z > config.crest_z_m - receiver_run:
			return false
		var reference_y := water_level_m + (config.height_m if point.z >= config.crest_z_m else 0.0)
		if absf(surface.y - reference_y) > config.height_m * 0.5 \
				or Vector2(surface.x - point.x, surface.z - point.z).length() > maxf(size_m.x, size_m.z) + 0.5:
			return false
		return true
	if kind == 2:
		var projected := point - normal * (distance + depth)
		return not config.is_vertical() and field.water_zone(Vector2(projected.x, projected.z)) == 3 \
			and distance + normal_extent >= -depth and distance - normal_extent <= 0.0 \
			and projected.z >= config.crest_z_m - config.run_m() and projected.z <= config.crest_z_m \
			and absf(point.x) <= config.width_m * 0.5 + _half_extent(basis, Vector3.RIGHT)
	if kind != 3:
		return false
	if config.is_vertical():
		var half_width := _half_extent(basis, Vector3.RIGHT)
		var low := water_level_m
		var high := water_level_m + config.height_m
		return absf(point.x) <= config.width_m * 0.5 + half_width \
			and point.y >= low - normal_extent and point.y <= high + normal_extent \
			and point.z <= config.crest_z_m + normal_extent \
			and absf(point.y - surface.y) <= size_m.length() \
			and absf(distance) <= depth * 0.5 + normal_extent
	return false


func _half_extent(basis: Basis, axis: Vector3) -> float:
	return absf(basis.x.normalized().dot(axis)) * size_m.x * 0.5 \
		+ absf(basis.y.normalized().dot(axis)) * size_m.y * 0.5 \
		+ absf(basis.z.normalized().dot(axis)) * size_m.z * 0.5
