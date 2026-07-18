class_name PlanetGenerator
extends RefCounted
## GPU planet mesh generator. Builds a signed-distance field (sphere + ridged FBM)
## into a storage buffer, runs marching cubes over it, then reads the triangle soup
## back into an ArrayMesh. Port of the "Terra" planet from SebLague/Fluid-Planet.
##
## The readback is the expensive part, so generation is one-shot and asynchronous:
## request_generate() -> poll() each frame -> take_mesh() when it returns true.
## The GPU half runs on the render thread, the byte-to-vertex unpacking on a worker.

const SHADER_DIR := "res://shaders/planet/"
const STAGES: Array[String] = ["density", "marching_cubes"]
const WG := 8
## Bytes per triangle: 3 vertices, each a vec4 position plus a vec4 normal.
const TRI_BYTES := 96
## Headroom between the tallest possible peak and the volume box faces.
const WORLD_SIZE_MARGIN := 1.05
const TABLE_TRIANGULATION_BASE := 512

enum State { IDLE, GPU, CPU, READY }

# Shape parameters. Defaults are Lague's tuned values (Terraform.unity:14246-14258).
var resolution := 128
var radius := 23.0
var iso_level := 0.0
var num_layers := 8
var lacunarity := 1.48
var persistence := 0.68
var noise_scale := 2.86
var noise_strength := 2.41
var noise_offset := -0.28
var noise_position_offset := Vector3.ZERO

var initialized := false
## Triangles emitted by the last generation, after clamping to the buffer cap.
var triangle_count := 0
## Wall time of the last full generation, in milliseconds.
var last_generate_ms := 0.0

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _density_buf := RID()
## Same field as _density_buf, as a sampleable 3D texture. The fluid solver reads
## it to collide against the terrain, exactly as SebLague's fluid samples the live
## marching-cubes density texture rather than a separate SDF bake.
var _density_tex := RID()
var _tri_buf := RID()
var _counter_buf := RID()
var _table_buf := RID()
var _buffer_resolution := 0
var _max_triangles := 0

var _state := State.IDLE
var _state_mutex := Mutex.new()
var _tri_bytes := PackedByteArray()
var _thread: Thread
var _positions := PackedVector3Array()
var _normals := PackedVector3Array()
var _start_usec := 0


func _get_state() -> State:
	_state_mutex.lock()
	var s := _state
	_state_mutex.unlock()
	return s


func _set_state(s: State) -> void:
	_state_mutex.lock()
	_state = s
	_state_mutex.unlock()


func is_busy() -> bool:
	return _get_state() != State.IDLE


## Buffer cap for the triangle soup. Only cubes straddling the surface emit, so the
## count scales with area, not volume; 20 triangles per surface cell is generous.
func _triangle_cap(res: int) -> int:
	return maxi(50000, res * res * 20)


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("Planet: no RenderingDevice (Compatibility renderer or headless?)")
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "planet_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "planet_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "planet_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Planet stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	# The marching-cubes lookup tables never change: one buffer for the whole run.
	var tables := PackedInt32Array()
	tables.resize(TABLE_TRIANGULATION_BASE + McTables.TRIANGULATION.size())
	for i in 256:
		tables[i] = McTables.OFFSETS[i]
		tables[256 + i] = McTables.LENGTHS[i]
	for i in McTables.TRIANGULATION.size():
		tables[TABLE_TRIANGULATION_BASE + i] = McTables.TRIANGULATION[i]
	var table_bytes := tables.to_byte_array()
	_table_buf = _rd.storage_buffer_create(table_bytes.size(), table_bytes)

	_allocate_volume_buffers(resolution)
	initialized = true


func _allocate_volume_buffers(res: int) -> void:
	_free_volume_buffers()

	_max_triangles = _triangle_cap(res)
	_density_buf = _rd.storage_buffer_create(res * res * res * 4)
	_density_tex = _create_density_texture(res)
	_tri_buf = _rd.storage_buffer_create(_max_triangles * TRI_BYTES)
	var zero := PackedInt32Array([0]).to_byte_array()
	_counter_buf = _rd.storage_buffer_create(4, zero)
	_buffer_resolution = res

	_uniform_sets["density"] = _rd.uniform_set_create(
		[_buffer_uniform(_density_buf, 0), _image_uniform(_density_tex, 1)],
		_shaders["density"], 0
	)
	_uniform_sets["marching_cubes"] = _rd.uniform_set_create([
		_buffer_uniform(_density_buf, 0),
		_buffer_uniform(_tri_buf, 1),
		_buffer_uniform(_counter_buf, 2),
		_buffer_uniform(_table_buf, 3),
	], _shaders["marching_cubes"], 0)


