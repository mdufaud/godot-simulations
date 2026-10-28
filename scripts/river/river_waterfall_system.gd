extends Node3D

const Solver := preload("res://scripts/river/river_swe_solver.gd")
# Layer 2 like the river surface: the reflection cameras would draw the sheets as a ghost on the pool.
const SHEET_LAYER := 2
const IMPACT_MIN_M3_S := 0.002
# Spray emitters pick their points at random: each impact gets points in proportion to its rate, the faint ones none.
const SPRAY_POINTS := 64
const SPRAY_MIN_SHARE := 0.05
# Landings on touching tiles form one impact zone with its own spray, kept on the zone nearest to where it was.
# A zone starts to spray from x and sprays fully from y of landing rate, weighted by drop.
const MAX_SPRAYS := 8
const SPRAY_RATE_M3_S := Vector2(0.25, 1.0)
const SPRAY_MATCH_M := 3.0
# Horeni break-up length of a rectangular nappe, L = 6 q^0.32, measured for q below 0.25 m2/s.
const BREAKUP_COEFFICIENT_M := 6.0
const BREAKUP_EXPONENT := 0.32
const BREAKUP_MAX_DISCHARGE_M2_S := 0.25
# A calm, thin sheet stays streaky where a turbulent torrent turns white: aeration grows with the river's
# turbulence and with the discharge per metre of lip.
const AERATION_CALM := 0.3
const AERATION_DISCHARGE_M2_S := Vector2(0.2, 0.9)
const AERATION_DISCHARGE_SHARE := 0.25
const DISCHARGE_SMOOTHING := 0.3
const SHEET_ROWS := 20
# Foam streak radius against the solver cell, at the reference stream's volume.
const FOAM_RADIUS_CELLS := 0.7

var field: RiverField
var water: RiverConfig
var swe: Node3D
var camera: Camera3D
var turbulence_texture: Texture2D
var quality_tier := 1
var unit_discharge_m2_s := 0.0
var _sprays: Array[RiverWaterfallSpray] = []
var _spray_centers := PackedVector3Array()
var _spray_shares := PackedFloat32Array()
var _sheet_material: ShaderMaterial
var _sheet_lips: Texture2DRD
var _sheet_flow: Texture2DRD
var _foam_material: ShaderMaterial
var _foam_positions: Texture2DRD
var _foam_motions: Texture2DRD
var _foam: MultiMeshInstance3D
var _lips_rid := RID()
var _impact_serial := -1
var _spill_words := PackedByteArray()
var _rock_impacts := PackedVector4Array()


class Zone:
	var points := PackedVector4Array()
	var flow := Vector3.ZERO
	var rate := 0.0


func start() -> void:
	assert(camera != null, "WaterfallSystem.camera must be set before start()")
	_add_spray()
	swe.solver.spill_breakup_exponent = BREAKUP_EXPONENT
	_add_sheets()
	_add_foam()
	_set_look("turbulence_texture", turbulence_texture)
	_set_look("streak_texture", load("res://resources/river/waterfall_streaks.png"))
	_set_look("short_spill_m", Solver.SPILL_SHORT_DROP_M)
	swe.materials.append(_sheet_material)
	set_quality(quality_tier)
	apply_config(water)


# Each fall from lip to pool: one sheet instance per face the solver lists, unused ones collapse.
func _add_sheets() -> void:
	_sheet_lips = Texture2DRD.new()
	_sheet_flow = Texture2DRD.new()
	_sheet_material = ShaderMaterial.new()
	_sheet_material.shader = load("res://shaders/river/river_spill_sheet.gdshader")
	_sheet_material.set_shader_parameter("lip_list", _sheet_lips)
	_sheet_material.set_shader_parameter("lip_flow", _sheet_flow)
	_sheet_material.set_shader_parameter("lip_list_width", Solver.SPILL_TEXTURE_WIDTH)
	_sheet_material.set_shader_parameter("sheet_rows", SHEET_ROWS)
	# After the pool's surface, which cuts its foot.
	_sheet_material.render_priority = 1
	_sheet_material.set_shader_parameter("handover", Vector4(0.0, 0.0, Solver.SPILL_WHOLE_STREAM_SHARE, Solver.SPILL_MAX_THINNING))
	_sheet_material.set_shader_parameter("thinning_exponent", BREAKUP_EXPONENT)
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var rows := SHEET_ROWS
	for row in rows:
		for column in 3:
			vertices.append(Vector3.ZERO)
			uvs.append(Vector2(column * 0.5, float(row) / float(rows - 1)))
	for row in rows - 1:
		for column in 2:
			var i := row * 3 + column
			indices.append_array(PackedInt32Array([i, i + 1, i + 3, i + 1, i + 4, i + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var strip := ArrayMesh.new()
	strip.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = strip
	multimesh.instance_count = Solver.SPILL_LIP_CAPACITY
	var transforms := PackedFloat32Array()
	for i in Solver.SPILL_LIP_CAPACITY:
		transforms.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]))
	multimesh.buffer = transforms
	multimesh.custom_aabb = _bounds()
	var sheets := MultiMeshInstance3D.new()
	sheets.name = "WaterfallSheets"
	sheets.multimesh = multimesh
	sheets.material_override = _sheet_material
	sheets.layers = SHEET_LAYER
	sheets.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sheets)


