class_name SphFluidSolver
extends RefCounted
## GPU dual-density SPH (SebLague / Clavet: density + near-density equation of
## state). Shares the PBF solver's dense counting-sort grid, ping-pong reorder,
## Texture2DRD bridge and capture_timestamp profiling, but replaces the physics.
## Unlike PBF, velocity is physically reordered by the sort (SPH reads old
## velocity after the sort), so velocities are ping-ponged too.

const SHADER_DIR := "res://shaders/sph/"
const STAGES: Array[String] = [
	"grid_clear", "grid_scan", "grid_scan_blocks", "grid_add_back", "grid_scatter",
	"sph_external", "sph_density", "sph_pressure", "sph_viscosity", "sph_integrate",
	"foam_update", "foam_compact",
]
const WG := 256
const FOAM_UBO_SIZE := 96
const PLANET_UBO_SIZE := 48

var particle_count := 65536
## How many of those slots are live. Buffers are always allocated at
## particle_count; the kernels only ever see the first `active_count`, so a demo
## can start empty and fill up as fluid is poured in. -1 means "all of them".
var active_count := -1
var grid_dims := Vector3i(64, 64, 64)
var grid_origin := Vector3(-8.0, 0.0, -8.0)
var cell_size := 0.25
var h := 0.25
var spacing := 0.12
var substeps := 3
var gravity := Vector3(0.0, -9.8, 0.0)
var pressure_mult := 180.0
var near_pressure_mult := 12.0
var viscosity_strength := 0.14
var collision_damping := 0.15
var mode := 0.0

var tex_width := 256

# White particles (foam / spray / bubbles). Spawning is driven by the trapped-air
# metric computed in the pressure pass, so it is part of this solver rather than
# a standalone pass. Values come from SebLague's "Fluid ScreenSpace 2" scene (his
# C# field defaults are NOT what he ships with). Only the trapped-air threshold is
# ours: measured here, that metric peaks around 32 and sits at 10 for the 99th
# percentile, so his 15 gates all but a handful of particles out.
var foam_enabled := false
var foam_tex_width := 1024
var foam_spawn_rate := 120.0
# SebLague budgets 2.5 white particles per fluid particle (1.024M against 411k in
# "Fluid ScreenSpace 2"). Foam only reads as froth when sprites overlap into a
# sheet, and that needs the pool to outnumber the fluid several times over. At the
# default 65k particles this is ~164k slots, i.e. 10 MB of buffers.
var foam_budget_ratio := 2.5
# Spawning is held off entirely for the first `fade_start` seconds and then eased
# in over `fade_time`, squared (SebLague: spawnRateFadeStartTime / InTime). The
# initial drop is the most violent event the sim ever sees, and without this gate
# it alone produces more foam than the whole rest of the run.
var foam_spawn_fade_start := 0.2
var foam_spawn_fade_time := 0.35
var foam_trapped_min := 3.0
var foam_trapped_max := 25.0
var foam_ke_min := 15.0
var foam_ke_max := 30.0
var foam_life_min := 5.0
var foam_life_max := 15.0
# Remaining lifetime at which a particle starts shrinking away.
var foam_dissolve_time := 3.0
var foam_spawn_radius_scale := 1.0
var foam_bubble_buoyancy := 1.4
var foam_spray_drag := 0.04
var foam_bubble_scale := 0.3
var foam_scale_speed := 7.0
var foam_spray_max_neighbours := 5
var foam_bubble_min_neighbours := 15

# Planet mode. Zero gravity leaves the solver on its flat-world path: constant
# downward gravity and an axis-aligned box. Set planet_field to the density texture
# of a PlanetGenerator to collide against real terrain instead.
var planet_centre := Vector3.ZERO
var planet_gravity := 0.0
var planet_field := RID()
var planet_field_world_size := 0.0
var planet_skin := 0.1
var planet_normal_offset := 0.5

var initialized := false
var profiling := false

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _uniform_sets := {}
var _buffers := {}
var _tex_rid := RID()
var _foam_tex_rid := RID()
var _foam_ubo := RID()
var _planet_ubo := RID()
var _planet_sampler := RID()
## Bound at binding 18 when planet mode is off, since the shader declares the
## sampler unconditionally and every declared binding must be satisfied.
var _dummy_field := RID()
var _frame := 0
var _sim_time := 0.0
var _target_density := 1.0
var _seed_data := PackedFloat32Array()
var _parity := 0
var _timings := {}
var _timings_mutex := Mutex.new()


