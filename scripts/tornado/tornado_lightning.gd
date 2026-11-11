class_name TornadoLightning extends Node3D
## One lightning strike at a time: the branched channel the eye sees and the
## envelope its light pulses with.
##
## Owns: the bolt mesh (world space, whatever this node's transform) and the
## strike envelope. The host decides when and where a strike lands, calls
## strike() then tick() every frame, and feeds flash() to its own lights.
##
## A strike is a few return strokes down one channel, 40-140 ms apart, each a
## sharp peak riding one slower afterglow: the scene flashes, flickers and stays
## lit for most of a second while it fades. The channel is a midpoint-displaced
## stroke with branches peeling off it and crawlers running under the cloud base.
##
##     var lightning := TornadoLightning.new()
##     add_child(lightning)
##     lightning.strike(cloud_point, ground_point, 1.0)
##     lightning.tick(delta)
##     light.light_energy = lightning.flash() * 25.0

const CORE_SHADER := preload("res://shaders/tornado/tornado_bolt_core.gdshader")
const HALO_SHADER := preload("res://shaders/tornado/tornado_bolt_halo.gdshader")
const STROKES := Vector2i(1, 4)
const STROKE_GAP_S := Vector2(0.04, 0.14)
const STROKE_TAU_S := 0.06
const AFTERGLOW_SHARE := 0.5
const AFTERGLOW_TAU_S := 0.4
## The channel holds full for this long after each stroke, then fades.
const CHANNEL_HOLD_S := 0.06
const CHANNEL_TAU_S := 0.1
const TAIL_S := 1.3
## Below this level the opaque core would draw as a dark line.
const CHANNEL_VISIBLE_LEVEL := 0.05
## Channel geometry: subdivision depth, lateral roughness as a share of each
## segment, core width in metres (the shader floors it in pixels).
const CHANNEL_LEVELS := 7
const BRANCH_LEVELS := 5
const ROUGHNESS := 0.2
const CORE_WIDTH_M := 1.2
const HALO_WIDTH_SCALE := 14.0
const BRANCH_CHANCE := 0.07
const MAX_BRANCHES := 12
const CRAWLER_CHANCE := 0.6
## Crawler reach under the cloud base, as a share of the channel height.
const CRAWLER_REACH := Vector2(0.6, 2.2)

var _rng := RandomNumberGenerator.new()
var _age := -1.0
var _strokes := PackedFloat32Array()
var _amplitude := 0.0
var _flash := 0.0
var _mesh_instance := MeshInstance3D.new()
var _core := ShaderMaterial.new()
var _halo := ShaderMaterial.new()


func _init(seed_value: int = 20260731) -> void:
	_rng.seed = seed_value
	_core.shader = CORE_SHADER
	_halo.shader = HALO_SHADER
	# After the raymarched funnel (render_priority 1), so the glow lands on it.
	_halo.render_priority = 2
	_mesh_instance.top_level = true
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mesh_instance.visible = false
	add_child(_mesh_instance)


func set_color(color: Color) -> void:
	_core.set_shader_parameter("bolt_color", color)
	_halo.set_shader_parameter("bolt_color", color)


## Starts a strike from `top` (in the cloud) to `ground`; amplitude 0..1 scales
## how hard it lights the scene, not the channel's own brightness.
func strike(top: Vector3, ground: Vector3, amplitude: float) -> void:
	_amplitude = clampf(amplitude, 0.0, 1.0)
	_strokes = PackedFloat32Array([0.0])
	for i in _rng.randi_range(STROKES.x, STROKES.y) - 1:
		_strokes.append(_strokes[_strokes.size() - 1]
			+ _rng.randf_range(STROKE_GAP_S.x, STROKE_GAP_S.y))
	_age = 0.0
	_flash = _amplitude
	_build_bolt(top, ground)


func tick(delta: float) -> void:
	if _age < 0.0:
		return
	_age += delta
	var stroke := 0.0
	var channel := 0.0
	for start: float in _strokes:
		if _age < start:
			continue
		var since := _age - start
		stroke = maxf(stroke, exp(-since / STROKE_TAU_S))
		channel = maxf(channel, 1.0 if since < CHANNEL_HOLD_S
			else exp(-(since - CHANNEL_HOLD_S) / CHANNEL_TAU_S))
	var afterglow := AFTERGLOW_SHARE * exp(-_age / AFTERGLOW_TAU_S)
	_flash = _amplitude * clampf(stroke * (1.0 - AFTERGLOW_SHARE) + afterglow, 0.0, 1.0)
	if _age > _strokes[_strokes.size() - 1] + TAIL_S:
		_age = -1.0
		_flash = 0.0
		channel = 0.0
	_core.set_shader_parameter("bolt_level", channel)
	_halo.set_shader_parameter("bolt_level", channel)
	_mesh_instance.visible = channel > CHANNEL_VISIBLE_LEVEL


