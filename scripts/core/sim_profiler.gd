class_name SimProfiler extends RefCounted
## Corner overlay: engine frame time, the viewport's measured GPU time and
## whatever stage lines the demo adds. Off until [method set_enabled] turns it
## on -- measuring the viewport render time costs a timestamp pair per frame.
##
## [codeblock]
## profiler.lines_provider = func() -> PackedStringArray: ...
## profiler.enabled_changed.connect(func(on): solver.profiling = on)
## profiler.build(ui_layer, get_viewport().get_viewport_rid(), ViewportGuard.attach(self))
## # in _process:
## profiler.poll(delta)
## [/codeblock]

## Emitted by [method set_enabled], for the solver-side profiling flag.
signal enabled_changed(on: bool)

const REFRESH_S := 0.25

## Optional [code]func() -> PackedStringArray[/code], appended under the frame
## line. Called at most every [constant REFRESH_S].
var lines_provider := Callable()

var _label: Label
var _viewport_rid: RID
## Set by [method build]; when present, the measurement flag is written through
## the guard so it is disabled again when the demo scene leaves the tree.
var _guard: ViewportGuard = null
var _accum := 0.0


func build(host: Node, viewport_rid: RID, guard: ViewportGuard = null) -> void:
	_viewport_rid = viewport_rid
	_guard = guard
	_label = Label.new()
	_label.position = Vector2(8, 8)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["monospace"])
	_label.add_theme_font_override("font", mono)
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.visible = false
	host.add_child(_label)


func visible() -> bool:
	return _label != null and _label.visible


func set_enabled(on: bool) -> void:
	_label.visible = on
	if _guard != null:
		_guard.set_measure_render_time(on)
	else:
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, on)
	enabled_changed.emit(on)


func poll(delta: float) -> void:
	if not visible():
		return
	_accum += delta
	if _accum < REFRESH_S:
		return
	_accum = 0.0
	var lines := PackedStringArray()
	lines.append("FPS %d  frame %.2f ms" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	if lines_provider.is_valid():
		lines.append_array(lines_provider.call())
	lines.append("viewport GPU %.2f ms" %
		RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid))
	_label.text = "\n".join(lines)
