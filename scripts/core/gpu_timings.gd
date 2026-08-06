class_name GpuTimings
extends RefCounted
## Parses a RenderingDevice timestamp chain into per-stage milliseconds.
##
## Solvers bracket their dispatches with capture_timestamp(prefix + "start") and
## capture_timestamp(prefix + "end"), and mark stage boundaries in between. Each
## marker closes the segment opened by the previous one; a name repeated across
## substeps sums. Timestamps are captured in nanoseconds and lag one to two frames.
##
## Call from the render thread, after the frame whose timestamps you want to read.

## Returns {stage_name: milliseconds, "total": milliseconds}, empty when the chain
## is absent. With [param include_post], the span between the last stage marker and
## "end" is reported as "post".
static func read(rd: RenderingDevice, prefix: String, include_post: bool = false) -> Dictionary:
	var out: Dictionary = {}
	var prev_time := 0
	var start_time := 0
	var in_chain := false
	for i in rd.get_captured_timestamps_count():
		var name: String = rd.get_captured_timestamp_name(i)
		if not name.begins_with(prefix):
			continue
		var timestamp: int = rd.get_captured_timestamp_gpu_time(i)
		if name == prefix + "start":
			start_time = timestamp
			prev_time = timestamp
			in_chain = true
			continue
		if not in_chain:
			continue
		var segment := name.trim_prefix(prefix)
		if segment == "end":
			out["total"] = float(timestamp - start_time) / 1e6
			if include_post:
				out["post"] = out.get("post", 0.0) + float(timestamp - prev_time) / 1e6
			in_chain = false
		else:
			out[segment] = out.get(segment, 0.0) + float(timestamp - prev_time) / 1e6
		prev_time = timestamp
	return out
