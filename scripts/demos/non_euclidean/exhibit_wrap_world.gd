class_name ExhibitWrapWorld extends RefCounted
## Exhibit — the Manifold-Garden wrap world: a finite block whose space repeats.
##
## The walkable slab spans the whole cell in X and Z, so walking a straight line
## crosses a boundary every [constant PERIODS].x/z metres and continues on the
## same floor one period over — nothing marks the seam but the colored trim it
## passes. The Y period is shorter, so the floors above and below stay in view:
## dropped in, a body falls out of the cell bottom and re-enters from the top,
## looping until it is scooped out. Colored trims per face keep the directions
## readable, and the block repeats as a lattice [constant LATTICE_RINGS] periods
## out in X and Z and [constant LATTICE_LAYERS] up and down — one MultiMesh of
## the furnished cell, so the floors above and below and the endless columns are
## the same world seen again. The wrap invariant is that the world is the same
## one period over, so the teleport at the boundary never moves visible content:
## the lattice edge sits past the fog, and one directional light lights every
## copy alike.
##
## A torus under uniform gravity gains speed on every loop, so [constant
## TERMINAL_FALL] caps the fall of the player and the props — the loop stays
## periodic and Jolt never has to swallow a supersonic body.
##
## The host drives it: [method track] every physics frame while active, [method
## reset] on reset.
##
## Reading aids: a HOME beacon marks the spawn, chevron arrows run from it
## toward the far seams in the seam's own color, the ball and the player are
## mirrored into every lattice copy — you see yourself walk over there and fall
## below you — and a crossing pulses that seam's trim across the whole lattice
## while the HUD names it. The ball is a carryable [GripBall]: take it, drop it
## down the shaft.

const PERIODS := Vector3(40.0, 30.0, 40.0)
const SLAB_THICKNESS := 1.0
const SHAFT_INNER := 3.4
const SHAFT_WALL := 0.4
const SHAFT_LIP := 0.6
const TERMINAL_FALL := 26.0
const PROP_RADIUS := 0.4
const PROP_COLOR := Color(0.85, 0.55, 0.12)
## Fog closes before the lattice edge, at least 120 m from anywhere in the cell
## both across ([constant LATTICE_RINGS]) and up or down ([constant LATTICE_LAYERS]).
const FOG_BEGIN := 45.0
const FOG_END := 115.0
const LATTICE_RINGS := 3
const LATTICE_LAYERS := 4
const HAZE := Color(0.13, 0.19, 0.27)
## Render layer only the wrap's directional light reaches.
const SUN_LAYER := 32
const COLUMN := 1.4
const COLUMN_AT := 12.0
const BEAM_HEIGHT := 9.0
## Trim key -> readable seam name. The trim colors double as direction codes:
## the +X seam is blue, -X orange, +Z green, -Z the dark cyan measure color.
const SEAM_NAMES := {
	"blue": "BLUE (+X)",
	"orange": "ORANGE (-X)",
	"green": "GREEN (+Z)",
	"measure": "CYAN (-Z)",
}

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Player boundary crossings counted so far.
var wrap_count := 0
## Prop boundary crossings counted so far — the shaft-loop meter.
var prop_wraps := 0
## Readable name of the seam the player last crossed, empty before the first.
var last_seam := ""
## Bodies that follow the cell wrap.
var props: Array[PortalRigidBody3D] = []

var _cell: Node3D
var _prop_poses: Array[Transform3D] = []
var _seam_materials: Dictionary = {}
var _base_emission: Dictionary = {}
var _pulses: Dictionary = {}
var _lattice_offsets: Array[Vector3] = []
var _prop_copies: MultiMeshInstance3D
var _self_copies: MultiMeshInstance3D
var _self_basis := Basis()
var _environment: Environment


