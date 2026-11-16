class_name ExplosionBarrelYard extends Node3D

signal full_changed(full: bool)

const BARREL_LIMIT := 16
const CLUSTER_SIZE := 4
const CLUSTER_SPACING_M := 0.75
const BARREL_GAP_M := 0.08
const NUDGE_STEP_M := 0.5
const NUDGE_MAX_M := 5.0
const NUDGE_ANGLES := 12
const AIM_LIMIT_M := 12.0
const BARREL_SEED := 1000
const SLAB_SIZE_M := Vector2(18.0, 10.0)
const SLAB_THICKNESS_M := 0.06
const SLAB_EDGE_MARGIN_M := 0.6
const WALL_LENGTH_M := 2.4
const WALL_HEIGHT_M := 0.8
const CRATE_SIZE_M := 0.7
const CRATE_MASS_KG := 14.0
const PALLET_SIZE_M := Vector3(1.2, 0.14, 0.8)
const PALLET_MASS_KG := 18.0
const PROP_SPIN := 0.25
const POLE_HEIGHT_M := 4.5
const FLOODLIGHT_ENERGY := 9.0
const FLOODLIGHT_RANGE_M := 22.0
const FLOODLIGHT_ANGLE_DEG := 50.0
## Pole feet (x, z): the two front corners and the back middle, so the camera side of the barrels is lit.
const POLES: Array[Vector2] = [Vector2(-8.4, 4.4), Vector2(8.4, 4.4), Vector2(0.0, -4.6)]
const RING_THICKNESS_M := 0.06
const RING_HEIGHT_M := 0.04
## Cluster centres on the slab (x, z): each one inside the previous one's chain reach, laid along the decor.
const DEFAULT_CLUSTERS_M: Array[Vector2] = [Vector2(-3.6, 0.8), Vector2(-0.3, -0.8), Vector2(3.0, 0.9)]
## Jersey walls: x, z, yaw in degrees.
const WALLS: Array[Vector3] = [
	Vector3(-5.6, -3.4, 0.0), Vector3(-3.1, -3.4, 0.0), Vector3(-0.6, -3.4, 0.0), Vector3(1.9, -3.4, 0.0),
	Vector3(4.4, -3.4, 0.0), Vector3(7.2, -2.2, 90.0), Vector3(-2.0, 2.0, 90.0), Vector3(1.5, 0.3, 90.0),
]
## Crates: x, z, stack height.
const CRATES: Array[Vector3] = [
	Vector3(-6.0, -0.8, 2.0), Vector3(-6.1, 0.3, 1.0), Vector3(1.0, -2.2, 1.0), Vector3(5.5, -0.6, 2.0),
	Vector3(5.6, 0.5, 1.0), Vector3(-0.4, 2.6, 1.0),
]
## Pallets: x, z, yaw in degrees.
const PALLETS: Array[Vector3] = [Vector3(-3.3, -2.0, 10.0), Vector3(3.2, -2.1, -8.0), Vector3(5.0, 2.7, 0.0)]

var system: ExplosionSystem
var charge: ExplosionCharge
var barrels: Array[ExplosiveBarrel] = []
var ring: MeshInstance3D
var ring_radius_m := 0.0

var _obstacles: Array[Dictionary] = []
var _props: Array[RigidBody3D] = []
var _spawned := 0
var _touch_driven := false
var _was_full := false
var _concrete: StandardMaterial3D
var _wood: StandardMaterial3D


static func default_barrel_count() -> int:
	return DEFAULT_CLUSTERS_M.size() * CLUSTER_SIZE


## Barrel centres of a cluster around [param centre] on the ground plane.
static func cluster_points(centre: Vector2) -> Array[Vector2]:
	var half := CLUSTER_SPACING_M * 0.5
	var points: Array[Vector2] = []
	for i in CLUSTER_SIZE:
		points.append(centre + Vector2(half if i % 2 == 0 else -half, half if i / 2 == 0 else -half))
	return points


