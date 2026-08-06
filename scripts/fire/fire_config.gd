class_name FireConfig extends Resource

@export var dense_grid_dims: Vector3i = Vector3i(64, 96, 64)
@export_range(0.01, 10.0, 0.01) var cell_size_m: float = 0.2
@export var virtual_tile_dims: Vector3i = Vector3i(256, 64, 256)
@export var atlas_tile_dims: Vector3i = Vector3i(16, 8, 16)
@export_range(1, 64, 1) var tile_cells: int = 8
@export_range(1, 64, 1) var max_logs: int = 12
@export_range(1, 2048, 1) var pool_budget: int = 2048
@export_range(1, 1048576, 1) var water_particle_count: int = 16384
@export_range(0.0, 10.0, 0.01) var liquid_drain_rate_per_s: float = 0.2


func validate() -> String:
	if dense_grid_dims.x <= 0 or dense_grid_dims.y <= 0 or dense_grid_dims.z <= 0:
		return "dense_grid_dims must be positive"
	if cell_size_m <= 0.0 or tile_cells <= 0:
		return "cell_size_m and tile_cells must be positive"
	if virtual_tile_dims.x <= 0 or virtual_tile_dims.y <= 0 or virtual_tile_dims.z <= 0:
		return "virtual_tile_dims must be positive"
	if atlas_tile_dims.x <= 0 or atlas_tile_dims.y <= 0 or atlas_tile_dims.z <= 0:
		return "atlas_tile_dims must be positive"
	if max_logs <= 0 or pool_budget <= 0 or water_particle_count <= 0:
		return "fire budgets must be positive"
	return ""


func sim_dims_cells() -> Vector3i:
	return Vector3i(virtual_tile_dims.x * tile_cells, virtual_tile_dims.y * tile_cells,
		virtual_tile_dims.z * tile_cells)


func dense_domain_size_m() -> Vector3:
	return Vector3(dense_grid_dims) * cell_size_m


func sparse_domain_size_m() -> Vector3:
	return Vector3(sim_dims_cells()) * cell_size_m
