class_name ViewportGuard
extends Node
## Saves the host viewport's global render state, and puts it back when it leaves the tree.
##
## Render scaling and MSAA live on the root viewport, which outlives the demo that
## changed them: without this the setting leaks into the main menu and into whatever
## demo is loaded next. Render-time measurement is global the same way, but has no
## engine getter to restore from and nothing ships with it on, so release() always
## turns it back off. Add one as a child, then route every write through the setters
## instead of touching the viewport directly.
##
## [codeblock]
## @onready var _viewport := ViewportGuard.attach(self)
##
## func _on_quality_changed(scale: float) -> void:
##     _viewport.set_render_scale(Viewport.SCALING_3D_MODE_FSR, scale)
## [/codeblock]

## Viewports currently timestamp-measured through any guard. RenderingServer has
## no getter for the flag, so the UI smoke asserts this count returns to zero.
static var measured_viewports := 0

var _viewport: Viewport = null
var _scaling_mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_BILINEAR
var _scaling_scale := 1.0
var _msaa: Viewport.MSAA = Viewport.MSAA_DISABLED
var _taa := false
var _measure_render_time := false


## Creates a guard and parents it to [param host], capturing the state immediately.
static func attach(host: Node) -> ViewportGuard:
	var guard := ViewportGuard.new()
	guard.name = "ViewportGuard"
	host.add_child(guard)
	return guard


func _ready() -> void:
	_viewport = get_viewport()
	if _viewport == null:
		push_error("ViewportGuard: no viewport, global render state will not be restored")
		return
	_scaling_mode = _viewport.scaling_3d_mode
	_scaling_scale = _viewport.scaling_3d_scale
	_msaa = _viewport.msaa_3d
	_taa = _viewport.use_taa


func _exit_tree() -> void:
	release()


## Restores the state captured on entry. Idempotent; called automatically on exit.
func release() -> void:
	if _viewport == null:
		return
	_viewport.scaling_3d_mode = _scaling_mode
	_viewport.scaling_3d_scale = _scaling_scale
	_viewport.msaa_3d = _msaa
	_viewport.use_taa = _taa
	set_measure_render_time(false)


func set_render_scale(mode: Viewport.Scaling3DMode, scale: float) -> void:
	if _viewport == null:
		return
	_viewport.scaling_3d_mode = mode
	_viewport.scaling_3d_scale = scale


## Enables the per-frame timestamp pair the GPU render-time read costs, and
## remembers it so release() can undo exactly this write.
func set_measure_render_time(enabled: bool) -> void:
	if _viewport == null or _measure_render_time == enabled:
		return
	RenderingServer.viewport_set_measure_render_time(_viewport.get_viewport_rid(), enabled)
	_measure_render_time = enabled
	measured_viewports += 1 if enabled else -1


func set_msaa(mode: Viewport.MSAA) -> void:
	if _viewport == null:
		return
	_viewport.msaa_3d = mode


func set_taa(enabled: bool) -> void:
	if _viewport == null:
		return
	_viewport.use_taa = enabled


## Current value, for asserting the demo turned measurement on when it said so.
func measure_render_time() -> bool:
	return _measure_render_time


## Current value, for seeding a UI control with what the viewport actually has.
func msaa() -> Viewport.MSAA:
	return _msaa if _viewport == null else _viewport.msaa_3d


func render_scale() -> float:
	return _scaling_scale if _viewport == null else _viewport.scaling_3d_scale
