extends "res://tests/test_case.gd"

const Field := preload("res://scripts/demos/river/river_landscape.gd")
const Config := preload("res://scripts/river/river_config.gd")
const WaterfallConfig := preload("res://scripts/river/river_waterfall_config.gd")
const WaterfallField := preload("res://scripts/demos/river/river_waterfall_landscape.gd")


func _initialize() -> void:
	var field := Field.new()
	for z in range(-40, 41, 5):
		var point := Vector2(Field.center_x(z), z)
		var flow := field.sample(point, 0.06)
		_check(flow.g < -0.2 and flow.a > 0.99, "Center current must run downstream")
		_check(field.sample(point + Vector2(18.0, 0.0), 0.06).a == 0.0, "Dry bank must have no current")
	for index in 3:
		var z: float = Field.drop_center(0.0, index)
		_check(Field.channel_height(z + 2.0) - Field.channel_height(z - 2.0) > 0.3,
			"Each rapid must have a downhill surface drop")
		_check(field.sample(Vector2(0.0, z - 0.7), 0.06).b > 0.1,
			"Drop foam must originate at the downstream transition")
	var center := Vector2(Field.center_x(0.0), 0.0)
	field.obstacles.append(Vector4(center.x, center.y, 1.0, 1.5))
	_check(field.sample(center, 0.06).a == 0.0, "Rock interior must not contain water")
	for side: float in [-1.0, 1.0]:
		var point := center + Vector2(side * 1.05, 0.5)
		var flow := field.sample(point, 0.06)
		var normal := (point - center).normalized()
		var radial := absf(Vector2(flow.r, flow.g).dot(normal))
		_check(radial < 0.3, "Current must deflect around the rock")
		_check(flow.g < 0.0, "Deflected current must still run downstream")
	field.obstacles[0] = Vector4(center.x, center.y, 1.0, 0.1)
	_check(field.sample(center, 0.54).a > 0.9, "Submerged obstacle must stop masking the water")
	var flood_point := Vector2(6.2, 0.0)
	_check(field.sample(flood_point, 0.0).a == 0.0 and field.sample(flood_point, 0.54).a > 0.5,
		"Flood regression point must become wet after raising the water level")
	var dry_drive := field.sample_solver(flood_point, 0.0)
	var flood_drive := field.sample_solver(flood_point, 0.54)
	_check(dry_drive.g < -0.1 and Vector2(dry_drive.r, dry_drive.g).is_equal_approx(Vector2(flood_drive.r, flood_drive.g)),
		"Solver driving current must not depend on shoreline wetness or water level")
	_check_prepared_field()
	for z: float in [-40.0, 0.0, 40.0]:
		var plane := Field.water_plane(0.54, z)
		_check(absf(plane.distance_to(Vector3(0.0, Field.water_height(Vector2(0.0, z), 0.54), z))) < 0.00001,
			"Reflection plane must follow the local surface level")
	var config := Config.new()
	_check(config.validate().is_empty(), "Default config must be valid")
	config.speed_m_s = NAN
	_check(not config.validate().is_empty(), "Invalid speed must be rejected")
	for path: String in ["calm", "natural_flow", "rapids", "high_water"]:
		var preset := load("res://resources/river/presets/%s.tres" % path) as RiverConfig
		_check(preset != null and preset.validate().is_empty(), "Preset must be valid: " + path)
	_check_waterfall_field()
	_check_triangle_ground()
	_check_waterfall_curtain()
	_finish("river_field")


func _check_waterfall_curtain() -> void:
	for angle: float in [20.0, 50.0, 89.9, 90.0]:
		var field := WaterfallField.new(angle)
		var profile: WaterfallConfig = field.waterfall
		var contained := true
		for z in range(-22, 23):
			contained = contained and field.sample_bed(Vector2(profile.width_m * 0.5, z)) >= field.water_height(Vector2(0.0, z), 0.65)
		_check(contained, "Waterfall banks must contain the highest water level at the channel edge")
		for level: float in [-0.2, 0.06, 0.65]:
			for speed: float in [0.22, 1.7, 4.0]:
				var water := Config.new()
				water.water_level_m = level
				water.speed_m_s = speed
				var curtain := RiverWaterfallCurtain.new()
				curtain.ground = field.sample_bed
				curtain.crest_from = Vector3(-profile.width_m * 0.5, 0.0, profile.crest_z_m)
				curtain.crest_to = Vector3(profile.width_m * 0.5, 0.0, profile.crest_z_m)
				curtain.surface_height_m = profile.height_m + level
				curtain.speed_m_s = speed
				curtain.landing_level_m = level
				curtain.columns = 8
				curtain.rows = 48
				var arrays := curtain.build().surface_get_arrays(0)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var traits: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
				var stride := curtain.columns + 3
				var above := true
				var tucked := true
				for index in vertices.size():
					if traits[index * 4 + 3] > 1.5 or traits[index * 4 + 3] < -0.5:
						continue
					var point := vertices[index]
					var ground := field.sample_bed(Vector2(point.x, point.z))
					var slot := index % stride
					if slot > 0 and slot < stride - 1 and point.y > level and traits[index * 4] > 0.5:
						above = above and point.y >= ground - 0.001
					elif (slot == 0 or slot == stride - 1) and point.z >= profile.crest_z_m:
						tucked = tucked and point.y <= ground
				_check(vertices.size() > 0 and above,
					"Waterfall curtain must stay above the bed at %.1f deg, level %.2f, speed %.2f" % [angle, level, speed])
				_check(tucked,
					"Waterfall curtain edges must sink into the banks at %.1f deg, level %.2f, speed %.2f" % [angle, level, speed])


