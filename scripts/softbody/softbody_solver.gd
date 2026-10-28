class_name SoftBodySolver
extends RefCounted
## GPU soft bodies: vertex block descent (Chen et al. 2024) on tetrahedral
## lattices with a stable Neo-Hookean material (Smith et al. 2018). Each substep
## predicts the inertial target, hashes surface vertices for body-body contact,
## then runs iterations x 8 colour passes of one Newton step per vertex, against
## the ground plane, analytic colliders and the other bodies' boundary triangles. Contact forces on
## dynamic colliders are summed on the GPU and read back a frame later.
##
## Every body lives in one set of buffers; bodies added inactive form a pool the
## host spawns without a rebuild. Positions land in an rgba32f texture, one texel
## per vertex, that SoftBodyRenderer reads in its vertex stage.
##
## [codeblock]
## var solver := SoftBodySolver.new()
## solver.config = preset.config.duplicate()
## for shape in preset.bodies:
##     solver.add_body(shape, true)
## solver.start()
## # each frame:
## solver.set_colliders(packed_colliders)
## solver.advance(clock.advance(delta))
## var wrenches := solver.reactions()
## # teardown:
## solver.stop()
## [/codeblock]

const SHADER_DIR := "res://shaders/softbody/"
const STAGES: Array[String] = ["predict", "hash_clear", "hash_insert", "detect", "vbd",
	"finalize"]
const WG := 64
const TEXTURE_WIDTH := 1024
const MAX_COLLIDERS := 64
const COLLIDER_VEC4S := 6
const COLLIDER_SPHERE := 1
const COLLIDER_BOX := 2
const COLLIDER_CAPSULE := 3
const HASH_BUCKETS := 65536
const HASH_SLOTS := 8
## Contacts a vertex can take a reaction from as a triangle corner (softbody_common.comp).
const INCOMING_SLOTS := 8
## Fixed point of the reaction accumulators, in units per newton.
const REACTION_SCALE := 1000.0
const PUSH_CONSTANT_BYTES := 112
const PROFILE_KEY := "softbody"

var config := SoftBodyConfig.new()
var profiling := false

var _shapes: Array[SoftBodyShape] = []
var _lattices: Array[TetLattice] = []
var _offsets := PackedInt32Array([0])
var _active := PackedByteArray()
var _lattice_cache := {}
var _colliders := PackedFloat32Array()
var _grab_vertex := -1
var _grab_target := Vector3.ZERO
var _color_ranges := PackedInt32Array()

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _texture := RID()
var _running := false
var _mutex := Mutex.new()
var _reactions := PackedFloat32Array()
var _generation := 0
var _timing_store := GpuTimingStore.new()


## Adds a body at its shape's rest pose. Before start() only.
func add_body(shape: SoftBodyShape, active: bool) -> int:
	var key := "%d|%s|%f" % [shape.kind, shape.size_m, config.lattice_cell_m]
	if not _lattice_cache.has(key):
		_lattice_cache[key] = TetLattice.build(shape, config.lattice_cell_m)
	var lattice: TetLattice = _lattice_cache[key]
	_shapes.append(shape)
	_lattices.append(lattice)
	_offsets.append(_offsets[-1] + lattice.vertex_count())
	_active.append(1 if active else 0)
	return _shapes.size() - 1


func clear_bodies() -> void:
	_shapes.clear()
	_lattices.clear()
	_offsets = PackedInt32Array([0])
	_active.clear()


func body_count() -> int:
	return _shapes.size()


func body_shape(body: int) -> SoftBodyShape:
	return _shapes[body]


func body_lattice(body: int) -> TetLattice:
	return _lattices[body]


func body_offset(body: int) -> int:
	return _offsets[body]


func is_body_active(body: int) -> bool:
	return _active[body] != 0


func vertex_count() -> int:
	return _offsets[-1]


func start() -> String:
	var error := config.validate()
	if error != "":
		return error
	if _shapes.is_empty():
		return "no body was added"
	if _shapes.size() > config.max_bodies:
		return "%d bodies exceed max_bodies %d" % [_shapes.size(), config.max_bodies]
	for shape in _shapes:
		error = shape.validate()
		if error != "":
			return error
	stop()
	RenderingServer.call_on_render_thread(_init_render.bind(_build_arrays()))
	return ""


func stop() -> void:
	var done := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		_free_render()
		done.post())
	done.wait()


