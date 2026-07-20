class_name FireWater
extends RefCounted
## Water droplet ↔ fire grid coupling for Fire-X (Wrede et al., SIGGRAPH Asia 2025).
##
## The droplets themselves are an [SphFluidSolver] (Clavet double-density SPH,
## Eq. 12-17, already implemented for the fluid demos). This class owns the
## particle↔grid sampling of Eq. 18-25 around it, as three compute passes:
##
##   scatter  particles → SSBO accumulators (Eq. 18-20)
##   gather   accumulators → liquid_scal / liquid_vel textures (Eq. 19-23)
##   return   textures → particle mass and temperature (Eq. 21, 24)
##
## Per-droplet mass and temperature ride in the spare w lanes of the SPH solver's
## position and velocity buffers, so the cell sort carries them along with their
## particle for free. A side buffer indexed by particle slot would be scrambled by
## the first sort, since the sort permutes slots.
##
## The P3 criterion is that the round trip conserves Σ m_p. Both directions are
## normalised for that; see the header of water_return.comp for the derivation.
##
## Evaporation (Eq. 9-11, 26-32) is P4, so mass only moves, never leaves.

## Droplet radius drives the SPH smoothing length; the paper's h_s range is
## 0.06-0.4 m (Tab. 3) and the neighbour search needs cell_size == h.
const SPH_H := 0.2
const DROPLET_MASS := 0.1
const AMBIENT_T := 300.0

var particle_count := 1024
var particles_active := 0

var sph: SphFluidSolver

var _rd: RenderingDevice
var _ssbo_scatter := RID()

# uniform_set_create binds against the shader, not the pipeline, so both are kept.
var _shader_scatter := RID()
var _shader_gather := RID()
var _shader_return := RID()
var _pipeline_scatter := RID()
var _pipeline_gather := RID()
var _pipeline_return := RID()
## Indexed by SPH parity: the solver ping-pongs its buffers every sub-step, so each
## pass needs a set built against either side rather than one rebuilt per frame.
var _sets_scatter := [RID(), RID()]
var _sets_return := [RID(), RID()]
var _uniform_set_gather := RID()
var _cached_scal_rid := RID()

var _grid_dims := Vector3i.ZERO
var _cell_size := 0.1
var _h_liquid := 0.15  # 1.5 * cell_size: one particle covers a 3³ block of cells
## World position of cell (0,0,0)'s corner. The fire domain is centred on the origin
## in x/z with the floor at y = 0 (fire_common.comp cell_to_world), so particle
## positions have to be shifted by this before they can be binned.
var _grid_origin := Vector3.ZERO

var initialized := false

## Σ m_p at spawn, and the same sum read back after the round trip.
var initial_mass := 0.0
var measured_mass := 0.0
var mass_error := 0.0
## Particles actually inside the fire domain, i.e. the ones the round trip covers.
var coupled_count := 0
## Droplet spread and peak speed, for the "fall, pile up, do not explode" half of
## the P3 criterion.
var droplet_y_min := 0.0
var droplet_y_max := 0.0
var droplet_speed_max := 0.0
var mass_measured_once := false

var _frame_count := 0
## Readback is a stall, so it runs on a slow cadence rather than every frame.
const MEASURE_INTERVAL := 30


func init_render(fire_grid_dims: Vector3i, fire_cell_size: float) -> void:
	if _rd != null:
		return
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return

	_grid_dims = fire_grid_dims
	_cell_size = fire_cell_size
	_h_liquid = fire_cell_size * 1.5
	var domain := Vector3(fire_grid_dims) * fire_cell_size
	_grid_origin = Vector3(-0.5 * domain.x, 0.0, -0.5 * domain.z)

	_init_sph(domain)

	var num_cells := fire_grid_dims.x * fire_grid_dims.y * fire_grid_dims.z
	var empty_accum := PackedByteArray()
	empty_accum.resize(num_cells * 16)
	_ssbo_scatter = _rd.storage_buffer_create(num_cells * 16, empty_accum)

	_shader_scatter = _compile("water_scatter")
	_shader_gather = _compile("water_gather")
	_shader_return = _compile("water_return")
	if not (_shader_scatter.is_valid() and _shader_gather.is_valid() and _shader_return.is_valid()):
		return
	_pipeline_scatter = _rd.compute_pipeline_create(_shader_scatter)
	_pipeline_gather = _rd.compute_pipeline_create(_shader_gather)
	_pipeline_return = _rd.compute_pipeline_create(_shader_return)

	for parity in 2:
		var pos: RID = sph.parity_positions_rid(parity)
		var vel: RID = sph.parity_velocities_rid(parity)
		_sets_scatter[parity] = _rd.uniform_set_create([
			_buffer_uniform(0, pos),
			_buffer_uniform(1, vel),
			_buffer_uniform(2, _ssbo_scatter),
		], _shader_scatter, 0)

	initialized = true