func _ready() -> void:
	_concrete = _noise_material(Color(0.34, 0.34, 0.33), Color(0.5, 0.5, 0.48), 0.06, 0.95)
	_wood = _noise_material(Color(0.32, 0.2, 0.1), Color(0.5, 0.34, 0.18), 0.25, 0.85)
	_build_slab()
	for wall in WALLS:
		_add_wall(Vector2(wall.x, wall.y), wall.z)
	for crate in CRATES:
		_add_crate(Vector2(crate.x, crate.y), int(crate.z))
	for pallet in PALLETS:
		_add_pallet(Vector2(pallet.x, pallet.y), pallet.z)
	for centre in DEFAULT_CLUSTERS_M:
		for point in cluster_points(centre):
			_spawn_barrel(point)
	_build_floodlights()
	_build_ring()
	system.blast.connect(_push_props)
	full_changed.emit(false)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_touch_driven = true
	elif event is InputEventMouse:
		_touch_driven = event.device == InputEvent.DEVICE_ID_EMULATION


func _process(_delta: float) -> void:
	if not is_instance_valid(system):
		return
	_update_ring()
	var full := is_full()
	if full != _was_full:
		_was_full = full
		full_changed.emit(full)


func live_count() -> int:
	for i in range(barrels.size() - 1, -1, -1):
		if not is_instance_valid(barrels[i]):
			barrels.remove_at(i)
	var count := 0
	for barrel in barrels:
		count += 0 if barrel.detonated else 1
	return count


func is_full() -> bool:
	return live_count() + CLUSTER_SIZE > BARREL_LIMIT


func reach_m() -> float:
	return ExplosiveBarrel.chain_reach_m(charge.blast_radius_m, system.blast_speed_mps(charge), charge.radius_m)


## Places a cluster as near [param wanted] as free ground allows; false when refused (limit or no room).
func add_cluster(wanted: Vector2) -> bool:
	if is_full():
		return false
	var centre := _free_centre(wanted)
	if centre.x == INF:
		return false
	for point in cluster_points(centre):
		_spawn_barrel(point)
	return true


func add_cluster_at_screen(camera: Camera3D, screen_position: Vector2) -> bool:
	var ground := ExplosionActions.aim_point(camera, screen_position, AIM_LIMIT_M)
	return add_cluster(Vector2(ground.x, ground.z))


func _free_centre(aimed: Vector2) -> Vector2:
	var limit := (SLAB_SIZE_M * 0.5) - Vector2.ONE * (SLAB_EDGE_MARGIN_M + ExplosiveBarrel.RADIUS_M + CLUSTER_SPACING_M)
	var wanted := aimed.clamp(-limit, limit)
	if _cluster_free(wanted):
		return wanted
	var rings := int(NUDGE_MAX_M / NUDGE_STEP_M)
	for ring_index in range(1, rings + 1):
		for a in NUDGE_ANGLES:
			var angle := TAU * float(a) / float(NUDGE_ANGLES)
			var candidate := wanted + Vector2.from_angle(angle) * (NUDGE_STEP_M * float(ring_index))
			if _cluster_free(candidate):
				return candidate
	return Vector2(INF, INF)


func _cluster_free(centre: Vector2) -> bool:
	var limit := (SLAB_SIZE_M * 0.5) - Vector2.ONE * (SLAB_EDGE_MARGIN_M + ExplosiveBarrel.RADIUS_M)
	var min_gap_m := ExplosiveBarrel.RADIUS_M * 2.0 + BARREL_GAP_M
	for point in cluster_points(centre):
		if absf(point.x) > limit.x or absf(point.y) > limit.y:
			return false
		for barrel in barrels:
			if is_instance_valid(barrel) and not barrel.detonated \
					and Vector2(barrel.global_position.x, barrel.global_position.z).distance_to(point) < min_gap_m:
				return false
		if _hits_obstacle(point):
			return false
	return true


