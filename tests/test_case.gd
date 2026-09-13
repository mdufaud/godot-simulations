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