func _create_density_texture(res: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = res
	fmt.height = res
	fmt.depth = res
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _image_uniform(tex: RID, binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


func _buffer_uniform(buf: RID, binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _free_volume_buffers() -> void:
	for key in ["density", "marching_cubes"]:
		if _uniform_sets.has(key) and _rd.uniform_set_is_valid(_uniform_sets[key]):
			_rd.free_rid(_uniform_sets[key])
	_uniform_sets.clear()
	for buf in [_density_buf, _density_tex, _tri_buf, _counter_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_density_buf = RID()
	_density_tex = RID()
	_tri_buf = RID()
	_counter_buf = RID()


func free_render() -> void:
	if _rd == null:
		return
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	_free_volume_buffers()
	if _table_buf.is_valid():
		_rd.free_rid(_table_buf)
		_table_buf = RID()
	for key in _pipelines:
		_rd.free_rid(_pipelines[key])
	for key in _shaders:
		_rd.free_rid(_shaders[key])
	_pipelines.clear()
	_shaders.clear()
	initialized = false


## Kicks off a generation. No-op while one is already running.
func request_generate() -> bool:
	if not initialized or is_busy():
		return false
	_start_usec = Time.get_ticks_usec()
	_set_state(State.GPU)
	RenderingServer.call_on_render_thread(_generate_render)
	return true


func _generate_render() -> void:
	if resolution != _buffer_resolution:
		_allocate_volume_buffers(resolution)

	_rd.buffer_update(_counter_buf, 0, 4, PackedInt32Array([0]).to_byte_array())

	var res := resolution
	var groups := int(ceil(float(res) / float(WG)))

	var box := world_size()
	var density_pc := PackedFloat32Array([
		0.0, 0.0, 0.0, radius,
		box, box, box, noise_scale,
		noise_position_offset.x, noise_position_offset.y, noise_position_offset.z, noise_strength,
		lacunarity, persistence, noise_offset, 0.0,
		0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	density_pc.encode_s32(60, num_layers)
	density_pc.encode_u32(64, res)

	# TerrainCreator.cs:123 hands marching cubes the negated iso level.
	var mc_pc := PackedFloat32Array([
		box, box, box, -iso_level,
		0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	mc_pc.encode_u32(16, res)
	mc_pc.encode_u32(20, _max_triangles)

	var cl := _rd.compute_list_begin()

	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["density"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets["density"], 0)
	_rd.compute_list_set_push_constant(cl, density_pc, density_pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, groups)

	_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["marching_cubes"])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets["marching_cubes"], 0)
	_rd.compute_list_set_push_constant(cl, mc_pc, mc_pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, groups)

	_rd.compute_list_end()

	# Forces a device sync, which is exactly why generation is one-shot and not per-frame.
	var count_bytes := _rd.buffer_get_data(_counter_buf, 0, 4)
	var count := count_bytes.decode_u32(0)
	if count > _max_triangles:
		push_warning("Planet: triangle buffer full (%d > %d), mesh is clipped" % [count, _max_triangles])
		count = _max_triangles
	triangle_count = count

	_tri_bytes = PackedByteArray()
	if count > 0:
		_tri_bytes = _rd.buffer_get_data(_tri_buf, 0, count * TRI_BYTES)
	_set_state(State.CPU)


## Call every frame. Returns true on the frame the mesh becomes available.
func poll() -> bool:
	match _get_state():
		State.CPU:
			if _thread == null:
				_thread = Thread.new()
				_thread.start(_unpack_vertices)
			return false
		State.READY:
			if _thread != null:
				_thread.wait_to_finish()
				_thread = null
			last_generate_ms = float(Time.get_ticks_usec() - _start_usec) / 1000.0
			_set_state(State.IDLE)
			return true
		_:
			return false


func _unpack_vertices() -> void:
	var floats := _tri_bytes.to_float32_array()
	var vertex_count := triangle_count * 3
	_positions = PackedVector3Array()
	_normals = PackedVector3Array()
	_positions.resize(vertex_count)
	_normals.resize(vertex_count)
	# Each vertex is 8 floats: position.xyz + pad, normal.xyz + pad.
	for i in vertex_count:
		var o := i * 8
		_positions[i] = Vector3(floats[o], floats[o + 1], floats[o + 2])
		_normals[i] = Vector3(floats[o + 4], floats[o + 5], floats[o + 6])
	_tri_bytes = PackedByteArray()
	_set_state(State.READY)


## Valid on the frame poll() returned true. Null when the field produced no surface.
func take_mesh() -> ArrayMesh:
	if _positions.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_NORMAL] = _normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_positions = PackedVector3Array()
	_normals = PackedVector3Array()
	return mesh


## The density field as a 3D texture, for anything that needs to sample the terrain
## between texels. Changes identity whenever the resolution changes, so consumers
## must rebuild their uniform sets rather than caching the RID across a regeneration.
func density_texture() -> RID:
	return _density_tex


## Outer radius the surface can reach. Each ridge octave tops out at 1, so the FBM
## maxes at the geometric sum of the amplitudes; the offset is subtracted before the
## strength scales it. At Lague's tuned values this yields 31.0, which is why his
## volume was 65 wide -- the box is sized from the terrain rather than guessed.
func max_surface_radius() -> float:
	var amplitude_sum := 0.0
	var amplitude := 1.0
	for i in num_layers:
		amplitude_sum += amplitude
		amplitude *= persistence
	return radius + maxf(0.0, (amplitude_sum - noise_offset) * noise_strength)


## Side of the sampled volume, sized so the tallest peak still fits inside.
func world_size() -> float:
	return max_surface_radius() * 2.0 * WORLD_SIZE_MARGIN
