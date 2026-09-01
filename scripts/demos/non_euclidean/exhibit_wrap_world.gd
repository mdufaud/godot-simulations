class_name ExhibitWrapWorld extends RefCounted
## Exhibit — the Manifold-Garden wrap world: a finite block whose space repeats.
##
## The walkable slab spans the whole cell in X and Z, so walking a straight line
## crosses a boundary every [constant PERIODS].x/z metres and continues on the
## same floor one period over — nothing marks the seam but the colored trim it
## passes. The Y period is taller so the fall through the central shaft breathes:
## dropped in, a body falls out of the cell below and re-enters from just under
## the shared ceiling, looping until it is scooped out. Colored trims per face
## keep the directions readable, and eight collision-free copies of the block
## stand one period away in X and Z so the neighbours the wrap promises are
## actually on screen. Y loops without a neighbour: the shared ceiling plus the
## fog carry the illusion.
##
## A torus under uniform gravity gains speed on every loop, so [constant
## TERMINAL_FALL] caps the fall of the player and the props — the loop stays
## periodic and Jolt never has to swallow a supersonic body.
##
## The host drives it: [method track] every physics frame while active, [method
## reset] on reset.

const PERIODS := Vector3(40.0, 60.0, 40.0)
const SLAB_THICKNESS := 1.0
const SHAFT_INNER := 3.4
const SHAFT_WALL := 0.4
const SHAFT_LIP := 0.6
const TERMINAL_FALL := 26.0

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Player boundary crossings counted so far.
var wrap_count := 0
## Prop boundary crossings counted so far — the shaft-loop meter.
var prop_wraps := 0
## Bodies that follow the cell wrap.
var props: Array[PortalRigidBody3D] = []

var _cell: Node3D
var _prop_poses: Array[Transform3D] = []


func build(cells: Node3D, materials: Dictionary) -> void:
	_cell = Node3D.new()
	_cell.name = "WrapWorld"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(-250.0, 0.0, -950.0))
	cells.add_child(_cell)
	_build_block(_cell, materials, true)
	_build_labels()
	_add_prop()
	_build_neighbors(materials)
	_build_shared_ceiling(materials)
	for corner in [Vector3(10.0, 4.0, 10.0), Vector3(-10.0, 4.0, 10.0),
			Vector3(10.0, 4.0, -10.0), Vector3(-10.0, 4.0, -10.0)]:
		GeometryKit.add_omni_light(_cell, corner, Color(0.55, 0.75, 0.95), 1.5, 24.0, false)
	# Spawn near an edge, facing across the whole block: a straight walk passes
	# the shaft and crosses the far seam after one period.
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(8.0, 0.9, 17.0))


## Wraps the player and every prop back into the cell. Returns [code]true[/code]
## when the player crossed a boundary, so the host can refresh its readout.
func track(player: NonEuclideanPlayer) -> bool:
	var changed := false
	var offset := WrapWorldState.wrap_offset(_cell.to_local(player.global_position), PERIODS)
	if offset != Vector3.ZERO:
		player.global_position += _cell.global_basis * offset
		player._portal_previous_position = player.global_position
		player.reset_physics_interpolation()
		wrap_count += 1
		changed = true
	_cap_player_fall(player)
	for body in props:
		var body_offset := WrapWorldState.wrap_offset(
			_cell.to_local(body.global_position), PERIODS)
		if body_offset != Vector3.ZERO:
			# A pure translation is a rigid mapping: velocities survive the wrap.
			body.request_portal_teleport(Transform3D(Basis.IDENTITY,
				_cell.global_basis * body_offset), null)
			prop_wraps += 1
		_cap_body_fall(body)
	return changed


## Zeroes the counters and returns every prop to its built pose. The host
## re-poses the player onto [member spawn_pose] right after.
func reset() -> void:
	wrap_count = 0
	prop_wraps = 0
	for index in props.size():
		var body := props[index]
		body.global_transform = _prop_poses[index]
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false