func build(cells: Node3D, materials: Dictionary) -> void:
	_cell = Node3D.new()
	_cell.name = "WrapWorld"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(-250.0, 0.0, -950.0))
	cells.add_child(_cell)
	for key in SEAM_NAMES:
		var owned := (materials[key] as StandardMaterial3D).duplicate() as StandardMaterial3D
		_seam_materials[key] = owned
		_base_emission[key] = owned.emission_energy_multiplier
		_pulses[key] = 0.0
	_lattice_offsets = _neighbor_offsets(LATTICE_RINGS, LATTICE_LAYERS)
	_build_block(_cell, materials, true)
	_furnish_cell(_cell, materials)
	_add_prop()
	_build_lattice(materials)
	_build_neighbor_labels()
	_build_copies(materials)
	_build_sun()
	for node in _cell.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).layers |= SUN_LAYER
	# Spawn near an edge, facing across the whole block: a straight walk passes
	# the shaft and crosses the far seam after one period.
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(8.0, 0.9, 17.0))


## Everything a cell wears besides its collision block: labels, the shaft sign,
## the HOME beacon and the seam arrows. The lattice copies all of it but the
## labels — the wrap invariant is that the world is identical one period over,
## so looking anywhere across a seam (or backwards across the crossing moment)
## must show the same content the centre cell has.
func _furnish_cell(cell: Node3D, materials: Dictionary) -> void:
	_build_labels(cell)
	_build_beacon(cell, materials)
	_build_seam_arrows(cell, materials)


## Wraps the player and every prop back into the cell, mirrors both into the
## lattice copies and decays the seam pulses. Returns [code]true[/code]
## when the player crossed a boundary, so the host can refresh its readout.
func track(player: NonEuclideanPlayer, delta: float) -> bool:
	var changed := false
	var offset := WrapWorldState.wrap_offset(_cell.to_local(player.global_position), PERIODS)
	if offset != Vector3.ZERO:
		player.request_portal_teleport(Transform3D(Basis.IDENTITY,
			_cell.global_basis * offset), null)
		var seam := _seam_for(offset)
		if not seam.is_empty():
			last_seam = SEAM_NAMES[seam]
			_pulses[seam] = 1.0
			wrap_count += 1
			changed = true
	_cap_player_fall(player)
	for body in props:
		# Carried: the grab keeps it with the player, who does the wrapping.
		if body.freeze:
			continue
		var body_offset := WrapWorldState.wrap_offset(
			_cell.to_local(body.global_position), PERIODS)
		if body_offset != Vector3.ZERO:
			# A pure translation is a rigid mapping: velocities survive the wrap.
			body.request_portal_teleport(Transform3D(Basis.IDENTITY,
				_cell.global_basis * body_offset), null)
			prop_wraps += 1
		_cap_body_fall(body)
	_update_copies(player)
	_decay_pulses(delta)
	return changed


## Camera-only depth fog closes before the lattice edge; the background is the
## haze itself, so the last copies dissolve instead of ending.
func set_active(active: bool, player: NonEuclideanPlayer) -> void:
	var camera := player.get_camera()
	if active:
		if _environment == null:
			_environment = player.get_world_3d().environment.duplicate() as Environment
			_environment.fog_enabled = true
			_environment.fog_mode = Environment.FOG_MODE_DEPTH
			_environment.fog_density = 1.0
			_environment.fog_depth_begin = FOG_BEGIN
			_environment.fog_depth_end = FOG_END
			_environment.fog_sky_affect = 1.0
			_environment.fog_light_color = HAZE
			_environment.fog_light_energy = 1.0
			_environment.background_mode = Environment.BG_COLOR
			_environment.background_color = HAZE
		camera.environment = _environment
	elif camera.environment == _environment:
		camera.environment = null


## Zeroes the counters and returns every prop to its built pose. The host
## re-poses the player onto [member spawn_pose] right after.
func reset() -> void:
	wrap_count = 0
	prop_wraps = 0
	last_seam = ""
	for key in _pulses:
		_pulses[key] = 0.0
		_apply_pulse(key)
	for index in props.size():
		var body := props[index]
		body.global_transform = _prop_poses[index]
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false


