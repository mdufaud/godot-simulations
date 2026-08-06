class_name FracturedWall extends RefCounted
## A wall fractured into Voronoi cells and turned into physics bodies. Every cell
## is a [RigidBody3D] that starts frozen (a static body, so it costs almost
## nothing); a blast wakes the cells inside its radius whose share of the impulse
## beats the wall's toughness, a woken cell that is still moving wakes whatever it
## runs into, and a support graph of cells sharing a Voronoi face is flood-filled
## from the ground so nothing is left floating.
##
## This is the [RigidBody3D] adapter over [VoronoiFracture]: the fracture itself
## knows nothing about physics.
##
## [codeblock]
## var wall := FracturedWall.new()
## wall.build(parent, preset, material, 100, 0.6, rng)
## wall.blast(hit_point, 1.4, 26.0)
## # every physics frame:
## wall.despawn_below(-8.0)
## wall.settle()
## [/codeblock]

## Emitted when the awake / asleep / gone tallies move.
signal stats_changed

# Below this speed an awake chunk is just settling and must not wake its neighbours,
# or the first hit would cascade through the whole wall.
const WAKE_SPEED := 1.6
# A cell whose lowest hull point starts within this of y=0 counts as resting on
# the ground: it is a root of the support flood-fill.
const GROUND_EPS := 0.08
# Fraction of a moving shard's speed handed to the neighbour it drags out.
const CONTACT_TRANSFER := 0.35
const MIN_CHUNKS := 12
const MIN_MASS_KG := 0.4

var chunks: Array[RigidBody3D] = []
var awake := 0
var gone := 0

var _toughness := 0.0
# body -> {neighbours: Array[RigidBody3D], grounded: bool, dead: bool}. Frozen
# chunks form a graph; anything not reachable from a grounded chunk has nothing
# holding it up and must fall.
var _info := {}
var _support_dirty := false


func asleep() -> int:
	return chunks.size() - awake - gone


func build(parent: Node3D, preset: WallPreset, material: Material, chunk_count: int,
		bias: float, rng: RandomNumberGenerator) -> void:
	clear()
	_toughness = preset.toughness
	var size := preset.size_m
	var frame := preset.frame()
	var count := maxi(int(chunk_count * preset.count_scale), MIN_CHUNKS)
	var seeds := VoronoiFracture.seed_points(size, count, Vector3.ZERO, bias, rng)
	var cells := VoronoiFracture.fracture_box(size, seeds)
	var base := Vector3(0.0, size.y * 0.5, 0.0)
	var by_seed := {}

	for cell in cells:
		var body := RigidBody3D.new()
		body.transform = frame * Transform3D(Basis(), base + cell.center)
		# Frozen cells are static bodies: they collide, they cost no solver time,
		# and Jolt never wakes them on its own.
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		body.continuous_cd = true
		body.contact_monitor = true
		body.max_contacts_reported = 4
		body.can_sleep = true
		var shape := ConvexPolygonShape3D.new()
		shape.points = cell.points
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		var mi := MeshInstance3D.new()
		mi.mesh = cell.mesh
		mi.material_override = material
		body.add_child(mi)
		body.mass = maxf(_hull_volume(cell.points) * preset.density_kg_m3, MIN_MASS_KG)
		body.body_entered.connect(_on_contact.bind(body))
		parent.add_child(body)
		chunks.append(body)

		var min_y := INF
		for p in cell.points:
			min_y = minf(min_y, (body.transform * p).y)
		_info[body] = {neighbours = [], grounded = min_y < GROUND_EPS, dead = false}
		by_seed[cell.seed] = body

	# The fracture's face-sharing report is symmetric in theory but clipped with
	# an epsilon, so register every edge in both directions.
	for cell in cells:
		var body: RigidBody3D = by_seed[cell.seed]
		for n in cell.neighbours:
			if not by_seed.has(n):
				continue
			var nb: RigidBody3D = by_seed[n]
			if not _info[body].neighbours.has(nb):
				_info[body].neighbours.append(nb)
			if not _info[nb].neighbours.has(body):
				_info[nb].neighbours.append(body)


