extends Node3D

const Body := preload("res://scripts/river/river_buoyant_body.gd")
const MAX_CRATES := 8

var river: RiverSystem
var camera: Camera3D
var crates: Array[RigidBody3D] = []
var _slots: Array[WeakRef] = []
var _pending := false
var _pending_body_query := false
var _pending_generation := -1
var _pending_field: RiverField


func throw_crate() -> void:
	var body := Body.new()
	add_child(body)
	var forward := -camera.global_basis.z
	body.global_position = camera.global_position + forward * 2.0
	body.linear_velocity = forward * 9.0 + Vector3.UP * 2.0
	body.angular_velocity = Vector3(0.7, 1.2, -0.6)
	body.freeze = river.frozen
	crates.append(body)
	if crates.size() > MAX_CRATES:
		crates.pop_front().queue_free()


func clear() -> void:
	if river != null:
		river.cancel_queries()
	for body in crates:
		body.queue_free()
	crates.clear()
	_reset_pending()


func _physics_process(_delta: float) -> void:
	if _pending and (_pending_generation != river.query_generation or _pending_field != river.field):
		_reset_pending()
	if _pending:
		var batch := river.take_query_batch()
		if not batch.is_empty():
			if int(batch.get("generation", -1)) == _pending_generation:
				var values: PackedFloat32Array = batch.values
				for slot in _slots.size():
					var body: RigidBody3D = _slots[slot].get_ref()
					if not is_instance_valid(body):
						continue
					if _pending_body_query and bool(batch.get("body", false)):
						var contacts := PackedFloat32Array()
						var offset := slot * Body.PROBES.size() * 12
						for value_index in Body.PROBES.size() * 12:
							contacts.append(values[offset + value_index])
						body.set_water_contacts(contacts, _pending_field)
					elif not _pending_body_query and not bool(batch.get("body", false)):
						var samples := PackedVector4Array()
						var offset := slot * Body.PROBES.size() * 4
						for index in Body.PROBES.size():
							var sample_offset := offset + index * 4
							samples.append(Vector4(values[sample_offset], values[sample_offset + 1], values[sample_offset + 2], values[sample_offset + 3]))
						body.set_water_samples(samples)
			_reset_pending()
	# Spilling fields keep pools at several heights over the same ground, so bodies query the water in 3D.
	var body_query := river.field.spills
	var body_points := PackedVector3Array()
	var points := PackedVector2Array()
	var slots: Array[WeakRef] = []
	for body in crates:
		body.freeze = river.frozen
		for point in body.probe_positions():
			if body_query:
				body_points.append(point)
			else:
				points.append(Vector2(point.x, point.z))
		slots.append(weakref(body))
	if not _pending:
		var submitted := river.submit_body_queries(body_points) if body_query else river.submit_queries(points)
		if submitted:
			_slots = slots
			_pending = true
			_pending_body_query = body_query
			_pending_generation = river.query_generation
			_pending_field = river.field


func _reset_pending() -> void:
	_pending = false
	_pending_body_query = false
	_pending_generation = -1
	_pending_field = null
	_slots.clear()