## The seam key whose boundary the given wrap [param offset] crossed: the
## offset carries one full negative period per crossed axis. Empty for a fall
## through the shaft, which crosses no seam.
func _seam_for(offset: Vector3) -> String:
	if offset.x < 0.0:
		return "blue"
	if offset.x > 0.0:
		return "orange"
	if offset.z < 0.0:
		return "green"
	if offset.z > 0.0:
		return "measure"
	return ""


func _decay_pulses(delta: float) -> void:
	for key in _pulses:
		if _pulses[key] > 0.0:
			_pulses[key] = maxf(0.0, _pulses[key] - delta * 1.4)
			_apply_pulse(key)


func _apply_pulse(key: String) -> void:
	var material := _seam_materials[key] as StandardMaterial3D
	material.emission_energy_multiplier = _base_emission[key] * (1.0 + 4.0 * _pulses[key])


## The ball and the player seen again in every lattice copy, moving as one:
## what repeats is the same space, not a set of clones. The player's copy wears
## a visor so its heading reads from afar; the centre copy is left out — it is
## the player.
func _build_copies(materials: Dictionary) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = PROP_RADIUS
	sphere.height = PROP_RADIUS * 2.0
	sphere.material = GeometryKit.make_material(PROP_COLOR, 0.05, 0.3)
	_prop_copies = _instance_over_lattice("PropCopies", sphere)
	var body := CapsuleMesh.new()
	body.radius = 0.35
	body.height = 1.8
	body.material = GeometryKit.make_material(Color(0.7, 0.76, 0.82), 0.0, 0.5)
	var visor := BoxMesh.new()
	visor.size = Vector3(0.42, 0.12, 0.12)
	visor.material = materials["blue"]
	var figure := ArrayMesh.new()
	for part in [[body, Vector3.ZERO], [visor, Vector3(0.0, 0.6, -0.3)]]:
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		tool.append_from(part[0], 0, Transform3D(Basis.IDENTITY, part[1]))
		tool.commit(figure)
		figure.surface_set_material(figure.get_surface_count() - 1,
			(part[0] as PrimitiveMesh).material)
	_self_copies = _instance_over_lattice("SelfCopies", figure)


## One instance of [param mesh] per lattice copy, the centre excluded.
func _instance_over_lattice(instance_name: String, mesh: Mesh) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = _lattice_offsets.size()
	for index in _lattice_offsets.size():
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY,
			_lattice_offsets[index] * PERIODS))
	var instance := MultiMeshInstance3D.new()
	instance.name = instance_name
	instance.multimesh = multimesh
	instance.layers = Portal3D.WORLD_LAYER
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cell.add_child(instance)
	return instance


## Followers ride on their original; only the player's heading needs every
## instance rewritten, and only when it changed.
func _update_copies(player: NonEuclideanPlayer) -> void:
	if not props.is_empty():
		_prop_copies.global_position = props[0].global_position
	_self_copies.global_position = player.global_position
	var heading := _cell.global_basis.inverse() * player.global_basis
	if heading.is_equal_approx(_self_basis):
		return
	_self_basis = heading
	for index in _lattice_offsets.size():
		_self_copies.multimesh.set_instance_transform(index, Transform3D(heading,
			_lattice_offsets[index] * PERIODS))


## Glowing pillar and floor ring beside the spawn point: walk straight in any
## direction and this is what you come back to.
func _build_beacon(cell: Node3D, materials: Dictionary) -> void:
	var at := Vector3(6.0, 0.0, 17.0)
	GeometryKit.add_box(cell, at + Vector3(0.0, 1.8, 0.0), Vector3(0.24, 3.6, 0.24),
		materials["corridor_light"], false)
	GeometryKit.add_box(cell, at + Vector3(0.0, 0.015, 0.0), Vector3(1.6, 0.03, 1.6),
		materials["corridor_light"], false)
	GeometryKit.add_label(cell, "HOME\nWALK STRAIGHT — COME BACK HERE",
		at + Vector3(0.0, 4.3, 0.0), 0.0, Color(0.35, 0.9, 1.0), 40)


