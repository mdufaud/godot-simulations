class_name ExhibitGrowingCorridor extends RefCounted
## Exhibit — the accordion corridor: a straight corridor drawn folded.
##
## Collision is one straight, endless corridor in real coordinates. Every
## corridor mesh goes through the stretch shader, which leaves the [constant
## RIGID] metres around the player untouched and folds the rest
## ([method GrowingCorridorState.apparent_offset]): from the start the far arches
## look packed like a closed bellows; walking toward them opens the folds while
## the bellows itself widens ([method GrowingCorridorState.stretch]), so the far
## door recedes as you go. Nothing is built or swapped in view: the arches are
## one MultiMesh in real coordinates, refilled as the player passes them, and
## the folded tail they reach is thinner than a millimetre per arch.
##
## The host drives it: [method track] every physics frame while active,
## [method set_active] on case switch, [method reset] on reset.

const STRETCH_SHADER := preload("res://shaders/non_euclidean/corridor_stretch.gdshader")

## Real length of one arch module, metres.
const MODULE := 3.0
## Clear width and height of the corridor.
const SIZE := Vector2(3.2, 3.4)
## Span around the player drawn at true scale, metres.
const RIGID := 6.0
const STRETCH_BASE := 8.0
const STRETCH_RATE := 0.6
const STRETCH_MAX := 80.0
## Modules reach this many bellows lengths past the rigid span: the fold leaves
## exp(-7) of an arch there, under a millimetre.
const REACH := 7.0
## Real distance past the rigid span that still gets omni lights; beyond it the
## folded ceiling strips carry the light.
const LIGHT_REACH := 30.0
const LIGHT_EVERY := 2
const LIGHT_ENERGY := 1.4
## Real metres between wall distance markers; markers fold with the wall.
const MARKER_SPACING := 12.0
const MARKER_REACH := 3.0
const CORRIDOR_FOG := 0.018
## Real collision length; nobody walks 20 km.
const LENGTH := 20000.0

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Real depth reached into the corridor, metres.
var walked := 0.0
## Drawn distance from the player to the far door, metres.
var far_distance := RIGID + STRETCH_BASE

var _cell: Node3D
var _materials: Dictionary = {}
var _multimesh: MultiMesh
var _window := Vector2i(-1, -1)
var _lights: Array[OmniLight3D] = []
var _markers: Array[Label3D] = []
var _start_door: Node3D
var _far_door: Node3D
var _environment: Environment


func build(cells: Node3D, materials: Dictionary) -> void:
	_cell = Node3D.new()
	_cell.name = "GrowingCorridor"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(250.0, 0.0, -450.0))
	cells.add_child(_cell)
	for key in ["tile", "concrete", "metal", "corridor_light", "measure"]:
		_materials[key] = _stretch_material(materials[key], _cell.global_transform)
	_build_collision()
	_build_modules()
	_start_door = _build_start_door(materials)
	_far_door = _build_far_door(materials)
	var light_count := int(ceil(2.0 * (RIGID + LIGHT_REACH) / (MODULE * LIGHT_EVERY))) + 1
	for index in light_count:
		_lights.append(GeometryKit.add_omni_light(_cell, Vector3.ZERO,
			Color(0.55, 0.8, 1.0), LIGHT_ENERGY, 9.0, false))
	var marker_count := int(ceil(2.0 * (RIGID + MARKER_REACH * STRETCH_MAX) / MARKER_SPACING)) + 1
	for index in marker_count:
		var marker := GeometryKit.add_label(_cell, "", Vector3.ZERO, PI * 0.5,
			Color(0.45, 0.85, 1.0), 64)
		_markers.append(marker)
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.9, -2.2))
	_update(0.0)


## Folds the drawing around the player's depth. Returns [code]true[/code] when
## the HUD readout changed.
func track(player: NonEuclideanPlayer) -> bool:
	var before := Vector2i(int(walked), int(far_distance))
	_update(-_cell.to_local(player.global_position).z)
	return before != Vector2i(int(walked), int(far_distance))


func set_active(active: bool, player: NonEuclideanPlayer) -> void:
	var camera := player.get_camera()
	if active:
		if _environment == null:
			_environment = player.get_world_3d().environment.duplicate() as Environment
			_environment.fog_enabled = true
			_environment.fog_density = CORRIDOR_FOG
		camera.environment = _environment
		_update(-_cell.to_local(player.global_position).z)
	elif camera.environment == _environment:
		camera.environment = null


## Zeroes the readout. The drawing is a pure function of the player's depth, so
## the host re-posing the player onto [member spawn_pose] restores it.
func reset() -> void:
	_update(0.0)


