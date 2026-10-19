class_name RiverWaterfallCurtain
extends RefCounted
## Builds the visible sheet of a waterfall over any terrain. Each column of the lip
## line is traced as a stream of water that slides on the ground while the ground
## holds it, leaves as a ballistic jet when the ground falls away faster, lands again
## on impact and stops below the landing water surface. Speed follows the energy line
## and thickness follows continuity, so ramps, cliffs, ledges and uneven lips share
## one algorithm. Edges are sunk into the terrain where a bank exists, and thinned to
## nothing where they hang free, so the sheet never shows an empty underside.
##
##   var curtain := RiverWaterfallCurtain.new()
##   curtain.ground = terrain.height_at            # func(point: Vector2) -> float
##   curtain.crest_from = Vector3(-3.0, 0.0, 4.0)  # left end of the lip, facing downstream
##   curtain.crest_to = Vector3(3.0, 0.0, 4.0)
##   curtain.surface_height_m = 6.06
##   curtain.speed_m_s = 0.85
##   curtain.landing_level_m = 0.06
##   mesh_instance.mesh = curtain.build()           # world-space vertices
##
## Pair the mesh with res://shaders/river/river_waterfall.gdshader.

const GRAVITY_M_S2 := 9.81
const MIN_FILM_M := 0.03
const DRY_M := 0.005
const MAX_FILM_M := 0.8
const PROFILE_STEP_M := 0.02
const CLING_FRACTION := 0.75
const CLING_MAX_TURN_DEG := 60.0
const EDGE_TUCK_M := 0.2
const FREE_EDGE_M := 0.6
const IMPACT_DECAY_S := 0.35
const MAX_STEPS := 4096
const STRIDE := 10

var ground: Callable
var crest_from := Vector3.ZERO
var crest_to := Vector3.RIGHT
var surface_height_m := 0.0
var speed_m_s := 1.0
var landing_level_m := 0.0
var inlet_m := 0.3
var overshoot_m := 0.4
var columns := 32
var rows := 96
var max_time_s := 6.0

var across := Vector3.RIGHT
var downstream := Vector3.FORWARD
var width_m := 0.0
var impact_points := PackedVector3Array()
var _profile := PackedFloat32Array()
var _profile_origin := Vector2.ZERO
var _flow := Vector2.ZERO


func validate() -> String:
	if not ground.is_valid():
		return "Waterfall curtain needs a ground sampler."
	if Vector2(crest_to.x - crest_from.x, crest_to.z - crest_from.z).length() < 0.01:
		return "Waterfall crest must have a horizontal extent."
	if columns < 1 or rows < 2:
		return "Waterfall curtain needs at least one column and two rows."
	if not is_finite(surface_height_m) or not is_finite(landing_level_m) or not is_finite(speed_m_s) or speed_m_s < 0.0:
		return "Waterfall flow must be finite with a non-negative speed."
	return ""