func is_ready() -> bool:
	_mutex.lock()
	var running := _running
	_mutex.unlock()
	return running


func position_texture_rid() -> RID:
	return _texture


## Colliders packed with pack_collider(), at most MAX_COLLIDERS.
func set_colliders(packed: PackedFloat32Array) -> void:
	_colliders = packed


func collider_count() -> int:
	return _colliders.size() / (COLLIDER_VEC4S * 4)


func set_grab(vertex: int, target: Vector3) -> void:
	_grab_vertex = vertex
	_grab_target = target


func release_grab() -> void:
	_grab_vertex = -1


func advance(quanta: int) -> void:
	if not is_ready() or quanta <= 0:
		return
	RenderingServer.call_on_render_thread(_advance_render.bind(quanta, config.substeps,
		config.iterations, make_push_constants(), _colliders.to_byte_array()))


## Moves a body to `xform` (applied to its rest shape) at rest and activates it.
func spawn_body(body: int, xform: Transform3D) -> void:
	_active[body] = 1
	var lattice := _lattices[body]
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	var previous := PackedFloat32Array()
	for v in lattice.vertex_count():
		var p := xform * lattice.rest[v]
		positions.append_array([p.x, p.y, p.z, lattice.volume_share[v]])
		velocities.append_array([0.0, 0.0, 0.0, float(body)])
		previous.append_array([p.x, p.y, p.z, float(lattice.surface[v])])
	if is_ready():
		RenderingServer.call_on_render_thread(_spawn_render.bind(_offsets[body] * 16,
			positions.to_byte_array(), velocities.to_byte_array(), previous.to_byte_array(),
			_pack_bodies().to_byte_array()))


func set_body_active(body: int, on: bool) -> void:
	_active[body] = 1 if on else 0
	refresh_materials()


## Re-uploads every body's material and active flag, after a config change.
func refresh_materials() -> void:
	if is_ready():
		RenderingServer.call_on_render_thread(_upload_bodies_render.bind(
			_pack_bodies().to_byte_array()))


## Force and torque (N, N m) each dynamic collider received, averaged over the
## last advanced frame; six floats per collider, in set_colliders() order.
func reactions() -> PackedFloat32Array:
	_mutex.lock()
	var out := _reactions
	_mutex.unlock()
	return out


## Blocks on a GPU readback: 4 floats per vertex (position, volume share).
func read_positions() -> PackedFloat32Array:
	var out: Array[PackedFloat32Array] = [PackedFloat32Array()]
	var done := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		if _rd != null and _buffers.has("positions"):
			out[0] = _rd.buffer_get_data(_buffers["positions"]).to_float32_array()
		done.post())
	done.wait()
	return out[0]


## Nearest active surface vertex to a ray, within max_distance_m of it, or -1.
func nearest_vertex(positions: PackedFloat32Array, origin: Vector3, direction: Vector3,
		max_distance_m: float) -> int:
	var best := -1
	var best_depth := INF
	for body in _shapes.size():
		if _active[body] == 0:
			continue
		var lattice := _lattices[body]
		for v in lattice.vertex_count():
			if lattice.surface[v] == 0:
				continue
			var i := _offsets[body] + v
			if i * 4 + 2 >= positions.size():
				return best
			var p := Vector3(positions[i * 4], positions[i * 4 + 1], positions[i * 4 + 2])
			var depth := (p - origin).dot(direction)
			if depth <= 0.0 or depth >= best_depth:
				continue
			if (origin + direction * depth).distance_to(p) <= max_distance_m:
				best = i
				best_depth = depth
	return best


func get_timings() -> Dictionary:
	return _timing_store.snapshot()


static func pack_collider(kind: int, xform: Transform3D, half_size_m: Vector3,
		linear_mps: Vector3, angular_rps: Vector3, dynamic: bool) -> PackedFloat32Array:
	var basis := xform.basis.orthonormalized()
	var bound := half_size_m.length() if kind == COLLIDER_BOX else half_size_m.x + half_size_m.y
	return PackedFloat32Array([
		xform.origin.x, xform.origin.y, xform.origin.z, kind,
		basis.x.x, basis.x.y, basis.x.z, half_size_m.x,
		basis.y.x, basis.y.y, basis.y.z, half_size_m.y,
		basis.z.x, basis.z.y, basis.z.z, half_size_m.z,
		linear_mps.x, linear_mps.y, linear_mps.z, bound,
		angular_rps.x, angular_rps.y, angular_rps.z, 1.0 if dynamic else 0.0,
	])


