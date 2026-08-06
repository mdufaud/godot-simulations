class_name SandConfig extends Resource

@export_range(16, 2048, 1) var grid_size: int = 512
@export_range(0.1, 100.0, 0.1) var world_size_m: float = 4.0
@export_range(1.0, 89.0, 0.1) var repose_angle_deg: float = 33.0
@export_range(0.001, 10.0, 0.001) var flow_rate: float = 0.11
@export_range(1, 64, 1) var flow_iterations: int = 10


func validate() -> String:
	if grid_size <= 0 or world_size_m <= 0.0:
		return "grid_size and world_size_m must be positive"
	if repose_angle_deg <= 0.0 or repose_angle_deg >= 90.0:
		return "repose_angle_deg must be between 0 and 90"
	if flow_rate <= 0.0 or flow_iterations <= 0:
		return "flow_rate and flow_iterations must be positive"
	return ""
