class_name PlanetConfig extends Resource

@export_range(16, 512, 1) var resolution: int = 128
@export_range(8.0, 30.0, 0.1) var radius_m: float = 23.0
@export_range(0.1, 2.0, 0.01) var triangle_budget_per_cell: float = 20.0
@export_range(1, 64, 1) var max_layers: int = 8


func validate() -> String:
	if resolution < 8 or radius_m <= 0.0:
		return "resolution and radius_m are invalid"
	if triangle_budget_per_cell <= 0.0 or max_layers <= 0:
		return "planet generation budgets must be positive"
	return ""