## Chevron trails from the spawn toward each seam, drawn in the seam's own
## color: following an arrow crosses that seam and proves the loop.
func _build_seam_arrows(cell: Node3D, materials: Dictionary) -> void:
	var start := Vector3(8.0, 0.0, 17.0)
	var half := PERIODS.x * 0.5
	var directions := [
		[Vector3.RIGHT, "blue"], [Vector3.LEFT, "orange"],
		[Vector3.BACK, "green"], [Vector3.FORWARD, "measure"],
	]
	for entry in directions:
		var direction: Vector3 = entry[0]
		var material: Material = materials[entry[1]]
		var yaw := atan2(direction.x, direction.z)
		var perpendicular := Vector3(direction.z, 0.0, -direction.x)
		var seam_distance := half - start.dot(direction)
		var chevrons := mini(int((seam_distance - 3.4) / 2.2), 6)
		for step in chevrons:
			var at := start + direction * (3.4 + 2.2 * float(step))
			for side in [-1.0, 1.0]:
				GeometryKit.add_box(cell, at + Vector3(0.0, 0.015, 0.0)
					- direction * 0.2 + perpendicular * (side * 0.2),
					Vector3(0.55, 0.02, 0.12), material, false,
					Vector3(0.0, yaw + side * PI * 0.25, 0.0))


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
	# slab side so a falling player can read which boundary they passed. Every
	# copy shares the centre cell's owned duplicates, so a seam pulse lights the
	# whole lattice identically — the wrap must not betray itself.
	var trim := 0.32
	for edge in [
		[Vector3(half - trim * 0.5, 0.0, 0.0), Vector3(trim, 0.04, PERIODS.z), "blue"],
		[Vector3(-half + trim * 0.5, 0.0, 0.0), Vector3(trim, 0.04, PERIODS.z), "orange"],
		[Vector3(0.0, 0.0, half - trim * 0.5), Vector3(PERIODS.x, 0.04, trim), "green"],
		[Vector3(0.0, 0.0, -half + trim * 0.5), Vector3(PERIODS.x, 0.04, trim), "measure"],
	]:
		var at: Vector3 = edge[0]
		var size: Vector3 = edge[1]
		var material: Material = _seam_materials[edge[2]]
		GeometryKit.add_box(parent, at + Vector3(0.0, 0.02, 0.0), size, material, false)
		var side := Vector3(at.x, 0.0, at.z).normalized()
		GeometryKit.add_box(parent, Vector3(at.x, -SLAB_THICKNESS * 0.5, at.z)
			+ side * 0.03, Vector3(size.x + 0.06, 0.5, size.z + 0.06), material, false)
	# Light strips under the slab: from the floor below, the slab overhead reads
	# as a lit ceiling instead of melting into the haze.
	for x in [-15.0, -5.0, 5.0, 15.0]:
		GeometryKit.add_box(parent, Vector3(x, -SLAB_THICKNESS - 0.02, 0.0),
			Vector3(0.3, 0.04, PERIODS.z - 1.0), materials["corridor_light"], false)
	# Four columns one full period tall: stacked by the lattice they read as
	# endless pillars through every floor, tied by lit beams overhead.
	for x_sign in [-1.0, 1.0]:
		for z_sign in [-1.0, 1.0]:
			GeometryKit.add_box(parent, Vector3(x_sign * COLUMN_AT, 0.0, z_sign * COLUMN_AT),
				Vector3(COLUMN, PERIODS.y, COLUMN), materials["white"], with_collision)
	var span := COLUMN_AT * 2.0 - COLUMN
	for edge in [-1.0, 1.0]:
		GeometryKit.add_box(parent, Vector3(0.0, BEAM_HEIGHT, edge * COLUMN_AT),
			Vector3(span, 0.8, 0.8), materials["white"], false)
		GeometryKit.add_box(parent, Vector3(edge * COLUMN_AT, BEAM_HEIGHT, 0.0),
			Vector3(0.8, 0.8, span), materials["white"], false)
		GeometryKit.add_box(parent, Vector3(0.0, BEAM_HEIGHT - 0.42, edge * COLUMN_AT),
			Vector3(span, 0.05, 0.24), materials["corridor_light"], false)
		GeometryKit.add_box(parent, Vector3(edge * COLUMN_AT, BEAM_HEIGHT - 0.42, 0.0),
			Vector3(0.24, 0.05, span), materials["corridor_light"], false)


