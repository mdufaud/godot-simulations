class_name GpuPreflight
extends RefCounted
## Single entry point for acquiring the RenderingDevice the compute solvers need.
##
## Compute work requires the Forward+ renderer on a real GPU. Under Compatibility,
## under --headless, or on a driver that failed to initialise, there is no
## RenderingDevice and every dispatch silently does nothing, which reads as a black
## screen. Going through here turns that into one explicit error naming the caller.
##
## Solvers call device() from inside RenderingServer.call_on_render_thread();
## controllers call available() before start() to show a message instead of a
## dead viewport.

## Returns the RenderingDevice, or null after reporting why it is missing.
## [param context] identifies the caller, e.g. "OceanSolver".
static func device(context: String) -> RenderingDevice:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		push_error("%s: no RenderingDevice (renderer=%s). GPU compute requires Forward+."
			% [context, renderer_name()])
	return rd


## True when GPU compute can run. Does not log.
static func available() -> bool:
	return RenderingServer.get_rendering_device() != null


static func renderer_name() -> String:
	return str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"))
