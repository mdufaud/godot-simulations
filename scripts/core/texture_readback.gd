extends RefCounted
## Render-thread readback of one texture layer, shared by the GPU test suites
## and the visual probes. Returns an empty buffer on timeout or size mismatch;
## callers turn that into their own failure report.

const DEFAULT_TIMEOUT_MS := 10000


class Request extends RefCounted:
	signal completed

	var _mutex := Mutex.new()
	var _done := false
	var _cancelled := false
	var _timed_out := false
	var _data := PackedByteArray()

	func pending() -> bool:
		_mutex.lock()
		var value := not _done
		_mutex.unlock()
		return value

	func cancelled() -> bool:
		_mutex.lock()
		var value := _cancelled
		_mutex.unlock()
		return value

	func timed_out() -> bool:
		_mutex.lock()
		var value := _timed_out
		_mutex.unlock()
		return value

	func data() -> PackedByteArray:
		_mutex.lock()
		var value := _data
		_mutex.unlock()
		return value

	func complete(value: PackedByteArray) -> void:
		_settle(value, false, false)

	func cancel() -> void:
		_settle(PackedByteArray(), true, false)

	func timeout() -> void:
		_settle(PackedByteArray(), false, true)

	func _settle(value: PackedByteArray, was_cancelled: bool, was_timed_out: bool) -> void:
		_mutex.lock()
		if _done:
			_mutex.unlock()
			return
		_done = true
		_data = value
		_cancelled = was_cancelled
		_timed_out = was_timed_out
		_mutex.unlock()
		completed.emit()


func read_layer(rid: RID, layer: int, expected_bytes: int = 0,
		timeout_ms: int = DEFAULT_TIMEOUT_MS, request: Request = null) -> PackedByteArray:
	if not rid.is_valid():
		return PackedByteArray()
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		push_error("texture readback needs a SceneTree main loop")
		return PackedByteArray()
	var state: Request = request if request != null else Request.new()
	if state.cancelled():
		return PackedByteArray()
	var timer := (loop as SceneTree).create_timer(float(timeout_ms) / 1000.0, true, false, true)
	timer.timeout.connect(state.timeout, CONNECT_ONE_SHOT)
	RenderingServer.call_on_render_thread(func():
		if not state.pending():
			return
		var rd := RenderingServer.get_rendering_device()
		# A texture freed between the request and this callable never answers the
		# async read, which would surface as a 10 s "timeout" instead of a miss.
		if rd == null or not rd.texture_is_valid(rid):
			state.complete.call_deferred(PackedByteArray())
			return
		rd.texture_get_data_async(rid, layer, func(bytes: PackedByteArray):
			call_deferred("_deliver_at_process_frame", loop, state, bytes)
		)
	)
	if state.pending():
		await state.completed
	if timer.timeout.is_connected(state.timeout):
		timer.timeout.disconnect(state.timeout)
	if state.cancelled():
		return PackedByteArray()
	if state.timed_out():
		push_error("texture readback timed out after %d ms" % timeout_ms)
		return PackedByteArray()
	var bytes := state.data()
	if expected_bytes > 0 and bytes.size() != expected_bytes:
		push_error("texture readback size mismatch (%d != %d)" % [bytes.size(), expected_bytes])
		return PackedByteArray()
	return bytes


func _deliver_at_process_frame(loop: SceneTree, state: Request, bytes: PackedByteArray) -> void:
	if state.pending() and is_instance_valid(loop):
		loop.process_frame.connect(state.complete.bind(bytes), CONNECT_ONE_SHOT)
