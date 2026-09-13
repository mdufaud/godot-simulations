class_name TornadoDebrisPool
extends Node3D

## RigidBody3D pool driven by an analytic tornado wind field.
## One manager loop applies quadratic drag to every active body.
##
## Optimisations:
##   active-only iteration (_active_slots) — never visits parked bodies.
##   flat Packed*Arrays instead of Dictionary per body — zero dict-lookup cost.
##   force-computation locals — single binding call per body property.

const RHO_AIR := 1.21
const WAKE_SPEED := 4.0
const RECYCLE_DIST := 600.0
# 12 s: steady-state airborne population = spawn_rate * age. At spawn distance
# sub-meter pieces render as 1 px white dots ringing the neck — a dense swarm
# reads as noise veiling the funnel, not as debris.
const RECYCLE_AGE := 12.0

enum Variant { CRATE, ROCK, PLANK, TREE }

var field: TornadoWindField
var debris_cap := 200
var spawn_rate := 1.5
var throw_speed := 45.0
var active_count := 0

var _bodies: Array[RigidBody3D] = []

# Per-body flat arrays (index = pool slot, always sized to debris_cap).
var _variants: PackedByteArray          # Variant enum (0-3)
var _sizes: PackedFloat32Array          # world-size of the body
## Camera whose view culls sub-pixel debris: a 0.5 m crate at 500 m spans
## ~1 px and reads as a white dot. The wind rings every airborne piece around
## the core radius, so an unculled swarm renders as a dotted pillar veiling
## the funnel neck. Pieces stay simulated; they only stop rendering when
## smaller than ~3 px.
var camera: Camera3D
var _cda: PackedFloat32Array            # drag coefficient × reference area
var _cp_offsets: PackedVector3Array     # centre-of-pressure offset (local space)
var _ages: PackedFloat32Array           # seconds since un-parked
var _active_flags: PackedByteArray      # 1 = active, 0 = parked

# Indices of currently active slots for fast iteration.
var _active_slots: PackedInt32Array = []

var _spawn_accum := 0.0
var _throw_queue: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

var _mat_crate := StandardMaterial3D.new()
var _mat_rock := StandardMaterial3D.new()
var _mat_plank := StandardMaterial3D.new()
var _mat_trunk := StandardMaterial3D.new()
var _mat_foliage := StandardMaterial3D.new()


func _ready() -> void:
	_rng.seed = 42
	_mat_crate.albedo_color = Color(0.45, 0.3, 0.15)
	_mat_rock.albedo_color = Color(0.35, 0.34, 0.32)
	_mat_plank.albedo_color = Color(0.55, 0.42, 0.25)
	_mat_trunk.albedo_color = Color(0.3, 0.2, 0.12)
	_mat_foliage.albedo_color = Color(0.12, 0.25, 0.13)
	for m in [_mat_crate, _mat_rock, _mat_plank, _mat_trunk, _mat_foliage]:
		m.roughness = 1.0


func build_pool(cap: int) -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()
	_clear_arrays()
	debris_cap = cap
	for i in cap:
		var variant: Variant = _pick_variant()
		var body := _make_body(variant)
		add_child(body)
		_park(i)


func _clear_arrays() -> void:
	_variants.clear()
	_sizes.clear()
	_cda.clear()
	_cp_offsets.clear()
	_ages.clear()
	_active_flags.clear()
	_active_slots.clear()
	active_count = 0


func _pick_variant() -> Variant:
	var roll := _rng.randf()
	if roll < 0.35:
		return Variant.CRATE
	if roll < 0.6:
		return Variant.ROCK
	if roll < 0.85:
		return Variant.PLANK
	return Variant.TREE