func get_position_tex_rid() -> RID:
	return _tex_rid


func get_foam_tex_rid() -> RID:
	return _foam_tex_rid


func live_count() -> int:
	return particle_count if active_count < 0 else mini(active_count, particle_count)


func foam_cap() -> int:
	return mini(foam_tex_width * foam_tex_width, int(float(particle_count) * foam_budget_ratio))


func set_seed_positions(seed: PackedFloat32Array) -> void:
	_seed_data = seed


## Teleports a contiguous slice of particle slots to new positions with zero
## velocity. Both parities are written, so the caller need not know which buffers
## are canonical this sub-step; the next sort re-bins them either way. Because the
## slots are cell-sorted, a slice is a spatially coherent clump, so this lifts a
## blob of fluid from wherever it was sitting and drops it somewhere new.
## Render-thread only.
func respawn_range(from: int, data: PackedFloat32Array) -> void:
	if not initialized:
		return
	@warning_ignore("integer_division")
	var count := data.size() / 4
	if from < 0 or count <= 0 or from + count > particle_count:
		return
	var bytes := data.to_byte_array()
	var zero := PackedByteArray()
	zero.resize(bytes.size())
	var off := from * 16
	for key in ["positions_a", "positions_b", "predicted_a", "predicted_b"]:
		_rd.buffer_update(_buffers[key], off, bytes.size(), bytes)
	for key in ["velocities_a", "velocities_b"]:
		_rd.buffer_update(_buffers[key], off, zero.size(), zero)


