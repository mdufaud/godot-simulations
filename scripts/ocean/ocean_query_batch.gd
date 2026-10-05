class_name OceanQueryBatch
extends RefCounted

var id: int = 0
var revision: int = 0
var simulation_time_s: float = 0.0
var points := PackedVector2Array()
var results := PackedVector4Array()
var velocities := PackedVector3Array()
