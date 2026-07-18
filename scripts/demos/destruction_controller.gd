extends Node3D
## Voronoi destruction on Jolt. Four walls — concrete, brick, glass and stone,
## each with its own thickness, density and toughness — are fractured once at
## load: every cell is a RigidBody3D that starts frozen (a static body, so it
## costs almost nothing). A blast wakes the cells inside its radius whose share
## of the impulse beats the wall's toughness, so a pistol round shatters glass
## but bounces off the stone rampart; a woken cell that is still moving wakes
## whatever it runs into, so the fracture propagates outward and the rest of the
## wall stays asleep. A support graph (cells sharing a Voronoi face) is
## flood-filled from the ground after every wake: frozen cells no longer
## connected to the ground fall instead of floating in mid-air.

const DESPAWN_Y := -8.0
# Below this speed an awake chunk is just settling and must not wake its neighbours,
# or the first hit would cascade through the whole wall.
const WAKE_SPEED := 1.6
# A cell whose lowest hull point starts within this of y=0 counts as resting on
# the ground: it is a root of the support flood-fill.
const GROUND_EPS := 0.08

@onready var menu: SimMenu = $UI/SimMenu
@onready var orbit_cam: OrbitCamera = $CameraPivot
@onready var main_cam: Camera3D = $CameraPivot/Camera3D
@onready var sun: DirectionalLight3D = $DirectionalLight3D
@onready var wall_root: Node3D = $Wall
@onready var projectile_root: Node3D = $Projectiles

var chunk_count := 100
var fracture_bias := 0.6
var radius_scale := 1.0
var power_scale := 1.0

var chunks: Array[RigidBody3D] = []
var status_label: Label
var _rng := RandomNumberGenerator.new()
var _awake := 0
var _gone := 0
var _rebuild_pending := false
# Per-chunk support data: body -> {neighbours: Array[RigidBody3D], grounded: bool,
# dead: bool, tough: float}. Frozen chunks form a graph; anything not reachable
# from a grounded chunk has nothing holding it up and must fall.
var _info := {}
var _support_dirty := false

# toughness = minimum blast impulse (after falloff) that tears a frozen cell out
# of its wall. count_scale spends the chunk budget where it reads best: glass
# splinters fine, stone breaks into a few heavy blocks.
var _wall_defs: Array[Dictionary] = []
var _projectile_defs: Array[Dictionary] = []
var _projectile_idx := 1


func _ready() -> void:
	orbit_cam.target = Vector3(-1.8, 0.8, -1.5)
	orbit_cam.distance = 18.0
	orbit_cam.pitch = -22.0
	orbit_cam.yaw = 14.0
	orbit_cam.min_distance = 4.0
	orbit_cam.max_distance = 50.0

	# The walls face the camera, so the sun comes from over the viewer's shoulder.
	sun.rotation_degrees = Vector3(-48.0, -25.0, 0.0)
	sun.directional_shadow_max_distance = 60.0

	_wall_defs = [
		{name = "Concrete", size = Vector3(5.6, 4.0, 0.7),
			pos = Vector3(-4.6, 0.0, 1.4), yaw = 14.0,
			density = 2300.0, tough = 9.0, count_scale = 1.0,
			mat = _concrete_material()},
		{name = "Brick", size = Vector3(5.6, 4.0, 0.45),
			pos = Vector3(1.4, 0.0, 1.2), yaw = -8.0,
			density = 1800.0, tough = 5.0, count_scale = 1.1,
			mat = _brick_material()},
		{name = "Glass", size = Vector3(5.0, 3.6, 0.18),
			pos = Vector3(-8.0, 0.0, -5.2), yaw = 24.0,
			density = 2500.0, tough = 0.5, count_scale = 1.8,
			mat = _glass_material()},
		{name = "Stone", size = Vector3(5.0, 4.4, 1.0),
			pos = Vector3(1.6, 0.0, -5.4), yaw = -14.0,
			density = 2700.0, tough = 14.0, count_scale = 0.7,
			mat = _stone_material()},
	]
	_projectile_defs = [
		{name = "Bullet", mass = 0.4, radius = 0.06, speed = 95.0,
			blast_radius = 0.7, blast_impulse = 13.0, flash = false,
			color = Color(0.75, 0.7, 0.45), metallic = 0.9, rough = 0.25,
			emission = Color.BLACK},
		{name = "Cannonball", mass = 12.0, radius = 0.22, speed = 30.0,
			blast_radius = 1.4, blast_impulse = 26.0, flash = false,
			color = Color(0.15, 0.15, 0.17), metallic = 0.9, rough = 0.25,
			emission = Color.BLACK},
		{name = "Explosive shell", mass = 7.0, radius = 0.16, speed = 26.0,
			blast_radius = 3.2, blast_impulse = 62.0, flash = true,
			color = Color(0.3, 0.28, 0.26), metallic = 0.6, rough = 0.4,
			emission = Color(1.0, 0.45, 0.1) * 0.6},
	]
	_spawn_wall_labels()
	_setup_ui()
	_build_wall()


