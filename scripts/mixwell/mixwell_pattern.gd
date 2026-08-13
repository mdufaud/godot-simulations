class_name MixwellPattern
extends RefCounted

const Operation := preload("res://scripts/mixwell/mixwell_operation.gd")

var id := -1
var name := ""
var operations: Array = []
var source_metadata := {}


func set_operations(values: Array) -> void:
	operations.clear()
	for value in values:
		if value is Operation:
			operations.append(value.duplicate_operation())
		elif value is Dictionary:
			var operation = Operation.new()
			operation.set_from_dictionary(value)
			operations.append(operation)


func to_render_operations() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for operation in operations:
		result.append(operation.to_dictionary())
	return result


func physical_operations() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(operations.size() - 1, -1, -1):
		result.append(operations[index].to_dictionary())
	return result


func render_operations(operation_limit := -1) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var active_count := operations.size() if operation_limit < 0 else mini(operation_limit,
			operations.size())
	for index in range(active_count - 1, -1, -1):
		var operation = operations[index]
		var value: Dictionary = operation.to_transformed_dictionary()
		if operation.points.size() < 2:
			result.append(value)
			continue
		var first_point: int = operation.points.size() - 1
		var last_point: int = 1
		if operation.periodic_segment_count > 0:
			last_point = maxi(first_point - operation.periodic_segment_count + 1, 1)
		for point_index in range(first_point, last_point - 1, -1):
			var start: Vector2 = value.points[point_index - 1]
			var end: Vector2 = value.points[point_index]
			var segment := value.duplicate(true)
			segment["type"] = 2
			segment["segment"] = Vector4(start.x, start.y, end.x, end.y)
			segment["points"] = []
			segment["curve_index"] = point_index - 1
			segment["curve_group"] = index
			result.append(segment)
	return result


func operation_count() -> int:
	return operations.size()


func serialize() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"source": source_metadata.duplicate(true),
		"operations": to_render_operations(),
	}
