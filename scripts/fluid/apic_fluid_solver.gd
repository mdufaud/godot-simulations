class_name ApicFluidSolver
extends RefCounted

const CutGeometry := preload("res://scripts/fluid/apic_cut_cell_geometry.gd")
const SHADER_DIR := "res://shaders/apic/"
const SHARED_GRID_DIR := "res://shaders/fluid/"
const WG := 256
const TRANSFER_TILE_WIDTH := 4
const MAX_SCENE_OBSTACLES := 14
const SCENE_UBO_SIZE := 1168
const PRESSURE_MAX_ITERATIONS := 512
const PRESSURE_BLOCK_ITERATIONS := 8
const AMOUNT_MAX_SUBSTEPS := 128
const AMOUNT_STATE_HEADER_BYTES := 64
const AMOUNT_CELL_BYTES := 16
const INTERFACE_AMOUNT_CORRECTION_ITERATIONS := 8
const CONTACT_SLOP_GRID_FRACTION := 1.0e-4
enum P2GTransfer { GATHER, SCATTER_CAS }
const STAGES: Array[String] = [
	"grid_clear", "grid_count", "grid_scan", "grid_scan_blocks", "grid_add_back",
	"grid_scatter", "classify", "p2g", "p2g_clear", "p2g_scatter",
	"p2g_normalize", "gravity", "divergence", "pressure",
	"residual", "pressure_schedule", "project", "g2p",
	"extension_schedule", "extension_prepare", "extension_expand", "extension_publish",
	"solid_faces", "surface", "surface_amount",
]

var config: FluidConfig = FluidConfig.new()
var particle_count := 65536
var active_count := -1
var spacing := 0.12
var h := 0.24
var grid_dx := 0.24
var grid_cell_size_m := 0.0
var grid_dims := Vector3i.ZERO
var grid_origin := Vector3.ZERO
var gravity := Vector3(0.0, -9.81, 0.0)
var material_density_kg_m3 := 1000.0
var collision_inflation := 0.14
var substeps := 3
var last_substeps := 0
var last_step_dt_s := 0.0
var pressure_iterations := 256
var pressure_tolerance_s_inv := 0.001
var pressure_relaxation := 1.7
var free_surface_cut_cells := false
var solid_cut_cells := true
var surface_min_fraction := 0.000001
var conservative_amount_tracking := false
var conservative_surface_reconstruction := false
var amount_transport_max_substeps := 64
var amount_transport_order := 1
var amount_geometric_full_cell_flux := false
var amount_geometric_flux_cache := true
var amount_geometric_split_transport := false
var pressure_surface_from_volume_planes := false
var pressure_plane_connection_fraction := 0.0001
var flip_velocity_fraction := 0.0
var interface_distance_max_iterations := 64
var interface_distance_tolerance_m := 0.00001
var interface_distance_red_black := true
var p2g_transfer: P2GTransfer = P2GTransfer.GATHER
var last_pressure_iterations := -1
var initialized := false
var profiling := false
var projection_energy_diagnostics := false
var tex_width := 256
var _target_density := 0.0
var _seed_data := PackedFloat32Array()
var _seed_levelset := PackedFloat32Array()
var _seed_liquid_amount := PackedFloat32Array()
var _initial_amount_volume_m3 := 0.0
var scene_obstacles: Array[Dictionary] = []
var _rd: RenderingDevice
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _uniform_sets: Dictionary = {}
var _buffers: Dictionary = {}
var _position_tex := RID()
var _pre_force_velocity_tex := RID()
var _pre_force_velocity_tex_size := 1
var _scene_ubo := RID()
var _scene_cache_hash := 0
var _scene_cache := PackedByteArray()
var _solid_geometry_build_ms := 0.0
var _solid_geometry_partial_cells := 0
var _solid_geometry_partial_faces := 0
var _cut_vertex_bytes := 16
var _sim_time := 0.0
var _frame := 0
var _last_diagnostics := {"divergence_max_s_inv": -1.0,
	"pressure_residual_max_s_inv": -1.0, "pressure_iterations": -1,
	"pressure_tolerance_s_inv": 0.001, "density_metric": "excluded_apic"}
var _timing_store := GpuTimingStore.new()


func set_seed_positions(seed: PackedFloat32Array) -> void:
	_seed_data = seed


func set_seed_levelset(values_m: PackedFloat32Array) -> void:
	_seed_levelset = values_m.duplicate()


func set_seed_liquid_amount(values: PackedFloat32Array) -> void:
	_seed_liquid_amount = values.duplicate()


func set_scene_obstacles(value: Array[Dictionary]) -> void:
	scene_obstacles = value


func live_count() -> int:
	return particle_count if active_count < 0 else mini(active_count, particle_count)


func current_parity() -> int:
	return 0


func get_position_tex_rid() -> RID:
	return _position_tex