func _update(depth: float) -> void:
	walked = maxf(depth, 0.0)
	var stretch := GrowingCorridorState.stretch(depth, STRETCH_BASE, STRETCH_RATE, STRETCH_MAX)
	far_distance = RIGID + stretch
	for material in _materials.values():
		(material as ShaderMaterial).set_shader_parameter("player_depth", depth)
		(material as ShaderMaterial).set_shader_parameter("stretch_length", stretch)
	_fill_modules(depth, stretch)
	_place_lights(depth, stretch)
	_place_markers(depth, stretch)
	_start_door.position.z = -_drawn_depth(0.0, depth, stretch)
	_far_door.position.z = -(depth + far_distance)


## Drawn depth of the real depth [param real] for a player at [param depth].
func _drawn_depth(real: float, depth: float, stretch: float) -> float:
	return depth + GrowingCorridorState.apparent_offset(real - depth, RIGID, stretch)


func _fill_modules(depth: float, stretch: float) -> void:
	var reach := RIGID + REACH * stretch
	var first := maxi(0, floori((depth - reach) / MODULE))
	var last := floori((depth + reach) / MODULE)
	var window := Vector2i(first, mini(last - first + 1, _multimesh.instance_count))
	if window == _window:
		return
	_window = window
	for index in window.y:
		_multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY,
			Vector3(0.0, 0.0, -float(first + index) * MODULE)))
	_multimesh.visible_instance_count = window.y


## Omni lights ride the arches near the player at their drawn depth; their
## energy follows the local fold so a packed stretch is not overlit.
func _place_lights(depth: float, stretch: float) -> void:
	var step := MODULE * LIGHT_EVERY
	var first := floori((depth - RIGID - LIGHT_REACH) / step)
	for index in _lights.size():
		var light := _lights[index]
		var real := (float(first + index) + 0.5) * step
		var offset := real - depth
		var fade := 1.0 - smoothstep(RIGID + LIGHT_REACH * 0.6, RIGID + LIGHT_REACH, absf(offset))
		light.visible = real > 0.0 and fade > 0.0
		light.position = Vector3(0.0, SIZE.y - 0.6, -_drawn_depth(real, depth, stretch))
		light.light_energy = LIGHT_ENERGY * fade \
			* GrowingCorridorState.apparent_slope(offset, RIGID, stretch)


## Real distances printed on the left wall, squeezed with the wall they sit on:
## the tell that the far arches are metres apart, not centimetres.
func _place_markers(depth: float, stretch: float) -> void:
	var reach := RIGID + MARKER_REACH * stretch
	var first := maxi(1, ceili((depth - reach) / MARKER_SPACING))
	for index in _markers.size():
		var marker := _markers[index]
		var real := float(first + index) * MARKER_SPACING
		# Half a module off the arches, so no post hides the number.
		var drawn_at := real + MODULE * 0.5
		var offset := drawn_at - depth
		marker.visible = absf(offset) <= reach
		if not marker.visible:
			continue
		var text := "%d m" % int(real)
		if marker.text != text:
			marker.text = text
		marker.position = Vector3(-SIZE.x * 0.5 + 0.02, 1.7, -_drawn_depth(drawn_at, depth, stretch))
		marker.scale.x = GrowingCorridorState.apparent_slope(offset, RIGID, stretch)


## Straight, real-scale collision: floor, walls flush with the arch posts and
## the start door. No mesh — what the player sees is the folded MultiMesh.
func _build_collision() -> void:
	var half_length := LENGTH * 0.5
	GeometryKit.add_collision_box(_cell, Vector3(0.0, -0.15, -half_length + 1.0),
		Vector3(SIZE.x + 1.0, 0.3, LENGTH + 2.0))
	for side in [-1.0, 1.0]:
		GeometryKit.add_collision_box(_cell, Vector3(side * (SIZE.x * 0.5 - 0.05),
			SIZE.y * 0.5, -half_length), Vector3(0.5, SIZE.y, LENGTH))
	GeometryKit.add_collision_box(_cell, Vector3(0.0, SIZE.y * 0.5, 0.25),
		Vector3(SIZE.x + 1.0, SIZE.y, 0.5))


func _build_modules() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.mesh = _build_module_mesh()
	_multimesh.instance_count = int(ceil(2.0 * (RIGID + REACH * STRETCH_MAX) / MODULE)) + 2
	_multimesh.visible_instance_count = 0
	var instance := MultiMeshInstance3D.new()
	instance.name = "Arches"
	instance.multimesh = _multimesh
	instance.layers = Portal3D.WORLD_LAYER
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The fold only pulls vertices toward the player, so the real span bounds them.
	instance.custom_aabb = AABB(Vector3(-SIZE.x, -1.0, -LENGTH), Vector3(SIZE.x * 2.0,
		SIZE.y + 2.0, LENGTH + 1.0))
	_cell.add_child(instance)