func make_push_constants() -> PackedByteArray:
	var h := 1.0 / (config.sim_rate_hz * config.substeps)
	var pc := PackedByteArray()
	pc.resize(PUSH_CONSTANT_BYTES)
	pc.encode_float(0, h)
	pc.encode_float(4, 1.0 / (h * h))
	pc.encode_float(8, config.damping_s)
	pc.encode_float(12, config.contact_stiffness)
	pc.encode_float(16, config.gravity_mps2.x)
	pc.encode_float(20, config.gravity_mps2.y)
	pc.encode_float(24, config.gravity_mps2.z)
	pc.encode_float(28, pow(config.velocity_retention, h * 60.0))
	pc.encode_s32(40, vertex_count())
	pc.encode_s32(48, collider_count())
	pc.encode_s32(52, HASH_BUCKETS)
	pc.encode_s32(56, HASH_SLOTS)
	pc.encode_s32(60, TEXTURE_WIDTH)
	pc.encode_float(64, _grab_target.x)
	pc.encode_float(68, _grab_target.y)
	pc.encode_float(72, _grab_target.z)
	pc.encode_float(76, config.grab_stiffness)
	pc.encode_s32(80, _grab_vertex)
	pc.encode_float(96, config.lattice_cell_m)
	pc.encode_float(100, config.self_contact_cells * config.lattice_cell_m)
	pc.encode_float(104, config.max_speed_mps)
	pc.encode_float(108, REACTION_SCALE)
	return pc


func _pack_bodies() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for body in _shapes.size():
		var lame := config.lame(_shapes[body].youngs_modulus_pa)
		out.append_array([lame.x, lame.y, config.density_kg_m3, float(_active[body]),
			_shapes[body].friction, 0.0, 0.0, 0.0])
	return out


func _build_arrays() -> Dictionary:
	var positions := PackedFloat32Array()
	var velocities := PackedFloat32Array()
	var previous := PackedFloat32Array()
	var tets := PackedInt32Array()
	var tet_rest := PackedFloat32Array()
	var buckets: Array[Array] = []
	for colour in TetLattice.COLORS:
		buckets.append([])
	var n := vertex_count()
	var degree := PackedInt32Array()
	degree.resize(n + 1)
	for body in _shapes.size():
		var lattice := _lattices[body]
		var offset := _offsets[body]
		var xform := _shapes[body].rest_transform()
		for v in lattice.vertex_count():
			var p := xform * lattice.rest[v]
			positions.append_array([p.x, p.y, p.z, lattice.volume_share[v]])
			velocities.append_array([0.0, 0.0, 0.0, float(body)])
			previous.append_array([p.x, p.y, p.z, float(lattice.surface[v])])
			buckets[lattice.colors[v]].append(offset + v)
		for tet in lattice.tet_count():
			var inverse_rows := lattice.rest_edges(tet).inverse().transposed()
			var volume := absf(lattice.rest_edges(tet).determinant()) / 6.0
			tet_rest.append_array([inverse_rows.x.x, inverse_rows.x.y, inverse_rows.x.z, volume,
				inverse_rows.y.x, inverse_rows.y.y, inverse_rows.y.z, 0.0,
				inverse_rows.z.x, inverse_rows.z.y, inverse_rows.z.z, 0.0])
			for corner in 4:
				var v := offset + lattice.tets[tet * 4 + corner]
				tets.append(v)
				degree[v + 1] += 1
	for v in n:
		degree[v + 1] += degree[v]
	var entries := PackedInt32Array()
	entries.resize(degree[n])
	var fill := degree.slice(0, n)
	for e in tets.size():
		var v := tets[e]
		entries[fill[v]] = e
		fill[v] += 1
	var triangles := PackedInt32Array()
	var triangle_degree := PackedInt32Array()
	triangle_degree.resize(n + 1)
	for body in _shapes.size():
		var lattice := _lattices[body]
		for k in lattice.triangles.size():
			if k % 3 == 0:
				triangles.append_array([0, 0, 0, body])
			var v := _offsets[body] + lattice.triangles[k]
			triangles[triangles.size() - 4 + k % 3] = v
			triangle_degree[v + 1] += 1
	for v in n:
		triangle_degree[v + 1] += triangle_degree[v]
	var triangle_entries := PackedInt32Array()
	triangle_entries.resize(triangle_degree[n])
	var triangle_fill := triangle_degree.slice(0, n)
	for t in triangles.size() / 4:
		for corner in 3:
			var v := triangles[t * 4 + corner]
			triangle_entries[triangle_fill[v]] = t
			triangle_fill[v] += 1
	var colors := PackedInt32Array()
	_color_ranges.clear()
	for bucket in buckets:
		_color_ranges.append_array([colors.size(), bucket.size()])
		colors.append_array(PackedInt32Array(bucket))
	return {
		positions = positions.to_byte_array(),
		velocities = velocities.to_byte_array(),
		previous = previous.to_byte_array(),
		tets = tets.to_byte_array(),
		tet_rest = tet_rest.to_byte_array(),
		adjacency_offsets = degree.to_byte_array(),
		adjacency_entries = entries.to_byte_array(),
		color_vertices = colors.to_byte_array(),
		bodies = _pack_bodies().to_byte_array(),
		triangles = triangles.to_byte_array(),
		triangle_offsets = triangle_degree.to_byte_array(),
		triangle_entries = triangle_entries.to_byte_array(),
	}


