class_name ExhibitGrowingCorridor extends RefCounted
## Exhibit — a corridor that keeps growing as the player walks it.
##
## Segments are indexed absolutely and built at [code]BASE * s_i[/code] with
## [code]s_i = min(GROWTH^i, MAX_SCALE)[/code] — dimensions go through the
## builders ([method GeometryKit.add_box] [param size]), never a node [code]scale[/code],
## so collision follows for free. A rolling window keeps the current segment, one
## behind it and [constant SEGMENTS_AHEAD] ahead; the swap happens outside the
## player's segment on both sides, so no frame is ever without floor. When the
## segment two behind falls out of the window, the boundary it shared with the
## survivor is closed with a cap wall (loop-seal motif): turning around leads to
## a labelled dead end instead of a hole into recycled space.
##
## The host drives it: [method track] every physics frame while active,
## [method set_active] on case switch, [method reset] on reset.

const SEGMENTS_AHEAD := 4
const GROWTH := 1.7
const MAX_SCALE := 8.0
const BASE := Vector3(3.0, 3.0, 8.0)
## The built window reaches ~420 m ahead at steady state, so the camera far
## plane stretches while this exhibit is active and goes back on leave.
const DEPTH_FAR := 500.0
## Exhibit-local fog: strong enough that the deepest built segments (never
## closer than ~190 m with SEGMENTS_AHEAD = 4) are fully veiled, so a freshly
## built segment or the jumping backdrop never pops into view. Restored on
## leave.
const CORRIDOR_FOG := 0.02

## Where the player starts, in world space. Valid after [method build].
var spawn_pose: Transform3D
## Segments crossed so far, forward and back.
var crossing_count := 0
## Perceived distance: real steps weighted by the local segment scale. Monotone.
var virtual_distance := 0.0
## Index of the segment the player currently stands in.
var current_index := 0

var _cell: Node3D
var _materials: Dictionary
var _segments: Dictionary = {}
var _cum: Array[float] = [0.0]
var _floor_index := 0
var _previous_depth := 0.0
var _cell_states: Array = []
var _original_far := -1.0
var _original_fog := -1.0


func build(cells: Node3D, materials: Dictionary) -> void:
	_materials = materials
	_cell = Node3D.new()
	_cell.name = "GrowingCorridor"
	_cell.transform = Transform3D(Basis.IDENTITY, Vector3(250.0, 0.0, -450.0))
	cells.add_child(_cell)
	_reset_segments()
	spawn_pose = _cell.global_transform * Transform3D(Basis.IDENTITY,
		Vector3(0.0, 0.9, -2.2))


## Detects the segment the player stands in, weighs their forward steps into the
## virtual distance and rebuilds the window on threshold crossings. Returns
## [code]true[/code] when the HUD readout changed.
func track(player: NonEuclideanPlayer) -> bool:
	var changed := false
	var depth := -_cell.to_local(player.global_position).z
	var index := _segment_index_at(depth)
	var step := depth - _previous_depth
	_previous_depth = depth
	if step > 0.0:
		virtual_distance = GrowingCorridorState.advance(virtual_distance, step,
			GrowingCorridorState.segment_scale(index, GROWTH, MAX_SCALE))
		changed = true
	if index != current_index:
		_enter_segment(index)
		changed = true
	return changed


func set_active(active: bool, player: NonEuclideanPlayer) -> void:
	var camera := player.get_camera()
	var environment := player.get_world_3d().environment
	if camera != null:
		if active:
			if _original_far < 0.0:
				_original_far = camera.far
			camera.far = DEPTH_FAR
		elif _original_far >= 0.0:
			camera.far = _original_far
	if environment != null:
		if active:
			if _original_fog < 0.0:
				_original_fog = environment.fog_density
			environment.fog_density = CORRIDOR_FOG
		elif _original_fog >= 0.0:
			environment.fog_density = _original_fog
			_original_fog = -1.0
	if active:
		_previous_depth = -_cell.to_local(player.global_position).z


## Rebuilds the whole corridor at scale 1 and zeroes the counters. The host
## re-poses the player onto [member spawn_pose] right after, and the coincident
## old geometry only outlives the frame.
func reset() -> void:
	_reset_segments()


