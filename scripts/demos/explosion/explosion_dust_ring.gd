class_name ExplosionDustRing extends Node3D

const SHADER := preload("res://shaders/explosion/dust_ring.gdshader")
const WALL_HEIGHT_PER_M := 0.08
const WALL_HEIGHT_PER_CHARGE_M := 0.3
const FADE_TAIL := 0.6
## Oldest ring goes first, so a chain of barrels cannot pile up nodes.
const MAX_RINGS := 8

static var _wall_mesh: CylinderMesh
static var _disc_mesh: PlaneMesh

var system: ExplosionSystem

var _rings: Array[Dictionary] = []


func start() -> void:
	assert(system != null)
	system.detonated.connect(_on_detonated)


## Expands at the blast speed from the charge radius to the blast radius, on the ground under the charge.
func _on_detonated(origin: Vector3, charge: ExplosionCharge) -> void:
	var span_m := charge.blast_radius_m - charge.radius_m
	var speed_mps := system.blast_speed_mps(charge)
	if speed_mps <= 0.0 or span_m <= 0.0:
		return
	if _rings.size() >= MAX_RINGS:
		_free_ring(0)
	var wall := _make(_shared_wall_mesh())
	var disc := _make(_shared_disc_mesh())
	wall.position = Vector3(origin.x, 0.0, origin.z)
	disc.position = Vector3(origin.x, 0.05, origin.z)
	_rings.append({wall = wall, disc = disc, from_m = charge.radius_m, to_m = charge.blast_radius_m,
		base_m = WALL_HEIGHT_PER_CHARGE_M * charge.radius_m, speed_mps = speed_mps, t_s = 0.0, span_m = span_m})
	_place(_rings[-1], 0.0)


func _process(delta: float) -> void:
	var dt := system.step_s(delta)
	for i in range(_rings.size() - 1, -1, -1):
		var ring := _rings[i]
		ring.t_s += dt
		var travel: float = ring.t_s * ring.speed_mps / ring.span_m
		if travel >= 1.0 + FADE_TAIL:
			_free_ring(i)
		else:
			_place(ring, travel)


## [param travel] runs 0 to 1 while the front moves and on to 1 + FADE_TAIL while the dust settles.
func _place(ring: Dictionary, travel: float) -> void:
	var radius_m: float = lerpf(ring.from_m, ring.to_m, clampf(travel, 0.0, 1.0))
	var height_m: float = ring.base_m + WALL_HEIGHT_PER_M * radius_m
	var fade := clampf(travel / (1.0 + FADE_TAIL), 0.0, 1.0)
	var wall: MeshInstance3D = ring.wall
	var disc: MeshInstance3D = ring.disc
	wall.scale = Vector3(radius_m, height_m, radius_m)
	wall.position.y = height_m * 0.5
	disc.scale = Vector3(radius_m * 2.0, 1.0, radius_m * 2.0)
	for node: MeshInstance3D in [wall, disc]:
		node.set_instance_shader_parameter("progress", fade)
		node.set_instance_shader_parameter("scale_m", height_m)


func clear() -> void:
	while not _rings.is_empty():
		_free_ring(0)


func _free_ring(index: int) -> void:
	_rings[index].wall.queue_free()
	_rings[index].disc.queue_free()
	_rings.remove_at(index)


func _make(mesh: Mesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


static func _material(wall: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("wall", wall)
	return material


static func _shared_wall_mesh() -> CylinderMesh:
	if _wall_mesh == null:
		_wall_mesh = CylinderMesh.new()
		_wall_mesh.top_radius = 1.0
		_wall_mesh.bottom_radius = 1.0
		_wall_mesh.height = 1.0
		_wall_mesh.radial_segments = 96
		_wall_mesh.rings = 1
		_wall_mesh.cap_top = false
		_wall_mesh.cap_bottom = false
		_wall_mesh.material = _material(1.0)
	return _wall_mesh


static func _shared_disc_mesh() -> PlaneMesh:
	if _disc_mesh == null:
		_disc_mesh = PlaneMesh.new()
		_disc_mesh.size = Vector2.ONE
		_disc_mesh.material = _material(0.0)
	return _disc_mesh
