extends "res://tests/test_case.gd"

const Field := preload("res://scripts/demos/river/river_landscape.gd")
const Config := preload("res://scripts/river/river_config.gd")


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
	var flood_point := Vector2(8.431, 0.0)
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
	_finish("river_field")


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
