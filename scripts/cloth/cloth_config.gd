class_name ClothConfig extends Resource

@export_range(8, 512, 1) var grid_width: int = 96
@export_range(8, 512, 1) var grid_height: int = 72
@export_range(0.001, 1.0, 0.001) var rest_spacing_m: float = 0.06
@export_range(1, 64, 1) var iterations: int = 14
@export_range(1, 32, 1) var substeps: int = 4
@export var gravity_mps2 := Vector3(0.0, -9.8, 0.0)
@export_range(0.0, 1.0, 0.001) var damping: float = 0.995
@export_range(0.0, 10.0, 0.01) var drag: float = 0.9


func validate() -> String:
	if grid_width < 2 or grid_height < 2:
		return "cloth grid must have at least two vertices per axis"
	if rest_spacing_m <= 0.0 or iterations <= 0 or substeps <= 0:
		return "rest_spacing_m, iterations and substeps must be positive"
	if damping < 0.0 or damping > 1.0 or drag < 0.0:
		return "damping or drag is invalid"
	return ""
