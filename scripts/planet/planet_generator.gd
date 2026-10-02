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

## The density field behind [method density_texture] has been rewritten. Emitted from
## [method poll] on the main thread, on the frame the mesh becomes available.
##
## Every generation rewrites the field, and a resolution change frees the texture and
## allocates a new one, so anything sampling it must rebuild its uniform sets here
## rather than caching the RID.
signal density_texture_changed

# Shape parameters. Defaults are Lague's tuned values (Terraform.unity:14246-14258).
var resolution := 128
var config: PlanetConfig = PlanetConfig.new()
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
var generated_radius := 0.0
var generated_surface_radius := 0.0
var generated_world_size := 0.0
var generated_resolution := 0
var generated_error := ""
var generated_volcanoes := PackedVector4Array()
var generated_volcano_size_ratio := 0.0
var generated_volcano_height_ratio := 0.0
var generated_terrain_style := 0
var generated_opening_style := 0

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
var _shape_buf := RID()
var _buffer_resolution := 0
var _buffer_budget := 0.0
var _max_triangles := 0

var _state := State.IDLE
var _state_mutex := Mutex.new()
var _tri_bytes := PackedByteArray()
var _thread: Thread
var _positions := PackedVector3Array()
var _normals := PackedVector3Array()
var _start_usec := 0
var _request := {}


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
func _triangle_cap(res: int, budget: float) -> int:
	return maxi(1, int(ceil(float(res * res) * budget)))


func init_render() -> void:
	config.resolution = resolution
	config.radius_m = radius
	config.max_layers = num_layers
	var config_error := config.validate()
	if config_error != "":
		push_error("Planet config: %s" % config_error)
		return
	_rd = GpuPreflight.device("PlanetGenerator")
	if _rd == null:
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "planet_common.comp")
	common += "\n" + FileAccess.get_file_as_string(SHADER_DIR + "volcano_shape.gdshaderinc")
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

	_allocate_volume_buffers(resolution, config.triangle_budget_per_cell)
	initialized = true


