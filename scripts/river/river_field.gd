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
var ground_height_image: Image
var ground_rows_m := PackedFloat32Array()
var waterfall: RiverWaterfallConfig


func sample_bed(point: Vector2) -> float:
	return _sample_data(point).r if solver_terrain_image != null else -0.64


func sample_height(point: Vector2, level_m: float) -> float:
	return (_sample_data(point).g if solver_terrain_image != null else point.y * surface_slope) + level_m


func sample_ground_height(point: Vector2) -> float:
	if ground_height_image == null:
		return sample_bed(point)
	if waterfall != null and waterfall.is_vertical() and point.y < waterfall.crest_z_m:
		point.y = minf(point.y, waterfall.crest_z_m - 0.25)
	var last := ground_height_image.get_size() - Vector2i.ONE
	var cell := ((point / domain_m + Vector2.ONE * 0.5) * Vector2(last)).clamp(Vector2.ZERO, Vector2(last))
	if not ground_rows_m.is_empty():
		var upper := ground_rows_m.bsearch(point.y)
		var low_y := 0
		var fraction_y := 0.0
		if upper >= ground_rows_m.size():
			low_y = ground_rows_m.size() - 1
		elif ground_rows_m[upper] == point.y:
			low_y = upper
		elif upper > 0:
			low_y = upper - 1
			fraction_y = clampf((point.y - ground_rows_m[low_y]) / (ground_rows_m[upper] - ground_rows_m[low_y]), 0.0, 1.0)
		cell.y = float(low_y) + fraction_y
	var low := Vector2i(cell.floor())
	var fraction := cell - Vector2(low)
	var a := ground_height_image.get_pixelv(low).r
	var b := ground_height_image.get_pixelv((low + Vector2i.RIGHT).min(last)).r
	var c := ground_height_image.get_pixelv((low + Vector2i.DOWN).min(last)).r
	var d := ground_height_image.get_pixelv((low + Vector2i.ONE).min(last)).r
	return a + (b - a) * fraction.x + (c - a) * fraction.y if fraction.x + fraction.y <= 1.0 \
		else d + (c - d) * (1.0 - fraction.x) + (b - d) * (1.0 - fraction.y)


func sample(point: Vector2, level_m: float) -> Color:
	var wet := smoothstep(0.0, 0.12, sample_height(point, level_m) - sample_bed(point))
	var data := _sample_data(point) if solver_terrain_image != null else Color(-0.64, 0.0, 0.0, -1.0)
	return Color(data.b * wet, data.a * wet, 0.0, wet)


func sample_solver(point: Vector2, _level_m: float) -> Color:
	var data := _sample_data(point) if solver_terrain_image != null else Color(-0.64, 0.0, 0.0, -1.0)
	return Color(data.b, data.a, 0.0, 1.0)


func channel_center_x(_z: float) -> float:
	return 0.0


func channel_half_width(_z: float) -> float:
	return domain_m.x * 0.5


func water_zone(_point: Vector2) -> int:
	return 1


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
	var rows := []
	rows.resize(size.y)
	var task := WorkerThreadPool.add_group_task(func(y: int) -> void:
		var flows := PackedFloat32Array()
		var beds := PackedFloat32Array()
		var points := PackedVector3Array()
		flows.resize(size.x * 4)
		beds.resize(size.x * 2)
		for x in size.x:
			var point := (Vector2(x + 0.5, y + 0.5) / Vector2(size) - Vector2.ONE * 0.5) * domain_m
			var flow := sample(point, level_m)
			flows[x * 4] = flow.r
			flows[x * 4 + 1] = flow.g
			flows[x * 4 + 2] = flow.b
			flows[x * 4 + 3] = flow.a
			beds[x * 2] = sample_bed(point)
			beds[x * 2 + 1] = sample_height(point, level_m)
			if x % 16 == 0 and y % 8 == 0 and flow.a > 0.1:
				points.append(Vector3(point.x, sample_height(point, 0.0), point.y))
		rows[y] = [flows, beds, points], size.y)
	LoadingPump.wait_for_group(task)
	var flow_data := PackedFloat32Array()
	var bed_data := PackedFloat32Array()
	surface_points.clear()
	for row: Array in rows:
		flow_data.append_array(row[0])
		bed_data.append_array(row[1])
		surface_points.append_array(row[2])
	bed_texture = ImageTexture.create_from_image(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGF, bed_data.to_byte_array()))
	return ImageTexture.create_from_image(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAF, flow_data.to_byte_array()))
