extends SceneTree
## Shared plumbing for the SceneTree test runners: failure counting, the PASS/FAIL
## line tests/run_tests.sh greps, and the basis comparison both suites need.

var _failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error(message)


func _basis_error(a: Basis, b: Basis) -> float:
	return maxf(maxf(a.x.distance_to(b.x), a.y.distance_to(b.y)), a.z.distance_to(b.z))


func _finish(suite: String) -> void:
	if _failures == 0:
		print("TEST PASS %s" % suite)
		quit(0)
		return
	printerr("TEST FAIL %s: %d check(s)" % [suite, _failures])
	quit(1)