func _set_look(parameter: String, value: Variant) -> void:
	for material: ShaderMaterial in [_sheet_material, _foam_material]:
		material.set_shader_parameter(parameter, value)


# The broken-up part of each fall: one soft streak per spill particle, drawn where the sheet has torn.
func _add_foam() -> void:
	_foam_positions = Texture2DRD.new()
	_foam_motions = Texture2DRD.new()
	_foam_material = ShaderMaterial.new()
	_foam_material.shader = load("res://shaders/river/river_spill_foam.gdshader")
	_foam_material.set_shader_parameter("positions", _foam_positions)
	_foam_material.set_shader_parameter("motions", _foam_motions)
	_foam_material.set_shader_parameter("texture_width", Solver.SPILL_TEXTURE_WIDTH)
	_foam_material.set_shader_parameter("radius_m", FOAM_RADIUS_CELLS * swe.cell_m)
	_foam_material.render_priority = 2
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = QuadMesh.new()
	multimesh.instance_count = Solver.SPILL_CAPACITY
	var transforms := PackedFloat32Array()
	for i in Solver.SPILL_CAPACITY:
		transforms.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]))
	multimesh.buffer = transforms
	multimesh.custom_aabb = _bounds()
	var foam := MultiMeshInstance3D.new()
	foam.name = "WaterfallFoam"
	foam.multimesh = multimesh
	foam.material_override = _foam_material
	foam.layers = SHEET_LAYER
	foam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Hidden until the solver's particles are bound: a placeholder texture reads as live particles.
	foam.visible = false
	add_child(foam)
	_foam = foam


func _add_spray() -> RiverWaterfallSpray:
	var spray := RiverWaterfallSpray.new()
	spray.name = "WaterfallSpray%d" % _sprays.size()
	spray.noise_texture = turbulence_texture
	add_child(spray)
	spray.start()
	spray.set_quality(quality_tier)
	if water != null:
		spray.set_mist_density(water.mist_density)
	_sprays.append(spray)
	_spray_centers.append(Vector3.INF)
	_spray_shares.append(0.0)
	return spray


func _drop_m() -> float:
	return maxf(field.height_range_m.y - field.height_range_m.x, 0.0)


func _bounds() -> AABB:
	var rect := field.domain_rect()
	var low := field.height_range_m.x - 2.0
	return AABB(Vector3(rect.position.x, low, rect.position.y), Vector3(rect.size.x, _drop_m() + 6.0, rect.size.y))


func apply_config(value: RiverConfig) -> void:
	water = value
	if _sheet_material == null:
		return
	if unit_discharge_m2_s <= 0.0:
		_set_discharge(0.1)
	_set_look("source_speed_m_s", water.speed_m_s)
	_set_look("aeration_strength", aeration_strength(unit_discharge_m2_s, water.whitewater_strength))
	_set_look("foam_amount", water.foam_amount)
	_set_look("deep_color", water.deep_color)
	_set_look("clarity", water.clarity)
	for spray in _sprays:
		spray.set_mist_density(water.mist_density)


func _set_discharge(value: float) -> void:
	unit_discharge_m2_s = value
	swe.solver.spill_breakup_reference_units = value * swe.cell_m / Solver.SPILL_EMISSION_HZ / Solver.SPILL_VOLUME_UNIT_M3
	swe.solver.spill_breakup_length_m = breakup_length_m(value)
	_set_look("unit_discharge_m2_s", value)
	_set_look("breakup_length_m", breakup_length_m(value))
	_set_look("aeration_strength", aeration_strength(value, water.whitewater_strength))


func set_quality(tier: int) -> void:
	quality_tier = clampi(tier, 0, 3)
	for spray in _sprays:
		spray.set_quality(quality_tier)


