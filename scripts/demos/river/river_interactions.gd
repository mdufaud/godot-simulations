extends Node3D

const Body := preload("res://scripts/river/river_buoyant_body.gd")
const MAX_CRATES := 8

var river: RiverSystem
var camera: Camera3D
var crates: Array[RigidBody3D] = []
var _slots: Array[WeakRef] = []
var _pending := false


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
	for body in crates:
		body.queue_free()
	crates.clear()
	_slots.clear()


func _physics_process(_delta: float) -> void:
	if _pending:
		var batch := river.take_query_batch()
		if not batch.is_empty():
			_pending = false
			var values: PackedFloat32Array = batch.values
			for slot in _slots.size():
				var body: RigidBody3D = _slots[slot].get_ref()
				if not is_instance_valid(body):
					continue
				var samples := PackedVector4Array()
				for index in Body.PROBES.size():
					var offset := (slot * Body.PROBES.size() + index) * 4
					samples.append(Vector4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]))
				body.set_water_samples(samples)
	var points := PackedVector2Array()
	var slots: Array[WeakRef] = []
	for body in crates:
		body.freeze = river.frozen
		for point in body.probe_positions():
			points.append(Vector2(point.x, point.z))
		slots.append(weakref(body))
	if not _pending and river.submit_queries(points):
		_slots = slots
		_pending = true