func _check_triangle_ground() -> void:
	var field := RiverField.new()
	field.domain_m = Vector2(2.0, 2.0)
	field.ground_height_image = Image.create(2, 2, false, Image.FORMAT_RGBAF)
	field.ground_height_image.set_pixel(0, 0, Color(0.0, 0.0, 0.0))
	field.ground_height_image.set_pixel(1, 0, Color(1.0, 0.0, 0.0))
	field.ground_height_image.set_pixel(0, 1, Color(4.0, 0.0, 0.0))
	field.ground_height_image.set_pixel(1, 1, Color(9.0, 0.0, 0.0))
	_check(is_equal_approx(field.sample_ground_height(Vector2.ZERO), 2.5)
		and is_equal_approx(field.sample_ground_height(Vector2(0.5, 0.5)), 5.75),
		"Ground sampling must follow the rendered triangle diagonal rather than a bilinear saddle")
	field.ground_rows_m = PackedFloat32Array([-1.0, 0.9, 1.0])
	field.ground_height_image = Image.create(2, 3, false, Image.FORMAT_RGBAF)
	for y in 3:
		for x in 2:
			field.ground_height_image.set_pixel(x, y, Color(float(y * 4 + x), field.ground_rows_m[y], 0.0, 1.0))
	_check(absf(field.sample_ground_height(Vector2(0.0, 0.95)) - 6.5) < 0.00001,
		"Adaptive ground sampling must interpolate the actual Z rows rather than assuming uniform spacing")


func _check_waterfall_field() -> void:
	var config := WaterfallConfig.new()
	_check(is_equal_approx(config.run_m(), 0.0) and is_equal_approx(config.length_m(), 6.0),
		"Vertical waterfall must have no horizontal run and retain its fall length")
	_check(config.normal().is_equal_approx(Vector3.FORWARD)
		and config.tangent().is_equal_approx(Vector3(0.0, -1.0, 0.0)),
		"Vertical waterfall must expose perpendicular surface axes")
	config.angle_degrees = 50.0
	_check(absf(config.run_m() - config.height_m / tan(deg_to_rad(50.0))) < 0.00001
		and absf(config.length_m() - config.height_m / sin(deg_to_rad(50.0))) < 0.00001,
		"Angled waterfall run and length must follow its configured slope")
	_check(absf(config.normal().length() - 1.0) < 0.00001
		and absf(config.tangent().length() - 1.0) < 0.00001
		and absf(config.normal().dot(config.tangent())) < 0.00001,
		"Waterfall surface normal and tangent must remain orthonormal")
	for angle: float in [20.0, 35.0, 50.0, 65.0, 80.0, 89.0, 89.9, 90.0]:
		var field := WaterfallField.new(angle)
		var waterfall: WaterfallConfig = field.waterfall
		_check(waterfall.validate().is_empty(), "Waterfall configuration must accept intermediate angles")
		_check(field.domain_m == Vector2(24.0, 48.0), "Waterfall field must use its bounded solver domain")
		_check(field.water_zone(Vector2(0.0, waterfall.crest_z_m + 1.0)) == WaterfallField.ZONE_UPPER_POOL
			and field.water_zone(Vector2(0.0, waterfall.crest_z_m - waterfall.run_m() - 1.0)) == WaterfallField.ZONE_LOWER_POOL,
			"Waterfall field must locate the pools on either side of the fall")
		_check(field.water_zone(Vector2(10.0, waterfall.crest_z_m)) == WaterfallField.ZONE_DRY,
			"Waterfall bank must be dry outside the channel")
		var lower := field.sample(Vector2(0.0, waterfall.crest_z_m - waterfall.run_m() - 1.0), 0.0)
		var upper := field.sample(Vector2(0.0, waterfall.crest_z_m + 1.0), 0.0)
		var transition := field.sample(Vector2(0.0, (waterfall.crest_z_m + waterfall.crest_z_m - waterfall.run_m()) * 0.5), 0.0)
		_check(Vector4(lower.r, lower.g, lower.b, lower.a).is_finite()
			and Vector4(upper.r, upper.g, upper.b, upper.a).is_finite()
			and Vector4(transition.r, transition.g, transition.b, transition.a).is_finite(),
			"Waterfall samples must remain finite in both pools and through the transition")
		if waterfall.is_vertical():
			_check(field.water_zone(Vector2(0.0, waterfall.crest_z_m)) == WaterfallField.ZONE_DRY,
				"Vertical waterfall must leave a dry gap at the crest")
		else:
			_check(field.water_zone(Vector2(0.0, waterfall.crest_z_m - waterfall.run_m() * 0.5)) == WaterfallField.ZONE_RAMP,
				"Angled waterfall must expose a sloped transition zone")
			var normal := waterfall.normal()
			var base := Vector3(0.0, waterfall.height_m - 0.65, waterfall.crest_z_m) + waterfall.tangent() * waterfall.length_m() * 0.45
			var body = preload("res://scripts/river/river_buoyant_body.gd").new()
			body._contact_field = field
			_check(body._contact_is_current(2, base + normal * 0.1, base + normal * 0.2,
				normal, -0.1, 0.2, 0.4, Basis.IDENTITY),
				"Film contacts must remain valid when the film thickness extends past a steep ramp's horizontal footprint")
			body.free()


