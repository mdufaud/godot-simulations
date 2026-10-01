class_name HeightfieldTerrain extends RefCounted
## GPU multi-material heightfield terrain. Each cell of the grid is a column
## of four channels — sand height, water depth, snow depth and suspended
## sediment (rgba32f, equivalent column heights in metres). Brushes and climate
## precede inertial pipe fluxes and conservative water/sediment gathering, then
## snow creep and sand relaxation. Rain, snowfall and uplift add material;
## evaporation and brushes can remove it. Internal transfers conserve mass
## within floating-point rounding. Terrain and water render directly from
## the GPU field; velocity drives the water material.
##
## All stages share one push-constant layout (hf_common.comp); each ping-pong
## pass runs an even number of dispatches so the frame's result lands back in
## tex 0 — the RID the render material is bound to.

const SHADER_DIR := "res://shaders/terrain/"
const TIMESTAMP_PREFIX := "terrain/"

## Each hydraulic substep updates flux before gathering the field. Only the
## gather toggles field parity; the even count returns field and flux to tex 0.
const RIVER_ITERATIONS := 2
const STAGES := ["flow_sand", "river_flux", "flow_rivers", "flow_snow", "climate", "tool"]

## Point queries (props resting on the surface). Results land one frame later.
const MAX_QUERY_POINTS := 64
const MAX_SUMMIT_SOURCES := 8

var config: TerrainConfig = TerrainConfig.new()
var grid_n := 512
var world_size := 4.0
var repose_deg := 33.0
var flow_rate := 0.11
var iterations := 10

## Water and transport: conductance, capacity-model gains, channel jitter.
var water_flow_rate := 0.55
var erosion_rate := 0.15
var sediment_capacity := 0.8
var stochasticity := 0.15
var rain_rate_m_s := 0.0
var deposition_gain := 0.6
var uplift_rate_m_s := 0.0
var uplift_mode: int = TerrainConfig.UpliftMode.NONE
var uplift_radius_fraction := 0.3
var snowline_m := -1.0
var summit_sources := PackedVector4Array()

## Snow: steep cohesion angle, creep rate, and the per-pair shed cap that
## bounds the avalanche release wave.
var snow_repose_deg := 50.0
var snow_enabled := true
var snow_flow_rate := 0.05
var snow_cap := 0.12
var snow_iterations := 2

## Climate: melt moves snow into water, evaporation dries it, snowfall
## deposits new snow above the snowline, freeze turns standing water into snow; wet
## sand holds up to wet_gain times steeper, saturating at water_sat_m of water.
var melt_rate_m_s := 0.0
var evap_rate_m_s := 0.02
var infiltration_rate_m_s := 0.0
var snowfall_rate_m_s := 0.0
var freeze_rate_m_s := 0.0
var wet_gain := 0.6
var water_sat_m := 0.04

## What the host sculpts with. Never null; set [member TerrainBrush.mode] to
## [constant TerrainBrush.NONE] to leave the surface alone.
var brush := TerrainBrush.new()
## Second slot for props (a ball ploughing through the surface), applied in
## the same tool dispatch as the user brush.
var contact_brush := TerrainBrush.new()

var initialized := false
var profiling := false

var _rd: RenderingDevice
## Pristine copy of the owner's config, taken at the first init_render —
## init_render then mirrors the live solver state into [member config] for
## validation, so a later duplicate would capture clobbered values.
## reset_to_config reads this, or a reseed would inherit the previous
## scene's drags.
var _defaults: TerrainConfig = TerrainConfig.new()
var _defaults_initialized := false
var _shaders := {}
var _pipelines := {}
var _sets := {}
var _tex := [RID(), RID()]
var _flux := [RID(), RID()]
var _velocity := RID()
var _hydro_params := RID()
var _summit_buffer := RID()
var _seed_data := PackedFloat32Array()
var _frames := 0
var _timing_store := GpuTimingStore.new()