# ── Materials ────────────────────────────────────────────────────────────────

func _noise_texture(frequency: float, dark: float) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.frequency = frequency
	var ramp := Gradient.new()
	ramp.set_color(0, Color(dark, dark, dark))
	ramp.set_color(1, Color.WHITE)
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.color_ramp = ramp
	return tex


func _concrete_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.68, 0.67, 0.64)
	mat.albedo_texture = _noise_texture(0.015, 0.6)
	mat.uv1_scale = Vector3(0.35, 0.35, 0.35)
	mat.roughness = 0.95
	mat.vertex_color_use_as_albedo = true
	return mat


func _brick_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/destruction/brick_wall.gdshader")
	return mat


func _glass_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.72, 0.85, 0.88, 0.42)
	mat.roughness = 0.06
	mat.metallic = 0.1
	mat.metallic_specular = 0.8
	return mat


func _stone_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.48, 0.42)
	mat.albedo_texture = _noise_texture(0.03, 0.45)
	mat.uv1_scale = Vector3(0.6, 0.6, 0.6)
	mat.roughness = 1.0
	mat.vertex_color_use_as_albedo = true
	return mat


func _spawn_wall_labels() -> void:
	for def in _wall_defs:
		var label := Label3D.new()
		label.text = def.name
		label.position = def.pos + Vector3(0.0, def.size.y + 0.6, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 64
		label.outline_size = 14
		label.modulate = Color(0.95, 0.95, 0.9)
		add_child(label)


# ── Walls ────────────────────────────────────────────────────────────────────

func _build_wall() -> void:
	for c in chunks:
		c.queue_free()
	chunks.clear()
	_info.clear()
	_clear_projectiles()
	_awake = 0
	_gone = 0

	_rng.seed = 0xB16B00B5
	for def in _wall_defs:
		_build_one_wall(def)
	_update_status()


func _build_one_wall(def: Dictionary) -> void:
	var size: Vector3 = def.size
	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(def.yaw)), def.pos)
	var count := maxi(int(chunk_count * def.count_scale), 12)
	var seeds := VoronoiFracture.seed_points(size, count, Vector3.ZERO, fracture_bias, _rng)
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
		mi.material_override = def.mat
		body.add_child(mi)
		body.mass = maxf(_hull_volume(cell.points) * def.density, 0.4)
		body.body_entered.connect(_on_chunk_contact.bind(body))
		wall_root.add_child(body)
		chunks.append(body)

		var min_y := INF
		for p in cell.points:
			min_y = minf(min_y, (body.transform * p).y)
		_info[body] = {neighbours = [], grounded = min_y < GROUND_EPS,
				dead = false, tough = def.tough}
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


# Half the cell's bounding box — a convex Voronoi cell fills roughly that much of
# it. The exact hull volume would buy nothing here: what matters is that a shard's
# mass tracks its size, or the splinters fly off like boulders.
func _hull_volume(points: PackedVector3Array) -> float:
	var aabb := AABB(points[0], Vector3.ZERO)
	for p in points:
		aabb = aabb.expand(p)
	return aabb.size.x * aabb.size.y * aabb.size.z * 0.5


func _clear_projectiles() -> void:
	for p in projectile_root.get_children():
		p.queue_free()


# ── Fracture propagation ─────────────────────────────────────────────────────

func _wake_chunk(body: RigidBody3D, impulse: Vector3) -> void:
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
	_awake += 1
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
			_awake += 1
	_update_status()


func _blast(origin: Vector3, radius: float, impulse: float) -> void:
	for body in chunks:
		var d := body.global_position - origin
		var dist := d.length()
		if dist > radius:
			continue
		# Linear falloff: the cells at the centre of the crater get the most.
		# impulse is an ejection speed (m/s): scaled by mass below, so a pebble
		# and a boulder leave the crater at the same speed, like a real blast.
		var imp := impulse * (1.0 - dist / radius)
		# A frozen cell holds until its share of the blast beats the wall's
		# toughness — that is the whole difference between glass and stone.
		if body.freeze and imp < _info[body].tough:
			continue
		var dir := d.normalized() if dist > 1e-3 else Vector3.BACK
		_wake_chunk(body, dir * imp * body.mass)
	_update_status()


