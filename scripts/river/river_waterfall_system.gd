extends Node3D

const Solver := preload("res://scripts/river/river_swe_solver.gd")
const SAMPLE_OVERLAP := 0.75
const PARTICLE_LAYER_SHIFT := 9
const PARTICLE_COMPOSITE_LAYER := 2
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
var _particles: ScreenSpaceFluidRenderer
var _material: ShaderMaterial
var _particles_rid := RID()
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
	_particles = ScreenSpaceFluidRenderer.new()
	_particles.name = "WaterfallParticles"
	_particles.camera = camera
	_particles.particle_count = Solver.SPILL_CAPACITY
	_particles.radius = particle_radius_m(swe.cell_m, _drop_m())
	swe.solver.spill_draw_radius_m = _particles.radius
	swe.solver.spill_breakup_exponent = BREAKUP_EXPONENT
	_particles.layer_shift = PARTICLE_LAYER_SHIFT
	_particles.cull_attribute_max = 0.0
	_particles.domain_aabb = _bounds()
	add_child(_particles)
	_particles.start()
	_particles.set_texture_width(Solver.SPILL_TEXTURE_WIDTH)
	# Layer 2 like the river surface: the reflection cameras would draw the screen-space composite as a ghost on the pool.
	_particles.composite_mi.layers = PARTICLE_COMPOSITE_LAYER
	_material = _particles.composite_material()
	_material.shader = load("res://shaders/river/river_waterfall_particles.gdshader")
	_material.set_shader_parameter("fluid_depth_tex", _particles.filtered_depth_texture())
	_material.set_shader_parameter("thickness_tex", _particles.thick_filter_v_vp.get_texture())
	_material.set_shader_parameter("sample_diameter_m", 2.0 * _particles.radius)
	_material.render_priority = 1
	_material.set_shader_parameter("turbulence_texture", turbulence_texture)
	_material.set_shader_parameter("streak_texture", load("res://resources/river/waterfall_streaks.png"))
	swe.materials.append(_material)
	set_quality(quality_tier)
	apply_config(water)


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
	if _material == null:
		return
	if unit_discharge_m2_s <= 0.0:
		_set_discharge(0.1)
	_material.set_shader_parameter("source_speed_m_s", water.speed_m_s)
	_material.set_shader_parameter("aeration_strength", aeration_strength(unit_discharge_m2_s, water.whitewater_strength))
	_material.set_shader_parameter("foam_amount", water.foam_amount)
	_material.set_shader_parameter("deep_color", water.deep_color)
	_material.set_shader_parameter("clarity", water.clarity)
	for spray in _sprays:
		spray.set_mist_density(water.mist_density)


func _set_discharge(value: float) -> void:
	unit_discharge_m2_s = value
	swe.solver.spill_breakup_reference_units = value * swe.cell_m / Solver.SPILL_EMISSION_HZ / Solver.SPILL_VOLUME_UNIT_M3
	swe.solver.spill_breakup_length_m = breakup_length_m(value)
	_material.set_shader_parameter("unit_discharge_m2_s", value)
	_material.set_shader_parameter("breakup_length_m", breakup_length_m(value))
	_material.set_shader_parameter("aeration_strength", aeration_strength(value, water.whitewater_strength))


func set_quality(tier: int) -> void:
	quality_tier = clampi(tier, 0, 3)
	for spray in _sprays:
		spray.set_quality(quality_tier)


# Spheres overlap their neighbours across a lip and along the fall at the landing speed of the highest drop.
static func particle_radius_m(cell_m: float, drop_m: float) -> float:
	var landing_m_s := sqrt(2.0 * Solver.GRAVITY_M_S2 * drop_m)
	return SAMPLE_OVERLAP * maxf(cell_m, landing_m_s / Solver.SPILL_EMISSION_HZ)


# Beyond the measured range the issuance turbulence grows with q, so the length is held at its last measured value.
static func breakup_length_m(discharge_m2_s: float) -> float:
	return BREAKUP_COEFFICIENT_M * pow(clampf(discharge_m2_s, 0.0, BREAKUP_MAX_DISCHARGE_M2_S), BREAKUP_EXPONENT)


static func aeration_strength(discharge_m2_s: float, turbulence: float) -> float:
	var thick := smoothstep(AERATION_DISCHARGE_M2_S.x, AERATION_DISCHARGE_M2_S.y, discharge_m2_s)
	return lerpf(AERATION_CALM, 1.0, sqrt(clampf(turbulence, 0.0, 1.0))) * lerpf(1.0 - AERATION_DISCHARGE_SHARE, 1.0, thick)


func tick(time_s: float, frozen: bool) -> void:
	var status: Dictionary = swe.solver.snapshot() if swe.active else {}
	var rid: RID = status.get("spill_positions", RID())
	_material.set_shader_parameter("simulation_time_s", time_s)
	if rid != _particles_rid:
		_particles.rebind()
		_particles_rid = rid
	_particles.update(rid, _particles.particle_count if rid.is_valid() else 0)
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
	if _material != null:
		swe.materials.erase(_material)
	for child in get_children():
		child.free()
	_sprays.clear()
	_spray_centers = PackedVector3Array()
	_spray_shares = PackedFloat32Array()
	_particles = null
	_material = null
	_particles_rid = RID()
	_impact_serial = -1
	_spill_words = PackedByteArray()


func rock_impacts() -> PackedVector4Array:
	return _rock_impacts


func set_effects_enabled(enabled: bool) -> void:
	for spray in _sprays:
		spray.visible = enabled
