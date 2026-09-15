class_name CellPropagationConfig extends Resource
## Coarse gameplay fire-spread grid (Far Cry 2 model): cells hold hitpoints that
## fire damage drains, then burn for a finite fuel lifetime per material, while
## a global pool of spreading points caps how far the fire may run.
## See docs/game_fire_rdr2_model.md.

@export var grid_size: Vector2i = Vector2i(32, 32)
@export_range(0.1, 10.0, 0.1) var cell_size_m: float = 1.5

## Indexed by material id (CellPropagation.MATERIAL_*).
@export var material_hitpoints: Array[float] = [60.0, 220.0, 1.0e12]
## Seconds a cell keeps burning once ignited; 0 burns out on the next step.
@export var material_burn_seconds: Array[float] = [7.0, 30.0, 0.0]
## Hitpoints per second a burning cell deals to each orthogonal neighbour
## before wind scaling.
@export var material_burn_power: Array[float] = [14.0, 30.0, 0.0]
## How strongly the wind biases damage: multiplier ranges from
## 1 + wind_damage_gain downwind to the upwind floor upwind.
@export_range(0.0, 4.0, 0.05) var wind_damage_gain: float = 1.5
## Minimum fraction of burn power a neighbour still takes against the wind.
@export_range(0.0, 1.0, 0.05) var upwind_floor: float = 0.15
## Every spread ignition spends one point; an empty pool stops the spread
## short of consuming the whole map (Far Cry 2 "spreading points").
@export_range(1, 100000, 1) var spreading_points: int = 900


func validate() -> String:
	if grid_size.x < 2 or grid_size.y < 2:
		return "grid_size must be at least 2x2"
	if cell_size_m <= 0.0:
		return "cell_size_m must be positive"
	if material_hitpoints.is_empty() or material_burn_seconds.is_empty() \
			or material_burn_power.is_empty():
		return "material tables must not be empty"
	if material_hitpoints.size() != material_burn_seconds.size() \
			or material_hitpoints.size() != material_burn_power.size():
		return "material tables must share one length"
	return ""