# Beyond the measured range the issuance turbulence grows with q, so the length is held at its last measured value.
static func breakup_length_m(discharge_m2_s: float) -> float:
	return BREAKUP_COEFFICIENT_M * pow(clampf(discharge_m2_s, 0.0, BREAKUP_MAX_DISCHARGE_M2_S), BREAKUP_EXPONENT)


static func aeration_strength(discharge_m2_s: float, turbulence: float) -> float:
	var thick := smoothstep(AERATION_DISCHARGE_M2_S.x, AERATION_DISCHARGE_M2_S.y, discharge_m2_s)
	return lerpf(AERATION_CALM, 1.0, sqrt(clampf(turbulence, 0.0, 1.0))) * lerpf(1.0 - AERATION_DISCHARGE_SHARE, 1.0, thick)


func tick(time_s: float, frozen: bool) -> void:
	var status: Dictionary = swe.solver.snapshot() if swe.active else {}
	var rid: RID = status.get("spill_lips", RID())
	_set_look("simulation_time_s", time_s)
	if rid != _lips_rid:
		_lips_rid = rid
		_sheet_lips.texture_rd_rid = rid
		_sheet_flow.texture_rd_rid = status.get("spill_lip_flow", RID())
		_foam_positions.texture_rd_rid = status.get("spill_positions", RID())
		_foam_motions.texture_rd_rid = status.get("spill_motion", RID())
		_foam.visible = _foam_positions.texture_rd_rid.is_valid() and _foam_motions.texture_rd_rid.is_valid()
	if int(status.get("spill_impact_serial", -1)) != _impact_serial:
		_impact_serial = int(status.spill_impact_serial)
		_measure_discharge(status.get("spill_words", PackedByteArray()), float(status.spill_impact_window_s))
		_follow_impacts(status.spill_impacts, float(status.spill_impact_window_s))
	var intensity := water.foam_amount * minf(water.speed_m_s / 0.85, 1.5)
	for i in _sprays.size():
		_sprays[i].tick(clampf(intensity * _spray_shares[i], 0.0, 1.0), frozen)


# Mean discharge per metre of spilling lip between two reads of the spill ledgers.
func _measure_discharge(words: PackedByteArray, elapsed: float) -> void:
	if words.size() < Solver.SPILL_STATE_BYTES:
		return
	var previous := _spill_words
	_spill_words = words
	if previous.size() < Solver.SPILL_STATE_BYTES:
		return
	var emitted := (words.decode_u32(12) - previous.decode_u32(12)) * 4294967296.0 + (float(words.decode_u32(8)) - float(previous.decode_u32(8)))
	var faces := float(words.decode_u32(60) - previous.decode_u32(60))
	var outputs := float(words.decode_u32(64) - previous.decode_u32(64))
	if faces <= 0.0 or outputs <= 0.0 or elapsed <= 0.0 or emitted < 0.0:
		return
	var lip_m: float = faces / outputs * swe.cell_m
	var measured: float = emitted * Solver.SPILL_VOLUME_UNIT_M3 / elapsed / lip_m
	_set_discharge(lerpf(unit_discharge_m2_s, measured, DISCHARGE_SMOOTHING))


