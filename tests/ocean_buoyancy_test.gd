extends "res://tests/test_case.gd"

const BuoyancyMath := preload("res://scripts/ocean/ocean_buoyancy_math.gd")
const BOX_SIZE := Vector3(1.2, 1.2, 1.2)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_clipped_box_volumes()
	_test_rotated_half_immersion()
	_test_translated_immersion()
	_test_water_plane_fit()
	_test_static_draft()
	_test_relative_drag()
	await _test_physical_body_contract()
	_finish("ocean_buoyancy")


func _test_clipped_box_volumes() -> void:
	var transform := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var dry := BuoyancyMath.clipped_box(BOX_SIZE, transform,
		Vector3(0.0, -0.61, 0.0), Vector3.UP)
	var half := BuoyancyMath.clipped_box(BOX_SIZE, transform,
		Vector3.ZERO, Vector3.UP)
	var full := BuoyancyMath.clipped_box(BOX_SIZE, transform,
		Vector3(0.0, 0.61, 0.0), Vector3.UP)
	_check(dry.volume <= 0.000001, "dry box has displaced volume")
	_check(absf(half.volume - 0.864) <= 0.00001,
		"half-immersed box volume %.6f != 0.864" % half.volume)
	_check(half.centroid.distance_to(Vector3(0.0, -0.3, 0.0)) <= 0.00001,
		"half-immersed centroid is not 0.3 m below center")
	_check(absf(full.volume - 1.728) <= 0.00001,
		"fully immersed box volume %.6f != 1.728" % full.volume)
	_check(full.centroid.distance_to(Vector3.ZERO) <= 0.00001,
		"fully immersed centroid differs from box center")


func _test_rotated_half_immersion() -> void:
	var angle := PI / 6.0
	var transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.0, angle)),
		Vector3.ZERO)
	var clipped := BuoyancyMath.clipped_box(BOX_SIZE, transform,
		Vector3.ZERO, Vector3.UP)
	var half_extent := BOX_SIZE.x * 0.5
	var tangent := tan(angle)
	var expected_center_y := half_extent * 0.5 * (
		-2.0 * sin(angle) * tangent / 3.0
		+ cos(angle) * (tangent * tangent / 3.0 - 1.0))
	_check(absf(clipped.volume - 0.864) <= 0.00001,
		"rotated center-plane cut does not split volume equally")
	_check(absf(clipped.centroid.y - expected_center_y) <= 0.00001,
		"rotated clipped centroid y %.6f != %.6f"
		% [clipped.centroid.y, expected_center_y])


func _test_translated_immersion() -> void:
	var basis := Basis.from_euler(Vector3(0.24, -0.35, 0.47))
	var normal := Vector3(0.15, 1.0, -0.2).normalized()
	var reference := BuoyancyMath.clipped_box(BOX_SIZE,
		Transform3D(basis, Vector3.ZERO), Vector3.ZERO, normal)
	for origin in [Vector3(90.0, 1.3, 35.0), Vector3(10000.0, 1.3, -11000.0)]:
		var translated := BuoyancyMath.clipped_box(BOX_SIZE,
			Transform3D(basis, origin), origin, normal)
		_check(absf(translated.volume - reference.volume) <= 0.00001,
			"displaced volume depends on world position: %.6f != %.6f" % [
				translated.volume, reference.volume])
		_check(translated.centroid.distance_to(origin + reference.centroid) <= 0.002,
			"center of buoyancy loses precision away from the world origin")


func _test_water_plane_fit() -> void:
	var slope_x := 0.2
	var slope_z := -0.1
	var positions := PackedVector3Array([
		Vector3(-0.45, 0.0, -0.45), Vector3(0.45, 0.0, -0.45),
		Vector3(-0.45, 0.0, 0.45), Vector3(0.45, 0.0, 0.45),
	])
	var depths := PackedFloat32Array()
	for position in positions:
		depths.append(2.0 + slope_x * position.x + slope_z * position.z)
	var mask := PackedByteArray([1, 1, 1, 0])
	var result: Dictionary = BuoyancyMath.water_plane(positions, depths, mask,
		Vector3(-slope_x, 1.0, -slope_z))
	var expected_normal := Vector3(-slope_x, 1.0, -slope_z).normalized()
	var expected_offset: float = expected_normal.dot(Vector3(0.0, 2.0, 0.0))
	_check(not result.is_empty(), "valid probes did not define a water plane")
	if not result.is_empty():
		_check(absf(result.normal.dot(result.point) - expected_offset) <= 0.00001,
		"fitted plane offset does not match the sloped query depths")
	var rejected: Dictionary = BuoyancyMath.water_plane(positions, depths,
		PackedByteArray([0, 0, 0, 0]), Vector3.UP)
	_check(rejected.is_empty(), "plane fit accepted a batch with no valid probes")