func _make_body(variant: Variant) -> RigidBody3D:
	var body := RigidBody3D.new()
	var mesh_inst := MeshInstance3D.new()
	var col := CollisionShape3D.new()
	var size := 1.0
	var cd := 1.0
	var area := 1.0
	match variant:
		Variant.CRATE:
			size = _rng.randf_range(0.4, 1.2)
			cd = 1.05
			area = 1.5 * size * size  # cube mean projected area = SA/4
			var m := BoxMesh.new()
			m.size = Vector3.ONE * size
			mesh_inst.mesh = m
			mesh_inst.material_override = _mat_crate
			var s := BoxShape3D.new()
			s.size = Vector3.ONE * size
			col.shape = s
		Variant.ROCK:
			size = _rng.randf_range(0.3, 1.0)
			cd = 0.47
			area = 0.25 * PI * size * size  # sphere of radius size/2
			var m := SphereMesh.new()
			m.radius = size * 0.5
			m.height = size * 0.7
			m.radial_segments = 10
			m.rings = 5
			mesh_inst.mesh = m
			mesh_inst.material_override = _mat_rock
			var s := SphereShape3D.new()
			s.radius = size * 0.5
			col.shape = s
		Variant.PLANK:
			size = _rng.randf_range(1.0, 2.5)
			cd = 1.2
			area = (size * 0.3 + size * 0.06 + 0.3 * 0.06) * 0.5  # thin box: SA/4
			var m := BoxMesh.new()
			m.size = Vector3(size, 0.06, 0.3)
			mesh_inst.mesh = m
			mesh_inst.material_override = _mat_plank
			var s := BoxShape3D.new()
			s.size = Vector3(size, 0.06, 0.3)
			col.shape = s
		Variant.TREE:
			size = _rng.randf_range(3.0, 6.0)
			cd = 0.9
			area = 0.35 * size * size  # canopy cone frontal area approximation
			var trunk := CylinderMesh.new()
			trunk.top_radius = size * 0.04
			trunk.bottom_radius = size * 0.06
			trunk.height = size * 0.5
			trunk.radial_segments = 8
			mesh_inst.mesh = trunk
			mesh_inst.material_override = _mat_trunk
			var cone_inst := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = size * 0.22
			cone.height = size * 0.6
			cone.radial_segments = 8
			cone_inst.mesh = cone
			cone_inst.material_override = _mat_foliage
			cone_inst.position.y = size * 0.5
			body.add_child(cone_inst)
			var s := CylinderShape3D.new()
			s.radius = size * 0.1
			s.height = size * 0.9
			col.shape = s
	body.mass = _mass_for_variant(variant, size)
	body.add_child(mesh_inst)
	body.add_child(col)
	_variants.append(variant)
	_sizes.append(size)
	_cda.append(cd * area)
	_cp_offsets.append(
		Vector3(
			_rng.randf_range(-0.15, 0.15),
			_rng.randf_range(-0.15, 0.15),
			_rng.randf_range(-0.15, 0.15)
		) * size
	)
	_ages.append(0.0)
	_active_flags.append(0)
	_bodies.append(body)
	return body


func _park(i: int) -> void:
	var body := _bodies[i]
	body.freeze = true
	body.visible = false
	body.global_position = Vector3(0.0, -100.0 - i, 0.0)
	if _active_flags[i]:
		active_count -= 1
		var slot_idx := _active_slots.find(i)
		if slot_idx >= 0:
			_active_slots.remove_at(slot_idx)
	_active_flags[i] = 0


func _unpark(i: int, xform: Transform3D, lin_vel: Vector3, ang_vel: Vector3) -> void:
	var body := _bodies[i]
	body.global_transform = xform
	body.freeze = false
	body.visible = true
	body.linear_velocity = lin_vel
	body.angular_velocity = ang_vel
	body.sleeping = false
	_ages[i] = 0.0
	if not _active_flags[i]:
		active_count += 1
		_active_slots.append(i)
	_active_flags[i] = 1
	if _rng.randf() < 0.7:
		body.mass = _mass_for_variant(_variants[i], _sizes[i])


## Mass bounded by the per-variant gameplay range, but correlated to body size so a
## small prop is never heavier than a big one of the same kind.
func _mass_for_variant(variant: Variant, size: float) -> float:
	var lo := 5.0
	var hi := 60.0
	var s_lo := 0.4
	var s_hi := 1.2
	match variant:
		Variant.CRATE:
			pass
		Variant.ROCK:
			lo = 20.0
			hi = 100.0
			s_lo = 0.3
			s_hi = 1.0
		Variant.PLANK:
			lo = 1.0
			hi = 15.0
			s_lo = 1.0
			s_hi = 2.5
		Variant.TREE:
			lo = 60.0
			hi = 100.0
			s_lo = 3.0
			s_hi = 6.0
	var t := clampf((size - s_lo) / (s_hi - s_lo) + _rng.randf_range(-0.25, 0.25), 0.0, 1.0)
	return lerpf(lo, hi, t)


func _find_idle() -> int:
	# Scan for a parked slot; if none, steal the oldest active one.
	for i in _bodies.size():
		if not _active_flags[i]:
			return i
	var oldest := -1
	var oldest_age := -1.0
	for i in _bodies.size():
		if _ages[i] > oldest_age:
			oldest_age = _ages[i]
			oldest = i
	return oldest