func clear() -> void:
	for c in chunks:
		c.queue_free()
	chunks.clear()
	_info.clear()
	awake = 0
	gone = 0
	_support_dirty = false


## [param impulse] is an ejection speed in m/s at the centre; it falls off
## linearly to nothing at [param radius] and is scaled by each cell's mass.
func blast(origin: Vector3, radius: float, impulse: float) -> void:
	for body in chunks:
		var d := body.global_position - origin
		var dist := d.length()
		if dist > radius:
			continue
		# Linear falloff: the cells at the centre of the crater get the most.
		var imp := impulse * (1.0 - dist / radius)
		# A frozen cell holds until its share of the blast beats the wall's
		# toughness — that is the whole difference between glass and stone.
		if body.freeze and imp < _toughness:
			continue
		var dir := d.normalized() if dist > 1e-3 else Vector3.BACK
		_wake(body, dir * imp * body.mass)
	stats_changed.emit()


## Retires the chunks that have fallen out of the world.
func despawn_below(y: float) -> void:
	var changed := false
	for body in chunks:
		if _info[body].dead:
			continue
		if not body.freeze and body.global_position.y < y:
			_info[body].dead = true
			body.visible = false
			body.process_mode = Node.PROCESS_MODE_DISABLED
			awake -= 1
			gone += 1
			changed = true
	if changed:
		stats_changed.emit()


## Runs the support pass when a wake has invalidated it. Call once per physics
## frame; it is a no-op while nothing has moved.
func settle() -> void:
	if not _support_dirty:
		return
	_support_dirty = false
	_drop_unsupported()


func _wake(body: RigidBody3D, impulse: Vector3) -> void:
	if _info[body].dead:
		return
	if not body.freeze:
		if impulse != Vector3.ZERO:
			body.apply_central_impulse(impulse)
		return
	body.freeze = false
	body.sleeping = false
	if impulse != Vector3.ZERO:
		body.apply_central_impulse(impulse)
	awake += 1
	# Losing a frozen cell may have orphaned the ones it was holding up.
	_support_dirty = true


# Flood-fill the frozen graph from the grounded cells; every frozen cell the fill
# never reaches is hanging in the air (its support was blasted away) and falls.
# This is what keeps a hole in the wall from leaving the top row floating.
func _drop_unsupported() -> void:
	var supported := {}
	var stack: Array[RigidBody3D] = []
	for body in chunks:
		var info: Dictionary = _info[body]
		if body.freeze and info.grounded and not info.dead:
			supported[body] = true
			stack.append(body)
	while not stack.is_empty():
		var b: RigidBody3D = stack.pop_back()
		for nb in _info[b].neighbours:
			if supported.has(nb) or not nb.freeze or _info[nb].dead:
				continue
			supported[nb] = true
			stack.append(nb)
	for body in chunks:
		if body.freeze and not _info[body].dead and not supported.has(body):
			body.freeze = false
			body.sleeping = false
			awake += 1
	stats_changed.emit()


# A moving shard drags its neighbours out of the wall; a shard that has already
# come to rest does not, which is what keeps the untouched wall a static island.
func _on_contact(other: Node, body: RigidBody3D) -> void:
	if body.freeze or body.linear_velocity.length() < WAKE_SPEED:
		return
	if not (other is RigidBody3D) or not (other in chunks):
		return
	var hit: RigidBody3D = other
	if not hit.freeze:
		return
	var dir := (hit.global_position - body.global_position).normalized()
	_wake(hit, dir * body.linear_velocity.length() * CONTACT_TRANSFER * hit.mass)
	stats_changed.emit()


# Half the cell's bounding box — a convex Voronoi cell fills roughly that much of
# it. The exact hull volume would buy nothing here: what matters is that a shard's
# mass tracks its size, or the splinters fly off like boulders.
func _hull_volume(points: PackedVector3Array) -> float:
	var aabb := AABB(points[0], Vector3.ZERO)
	for p in points:
		aabb = aabb.expand(p)
	return aabb.size.x * aabb.size.y * aabb.size.z * 0.5
