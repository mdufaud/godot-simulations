class_name FireConfig extends Resource

@export var dense_grid_dims: Vector3i = Vector3i(64, 96, 64)
@export_range(0.01, 10.0, 0.01) var cell_size_m: float = 0.2
@export_range(1, 1048576, 1) var water_particle_count: int = 16384
@export_range(0.0, 10.0, 0.01) var liquid_drain_rate_per_s: float = 0.2


func validate() -> String:
	if dense_grid_dims.x <= 0 or dense_grid_dims.y <= 0 or dense_grid_dims.z <= 0:
		return "dense_grid_dims must be positive"
	if cell_size_m <= 0.0:
		return "cell_size_m must be positive"
	if water_particle_count <= 0:
		return "water_particle_count must be positive"
	return ""


func sim_dims_cells() -> Vector3i:
	return FireTilePool.VTILES * FireTilePool.TILE


func dense_domain_size_m() -> Vector3:
	return Vector3(dense_grid_dims) * cell_size_m


func sparse_domain_size_m() -> Vector3:
	return Vector3(sim_dims_cells()) * cell_size_m
