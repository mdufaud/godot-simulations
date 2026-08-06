class_name DestructionConfig extends Resource

@export_range(12, 1000, 1) var chunk_count: int = 100
@export_range(0.0, 1.0, 0.01) var fracture_bias: float = 0.6
@export_range(-100.0, 0.0, 0.1) var despawn_y_m: float = -12.0
@export_range(1.0, 100.0, 0.1) var projectile_despawn_y_m: float = -12.0


func validate() -> String:
	if chunk_count < 12:
		return "chunk_count must be at least 12"
	if fracture_bias < 0.0 or fracture_bias > 1.0:
		return "fracture_bias must be within 0..1"
	if despawn_y_m >= 0.0 or projectile_despawn_y_m >= 0.0:
		return "despawn heights must be below zero"
	return ""
