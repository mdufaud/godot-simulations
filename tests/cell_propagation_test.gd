extends "res://tests/test_case.gd"
## CPU gates for the Far Cry 2-style spread grid. No scene, no GPU: runs under
## --headless in a couple of seconds.

const CellPropagationScript := preload("res://scripts/cellpropagation/cell_propagation.gd")
const CellPropagationConfigScript := preload("res://scripts/cellpropagation/cell_propagation_config.gd")

var _current_step := 0
var _ignited_steps := {}
var _burned_cells: Array[Vector2i] = []


func _initialize() -> void:
	_test_config_validation()
	_test_symmetric_front()
	_test_wind_bias()
	_test_fuel_burnout()
	_test_budget_cap()
	_test_inert_cells_stop_fire()
	_finish("cell_propagation")


func _make_config(size: int, points: int) -> CellPropagationConfig:
	var config: CellPropagationConfig = CellPropagationConfigScript.new()
	config.grid_size = Vector2i(size, size)
	config.cell_size_m = 1.0
	config.material_hitpoints = [10.0, 220.0, 1.0e12]
	config.material_burn_seconds = [2.0, 30.0, 0.0]
	config.material_burn_power = [30.0, 30.0, 0.0]
	config.spreading_points = points
	return config


func _watch(grid: CellPropagation) -> void:
	_ignited_steps = {}
	_burned_cells = []
	grid.cell_ignited.connect(func(cell: Vector2i) -> void:
		_ignited_steps[cell] = _current_step)
	grid.cell_burned_out.connect(func(cell: Vector2i) -> void:
		_burned_cells.append(cell))


func _run(grid: CellPropagation, steps: int, wind := Vector2.ZERO) -> void:
	for index in steps:
		_current_step = index
		grid.step(0.1, wind)


func _test_config_validation() -> void:
	var config := CellPropagationConfig.new()
	_check(config.validate().is_empty(), "defaults validate")
	config.grid_size = Vector2i(1, 8)
	_check(not config.validate().is_empty(), "tiny grid rejected")
	config = CellPropagationConfig.new()
	config.material_burn_seconds = [1.0]
	_check(not config.validate().is_empty(), "mismatched material tables rejected")


func _test_symmetric_front() -> void:
	var config := _make_config(11, 10000)
	var grid: CellPropagation = CellPropagationScript.new()
	grid.setup(config, Vector3.ZERO, 7)
	_watch(grid)
	_check(grid.ignite_at(Vector3(5.5, 0.0, 5.5), 100.0), "center ignited")
	_run(grid, 30)
	for distance in [1, 2]:
		var reference: int = _ignited_steps.get(Vector2i(5 + distance, 5), -1)
		_check(reference >= 0, "front reached +x at d=%d" % distance)
		for cell in [Vector2i(5 - distance, 5), Vector2i(5, 5 + distance),
				Vector2i(5, 5 - distance)]:
			var reached: int = _ignited_steps.get(cell, -1)
			_check(absi(reached - reference) <= 1,
				"front symmetric at d=%d (%s: %d vs %d)" % [distance, cell, reached, reference])


func _test_wind_bias() -> void:
	var config := _make_config(9, 10000)
	var grid: CellPropagation = CellPropagationScript.new()
	grid.setup(config, Vector3.ZERO, 11)
	_watch(grid)
	grid.ignite_at(Vector3(4.5, 0.0, 4.5), 100.0)
	_run(grid, 40, Vector2(1.0, 0.0))
	var downwind: int = _ignited_steps.get(Vector2i(6, 4), -1)
	var upwind: int = _ignited_steps.get(Vector2i(2, 4), -1)
	_check(downwind >= 0, "downwind cell ignited")
	_check(upwind < 0 or downwind < upwind,
		"front advanced downwind (downwind %s vs upwind %s)" % [downwind, upwind])


func _test_fuel_burnout() -> void:
	var config := _make_config(3, 100)
	var grid: CellPropagation = CellPropagationScript.new()
	grid.setup(config, Vector3.ZERO, 3)
	_watch(grid)
	for x in 3:
		for z in 3:
			if x != 1 or z != 1:
				grid.set_cell_material(Vector2i(x, z), CellPropagation.MATERIAL_NONE)
	var center := Vector3(1.5, 0.0, 1.5)
	_check(grid.ignite_at(center, 100.0), "isolated cell ignited")
	_run(grid, 15)
	_check(grid.is_burning(Vector2i(1, 1)), "cell still burning at 1.5 s")
	_check(_burned_cells.is_empty(), "nothing burned out early")
	_run(grid, 15)
	_check(grid.state_of(Vector2i(1, 1)) == CellPropagation.STATE_BURNED,
		"fuel exhausted burns out")
	_check(grid.burning_count() == 0, "no burning left")
	_check(_burned_cells.size() == 1 and _burned_cells[0] == Vector2i(1, 1),
		"one burnout signal")
	_check(not grid.ignite_at(center, 100.0), "burned cell refuses re-ignition")


func _test_budget_cap() -> void:
	var config := _make_config(21, 5)
	var grid: CellPropagation = CellPropagationScript.new()
	grid.setup(config, Vector3.ZERO, 5)
	_watch(grid)
	grid.ignite_at(Vector3(10.5, 0.0, 10.5), 100.0)
	_run(grid, 120)
	_check(grid.points_left == 0, "budget drained")
	_check(grid.burned_count() == 6,
		"budget capped the fire at 6 cells (got %d)" % grid.burned_count())
	_check(grid.burning_count() == 0, "fire died out")
	_check(grid.burned_count() < config.grid_size.x * config.grid_size.y, "fuel remains")


func _test_inert_cells_stop_fire() -> void:
	var config := _make_config(5, 100)
	var grid: CellPropagation = CellPropagationScript.new()
	grid.setup(config, Vector3.ZERO, 9)
	_watch(grid)
	for x in 5:
		for z in 5:
			if x == 0 or z == 0 or x == 4 or z == 4:
				grid.set_cell_material(Vector2i(x, z), CellPropagation.MATERIAL_NONE)
	_check(grid.ignite_at(Vector3(2.5, 0.0, 2.5), 100.0), "interior ignited")
	_run(grid, 100)
	_check(grid.burned_count() == 9,
		"fire consumed the interior 3x3 (got %d)" % grid.burned_count())
	for cell in [Vector2i(0, 2), Vector2i(2, 0), Vector2i(4, 2), Vector2i(2, 4)]:
		_check(grid.state_of(cell) == CellPropagation.STATE_INTACT,
			"inert border cell untouched at %s" % cell)
	_check(not grid.ignite_at(Vector3(0.5, 0.0, 2.5), 100.0), "inert cell refuses ignition")