func init_render() -> void:
	_rd = RenderingServer.get_rendering_device()
	_target_density = _compute_rest_density()

	var common := FileAccess.get_file_as_string(SHADER_DIR + "sph_common.comp")
	for stage in STAGES:
		var stage_src := FileAccess.get_file_as_string(SHADER_DIR + stage + ".comp")
		var spirv := ShaderCache.compile(_rd, "sph_" + stage, "#version 450\n\n" + common + "\n" + stage_src)
		if not spirv.compile_error_compute.is_empty():
			push_error("SPH stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[stage] = shader
		_pipelines[stage] = _rd.compute_pipeline_create(shader)

	var n := particle_count
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var num_blocks := ceili(float(cells) / WG)
	var vec4_bytes := n * 16
	var zero_vec4 := PackedByteArray()
	zero_vec4.resize(vec4_bytes)
	var zero_f := PackedByteArray()
	zero_f.resize(n * 4)
	var zero_cells := PackedByteArray()
	zero_cells.resize(cells * 4)
	var zero_blocks := PackedByteArray()
	zero_blocks.resize(num_blocks * 4)

	var seed_bytes := _seed_data.to_byte_array()
	if seed_bytes.size() != vec4_bytes:
		push_error("SPH seed size mismatch: %d != %d" % [seed_bytes.size(), vec4_bytes])
		return

	_buffers["positions_a"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["positions_b"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["velocities_a"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["velocities_b"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["predicted_a"] = _rd.storage_buffer_create(vec4_bytes, seed_bytes)
	_buffers["predicted_b"] = _rd.storage_buffer_create(vec4_bytes, zero_vec4)
	_buffers["densities"] = _rd.storage_buffer_create(n * 4, zero_f)
	_buffers["near_densities"] = _rd.storage_buffer_create(n * 4, zero_f)
	_buffers["cell_count"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["cell_start"] = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers["block_sums"] = _rd.storage_buffer_create(num_blocks * 4, zero_blocks)

	var foam_n := foam_cap()
	var zero_foam := PackedByteArray()
	zero_foam.resize(foam_n * 16)
	var zero_counter := PackedByteArray()
	zero_counter.resize(8)
	_buffers["foam_pos"] = _rd.storage_buffer_create(foam_n * 16, zero_foam)
	_buffers["foam_vel"] = _rd.storage_buffer_create(foam_n * 16, zero_foam)
	_buffers["foam_pos_c"] = _rd.storage_buffer_create(foam_n * 16, zero_foam)
	_buffers["foam_vel_c"] = _rd.storage_buffer_create(foam_n * 16, zero_foam)
	_buffers["foam_count"] = _rd.storage_buffer_create(8, zero_counter)
	_foam_ubo = _rd.uniform_buffer_create(FOAM_UBO_SIZE, _pack_foam_ubo(1.0 / 60.0))
	_planet_ubo = _rd.uniform_buffer_create(PLANET_UBO_SIZE, _pack_planet_ubo())
	_dummy_field = _create_dummy_field()
	_planet_sampler = _create_field_sampler()

	var fmt := RDTextureFormat.new()
	fmt.width = tex_width
	fmt.height = tex_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_tex_rid = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rd.texture_clear(_tex_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var foam_fmt := RDTextureFormat.new()
	foam_fmt.width = foam_tex_width
	foam_fmt.height = foam_tex_width
	foam_fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	foam_fmt.usage_bits = fmt.usage_bits
	_foam_tex_rid = _rd.texture_create(foam_fmt, RDTextureView.new(), [])
	_rd.texture_clear(_foam_tex_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	_build_uniform_sets()

	_parity = 0
	initialized = true


func _build_uniform_sets() -> void:
	# Bindings 0/1/2 = src (canonical this sub-step), 8/9/11 = dst (cell-sorted);
	# parity swaps positions/velocities/predicted src<->dst each sub-step.
	# Bindings 10/15 are images, 16/17 uniform buffers and 18 a sampled texture; the
	# foam pool does not ping-pong, so both parities bind the same foam resources.
	var binding_orders := [
		["positions_a", "velocities_a", "predicted_a", "densities", "near_densities",
			"cell_count", "cell_start", "block_sums", "positions_b", "velocities_b",
			"", "predicted_b", "foam_pos", "foam_vel", "foam_count", "", "", "", "",
			"foam_pos_c", "foam_vel_c"],
		["positions_b", "velocities_b", "predicted_b", "densities", "near_densities",
			"cell_count", "cell_start", "block_sums", "positions_a", "velocities_a",
			"", "predicted_a", "foam_pos", "foam_vel", "foam_count", "", "", "", "",
			"foam_pos_c", "foam_vel_c"],
	]
	var field: RID = planet_field if planet_field.is_valid() else _dummy_field
	for stage in _uniform_sets:
		for set_rid in _uniform_sets[stage]:
			if _rd.uniform_set_is_valid(set_rid):
				_rd.free_rid(set_rid)
	_uniform_sets.clear()
	for stage in STAGES:
		var sets := []
		for parity in 2:
			var uniforms: Array[RDUniform] = []
			var order: Array = binding_orders[parity]
			for bi in order.size():
				var u := RDUniform.new()
				if bi == 10 or bi == 15:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
					u.add_id(_tex_rid if bi == 10 else _foam_tex_rid)
				elif bi == 16 or bi == 17:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
					u.add_id(_foam_ubo if bi == 16 else _planet_ubo)
				elif bi == 18:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
					u.add_id(_planet_sampler)
					u.add_id(field)
				else:
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
					u.add_id(_buffers[order[bi]])
				u.binding = bi
				uniforms.append(u)
			sets.append(_rd.uniform_set_create(uniforms, _shaders[stage], 0))
		_uniform_sets[stage] = sets


## Point the solver at a new terrain field. The RID changes whenever the planet's
## resolution changes, which invalidates every uniform set that referenced it.
func set_planet_field(field: RID) -> void:
	if field == planet_field:
		return
	planet_field = field
	if initialized:
		_build_uniform_sets()


func _create_dummy_field() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = 1
	fmt.height = 1
	fmt.depth = 1
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	# One texel of "outside the terrain", so a stray planet-mode dispatch collides
	# with nothing rather than pushing every particle somewhere arbitrary.
	var one := PackedFloat32Array([1.0]).to_byte_array()
	return _rd.texture_create(fmt, RDTextureView.new(), [one])


func _create_field_sampler() -> RID:
	var s := RDSamplerState.new()
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return _rd.sampler_create(s)


func step_render(dt: float) -> void:
	if not initialized:
		return
	_read_timings()
	dt = minf(dt, 1.0 / 60.0)
	var dt_sub := dt / float(substeps)
	_frame += 1
	_sim_time += dt
	_rd.buffer_update(_foam_ubo, 0, FOAM_UBO_SIZE, _pack_foam_ubo(dt))
	_rd.buffer_update(_planet_ubo, 0, PLANET_UBO_SIZE, _pack_planet_ubo())
	# Nothing poured yet: every stage below would dispatch zero groups, which the
	# rendering device rejects once per stage per frame.
	if live_count() == 0:
		return
	var n_groups := ceili(float(live_count()) / WG)
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var cell_groups := ceili(float(cells) / WG)
	var foam_groups := ceili(float(foam_cap()) / WG)

	_rd.capture_timestamp("sph/start")
	var cl := _rd.compute_list_begin()
	for s in substeps:
		var last := s == substeps - 1
		# Salting the seed per (frame, sub-step) stops every sub-step from
		# drawing the same random numbers and stacking foam on the same spots.
		var pc := _pack_push_constant(dt_sub, 1 if last else 0, _frame * substeps + s)
		_dispatch(cl, "grid_clear", pc, cell_groups)
		_dispatch(cl, "sph_external", pc, n_groups)
		_dispatch(cl, "grid_scan", pc, cell_groups)
		_dispatch(cl, "grid_scan_blocks", pc, 1)
		_dispatch(cl, "grid_add_back", pc, cell_groups)
		_dispatch(cl, "grid_scatter", pc, n_groups)
		cl = _mark(cl, "sph/grid")
		_dispatch(cl, "sph_density", pc, n_groups)
		cl = _mark(cl, "sph/density")
		_dispatch(cl, "sph_pressure", pc, n_groups)
		cl = _mark(cl, "sph/pressure")
		_dispatch(cl, "sph_viscosity", pc, n_groups)
		_dispatch(cl, "sph_integrate", pc, n_groups)
		cl = _mark(cl, "sph/integrate")
		# White particles advance once per frame (full dt) against the grid the
		# last sub-step just built, so this must run before the parity flip.
		if last and foam_enabled:
			_dispatch(cl, "foam_update", pc, foam_groups)
			_dispatch(cl, "foam_compact", pc, foam_groups)
			cl = _mark(cl, "sph/foam")
		_parity = 1 - _parity
	_rd.compute_list_end()
	_rd.capture_timestamp("sph/end")


# Timestamps cannot be captured inside an open compute list; split the list at
# group boundaries when profiling (the render graph re-merges adjacent lists).
func _mark(cl: int, name: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(name)
	return _rd.compute_list_begin()


# Render thread. Repeated names sum across sub-steps.
func _read_timings() -> void:
	var out := {}
	var prev_time := 0
	var start_time := 0
	var in_chain := false
	for i in _rd.get_captured_timestamps_count():
		var nm := _rd.get_captured_timestamp_name(i)
		if not nm.begins_with("sph/"):
			continue
		var t := _rd.get_captured_timestamp_gpu_time(i)
		if nm == "sph/start":
			start_time = t
			prev_time = t
			in_chain = true
			continue
		if not in_chain:
			continue
		var seg := nm.trim_prefix("sph/")
		if seg == "end":
			out["total"] = float(t - start_time) / 1e6
			in_chain = false
		else:
			out[seg] = out.get(seg, 0.0) + float(t - prev_time) / 1e6
		prev_time = t
	if out.is_empty():
		return
	_timings_mutex.lock()
	_timings = out
	_timings_mutex.unlock()


# Main thread. GPU times in milliseconds, lagging 1-2 frames.
func get_timings() -> Dictionary:
	_timings_mutex.lock()
	var copy := _timings.duplicate()
	_timings_mutex.unlock()
	return copy


func free_render() -> void:
	initialized = false
	if _rd == null:
		return
	for stage in _uniform_sets:
		for s in _uniform_sets[stage]:
			if s.is_valid():
				_rd.free_rid(s)
	for key in _buffers:
		if _buffers[key].is_valid():
			_rd.free_rid(_buffers[key])
	if _foam_ubo.is_valid():
		_rd.free_rid(_foam_ubo)
	if _planet_ubo.is_valid():
		_rd.free_rid(_planet_ubo)
	if _planet_sampler.is_valid():
		_rd.free_rid(_planet_sampler)
	if _dummy_field.is_valid():
		_rd.free_rid(_dummy_field)
	if _tex_rid.is_valid():
		_rd.free_rid(_tex_rid)
	if _foam_tex_rid.is_valid():
		_rd.free_rid(_foam_tex_rid)
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
	_tex_rid = RID()
	_foam_tex_rid = RID()
	_foam_ubo = RID()
	_planet_ubo = RID()
	_planet_sampler = RID()
	_dummy_field = RID()


func _dispatch(cl: int, stage: String, pc: PackedByteArray, groups: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage][_parity], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)


func _pack_push_constant(dt: float, last: int, seed: int = 0) -> PackedByteArray:
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var num_blocks := ceili(float(cells) / WG)
	var h2 := h * h
	var k_sp2 := 15.0 / (2.0 * PI * pow(h, 5))
	var k_sp3 := 15.0 / (PI * pow(h, 6))
	var k_sp2_grad := 15.0 / (PI * pow(h, 5))
	var k_sp3_grad := 45.0 / (PI * pow(h, 6))
	var k_poly6 := 315.0 / (64.0 * PI * pow(h, 9))

	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_float(0, grid_origin.x)
	pc.encode_float(4, grid_origin.y)
	pc.encode_float(8, grid_origin.z)
	pc.encode_float(12, cell_size)
	pc.encode_s32(16, grid_dims.x)
	pc.encode_s32(20, grid_dims.y)
	pc.encode_s32(24, grid_dims.z)
	pc.encode_s32(28, live_count())
	pc.encode_float(32, h)
	pc.encode_float(36, h2)
	pc.encode_float(40, k_sp2)
	pc.encode_float(44, k_sp3)
	pc.encode_float(48, k_sp2_grad)
	pc.encode_float(52, k_sp3_grad)
	pc.encode_float(56, k_poly6)
	pc.encode_float(60, 0.0)
	pc.encode_float(64, dt)
	pc.encode_float(68, _target_density)
	pc.encode_float(72, pressure_mult)
	pc.encode_float(76, near_pressure_mult)
	pc.encode_float(80, viscosity_strength)
	pc.encode_float(84, collision_damping)
	pc.encode_float(88, 0.0)
	pc.encode_float(92, 0.0)
	pc.encode_float(96, gravity.x)
	pc.encode_float(100, gravity.y)
	pc.encode_float(104, gravity.z)
	pc.encode_float(108, mode)
	pc.encode_s32(112, tex_width)
	pc.encode_s32(116, num_blocks)
	pc.encode_s32(120, last)
	pc.encode_s32(124, seed)
	return pc


# std140: three 16-byte rows. Mirrors the PlanetParams block in sph_common.comp.
func _pack_planet_ubo() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(PLANET_UBO_SIZE)
	b.encode_float(0, planet_centre.x)
	b.encode_float(4, planet_centre.y)
	b.encode_float(8, planet_centre.z)
	b.encode_float(12, planet_gravity)
	b.encode_float(16, planet_field_world_size)
	b.encode_float(20, planet_skin)
	b.encode_float(24, planet_normal_offset)
	b.encode_s32(32, 1 if planet_mode() else 0)
	return b


func planet_mode() -> bool:
	return planet_gravity > 0.0 and planet_field.is_valid()


# std140: six 16-byte rows. Mirrors the FoamParams block in sph_common.comp.
func _pack_foam_ubo(frame_dt: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(FOAM_UBO_SIZE)
	var fade := 1.0
	if foam_spawn_fade_time > 0.0:
		fade = clampf((_sim_time - foam_spawn_fade_start) / foam_spawn_fade_time, 0.0, 1.0)
	b.encode_float(0, foam_spawn_rate * fade * fade)
	b.encode_float(4, foam_trapped_min)
	b.encode_float(8, foam_trapped_max)
	b.encode_float(12, foam_ke_min)
	b.encode_float(16, foam_ke_max)
	b.encode_float(20, foam_life_min)
	b.encode_float(24, foam_life_max)
	b.encode_float(28, frame_dt)
	b.encode_float(32, foam_bubble_buoyancy)
	b.encode_float(36, foam_spray_drag)
	b.encode_float(40, foam_bubble_scale)
	b.encode_float(44, foam_scale_speed)
	b.encode_float(48, foam_dissolve_time)
	b.encode_float(52, foam_spawn_radius_scale)
	b.encode_s32(64, foam_spray_max_neighbours)
	b.encode_s32(68, foam_bubble_min_neighbours)
	b.encode_s32(72, foam_cap())
	b.encode_s32(76, foam_tex_width)
	b.encode_s32(80, 1 if foam_enabled else 0)
	return b


# Rest density = sum of the SpikyPow2 density kernel over a regular lattice at
# the spawn spacing. Auto-scales the pressure target to h/spacing.
func _compute_rest_density() -> float:
	var k_sp2 := 15.0 / (2.0 * PI * pow(h, 5))
	var sum := 0.0
	var steps := int(ceil(h / spacing))
	for x in range(-steps, steps + 1):
		for y in range(-steps, steps + 1):
			for z in range(-steps, steps + 1):
				var r := (Vector3(x, y, z) * spacing).length()
				if r < h:
					var v := h - r
					sum += k_sp2 * v * v
	return sum
