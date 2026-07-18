class_name GravityField3D
extends Area3D

enum Mode { CONSTANT, RADIAL_OUTWARD }

@export var mode := Mode.CONSTANT
@export var gravity_strength := 12.0
@export var direction := Vector3.DOWN


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func sample_gravity(world_position: Vector3) -> Vector3:
	if mode == Mode.RADIAL_OUTWARD:
		var radial := world_position - global_position
		if radial.length_squared() > 0.000001:
			return radial.normalized() * gravity_strength
	return direction.normalized() * gravity_strength


func _on_body_entered(body: Node3D) -> void:
	if body.has_method("set_gravity_field"):
		body.set_gravity_field(self)


func _on_body_exited(body: Node3D) -> void:
	if body.has_method("clear_gravity_field"):
		body.clear_gravity_field(self)
