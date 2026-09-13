extends RefCounted
## Render-thread readback of one texture layer, shared by the GPU test suites
## and the visual probes. Returns an empty buffer on timeout or size mismatch;
## callers turn that into their own failure report.

const DEFAULT_TIMEOUT_MS := 10000


func read_layer(rid: RID, layer: int, expected_bytes: int = 0,
		timeout_ms: int = DEFAULT_TIMEOUT_MS) -> PackedByteArray:
	if not rid.is_valid():
		return PackedByteArray()
	var state := {"done": false, "data": PackedByteArray()}
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		rd.texture_get_data_async(rid, layer, func(data: PackedByteArray):
			call_deferred("_store", state, data)
		)
	)
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		push_error("texture readback needs a SceneTree main loop")
		return PackedByteArray()
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await (loop as SceneTree).process_frame
		if state.done:
			if expected_bytes > 0 and state.data.size() != expected_bytes:
				push_error("texture readback size mismatch (%d != %d)" % [
					state.data.size(), expected_bytes])
				return PackedByteArray()
			return state.data
	push_error("texture readback timed out after %d ms" % timeout_ms)
	return PackedByteArray()


func _store(state: Dictionary, data: PackedByteArray) -> void:
	state.data = data
	state.done = true
