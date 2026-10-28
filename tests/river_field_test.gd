extends "res://tests/test_case.gd"

const Field := preload("res://scripts/demos/river/river_landscape.gd")
const Config := preload("res://scripts/river/river_config.gd")
const WaterfallField := preload("res://scripts/demos/river/river_waterfall_landscape.gd")
const WaterfallSystem := preload("res://scripts/river/river_waterfall_system.gd")
const Solver := preload("res://scripts/river/river_swe_solver.gd")


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
	_check_waterfall_banks()
	_check_fall_sampling()
	_finish("river_field")


func _check_waterfall_banks() -> void:
	for angle: float in [20.0, 50.0, 89.9, 90.0]:
		var field := WaterfallField.new(angle)
		var contained := true
		for z in range(-22, 23):
			contained = contained and field.sample_bed(Vector2(WaterfallField.WIDTH_M * 0.5, z)) >= field.water_height(Vector2(0.0, z), 0.65)
		_check(contained, "Waterfall banks must contain the highest water level at the channel edge")


func _check_fall_sampling() -> void:
	_check(absf(WaterfallSystem.breakup_length_m(0.1) - 2.871) < 0.001 and absf(WaterfallSystem.breakup_length_m(0.25) - 3.850) < 0.001,
		"Nappe break-up length must follow Horeni's 6 q^0.32")
	_check(is_equal_approx(WaterfallSystem.breakup_length_m(2.0), WaterfallSystem.breakup_length_m(0.25)) and WaterfallSystem.breakup_length_m(0.0) == 0.0,
		"Nappe break-up length must hold at its measured range instead of extrapolating")
	_check(WaterfallSystem.aeration_strength(0.1, 0.0) < WaterfallSystem.aeration_strength(0.5, 0.0)
		and WaterfallSystem.aeration_strength(0.5, 0.0) < WaterfallSystem.aeration_strength(0.5, 0.5)
		and WaterfallSystem.aeration_strength(1.0, 1.0) == 1.0,
		"A calm or thin sheet must stay less aerated than a turbulent torrent, up to fully aerated")


func _check_waterfall_field() -> void:
	for angle: float in [20.0, 35.0, 50.0, 65.0, 80.0, 89.0, 89.9, 90.0]:
		var field := WaterfallField.new(angle)
		var crest := WaterfallField.CREST_Z_M
		_check(field.spills and field.reflection_pools, "Waterfall field must spill and mirror each pool")
		_check(field.domain_m == Vector2(24.0, 48.0), "Waterfall field must use its bounded solver domain")
		_check(absf(field.run_m() - (0.0 if field.is_vertical() else WaterfallField.HEIGHT_M / tan(deg_to_rad(angle)))) < 0.00001,
			"Waterfall run must follow its slope")
		_check(field.water_zone(Vector2(0.0, crest + 1.0)) == WaterfallField.ZONE_UPPER_POOL
			and field.water_zone(Vector2(0.0, crest - field.run_m() - 1.0)) == WaterfallField.ZONE_LOWER_POOL,
			"Waterfall field must locate the pools on either side of the fall")
		_check(field.water_zone(Vector2(10.0, crest)) == WaterfallField.ZONE_DRY,
			"Waterfall bank must be dry outside the channel")
		var lower := field.sample(Vector2(0.0, crest - field.run_m() - 1.0), 0.0)
		var upper := field.sample(Vector2(0.0, crest + 1.0), 0.0)
		var transition := field.sample(Vector2(0.0, crest - field.run_m() * 0.5), 0.0)
		_check(Vector4(lower.r, lower.g, lower.b, lower.a).is_finite()
			and Vector4(upper.r, upper.g, upper.b, upper.a).is_finite()
			and Vector4(transition.r, transition.g, transition.b, transition.a).is_finite(),
			"Waterfall samples must remain finite in both pools and through the transition")
		if not field.is_vertical():
			_check(field.water_zone(Vector2(0.0, crest - field.run_m() * 0.5)) == WaterfallField.ZONE_RAMP,
				"Angled waterfall must expose a sloped transition zone")
		# Across one solver cell, as the spill rule sees it: the cliff leaves the height field, a 50 degree ramp flows down it.
		var steepest := 0.0
		for z in range(0, 96):
			var point := Vector2(0.0, crest - field.run_m() - 0.5 + z * 0.0625)
			steepest = maxf(steepest, absf(field.sample_bed(point + Vector2(0.0, Solver.CELL_M * 0.5)) - field.sample_bed(point - Vector2(0.0, Solver.CELL_M * 0.5))) / Solver.CELL_M)
		if angle >= 90.0:
			_check(steepest > Solver.SPILL_SLOPE, "A vertical crest must spill")
		elif angle <= 50.0:
			_check(steepest < Solver.SPILL_SLOPE, "A ramp of 50 degrees or less must stay on the height field")


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