func init_render() -> void:
	free_render()
	grid_dx = spacing * 2.0 if grid_cell_size_m == 0.0 else grid_cell_size_m
	h = grid_dx
	if particle_count <= 0 or not is_finite(spacing) or spacing <= 0.0:
		push_error("APIC requires a positive particle count and spacing")
		return
	if scene_obstacles.size() > MAX_SCENE_OBSTACLES:
		push_error("APIC supports at most %d scene obstacles" % MAX_SCENE_OBSTACLES)
		return
	if not is_finite(grid_dx) or grid_dx <= 0.0:
		push_error("APIC requires a positive grid cell size")
		return
	if not is_finite(pressure_relaxation) or pressure_relaxation <= 0.0 or pressure_relaxation >= 2.0:
		push_error("APIC pressure relaxation must be between zero and two")
		return
	if not is_finite(surface_min_fraction) or surface_min_fraction <= 0.0 or surface_min_fraction > 1.0:
		push_error("APIC surface minimum fraction must be finite and in (0, 1]")
		return
	if not is_finite(flip_velocity_fraction) or flip_velocity_fraction < 0.0 or flip_velocity_fraction > 1.0:
		push_error("APIC FLIP velocity fraction must be finite and in [0, 1]")
		return
	grid_origin = config.domain_origin
	grid_dims = Vector3i(
		ceili(config.domain_size_m.x / grid_dx),
		ceili(config.domain_size_m.y / grid_dx),
		ceili(config.domain_size_m.z / grid_dx))
	config.cell_size_m = grid_dx
	config.grid_origin = grid_origin
	config.grid_dims = grid_dims
	config.default_particle_count = particle_count
	tex_width = config.texture_width
	var config_error := config.validate()
	if config_error != "":
		push_error("APIC config: " + config_error)
		return
	if _seed_data.size() != particle_count * 4:
		push_error("APIC seed size mismatch: %d != %d" % [_seed_data.size(), particle_count * 4])
		return
	if free_surface_cut_cells:
		if _seed_levelset.size() != grid_dims.x * grid_dims.y * grid_dims.z:
			push_error("APIC free surface requires one initial level-set value per cell")
			return
		for value in _seed_levelset:
			if not is_finite(value):
				push_error("APIC initial level set contains a non-finite value")
				return
	if conservative_amount_tracking:
		if amount_transport_order != 1 and amount_transport_order != 2:
			push_error("APIC amount transport order must be 1 or 2")
			return
		if not free_surface_cut_cells or not solid_cut_cells or (not _seed_liquid_amount.is_empty()
				and _seed_liquid_amount.size() != grid_dims.x * grid_dims.y * grid_dims.z):
			push_error("APIC amount transport requires a free surface and one initial liquid amount per cell")
			return
		if amount_transport_max_substeps < 1 or amount_transport_max_substeps > AMOUNT_MAX_SUBSTEPS:
			push_error("APIC amount transport substep budget must be in [1, %d]" % AMOUNT_MAX_SUBSTEPS)
			return
		for amount in _seed_liquid_amount:
			if not is_finite(amount) or amount < 0.0 or amount > 1.0:
				push_error("APIC initial liquid amount must be finite and in [0, 1]")
				return
	if conservative_surface_reconstruction and not conservative_amount_tracking:
		push_error("APIC conservative surface reconstruction requires amount transport")
		return
	if amount_geometric_full_cell_flux and (not conservative_surface_reconstruction or amount_transport_order != 1):
		push_error("APIC geometric full-cell flux requires conservative reconstruction and transport order 1")
		return
	if amount_geometric_split_transport and not amount_geometric_full_cell_flux:
		push_error("APIC split geometric transport requires geometric full-cell flux")
		return
	if pressure_surface_from_volume_planes and (not conservative_surface_reconstruction
			or not is_finite(pressure_plane_connection_fraction) or pressure_plane_connection_fraction < 0.0
			or pressure_plane_connection_fraction > 0.01):
		push_error("APIC volume-plane pressure requires conservative reconstruction and a finite connection fraction in [0, 0.01]")
		return
	if conservative_surface_reconstruction and (interface_distance_max_iterations < 1
			or interface_distance_max_iterations > 256 or not is_finite(interface_distance_tolerance_m)
			or interface_distance_tolerance_m <= 0.0):
		push_error("APIC interface distance requires an iteration budget in [1, 256] and a positive finite tolerance in metres")
		return
	_rd = GpuPreflight.device("ApicFluidSolver")
	if _rd == null:
		return
	var common := FileAccess.get_file_as_string(SHADER_DIR + "apic_common.comp")
	for stage: String in STAGES:
		var stage_dir := SHARED_GRID_DIR if stage in ["grid_clear", "grid_scan",
			"grid_scan_blocks", "grid_add_back"] else SHADER_DIR
		var source_name := stage if stage_dir == SHARED_GRID_DIR else "apic_" + stage
		var stage_source := FileAccess.get_file_as_string(stage_dir + source_name + ".comp")
		var group_size := TRANSFER_TILE_WIDTH * TRANSFER_TILE_WIDTH * TRANSFER_TILE_WIDTH if stage == "p2g" else WG
		var defines := "#version 450\n#define APIC_WORKGROUP_SIZE %d\n#define APIC_TRANSFER_TILE %d\n#define APIC_CONTACT_SLOP_DX %.9f\n" % [group_size, TRANSFER_TILE_WIDTH, CONTACT_SLOP_GRID_FRACTION]
		var spirv := ShaderCache.compile(_rd, "apic_" + stage,
			defines + common + "\n" + stage_source)
		if not spirv.compile_error_compute.is_empty():
			push_error("APIC stage '%s' compile error:\n%s" % [stage, spirv.compile_error_compute])
			free_render()
			return
		_shaders[stage] = _rd.shader_create_from_spirv(spirv)
		_pipelines[stage] = _rd.compute_pipeline_create(_shaders[stage])
	if not _create_resources():
		free_render()
		return
	if conservative_amount_tracking and not _initialize_liquid_amount_render():
		free_render()
		return
	_scene_cache_hash = hash(scene_obstacles)
	if free_surface_cut_cells:
		var pc := _pack_push_constant(0.0, -1)
		var cl := _rd.compute_list_begin()
		_dispatch(cl, "classify", pc, ceili(float(grid_dims.x * grid_dims.y * grid_dims.z) / WG), 1, 1)
		var faces := (grid_dims.x + 1) * (grid_dims.y + 1) * (grid_dims.z + 1)
		_dispatch(cl, "solid_faces", pc, ceili(float(faces * 3) / WG), 1, 1)
		_rd.compute_list_end()
	_sim_time = 0.0
	_frame = 0
	last_step_dt_s = 0.0
	last_pressure_iterations = -1
	_last_diagnostics = {"divergence_max_s_inv": -1.0,
		"pressure_residual_max_s_inv": -1.0, "pressure_iterations": -1,
		"pressure_tolerance_s_inv": pressure_tolerance_s_inv,
		"density_metric": "excluded_apic"}
	_timing_store.clear()
	initialized = true