# Async point queries: pending points queued from the main thread, one
# in/out buffer pair, results published back one generation later.
var _query_points_pending := PackedVector2Array()
var _query_has_pending := false
var _query_submitted_count := 0
var _query_generation := 0
var _query_latest := PackedVector4Array()
var _query_results_valid := false
var _query_revision := 0
var _query_in := RID()
var _query_out := RID()


func cell_size() -> float:
	return world_size / float(grid_n)


## Restores every user-tweakable parameter to the owner's config defaults.
## Hosts call this when the scene (preset) changes, then apply their preset
## overrides, so slider drags never leak from one scene into the next.
func reset_to_config() -> void:
	summit_sources = PackedVector4Array()
	# iterations is owned by the quality tier (never preset- or slider-driven),
	# so it must survive this reset or a tier switch that rebuilds the grid
	# would lose its settle count.
	repose_deg = _defaults.repose_angle_deg
	flow_rate = _defaults.flow_rate
	water_flow_rate = _defaults.water_flow_rate
	erosion_rate = _defaults.erosion_rate
	sediment_capacity = _defaults.sediment_capacity
	stochasticity = _defaults.stochasticity
	rain_rate_m_s = _defaults.rain_rate_m_s
	deposition_gain = _defaults.deposition_gain
	uplift_rate_m_s = _defaults.uplift_rate_m_s
	uplift_mode = _defaults.uplift_mode
	uplift_radius_fraction = _defaults.uplift_radius_fraction
	snowline_m = _defaults.snowline_m
	snow_enabled = _defaults.snow_enabled
	snow_repose_deg = _defaults.snow_repose_angle_deg
	snow_flow_rate = _defaults.snow_flow_rate
	snow_iterations = _defaults.snow_pass_iterations
	snow_cap = 0.12
	melt_rate_m_s = _defaults.melt_rate_m_s
	evap_rate_m_s = _defaults.evap_rate_m_s
	infiltration_rate_m_s = _defaults.infiltration_rate_m_s
	snowfall_rate_m_s = _defaults.snowfall_rate_m_s
	freeze_rate_m_s = _defaults.freeze_rate_m_s
	wet_gain = _defaults.wet_gain
	water_sat_m = _defaults.water_sat_m


func get_height_tex_rid() -> RID:
	return _tex[0]


func get_flux_tex_rid() -> RID:
	return _flux[0]


func get_velocity_tex_rid() -> RID:
	return _velocity


## Queue world-space xz query points for the next step. Results land one frame
## later; read them with [method latest_results]. At most MAX_QUERY_POINTS
## are kept.
func submit_queries(points: PackedVector2Array) -> void:
	_query_points_pending = points.slice(0, mini(points.size(), MAX_QUERY_POINTS))
	_query_has_pending = true


## Last completed query results, one vec4 per submitted slot:
## (total height, water depth, snow depth, valid).
func latest_results() -> PackedVector4Array:
	return _query_latest


func query_results_valid() -> bool:
	return _query_results_valid


func query_revision() -> int:
	return _query_revision


func set_summit_sources(points: PackedVector2Array, radius_m: float, rate_m_s: float) -> void:
	var sources := PackedVector4Array()
	for point in points.slice(0, MAX_SUMMIT_SOURCES):
		sources.append(Vector4(point.x, point.y, radius_m, rate_m_s))
	summit_sources = sources


## grid_n * grid_n sand column heights, row-major, x fastest. Water, snow and
## sediment start empty; [method set_seed_channels] seeds them explicitly.
func set_seed(heights: PackedFloat32Array) -> void:
	set_seed_channels(heights, PackedFloat32Array(), PackedFloat32Array())