func _hits_obstacle(point: Vector2, inflate := ExplosiveBarrel.RADIUS_M + BARREL_GAP_M) -> bool:
	for obstacle in _obstacles:
		var body: Node3D = obstacle.body
		if not is_instance_valid(body):
			continue
		var local := body.global_transform.affine_inverse() * Vector3(point.x, body.global_position.y, point.y)
		var half: Vector2 = obstacle.half
		if absf(local.x) <= half.x + inflate and absf(local.z) <= half.y + inflate:
			return true
	return false


func _spawn_barrel(point: Vector2) -> void:
	var barrel := ExplosiveBarrel.new()
	barrel.system = system
	barrel.charge = charge
	barrel.rng.seed = BARREL_SEED + _spawned
	_spawned += 1
	barrel.position = Vector3(point.x, SLAB_THICKNESS_M + ExplosiveBarrel.HEIGHT_M * 0.5 + 0.01, point.y)
	add_child(barrel)
	system.blast.connect(barrel.apply_blast)
	barrels.append(barrel)


func _push_props(origin: Vector3, radius_m: float, speed_mps: float) -> void:
	for prop in _props:
		if not is_instance_valid(prop):
			continue
		var offset := prop.global_position - origin
		var impulse := ExplosiveBarrel.blast_impulse(offset, radius_m, speed_mps, prop.mass)
		prop.apply_central_impulse(impulse)
		prop.apply_torque_impulse(Vector3(offset.z, 0.0, -offset.x).normalized() * impulse.length() * PROP_SPIN)


func _build_slab() -> void:
	var body := StaticBody3D.new()
	body.position.y = SLAB_THICKNESS_M * 0.5
	var size := Vector3(SLAB_SIZE_M.x, SLAB_THICKNESS_M, SLAB_SIZE_M.y)
	body.add_child(_box_mesh(size, Vector3.ZERO, _concrete))
	body.add_child(_box_shape(size, Vector3.ZERO))
	add_child(body)


func _add_wall(centre: Vector2, yaw_deg: float) -> void:
	var body := StaticBody3D.new()
	body.position = Vector3(centre.x, SLAB_THICKNESS_M, centre.y)
	body.rotation.y = deg_to_rad(yaw_deg)
	var base := Vector3(WALL_LENGTH_M, WALL_HEIGHT_M * 0.4, 0.6)
	var top := Vector3(WALL_LENGTH_M, WALL_HEIGHT_M * 0.6, 0.3)
	var base_at := Vector3(0.0, base.y * 0.5, 0.0)
	var top_at := Vector3(0.0, base.y + top.y * 0.5, 0.0)
	body.add_child(_box_mesh(base, base_at, _concrete))
	body.add_child(_box_mesh(top, top_at, _concrete))
	body.add_child(_box_shape(base, base_at))
	body.add_child(_box_shape(top, top_at))
	add_child(body)
	_obstacles.append({body = body, half = Vector2(WALL_LENGTH_M, base.z) * 0.5})


func _add_crate(centre: Vector2, stack: int) -> void:
	var size := Vector3.ONE * CRATE_SIZE_M
	for level in stack:
		var body := _prop_body(Vector3(centre.x, SLAB_THICKNESS_M + CRATE_SIZE_M * (float(level) + 0.5), centre.y),
			float(level) * 0.3, CRATE_MASS_KG)
		body.add_child(_box_mesh(size, Vector3.ZERO, _wood))
		body.add_child(_box_shape(size, Vector3.ZERO))
		add_child(body)
		_obstacles.append({body = body, half = Vector2.ONE * CRATE_SIZE_M * 0.5})