func _create_resources() -> bool:
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var face_count := (grid_dims.x + 1) * (grid_dims.y + 1) * (grid_dims.z + 1)
	var blocks := ceili(float(cells) / WG)
	var particle_bytes := particle_count * 16
	var velocity_data := PackedFloat32Array()
	velocity_data.resize(particle_count * 4)
	for i in particle_count:
		velocity_data[i * 4 + 3] = float(i)
	var zero_cells := PackedByteArray()
	zero_cells.resize(cells * 4)
	var zero_blocks := PackedByteArray()
	zero_blocks.resize(blocks * 4)
	var zero_faces := PackedByteArray()
	zero_faces.resize(face_count * 4)
	var zero_motion_flags := PackedByteArray()
	zero_motion_flags.resize(particle_count * 4)
	var pressure_control_data := PackedByteArray()
	pressure_control_data.resize(48)
	pressure_control_data.encode_u32(24, 1)
	var zero_affine := PackedByteArray()
	zero_affine.resize(particle_bytes * 3)
	_buffers.positions_a = _rd.storage_buffer_create(particle_bytes, _seed_data.to_byte_array())
	_buffers.velocities_a = _rd.storage_buffer_create(particle_bytes, velocity_data.to_byte_array())
	_buffers.affine_rows = _rd.storage_buffer_create(particle_bytes * 3, zero_affine)
	_buffers.particle_motion_flags = _rd.storage_buffer_create(particle_count * 4, zero_motion_flags)
	_buffers.cell_count = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.cell_start = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.block_sums = _rd.storage_buffer_create(blocks * 4, zero_blocks)
	_buffers.particle_ids = _rd.storage_buffer_create(particle_count * 4)
	_buffers.face_u = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.face_v = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.face_w = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.face_mass_u = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.face_mass_v = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.face_mass_w = _rd.storage_buffer_create(face_count * 4, zero_faces)
	_buffers.cell_types = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.pressure = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.divergence = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.residual = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.pressure_control = _rd.storage_buffer_create(48, pressure_control_data,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var extension_control_data := PackedByteArray()
	extension_control_data.resize(48)
	_buffers.extension_control = _rd.storage_buffer_create(48, extension_control_data,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_buffers.face_extension_a = _rd.storage_buffer_create(face_count * 24)
	_buffers.face_extension_b = _rd.storage_buffer_create(face_count * 24)
	_buffers.solid_faces = _rd.storage_buffer_create(face_count * 12)
	_buffers.face_accum = _rd.storage_buffer_create(face_count * 24)
	_buffers.cell_phi = _rd.storage_buffer_create(cells * 4,
		_seed_levelset.to_byte_array() if free_surface_cut_cells else zero_cells)
	_buffers.cell_phi_next = _rd.storage_buffer_create(cells * 4, zero_cells)
	_buffers.cell_phi_corrected = _rd.storage_buffer_create(cells * 4, zero_cells)
	var amount_data := PackedByteArray()
	amount_data.resize(AMOUNT_STATE_HEADER_BYTES + (cells if conservative_amount_tracking else 1) * AMOUNT_CELL_BYTES)
	amount_data.encode_u32(28, 1)
	if conservative_amount_tracking and not _seed_liquid_amount.is_empty():
		for cell in cells:
			amount_data.encode_float(AMOUNT_STATE_HEADER_BYTES + cell * AMOUNT_CELL_BYTES, _seed_liquid_amount[cell])
	_buffers.surface_amount = _rd.storage_buffer_create(amount_data.size(), amount_data,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var cell_geometry := PackedFloat32Array([0.0, 0.0, 0.0, 1.0])
	var face_area := PackedFloat32Array([1.0])
	if free_surface_cut_cells and solid_cut_cells:
		cell_geometry.resize(cells * 4)
		for cell in cells:
			cell_geometry[cell * 4 + 3] = 1.0
		face_area.resize(face_count * 3)
		face_area.fill(1.0)
	_buffers.cell_geometry = _rd.storage_buffer_create(cell_geometry.size() * 4, cell_geometry.to_byte_array())
	_buffers.face_area = _rd.storage_buffer_create(face_area.size() * 4, face_area.to_byte_array())
	var vertex_ranges := PackedByteArray()
	vertex_ranges.resize(cells * 16 if free_surface_cut_cells and solid_cut_cells else 16)
	_buffers.cell_vertex_ranges = _rd.storage_buffer_create(vertex_ranges.size(), vertex_ranges)
	if not free_surface_cut_cells or not solid_cut_cells:
		_buffers.cut_vertices = _rd.storage_buffer_create(16, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array())
	_scene_ubo = _rd.uniform_buffer_create(SCENE_UBO_SIZE, _pack_scene_ubo())
	var fmt := RDTextureFormat.new()
	fmt.width = tex_width
	fmt.height = tex_width
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_position_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	var texture_seed := _seed_data.to_byte_array()
	texture_seed.resize(tex_width * tex_width * 16)
	_rd.texture_update(_position_tex, 0, texture_seed)
	_pre_force_velocity_tex_size = ceili(sqrt(float(face_count * (3 if projection_energy_diagnostics else 1)))) if flip_velocity_fraction > 0.0 or projection_energy_diagnostics else 1
	fmt.width = _pre_force_velocity_tex_size
	fmt.height = _pre_force_velocity_tex_size
	_pre_force_velocity_tex = _rd.texture_create(fmt, RDTextureView.new(), [])
	_rebuild_solid_geometry_render()
	_build_uniform_sets()
	return true


func _build_uniform_sets() -> void:
	for stage: String in STAGES:
		var uniforms: Array[RDUniform] = []
		for binding in 35:
			var uniform := RDUniform.new()
			uniform.binding = binding
			if binding == 18:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				uniform.add_id(_position_tex)
			elif binding == 34:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				uniform.add_id(_pre_force_velocity_tex)
			elif binding == 19:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
				uniform.add_id(_scene_ubo)
			else:
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				uniform.add_id(_buffers[_binding_key(binding)])
			uniforms.append(uniform)
		_uniform_sets[stage] = _rd.uniform_set_create(uniforms, _shaders[stage], 0)


func _initialize_liquid_amount_render() -> bool:
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var geometry := _rd.buffer_get_data(_buffers.cell_geometry).to_float32_array()
	var amounts := _seed_liquid_amount.duplicate()
	if amounts.is_empty():
		amounts.resize(cells)
		var strides := Vector3i(1, grid_dims.x, grid_dims.x * grid_dims.y)
		var planes: Array[Array] = CutGeometry.obstacle_planes(scene_obstacles)
		var domain := AABB(config.domain_origin, config.domain_size_m)
		for cell in cells:
			var capacity := geometry[cell * 4 + 3]
			if capacity <= 0.0:
				continue
			var coordinate := Vector3i(cell % grid_dims.x, (cell / grid_dims.x) % grid_dims.y,
				cell / (grid_dims.x * grid_dims.y))
			var span := Vector3.ZERO
			for axis in 3:
				var has_left := coordinate[axis] > 0 and geometry[(cell - strides[axis]) * 4 + 3] > 0.0
				var has_right := coordinate[axis] + 1 < grid_dims[axis] and geometry[(cell + strides[axis]) * 4 + 3] > 0.0
				if has_left and has_right:
					span[axis] = 0.5 * (_seed_levelset[cell + strides[axis]] - _seed_levelset[cell - strides[axis]])
				elif has_left:
					span[axis] = _seed_levelset[cell] - _seed_levelset[cell - strides[axis]]
				elif has_right:
					span[axis] = _seed_levelset[cell + strides[axis]] - _seed_levelset[cell]
			var fraction := CutGeometry.linear_liquid_fraction(_seed_levelset[cell], span)
			if capacity < 1.0:
				var center := grid_origin + (Vector3(coordinate) + Vector3.ONE * 0.5) * grid_dx
				if span.length_squared() > 1.0e-20:
					var gradient := span / grid_dx
					var normal := -gradient.normalized()
					var excluded: Array[Array] = planes.duplicate()
					excluded.append([Plane(normal, normal.dot(center) + _seed_levelset[cell] / gradient.length())])
					fraction = CutGeometry.open_cube(center, grid_dx, domain, excluded).open_fraction
				else:
					fraction *= capacity
			amounts[cell] = fraction
	var bytes := PackedByteArray()
	bytes.resize(cells * AMOUNT_CELL_BYTES)
	_initial_amount_volume_m3 = 0.0
	for cell in cells:
		var amount := amounts[cell]
		if not is_finite(amount) or amount < 0.0 or amount > geometry[cell * 4 + 3] + 1.0e-6:
			push_error("APIC initial liquid amount exceeds the open cell volume at cell %d" % cell)
			return false
		_initial_amount_volume_m3 += amount * pow(grid_dx, 3.0)
		bytes.encode_float(cell * AMOUNT_CELL_BYTES, amount)
	_rd.buffer_update(_buffers.surface_amount, AMOUNT_STATE_HEADER_BYTES, bytes.size(), bytes)
	return true


func _binding_key(binding: int) -> String:
	return ["positions_a", "velocities_a", "affine_rows", "cell_count", "cell_start",
		"block_sums", "particle_ids", "face_u", "face_v", "face_w", "face_mass_u",
		"face_mass_v", "face_mass_w", "cell_types", "pressure", "divergence",
		"residual", "particle_motion_flags", "", "", "face_extension_a", "face_extension_b",
		"solid_faces", "pressure_control", "face_accum", "cell_phi", "cell_phi_next", "cell_phi_corrected", "extension_control", "face_area", "cell_geometry", "cell_vertex_ranges", "cut_vertices", "surface_amount"][binding]


func _pack_scene_ubo() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SCENE_UBO_SIZE)
	var count := mini(scene_obstacles.size(), MAX_SCENE_OBSTACLES)
	bytes.encode_s32(1120, count)
	bytes.encode_float(1136, config.domain_origin.x)
	bytes.encode_float(1140, config.domain_origin.y)
	bytes.encode_float(1144, config.domain_origin.z)
	var domain_max := config.domain_origin + config.domain_size_m
	bytes.encode_float(1152, domain_max.x)
	bytes.encode_float(1156, domain_max.y)
	bytes.encode_float(1160, domain_max.z)
	for i in count:
		var obstacle: Dictionary = scene_obstacles[i]
		var inverse: Transform3D = (obstacle.transform as Transform3D).affine_inverse()
		var columns := [inverse.basis.x, inverse.basis.y, inverse.basis.z]
		var base := i * 64
		for column in 3:
			var vector: Vector3 = columns[column]
			bytes.encode_float(base + column * 16, vector.x)
			bytes.encode_float(base + column * 16 + 4, vector.y)
			bytes.encode_float(base + column * 16 + 8, vector.z)
		bytes.encode_float(base + 48, inverse.origin.x)
		bytes.encode_float(base + 52, inverse.origin.y)
		bytes.encode_float(base + 56, inverse.origin.z)
		bytes.encode_float(base + 60, 1.0)
		var half := (obstacle.size as Vector3) * 0.5
		var extents := 896 + i * 16
		bytes.encode_float(extents, half.x)
		bytes.encode_float(extents + 4, half.y)
		bytes.encode_float(extents + 8, half.z)
		bytes.encode_float(extents + 12, float(obstacle.get("retention", 0.985)))
	return bytes


func _rebuild_solid_geometry_render() -> void:
	if not free_surface_cut_cells or not solid_cut_cells:
		return
	var started_us := Time.get_ticks_usec()
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var face_dims := grid_dims + Vector3i.ONE
	var faces := face_dims.x * face_dims.y * face_dims.z
	var cell_data := PackedFloat32Array()
	cell_data.resize(cells * 4)
	for cell in cells:
		cell_data[cell * 4 + 3] = 1.0
	var face_data := PackedFloat32Array()
	face_data.resize(faces * 3)
	face_data.fill(1.0)
	var cut_cells: Dictionary = {}
	var cut_faces: Dictionary = {}
	var vertex_ranges := PackedInt32Array()
	vertex_ranges.resize(cells * 4)
	var vertices := PackedFloat32Array()
	var domain := AABB(config.domain_origin, config.domain_size_m)
	var extent := Vector3(grid_dims) * grid_dx
	var padded := Vector3i(
		1 if extent.x > config.domain_size_m.x + grid_dx * 1.0e-6 else 0,
		1 if extent.y > config.domain_size_m.y + grid_dx * 1.0e-6 else 0,
		1 if extent.z > config.domain_size_m.z + grid_dx * 1.0e-6 else 0)
	if padded != Vector3i.ZERO:
		for z in grid_dims.z:
			for y in grid_dims.y:
				for x in grid_dims.x:
					if (padded.x != 0 and x == grid_dims.x - 1) or (padded.y != 0 and y == grid_dims.y - 1) \
							or (padded.z != 0 and z == grid_dims.z - 1):
						cut_cells[(z * grid_dims.y + y) * grid_dims.x + x] = true
		for component in 3:
			var dims := grid_dims
			dims[component] += 1
			for z in dims.z:
				for y in dims.y:
					for x in dims.x:
						if (padded.x != 0 and x >= grid_dims.x - 1) or (padded.y != 0 and y >= grid_dims.y - 1) \
								or (padded.z != 0 and z >= grid_dims.z - 1):
							cut_faces[component * faces + (z * face_dims.y + y) * face_dims.x + x] = true
	for obstacle: Dictionary in scene_obstacles:
		var transform: Transform3D = obstacle.transform
		var half: Vector3 = obstacle.size * 0.5
		var inverse := transform.affine_inverse()
		var bound := transform.basis.x.abs() * half.x + transform.basis.y.abs() * half.y + transform.basis.z.abs() * half.z
		for component in range(-1, 3):
			var offset := Vector3.ONE * 0.5
			var radius := Vector3.ONE * (0.5 * grid_dx)
			var dims := grid_dims
			if component >= 0:
				offset[component] = 0.0
				radius[component] = 0.0
				dims[component] += 1
			var minimum := (transform.origin - bound - radius - grid_origin) / grid_dx - offset
			var maximum := (transform.origin + bound + radius - grid_origin) / grid_dx - offset
			var lo := Vector3i(maxi(floori(minimum.x), 0), maxi(floori(minimum.y), 0), maxi(floori(minimum.z), 0))
			var hi := Vector3i(mini(ceili(maximum.x), dims.x - 1), mini(ceili(maximum.y), dims.y - 1), mini(ceili(maximum.z), dims.z - 1))
			var reach := inverse.basis.x.abs() * radius.x + inverse.basis.y.abs() * radius.y + inverse.basis.z.abs() * radius.z
			var tolerance := Vector3.ONE * (grid_dx * 1.0e-6)
			for z in range(lo.z, hi.z + 1):
				for y in range(lo.y, hi.y + 1):
					for x in range(lo.x, hi.x + 1):
						var center := grid_origin + (Vector3(x, y, z) + offset) * grid_dx
						var local := (inverse * center).abs()
						if local.x - reach.x > half.x + tolerance.x or local.y - reach.y > half.y + tolerance.y \
								or local.z - reach.z > half.z + tolerance.z:
							continue
						var covered := local.x + reach.x <= half.x and local.y + reach.y <= half.y and local.z + reach.z <= half.z
						if component < 0:
							var index := (z * grid_dims.y + y) * grid_dims.x + x
							if covered:
								cell_data[index * 4 + 3] = 0.0
							else:
								cut_cells[index] = true
						else:
							var index := component * faces + (z * face_dims.y + y) * face_dims.x + x
							if covered:
								face_data[index] = 0.0
							else:
								cut_faces[index] = true
	var planes: Array[Array] = CutGeometry.obstacle_planes(scene_obstacles)
	_solid_geometry_partial_cells = 0
	_solid_geometry_partial_faces = 0
	for index: int in cut_cells:
		if cell_data[index * 4 + 3] == 0.0:
			continue
		var coordinate := Vector3i(index % grid_dims.x, (index / grid_dims.x) % grid_dims.y, index / (grid_dims.x * grid_dims.y))
		var center := grid_origin + (Vector3(coordinate) + Vector3.ONE * 0.5) * grid_dx
		var measure := CutGeometry.open_cube(center, grid_dx, domain, planes,
			conservative_surface_reconstruction)
		cell_data[index * 4] = measure.anchor_m.x - center.x
		cell_data[index * 4 + 1] = measure.anchor_m.y - center.y
		cell_data[index * 4 + 2] = measure.anchor_m.z - center.z
		cell_data[index * 4 + 3] = measure.open_fraction
		_solid_geometry_partial_cells += 1 if measure.open_fraction > 0.0 and measure.open_fraction < 1.0 else 0
		if measure.open_fraction > 0.0 and measure.open_fraction < 1.0:
			vertex_ranges[index * 4] = vertices.size() / 4
			vertex_ranges[index * 4 + 1] = measure.vertices_m.size()
			for point: Vector3 in measure.vertices_m:
				var offset := point - center
				vertices.append_array([offset.x, offset.y, offset.z, 0.0])
			if conservative_surface_reconstruction:
				vertex_ranges[index * 4 + 2] = vertices.size() / 4
				vertex_ranges[index * 4 + 3] = measure.tetrahedra_m.size() / 4
				for tetrahedron in range(0, measure.tetrahedra_m.size(), 4):
					var a: Vector3 = measure.tetrahedra_m[tetrahedron]
					var b: Vector3 = measure.tetrahedra_m[tetrahedron + 1]
					var c: Vector3 = measure.tetrahedra_m[tetrahedron + 2]
					var d: Vector3 = measure.tetrahedra_m[tetrahedron + 3]
					var weight := absf((b - a).dot((c - a).cross(d - a))) / (6.0 * pow(grid_dx, 3.0))
					for corner in 4:
						var offset: Vector3 = measure.tetrahedra_m[tetrahedron + corner] - center
						vertices.append_array([offset.x, offset.y, offset.z, weight if corner == 0 else 0.0])
	for index: int in cut_faces:
		if face_data[index] == 0.0:
			continue
		var component := index / faces
		var face := index % faces
		var coordinate := Vector3i(face % face_dims.x, (face / face_dims.x) % face_dims.y, face / (face_dims.x * face_dims.y))
		var offset := Vector3.ONE * 0.5
		offset[component] = 0.0
		var center := grid_origin + (Vector3(coordinate) + offset) * grid_dx
		face_data[index] = CutGeometry.open_face(center, grid_dx, component, domain, planes)
		_solid_geometry_partial_faces += 1 if face_data[index] > 0.0 and face_data[index] < 1.0 else 0
	var cell_bytes := cell_data.to_byte_array()
	var face_bytes := face_data.to_byte_array()
	_rd.buffer_update(_buffers.cell_geometry, 0, cell_bytes.size(), cell_bytes)
	_rd.buffer_update(_buffers.face_area, 0, face_bytes.size(), face_bytes)
	var range_bytes := vertex_ranges.to_byte_array()
	_rd.buffer_update(_buffers.cell_vertex_ranges, 0, range_bytes.size(), range_bytes)
	if vertices.is_empty():
		vertices.resize(4)
	var vertex_bytes := vertices.to_byte_array()
	_cut_vertex_bytes = vertex_bytes.size()
	var replace_vertices := _buffers.has("cut_vertices")
	if replace_vertices:
		for uniform_set: RID in _uniform_sets.values():
			if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
				_rd.free_rid(uniform_set)
		_uniform_sets.clear()
		_rd.free_rid(_buffers.cut_vertices)
	_buffers.cut_vertices = _rd.storage_buffer_create(vertex_bytes.size(), vertex_bytes)
	if replace_vertices:
		_build_uniform_sets()
	_solid_geometry_build_ms = float(Time.get_ticks_usec() - started_us) / 1000.0


func step_render(dt: float) -> void:
	if not initialized or not is_finite(dt) or dt <= 0.0:
		return
	if scene_obstacles.size() > MAX_SCENE_OBSTACLES:
		push_error("APIC supports at most %d scene obstacles" % MAX_SCENE_OBSTACLES)
		return
	_read_timings()
	_sim_time += dt
	_frame += 1
	last_step_dt_s = dt
	var scene_hash := hash(scene_obstacles)
	if scene_hash != _scene_cache_hash:
		_scene_cache = _pack_scene_ubo()
		_rd.buffer_update(_scene_ubo, 0, _scene_cache.size(), _scene_cache)
		_scene_cache_hash = scene_hash
		_rebuild_solid_geometry_render()
	var step_count := maxi(substeps, 1)
	last_substeps = step_count
	var dt_sub := dt / float(step_count)
	var cell_count := grid_dims.x * grid_dims.y * grid_dims.z
	var face_count := (grid_dims.x + 1) * (grid_dims.y + 1) * (grid_dims.z + 1)
	var particle_groups := ceili(float(live_count()) / WG)
	var cell_groups := ceili(float(cell_count) / WG)
	var face_groups := ceili(float(face_count * 3) / WG)
	if profiling:
		_rd.capture_timestamp("apic/start")
	var pc := _pack_push_constant(dt_sub, -1)
	var cl := _rd.compute_list_begin()
	for substep in step_count:
		pc = _pack_push_constant(dt_sub, -1)
		_dispatch(cl, "grid_clear", pc, cell_groups, 1, 1)
		_dispatch(cl, "grid_count", pc, particle_groups, 1, 1)
		_dispatch(cl, "grid_scan", pc, cell_groups, 1, 1)
		_dispatch(cl, "grid_scan_blocks", pc, 1, 1, 1)
		_dispatch(cl, "grid_add_back", pc, cell_groups, 1, 1)
		_dispatch(cl, "grid_scatter", pc, particle_groups, 1, 1)
		_dispatch(cl, "classify", pc, cell_groups, 1, 1)
		_dispatch(cl, "solid_faces", pc, face_groups, 1, 1)
		_dispatch_p2g_render(cl, pc)
		if free_surface_cut_cells:
			cl = _mark(cl, "apic/transfer")
			_dispatch_velocity_extension_render(cl, dt_sub, face_groups, true)
			cl = _mark(cl, "apic/velocity_support")
		if pressure_surface_from_volume_planes:
			_dispatch(cl, "surface_amount", _pack_push_constant(dt_sub, 31), cell_groups, 1, 1)
			cl = _mark(cl, "apic/pressure_interface")
		if flip_velocity_fraction > 0.0:
			_dispatch_velocity_extension_render(cl, dt_sub, face_groups, false)
			_dispatch(cl, "extension_publish", _pack_push_constant(dt_sub, 2), ceili(float(face_count) / WG), 1, 1)
			cl = _mark(cl, "apic/velocity_archive")
		_dispatch(cl, "gravity", pc, face_groups, 1, 1)
		if projection_energy_diagnostics:
			_dispatch(cl, "extension_publish", _pack_push_constant(dt_sub, 3), ceili(float(face_count) / WG), 1, 1)
		_dispatch(cl, "divergence", pc, cell_groups, 1, 1)
		cl = _mark(cl, "apic/transfer")
		var iterations := mini(maxi(pressure_iterations, 0), PRESSURE_MAX_ITERATIONS)
		pc = _pack_push_constant(dt_sub, -1, 0, 0)
		_dispatch(cl, "pressure_schedule", pc, 1, 1, 1)
		for block in ceili(float(iterations) / PRESSURE_BLOCK_ITERATIONS):
			var block_iterations := mini(PRESSURE_BLOCK_ITERATIONS,
				iterations - block * PRESSURE_BLOCK_ITERATIONS)
			pc = _pack_push_constant(dt_sub, -1, 1, block_iterations)
			_dispatch(cl, "pressure_schedule", pc, 1, 1, 1)
			for iteration in block_iterations:
				pc = _pack_push_constant(dt_sub, 0)
				_dispatch_indirect(cl, "pressure", pc, _buffers.pressure_control)
				pc = _pack_push_constant(dt_sub, 1)
				_dispatch_indirect(cl, "pressure", pc, _buffers.pressure_control)
			pc = _pack_push_constant(dt_sub, -1)
			_dispatch_indirect(cl, "residual", pc, _buffers.pressure_control)
			pc = _pack_push_constant(dt_sub, -1, 2, block_iterations)
			_dispatch(cl, "pressure_schedule", pc, 1, 1, 1)
		pc = _pack_push_constant(dt_sub, -1)
		_dispatch(cl, "project", pc, face_groups, 1, 1)
		if projection_energy_diagnostics:
			_dispatch(cl, "extension_publish", _pack_push_constant(dt_sub, 4), ceili(float(face_count) / WG), 1, 1)
		pc = _pack_push_constant(dt_sub, -1, 3)
		_dispatch(cl, "pressure_schedule", pc, 1, 1, 1)
		_dispatch(cl, "divergence", pc, cell_groups, 1, 1)
		_dispatch(cl, "pressure_schedule", _pack_push_constant(dt_sub, -1, 4, iterations), 1, 1, 1)
		cl = _mark(cl, "apic/pressure")
		_dispatch_velocity_extension_render(cl, dt_sub, face_groups, false)
		pc = _pack_push_constant(dt_sub, -1)
		cl = _mark(cl, "apic/extrapolation")
		_dispatch(cl, "g2p", pc, particle_groups, 1, 1)
		cl = _mark(cl, "apic/g2p")
		if free_surface_cut_cells:
			cl = _dispatch_surface_transport_render(cl, dt_sub, cell_groups)
			cl = _mark(cl, "apic/surface_transport")
	_rd.compute_list_end()
	if profiling:
		_rd.capture_timestamp("apic/end")


func _dispatch_velocity_extension_render(cl: int, dt: float, groups: int,
		before_projection: bool) -> void:
	if before_projection:
		_dispatch(cl, "extension_schedule", _pack_push_constant(dt, -1), 1, 1, 1)
	_dispatch(cl, "extension_prepare", _pack_push_constant(dt, -1, 4 if before_projection else -1), groups, 1, 1)
	for extension in 6:
		if before_projection:
			if extension > 0:
				_dispatch(cl, "extension_schedule", _pack_push_constant(dt, -1, 5), 1, 1, 1)
			_dispatch_indirect(cl, "extension_expand", _pack_push_constant(dt, extension % 2, 5), _buffers.extension_control)
		else:
			_dispatch(cl, "extension_expand", _pack_push_constant(dt, extension % 2), groups, 1, 1)
	if before_projection:
		_dispatch(cl, "extension_schedule", _pack_push_constant(dt, -1, 6), 1, 1, 1)
		_dispatch_indirect(cl, "extension_publish", _pack_push_constant(dt, -1, 5), _buffers.extension_control)
	else:
		_dispatch(cl, "extension_publish", _pack_push_constant(dt, -1), groups, 1, 1)


func _dispatch_surface_transport_render(cl: int, dt: float, groups: int) -> int:
	if conservative_amount_tracking:
		_dispatch_surface_amount_render(cl, dt, groups)
		cl = _mark(cl, "apic/amount_transport")
	_dispatch(cl, "surface", _pack_push_constant(dt, -1), groups, 1, 1)
	_dispatch(cl, "surface", _pack_push_constant(dt, -3), groups, 1, 1)
	_dispatch(cl, "surface", _pack_push_constant(dt, -2), groups, 1, 1)
	if conservative_surface_reconstruction:
		_dispatch_surface_amount_saturation_render(cl, dt, groups)
		cl = _mark(cl, "apic/amount_saturation")
		_dispatch_surface_amount_reconstruction_render(cl, dt, groups)
		cl = _mark(cl, "apic/amount_reconstruction")
	return cl


func _dispatch_surface_amount_reconstruction_render(cl: int, dt: float, groups: int) -> void:
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 16, -1, 1 if interface_distance_red_black else 0), 1, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 6), groups, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 13), groups, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 15), groups, 1, 1)
	for iteration in interface_distance_max_iterations:
		_dispatch(cl, "surface_amount", _pack_push_constant(dt, 17), 1, 1, 1)
		_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 18, -1, 1 if interface_distance_red_black else 0), _buffers.pressure_control)
		_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 19, -1, 1 if interface_distance_red_black else 0), _buffers.pressure_control)
		_dispatch(cl, "surface_amount", _pack_push_constant(dt, 20), 1, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 21), groups, 1, 1)
	for iteration in INTERFACE_AMOUNT_CORRECTION_ITERATIONS:
		_dispatch(cl, "surface_amount", _pack_push_constant(dt, 26), groups, 1, 1)
		_dispatch(cl, "surface_amount", _pack_push_constant(dt, 7), groups, 1, 1)


