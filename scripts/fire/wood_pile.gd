class_name WoodPile extends Node3D

const FUEL_INDEX_METHANE := WoodPyrolysis.FUEL_INDEX_METHANE
const LOG_MESH := preload("res://resources/fire/fire_log.res")
const BARK_MATERIAL := preload("res://resources/fire/fire_bark.tres")
const END_MATERIAL := preload("res://resources/fire/fire_endgrain.tres")
const COLOR_FRESH := Color(1.5, 0.95, 0.6)
const COLOR_CHAR := Color(0.75, 0.7, 0.66)
const STACK_SLOTS := [Vector2(-0.16, 0.0), Vector2(0.16, 0.0), Vector2(0.0, 0.16)]

var emit_radius := 0.45
## The solver's cell size, set by the controller. The injection kernel is
## normalized on the discrete falloff sum at this resolution, so the prescribed
## volatile flow lands in the gas whatever the grid.
var cell_size := 0.2
var log_fuel := 8.0
var _logs: Array[Dictionary] = []
var _stacked_log_count := 0
var _stack_base_top_y := 0.0
var _pyrolysis := WoodPyrolysis.new()
var _kernel_cache := -1.0
var _kernel_cache_key := Vector2.ZERO


func add_log(pos: Vector3, yaw: float, tilt := 0.0, radius := 0.09,
		length := 0.85) -> void:
	if _logs.size() >= FireGpuSolver.MAX_LOGS:
		return
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = LOG_MESH
	var material := BARK_MATERIAL.duplicate() as StandardMaterial3D
	var end_material := END_MATERIAL.duplicate() as StandardMaterial3D
	mesh_instance.set_surface_override_material(0, material)
	mesh_instance.set_surface_override_material(1, end_material)
	mesh_instance.transform = Transform3D(
		Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, PI * 0.5 + tilt), pos)
	mesh_instance.scale = Vector3(radius, length, radius)
	add_child(mesh_instance)
	var area := PI * radius * length + 2.0 * PI * radius * radius
	_logs.append({
		"node": mesh_instance, "mat": material, "end_mat": end_material,
		"pos": pos, "radius": radius,
		"length": length, "tilt": tilt, "area": area, "t_solid": 300.0,
		"t_char": 300.0, "m_volatile": log_fuel, "m_volatile_max": log_fuel,
		"m_char": log_fuel * 0.25, "m_ash": 0.0, "rate": 0.0, "pilot": 0.0,
	})


func log_ground_center_y(tilt := 0.0, radius := 0.09, length := 0.85) -> float:
	return _log_vertical_extent(radius, length, tilt)


func add_log_on_pile(yaw: float, tilt := 0.0, radius := 0.09,
		length := 0.85) -> void:
	if _logs.size() >= FireGpuSolver.MAX_LOGS:
		return
	if _stacked_log_count == 0:
		_stack_base_top_y = _pile_top_y()
	var slot := _stacked_log_count % STACK_SLOTS.size()
	var layer := _stacked_log_count / STACK_SLOTS.size()
	var offset: Vector2 = STACK_SLOTS[slot]
	if layer % 2 == 1:
		offset = Vector2(-offset.y, offset.x)
	var center_y := _stack_base_top_y + layer * radius * 2.3 \
		+ _log_vertical_extent(radius, length, tilt)
	add_log(Vector3(offset.x, center_y, offset.y), yaw, tilt, radius, length)
	_stacked_log_count += 1


func _pile_top_y() -> float:
	var top := 0.0
	for entry in _logs:
		top = maxf(top, float(entry["pos"].y) + _log_vertical_extent(
			float(entry["radius"]), float(entry["length"]), float(entry["tilt"])))
	return top


func _log_vertical_extent(radius: float, length: float, tilt: float) -> float:
	return length * 0.5 * absf(sin(tilt)) + radius * 1.15 * absf(cos(tilt))


func ignite_at(pos: Vector3, radius: float) -> void:
	for entry in _logs:
		if entry["pos"].distance_to(pos) <= radius and entry["m_volatile"] > 0.0:
			entry["t_solid"] = maxf(entry["t_solid"], WoodPyrolysis.T_PYROLYSIS)
			entry["t_char"] = maxf(entry["t_char"], WoodPyrolysis.T_GLOW)
			entry["pilot"] = entry["t_char"]


func clear() -> void:
	for entry in _logs:
		entry["node"].queue_free()
	_logs.clear()
	_stacked_log_count = 0
	_stack_base_top_y = 0.0


func log_count() -> int:
	return _logs.size()


func is_full() -> bool:
	return _logs.size() >= FireGpuSolver.MAX_LOGS


func total_fuel() -> float:
	var total := 0.0
	for entry in _logs:
		total += entry["m_volatile"]
	return total


func initial_fuel() -> float:
	var total := 0.0
	for entry in _logs:
		total += entry["m_volatile_max"]
	return total


func burning_count() -> int:
	var count := 0
	for entry in _logs:
		if entry["rate"] > 0.0:
			count += 1
	return count


func hottest_surface() -> float:
	var hottest := 0.0
	for entry in _logs:
		hottest = maxf(hottest, entry["t_char"])
	return hottest


func update(delta: float, gas_temperatures: PackedFloat32Array,
		ambient := 300.0) -> void:
	var kernel_weight := kernel_weight()
	var cell_volume := cell_size * cell_size * cell_size
	for i in _logs.size():
		var entry: Dictionary = _logs[i]
		var t_gas := ambient
		if i < gas_temperatures.size():
			t_gas = maxf(gas_temperatures[i], ambient)
		_pyrolysis.step(entry, delta, t_gas, ambient, kernel_weight, cell_volume)
		_update_look(entry)


## Sum of the falloff weights fire_inject mode 5 applies across the emit sphere:
## one weight per cell centre at the grid resolution, 1 - dist/radius when
## inside. Aligned-grid approximation (the real field is translation-dependent
## at half-cell scale); cached per (radius, cell size).
func kernel_weight() -> float:
	var key := Vector2(emit_radius, cell_size)
	if _kernel_cache > 0.0 and key == _kernel_cache_key:
		return _kernel_cache
	var reach := int(ceil(emit_radius / cell_size))
	var total := 0.0
	for x in range(-reach, reach + 1):
		for y in range(-reach, reach + 1):
			for z in range(-reach, reach + 1):
				var d := Vector3(x, y, z).length() * cell_size
				if d <= emit_radius:
					total += 1.0 - d / emit_radius
	_kernel_cache = maxf(total, 1e-6)
	_kernel_cache_key = key
	return _kernel_cache


func set_flame_boost(value: float) -> void:
	_pyrolysis.flame_boost = maxf(value, 0.0)


func _update_look(entry: Dictionary) -> void:
	var charred := 1.0 - float(entry["m_volatile"]) / maxf(entry["m_volatile_max"], 1e-4)
	var glow := clampf((float(entry["t_char"]) - WoodPyrolysis.T_CHAR_OUT)
		/ (WoodPyrolysis.T_GLOW - WoodPyrolysis.T_CHAR_OUT), 0.0, 1.0)
	charred = maxf(charred, glow * 0.8)
	for material: StandardMaterial3D in [entry["mat"], entry["end_mat"]]:
		material.albedo_color = COLOR_FRESH.lerp(COLOR_CHAR, clampf(charred, 0.0, 1.0))
		material.emission_energy_multiplier = glow * 1.4


func emitters() -> Array:
	var out := []
	for entry in _logs:
		out.append({
			"pos": entry["pos"], "radius": emit_radius, "rate": entry["rate"],
			"pilot": entry["pilot"],
		})
	return out