func _check_prepared_field() -> void:
	var field := RiverField.new()
	field.domain_m = Vector2(2.0, 2.0)
	field.solver_terrain_image = Image.create(2, 2, false, Image.FORMAT_RGBAF)
	for y in 2:
		for x in 2:
			var value := float((y * 2 + x) * 2)
			field.solver_terrain_image.set_pixel(x, y, Color(value, value + 0.06, value + 1.0, -value - 1.0))
	var points := PackedVector2Array([Vector2(-0.5, -0.5), Vector2(0.0, -0.5), Vector2.ZERO,
		Vector2(0.5, 0.5), Vector2(-1.0, -1.0), Vector2(1.0, 1.0)])
	var beds := PackedFloat32Array([0.0, 1.0, 3.0, 6.0, 0.0, 6.0])
	for index in points.size():
		var point := points[index]
		_check(absf(field.sample_bed(point) - beds[index]) < 0.00001,
			"Prepared field must interpolate texel centers and clamp edge samples")
		_check(absf(field.sample_height(point, 0.0) - beds[index] - 0.06) < 0.00001,
			"Prepared field height must use the same bilinear sampling as its bed")
		var drive := field.sample_solver(point, 0.0)
		_check(absf(drive.r - beds[index] - 1.0) < 0.00001 and absf(drive.g + beds[index] + 1.0) < 0.00001,
			"Prepared solver current must preserve raw image velocity channels")
	var flow := field.sample(Vector2.ZERO, 0.0)
	_check(absf(flow.r - 2.0) < 0.0001 and absf(flow.g + 2.0) < 0.0001,
		"Guided current must apply the shallow wet fade exactly once")
	field.origin_m = Vector2(120.0, -40.0)
	for index in points.size():
		_check(absf(field.sample_bed(points[index] + field.origin_m) - beds[index]) < 0.00001,
			"Prepared field must sample the same texels around a moved domain origin")
	_check(field.domain_rect() == Rect2(Vector2(119.0, -41.0), Vector2(2.0, 2.0)),
		"Domain rectangle must be centred on the origin")
	field.flow_image = Image.create(4, 4, false, Image.FORMAT_RGBAF)
	field.flow_image.fill(Color(0.25, -0.5, 0.0, 1.0))
	field.bed_image = Image.create(4, 4, false, Image.FORMAT_RGBF)
	field.bed_image.fill(Color(-0.3, 0.1, 1.0))
	var baked := field.bake(0.0, Vector2i(64, 64))
	_check(baked.get_size() == Vector2(4, 4) and field.bed_texture.get_size() == Vector2(4, 4)
		and baked.get_image().get_pixel(1, 2).is_equal_approx(Color(0.25, -0.5, 0.0, 1.0)),
		"Prepared flow and bed images must be uploaded as given, without sampling")