## The SPH domain is the fire domain, so a droplet's world position means the same
## thing to both and the scatter needs no second transform.
func _init_sph(domain: Vector3) -> void:
	sph = SphFluidSolver.new()
	sph.particle_count = particle_count
	sph.cell_size = SPH_H
	sph.h = SPH_H
	sph.grid_origin = _grid_origin
	sph.grid_dims = Vector3i(
		ceili(domain.x / SPH_H), ceili(domain.y / SPH_H), ceili(domain.z / SPH_H))
	sph.gravity = Vector3(0.0, -9.81, 0.0)
	# Nothing poured yet. active_count is raised by spawn_droplets.
	sph.active_count = 0
	# NON-PAPER: the stiffnesses are this solver's own (pressure_mult 180,
	# near_pressure_mult 12), not Tab. 3's Stiffness 0.004-0.005. The two equations
	# of state differ by a normalisation that has not been reconciled against
	# Eq. 14 yet, so the working values are kept rather than transcribing numbers
	# that would mean something else here. Revisit with the P4 tuning pass.
	var seed := PackedFloat32Array()
	seed.resize(particle_count * 4)
	sph.set_seed_positions(seed)
	sph.init_render()


func _compile(name: String) -> RID:
	var src := FileAccess.get_file_as_string("res://shaders/fire/%s.comp" % name)
	var spirv := ShaderCache.compile(_rd, name, src)
	if not spirv.compile_error_compute.is_empty():
		push_error("%s compile error:\n%s" % [name, spirv.compile_error_compute])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


func _buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.add_id(buffer)
	return u


func _image_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.add_id(tex)
	return u


## Must run on the render thread, after [method init_render] has actually executed
## there — calling it from _ready alongside a queued init_render silently spawns
## nothing, because [member initialized] is still false at that point.
func spawn_droplets(count: int, pos: Vector3, radius: float) -> void:
	if not initialized or count <= 0:
		return

	var n := mini(count, particle_count)
	# Position w carries the temperature; the solver preserves it (it is the lava
	# heat channel, inert with lava mode off) and the sort moves it with the slot.
	var seed := PackedFloat32Array()
	seed.resize(n * 4)
	# Velocity w carries the mass, and starts at rest.
	var vel := PackedFloat32Array()
	vel.resize(n * 4)

	for i in n:
		var p := pos + Vector3(
			randf_range(-radius, radius),
			randf_range(-radius, radius),
			randf_range(-radius, radius))
		seed[i * 4 + 0] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		seed[i * 4 + 3] = AMBIENT_T
		vel[i * 4 + 3] = DROPLET_MASS

	var seed_bytes := seed.to_byte_array()
	var vel_bytes := vel.to_byte_array()
	# Both parities, so the write lands wherever the next sub-step reads from.
	for parity in 2:
		var pos_rid: RID = sph.parity_positions_rid(parity)
		var vel_rid: RID = sph.parity_velocities_rid(parity)
		_rd.buffer_update(pos_rid, 0, seed_bytes.size(), seed_bytes)
		_rd.buffer_update(vel_rid, 0, vel_bytes.size(), vel_bytes)

	particles_active = n
	sph.active_count = n
	initial_mass = DROPLET_MASS * float(n)
	mass_measured_once = false


## std430 rounds a push constant block up to a 16-byte multiple, and the driver
## rejects anything shorter than the rounded size.
func _push_bytes(ints: PackedInt32Array, floats: PackedFloat32Array) -> PackedByteArray:
	var bytes := ints.to_byte_array()
	bytes.append_array(floats.to_byte_array())
	var padded := (bytes.size() + 15) / 16 * 16
	bytes.resize(padded)
	return bytes


func _particle_push() -> PackedByteArray:
	return _push_bytes(
		PackedInt32Array([particles_active, _grid_dims.x, _grid_dims.y, _grid_dims.z]),
		PackedFloat32Array([_cell_size, _h_liquid,
			_grid_origin.x, _grid_origin.y, _grid_origin.z]))


## Advances the droplets themselves (Eq. 12-17). Runs before the scatter, so the
## grid samples where the droplets are this frame rather than last.
func step_droplets(delta: float) -> void:
	if not initialized or particles_active == 0:
		return
	sph.step_render(delta)


func scatter_render() -> void:
	if not initialized or particles_active == 0:
		return

	var push := _particle_push()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_scatter)
	_rd.compute_list_bind_uniform_set(cl, _sets_scatter[sph.current_parity()], 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, ceili(float(particles_active) / 256.0), 1, 1)
	_rd.compute_list_end()


func gather_render(liquid_scal_rid: RID, liquid_vel_rid: RID) -> void:
	if not initialized or particles_active == 0:
		return
	if not liquid_scal_rid.is_valid() or not liquid_vel_rid.is_valid():
		return

	if liquid_scal_rid != _cached_scal_rid:
		_rebuild_texture_sets(liquid_scal_rid, liquid_vel_rid)

	var push := _push_bytes(
		PackedInt32Array([_grid_dims.x, _grid_dims.y, _grid_dims.z]),
		PackedFloat32Array([_cell_size]))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_gather)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set_gather, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl,
		ceili(float(_grid_dims.x) / 8.0),
		ceili(float(_grid_dims.y) / 8.0),
		ceili(float(_grid_dims.z) / 4.0))
	_rd.compute_list_end()