func _reset_segments() -> void:
	for node in _segments.values():
		node.queue_free()
	_segments.clear()
	_cum = [0.0]
	_floor_index = 0
	current_index = 0
	_previous_depth = 0.0
	virtual_distance = 0.0
	crossing_count = 0
	_cell_states = []
	for index in SEGMENTS_AHEAD + 1:
		_build_segment(index)
	_update_backdrop()


func _enter_segment(index: int) -> void:
	var direction := GrowingCorridorState.Entered.FORWARD \
		if index > current_index else GrowingCorridorState.Entered.BACKWARD
	_cell_states = GrowingCorridorState.next_state(_cell_states, index, direction)
	current_index = index
	crossing_count += 1
	_ensure_window()


## Window [code][max(_floor_index, current - 1) .. current + SEGMENTS_AHEAD][/code].
## Missing indices are built, indices below are recycled. By construction the
## player's own segment is never built or freed here: it entered an already
## built segment, and only segments two or more behind lose their node.
func _ensure_window() -> void:
	var low := maxi(_floor_index, current_index - 1)
	for index in range(low, current_index + SEGMENTS_AHEAD + 1):
		if not _segments.has(index):
			_build_segment(index)
	var obsolete: Array[int] = []
	for index in _segments.keys():
		if int(index) < low:
			obsolete.append(int(index))
	obsolete.sort()
	for index in obsolete:
		_free_segment(index)
	_update_backdrop()


## The deepest segment carries a backdrop wall, so the window's open end reads as
## distant depth instead of a hole into the background. It jumps one segment
## deeper on every crossing — always several segments and 190+ m away, deep in
## the exhibit fog where the jump cannot be seen.
func _update_backdrop() -> void:
	var high := current_index + SEGMENTS_AHEAD
	for index in _segments.keys():
		var node := _segments[index] as Node3D
		var backdrop := node.get_node_or_null("FarBackdrop") as Node3D
		if int(index) == high:
			if backdrop == null:
				_build_backdrop(node, _segment_size(int(index)))
		elif backdrop != null:
			backdrop.queue_free()


func _build_backdrop(node: Node3D, size: Vector3) -> void:
	var backdrop := Node3D.new()
	backdrop.name = "FarBackdrop"
	node.add_child(backdrop)
	GeometryKit.add_box(backdrop, Vector3(0.0, size.y * 0.5, -size.z * 0.5 - 0.25),
		Vector3(size.x + 1.0, size.y + 1.0, 0.5), _materials["concrete_dark"], false)
	# A lit slit standing clear of the corridor-facing wall face, so the far end
	# reads as a distant glowing doorway instead of a hole. Coplanar with the
	# wall it would z-fight, visible at some distances only.
	GeometryKit.add_box(backdrop, Vector3(0.0, size.y * 0.55, -size.z * 0.5 + 0.05),
		Vector3(size.x * 0.18, size.y * 0.7, 0.08), _materials["corridor_light"], false)


func _free_segment(index: int) -> void:
	# Loop-seal motif: close the boundary of the surviving segment behind the
	# recycled one, so turning around shows a wall, never the recycled gap.
	_add_recycle_cap(index + 1)
	_segments[index].queue_free()
	_segments.erase(index)
	_floor_index = maxi(_floor_index, index + 1)


func _segment_size(index: int) -> Vector3:
	return BASE * GrowingCorridorState.segment_scale(index, GROWTH, MAX_SCALE)


func _ensure_cum(index: int) -> void:
	while _cum.size() <= index:
		_cum.append(_cum[_cum.size() - 1] + _segment_size(_cum.size() - 1).z)


## Depth (distance walked into the corridor) of the boundary the player crossed
## last, clamped to the live window.
func _segment_index_at(depth: float) -> int:
	_ensure_cum(current_index + SEGMENTS_AHEAD + 1)
	var index := current_index
	var highest := _cum.size() - 2
	while index < highest and depth >= _cum[index + 1]:
		index += 1
	while index > _floor_index and depth < _cum[index]:
		index -= 1
	return index