func _init_render(arrays: Dictionary) -> void:
	_free_render()
	_rd = GpuPreflight.device("SoftBodySolver")
	if _rd == null:
		return
	var common := FileAccess.get_file_as_string(SHADER_DIR + "softbody_common.comp")
	for stage in STAGES:
		var source := FileAccess.get_file_as_string(SHADER_DIR + "softbody_%s.comp" % stage)
		var spirv := ShaderCache.compile(_rd, "softbody_" + stage,
			"#version 450\n\n" + common + "\n" + source)
		if not spirv.compile_error_compute.is_empty():
			push_error("SoftBody stage '%s' compile error:\n%s" % [stage,
				spirv.compile_error_compute])
			_free_render()
			return
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])

	var n := vertex_count()
	for key in arrays:
		var bytes: PackedByteArray = arrays[key]
		_buffers[key] = _rd.storage_buffer_create(maxi(bytes.size(), 16), bytes)
	_buffers["inertial"] = _rd.storage_buffer_create(n * 16)
	_buffers["colliders"] = _rd.storage_buffer_create(MAX_COLLIDERS * COLLIDER_VEC4S * 16)
	_buffers["reactions"] = _rd.storage_buffer_create(MAX_COLLIDERS * 6 * 4)
	_buffers["hash_counts"] = _rd.storage_buffer_create(HASH_BUCKETS * 4)
	_buffers["hash_slots"] = _rd.storage_buffer_create(HASH_BUCKETS * HASH_SLOTS * 4)
	_buffers["contacts"] = _rd.storage_buffer_create(n * 4)
	_buffers["incoming"] = _rd.storage_buffer_create(n * INCOMING_SLOTS * 4)
	_buffers["incoming_counts"] = _rd.storage_buffer_create(n * 4)

	var fmt := RDTextureFormat.new()
	fmt.width = TEXTURE_WIDTH
	fmt.height = ceili(float(n) / TEXTURE_WIDTH)
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_texture = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(_texture, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var order := ["positions", "velocities", "inertial", "previous", "tets", "tet_rest",
		"adjacency_offsets", "adjacency_entries", "color_vertices", "bodies", "colliders",
		"reactions", "hash_counts", "hash_slots", "contacts"]
	for stage in STAGES:
		var uniforms: Array[RDUniform] = []
		for binding in order.size():
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = binding
			u.add_id(_buffers[order[binding]])
			uniforms.append(u)
		var image := RDUniform.new()
		image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image.binding = order.size()
		image.add_id(_texture)
		uniforms.append(image)
		for extra in ["triangles", "triangle_offsets", "triangle_entries", "incoming",
				"incoming_counts"]:
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = uniforms.size()
			u.add_id(_buffers[extra])
			uniforms.append(u)
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)
	# Fills the texture and the previous positions before the first frame.
	var cl := _rd.compute_list_begin()
	var pc := make_push_constants()
	pc.encode_float(0, 1.0)
	_dispatch(cl, "finalize", pc, n)
	_rd.compute_list_end()
	_mutex.lock()
	_running = true
	_generation += 1
	_reactions = PackedFloat32Array()
	_mutex.unlock()