func return_render() -> void:
	if not initialized or particles_active == 0:
		return
	var set_rid: RID = _sets_return[sph.current_parity()]
	if not set_rid.is_valid():
		return

	var push := _particle_push()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_return)
	_rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, ceili(float(particles_active) / 256.0), 1, 1)
	_rd.compute_list_end()

	_frame_count += 1
	if _frame_count % MEASURE_INTERVAL == 0:
		_measure_particle_mass()


## The gather and return sets bind solver textures, whose RIDs are only known once
## a frame runs and change on a resolution switch.
func _rebuild_texture_sets(liquid_scal_rid: RID, liquid_vel_rid: RID) -> void:
	_free_texture_sets()
	_uniform_set_gather = _rd.uniform_set_create([
		_image_uniform(0, liquid_scal_rid),
		_image_uniform(1, liquid_vel_rid),
		_buffer_uniform(2, _ssbo_scatter),
	], _shader_gather, 0)
	for parity in 2:
		_sets_return[parity] = _rd.uniform_set_create([
			_buffer_uniform(0, sph.parity_positions_rid(parity)),
			_buffer_uniform(1, sph.parity_velocities_rid(parity)),
			_image_uniform(2, liquid_scal_rid),
		], _shader_return, 0)
	_cached_scal_rid = liquid_scal_rid


## The P3 criterion measured directly: Σ m_p over the particle buffer after the
## round trip, against Σ m_p at spawn.
##
## Particles outside the domain are skipped identically by both the scatter and the
## return, so their mass survives untouched and would pass the test without ever
## making the trip. The in-domain count is reported alongside the error so a green
## number cannot hide an empty test.
func _measure_particle_mass() -> void:
	if initial_mass <= 0.0:
		return

	var parity := sph.current_parity()
	var vel_data := _rd.buffer_get_data(sph.parity_velocities_rid(parity), 0, particles_active * 16)
	var pos_data := _rd.buffer_get_data(sph.parity_positions_rid(parity), 0, particles_active * 16)
	var domain_size := Vector3(_grid_dims) * _cell_size
	var total := 0.0
	var coupled := 0
	# The other half of the criterion is that the droplets fall, pile up and stay
	# finite, so the same readback reports the height they have settled to and the
	# fastest particle. A blown-up solver shows here as a climbing max speed or a
	# non-finite height long before it is obvious on screen.
	var y_min := INF
	var y_max := -INF
	var speed_max := 0.0

	for i in particles_active:
		total += vel_data.decode_float(i * 16 + 12)
		var local := Vector3(
			pos_data.decode_float(i * 16),
			pos_data.decode_float(i * 16 + 4),
			pos_data.decode_float(i * 16 + 8)) - _grid_origin
		if local.x >= 0.0 and local.y >= 0.0 and local.z >= 0.0 \
				and local.x < domain_size.x and local.y < domain_size.y \
				and local.z < domain_size.z:
			coupled += 1
		y_min = minf(y_min, local.y)
		y_max = maxf(y_max, local.y)
		speed_max = maxf(speed_max, Vector3(
			vel_data.decode_float(i * 16),
			vel_data.decode_float(i * 16 + 4),
			vel_data.decode_float(i * 16 + 8)).length())

	measured_mass = total
	mass_error = abs(measured_mass - initial_mass) / initial_mass
	coupled_count = coupled
	droplet_y_min = y_min
	droplet_y_max = y_max
	droplet_speed_max = speed_max
	mass_measured_once = true
	# GDScript's formatter has no %e, so the relative error goes through str().
	print("P3 @ frame %d: %d/%d in domain, Σm_p %.6f→%.6f kg, err=%s %s | y %.2f..%.2f m, vmax %.2f m/s" % [
		_frame_count, coupled, particles_active, initial_mass, measured_mass,
		str(mass_error), "PASS" if mass_error < 1e-3 else "FAIL",
		y_min, y_max, speed_max])


func _free_texture_sets() -> void:
	if _uniform_set_gather.is_valid():
		_rd.free_rid(_uniform_set_gather)
		_uniform_set_gather = RID()
	for parity in 2:
		if _sets_return[parity].is_valid():
			_rd.free_rid(_sets_return[parity])
			_sets_return[parity] = RID()


func free_render() -> void:
	if _rd == null:
		return
	_free_texture_sets()
	for parity in 2:
		if _sets_scatter[parity].is_valid():
			_rd.free_rid(_sets_scatter[parity])
	for rid in [_pipeline_scatter, _pipeline_gather, _pipeline_return,
			_shader_scatter, _shader_gather, _shader_return, _ssbo_scatter]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if sph != null and sph.initialized:
		sph.free_render()
	initialized = false