func _test_static_draft() -> void:
	var body_density := 450.0
	var water_density := 1025.0
	var expected_fraction := body_density / water_density
	var lower := -BOX_SIZE.y * 0.5
	var upper := BOX_SIZE.y * 0.5
	for _iteration in 28:
		var waterline := (lower + upper) * 0.5
		var result := BuoyancyMath.clipped_box(BOX_SIZE,
			Transform3D(Basis.IDENTITY, Vector3.ZERO),
			Vector3(0.0, waterline, 0.0), Vector3.UP)
		if result.volume / 1.728 < expected_fraction:
			lower = waterline
		else:
			upper = waterline
	var final_waterline := (lower + upper) * 0.5
	var final_clip: Dictionary = BuoyancyMath.clipped_box(BOX_SIZE,
		Transform3D(Basis.IDENTITY, Vector3.ZERO),
		Vector3(0.0, final_waterline, 0.0), Vector3.UP)
	var displaced: float = final_clip.volume
	var buoyancy := water_density * 9.81 * displaced
	var weight := body_density * 1.728 * 9.81
	_check(absf(displaced / 1.728 - expected_fraction) <= 0.00001,
		"450/1025 density ratio has incorrect static draft")
	_check(absf(buoyancy - weight) <= 0.001,
		"static displaced-water support does not balance crate weight")


func _test_relative_drag() -> void:
	var still := BuoyancyMath.quadratic_drag(Vector3.ZERO, 1.0, 1025.0, 0.8)
	var relative := Vector3(2.0, 0.0, -3.0)
	var drag := BuoyancyMath.quadratic_drag(relative, 1.4, 1025.0, 0.8)
	_check(still == Vector3.ZERO, "zero relative flow creates drag")
	_check(drag.dot(relative) < 0.0,
		"drag does not oppose body-relative water velocity")
	var impulse := -Vector3(drag.x, 0.0, drag.z) / 60.0
	_check(impulse.dot(Vector3(relative.x, 0.0, relative.z)) > 0.0,
		"opposite horizontal water impulse does not follow body drag")


func _test_physical_body_contract() -> void:
	var crate := OceanBuoy.new()
	_check(not crate.physical_model_enabled, "physical buoyancy must default off")
	root.add_child(crate)
	await process_frame
	_check(absf(crate.mass - 30.0) <= 0.0001,
		"P1 buoy mass changed while physical mode is disabled")
	crate.physical_model_enabled = true
	_check(absf(crate.mass - 777.6) <= 0.0001,
		"physical buoy mass does not match 450 kg/m3 and 1.728 m3")
	var positions := PackedVector3Array()
	for probe in OceanBuoy.PROBES:
		positions.append(crate.global_transform * probe)
	var half_depths := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var validity := PackedByteArray([1, 1, 1, 1])
	var flow := PackedVector3Array([
		Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
	])
	crate.apply_water_frame(half_depths, Vector3.UP, validity, flow, positions, 1.0 / 30.0)
	var expected_support := 1025.0 * 9.81 * 0.864
	_check(absf(crate.last_support_force_n.y - expected_support) <= 0.01,
		"physical body support force does not use exact clipped volume")
	_check(crate.last_drag_force_n.x > 0.0 and crate.last_water_impulse.x < 0.0,
		"body drag or opposite water reaction has the wrong sign")
	_check(absf(crate.last_water_impulse.x
		+ crate.last_drag_force_n.x / 30.0) <= 0.0001,
		"water reaction impulse did not use the supplied physics delta")
	var dry_depths := PackedFloat32Array([-0.61, -0.61, -0.61, -0.61])
	crate.apply_water_frame(dry_depths, Vector3.UP, validity, flow, positions, 1.0 / 30.0)
	_check(crate.last_support_force_n == Vector3.ZERO
		and crate.last_drag_force_n == Vector3.ZERO
		and crate.last_water_impulse == Vector3.ZERO,
		"dry physical frame retained buoyancy or drag feedback")
	crate.queue_free()
	await process_frame