## How hard the strike lights the scene right now, 0..1.
func flash() -> float:
	return _flash


func is_striking() -> bool:
	return _age >= 0.0


func _build_bolt(top: Vector3, ground: Vector3) -> void:
	var segments: Array = []
	var main := _jag(top, ground, CHANNEL_LEVELS)
	_add_path(segments, main, CORE_WIDTH_M, 1.0)
	var height := top.y - ground.y
	var branches := 0
	for i in range(int(main.size() * 0.1), int(main.size() * 0.8)):
		if branches >= MAX_BRANCHES or _rng.randf() > BRANCH_CHANCE:
			continue
		branches += 1
		var along := main[i + 1] - main[i]
		var out := Vector3(_rng.randf_range(-1.0, 1.0), 0.0,
			_rng.randf_range(-1.0, 1.0)).normalized()
		var direction := (along.normalized() * 0.6 + out * 0.8).normalized()
		var length := height * _rng.randf_range(0.08, 0.3) * (1.0 - float(i) / main.size())
		var branch := _jag(main[i], main[i] + direction * length, BRANCH_LEVELS)
		_add_path(segments, branch, CORE_WIDTH_M * 0.45, _rng.randf_range(0.35, 0.6))
	if _rng.randf() < CRAWLER_CHANCE:
		for c in _rng.randi_range(1, 3):
			var angle := _rng.randf_range(0.0, TAU)
			var reach := height * _rng.randf_range(CRAWLER_REACH.x, CRAWLER_REACH.y)
			var end := top + Vector3(cos(angle), 0.0, sin(angle)) * reach \
				+ Vector3(0.0, height * _rng.randf_range(-0.12, 0.02), 0.0)
			var crawler := _jag(top, end, CHANNEL_LEVELS)
			_add_path(segments, crawler, CORE_WIDTH_M * 0.6, _rng.randf_range(0.4, 0.7))
	_mesh_instance.mesh = _ribbons(segments)


## Midpoint displacement: each level splits every segment and pushes the new
## point sideways by a share of the segment's length, so the jag is fractal.
func _jag(from: Vector3, to: Vector3, levels: int) -> PackedVector3Array:
	var points := PackedVector3Array([from, to])
	for level in levels:
		var next := PackedVector3Array([points[0]])
		for i in points.size() - 1:
			var a := points[i]
			var b := points[i + 1]
			var span := b - a
			var axis := span.normalized()
			var side := axis.cross(Vector3.UP if absf(axis.y) < 0.95 else Vector3.RIGHT)
			side = side.normalized().rotated(axis, _rng.randf_range(0.0, TAU))
			next.append((a + b) * 0.5 + side * _rng.randfn(0.0, ROUGHNESS) * span.length())
			next.append(b)
		points = next
	return points


func _add_path(segments: Array, points: PackedVector3Array, width: float,
		intensity: float) -> void:
	for i in points.size() - 1:
		# The stroke thins and dims towards its end, like a branch tip.
		var fade := 1.0 - 0.5 * float(i) / points.size()
		segments.append([points[i], points[i + 1], width * fade, intensity * fade])


## Surface 0 is the core, surface 1 the halo. Each segment is a quad the shader
## turns to the camera: both corners of an end share the end's position, the
## segment direction rides in NORMAL, UV.x is the side (-1/+1), UV.y the
## intensity, UV2 the width and the halo flag, COLOR.r which end.
func _ribbons(segments: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var low := Vector3.INF
	var high := -Vector3.INF
	for halo in [0.0, 1.0]:
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var uv2s := PackedVector2Array()
		var ends := PackedColorArray()
		var indices := PackedInt32Array()
		for segment: Array in segments:
			var a: Vector3 = segment[0]
			var b: Vector3 = segment[1]
			var direction := (b - a).normalized()
			var width: float = segment[2] * (HALO_WIDTH_SCALE if halo > 0.0 else 1.0)
			var base := vertices.size()
			for end in 2:
				var at: Vector3 = a if end == 0 else b
				for side in [-1.0, 1.0]:
					vertices.append(at)
					normals.append(direction)
					uvs.append(Vector2(side, segment[3]))
					uv2s.append(Vector2(width, halo))
					ends.append(Color(float(end), 0.0, 0.0))
				low = low.min(at)
				high = high.max(at)
			indices.append_array(PackedInt32Array([base, base + 1, base + 2,
				base + 1, base + 3, base + 2]))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		arrays[Mesh.ARRAY_COLOR] = ends
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _core)
	mesh.surface_set_material(1, _halo)
	# The shader widens every quad on screen; the box must hold the halo too.
	mesh.custom_aabb = AABB(low, high - low).grow(200.0)
	return mesh
