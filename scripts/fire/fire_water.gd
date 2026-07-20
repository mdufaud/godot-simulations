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
## With P4's evaporation running, the grid stage takes mass out of liquid_scal
## before the return reads it, so Sum m_p is meant to fall and the conservation
## check only applies with [member evaporation_active] false.

## Droplet radius drives the SPH smoothing length; the paper's h_s range is
## 0.06-0.4 m (Tab. 3) and the neighbour search needs cell_size == h.
const SPH_H := 0.2
## Mass one particle stands for, not the mass of one droplet: a 1 mm droplet is
## 5e-7 kg. This is Fire-X Tab. 3 "Particle Emitter Parameter / Mass", whose range
## is 0.1-1.0 kg; at the nozzle's default 60 Hz the low end is a 6 kg/s hose.
##
## It matters where the water goes rather than how much of it there is: the same
## 0.1 kg dropped as a single packed ball puts ~1000 kg/m^3 of liquid in one cell,
## and Eq. 32 then throttles the updraft hard enough to make the flame burn
## *hotter*. Fig. 8 makes the same point — a stream aimed at the top of a flame
## has "a limited extinguishing effect".
const DROPLET_MASS := 0.1
const AMBIENT_T := 300.0

var particle_count := 1024
var particles_active := 0

# --- Nozzle, Fire-X Tab. 3 "Particle Emitter Parameter" ---
## Droplets emitted per second. Tab. 3 "Frequency", range 10-100 Hz.
var jet_frequency := 60.0
## Tab. 3 "Velocity", range 0.0-10.0 m/s.
var jet_velocity := 6.0
## Cone half-angle spread. Tab. 3 "Spray Angle", range 0-180 degrees. Fig. 8
## contrasts a laminar stream (0 degrees here) with a spray nozzle (wide cone),
## and finds the spray the more effective of the two.
var jet_spray_angle := 0.0
var jet_position := Vector3(2.5, 2.0, 0.0)
var jet_direction := Vector3(-1.0, -0.6, 0.0)
## Radius of the emission disc at the nozzle mouth.
var jet_nozzle_radius := 0.08

var _jet_accum := 0.0
var _jet_cursor := 0
var _jet_emitted := 0
## Mirrors FireGpuSolver.evaporation_enabled: mass is expected to leave when it is
## on, so the round-trip conservation check is only meaningful when it is off.
var evaporation_active := false

var sph: SphFluidSolver

var _rd: RenderingDevice
var _ssbo_scatter := RID()
## Eq. 25 needs signed sums, which an atomic uint cannot carry; see water_scatter.
var _ssbo_vel_scatter := RID()

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
	_ssbo_vel_scatter = _rd.storage_buffer_create(num_cells * 16, empty_accum)

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
			_buffer_uniform(3, _ssbo_vel_scatter),
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

	# Reconciliation against Fire-X Eq. 14 / Tab. 3 (the "verify before copying"
	# the plan asked for). The solver's state equation is, per sph_pressure.comp,
	#   pressure      = (rho      - rho_0) * pressure_mult
	#   near_pressure =  near_rho          * near_pressure_mult
	# which is exactly Eq. 14 (p_ij = k_s(rho_ij - rho_0), p^near = k^near.rho^near)
	# in form. The *numbers* still cannot be transcribed, for two reasons:
	#  1. Kernel normalisation. The paper's density is the bare Clavet sum of
	#     (1 - r/h)^2; this solver's is a SpikyPow2 kernel carrying a 15/(2.pi.h^5)
	#     factor, so its rho is ~15/(2.pi.h^3) times larger (~300x at h = 0.2 m) and
	#     a matching k_s would be that much smaller. Tab. 3's Stiffness 0.004-0.005
	#     is defined against the bare sum, not this one.
	#  2. Integration scheme. Clavet applies the pressure as a position displacement
	#     (D = dt^2.grad p); this solver applies it as a force through the SPH
	#     gradient, integrated to velocity. The two are not unit-compatible, so even
	#     after (1) the coefficients would not line up.
	# What *does* carry over is the paper's ratio and character: Near Stiffness is
	# 3-4x the Stiffness (0.01-0.02 vs 0.004-0.005), i.e. short-range incompressibility
	# dominates so droplets hold their shape instead of interpenetrating. The demo
	# default 180/12 has the far term dominant, which reads as beads that scatter on
	# impact. These droplet-only values put the near term on top and add viscous
	# cohesion so a jet lands as a puddle. They do not touch the shared solver used
	# by the fluid demos.
	sph.pressure_mult = 60.0
	sph.near_pressure_mult = 240.0
	# Clavet's viscosity is a linear/quadratic impulse (Eq. 17, Tab. 3: Linear 0.0,
	# Quadratic 0.4); this solver's is XSPH velocity smoothing, a different model,
	# so the number is not the paper's 0.4 either. Raised from the demo's 0.14 for
	# the cohesion a settling puddle needs; kept under 0.5, where XSPH goes unstable.
	sph.viscosity_strength = 0.4
	sph.collision_damping = 0.3
	# Spawn spacing feeds the rest-density estimate; at the droplet smoothing length
	# it wants to be a fraction of h, not the demo's fixed 0.12 m.
	sph.spacing = SPH_H * 0.5

	var seed := PackedFloat32Array()
	seed.resize(particle_count * 4)
	sph.set_seed_positions(seed)
	sph.init_render()