func build() -> ArrayMesh:
	var error := validate()
	assert(error.is_empty(), error)
	var span := Vector3(crest_to.x - crest_from.x, 0.0, crest_to.z - crest_from.z)
	width_m = span.length()
	across = span / width_m
	downstream = Vector3.UP.cross(across)
	_flow = Vector2(downstream.x, downstream.z)
	impact_points.clear()
	var origins := PackedVector2Array()
	var depths := PackedFloat32Array()
	var traces: Array[PackedFloat32Array] = []
	var reference := 0
	for column in columns + 1:
		var point := crest_from.lerp(crest_to, float(column) / columns)
		var origin := Vector2(point.x, point.z)
		var depth := maxf(surface_height_m - ground.call(origin - _flow * inlet_m), 0.0)
		origins.append(origin)
		depths.append(depth)
		traces.append(_trace(origin, depth))
		if depth > depths[reference]:
			reference = column
	var times := _row_times(traces[reference])
	var lip_time := _lip_time(traces[reference])
	var vertices := PackedVector3Array()
	var films := PackedColorArray()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var details := PackedVector2Array()
	var traits := PackedFloat32Array()
	var indices := PackedInt32Array()
	var wet_low := 0
	while wet_low < columns and depths[wet_low] <= DRY_M:
		wet_low += 1
	var wet_high := columns
	while wet_high > wet_low and depths[wet_high] <= DRY_M:
		wet_high -= 1
	var spacing := width_m / columns
	var stride := columns + 3
	for row in times.size():
		var states: Array[PackedFloat32Array] = []
		for column in columns + 1:
			states.append(_state_at(traces[column], times[row]))
		var skirts := [_skirt(origins[wet_low], states[wet_low], -1.0), _skirt(origins[wet_high], states[wet_high], 1.0)]
		var free := Vector2(1.0 if skirts[0] == null else 0.0, 1.0 if skirts[1] == null else 0.0)
		for slot in stride:
			var column := clampi(slot - 1, wet_low, wet_high)
			var u := float(column) / columns
			var edge_m := minf(column - wet_low, wet_high - column) * spacing
			var side_free := free.x if column - wet_low < wet_high - column else free.y
			var state := states[column]
			var thin := lerpf(1.0, smoothstep(0.0, FREE_EDGE_M, edge_m), side_free)
			var film := maxf(state[5] * thin, MIN_FILM_M * state[6])
			var surface := _surface_point(origins[column], state, film)
			var outside := slot - 1 < wet_low or slot == 0 or slot - 1 > wet_high or slot == stride - 1
			var skirt: Variant = skirts[0] if slot - 1 < wet_low or slot == 0 else skirts[1]
			var tucked := outside and skirt != null
			if tucked:
				surface = skirt
			vertices.append(surface)
			films.append(Color(film / MAX_FILM_M, 0.0, 0.0))
			normals.append(_normal(state))
			uvs.append(Vector2(u, times[row] - lip_time))
			details.append(Vector2(state[8], Vector2(state[3], state[4]).length()))
			traits.append_array(PackedFloat32Array([smoothstep(DRY_M, 0.03, depths[column]), side_free, state[7], -1.0 if tucked else state[6]]))
			if row < times.size() - 1 and slot < stride - 1:
				var i := row * stride + slot
				indices.append_array(PackedInt32Array([i, i + stride, i + 1, i + 1, i + stride, i + stride + 1]))
	for column in columns + 1:
		var landing := _landing_state(traces[column])
		if depths[column] > DRY_M and not landing.is_empty():
			impact_points.append(_surface_point(origins[column], landing, landing[5]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = films
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = details
	arrays[Mesh.ARRAY_CUSTOM0] = traits
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	return mesh


# Samples: time, along, bottom height, horizontal speed, vertical speed, thickness,
# attached, impact foam, distance travelled past the lip, landed.
func _trace(origin: Vector2, depth: float) -> PackedFloat32Array:
	_profile.clear()
	_profile_origin = origin
	var inlet_speed := maxf(speed_m_s, 0.05)
	var discharge := inlet_speed * maxf(depth, MIN_FILM_M)
	var max_film := MAX_FILM_M
	var along := -inlet_m
	var bottom := _ground(along)
	var velocity := Vector2(inlet_speed, 0.0)
	var head := bottom + inlet_speed * inlet_speed / (2.0 * GRAVITY_M_S2)
	var attached := true
	var impact := 0.0
	var travelled := -inlet_m
	var landed := false
	var time := 0.0
	var samples := PackedFloat32Array()
	for step in MAX_STEPS:
		var speed := maxf(velocity.length(), 0.01)
		var thickness := clampf(discharge / speed, MIN_FILM_M, max_film)
		if along < 0.0:
			thickness = maxf(surface_height_m - bottom, MIN_FILM_M)
			max_film = maxf(max_film, thickness)
		samples.append_array(PackedFloat32Array([time, along, bottom, velocity.x, velocity.y, thickness,
			1.0 if attached else 0.0, impact, travelled, 1.0 if landed else 0.0]))
		var surface := bottom + velocity.x / speed * thickness
		if along > 0.0 and surface < landing_level_m:
			landed = true
			if surface < landing_level_m - overshoot_m:
				break
		if time > max_time_s:
			break
		var dt := clampf(0.03 / speed, 0.001, 1.0 / 60.0)
		time += dt
		impact *= exp(-dt / IMPACT_DECAY_S)
		var previous := Vector2(along, bottom)
		if attached:
			var next := along + velocity.x * dt
			var flight := bottom + velocity.y * dt - 0.5 * GRAVITY_M_S2 * dt * dt
			var terrain := _ground(next)
			var direction := Vector2(next - along, terrain - bottom).normalized()
			var sharp := flight > terrain and direction.dot(velocity / speed) < cos(deg_to_rad(CLING_MAX_TURN_DEG))
			if sharp or flight > terrain + maxf(0.002, thickness * CLING_FRACTION):
				attached = false
				along = next
				bottom = flight
				velocity.y -= GRAVITY_M_S2 * dt
			else:
				along = next
				bottom = terrain
				if along < 0.0:
					velocity = direction * discharge / maxf(surface_height_m - bottom, MIN_FILM_M)
					head = bottom + velocity.length_squared() / (2.0 * GRAVITY_M_S2)
				else:
					velocity = direction * sqrt(maxf(2.0 * GRAVITY_M_S2 * (head - bottom), 0.0025))
		else:
			along += velocity.x * dt
			bottom += velocity.y * dt - 0.5 * GRAVITY_M_S2 * dt * dt
			velocity.y -= GRAVITY_M_S2 * dt
			var terrain := _ground(along)
			if bottom < terrain:
				var tangent := Vector2(2.0 * PROFILE_STEP_M, _ground(along + PROFILE_STEP_M) - _ground(along - PROFILE_STEP_M)).normalized()
				var kept := maxf(velocity.dot(tangent), 0.05)
				impact = maxf(impact, clampf(absf(velocity.dot(Vector2(-tangent.y, tangent.x))) / 6.0, 0.0, 1.0))
				bottom = terrain
				velocity = tangent * kept
				head = bottom + kept * kept / (2.0 * GRAVITY_M_S2)
				attached = true
		var step_length := Vector2(along, bottom).distance_to(previous)
		if previous.x >= 0.0:
			travelled += step_length
		elif along > 0.0:
			travelled = step_length * along / (along - previous.x)
		else:
			travelled = along
	return samples


func _ground(along: float) -> float:
	var position := maxf((along + inlet_m) / PROFILE_STEP_M, 0.0)
	var index := int(position)
	while _profile.size() <= index + 1:
		var point := _profile_origin + _flow * (_profile.size() * PROFILE_STEP_M - inlet_m)
		_profile.append(ground.call(point))
	return lerpf(_profile[index], _profile[index + 1], position - index)


func _row_times(samples: PackedFloat32Array) -> PackedFloat32Array:
	var count := samples.size() / STRIDE
	var lengths := PackedFloat32Array([0.0])
	var previous := _local_surface(samples, 0)
	for i in range(1, count):
		var point := _local_surface(samples, i)
		lengths.append(lengths[i - 1] + point.distance_to(previous))
		previous = point
	var times := PackedFloat32Array()
	var cursor := 1
	for row in rows + 1:
		var target := lengths[count - 1] * row / rows
		while cursor < count - 1 and lengths[cursor] < target:
			cursor += 1
		var low := maxi(cursor - 1, 0)
		var fraction := clampf((target - lengths[low]) / maxf(lengths[cursor] - lengths[low], 0.000001), 0.0, 1.0)
		times.append(lerpf(samples[low * STRIDE], samples[cursor * STRIDE], fraction))
	return times


func _lip_time(samples: PackedFloat32Array) -> float:
	for i in samples.size() / STRIDE:
		if samples[i * STRIDE + 1] >= 0.0:
			return samples[i * STRIDE]
	return 0.0


func _state_at(samples: PackedFloat32Array, time: float) -> PackedFloat32Array:
	var count := samples.size() / STRIDE
	var low := 0
	var high := count - 1
	if time >= samples[high * STRIDE]:
		return samples.slice(high * STRIDE, high * STRIDE + STRIDE)
	while high - low > 1:
		var middle := (low + high) / 2
		if samples[middle * STRIDE] <= time:
			low = middle
		else:
			high = middle
	var fraction := clampf((time - samples[low * STRIDE]) / maxf(samples[high * STRIDE] - samples[low * STRIDE], 0.000001), 0.0, 1.0)
	var state := PackedFloat32Array()
	for channel in STRIDE:
		state.append(lerpf(samples[low * STRIDE + channel], samples[high * STRIDE + channel], fraction))
	return state


func _landing_state(samples: PackedFloat32Array) -> PackedFloat32Array:
	for i in range(1, samples.size() / STRIDE):
		if samples[i * STRIDE + 9] > 0.5:
			var above := _local_surface(samples, i - 1).y - landing_level_m
			var below := _local_surface(samples, i).y - landing_level_m
			var time := lerpf(samples[(i - 1) * STRIDE], samples[i * STRIDE], clampf(above / maxf(above - below, 0.000001), 0.0, 1.0))
			return _state_at(samples, time)
	return PackedFloat32Array()


func _local_surface(samples: PackedFloat32Array, index: int) -> Vector2:
	var state := samples.slice(index * STRIDE, index * STRIDE + STRIDE)
	var normal := _local_normal(state)
	return Vector2(state[1], state[2]) + normal * state[5]


func _local_normal(state: PackedFloat32Array) -> Vector2:
	var velocity := Vector2(state[3], state[4])
	return Vector2(-velocity.y, velocity.x).normalized() if velocity.length() > 0.0001 else Vector2.UP


func _normal(state: PackedFloat32Array) -> Vector3:
	var normal := _local_normal(state)
	return downstream * normal.x + Vector3.UP * normal.y


func _surface_point(origin: Vector2, state: PackedFloat32Array, thickness: float) -> Vector3:
	var local := Vector2(state[1], state[2]) + _local_normal(state) * thickness
	return Vector3(origin.x, 0.0, origin.y) + downstream * local.x + Vector3.UP * local.y


func _skirt(origin: Vector2, state: PackedFloat32Array, side: float) -> Variant:
	var bed := _surface_point(origin, state, 0.0) + across * side * EDGE_TUCK_M
	if ground.call(Vector2(bed.x, bed.z)) < state[2] - 0.01:
		return null
	var surface := _surface_point(origin, state, state[5])
	var beside := surface + across * side * EDGE_TUCK_M
	var terrain: float = ground.call(Vector2(beside.x, beside.z))
	return Vector3(beside.x, minf(surface.y, terrain - 0.05), beside.z)
