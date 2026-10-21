extends SceneTree
## Shared plumbing for the SceneTree test runners: failure counting, the PASS/FAIL
## line tests/run_tests.sh greps, the basis comparison, and the numeric
## comparison helpers the ambient-fluid suites share.

var _failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error(message)


## Root size for a suite that pins one: `size`, unless the runner shrinks
## windows for software Vulkan (PHYSICS_TEST_RESOLUTION=WxH, virtual_display.sh).
func _root_size(size: Vector2i) -> Vector2i:
	var parts := OS.get_environment("PHYSICS_TEST_RESOLUTION").split("x")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return Vector2i(parts[0].to_int(), parts[1].to_int())
	return size


## Waits until `seconds` of simulated time have elapsed, whatever the frame rate.
func _sim_seconds(seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds - 0.000001:
		await process_frame
		elapsed += root.get_process_delta_time()


func _basis_error(a: Basis, b: Basis) -> float:
	return maxf(maxf(a.x.distance_to(b.x), a.y.distance_to(b.y)), a.z.distance_to(b.z))


func _wrench_norm(wrench: PackedFloat64Array) -> float:
	var sum := 0.0
	for value in wrench:
		sum += value * value
	return sqrt(sum)


func _array_near(a: PackedFloat64Array, b: PackedFloat64Array, tolerance: float) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if absf(a[index] - b[index]) > tolerance:
			return false
	return true


func _matrix_near_transpose(matrix: PackedFloat64Array, tolerance: float) -> bool:
	for row in 6:
		for col in 6:
			if absf(matrix[row * 6 + col] - matrix[col * 6 + row]) > tolerance:
				return false
	return true


func _finish(suite: String) -> void:
	if _failures == 0:
		print("TEST PASS %s" % suite)
		quit(0)
		return
	printerr("TEST FAIL %s: %d check(s)" % [suite, _failures])
	quit(1)