func _allocate_volume_buffers(res: int, budget: float) -> void:
	_free_volume_buffers()

	_max_triangles = _triangle_cap(res, budget)
	_density_buf = _rd.storage_buffer_create(res * res * res * 4)
	_density_tex = _create_density_texture(res)
	_tri_buf = _rd.storage_buffer_create(_max_triangles * TRI_BYTES)
	var zero := PackedInt32Array([0]).to_byte_array()
	_counter_buf = _rd.storage_buffer_create(4, zero)
	_shape_buf = _rd.storage_buffer_create(29 * 16)
	_buffer_resolution = res
	_buffer_budget = budget

	_uniform_sets["density"] = _rd.uniform_set_create(
		[_buffer_uniform(_density_buf, 0), _image_uniform(_density_tex, 1), _buffer_uniform(_shape_buf, 2)],
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
	for buf in [_density_buf, _density_tex, _tri_buf, _counter_buf, _shape_buf]:
		if buf.is_valid():
			_rd.free_rid(buf)
	_density_buf = RID()
	_density_tex = RID()
	_tri_buf = RID()
	_counter_buf = RID()
	_shape_buf = RID()


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
	config.resolution = resolution
	config.radius_m = radius
	config.max_layers = num_layers
	var config_error := config.validate()
	if config_error != "":
		generated_error = config_error
		return false
	var request_radius := config.radius_m
	var request_reference_radius := config.reference_radius_m
	var scale := request_radius / request_reference_radius
	var request_offset := noise_position_offset
	if config.seed != 0:
		var seed_rng := RandomNumberGenerator.new()
		seed_rng.seed = config.seed
		request_offset += Vector3(
			seed_rng.randf_range(-500.0, 500.0),
			seed_rng.randf_range(-500.0, 500.0),
			seed_rng.randf_range(-500.0, 500.0)
		)
	var box := world_size()
	var density_pc := PackedFloat32Array([
		0.0, 0.0, 0.0, request_radius,
		box, box, box, noise_scale,
		request_offset.x, request_offset.y, request_offset.z, noise_strength,
		lacunarity, persistence, noise_offset, 0.0,
		0.0, iso_level * scale, 0.0, 0.0,
	]).to_byte_array()
	density_pc.encode_s32(60, num_layers)
	density_pc.encode_u32(64, resolution)
	var shape_data := _make_shape_data(request_reference_radius)
	_request = {
		"resolution": resolution, "radius": request_radius, "surface_radius": max_surface_radius(),
		"world_size": box, "iso_level": iso_level * scale, "density_pc": density_pc,
		"shape_data": shape_data, "triangle_budget": config.triangle_budget_per_cell,
		"volcano_count": config.volcano_count,
		"volcano_size_ratio": config.volcano_size_ratio,
		"volcano_height_ratio": config.volcano_height_ratio,
		"terrain_style": config.terrain_style, "opening_style": config.opening_style,
	}
	generated_error = ""
	_start_usec = Time.get_ticks_usec()
	_set_state(State.GPU)
	RenderingServer.call_on_render_thread(_generate_render)
	return true


func _generate_render() -> void:
	var res: int = _request.resolution
	var budget: float = _request.triangle_budget
	if res != _buffer_resolution or not is_equal_approx(budget, _buffer_budget):
		_allocate_volume_buffers(res, budget)
	_rd.buffer_update(_shape_buf, 0, _request.shape_data.size(), _request.shape_data)

	_rd.buffer_update(_counter_buf, 0, 4, PackedInt32Array([0]).to_byte_array())

	var groups := int(ceil(float(res) / float(WG)))

	var box: float = _request.world_size
	var density_pc: PackedByteArray = _request.density_pc

	# TerrainCreator.cs:123 hands marching cubes the negated iso level.
	var mc_pc := PackedFloat32Array([
		box, box, box, -float(_request.iso_level),
		0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	mc_pc.encode_u32(16, res)
	mc_pc.encode_u32(20, _max_triangles)

	var cl := _rd.compute_list_begin()
	if _request.volcano_count > 0:
		var setup_pc := density_pc.duplicate()
		setup_pc.encode_u32(72, 1)
		_rd.compute_list_bind_compute_pipeline(cl, _pipelines["density"])
		_rd.compute_list_bind_uniform_set(cl, _uniform_sets["density"], 0)
		_rd.compute_list_set_push_constant(cl, setup_pc, setup_pc.size())
		_rd.compute_list_dispatch(cl, 1, 1, 1)
		_rd.compute_list_add_barrier(cl)
		density_pc.encode_u32(72, 0)

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
	if _request.volcano_count > 0:
		_request["shape_readback"] = _rd.buffer_get_data(_shape_buf, 0, 29 * 16)
	var count := count_bytes.decode_u32(0)
	if count > _max_triangles:
		generated_error = "Planet generation exceeded triangle budget (%d triangles, capacity %d)" % [count, _max_triangles]
		count = 0
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
			generated_radius = _request.radius
			generated_surface_radius = _request.surface_radius
			generated_world_size = _request.world_size
			generated_resolution = _request.resolution
			generated_volcano_size_ratio = _request.volcano_size_ratio
			generated_volcano_height_ratio = _request.volcano_height_ratio
			generated_terrain_style = _request.terrain_style
			generated_opening_style = _request.opening_style
			generated_volcanoes = _read_volcano_anchors()
			_set_state(State.IDLE)
			density_texture_changed.emit()
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


func max_surface_radius() -> float:
	var amplitude_sum := 0.0
	var amplitude := 1.0
	for i in num_layers:
		amplitude_sum += amplitude
		amplitude *= persistence
	var scale := radius / config.reference_radius_m
	var relief_bound := 1.3 if config.terrain_style == PlanetConfig.TerrainStyle.CONTINENTAL else amplitude_sum
	var relief_extent := (relief_bound + absf(noise_offset)) * absf(noise_strength) * config.mountain_strength
	var continent_extent := config.continent_strength * config.reference_radius_m * 0.16
	var surface_radius := radius + maxf(0.0, (relief_extent + continent_extent) * scale + absf(iso_level) * scale)
	if config.volcano_count > 0:
		surface_radius += radius * (config.volcano_height_ratio + 0.02)
	if config.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL:
		surface_radius += radius * config.fragment_separation_ratio * config.opening_strength
	return surface_radius


## Side of the sampled volume, sized so the tallest peak still fits inside.
func world_size() -> float:
	return max_surface_radius() * 2.0 * WORLD_SIZE_MARGIN


func _make_shape_data(reference_radius: float) -> PackedByteArray:
	var data := PackedFloat32Array()
	data.resize(116)
	data[0] = reference_radius
	data[1] = config.continent_strength
	data[2] = config.mountain_strength
	data[3] = config.warp_strength
	data[4] = config.opening_strength
	data[5] = config.core_fraction
	data[6] = config.crust_fraction
	data[7] = float(config.opening_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed ^ 0x6d2b79f5
	var first_direction := Vector3(0.2, 0.15, 1.0).normalized()
	var fragment_axes := _make_fragment_axes()
	for opening_index in 8:
		var offset := 8 + opening_index * 8
		if opening_index >= config.opening_count:
			continue
		var direction := first_direction
		if config.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL:
			direction = fragment_axes[opening_index]
		elif opening_index > 0:
			var y := rng.randf_range(-1.0, 1.0)
			var angle := rng.randf_range(0.0, TAU)
			var planar := sqrt(maxf(0.0, 1.0 - y * y))
			direction = Vector3(cos(angle) * planar, y, sin(angle) * planar)
		var width := 0.42 if opening_index == 0 else rng.randf_range(0.13, 0.22)
		var a := direction * 1.4
		var b := direction * config.core_fraction * 0.88
		data[offset] = a.x
		data[offset + 1] = a.y
		data[offset + 2] = a.z
		data[offset + 3] = width * config.opening_strength
		data[offset + 4] = b.x
		data[offset + 5] = b.y
		data[offset + 6] = b.z
	data[72] = float(config.volcano_count)
	data[73] = config.volcano_size_ratio
	data[74] = config.volcano_height_ratio
	data[75] = PlanetConfig.VOLCANO_FLOOR_FRACTION
	data[108] = float(config.terrain_style)
	data[109] = float(config.opening_style)
	data[110] = config.fragment_separation_ratio
	data[111] = PlanetConfig.VOLCANO_CRATER_BOTTOM_RATIO
	data[112] = PlanetConfig.VOLCANO_CRATER_TOP_RATIO
	data[113] = PlanetConfig.SHATTERED_BELT_AXIS.x
	data[114] = PlanetConfig.SHATTERED_BELT_AXIS.y
	data[115] = PlanetConfig.SHATTERED_BELT_AXIS.z
	var volcano_axes := _make_volcano_axes(data)
	for volcano_index in config.volcano_count:
		var offset: int = 76 + volcano_index * 4
		var axis: Vector3 = volcano_axes[volcano_index]
		data[offset] = axis.x
		data[offset + 1] = axis.y
		data[offset + 2] = axis.z
	return data.to_byte_array()


func _make_fragment_axes() -> PackedVector3Array:
	var axes := PackedVector3Array()
	var forward := Vector3(0.2, 0.15, 1.0).normalized()
	var tangent := forward.cross(Vector3.UP).normalized()
	var bitangent := forward.cross(tangent).normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed ^ 0x187ba921
	var turn := rng.randf_range(0.0, TAU)
	axes.append(forward)
	for index in range(1, config.opening_count):
		var z := 1.0 - 2.0 * float(index) / float(config.opening_count - 1)
		var angle := turn + float(index) * PI * (3.0 - sqrt(5.0))
		var planar := sqrt(maxf(0.0, 1.0 - z * z))
		axes.append((forward * z + (tangent * cos(angle) + bitangent * sin(angle)) * planar).normalized())
	return axes


func _make_volcano_axes(shape_data: PackedFloat32Array) -> PackedVector3Array:
	var axes := PackedVector3Array()
	if config.volcano_count <= 0:
		return axes
	var rng := RandomNumberGenerator.new()
	rng.seed = config.seed ^ 0x2c1b3c6d
	var first_direction := Vector3(0.15, 0.48, 1.0).normalized()
	first_direction = first_direction.rotated(Vector3.RIGHT, rng.randf_range(-0.18, 0.18))
	first_direction = first_direction.rotated(Vector3.UP, rng.randf_range(-0.16, 0.16))
	var opening_axes := PackedVector4Array()
	for opening_index in config.opening_count:
		var offset := 8 + opening_index * 8
		var opening_axis := Vector3(shape_data[offset], shape_data[offset + 1], shape_data[offset + 2]).normalized()
		var opening_width := shape_data[offset + 3]
		opening_axes.append(Vector4(opening_axis.x, opening_axis.y, opening_axis.z, opening_width))
	for volcano_index in config.volcano_count:
		var best := first_direction if volcano_index == 0 else Vector3.UP
		var best_score := -INF
		var attempts := 64 if volcano_index > 0 or config.opening_strength > 0.0 else 1
		for attempt in attempts:
			var candidate := first_direction if volcano_index == 0 and attempt == 0 else Vector3.ZERO
			if volcano_index > 0 or attempt > 0:
				var y := rng.randf_range(-1.0, 1.0)
				var angle := rng.randf_range(0.0, TAU)
				var planar := sqrt(maxf(0.0, 1.0 - y * y))
				candidate = Vector3(cos(angle) * planar, y, sin(angle) * planar)
			var score := PI
			for other in axes:
				score = minf(score, candidate.angle_to(other))
			if config.opening_strength > 0.0:
				if config.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL:
					var nearest := 0
					var best_dot := -INF
					for index in opening_axes.size():
						var opening := opening_axes[index]
						var alignment := candidate.dot(Vector3(opening.x, opening.y, opening.z))
						if alignment > best_dot:
							best_dot = alignment
							nearest = index
					var opening := opening_axes[nearest]
					var site := Vector3(opening.x, opening.y, opening.z)
					score = minf(score, absf(candidate.dot(PlanetConfig.SHATTERED_BELT_AXIS.normalized())) - config.volcano_size_ratio - 0.16)
					if nearest == 0:
						score = -PI
					for index in opening_axes.size():
						if index == nearest:
							continue
						var other := opening_axes[index]
						var plane := (site - Vector3(other.x, other.y, other.z)).normalized()
						score = minf(score, candidate.dot(plane) - config.volcano_size_ratio - 0.04)
				else:
					for opening in opening_axes:
						var exclusion := config.volcano_size_ratio + opening.w + 0.05
						score = minf(score, candidate.angle_to(Vector3(opening.x, opening.y, opening.z)) - exclusion)
			if score > best_score:
				best_score = score
				best = candidate
			if score > config.volcano_size_ratio * 2.0 + 0.05:
				break
		axes.append(best)
	return axes


func _read_volcano_anchors() -> PackedVector4Array:
	var result := PackedVector4Array()
	if _request.volcano_count <= 0 or not _request.has("shape_readback"):
		return result
	var values: PackedFloat32Array = _request.shape_readback.to_float32_array()
	for volcano_index in _request.volcano_count:
		var offset: int = 76 + volcano_index * 4
		if values[offset + 3] > 0.0:
			result.append(Vector4(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]))
	return result
