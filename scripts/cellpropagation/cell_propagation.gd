class_name CellPropagation extends RefCounted
## Coarse fire propagation on a 2D grid, after the Far Cry 2 model
## (J.-F. Levesque, "Far Cry: How the Fire Burns and Spreads", 2012).
##
## Every cell stores hitpoints; fire damage drains them and an empty tank
## ignites the cell. While burning, a cell deals burn power to its four
## orthogonal neighbours — scaled by dot(wind, direction) so the front advances
## downwind — and consumes a finite fuel lifetime before burning out. New
## spread ignitions spend a global pool of spreading points; an empty pool
## stops the fire short of consuming the whole map. Pure CPU, no scene
## dependencies: the host translates signals into VFX.
##
##     var grid := CellPropagation.new()
##     grid.setup(config, Vector3.ZERO, 12345)
##     grid.ignite_at(world_pos, 100.0)
##     grid.step(delta, wind_xz)

signal cell_ignited(cell: Vector2i)
signal cell_burned_out(cell: Vector2i)

enum { STATE_INTACT = 0, STATE_BURNING = 1, STATE_BURNED = 2 }
enum { MATERIAL_GRASS = 0, MATERIAL_WOOD = 1, MATERIAL_NONE = 2 }

const DIRECTIONS: Array[Vector2i] = [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

## Remaining spreading points. External sources top it up via
## [method ignite_at] `granted_points`.
var points_left := 0

var _config: CellPropagationConfig
var _origin := Vector3.ZERO
var _state := PackedByteArray()
var _hitpoints := PackedFloat32Array()
var _life := PackedFloat32Array()
var _material := PackedInt32Array()
var _burning_count := 0
var _burned_count := 0
var _rng := RandomNumberGenerator.new()


func setup(config: CellPropagationConfig, origin: Vector3, seed_value: int = -1) -> void:
	var error := config.validate()
	assert(error.is_empty(), "CellPropagation: %s" % error)
	_config = config
	_origin = origin
	points_left = config.spreading_points
	var count := config.grid_size.x * config.grid_size.y
	_state.resize(count)
	_hitpoints.resize(count)
	_life.resize(count)
	_material.resize(count)
	_material.fill(MATERIAL_GRASS)
	_hitpoints.fill(config.material_hitpoints[MATERIAL_GRASS])
	_burning_count = 0
	_burned_count = 0
	_rng.seed = seed_value if seed_value >= 0 else randi()


func step(delta: float, wind_xz: Vector2) -> void:
	var wind_norm := wind_xz.normalized() if wind_xz.length() > 0.001 else Vector2.ZERO
	var width := _config.grid_size.x
	for index in _state.size():
		if _state[index] != STATE_BURNING:
			continue
		_life[index] -= delta
		if _life[index] <= 0.0:
			_burn_out(index)
			continue
		var cell := Vector2i(index % width, index / width)
		var power: float = _config.material_burn_power[_material[index]]
		for direction in DIRECTIONS:
			var neighbour := cell + direction
			if not _in_bounds(neighbour):
				continue
			var facing := Vector2(direction)
			var scale := 1.0
			if wind_norm != Vector2.ZERO:
				scale = maxf(_config.upwind_floor,
					1.0 + _config.wind_damage_gain * wind_norm.dot(facing))
			_damage_cell(index_of(neighbour), power * scale * delta, true)


## Drains hitpoints at the cell under [param world_pos]. External sources are
## free; [param granted_points] tops the spread budget up (Far Cry 2: the
## Molotov carries its own points).
func ignite_at(world_pos: Vector3, damage: float, granted_points := 0) -> bool:
	var cell := world_to_cell(world_pos)
	if cell.x < 0:
		return false
	points_left += granted_points
	return _damage_cell(index_of(cell), damage, false)


func set_cell_material(cell: Vector2i, material: int) -> void:
	if not _in_bounds(cell):
		return
	var index := index_of(cell)
	_material[index] = material
	if _state[index] == STATE_INTACT:
		_hitpoints[index] = _config.material_hitpoints[material]


func state_of(cell: Vector2i) -> int:
	if not _in_bounds(cell):
		return STATE_BURNED
	return _state[index_of(cell)]


func is_burning(cell: Vector2i) -> bool:
	return state_of(cell) == STATE_BURNING


func burning_count() -> int:
	return _burning_count


func burned_count() -> int:
	return _burned_count


func world_to_cell(world_pos: Vector3) -> Vector2i:
	var local := Vector2(world_pos.x - _origin.x, world_pos.z - _origin.z) \
		/ _config.cell_size_m
	var cell := Vector2i(floori(local.x), floori(local.y))
	return cell if _in_bounds(cell) else Vector2i(-1, -1)


func cell_center(cell: Vector2i, ground_y := 0.0) -> Vector3:
	return Vector3(
		_origin.x + (float(cell.x) + 0.5) * _config.cell_size_m,
		ground_y,
		_origin.z + (float(cell.y) + 0.5) * _config.cell_size_m)


func index_of(cell: Vector2i) -> int:
	return cell.y * _config.grid_size.x + cell.x


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < _config.grid_size.x and cell.y < _config.grid_size.y


func _damage_cell(index: int, damage: float, from_spread: bool) -> bool:
	if _state[index] != STATE_INTACT:
		return false
	if _material[index] == MATERIAL_NONE:
		return false
	_hitpoints[index] -= damage
	if _hitpoints[index] > 0.0:
		return false
	if from_spread and points_left <= 0:
		# Out of spreading points: the fire stops growing but keeps burning
		# where it is. Hold the tank at zero so a later grant can ignite it.
		_hitpoints[index] = 0.0
		return false
	_state[index] = STATE_BURNING
	_burning_count += 1
	var seconds: float = _config.material_burn_seconds[_material[index]]
	_life[index] = seconds * _rng.randf_range(0.85, 1.15)
	if from_spread:
		points_left -= 1
	cell_ignited.emit(cell_of(index))
	return true


func _burn_out(index: int) -> void:
	_state[index] = STATE_BURNED
	_burning_count -= 1
	_burned_count += 1
	cell_burned_out.emit(cell_of(index))


func cell_of(index: int) -> Vector2i:
	return Vector2i(index % _config.grid_size.x, index / _config.grid_size.x)
