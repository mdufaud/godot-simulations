class_name ExplosionDustRing extends Node3D

const Puffs := preload("res://scripts/demos/explosion/explosion_dust_puffs.gd")
const SHADER := preload("res://shaders/explosion/dust_ring.gdshader")
const WALL_HEIGHT_PER_M := 0.08
const WALL_HEIGHT_PER_CHARGE_M := 0.3
const FADE_TAIL := 0.6
## The ground disc is only a hint under the solver's own dust: a flat plate at full opacity reads as a white sheet.
const DISC_OPACITY := 0.3
## Past this radius the wall stops growing taller and the disc band stops growing wider.
const GROWTH_MAX_M := 1200.0
const BAND_FRACTION := 0.22
## Blasts at least this big draw the air back in behind the front (afterwinds); smaller ones just settle.
const INFLOW_MIN_BLAST_M := 500.0
const INFLOW_FROM := 0.5
## Fraction of the front's travel at which the inflow starts: always behind the front.
const INFLOW_START_TRAVEL := 0.6
const INFLOW_SPEED_RATIO := 0.6
## Inflow wall height at the stem base, in charge radii: the dust is drawn up into the stem.
const INFLOW_RISE_PER_CHARGE := 4.0
const INFLOW_OPACITY := 0.8
const INFLOW_PROGRESS := 0.05
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
func _on_detonated(origin: Vector3, charge: ExplosionCharge, _carry_velocity: Vector3) -> void:
	if ExplosionFx.is_small_blast(charge):
		Puffs.burst(self, Vector3(origin.x, 0.1, origin.z), charge)
		return
	var span_m := charge.blast_radius_m - charge.final_radius_m()
	var speed_mps := system.blast_speed_mps(charge)
	if speed_mps <= 0.0 or span_m <= 0.0:
		return
	if _rings.size() >= MAX_RINGS:
		_free_ring(0)
	var wall := _make(_shared_wall_mesh())
	var disc := _make(_shared_disc_mesh())
	wall.position = Vector3(origin.x, 0.0, origin.z)
	disc.position = Vector3(origin.x, 0.05, origin.z)
	var ring := {wall = wall, disc = disc, from_m = charge.final_radius_m(), to_m = charge.blast_radius_m,
		base_m = WALL_HEIGHT_PER_CHARGE_M * charge.final_radius_m(), speed_mps = speed_mps, t_s = 0.0, span_m = span_m,
		inflow = inflow_window_s(charge.final_radius_m(), charge.blast_radius_m, speed_mps).y > 0.0 and charge.blast_radius_m >= INFLOW_MIN_BLAST_M, end_s = (1.0 + FADE_TAIL) * span_m / speed_mps}
	if ring.inflow:
		var start_m := INFLOW_FROM * charge.blast_radius_m
		var window_s := inflow_window_s(charge.final_radius_m(), charge.blast_radius_m, speed_mps)
		var inflow_wall := _make(_shared_wall_mesh())
		var inflow_disc := _make(_shared_disc_mesh())
		inflow_wall.position = wall.position
		inflow_disc.position = Vector3(origin.x, 0.08, origin.z)
		ring.merge({inflow_wall = inflow_wall, inflow_disc = inflow_disc, inflow_from_m = start_m,
			inflow_start_s = window_s.x, inflow_s = window_s.y})
		ring.end_s = maxf(ring.end_s, ring.inflow_start_s + ring.inflow_s)
	_rings.append(ring)
	_place(ring, 0.0)
	_place_inflow(ring)


## (start, duration) of the inflow in seconds; duration 0 when the charge reaches the inflow start radius.
static func inflow_window_s(from_m: float, blast_m: float, speed_mps: float) -> Vector2:
	var start_m := INFLOW_FROM * blast_m
	if speed_mps <= 0.0 or from_m >= start_m:
		return Vector2.ZERO
	return Vector2(INFLOW_START_TRAVEL * (blast_m - from_m) / speed_mps, (start_m - from_m) / (INFLOW_SPEED_RATIO * speed_mps))


func _process(delta: float) -> void:
	var dt := system.step_s(delta)
	for i in range(_rings.size() - 1, -1, -1):
		var ring := _rings[i]
		ring.t_s += dt
		var travel: float = ring.t_s * ring.speed_mps / ring.span_m
		if ring.t_s >= ring.end_s:
			_free_ring(i)
		else:
			_place(ring, travel)
			_place_inflow(ring)


## [param travel] runs 0 to 1 while the front moves and on to 1 + FADE_TAIL while the dust settles.
func _place(ring: Dictionary, travel: float) -> void:
	var radius_m: float = lerpf(ring.from_m, ring.to_m, clampf(travel, 0.0, 1.0))
	var height_m: float = ring.base_m + WALL_HEIGHT_PER_M * minf(radius_m, GROWTH_MAX_M)
	var fade := clampf(travel / (1.0 + FADE_TAIL), 0.0, 1.0)
	var wall: MeshInstance3D = ring.wall
	var disc: MeshInstance3D = ring.disc
	wall.scale = Vector3(radius_m, height_m, radius_m)
	wall.position.y = height_m * 0.5
	disc.scale = Vector3(radius_m * 2.0, 1.0, radius_m * 2.0)
	for node: MeshInstance3D in [wall, disc]:
		node.set_instance_shader_parameter("progress", fade)
		node.set_instance_shader_parameter("scale_m", height_m)
		node.set_instance_shader_parameter("band_width", BAND_FRACTION * minf(radius_m, GROWTH_MAX_M) / radius_m)
	disc.set_instance_shader_parameter("opacity", DISC_OPACITY)


## The air rushes back at a fixed share of the blast speed: the dust contracts toward the stem base and rises as it closes.
func _place_inflow(ring: Dictionary) -> void:
	if not ring.inflow:
		return
	var closure: float = (ring.t_s - ring.inflow_start_s) / ring.inflow_s
	var wall: MeshInstance3D = ring.inflow_wall
	var disc: MeshInstance3D = ring.inflow_disc
	wall.visible = closure >= 0.0 and closure <= 1.0
	disc.visible = wall.visible
	if not wall.visible:
		return
	var radius_m: float = lerpf(ring.inflow_from_m, ring.from_m, closure)
	var start_height_m: float = WALL_HEIGHT_PER_M * minf(ring.inflow_from_m, GROWTH_MAX_M) * 0.5
	var height_m: float = lerpf(start_height_m, INFLOW_RISE_PER_CHARGE * ring.from_m, closure)
	var opacity := INFLOW_OPACITY * smoothstep(0.0, 0.15, closure) * (1.0 - smoothstep(0.7, 1.0, closure))
	wall.scale = Vector3(radius_m, height_m, radius_m)
	wall.position.y = height_m * 0.5
	disc.scale = Vector3(radius_m * 2.0, 1.0, radius_m * 2.0)
	for node: MeshInstance3D in [wall, disc]:
		node.set_instance_shader_parameter("progress", INFLOW_PROGRESS)
		node.set_instance_shader_parameter("scale_m", height_m)
		node.set_instance_shader_parameter("opacity", opacity)
		node.set_instance_shader_parameter("band_width", BAND_FRACTION * minf(radius_m, GROWTH_MAX_M) / radius_m)


func clear() -> void:
	while not _rings.is_empty():
		_free_ring(0)


func _free_ring(index: int) -> void:
	_rings[index].wall.queue_free()
	_rings[index].disc.queue_free()
	if _rings[index].inflow:
		_rings[index].inflow_wall.queue_free()
		_rings[index].inflow_disc.queue_free()
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
