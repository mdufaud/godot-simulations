extends "res://tests/test_case.gd"

const FireSolver = preload("res://scripts/fire/fire_gpu_solver.gd")

## Lot I: the display proxy box grows the instant the readback bounds demand
## it, but only shrinks after a quiet delay and then at a bounded per-face
## speed — a cut through the plume is a visible defect, a stale margin is not.
## Pure policy on an AABB timeline, so it tests headless against the solver's
## own DisplayBoxHysteresis class.

const MS := 16 # one update per simulated frame, 60 Hz


func _advance(hyst, boxes: Array, start_msec: int) -> Array:
	var out: Array = []
	var t := start_msec
	for target in boxes:
		out.append(hyst.update(target, t))
		t += MS
	return out


func _initialize() -> void:
	# First target is adopted outright, however odd.
	var hyst = FireSolver.DisplayBoxHysteresis.new()
	var first := AABB(Vector3(-2, 0, -2), Vector3(4, 6, 4))
	var adopted := hyst.update(first, 0)
	if adopted != first:
		_check(false, "first target was not adopted")

	# Growth and translation are immediate at any time.
	hyst = FireSolver.DisplayBoxHysteresis.new()
	hyst.update(first, 0)
	var grown := AABB(Vector3(-3, -1, -3), Vector3(7, 9, 7))
	if hyst.update(grown, MS) != grown:
		_check(false, "growth was not adopted immediately")
	var moved := AABB(Vector3(1, 0, 1), Vector3(4, 6, 4))
	if hyst.update(moved, 2 * MS) != moved:
		_check(false, "translation was not adopted immediately")

	# A pure shrink waits out the delay, then closes at <= speed * dt per face
	# and converges on the target instead of stalling above it.
	hyst = FireSolver.DisplayBoxHysteresis.new()
	var big := AABB(Vector3(-4, 0, -4), Vector3(8, 12, 8))
	var small := AABB(Vector3(-1, 2, -1), Vector3(2, 6, 2))
	hyst.update(big, 0)
	var t := MS
	var delayed_boxes := _advance(hyst, [small, small, small, small], t)
	# ~64 ms in: still the full box.
	if delayed_boxes[3] != big:
		_check(false, "shrink happened before the delay elapsed")
	t += 4 * MS
	var last := big
	var max_step := 0.0
	var converged := false
	for _frame in 600:
		var next: AABB = hyst.update(small, t)
		max_step = maxf(max_step, (big.position - next.position).length())
		var face_step: float = maxf(
			maxf(absf(last.position.x - next.position.x), absf(last.end.x - next.end.x)),
			maxf(absf(last.position.y - next.position.y), absf(last.end.y - next.end.y)))
		if face_step > FireSolver.DisplayBoxHysteresis.SHRINK_SPEED * 0.25 + 1e-4:
			_check(false, "shrink moved a face %.3f m in one 60 Hz frame" % face_step)
		last = next
		if next.is_equal_approx(small):
			converged = true
			break
		t += MS
	if not converged:
		_check(false, "shrinking box never reached its target")
	if max_step > (big.size - small.size).length():
		_check(false, "shrink overshot its target")

	# A growth inside the delay window re-arms it: quiet time is measured from
	# the last grow, not from the first shrink request.
	hyst = FireSolver.DisplayBoxHysteresis.new()
	hyst.update(big, 0)
	hyst.update(small, 100)
	# Just before the delay expires, the bounds grow again; the shrink that was
	# pending must never land afterwards while the box only shrinks.
	var rearm := AABB(Vector3(-5, 0, -5), Vector3(9, 12, 9))
	if hyst.update(rearm, 100 + int(FireSolver.DisplayBoxHysteresis.SHRINK_DELAY * 1000) - 32) != rearm:
		_check(false, "late growth was not adopted immediately")
	var after := hyst.update(small, 100 + int(FireSolver.DisplayBoxHysteresis.SHRINK_DELAY * 1000) + 500)
	if not after.encloses(rearm) or not after.encloses(small):
		_check(false, "post-rearm shrink lost the grown extent")

	_finish("fire_display_box")