func spawn_debris_random() -> void:
	if field == null or _bodies.is_empty():
		return
	var i := _find_idle()
	if i < 0:
		return
	var ang := _rng.randf_range(0.0, TAU)
	var r: float = field.r_core0 * _rng.randf_range(0.8, 2.5)
	var y: float = _rng.randf_range(1.0, 0.25 * field.height)
	var c: Vector3 = field.centerline_at(y)
	var pos := Vector3(c.x + cos(ang) * r, y, c.z + sin(ang) * r)
	var t := TornadoWindField.tangent_from_radial(cos(ang), sin(ang), field.swirl_sign)
	var tangent := Vector3(t.x, 0.0, t.y)
	var vel: Vector3 = tangent * 0.5 * field.u_max + Vector3(
		_rng.randf_range(-5.0, 5.0), _rng.randf_range(-5.0, 5.0), _rng.randf_range(-5.0, 5.0)
	)
	var basis := Basis.from_euler(Vector3(_rng.randf(), _rng.randf(), _rng.randf()) * TAU)
	_unpark(i, Transform3D(basis, pos), vel, Vector3(_rng.randf(), _rng.randf(), _rng.randf()) * 3.0)


func scatter_props(fraction := 0.6) -> void:
	var count := int(_bodies.size() * fraction)
	var c := field.centerline_at(0.0) if field != null else Vector3.ZERO
	for i in count:
		var ang := _rng.randf_range(0.0, TAU)
		var r := _rng.randf_range(30.0, 250.0)
		var pos := c + Vector3(cos(ang) * r, _sizes[i] * 0.6 + 0.2, sin(ang) * r)
		var basis := Basis.from_euler(Vector3(0.0, _rng.randf_range(0.0, TAU), 0.0))
		_unpark(i, Transform3D(basis, pos), Vector3.ZERO, Vector3.ZERO)


## Queue a throw from a world-space position along a world-space direction.
func queue_throw(from: Vector3, dir: Vector3) -> void:
	_throw_queue.append({from = from, dir = dir})


func _physics_process(delta: float) -> void:
	if field == null:
		return

	# ── throw queue ──
	for t in _throw_queue:
		var i := _find_idle()
		if i >= 0:
			_unpark(i, Transform3D(Basis.IDENTITY, t.from + t.dir * 3.0),
				t.dir * throw_speed,
				Vector3(_rng.randf(), _rng.randf(), _rng.randf()) * 5.0)
	_throw_queue.clear()

	# ── spawn ──
	_spawn_accum += spawn_rate * delta
	while _spawn_accum >= 1.0:
		_spawn_accum -= 1.0
		spawn_debris_random()

	# ── active-only drag loop ──
	var base_x := field.base_pos.x
	var base_z := field.base_pos.z
	var inv_delta: float = 1.0 / delta

	for i in _active_slots:
		var body := _bodies[i]
		_ages[i] += delta

		var bpos := body.global_position
		# Recycle check (world-distance from tornado base, same as original).
		var flat_dist := Vector2(bpos.x - base_x, bpos.z - base_z).length()
		if flat_dist > RECYCLE_DIST or bpos.y < -5.0 \
				or (body.sleeping and _ages[i] > RECYCLE_AGE
					and flat_dist > field.influence_radius(0.0)):
			_park(i)
			continue
		# Sub-pixel cull: hide pieces smaller than ~3 px from the camera.
		if camera != null:
			body.visible = bpos.distance_to(camera.global_position) < 380.0 * _sizes[i]

		# ── centreline-relative wind lookup ──
		var c := field.centerline_at(bpos.y)
		var r_core := field.core_radius_at(bpos.y)
		var rel_x := bpos.x - c.x
		var rel_z := bpos.z - c.z
		var r := sqrt(rel_x * rel_x + rel_z * rel_z)
		var r_bar := r / r_core
		if r_bar > TornadoWindField.INFLUENCE_FACTOR:
			continue

		# Sample precomputed cylindrical wind (v_r, v_t, v_z).
		var v_cyl := field.sample_wind_grid(r_bar, bpos.y)

		# Reconstruct world-space wind (same convention as wind_at).
		var r_dir_x := 0.0
		var r_dir_z := 0.0
		if r > 1e-4:
			r_dir_x = rel_x / r
			r_dir_z = rel_z / r
		var t := TornadoWindField.tangent_from_radial(r_dir_x, r_dir_z, field.swirl_sign)
		var v_wind := Vector3(
			r_dir_x * v_cyl.x + t.x * v_cyl.y,
			v_cyl.z,
			r_dir_z * v_cyl.x + t.y * v_cyl.y
		)

		var bvel := body.linear_velocity
		var v_rel := v_wind - bvel
		var sp := v_rel.length()
		if sp < 0.5:
			continue
		if body.sleeping:
			if sp > WAKE_SPEED:
				body.sleeping = false
			else:
				continue

		var f := 0.5 * RHO_AIR * _cda[i] * sp * v_rel
		var f_max: float = sp * body.mass * inv_delta
		f = f.limit_length(f_max)
		body.apply_force(f, body.global_basis * _cp_offsets[i])