func _dispatch_surface_amount_saturation_render(cl: int, dt: float, groups: int) -> void:
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 10), groups, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 11), groups, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 12), groups, 1, 1)


func _dispatch_surface_amount_render(cl: int, dt: float, groups: int) -> void:
	var transport_mode := (1 if conservative_surface_reconstruction else 0) | (2 if amount_transport_order == 2 else 0) | (4 if amount_geometric_full_cell_flux else 0)
	if amount_geometric_full_cell_flux and amount_geometric_flux_cache:
		transport_mode |= 64
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 0), 1, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 1, transport_mode), groups, 1, 1)
	_dispatch(cl, "surface_amount", _pack_push_constant(dt, 2), 1, 1, 1)
	for substep in amount_transport_max_substeps:
		if amount_geometric_split_transport:
			_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 33, transport_mode), _buffers.surface_amount)
			for sweep in 3:
				var axis := (substep + sweep + _frame) % 3
				var sweep_mode := transport_mode | ((axis + 1) << 3)
				if amount_geometric_flux_cache:
					_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 34, sweep_mode), _buffers.surface_amount)
				_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 32, sweep_mode), _buffers.surface_amount)
				_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 3, sweep_mode), _buffers.surface_amount)
				_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 4), _buffers.surface_amount)
			_dispatch(cl, "surface_amount", _pack_push_constant(dt, 5), 1, 1, 1)
			continue
		if amount_geometric_full_cell_flux:
			if amount_geometric_flux_cache:
				_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 34, transport_mode), _buffers.surface_amount)
			_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 32, transport_mode), _buffers.surface_amount)
		_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 3, transport_mode), _buffers.surface_amount)
		if amount_transport_order == 2:
			_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 24, transport_mode), _buffers.surface_amount)
			_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 25, transport_mode), _buffers.surface_amount)
		_dispatch_indirect(cl, "surface_amount", _pack_push_constant(dt, 4), _buffers.surface_amount)
		_dispatch(cl, "surface_amount", _pack_push_constant(dt, 5), 1, 1, 1)


