class_name GpuTimingStore
extends RefCounted
## Thread-safe holder for the latest GPU timing sample.
##
## Solvers parse their RenderingDevice timestamps on the render thread (usually
## via [method GpuTimings.read]) and [method publish] the result; the main
## thread pulls a defensive copy with [method snapshot]. Replaces the per-solver
## [code]_timings[/code] + [code]Mutex[/code] boilerplate.

var _timings: Dictionary = {}
var _mutex := Mutex.new()


## Stores a defensive copy: mutating [param timings] afterwards does not
## affect the stored sample.
func publish(timings: Dictionary) -> void:
	var copy := timings.duplicate()
	_mutex.lock()
	_timings = copy
	_mutex.unlock()


## Defensive copy of the latest published sample; empty until the first publish.
func snapshot() -> Dictionary:
	_mutex.lock()
	var copy := _timings.duplicate()
	_mutex.unlock()
	return copy


func clear() -> void:
	_mutex.lock()
	_timings.clear()
	_mutex.unlock()