func _advance_render(quanta: int, substeps: int, iterations: int, pc: PackedByteArray,
		colliders: PackedByteArray) -> void:
	if _rd == null or not _running:
		return
	_read_timings()
	if not colliders.is_empty():
		_rd.buffer_update(_buffers["colliders"], 0, colliders.size(), colliders)
	_rd.buffer_clear(_buffers["reactions"], 0, MAX_COLLIDERS * 6 * 4)
	var n := vertex_count()
	var colour_pcs: Array[PackedByteArray] = []
	for colour in TetLattice.COLORS:
		for last in 2:
			var colour_pc := pc.duplicate()
			colour_pc.encode_s32(32, _color_ranges[colour * 2])
			colour_pc.encode_s32(36, _color_ranges[colour * 2 + 1])
			colour_pc.encode_s32(44, last)
			colour_pcs.append(colour_pc)
	_rd.capture_timestamp(PROFILE_KEY + "/start")
	var cl := _rd.compute_list_begin()
	for _q in quanta:
		for _s in substeps:
			_dispatch(cl, "predict", pc, n)
			cl = _mark(cl, "predict")
			_dispatch(cl, "hash_clear", pc, HASH_BUCKETS)
			_dispatch(cl, "hash_insert", pc, n)
			_dispatch(cl, "detect", pc, n)
			cl = _mark(cl, "contacts")
			for iteration in iterations:
				var last := 1 if iteration == iterations - 1 else 0
				# Symmetric Gauss-Seidel: a fixed colour order biases contacts sideways.
				for step in TetLattice.COLORS:
					var colour := step if iteration % 2 == 0 else TetLattice.COLORS - 1 - step
					var count := _color_ranges[colour * 2 + 1]
					if count > 0:
						_dispatch(cl, "vbd", colour_pcs[colour * 2 + last], count)
			cl = _mark(cl, "vbd")
			_dispatch(cl, "finalize", pc, n)
			cl = _mark(cl, "finalize")
	_rd.compute_list_end()
	_rd.capture_timestamp(PROFILE_KEY + "/end")
	var generation := _generation
	var steps := float(quanta * substeps)
	_rd.buffer_get_data_async(_buffers["reactions"], func(data: PackedByteArray) -> void:
		var fixed := data.to_int32_array()
		var out := PackedFloat32Array()
		out.resize(fixed.size())
		for k in fixed.size():
			out[k] = fixed[k] / (REACTION_SCALE * steps)
		_mutex.lock()
		if generation == _generation:
			_reactions = out
		_mutex.unlock(), 0, MAX_COLLIDERS * 6 * 4)


func _spawn_render(byte_offset: int, positions: PackedByteArray, velocities: PackedByteArray,
		previous: PackedByteArray, bodies: PackedByteArray) -> void:
	if _rd == null or not _running:
		return
	_rd.buffer_update(_buffers["positions"], byte_offset, positions.size(), positions)
	_rd.buffer_update(_buffers["velocities"], byte_offset, velocities.size(), velocities)
	_rd.buffer_update(_buffers["previous"], byte_offset, previous.size(), previous)
	_upload_bodies_render(bodies)


func _upload_bodies_render(bodies: PackedByteArray) -> void:
	if _rd == null or not _running:
		return
	_rd.buffer_update(_buffers["bodies"], 0, bodies.size(), bodies)


func _dispatch(cl: int, stage: String, pc: PackedByteArray, threads: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, ceili(float(threads) / WG), 1, 1)
	_rd.compute_list_add_barrier(cl)


# Timestamps cannot be captured inside an open compute list: split it at stage
# boundaries when profiling.
func _mark(cl: int, stage: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(PROFILE_KEY + "/" + stage)
	return _rd.compute_list_begin()


func _read_timings() -> void:
	var out := GpuTimings.read(_rd, PROFILE_KEY + "/")
	if not out.is_empty():
		_timing_store.publish(out)


func _free_render() -> void:
	_mutex.lock()
	_running = false
	_generation += 1
	_reactions = PackedFloat32Array()
	_mutex.unlock()
	if _rd == null:
		return
	for stage in _uniform_sets:
		if _uniform_sets[stage].is_valid():
			_rd.free_rid(_uniform_sets[stage])
	for key in _buffers:
		if _buffers[key].is_valid():
			_rd.free_rid(_buffers[key])
	if _texture.is_valid():
		_rd.free_rid(_texture)
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_uniform_sets.clear()
	_buffers.clear()
	_pipelines.clear()
	_shaders.clear()
	_texture = RID()
	_rd = null
