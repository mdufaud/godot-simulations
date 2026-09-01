extends "res://tests/test_case.gd"
## Unit tests for apparent_scale.gd plus the static grip contracts — pure math,
## no scene, no GPU. Runs under --headless in a couple of seconds.

const ApparentScaleScript := preload("res://scripts/non_euclidean/apparent_scale.gd")
const GripBallScript := preload("res://scripts/non_euclidean/grip_ball.gd")
const GripRoomScript := preload("res://scripts/demos/non_euclidean/exhibit_grip_room.gd")


func _initialize() -> void:
	_test_angular_invariance()
	_test_commit_bounds()
	_test_mass_law()
	_test_room_contract()
	_finish("apparent_scale")


func _test_angular_invariance() -> void:
	var r_grab := 0.42
	var d_grab := 1.3
	var ratio := r_grab / d_grab
	for distance in [0.9, 1.3, 2.0, 3.2, 14.0, 40.0]:
		var radius := ApparentScaleScript.hold_radius(r_grab, d_grab, float(distance))
		_check(is_finite(radius), "hold radius left the finite range at %.1f m" % distance)
		_check(absf(radius / float(distance) - ratio) <= 0.000001,
			"angular size not preserved at %.1f m" % distance)


func _test_commit_bounds() -> void:
	var r_min := GripBallScript.RADIUS_MIN
	var r_max := GripBallScript.RADIUS_MAX
	_check(is_equal_approx(ApparentScaleScript.commit_radius(0.01, r_min, r_max), r_min),
		"radius below the bound was not clamped")
	_check(is_equal_approx(ApparentScaleScript.commit_radius(9.0, r_min, r_max), r_max),
		"radius above the bound was not clamped")
	_check(is_equal_approx(ApparentScaleScript.commit_radius(1.1, r_min, r_max), 1.1),
		"in-bounds radius changed")
	_check(ApparentScaleScript.commit_radius(2.5, r_min, r_max) == GripBallScript.RADIUS_MAX,
		"giant resolve must stop at RADIUS_MAX")


func _test_mass_law() -> void:
	_check(is_equal_approx(ApparentScaleScript.mass_for(0.5, 0.5, 2.0), 2.0),
		"base radius mass is not the base mass")
	_check(is_equal_approx(ApparentScaleScript.mass_for(1.0, 0.5, 2.0), 16.0),
		"mass law is not cubic")
	_check(ApparentScaleScript.mass_for(0.25, 0.5, 2.0) < 2.0,
		"shrunken ball heavier than the base mass")
	for radius in [0.2, 1.0, 2.0]:
		var mass := ApparentScaleScript.mass_for(float(radius), 0.35, 1.2)
		_check(is_finite(mass) and mass > 0.0, "mass left the positive finite range")


func _test_room_contract() -> void:
	_check(GripRoomScript.FAR_OPENING.x >= GripBallScript.RADIUS_MAX * 2.0,
		"far opening is too narrow for the widest committable ball")
	_check(GripRoomScript.FAR_OPENING.y >= GripBallScript.RADIUS_MAX * 2.0,
		"far opening is too low for the widest committable ball")
	_check(GripBallScript.RADIUS_MIN > 0.0, "radius lower bound vanished")