# Impact tiles: landings in water, then hits on dry ground, each as weight, weighted velocity x and z, weighted height.
func _follow_impacts(tiles: PackedInt32Array, window_s: float) -> void:
	var columns: int = Solver.impact_tiles(swe.solver.grid, swe.cell_m).x
	var origin: Vector2 = swe.region_m.position
	var rate := Solver.SPILL_IMPACT_WEIGHT_UNITS * Solver.SPILL_VOLUME_UNIT_M3 / maxf(window_s, 0.001)
	var landings := {}
	var flows := {}
	var rocks := PackedVector4Array()
	for tile in tiles.size() / 8:
		var cell := Vector2i(tile % columns, tile / columns)
		var center := origin + (Vector2(cell) + Vector2.ONE * 0.5) * Solver.SPILL_IMPACT_TILE_M
		for kind in 2:
			var base := tile * 8 + kind * 4
			var weight := float(tiles[base])
			if weight * rate < IMPACT_MIN_M3_S:
				continue
			var point := Vector4(center.x, tiles[base + 3] / weight, center.y, weight * rate)
			if kind == 0:
				landings[cell] = point
				flows[cell] = Vector3(tiles[base + 1], 0.0, tiles[base + 2])
			else:
				rocks.append(point)
	var zones: Array[Zone] = []
	var seen := {}
	for cell: Vector2i in landings:
		if seen.has(cell):
			continue
		var zone := Zone.new()
		var stack: Array[Vector2i] = [cell]
		seen[cell] = true
		while not stack.is_empty():
			var current: Vector2i = stack.pop_back()
			zone.points.append(landings[current])
			zone.flow += flows[current]
			zone.rate += landings[current].w
			for neighbour in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
				var next: Vector2i = current + neighbour
				if landings.has(next) and not seen.has(next):
					seen[next] = true
					stack.append(next)
		zones.append(zone)
	zones.sort_custom(func(a: Zone, b: Zone) -> bool: return a.rate > b.rate)
	var taken := PackedByteArray()
	taken.resize(_sprays.size())
	var centers := PackedVector3Array()
	centers.resize(_sprays.size())
	centers.fill(Vector3.INF)
	var shares := PackedFloat32Array()
	shares.resize(_sprays.size())
	for zone: Zone in zones.slice(0, MAX_SPRAYS):
		if zone.rate < SPRAY_MIN_SHARE * zones[0].rate:
			break
		var center := Vector3.ZERO
		for point in zone.points:
			center += Vector3(point.x, point.y, point.z) * point.w / zone.rate
		var index := _nearest_spray(center, taken)
		if index < 0:
			_add_spray()
			taken.append(0)
			centers.append(Vector3.INF)
			shares.append(0.0)
			index = _sprays.size() - 1
		taken[index] = 1
		centers[index] = center
		shares[index] = smoothstep(SPRAY_RATE_M3_S.x, SPRAY_RATE_M3_S.y, zone.rate)
		var downstream := zone.flow.normalized() if zone.flow.length() > 0.0 else Vector3.FORWARD
		var across := downstream.cross(Vector3.UP).normalized()
		var points := PackedVector3Array()
		for landing in weighted_points(zone.points):
			points.append(Vector3(landing.x, landing.y, landing.z))
		var sorted := Array(points)
		sorted.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.dot(across) < b.dot(across))
		points = PackedVector3Array(sorted)
		var width := (points[-1] - points[0]).dot(across) + Solver.SPILL_IMPACT_TILE_M
		_sprays[index].set_impacts(points, downstream, across, width)
	_spray_centers = centers
	_spray_shares = shares
	_rock_impacts = rocks
	_sprays[0].set_rock_impacts(weighted_points(rocks), Vector3.FORWARD if zones.is_empty() else zones[0].flow.normalized())


# The free spray that last followed a zone near this one, else a free idle one, else -1.
func _nearest_spray(center: Vector3, taken: PackedByteArray) -> int:
	var best := -1
	var best_distance := SPRAY_MATCH_M
	for i in _sprays.size():
		if taken[i] == 0 and _spray_centers[i].distance_to(center) < best_distance:
			best = i
			best_distance = _spray_centers[i].distance_to(center)
	if best >= 0:
		return best
	for i in _sprays.size():
		if taken[i] == 0 and _spray_shares[i] <= 0.0:
			return i
	return -1 if _sprays.size() < MAX_SPRAYS else taken.find(0)


static func weighted_points(impacts: PackedVector4Array) -> PackedVector4Array:
	var total := 0.0
	var largest := 0.0
	for impact in impacts:
		total += impact.w
		largest = maxf(largest, impact.w)
	var points := PackedVector4Array()
	for impact in impacts:
		if impact.w < SPRAY_MIN_SHARE * largest:
			continue
		for i in maxi(roundi(SPRAY_POINTS * impact.w / total), 1):
			points.append(impact)
	return points


func reset() -> void:
	_spill_words = PackedByteArray()
	for spray in _sprays:
		spray.restart()


func stop() -> void:
	for spray in _sprays:
		spray.stop()
	if _sheet_material != null:
		swe.materials.erase(_sheet_material)
	if _sheet_lips != null:
		_sheet_lips.texture_rd_rid = RID()
		_sheet_flow.texture_rd_rid = RID()
	for child in get_children():
		child.free()
	_sprays.clear()
	_spray_centers = PackedVector3Array()
	_spray_shares = PackedFloat32Array()
	_sheet_material = null
	_sheet_lips = null
	_sheet_flow = null
	_foam_material = null
	_foam_positions = null
	_foam_motions = null
	_lips_rid = RID()
	_impact_serial = -1
	_spill_words = PackedByteArray()


func rock_impacts() -> PackedVector4Array:
	return _rock_impacts


func set_effects_enabled(enabled: bool) -> void:
	for spray in _sprays:
		spray.visible = enabled