func _pack_push_constant(dt: float, color: int, schedule_mode: int = -1,
		block_iterations: int = PRESSURE_BLOCK_ITERATIONS) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(128)
	bytes.encode_float(0, grid_origin.x)
	bytes.encode_float(4, grid_origin.y)
	bytes.encode_float(8, grid_origin.z)
	bytes.encode_float(12, grid_dx)
	bytes.encode_s32(16, grid_dims.x)
	bytes.encode_s32(20, grid_dims.y)
	bytes.encode_s32(24, grid_dims.z)
	bytes.encode_float(28, spacing)
	bytes.encode_float(32, dt)
	bytes.encode_float(36, gravity.y)
	bytes.encode_float(40, material_density_kg_m3)
	bytes.encode_float(44, collision_inflation)
	bytes.encode_s32(48, grid_dims.x + 1)
	bytes.encode_s32(52, grid_dims.y + 1)
	bytes.encode_s32(56, grid_dims.z + 1)
	bytes.encode_s32(60, live_count())
	bytes.encode_s32(64, grid_dims.x * grid_dims.y * grid_dims.z)
	bytes.encode_s32(68, ceili(float(grid_dims.x * grid_dims.y * grid_dims.z) / WG))
	bytes.encode_s32(72, tex_width)
	bytes.encode_s32(76, color)
	bytes.encode_float(80, pressure_tolerance_s_inv)
	bytes.encode_float(84, float(block_iterations))
	bytes.encode_float(88, interface_distance_tolerance_m if color >= 15 and color <= 21 else float(schedule_mode))
	bytes.encode_float(92, pressure_relaxation)
	bytes.encode_float(96, 1.0 if free_surface_cut_cells else 0.0)
	bytes.encode_float(100, 1.0 if free_surface_cut_cells and solid_cut_cells else 0.0)
	bytes.encode_float(104, float(amount_transport_max_substeps) if conservative_amount_tracking else 0.0)
	bytes.encode_float(108, surface_min_fraction)
	bytes.encode_float(112, 1.0 if pressure_surface_from_volume_planes else 0.0)
	bytes.encode_float(116, pressure_plane_connection_fraction)
	bytes.encode_float(120, flip_velocity_fraction)
	bytes.encode_float(124, 1.0 if amount_geometric_split_transport else 0.0)
	return bytes


