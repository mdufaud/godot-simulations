class_name FluidConfig extends Resource

@export_range(1024, 1048576, 1024) var default_particle_count: int = 65536
@export var particle_counts: Array[int] = [16384, 32768, 65536]
@export_range(0.01, 100.0, 0.01) var flow_min: float = 0.5
@export_range(0.01, 100.0, 0.01) var flow_max: float = 10.0
@export_range(0.01, 100.0, 0.01) var default_flow: float = 1.0
@export var grid_dims: Vector3i = Vector3i(64, 64, 64)
@export var grid_origin: Vector3 = Vector3(-8.0, 0.0, -8.0)
@export_range(0.001, 10.0, 0.001) var cell_size_m: float = 0.25
@export_range(1, 4096, 1) var texture_width: int = 256
@export var domain_origin: Vector3 = Vector3(-8.0, 0.0, -8.0)
@export var domain_size_m: Vector3 = Vector3(16.0, 16.0, 16.0)


func validate() -> String:
	if default_particle_count <= 0:
		return "default_particle_count must be positive"
	if particle_counts.is_empty():
		return "particle_counts must not be empty"
	if flow_min <= 0.0 or flow_max < flow_min:
		return "flow range is invalid"
	if default_flow < flow_min or default_flow > flow_max:
		return "default_flow must be inside flow range"
	if grid_dims.x <= 0 or grid_dims.y <= 0 or grid_dims.z <= 0:
		return "grid_dims must be positive"
	if cell_size_m <= 0.0 or texture_width <= 0:
		return "cell_size_m and texture_width must be positive"
	if domain_size_m.x <= 0.0 or domain_size_m.y <= 0.0 or domain_size_m.z <= 0.0:
		return "domain_size_m must be positive"
	return ""