## The cell content: full-period slab pierced by the through-shaft, a collar lip
## around the shaft mouth, and the colored trims. Reused without collision for
## the eight neighbour copies.
func _build_block(parent: Node3D, materials: Dictionary, with_collision: bool) -> void:
	var half := PERIODS.x * 0.5
	var inner := SHAFT_INNER * 0.5
	# The slab is four pieces around the shaft hole, never one box with a hole
	# cut into it: the cut faces ARE the shaft walls below the floor, and no two
	# boxes overlap, so no coplanar faces flicker.
	var slab_y := -SLAB_THICKNESS * 0.5
	for piece in [
		[Vector3((inner + half) * 0.5, slab_y, 0.0), Vector3(half - inner, SLAB_THICKNESS, PERIODS.z)],
		[Vector3(-(inner + half) * 0.5, slab_y, 0.0), Vector3(half - inner, SLAB_THICKNESS, PERIODS.z)],
		[Vector3(0.0, slab_y, (inner + half) * 0.5), Vector3(SHAFT_INNER, SLAB_THICKNESS, half - inner)],
		[Vector3(0.0, slab_y, -(inner + half) * 0.5), Vector3(SHAFT_INNER, SLAB_THICKNESS, half - inner)],
	]:
		var at: Vector3 = piece[0]
		var size: Vector3 = piece[1]
		GeometryKit.add_box(parent, at, size, materials["concrete"], with_collision)
	# Collar lip around the shaft mouth: low enough to step over, tall enough to
	# read as a hole from distance, with a lit rim as a beacon.
	for wall in [
		[Vector3(inner + SHAFT_WALL * 0.5, 0.0, 0.0), Vector3(SHAFT_WALL, SHAFT_LIP, SHAFT_INNER + SHAFT_WALL * 2.0)],
		[Vector3(-inner - SHAFT_WALL * 0.5, 0.0, 0.0), Vector3(SHAFT_WALL, SHAFT_LIP, SHAFT_INNER + SHAFT_WALL * 2.0)],
		[Vector3(0.0, 0.0, inner + SHAFT_WALL * 0.5), Vector3(SHAFT_INNER, SHAFT_LIP, SHAFT_WALL)],
		[Vector3(0.0, 0.0, -inner - SHAFT_WALL * 0.5), Vector3(SHAFT_INNER, SHAFT_LIP, SHAFT_WALL)],
	]:
		var at: Vector3 = wall[0]
		var size: Vector3 = wall[1]
		GeometryKit.add_box(parent, Vector3(at.x, SHAFT_LIP * 0.5, at.z), size,
			materials["tile"], with_collision)
		GeometryKit.add_box(parent, Vector3(at.x, SHAFT_LIP, at.z),
			Vector3(size.x * 0.7, 0.06, size.z * 0.7), materials["corridor_light"], false)
	# Seam trims: one color per cardinal face, on the floor and repeated on the
	# slab side so a falling player can read which boundary they passed.
	var trim := 0.32
	for edge in [
		[Vector3(half - trim * 0.5, 0.0, 0.0), Vector3(trim, 0.04, PERIODS.z), "blue"],
		[Vector3(-half + trim * 0.5, 0.0, 0.0), Vector3(trim, 0.04, PERIODS.z), "orange"],
		[Vector3(0.0, 0.0, half - trim * 0.5), Vector3(PERIODS.x, 0.04, trim), "green"],
		[Vector3(0.0, 0.0, -half + trim * 0.5), Vector3(PERIODS.x, 0.04, trim), "measure"],
	]:
		var at: Vector3 = edge[0]
		var size: Vector3 = edge[1]
		var material: Material = materials[edge[2]]
		GeometryKit.add_box(parent, at + Vector3(0.0, 0.02, 0.0), size, material, false)
		var side := Vector3(at.x, 0.0, at.z).normalized()
		GeometryKit.add_box(parent, Vector3(at.x, -SLAB_THICKNESS * 0.5, at.z)
			+ side * 0.03, Vector3(size.x + 0.06, 0.5, size.z + 0.06), material, false)


func _build_labels() -> void:
	GeometryKit.add_label(_cell,
		"WRAP GARDEN\nSPACE REPEATS EVERY 40 M — WALK STRAIGHT TO RETURN\nTHE SHAFT FALLS FOREVER",
		Vector3(0.0, 3.4, 0.0), 0.0, Color(0.35, 0.85, 1.0), 48)


func _add_prop() -> void:
	var sphere := GeometryKit.add_sphere_prop(_cell, Vector3(-4.0, 0.5, 4.0), 0.4,
		Color(0.85, 0.55, 0.12), 1.4)
	props.assign([sphere])
	_prop_poses.append(sphere.global_transform)


## Eight collision-free copies one period away in X and Z — what the wrap
## promises is visibly there. No props, labels or lights: fog eats the detail.
func _build_neighbors(materials: Dictionary) -> void:
	for x_offset in [-1.0, 0.0, 1.0]:
		for z_offset in [-1.0, 0.0, 1.0]:
			if x_offset == 0.0 and z_offset == 0.0:
				continue
			var copy := Node3D.new()
			copy.name = "Neighbor%d%d" % [int(x_offset), int(z_offset)]
			copy.position = Vector3(x_offset * PERIODS.x, 0.0, z_offset * PERIODS.z)
			_cell.add_child(copy)
			_build_block(copy, materials, false)


## One slab shared by the nine visible copies: the fall re-enters from just
## under it, and it hides where the vertical repetition would begin.
func _build_shared_ceiling(materials: Dictionary) -> void:
	GeometryKit.add_box(_cell, Vector3(0.0, PERIODS.y * 0.5 + 0.25, 0.0),
		Vector3(PERIODS.x * 3.0, 0.5, PERIODS.z * 3.0), materials["concrete_dark"], false)


func _cap_player_fall(player: NonEuclideanPlayer) -> void:
	var fall := -player.velocity.dot(_cell.global_basis.y)
	if fall > TERMINAL_FALL:
		player.velocity += _cell.global_basis.y * (fall - TERMINAL_FALL)


func _cap_body_fall(body: PortalRigidBody3D) -> void:
	var fall := -body.linear_velocity.dot(_cell.global_basis.y)
	if fall > TERMINAL_FALL:
		body.linear_velocity += _cell.global_basis.y * (fall - TERMINAL_FALL)