func _dispatch_p2g_render(cl: int, pc: PackedByteArray) -> void:
	var face_count := (grid_dims.x + 1) * (grid_dims.y + 1) * (grid_dims.z + 1)
	var face_groups := ceili(float(face_count * 3) / WG)
	if p2g_transfer == P2GTransfer.GATHER:
		_dispatch(cl, "p2g", pc, ceili(float(grid_dims.x + 1) / TRANSFER_TILE_WIDTH),
			ceili(float(grid_dims.y + 1) / TRANSFER_TILE_WIDTH),
			ceili(float(grid_dims.z + 1) / TRANSFER_TILE_WIDTH))
	else:
		_dispatch(cl, "p2g_clear", pc, face_groups, 1, 1)
		_dispatch(cl, "p2g_scatter", pc, ceili(float(live_count()) / WG), 1, 1)
		_dispatch(cl, "p2g_normalize", pc, face_groups, 1, 1)


func _dispatch(cl: int, stage: String, pc: PackedByteArray, x: int, y: int, z: int) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, x, y, z)
	_rd.compute_list_add_barrier(cl)


func _dispatch_indirect(cl: int, stage: String, pc: PackedByteArray, control_buffer: RID) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(cl, _uniform_sets[stage], 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch_indirect(cl, control_buffer, 0)
	_rd.compute_list_add_barrier(cl)


func _mark(cl: int, label: String) -> int:
	if not profiling:
		return cl
	_rd.compute_list_end()
	_rd.capture_timestamp(label)
	return _rd.compute_list_begin()


func _read_timings() -> void:
	var timings: Dictionary = GpuTimings.read(_rd, "apic/")
	if not timings.is_empty():
		_timing_store.publish(timings)


func get_timings() -> Dictionary:
	return _timing_store.snapshot()


func get_diagnostics() -> Dictionary:
	if not initialized:
		return _last_diagnostics.duplicate()
	var control: PackedByteArray = _rd.buffer_get_data(_buffers.pressure_control, 0, 48)
	var iterations := int(control.decode_u32(16))
	var residual_max := control.decode_float(20)
	var finite := control.decode_u32(24) != 0
	var divergence_max := control.decode_float(28)
	last_pressure_iterations = iterations
	_last_diagnostics = {"divergence_max_s_inv": divergence_max,
		"pressure_residual_max_s_inv": residual_max,
		"pressure_iterations": iterations,
		"pressure_tolerance_s_inv": pressure_tolerance_s_inv,
		"pressure_relaxation": pressure_relaxation,
		"finite": finite,
		"density_metric": "excluded_apic"}
	_last_diagnostics["pressure_iteration_budget_requested"] = pressure_iterations
	_last_diagnostics["pressure_iteration_budget_applied"] = mini(maxi(pressure_iterations, 0), PRESSURE_MAX_ITERATIONS)
	_last_diagnostics["pressure_stopping_metric"] = "predicted_projected_velocity_divergence"
	_last_diagnostics["pressure_stopping_tolerance_s_inv"] = pressure_tolerance_s_inv
	_last_diagnostics["projection_history"] = {"maximum_divergence_s_inv": control.decode_float(32),
		"failed_substeps": control.decode_u32(36), "checked_substeps": control.decode_u32(40),
		"budget_exhausted_failures": control.decode_u32(44)}
	_last_diagnostics["collision_numerical_clearance_m"] = grid_dx * CONTACT_SLOP_GRID_FRACTION
	_last_diagnostics["interface_distance_iteration_method"] = "red_black_gauss_seidel" if interface_distance_red_black else "jacobi"
	_last_diagnostics["free_surface_method"] = "advected_level_set_with_local_amount_interface_correction" if conservative_surface_reconstruction else ("advected_level_set" if free_surface_cut_cells else "air_cell_center")
	_last_diagnostics["free_surface_pressure_method"] = "connected_volume_planes_with_level_set_fallback" if pressure_surface_from_volume_planes else "interpolated_level_set_fraction"
	_last_diagnostics["pressure_plane_connection_tolerance_m"] = grid_dx * pressure_plane_connection_fraction if pressure_surface_from_volume_planes else 0.0
	_last_diagnostics["pressure_plane_fallback_evaluations"] = "unavailable" if pressure_surface_from_volume_planes else "disabled"
	_last_diagnostics["pressure_volume_plane_normal_method"] = "visible_sobel_liquid_fraction_with_level_set_fallback" if pressure_surface_from_volume_planes else "disabled"
	_last_diagnostics["flip_velocity_fraction"] = flip_velocity_fraction
	_last_diagnostics["supported_particle_advection"] = "projected_grid_velocity"
	_last_diagnostics["surface_advection"] = "bounded_maccormack_rk2" if free_surface_cut_cells else "unavailable"
	_last_diagnostics["surface_characteristic_origin"] = "geometric_cell_center" if free_surface_cut_cells else "unavailable"
	_last_diagnostics["masked_surface_sampling"] = "limited_visible_centroid_bias_correction_when_gradient_available" if free_surface_cut_cells and solid_cut_cells else "renormalized_visible_donors"
	_last_diagnostics["solid_geometry"] = "clipped_obb_union" if free_surface_cut_cells and solid_cut_cells else "cell_center_mask"
	_last_diagnostics["solid_geometry_build_ms"] = _solid_geometry_build_ms if free_surface_cut_cells and solid_cut_cells else "unavailable"
	_last_diagnostics["solid_geometry_partial_cells"] = _solid_geometry_partial_cells if free_surface_cut_cells and solid_cut_cells else "unavailable"
	_last_diagnostics["solid_geometry_partial_faces"] = _solid_geometry_partial_faces if free_surface_cut_cells and solid_cut_cells else "unavailable"
	_last_diagnostics["dry_cut_face_pressure"] = "zero_water_flux_with_extrapolated_velocity" if free_surface_cut_cells and solid_cut_cells else "unavailable"
	_last_diagnostics["velocity_support"] = "particle_mass_before_projection" if free_surface_cut_cells else "projected_fluid_faces"
	_last_diagnostics["particle_motion"] = get_particle_motion_diagnostics_render()
	var extension_control := _rd.buffer_get_data(_buffers.extension_control, 0, 48)
	_last_diagnostics["pre_projection_missing_mass_faces"] = extension_control.decode_u32(12) if free_surface_cut_cells else "unavailable"
	_last_diagnostics["pre_projection_deep_extension_dispatched"] = extension_control.decode_u32(0) > 0 if free_surface_cut_cells else "unavailable"
	_last_diagnostics["pre_projection_directly_repaired_faces"] = extension_control.decode_u32(20) if free_surface_cut_cells else "unavailable"
	_last_diagnostics["pre_projection_deep_missing_faces"] = extension_control.decode_u32(16) if free_surface_cut_cells else "unavailable"
	_last_diagnostics["pre_projection_extension_passes"] = extension_control.decode_u32(44) if free_surface_cut_cells else "unavailable"
	return _last_diagnostics.duplicate()


func get_particle_motion_diagnostics_render() -> Dictionary:
	if not initialized:
		return {}
	var flags := _rd.buffer_get_data(_buffers.particle_motion_flags, 0, live_count() * 4).to_float32_array()
	var velocities := _rd.buffer_get_data(_buffers.velocities_a, 0, live_count() * 16).to_float32_array()
	var ballistic_count := 0
	var unknown_phase_count := 0
	var finite := true
	var grid_momentum := Vector3.ZERO
	var ballistic_momentum := Vector3.ZERO
	var particle_volume_m3 := pow(spacing, 3.0)
	var particle_mass_kg := material_density_kg_m3 * particle_volume_m3
	for i in live_count():
		var velocity := Vector3(velocities[i * 4], velocities[i * 4 + 1], velocities[i * 4 + 2])
		finite = finite and is_finite(flags[i]) and velocity.is_finite()
		if flags[i] < 0.0:
			unknown_phase_count += 1
		if flags[i] > 0.5:
			ballistic_count += 1
			ballistic_momentum += particle_mass_kg * velocity
		else:
			grid_momentum += particle_mass_kg * velocity
	return {"physical_time_s": _sim_time, "state_revision": _frame,
		"classification_time_s": _sim_time - last_step_dt_s / float(maxi(last_substeps, 1)),
		"method": "outside_interface_without_pressure_support" if free_surface_cut_cells else "grid_only",
		"ballistic_integrator": "constant_gravity_exact_between_contacts" if free_surface_cut_cells else "unavailable",
		"finite": finite, "grid_transferred_particle_count": live_count() - ballistic_count,
		"ballistic_particle_count": ballistic_count,
		"unknown_phase_particle_count": unknown_phase_count,
		"grid_transferred_particle_volume_m3": (live_count() - ballistic_count) * particle_volume_m3,
		"ballistic_particle_volume_m3": ballistic_count * particle_volume_m3,
		"grid_transferred_particle_momentum_kg_m_s": grid_momentum,
		"ballistic_particle_momentum_kg_m_s": ballistic_momentum,
		"particle_pressure_consistency_verified": false}


func read_volume_state_render() -> Dictionary:
	if not initialized or not free_surface_cut_cells:
		return {}
	var types := _rd.buffer_get_data(_buffers.cell_types).to_int32_array()
	var solid_mask := PackedByteArray()
	solid_mask.resize(types.size())
	for cell in types.size():
		solid_mask[cell] = 1 if types[cell] == 2 else 0
	return {"level_set_m": _rd.buffer_get_data(_buffers.cell_phi).to_float32_array(),
		"solid_cell_mask": solid_mask,
		"cell_geometry": _rd.buffer_get_data(_buffers.cell_geometry).to_float32_array() if free_surface_cut_cells and solid_cut_cells else PackedFloat32Array(),
		"grid_dims": grid_dims, "grid_origin_m": grid_origin, "cell_size_m": grid_dx,
		"physical_time_s": _sim_time, "state_revision": _frame}


func read_liquid_amount_state_render() -> Dictionary:
	if not initialized or not conservative_amount_tracking:
		return {}
	var data := _rd.buffer_get_data(_buffers.surface_amount)
	var distance_unavailable := _rd.buffer_get_data(_buffers.pressure_control, 12, 4).decode_u32(0)
	var amounts := PackedFloat32Array()
	amounts.resize(grid_dims.x * grid_dims.y * grid_dims.z)
	for cell in amounts.size():
		amounts[cell] = data.decode_float(AMOUNT_STATE_HEADER_BYTES + cell * AMOUNT_CELL_BYTES)
	return {"liquid_amount_per_full_cell": amounts,
		"transport_time_s": data.decode_float(32), "completed_steps": data.decode_u32(36),
		"failed_steps": data.decode_u32(40), "time_compensation_s": data.decode_float(44),
		"max_outflow_rate_s_inv": data.decode_float(16),
		"requested_substeps": data.decode_u32(20), "completed_substeps": data.decode_u32(24),
		"normal_fallback_cells": data.decode_u32(12),
		"transport_valid": data.decode_u32(28) != 0,
		"surface_controls_pressure": conservative_surface_reconstruction,
		"amount_saturation": "local_shared_face_surplus_to_full_cell_deficit" if conservative_surface_reconstruction else "disabled",
		"interface_extension_width_m": 2.0 * grid_dx if conservative_surface_reconstruction else 0.0,
		"interface_plane_normalization": "unit_normal_and_distance" if conservative_surface_reconstruction else "disabled",
		"interface_distance_method": "same_phase_visible_neighbor_eikonal" if conservative_surface_reconstruction else "disabled",
		"interface_amount_correction_iterations": INTERFACE_AMOUNT_CORRECTION_ITERATIONS if conservative_surface_reconstruction else 0,
		"interface_amount_correction_relaxation": 0.5 if conservative_surface_reconstruction else 0.0,
		"interface_amount_identity_culling": conservative_surface_reconstruction,
		"interface_amount_geometry_endpoint_tolerance": 1.0e-7,
		"interface_amount_geometry_endpoint_snapping_changes_amount": false,
		"interface_endpoint_consistency_rule": "full_or_empty_geometry_within_pressure_tolerance_times_substep_dt",
		"interface_cube_fraction_method": "normalized_rectangle_cdf_with_tetrahedra_for_solid_cuts",
		"interface_distance_seed_cells": data.decode_u32(48),
		"interface_distance_iterations": data.decode_u32(52),
		"interface_distance_max_iterations": interface_distance_max_iterations,
		"interface_distance_max_change_m": data.decode_float(56),
		"interface_distance_tolerance_m": interface_distance_tolerance_m,
		"interface_distance_converged": data.decode_u32(60) != 0,
		"interface_distance_unavailable_cells": distance_unavailable if conservative_surface_reconstruction else "unavailable",
		"method": "shared_face_geometric_full_cell_flux_with_cfl_subcycling" if amount_geometric_full_cell_flux else ("shared_face_fct_superbee_with_cfl_subcycling" if amount_transport_order == 2 else "shared_face_upwind_with_cfl_subcycling"),
		"geometric_flux_solid_cuts": "upwind_fallback" if amount_geometric_full_cell_flux else "disabled",
		"geometric_flux_positivity": "shared_face_donor_outflow_budget" if amount_geometric_full_cell_flux else "disabled",
		"geometric_flux_plane_cache": amount_geometric_full_cell_flux and amount_geometric_flux_cache,
		"geometric_split_transport": "alternating_xyz_with_frozen_majority_indicator" if amount_geometric_split_transport else "disabled",
		"geometric_split_compression_solid_cuts": "disabled" if amount_geometric_split_transport else "unavailable",
		"amount_transport_order": amount_transport_order,
		"dry_swept_prism_exclusion": conservative_surface_reconstruction,
		"physical_time_s": _sim_time, "state_revision": _frame}


func get_liquid_amount_diagnostics_render() -> Dictionary:
	var state := read_liquid_amount_state_render()
	if state.is_empty():
		return {}
	var amounts: PackedFloat32Array = state.liquid_amount_per_full_cell
	state.erase("liquid_amount_per_full_cell")
	var geometry := _rd.buffer_get_data(_buffers.cell_geometry).to_float32_array()
	var volume := 0.0
	var min_concentration := INF
	var max_concentration := -INF
	var solid_volume := 0.0
	var overfilled_volume := 0.0
	var finite := true
	for cell in amounts.size():
		var amount := amounts[cell]
		finite = finite and is_finite(amount)
		volume += amount * pow(grid_dx, 3.0)
		var capacity := geometry[cell * 4 + 3]
		if capacity <= 0.0:
			solid_volume += amount * pow(grid_dx, 3.0)
		else:
			overfilled_volume += maxf(amount - capacity, 0.0) * pow(grid_dx, 3.0)
			min_concentration = minf(min_concentration, amount / capacity)
			max_concentration = maxf(max_concentration, amount / capacity)
	state.merge({"initial_amount_volume_m3": _initial_amount_volume_m3,
		"amount_volume_m3": volume, "relative_amount_drift": absf(volume - _initial_amount_volume_m3) / maxf(_initial_amount_volume_m3, 1.0e-20),
		"concentration_min": min_concentration, "concentration_max": max_concentration,
		"solid_amount_volume_m3": solid_volume, "finite": finite,
		"overfilled_amount_volume_m3": overfilled_volume,
		"geometric_volume_conservation_verified": false})
	return state


func get_interface_geometry_diagnostics_render() -> Dictionary:
	if not initialized or not conservative_surface_reconstruction:
		return {}
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var cl := _rd.compute_list_begin()
	_dispatch(cl, "surface_amount", _pack_push_constant(0.0, 8), ceili(float(cells) / WG), 1, 1)
	_rd.compute_list_end()
	var data := _rd.buffer_get_data(_buffers.surface_amount)
	var geometry := _rd.buffer_get_data(_buffers.cell_geometry).to_float32_array()
	var volume := 0.0
	var amount_volume := 0.0
	var absolute_error_volume := 0.0
	var maximum_fraction_error := 0.0
	var pure_deficit_volume := 0.0
	var mixed_deficit_volume := 0.0
	var cut_deficit_volume := 0.0
	var worst := {}
	var finite := true
	for cell in cells:
		var offset := AMOUNT_STATE_HEADER_BYTES + cell * AMOUNT_CELL_BYTES
		var amount := data.decode_float(offset)
		var fraction := data.decode_float(offset + 4)
		var target := clampf(amount, 0.0, geometry[cell * 4 + 3])
		finite = finite and is_finite(amount) and is_finite(fraction)
		volume += fraction * pow(grid_dx, 3.0)
		amount_volume += amount * pow(grid_dx, 3.0)
		absolute_error_volume += absf(fraction - target) * pow(grid_dx, 3.0)
		var deficit := (target - fraction) * pow(grid_dx, 3.0)
		var capacity := geometry[cell * 4 + 3]
		if target == 0.0 or target == capacity:
			pure_deficit_volume += deficit
		else:
			mixed_deficit_volume += deficit
		if capacity > 0.0 and capacity < 1.0:
			cut_deficit_volume += deficit
		if absf(fraction - target) > maximum_fraction_error:
			worst = {"cell": Vector3i(cell % grid_dims.x, (cell / grid_dims.x) % grid_dims.y, cell / (grid_dims.x * grid_dims.y)),
				"amount": amount, "geometric_fraction": fraction, "capacity": capacity}
		maximum_fraction_error = maxf(maximum_fraction_error, absf(fraction - target))
	return {"physical_time_s": _sim_time, "state_revision": _frame, "finite": finite,
		"method": "current_visible_gradient_open_tetrahedra",
		"geometric_volume_m3": volume, "amount_volume_m3": amount_volume,
		"relative_amount_volume_difference": absf(volume - amount_volume) / maxf(amount_volume, 1.0e-20),
		"local_absolute_volume_error_m3": absolute_error_volume,
		"local_fraction_max_error": maximum_fraction_error,
		"pure_cell_deficit_m3": pure_deficit_volume, "mixed_cell_deficit_m3": mixed_deficit_volume,
		"cut_cell_deficit_m3": cut_deficit_volume, "worst_cell": worst,
		"geometric_volume_conservation_verified": false}


func get_gpu_memory_bytes() -> int:
	return estimate_vram_bytes()


func estimate_vram_bytes() -> int:
	if not initialized:
		return 0
	var particles := particle_count * (16 + 16 + 48 + 4 + 4)
	var cells := grid_dims.x * grid_dims.y * grid_dims.z
	var face_count := (grid_dims.x + 1) * (grid_dims.y + 1) * (grid_dims.z + 1)
	var geometry_bytes := cells * 32 + face_count * 12 + _cut_vertex_bytes if free_surface_cut_cells and solid_cut_cells else 52
	return particles + cells * 36 + ceili(float(cells) / WG) * 4 \
		+ face_count * 108 + tex_width * tex_width * 16 + SCENE_UBO_SIZE + 48 + 48 + geometry_bytes \
		+ AMOUNT_STATE_HEADER_BYTES + (cells if conservative_amount_tracking else 1) * AMOUNT_CELL_BYTES \
		+ _pre_force_velocity_tex_size * _pre_force_velocity_tex_size * 16


func free_render() -> void:
	initialized = false
	if _rd != null:
		for uniform_set: RID in _uniform_sets.values():
			if uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set):
				_rd.free_rid(uniform_set)
		for buffer: RID in _buffers.values():
			if buffer.is_valid():
				_rd.free_rid(buffer)
		if _scene_ubo.is_valid():
			_rd.free_rid(_scene_ubo)
		for pipeline: RID in _pipelines.values():
			if pipeline.is_valid():
				_rd.free_rid(pipeline)
		for shader: RID in _shaders.values():
			if shader.is_valid():
				_rd.free_rid(shader)
		if _position_tex.is_valid():
			_rd.free_rid(_position_tex)
		if _pre_force_velocity_tex.is_valid():
			_rd.free_rid(_pre_force_velocity_tex)
	_uniform_sets.clear()
	_buffers.clear()
	_pipelines.clear()
	_shaders.clear()
	_rd = null
	_position_tex = RID()
	_pre_force_velocity_tex = RID()
	_pre_force_velocity_tex_size = 1
	_scene_ubo = RID()
	_scene_cache_hash = 0
	_scene_cache = PackedByteArray()
	_solid_geometry_build_ms = 0.0
	_solid_geometry_partial_cells = 0
	_solid_geometry_partial_faces = 0
	_cut_vertex_bytes = 16
