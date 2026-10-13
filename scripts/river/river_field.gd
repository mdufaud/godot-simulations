class_name RiverField extends RefCounted

var domain_m := Vector2(72.0, 160.0)
var surface_slope := 0.0
var reflection_anchors_m := Vector4.ZERO
var terrace_heights_m := Vector4.ZERO
var obstacles := PackedVector4Array()
var obstacle_meshes: Array[MeshInstance3D] = []
var bed_texture: ImageTexture
var surface_points := PackedVector3Array()
var solver_terrain_image: Image


func sample_bed(point: Vector2) -> float:
	return _sample_data(point).r if solver_terrain_image != null else -0.64


func sample_height(point: Vector2, level_m: float) -> float:
	return (_sample_data(point).g if solver_terrain_image != null else point.y * surface_slope) + level_m


func sample(point: Vector2, level_m: float) -> Color:
	var wet := smoothstep(0.0, 0.12, sample_height(point, level_m) - sample_bed(point))
	var data := _sample_data(point) if solver_terrain_image != null else Color(-0.64, 0.0, 0.0, -1.0)
	return Color(data.b * wet, data.a * wet, 0.0, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	var data := _sample_data(point) if solver_terrain_image != null else Color(-0.64, 0.0, 0.0, -1.0)
	return Color(data.b, data.a, 0.0, 1.0)


func _sample_data(point: Vector2) -> Color:
	var size := solver_terrain_image.get_size()
	var cell := (point / domain_m + Vector2(0.5, 0.5)) * Vector2(size) - Vector2.ONE * 0.5
	var low := Vector2i(cell.floor())
	var fraction := cell - Vector2(low)
	var last := size - Vector2i.ONE
	var a := solver_terrain_image.get_pixelv(low.clamp(Vector2i.ZERO, last))
	var b := solver_terrain_image.get_pixelv((low + Vector2i(1, 0)).clamp(Vector2i.ZERO, last))
	var c := solver_terrain_image.get_pixelv((low + Vector2i(0, 1)).clamp(Vector2i.ZERO, last))
	var d := solver_terrain_image.get_pixelv((low + Vector2i.ONE).clamp(Vector2i.ZERO, last))
	return a.lerp(b, fraction.x).lerp(c.lerp(d, fraction.x), fraction.y)


func reflection_plane(level_m: float, anchor_z_m: float) -> Plane:
	var normal := Vector3(0.0, 1.0, -surface_slope).normalized()
	var height := sample_height(Vector2(0.0, anchor_z_m), level_m) - anchor_z_m * surface_slope
	return Plane(normal, height / sqrt(1.0 + surface_slope * surface_slope))


func bake(level_m: float, size: Vector2i = Vector2i(384, 512)) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	var bed := Image.create(size.x, size.y, false, Image.FORMAT_RGF)
	surface_points.clear()
	for y in size.y:
		for x in size.x:
			var point := (Vector2(x + 0.5, y + 0.5) / Vector2(size) - Vector2.ONE * 0.5) * domain_m
			var flow := sample(point, level_m)
			image.set_pixel(x, y, flow)
			bed.set_pixel(x, y, Color(sample_bed(point), sample_height(point, level_m), 0.0))
			if x % 16 == 0 and y % 8 == 0 and flow.a > 0.1:
				surface_points.append(Vector3(point.x, sample_height(point, 0.0), point.y))
	bed_texture = ImageTexture.create_from_image(bed)
	return ImageTexture.create_from_image(image)