func _build_labels(cell: Node3D) -> void:
	GeometryKit.add_label(cell,
		"WRAP GARDEN\nSPACE REPEATS EVERY 40 M — WALK STRAIGHT TO RETURN\nTHE SHAFT FALLS FOREVER",
		Vector3(0.0, 3.4, 0.0), 0.0, Color(0.35, 0.85, 1.0), 48)
	GeometryKit.add_label(cell, "DROP A BALL IN THE SHAFT\nIT FALLS FOREVER",
		Vector3(0.0, 1.5, SHAFT_INNER * 0.5 + 1.9), 0.0, Color(0.35, 0.85, 1.0), 34)


func _add_prop() -> void:
	var sphere := GeometryKit.add_grip_ball(_cell, Vector3(-4.0, 0.5, 4.0), PROP_RADIUS,
		PROP_COLOR, 1.4)
	sphere.resizes = false
	props.assign([sphere])
	_prop_poses.append(sphere.global_transform)


## The furnished cell merged into one mesh (one surface per material, the
## seam materials shared so a pulse lights every copy) and instanced over the
## whole lattice but the centre, which is the real, colliding cell.
func _build_lattice(materials: Dictionary) -> void:
	var template := Node3D.new()
	_build_block(template, materials, false)
	_build_beacon(template, materials)
	_build_seam_arrows(template, materials)
	var surfaces := {}
	for node in template.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var material := mesh_instance.material_override
		if not surfaces.has(material):
			var tool := SurfaceTool.new()
			tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			surfaces[material] = tool
		var placement := mesh_instance.transform
		var parent := mesh_instance.get_parent()
		while parent != template:
			placement = (parent as Node3D).transform * placement
			parent = parent.get_parent()
		(surfaces[material] as SurfaceTool).append_from(mesh_instance.mesh, 0, placement)
	template.free()
	var merged := ArrayMesh.new()
	for material in surfaces:
		(surfaces[material] as SurfaceTool).commit(merged)
		merged.surface_set_material(merged.get_surface_count() - 1, material)
	_instance_over_lattice("Lattice", merged)


## Labels stay out of the merged lattice; the ring next to the centre carries
## them so the signs read across a seam.
func _build_neighbor_labels() -> void:
	for offset in _neighbor_offsets(1, 0):
		var copy := Node3D.new()
		copy.name = "NeighborLabels%d%d" % [int(offset.x), int(offset.z)]
		copy.position = offset * PERIODS
		_cell.add_child(copy)
		_build_labels(copy)


## Every lattice step within [param rings] periods in X and Z and [param layers]
## in Y, the centre excluded.
func _neighbor_offsets(rings: int, layers: int) -> Array[Vector3]:
	var offsets: Array[Vector3] = []
	for x in range(-rings, rings + 1):
		for y in range(-layers, layers + 1):
			for z in range(-rings, rings + 1):
				if x != 0 or y != 0 or z != 0:
					offsets.append(Vector3(x, y, z))
	return offsets


## One sun for every copy: a directional light shades all cells identically,
## which no set of omni lights placed in a finite lattice can.
func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-58.0), deg_to_rad(28.0), 0.0)
	sun.light_color = Color(1.0, 0.93, 0.82)
	sun.light_energy = 0.85
	sun.light_cull_mask = SUN_LAYER
	sun.shadow_enabled = false
	_cell.add_child(sun)


func _cap_player_fall(player: NonEuclideanPlayer) -> void:
	var fall := -player.velocity.dot(_cell.global_basis.y)
	if fall > TERMINAL_FALL:
		player.velocity += _cell.global_basis.y * (fall - TERMINAL_FALL)


func _cap_body_fall(body: PortalRigidBody3D) -> void:
	var fall := -body.linear_velocity.dot(_cell.global_basis.y)
	if fall > TERMINAL_FALL:
		body.linear_velocity += _cell.global_basis.y * (fall - TERMINAL_FALL)