func _add_pallet(centre: Vector2, yaw_deg: float) -> void:
	var body := _prop_body(Vector3(centre.x, SLAB_THICKNESS_M + PALLET_SIZE_M.y * 0.5, centre.y),
		deg_to_rad(yaw_deg), PALLET_MASS_KG)
	var deck := Vector3(PALLET_SIZE_M.x, 0.025, 0.14)
	for i in 5:
		var z := (float(i) / 4.0 - 0.5) * (PALLET_SIZE_M.z - deck.z)
		body.add_child(_box_mesh(deck, Vector3(0.0, PALLET_SIZE_M.y * 0.5 - deck.y * 0.5, z), _wood))
	var stringer := Vector3(PALLET_SIZE_M.x, PALLET_SIZE_M.y - deck.y * 2.0, 0.09)
	for i in 3:
		var z := (float(i) / 2.0 - 0.5) * (PALLET_SIZE_M.z - stringer.z)
		body.add_child(_box_mesh(stringer, Vector3(0.0, 0.0, z), _wood))
	body.add_child(_box_shape(PALLET_SIZE_M, Vector3.ZERO))
	add_child(body)
	_obstacles.append({body = body, half = Vector2(PALLET_SIZE_M.x, PALLET_SIZE_M.z) * 0.5})


func _prop_body(position_m: Vector3, yaw_rad: float, mass_kg: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass_kg
	body.position = position_m
	body.rotation.y = yaw_rad
	_props.append(body)
	return body


func _build_floodlights() -> void:
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.06
	pole_mesh.bottom_radius = 0.09
	pole_mesh.height = POLE_HEIGHT_M
	pole_mesh.material = _concrete
	for i in POLES.size():
		var foot := POLES[i]
		var pole := MeshInstance3D.new()
		pole.mesh = pole_mesh
		pole.position = Vector3(foot.x, SLAB_THICKNESS_M + POLE_HEIGHT_M * 0.5, foot.y)
		add_child(pole)
		var lamp := SpotLight3D.new()
		lamp.position = Vector3(foot.x, SLAB_THICKNESS_M + POLE_HEIGHT_M, foot.y)
		lamp.light_energy = FLOODLIGHT_ENERGY
		lamp.light_color = Color(1.0, 0.93, 0.8)
		lamp.spot_range = FLOODLIGHT_RANGE_M
		lamp.spot_angle = FLOODLIGHT_ANGLE_DEG
		lamp.shadow_enabled = i != 1
		add_child(lamp)
		lamp.look_at(Vector3(0.0, 0.0, 0.0))


func _build_ring() -> void:
	var mesh := TorusMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.62, 0.15, 0.8)
	mesh.material = material
	ring = MeshInstance3D.new()
	ring.mesh = mesh
	ring.scale.y = RING_HEIGHT_M / RING_THICKNESS_M
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	add_child(ring)


func _update_ring() -> void:
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	var mouse := viewport.get_mouse_position()
	var radius_m := reach_m()
	ring.visible = camera != null and radius_m > 0.0 and not _touch_driven \
		and viewport.get_visible_rect().has_point(mouse) and viewport.gui_get_hovered_control() == null
	if not ring.visible:
		return
	if not is_equal_approx(radius_m, ring_radius_m):
		ring_radius_m = radius_m
		var mesh := ring.mesh as TorusMesh
		mesh.inner_radius = maxf(radius_m - RING_THICKNESS_M * 0.5, 0.0)
		mesh.outer_radius = radius_m + RING_THICKNESS_M * 0.5
	var ground := ExplosionActions.aim_point(camera, mouse, AIM_LIMIT_M)
	ring.global_position = Vector3(ground.x, SLAB_THICKNESS_M + RING_HEIGHT_M, ground.z)


static func _box_mesh(size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	return instance


static func _box_shape(size: Vector3, at: Vector3) -> CollisionShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = at
	return collision


static func _noise_material(dark: Color, light: Color, frequency: float, roughness: float) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.frequency = frequency
	noise.fractal_octaves = 4
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([dark, light])
	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.color_ramp = ramp
	texture.seamless = true
	texture.width = 256
	texture.height = 256
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.roughness = roughness
	material.uv1_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.5
	return material