## Position texture and its width, for whoever draws the droplets. The RID is
## only valid once [method init_render] has run on the render thread.
func sph_position_tex_rid() -> RID:
	return sph.get_position_tex_rid() if sph != null else RID()


func sph_tex_width() -> int:
	return sph.tex_width if sph != null else 256


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


## Emit one nozzle burst, Fire-X Tab. 3 "Particle Emitter Parameter".
##
## The paper's extinguishing experiments (Fig. 8) are a continuous stream, not a
## dropped packet: "we use two nozzle types to generate a laminar (a)-(h) and a
## spray (i-p) type of water stream to extinguish a flame". [member jet_spray_angle]
## is what separates the two — 0 degrees is the laminar jet, a wide cone is the
## spray nozzle.
##
## The emitter appends into free slots until the buffer is full, then recycles
## from the start. Recycling does not pick the oldest particle: the SPH cell sort
## permutes the slots every sub-step, so slot order carries no age information —
## the write lands on an arbitrary live droplet. For a running hose that is
## indistinguishable from a lifetime cutoff (Tab. 3 "Lifetime"), and it is the
## only scheme that does not need a fourth per-particle lane the buffers do not
## have.
##
## Render thread only.
func emit_jet(delta: float) -> void:
	if not initialized:
		return

	_jet_accum += delta * jet_frequency
	var count := int(_jet_accum)
	if count <= 0:
		return
	_jet_accum -= float(count)
	count = mini(count, particle_count)

	var seed := PackedFloat32Array()
	seed.resize(count * 4)
	var vel := PackedFloat32Array()
	vel.resize(count * 4)

	var dir := jet_direction.normalized()
	# Any two vectors orthogonal to the aim, to spread the cone across.
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 1e-6:
		side = dir.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := dir.cross(side)
	var half_angle := deg_to_rad(jet_spray_angle) * 0.5

	for i in count:
		# Cone sampling: uniform azimuth, angle scaled by the square root so the
		# cross-section fills evenly instead of clumping on the axis.
		var phi := randf() * TAU
		var theta := half_angle * sqrt(randf())
		var d := (dir * cos(theta)
			+ (side * cos(phi) + up * sin(phi)) * sin(theta)).normalized()
		var p := jet_position + d * (jet_nozzle_radius * randf())
		seed[i * 4 + 0] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		seed[i * 4 + 3] = AMBIENT_T # Tab. 3 emitter temperature, 300 K
		var v := d * jet_velocity
		vel[i * 4 + 0] = v.x
		vel[i * 4 + 1] = v.y
		vel[i * 4 + 2] = v.z
		vel[i * 4 + 3] = DROPLET_MASS

	# One contiguous run per call, wrapped at the end of the buffer, so the burst
	# is at most two buffer_update calls instead of one per droplet.
	var written := 0
	while written < count:
		var run := mini(count - written, particle_count - _jet_cursor)
		var pos_bytes := seed.slice(written * 4, (written + run) * 4).to_byte_array()
		var vel_bytes := vel.slice(written * 4, (written + run) * 4).to_byte_array()
		for parity in 2:
			_rd.buffer_update(sph.parity_positions_rid(parity),
				_jet_cursor * 16, pos_bytes.size(), pos_bytes)
			_rd.buffer_update(sph.parity_velocities_rid(parity),
				_jet_cursor * 16, vel_bytes.size(), vel_bytes)
		_jet_cursor = (_jet_cursor + run) % particle_count
		written += run

	particles_active = maxi(particles_active, mini(_jet_emitted + count, particle_count))
	_jet_emitted += count
	sph.active_count = particles_active
	initial_mass = DROPLET_MASS * float(particles_active)
	mass_measured_once = false


## Must run on the render thread, after [method init_render] has actually executed
## there — calling it from _ready alongside a queued init_render silently spawns
## nothing, because [member initialized] is still false at that point.
func spawn_droplets(count: int, pos: Vector3, radius: float,
		velocity := Vector3.ZERO) -> void:
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
		vel[i * 4 + 0] = velocity.x
		vel[i * 4 + 1] = velocity.y
		vel[i * 4 + 2] = velocity.z
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
	# The nozzle appends after whatever this dropped in, rather than overwriting it.
	_jet_cursor = n % particle_count
	_jet_emitted = n


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
		_buffer_uniform(3, _ssbo_vel_scatter),
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
	# var verdict := "evaporating" if evaporation_active \
		# else ("PASS" if mass_error < 1e-3 else "FAIL")
	# print("water @ frame %d: %d/%d in domain, Σm_p %.6f→%.6f kg, err=%s %s | y %.2f..%.2f m, vmax %.2f m/s" % [
		# _frame_count, coupled, particles_active, initial_mass, measured_mass,
		# str(mass_error), verdict, y_min, y_max, speed_max])


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
			_shader_scatter, _shader_gather, _shader_return,
			_ssbo_scatter, _ssbo_vel_scatter]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if sph != null and sph.initialized:
		sph.free_render()
	initialized = false