func _build_segment(index: int) -> void:
	_ensure_cum(index + 1)
	var size := _segment_size(index)
	var scale := GrowingCorridorState.segment_scale(index, GROWTH, MAX_SCALE)
	var node := Node3D.new()
	node.name = "Segment%02d" % index
	node.position = Vector3(0.0, 0.0, -(_cum[index] + size.z * 0.5))
	_cell.add_child(node)
	GeometryKit.add_box(node, Vector3(0.0, -0.15, 0.0),
		Vector3(size.x, 0.3, size.z), _materials["tile"])
	GeometryKit.add_box(node, Vector3(-size.x * 0.5 - 0.25, size.y * 0.5, 0.0),
		Vector3(0.5, size.y, size.z), _materials["concrete"])
	GeometryKit.add_box(node, Vector3(size.x * 0.5 + 0.25, size.y * 0.5, 0.0),
		Vector3(0.5, size.y, size.z), _materials["concrete"])
	GeometryKit.add_box(node, Vector3(0.0, size.y + 0.25, 0.0),
		Vector3(size.x, 0.5, size.z), _materials["concrete"])
	# Light follows size: one emissive strip plus an omni whose energy and reach
	# grow with the segment, so the bigger cells stay readable.
	GeometryKit.add_box(node, Vector3(0.0, size.y + 0.02, 0.0),
		Vector3(size.x * 0.22, 0.08, size.z * 0.72), _materials["corridor_light"], false)
	GeometryKit.add_omni_light(node, Vector3(0.0, size.y * 0.55, 0.0),
		Color(0.55, 0.8, 1.0), 1.2 + 0.85 * scale, 8.0 * scale, false)
	GeometryKit.add_box(node, Vector3(0.0, 0.03, size.z * 0.5 - 0.7),
		Vector3(size.x, 0.05, 0.1), _materials["measure"], false)
	GeometryKit.add_label(node, "SEGMENT %02d · %.1f × %.1f × %.1f m"
		% [index, size.x, size.y, size.z],
		Vector3(0.0, size.y * 0.62, size.z * 0.5 - 0.35), 0.0,
		Color(0.45, 0.85, 1.0), 40)
	if index == 0:
		_build_reset_door(node, size)
	_segments[index] = node


## Sealed doorway at the corridor start: the reset goes through the menu, this
## door only marks where it lands.
func _build_reset_door(node: Node3D, size: Vector3) -> void:
	GeometryKit.add_box(node, Vector3(0.0, size.y * 0.5, size.z * 0.5 + 0.25),
		Vector3(size.x, size.y, 0.5), _materials["concrete"])
	GeometryKit.add_box(node, Vector3(-0.95, 1.7, size.z * 0.5 + 0.04),
		Vector3(0.4, 3.4, 0.16), _materials["blue"], false)
	GeometryKit.add_box(node, Vector3(0.95, 1.7, size.z * 0.5 + 0.04),
		Vector3(0.4, 3.4, 0.16), _materials["blue"], false)
	GeometryKit.add_box(node, Vector3(0.0, 3.6, size.z * 0.5 + 0.04),
		Vector3(2.3, 0.4, 0.16), _materials["blue"], false)
	GeometryKit.add_collision_box(node, Vector3(0.0, 1.75, size.z * 0.5 + 0.12),
		Vector3(1.5, 3.5, 0.4))
	GeometryKit.add_label(node, "⟲ RESET POINT\nWALK FORWARD — THE CORRIDOR KEEPS GROWING",
		Vector3(0.0, 4.4, size.z * 0.5 + 0.05), 0.0, Color(0.35, 0.9, 1.0), 46)


func _add_recycle_cap(index: int) -> void:
	if not _segments.has(index):
		return
	var node := _segments[index] as Node3D
	var size := _segment_size(index)
	GeometryKit.add_box(node, Vector3(0.0, size.y * 0.5, size.z * 0.5 + 0.25),
		Vector3(size.x + 1.0, size.y + 0.5, 0.5), _materials["concrete_dark"])
	GeometryKit.add_label(node, "⟲ RECYCLED\nTHE SPACE BEHIND NO LONGER EXISTS",
		Vector3(0.0, size.y * 0.72, size.z * 0.5 + 0.52), PI, Color(1.0, 0.55, 0.25), 40)