## grid_n * grid_n floats per channel (missing channels seed to zero).
func set_seed_channels(sand: PackedFloat32Array, water: PackedFloat32Array,
		snow: PackedFloat32Array, sediment := PackedFloat32Array()) -> void:
	var cells := grid_n * grid_n
	var interleaved := PackedFloat32Array()
	interleaved.resize(cells * 4)
	for i in cells:
		interleaved[i * 4] = sand[i] if i < sand.size() else 0.0
		interleaved[i * 4 + 1] = water[i] if i < water.size() else 0.0
		interleaved[i * 4 + 2] = snow[i] if i < snow.size() else 0.0
		interleaved[i * 4 + 3] = sediment[i] if i < sediment.size() else 0.0
	_seed_data = interleaved


func init_render() -> void:
	if not _defaults_initialized:
		_defaults = config.duplicate()
		_defaults_initialized = true
	config.grid_size = grid_n
	config.world_size_m = world_size
	config.repose_angle_deg = repose_deg
	config.flow_rate = flow_rate
	config.flow_iterations = iterations
	config.water_flow_rate = water_flow_rate
	config.erosion_rate = erosion_rate
	config.sediment_capacity = sediment_capacity
	config.stochasticity = stochasticity
	config.rain_rate_m_s = rain_rate_m_s
	config.deposition_gain = deposition_gain
	config.uplift_rate_m_s = uplift_rate_m_s
	config.uplift_mode = uplift_mode
	config.uplift_radius_fraction = uplift_radius_fraction
	config.snowline_m = snowline_m
	config.snow_enabled = snow_enabled
	config.snow_repose_angle_deg = snow_repose_deg
	config.snow_flow_rate = snow_flow_rate
	config.snow_pass_iterations = snow_iterations
	config.melt_rate_m_s = melt_rate_m_s
	config.evap_rate_m_s = evap_rate_m_s
	config.infiltration_rate_m_s = infiltration_rate_m_s
	config.snowfall_rate_m_s = snowfall_rate_m_s
	config.freeze_rate_m_s = freeze_rate_m_s
	config.wet_gain = wet_gain
	config.water_sat_m = water_sat_m
	var config_error := config.validate()
	if config_error != "":
		push_error("Terrain config: %s" % config_error)
		return
	_rd = GpuPreflight.device("HeightfieldTerrain")
	if _rd == null:
		return

	var common := FileAccess.get_file_as_string(SHADER_DIR + "hf_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + "hf_" + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "hf_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("Terrain stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	if _seed_data.size() != grid_n * grid_n * 4:
		push_error("Terrain seed size mismatch: %d != %d" % [
			_seed_data.size(), grid_n * grid_n * 4])
		return

	var fmt := RDTextureFormat.new()
	fmt.width = grid_n
	fmt.height = grid_n
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var seed_bytes := _seed_data.to_byte_array()
	_tex[0] = _rd.texture_create(fmt, RDTextureView.new(), [seed_bytes])
	_tex[1] = _rd.texture_create(fmt, RDTextureView.new(), [seed_bytes])
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(grid_n * grid_n * 16)
	zero_bytes.fill(0)
	_flux[0] = _rd.texture_create(fmt, RDTextureView.new(), [zero_bytes])
	_flux[1] = _rd.texture_create(fmt, RDTextureView.new(), [zero_bytes])
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	zero_bytes.resize(grid_n * grid_n * 8)
	_velocity = _rd.texture_create(fmt, RDTextureView.new(), [zero_bytes])
	_hydro_params = _rd.uniform_buffer_create(16, _pack_hydro_params())
	_summit_buffer = _rd.storage_buffer_create(16 * (MAX_SUMMIT_SOURCES + 1), _pack_summit_sources())

	# Parity 0 reads tex 0 and writes tex 1; parity 1 the reverse. Every
	# ping-pong stage of a frame runs an even number of dispatches, so the
	# frame's result lands back in tex 0 — the one RID the render material
	# is bound to. The tool and climate stages write tex 0 in place.
	# Explicit list: "query" also lives in _shaders across re-inits and has
	# buffer bindings, not the image pair below.
	for stage in STAGES:
		var sets := []
		for parity in 2:
			var u0 := RDUniform.new()
			u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u0.binding = 0
			u0.add_id(_tex[parity])
			var u1 := RDUniform.new()
			u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u1.binding = 1
			u1.add_id(_tex[1 - parity])
			var hydro := RDUniform.new()
			hydro.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
			hydro.binding = 4
			hydro.add_id(_hydro_params)
			var uniforms: Array[RDUniform] = [u0, u1, hydro]
			if stage == "climate":
				var sources := RDUniform.new()
				sources.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				sources.binding = 5
				sources.add_id(_summit_buffer)
				uniforms.append(sources)
			if stage == "river_flux" or stage == "flow_rivers":
				var u2 := RDUniform.new()
				u2.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u2.binding = 2
				u2.add_id(_flux[parity] if stage == "river_flux" else _flux[1 - parity])
				var u3 := RDUniform.new()
				u3.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u3.binding = 3
				u3.add_id(_flux[1 - parity] if stage == "river_flux" else _velocity)
				uniforms.append(u2)
				uniforms.append(u3)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_sets[stage] = sets

	# Point-query stage: standalone shader (own bindings and push constant),
	# reading the settled tex 0.
	var query_spirv := ShaderCache.compile(_rd, "hf_query",
		"#version 450\n\n" + FileAccess.get_file_as_string(SHADER_DIR + "hf_query.comp"))
	if not query_spirv.compile_error_compute.is_empty():
		push_error("Terrain stage 'query' compile error:\n%s" % query_spirv.compile_error_compute)
		return
	_shaders["query"] = _rd.shader_create_from_spirv(query_spirv)
	_pipelines["query"] = _rd.compute_pipeline_create(_shaders["query"])
	_query_in = _rd.storage_buffer_create(MAX_QUERY_POINTS * 8)
	_query_out = _rd.storage_buffer_create(MAX_QUERY_POINTS * 16)
	var q_in := RDUniform.new()
	q_in.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	q_in.binding = 0
	q_in.add_id(_query_in)
	var q_out := RDUniform.new()
	q_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	q_out.binding = 1
	q_out.add_id(_query_out)
	var q_img := RDUniform.new()
	q_img.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	q_img.binding = 2
	q_img.add_id(_tex[0])
	_sets["query"] = [_rd.uniform_set_create([q_in, q_out, q_img], _shaders["query"], 0)]

	_query_generation += 1
	_query_results_valid = false
	# Every restart replays the same frame seeds, so a reseed is bit-reproducible.
	_frames = 0
	initialized = true


func step_render(dt: float) -> void:
	if not initialized:
		return
	_read_timings()
	_frames += 1
	var pc := _pack_push_constant(dt)
	var river_pc := _pack_push_constant(dt / float(RIVER_ITERATIONS))
	var hydro := _pack_hydro_params()
	_rd.buffer_update(_hydro_params, 0, hydro.size(), hydro)
	var sources := _pack_summit_sources()
	_rd.buffer_update(_summit_buffer, 0, sources.size(), sources)
	var groups := ceili(float(grid_n) / 16.0)
	var iters := iterations + (iterations & 1)
	var snow_iters := snow_iterations + (snow_iterations & 1) if snow_enabled else 0

	if profiling:
		_rd.capture_timestamp(TIMESTAMP_PREFIX + "start")
	var cl := _rd.compute_list_begin()
	var any_tool := not brush.idle() or not contact_brush.idle()
	if any_tool and dt > 0.0:
		_dispatch(cl, "tool", 0, pc, groups)
	if dt > 0.0:
		_dispatch(cl, "climate", 0, pc, groups)
		for i in RIVER_ITERATIONS:
			_dispatch(cl, "river_flux", i & 1, river_pc, groups)
			_dispatch(cl, "flow_rivers", i & 1, river_pc, groups)
	if profiling:
		_rd.capture_timestamp(TIMESTAMP_PREFIX + "hydraulic")
	for i in snow_iters:
		_dispatch(cl, "flow_snow", i & 1, pc, groups)
	for i in iters:
		_dispatch(cl, "flow_sand", i & 1, pc, groups)
	_rd.compute_list_end()
	# buffer_update must run between compute lists, so the query pass gets its
	# own list after the flows: it samples the settled tex 0.
	_dispatch_pending_queries()
	if profiling:
		_rd.capture_timestamp(TIMESTAMP_PREFIX + "end")


## Render thread. Uploads the pending points, dispatches one query pass and
## kicks the async readback.
func _dispatch_pending_queries() -> void:
	if not _query_has_pending:
		return
	_query_has_pending = false
	var points := _query_points_pending
	if points.is_empty():
		return
	_query_submitted_count = points.size()
	var in_bytes := PackedByteArray()
	in_bytes.resize(MAX_QUERY_POINTS * 8)
	for i in points.size():
		in_bytes.encode_float(i * 8, points[i].x)
		in_bytes.encode_float(i * 8 + 4, points[i].y)
	_rd.buffer_update(_query_in, 0, in_bytes.size(), in_bytes)
	var pc := PackedByteArray()
	pc.resize(16)
	pc.encode_float(0, cell_size())
	pc.encode_float(4, world_size)
	# All-float: the shader sees one vec4, int-typed bit patterns would read
	# back as denormals and int(info.w) would collapse to 0.
	pc.encode_float(8, float(grid_n))
	pc.encode_float(12, float(points.size()))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines["query"])
	_rd.compute_list_bind_uniform_set(cl, _sets["query"][0], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, ceili(float(points.size()) / 64.0), 1, 1)
	_rd.compute_list_end()
	_rd.buffer_get_data_async(_query_out,
		_store_query_results.bind(_query_submitted_count, _query_generation),
		0, MAX_QUERY_POINTS * 16)


# Render thread: decode the readback, then hop to the main thread. Only the
# submitted slots are meaningful; the rest of the buffer stays stale.
func _store_query_results(data: PackedByteArray, submitted_count: int, generation: int) -> void:
	var floats := data.to_float32_array()
	var results := PackedVector4Array()
	var count := mini(submitted_count, MAX_QUERY_POINTS)
	results.resize(count)
	for i in count:
		results[i] = Vector4(floats[i * 4], floats[i * 4 + 1],
			floats[i * 4 + 2], floats[i * 4 + 3])
	_apply_query_results.call_deferred(results, generation)


# Main thread.
func _apply_query_results(results: PackedVector4Array, generation: int) -> void:
	if generation != _query_generation:
		return
	_query_latest = results
	_query_results_valid = true
	_query_revision += 1


func _dispatch(cl: int, stage: String, parity: int, pc: PackedByteArray, groups: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _sets[stage][parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(dt: float) -> PackedByteArray:
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, brush.pos_m.x)
	pc.encode_float(4, brush.pos_m.y)
	pc.encode_float(8, brush.radius_m)
	pc.encode_float(12, brush.strength)
	pc.encode_float(16, contact_brush.pos_m.x)
	pc.encode_float(20, contact_brush.pos_m.y)
	pc.encode_float(24, contact_brush.radius_m)
	pc.encode_float(28, contact_brush.strength)
	pc.encode_float(32, tan(deg_to_rad(repose_deg)) * cell_size())
	pc.encode_float(36, flow_rate)
	pc.encode_float(40, cell_size())
	pc.encode_float(44, dt)
	pc.encode_float(48, melt_rate_m_s)
	pc.encode_float(52, evap_rate_m_s)
	pc.encode_float(56, wet_gain)
	pc.encode_float(60, water_sat_m)
	pc.encode_float(64, water_flow_rate)
	pc.encode_float(68, erosion_rate)
	pc.encode_float(72, sediment_capacity)
	pc.encode_float(76, stochasticity)
	pc.encode_float(80, tan(deg_to_rad(snow_repose_deg)) * cell_size())
	pc.encode_float(84, snow_flow_rate)
	pc.encode_float(88, snow_cap)
	pc.encode_s32(96, grid_n)
	pc.encode_s32(100, brush.mode)
	pc.encode_s32(104, contact_brush.mode)
	pc.encode_s32(108, _frames)
	pc.encode_float(112, snowfall_rate_m_s)
	pc.encode_float(116, freeze_rate_m_s)
	pc.encode_float(120, snowline_m)
	pc.encode_float(124, uplift_radius_fraction)
	return pc


func _pack_hydro_params() -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(16)
	data.encode_float(0, rain_rate_m_s)
	data.encode_float(4, deposition_gain)
	data.encode_float(8, uplift_rate_m_s)
	data.encode_float(12, float(uplift_mode))
	return data


func _pack_summit_sources() -> PackedByteArray:
	var sources := summit_sources
	var count := mini(sources.size(), MAX_SUMMIT_SOURCES)
	var data := PackedByteArray()
	data.resize(16 * (MAX_SUMMIT_SOURCES + 1))
	data.encode_float(0, float(count))
	data.encode_float(4, infiltration_rate_m_s)
	data.encode_float(8, 1.0 if snow_enabled else 0.0)
	for i in count:
		var offset := 16 * (i + 1)
		data.encode_float(offset, sources[i].x)
		data.encode_float(offset + 4, sources[i].y)
		data.encode_float(offset + 8, sources[i].z)
		data.encode_float(offset + 12, sources[i].w)
	return data


# Render thread; reads last frame's pair of timestamps.
func _read_timings() -> void:
	var parsed := GpuTimings.read(_rd, TIMESTAMP_PREFIX)
	if parsed.is_empty():
		return
	_timing_store.publish(parsed)


func get_timings() -> Dictionary:
	return _timing_store.snapshot()


## Render thread only. Reads the full field back for tests and probes; the
## simulation loop never calls this (it would stall the pipeline).
func readback_cells() -> PackedFloat32Array:
	if _rd == null or not _tex[0].is_valid():
		return PackedFloat32Array()
	return _rd.texture_get_data(_tex[0], 0).to_float32_array()


func free_render() -> void:
	initialized = false
	_query_generation += 1
	_query_has_pending = false
	_query_points_pending = PackedVector2Array()
	_query_results_valid = false
	_query_latest = PackedVector4Array()
	if _rd == null:
		return
	# Sets first: freeing a buffer/texture invalidates the sets referencing it,
	# so a later explicit free would hit an already-dead ID.
	for stage in _sets:
		for s in _sets[stage]:
			if s.is_valid():
				_rd.free_rid(s)
	_sets.clear()
	if _hydro_params.is_valid():
		_rd.free_rid(_hydro_params)
	_hydro_params = RID()
	if _summit_buffer.is_valid():
		_rd.free_rid(_summit_buffer)
	_summit_buffer = RID()
	for i in 2:
		if _tex[i].is_valid():
			_rd.free_rid(_tex[i])
		_tex[i] = RID()
		if _flux[i].is_valid():
			_rd.free_rid(_flux[i])
		_flux[i] = RID()
	if _velocity.is_valid():
		_rd.free_rid(_velocity)
	_velocity = RID()
	for stage in _pipelines:
		if _pipelines[stage].is_valid():
			_rd.free_rid(_pipelines[stage])
	_pipelines.clear()
	for stage in _shaders:
		if _shaders[stage].is_valid():
			_rd.free_rid(_shaders[stage])
	_shaders.clear()
	if _query_in.is_valid():
		_rd.free_rid(_query_in)
		_query_in = RID()
	if _query_out.is_valid():
		_rd.free_rid(_query_out)
		_query_out = RID()