# A moving shard drags its neighbours out of the wall; a shard that has already
# come to rest does not, which is what keeps the untouched wall a static island.
func _on_chunk_contact(other: Node, body: RigidBody3D) -> void:
	if body.freeze or body.linear_velocity.length() < WAKE_SPEED:
		return
	if not (other is RigidBody3D) or not (other in chunks):
		return
	var hit: RigidBody3D = other
	if not hit.freeze:
		return
	var dir := (hit.global_position - body.global_position).normalized()
	_wake_chunk(hit, dir * body.linear_velocity.length() * 0.35 * hit.mass)
	_update_status()


# ── Projectiles ──────────────────────────────────────────────────────────────

func _fire(screen_pos: Vector2) -> void:
	var def: Dictionary = _projectile_defs[_projectile_idx]
	var origin := main_cam.project_ray_origin(screen_pos)
	var dir := main_cam.project_ray_normal(screen_pos)

	var ball := RigidBody3D.new()
	ball.position = origin + dir * 0.6
	ball.mass = def.mass
	ball.continuous_cd = true
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	ball.linear_velocity = dir * def.speed
	var shape := SphereShape3D.new()
	shape.radius = def.radius
	var col := CollisionShape3D.new()
	col.shape = shape
	ball.add_child(col)
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = def.radius
	sphere.height = def.radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = def.color
	mat.metallic = def.metallic
	mat.roughness = def.rough
	if def.emission != Color.BLACK:
		mat.emission_enabled = true
		mat.emission = def.emission
	sphere.material = mat
	mi.mesh = sphere
	ball.add_child(mi)
	ball.body_entered.connect(_on_projectile_hit.bind(ball, def), CONNECT_ONE_SHOT)
	projectile_root.add_child(ball)


func _on_projectile_hit(_other: Node, ball: RigidBody3D, def: Dictionary) -> void:
	# The kinetic energy the projectile actually arrives with drives the blast, so
	# a slow lob dents the wall and a full-speed shot blows a hole through it.
	var strength := clampf(ball.linear_velocity.length() / def.speed, 0.1, 1.5)
	_blast(ball.global_position, def.blast_radius * radius_scale,
			strength * def.blast_impulse * power_scale)
	if def.flash:
		_explosion_flash(ball.global_position)
		ball.queue_free()


func _explosion_flash(pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 10.0
	light.omni_range = 14.0
	add_child(light)
	var tween := create_tween()
	tween.tween_property(light, "light_energy", 0.0, 0.4)
	tween.tween_callback(light.queue_free)


# ── UI ───────────────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	menu.add_section("Walls")
	menu.add_button("↺ Rebuild walls", _build_wall)
	menu.add_slider("Chunks / wall", 40.0, 180.0, float(chunk_count), _on_chunk_count)
	menu.add_slider("Shard bias", 0.0, 1.0, fracture_bias, _on_bias)
	status_label = menu.add_label("")
	menu.add_separator()

	menu.add_section("Weapon")
	menu.add_option_button("Projectile", _projectile_defs.map(func(d): return d.name),
			_projectile_idx, func(i): _projectile_idx = i)
	menu.add_button("💥 Fire", func(): _fire(get_viewport().get_visible_rect().size * 0.5))
	menu.add_label("Right-click to shoot at the cursor")
	menu.add_slider("Blast radius ×", 0.3, 2.5, radius_scale, func(v): radius_scale = v)
	menu.add_slider("Blast power ×", 0.2, 3.0, power_scale, func(v): power_scale = v)
	menu.add_separator()

	menu.add_section("Scene")
	menu.add_button("🧹 Clear rubble", _clear_projectiles)


# Rebuilding the walls on every slider tick would refracture 500 hulls per frame,
# so the count and the bias land on release.
func _on_chunk_count(v: float) -> void:
	chunk_count = int(round(v))
	_queue_rebuild()


func _on_bias(v: float) -> void:
	fracture_bias = v
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	get_tree().create_timer(0.35).timeout.connect(func():
		_rebuild_pending = false
		_build_wall()
	)


func _update_status() -> void:
	if status_label == null:
		return
	status_label.text = "%d cells · %d awake · %d asleep · %d gone" % [
		chunks.size(), _awake, chunks.size() - _awake - _gone, _gone,
	]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		_fire(event.position)


func _physics_process(_delta: float) -> void:
	for p in projectile_root.get_children():
		if p is Node3D and p.global_position.y < DESPAWN_Y:
			p.queue_free()
	for body in chunks:
		if _info[body].dead:
			continue
		if not body.freeze and body.global_position.y < DESPAWN_Y:
			_info[body].dead = true
			body.visible = false
			body.process_mode = Node.PROCESS_MODE_DISABLED
			_awake -= 1
			_gone += 1
	if _support_dirty:
		_support_dirty = false
		_drop_unsupported()
