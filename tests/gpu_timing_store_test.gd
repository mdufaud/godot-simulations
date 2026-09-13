extends "res://tests/test_case.gd"
## CPU checks for GpuTimingStore: defensive copies in and out, snapshot
## replacement and clear. No RenderingDevice involved.


func _init() -> void:
	var store := GpuTimingStore.new()

	_check(store.snapshot().is_empty(), "fresh store must snapshot empty")

	var sample := {"spectrum": 1.5, "fft": 2.0, "total": 4.0}
	store.publish(sample)
	_check(store.snapshot() == sample, "snapshot must equal the published sample")

	# Defensive copy on publish: mutating the caller's dictionary must not
	# leak into the stored sample.
	sample["spectrum"] = 99.0
	_check(absf(float(store.snapshot()["spectrum"]) - 1.5) < 0.0001,
			"publish must store a defensive copy")

	# Defensive copy on snapshot: mutating the returned dictionary must not
	# leak into the store.
	var grabbed := store.snapshot()
	grabbed["spectrum"] = 42.0
	grabbed["injected"] = 1.0
	_check(absf(float(store.snapshot()["spectrum"]) - 1.5) < 0.0001
			and not store.snapshot().has("injected"),
			"snapshot must hand out a defensive copy")

	# A second publish replaces the previous sample wholesale.
	store.publish({"total": 7.0})
	var second := store.snapshot()
	_check(second.size() == 1 and absf(float(second["total"]) - 7.0) < 0.0001,
			"publish must replace the previous sample")

	# Clear empties the store again.
	store.clear()
	_check(store.snapshot().is_empty(), "clear must empty the store")

	_finish("gpu_timing_store")