## One module, its arch at depth 0 and its slab running one [constant MODULE]
## deeper. One surface per material, so the whole corridor is five draws.
func _build_module_mesh() -> ArrayMesh:
	var w := SIZE.x
	var h := SIZE.y
	var m := MODULE
	var parts := {
		"tile": [[Vector3(0.0, -0.15, -m * 0.5), Vector3(w + 1.0, 0.3, m)]],
		"concrete": [
			[Vector3(-w * 0.5 - 0.25, h * 0.5, -m * 0.5), Vector3(0.5, h, m)],
			[Vector3(w * 0.5 + 0.25, h * 0.5, -m * 0.5), Vector3(0.5, h, m)],
			[Vector3(0.0, h + 0.25, -m * 0.5), Vector3(w + 1.0, 0.5, m)],
		],
		"metal": [
			[Vector3(-w * 0.5 + 0.15, h * 0.5, 0.0), Vector3(0.3, h, 0.3)],
			[Vector3(w * 0.5 - 0.15, h * 0.5, 0.0), Vector3(0.3, h, 0.3)],
			[Vector3(0.0, h - 0.15, 0.0), Vector3(w - 0.6, 0.3, 0.3)],
		],
		"corridor_light": [[Vector3(0.0, h - 0.03, -m * 0.5), Vector3(w * 0.16, 0.05, m * 0.55)]],
		# Lit inner rim of every arch: folded far away, the rims pack into the
		# glowing pleats of the bellows.
		"measure": [
			[Vector3(0.0, 0.012, 0.0), Vector3(w - 0.6, 0.02, 0.08)],
			[Vector3(-w * 0.5 + 0.315, h * 0.5, 0.0), Vector3(0.03, h - 0.3, 0.12)],
			[Vector3(w * 0.5 - 0.315, h * 0.5, 0.0), Vector3(0.03, h - 0.3, 0.12)],
			[Vector3(0.0, h - 0.315, 0.0), Vector3(w - 0.66, 0.03, 0.12)],
		],
	}
	var mesh := ArrayMesh.new()
	for key in parts:
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		for part in parts[key]:
			var box := BoxMesh.new()
			box.size = part[1]
			tool.append_from(box, 0, Transform3D(Basis.IDENTITY, part[0]))
		tool.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _materials[key])
	return mesh


## The same palette entry, drawn through the fold. Textures map in real
## corridor coordinates, so tiles squeeze with the floor they print on.
func _stretch_material(source: StandardMaterial3D, frame: Transform3D) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = STRETCH_SHADER
	material.set_shader_parameter("albedo", source.albedo_color)
	if source.albedo_texture != null:
		material.set_shader_parameter("albedo_texture", source.albedo_texture)
	material.set_shader_parameter("roughness", source.roughness)
	material.set_shader_parameter("metallic", source.metallic)
	if source.emission_enabled:
		material.set_shader_parameter("emission", source.emission)
		material.set_shader_parameter("emission_energy", source.emission_energy_multiplier)
	material.set_shader_parameter("world_to_corridor", Projection(frame.affine_inverse()))
	material.set_shader_parameter("corridor_to_world", Projection(frame))
	material.set_shader_parameter("rigid", RIGID)
	return material


## Sealed doorway at the corridor start, drawn at its folded depth: the reset
## goes through the menu, this door only marks where it lands.
func _build_start_door(materials: Dictionary) -> Node3D:
	var door := Node3D.new()
	door.name = "StartDoor"
	_cell.add_child(door)
	GeometryKit.add_box(door, Vector3(0.0, SIZE.y * 0.5, 0.25),
		Vector3(SIZE.x + 1.0, SIZE.y + 0.5, 0.5), materials["concrete"], false)
	GeometryKit.add_box(door, Vector3(-0.95, 1.4, -0.04), Vector3(0.3, 2.8, 0.08),
		materials["blue"], false)
	GeometryKit.add_box(door, Vector3(0.95, 1.4, -0.04), Vector3(0.3, 2.8, 0.08),
		materials["blue"], false)
	GeometryKit.add_box(door, Vector3(0.0, 2.95, -0.04), Vector3(2.2, 0.3, 0.08),
		materials["blue"], false)
	GeometryKit.add_label(door, "⟲ RESET POINT\nWALK FORWARD — THE CORRIDOR UNFOLDS",
		Vector3(0.0, 1.6, -0.05), PI, Color(0.35, 0.9, 1.0), 40)
	return door


## The far door, always at the end of the bellows: a lit doorway in a dark
## wall, drawn where the folded corridor closes.
func _build_far_door(materials: Dictionary) -> Node3D:
	var door := Node3D.new()
	door.name = "FarDoor"
	_cell.add_child(door)
	GeometryKit.add_box(door, Vector3(0.0, SIZE.y * 0.5, -0.25),
		Vector3(SIZE.x + 1.0, SIZE.y + 1.0, 0.5), materials["concrete_dark"], false)
	GeometryKit.add_box(door, Vector3(0.0, 1.3, 0.05), Vector3(1.1, 2.6, 0.08),
		materials["corridor_light"], false)
	return door
