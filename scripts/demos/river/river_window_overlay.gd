extends MeshInstance3D

const WIDTH_M := 0.2
const SEGMENT_M := 1.0
const LIVE := Color(0.1, 0.9, 0.25)
const FADING := Color(1.0, 0.72, 0.0)
const STOPPED := Color(1.0, 0.15, 0.1)

var river: RiverSystem
var _strip := ImmediateMesh.new()


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 10
	material_override = material
	mesh = _strip
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(_delta: float) -> void:
	_strip.clear_surfaces()
	if river == null or river.swe == null or not river.swe.active:
		return
	var swe := river.swe
	var color := LIVE if swe.live and swe.blend >= 1.0 else (FADING if swe.live or swe.blend > 0.0 else STOPPED)
	var rect: Rect2 = swe.region_m
	var corners: Array[Vector2] = [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	_strip.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_strip.surface_set_color(color)
	for side in 4:
		var start := corners[side]
		var end := corners[(side + 1) % 4]
		var inward := (rect.get_center() - (start + end) * 0.5).normalized() * WIDTH_M
		var steps := maxi(ceili(start.distance_to(end) / SEGMENT_M), 1)
		for step in steps:
			var a := start.lerp(end, float(step) / steps)
			var b := start.lerp(end, float(step + 1) / steps)
			var quad: Array[Vector2] = [a, b, b + inward, a + inward]
			for index in [0, 1, 2, 0, 2, 3]:
				var point: Vector2 = quad[index]
				_strip.surface_add_vertex(Vector3(point.x, river.field.sample_height(point, river.config.water_level_m) + 0.05, point.y))
	_strip.surface_end()
