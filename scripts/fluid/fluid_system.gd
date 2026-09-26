class_name FluidSystem
extends Node3D
## Reusable GPU fluid: one dual-density SPH simulation with a screen-space surface
## and optional foam. Instance it in a scene, assign a camera, and call start().
## The host scene owns its camera, environment and ground; this node owns the fluid.

enum Scenario { POOL, CASCADE, BASIN }
enum FluidKind { WATER, LAVA, MERCURY, HONEY, WATER_OIL }

const RADIUS := 0.16
const POUR_COOLDOWN_MS := 400
const POOL_START_MULTIPLIER := 1
const POOL_CAPACITY_MULTIPLIER := 3
const POOL_ADD_BATCH_DIVISOR := 4
const HONEY_CASCADE_FLOW_MAX := 1.3

# --- Public configuration (set before start(); use the setters afterwards). ---
@export var config: FluidConfig = FluidConfig.new()

var scenario: Scenario = Scenario.POOL
var mode: FluidKind = FluidKind.WATER
var particle_count := 65536
var foam_enabled := true
var render_scale := 0.5
var flow_rate := 1.0
var camera: Camera3D # REQUIRED: the main camera the prepass cameras track.
var domain_origin := Vector3(-8.0, 0.0, -8.0)
var domain_size := Vector3(16.0, 16.0, 16.0)
var seed_origin := Vector3(-7.7, 0.1, -7.7)

# --- Planet mode (SPH only; leave planet_gravity at 0 for the flat-world box). ---
## Signed-distance field of the terrain to collide against, from
## PlanetGenerator.density_texture(). Negative inside the terrain.
var planet_field := RID()
## Side of the cube that field covers, centred on planet_centre.
var planet_field_world_size := 0.0
var planet_centre := Vector3.ZERO
var planet_gravity := 0.0
## Base sphere radius (before the noise displacement), used only to place fluid.
## Peaks rise well above it, so some fluid spawns buried and the collision pass
## pushes it out on the first sub-step -- which is what SebLague's spawner does too.
var planet_radius := 0.0
## Number of grid cells per axis across the field. Cell size follows from it, and
## the smoothing radius follows the cell size.
var planet_grid_dim := 144
## Half-angle of the spawn cap, in degrees. 180 gives SebLague's full shell; a cap
## concentrates the same particle budget deep enough to pool and run as streams.
var spawn_cap_degrees := 40.0
var spawn_axis := Vector3.UP
## Shell thickness as a multiple of the planet radius, above the tallest peak.
var spawn_height := 0.06
## Half-angle of a poured blob. Narrow enough to land as a trickle rather than a sheet.
var pour_cap_degrees := 10.0
## Share of the particle buffer recycled per pour.
var pour_fraction := 0.15

var sph_solver := SphFluidSolver.new()
var active_solver: SphFluidSolver

var renderer: ScreenSpaceFluidRenderer
var _radius := RADIUS
var _pour_cursor := 0
var _last_pour_ms := -POUR_COOLDOWN_MS
var _step_clock := SimStepClock.new()
# Set when a teardown+re-init pair is queued on the render thread; _process
# skips renderer updates until the queued init has landed (generation observed),
# or one frame hands the renderer the position RID being freed.
var _pending_init := false
var _expected_init_generation := 0
var _base_texture_width := 0


func active() -> Object:
	return active_solver


func _foam_active() -> bool:
	return foam_enabled and mode == FluidKind.WATER


func start() -> void:
	var config_error := config.validate()
	if config_error != "":
		push_error("Fluid config: %s" % config_error)
		return
	assert(camera != null, "FluidSystem.camera must be set before start()")
	particle_count = config.default_particle_count
	_base_texture_width = config.texture_width
	_ensure_texture_capacity(_solver_particle_capacity())
	flow_rate = config.default_flow
	domain_origin = config.domain_origin
	domain_size = config.domain_size_m
	sph_solver.config = config
	active_solver = sph_solver
	_initialize_runtime()


func _setup_renderer() -> void:
	renderer = ScreenSpaceFluidRenderer.new()
	renderer.config = config
	renderer.camera = camera
	renderer.particle_count = active_solver.particle_count
	renderer.tex_width = active_solver.tex_width
	renderer.radius = _radius
	renderer.mode = mode
	renderer.render_scale = render_scale
	renderer.domain_aabb = AABB(domain_origin, domain_size)
	renderer.build_foam = true
	renderer.foam_cap = sph_solver.foam_cap()
	renderer.foam_tex_width = sph_solver.foam_tex_width
	renderer.foam_billboard_size = _foam_billboard_size()
	add_child(renderer)
	renderer.start()


# --- Runtime control -------------------------------------------------------


func set_configuration(next_mode: FluidKind, next_scenario: Scenario) -> void:
	if next_mode == mode and next_scenario == scenario:
		return
	mode = next_mode
	scenario = next_scenario
	_rebuild()


func set_flow(value: float) -> void:
	flow_rate = clampf(value, config.flow_min,
		HONEY_CASCADE_FLOW_MAX if mode == FluidKind.HONEY and scenario == Scenario.CASCADE
		else config.flow_max)
	sph_solver.emission_rate = flow_rate


func set_particle_count(n: int) -> void:
	var count_changed := n != particle_count
	# init_render validates the config before allocating, and every later re-init
	# (restart, mode/preset switches) validates the same pair, so the config must
	# describe the new count before the teardown queues it.
	config.default_particle_count = n
	particle_count = n
	_ensure_texture_capacity(_solver_particle_capacity())
	if active_solver == null or not count_changed:
		return
	_rebuild()


func can_add_pool_liquid() -> bool:
	return scenario == Scenario.POOL and active_solver != null \
		and active_solver.initialized and not _pending_init \
		and active_solver.active_count >= 0 \
		and active_solver.active_count < active_solver.particle_count


func add_pool_liquid() -> bool:
	if not can_add_pool_liquid():
		return false
	var from: int = active_solver.active_count
	var initial_count := particle_count * POOL_START_MULTIPLIER
	# Each Add pours one DIVISORth of the headroom above the initial fill, so
	# DIVISOR presses take the pool from its start count to full capacity.
	@warning_ignore("integer_division")
	var batch_capacity := maxi(1, (active_solver.particle_count - initial_count) / POOL_ADD_BATCH_DIVISOR)
	var count := mini(batch_capacity, active_solver.particle_count - from)
	var side := ceili(pow(float(count), 1.0 / 3.0))
	var initial_side := ceili(pow(float(initial_count), 1.0 / 3.0))
	var initial_layers := ceili(float(initial_count) / float(initial_side * initial_side))
	var spacing: float = active_solver.spacing
	@warning_ignore("integer_division")
	var batch_index := (from - initial_count) / batch_capacity
	var patch_span := float(side - 1) * spacing
	var left_x := domain_origin.x + 0.4
	var right_x := domain_origin.x + domain_size.x - 0.4 - patch_span
	var near_z := domain_origin.z + 0.4
	var far_z := domain_origin.z + domain_size.z - 0.4 - patch_span
	var start_x := left_x if batch_index % 2 == 0 else right_x
	var start_z := near_z if batch_index < 2 else far_z
	var start_y := seed_origin.y + float(initial_layers) * spacing + 1.4
	var batch := PackedFloat32Array()
	batch.resize(count * 4)
	for i in count:
		var x := i % side
		@warning_ignore("integer_division")
		var y := (i / side) % side
		@warning_ignore("integer_division")
		var z := i / (side * side)
		var p := Vector3(start_x + float(x) * spacing,
			start_y + float(y) * spacing, start_z + float(z) * spacing)
		batch[i * 4] = p.x
		batch[i * 4 + 1] = p.y
		batch[i * 4 + 2] = p.z
		var phase := 1.0 if mode == FluidKind.LAVA else 0.0
		if mode == FluidKind.WATER_OIL:
			@warning_ignore("integer_division")
			phase = float(((from + i) / 216) % 2)
		batch[i * 4 + 3] = phase
	active_solver.active_count = from + count
	renderer.set_visible_count(active_solver.active_count)
	RenderingServer.call_on_render_thread(sph_solver.respawn_range.bind(from, batch))
	return true


func _solver_particle_capacity() -> int:
	return particle_count * POOL_CAPACITY_MULTIPLIER \
		if scenario == Scenario.POOL and not planet_mode() else particle_count


func _ensure_texture_capacity(count: int) -> void:
	while count > config.texture_width * config.texture_width:
		config.texture_width *= 2
		push_warning("Fluid: raised position texture to %dpx for %d particles" % [
			config.texture_width, count])


# The pool is allocated with the solver, so toggling only gates the foam stages
# and hides the billboards — no GPU resources are created or destroyed here.
func set_foam_enabled(on: bool) -> void:
	foam_enabled = on
	sph_solver.foam_enabled = _foam_active()
	if renderer != null:
		renderer.set_foam_visible(_foam_active())


## Planet mode: the composite draws after the atmosphere quad and both read the
## same pre-transparent screen copy, so the atmosphere cannot fog the water from
## outside. Feeding it the same parameters lets it scatter its own output.
func set_atmosphere(params: Dictionary) -> void:
	var cm := renderer.composite_material()
	cm.set_shader_parameter("atmosphere_enabled", not params.is_empty())
	for key in params:
		cm.set_shader_parameter(key, params[key])


func set_render_scale(v: float) -> void:
	render_scale = v
	renderer.set_render_scale(v)


func restart() -> void:
	_pour_cursor = 0
	_last_pour_ms = -POUR_COOLDOWN_MS
	_step_clock.reset()
	_rebuild()



func set_profiling(on: bool) -> void:
	sph_solver.profiling = on


func set_sph_pressure(value: float) -> void:
	sph_solver.pressure_mult = value


func get_sph_pressure() -> float:
	return sph_solver.pressure_mult


func set_sph_near_pressure(value: float) -> void:
	sph_solver.near_pressure_mult = value


func get_sph_near_pressure() -> float:
	return sph_solver.near_pressure_mult


func set_sph_viscosity(value: float) -> void:
	sph_solver.viscosity_strength = value


func get_sph_viscosity() -> float:
	return sph_solver.viscosity_strength


func set_sph_bounce(value: float) -> void:
	sph_solver.collision_damping = value


func get_sph_bounce() -> float:
	return sph_solver.collision_damping


func set_sph_substeps(value: float) -> void:
	sph_solver.substeps = int(round(value))


func get_sph_substeps() -> int:
	return sph_solver.substeps


func set_sph_cohesion(value: float) -> void:
	sph_solver.cohesion_strength = value


func get_sph_cohesion() -> float:
	return sph_solver.cohesion_strength


func set_sph_foam_amount(value: float) -> void:
	sph_solver.foam_spawn_rate = value


func get_sph_foam_amount() -> float:
	return sph_solver.foam_spawn_rate


func set_sph_foam_threshold(value: float) -> void:
	sph_solver.foam_trapped_min = value


func get_sph_foam_threshold() -> float:
	return sph_solver.foam_trapped_min


func set_sph_foam_life(value: float) -> void:
	sph_solver.foam_life_max = value


func get_sph_foam_life() -> float:
	return sph_solver.foam_life_max


func get_timings() -> Dictionary:
	return active_solver.get_timings() if active_solver != null else {}


func request_validation_stats(result: Dictionary) -> void:
	if active_solver == null:
		result["done"] = true
		return
	RenderingServer.call_on_render_thread(active_solver.capture_validation_stats.bind(result))


func profiled_viewports() -> Array:
	return renderer.profiled_viewports()


# --- Solver tuning ---------------------------------------------------------

func planet_mode() -> bool:
	return planet_gravity > 0.0 and planet_field.is_valid()


func set_sky_up_axis(up: Vector3) -> void:
	renderer.composite_material().set_shader_parameter("sky_up_axis", up)


## Points the composite's sun highlight along the scene light, so the reflection
## matches the actual lighting. `direction` is where the light travels -- for a
## DirectionalLight3D, that is -basis.z.
func set_light_direction(direction: Vector3) -> void:
	if renderer == null:
		return
	renderer.composite_material().set_shader_parameter("sun_direction", direction.normalized())


## Feeds the composite the scene's real sky gradient, so grazing-angle Fresnel
## brightens toward the horizon the camera actually sees instead of the baked-in
## default (which reads as painted plastic on settled water).
func set_sky_colors(zenith: Color, horizon: Color) -> void:
	if renderer == null:
		return
	renderer.composite_material().set_shader_parameter("sky_zenith", zenith)
	renderer.composite_material().set_shader_parameter("sky_horizon", horizon)


## Draw order for the full-screen composite quad. Any other transparent full-screen
## quad reading SCREEN_TEXTURE (the planet's atmosphere) shares the same screen copy,
## so the two do not blend -- the later one overwrites the earlier. Raise this to keep
## the fluid visible alongside one.
func set_composite_priority(p: int) -> void:
	renderer.composite_material().render_priority = p


## Grid, kernel radius and spawn spacing all scale together off the planet's volume.
## _compute_rest_density() derives the density target from h/spacing, so keeping
## their ratio fixed means the pressure target stays valid at any scale; only the
## pressure multiplier needs the extra factor, since pressure acceleration carries
## a 1/h in its gradient.
func _configure_planet_solver() -> void:
	var cell: float = planet_field_world_size / float(planet_grid_dim)
	sph_solver.grid_dims = Vector3i(planet_grid_dim, planet_grid_dim, planet_grid_dim)
	sph_solver.grid_origin = planet_centre - Vector3.ONE * planet_field_world_size * 0.5
	# cell_size must stay equal to h: the neighbour macro scans a 3x3x3 cell block.
	sph_solver.cell_size = cell
	sph_solver.h = cell
	sph_solver.spacing = cell * 0.48
	sph_solver.pressure_mult = 180.0 * (cell / 0.25)
	sph_solver.near_pressure_mult = 12.0 * (cell / 0.25)
	# SebLague's collisionDamping: the normal component is removed outright, so this
	# is tangential retention, not restitution. Near 1 lets fluid sheet across rock.
	sph_solver.collision_damping = 0.999
	sph_solver.planet_centre = planet_centre
	sph_solver.planet_gravity = planet_gravity
	sph_solver.planet_field_world_size = planet_field_world_size
	sph_solver.planet_skin = cell * 0.25
	# Wider than a texel: with trilinear filtering this is the only smoothing there
	# is, and it keeps particles from jittering on texel facets.
	sph_solver.planet_normal_offset = cell * 1.25
	sph_solver.set_planet_field(planet_field)
	# Foam settings straight from SebLague's Earth.unity, the scene his planet foam
	# is tuned in (his C# field defaults are not what he ships). All of them are
	# expressed against his smoothing radius of 0.2, so only the budget is rescaled.
	# A planet pours far more violently than the flat tank -- fluid falls from orbit
	# rather than sloshing -- so the rate is five times the flat one and the fade-in
	# holds foam off until the initial shell has landed.
	sph_solver.foam_spawn_rate = 600.0
	sph_solver.foam_spawn_fade_start = 4.0
	sph_solver.foam_spawn_fade_time = 1.0
	sph_solver.foam_trapped_min = 8.0
	sph_solver.foam_trapped_max = 15.0
	# Earth.unity has no surface gate; the orbital pour is violent enough that
	# the churn it wants foam on sits at low density anyway.
	sph_solver.foam_surface_gate = 0.0
	sph_solver.foam_ke_min = 9.0
	sph_solver.foam_ke_max = 20.0
	sph_solver.foam_life_min = 5.0
	sph_solver.foam_life_max = 15.0
	# The impostor radius is tuned against the default spacing, so it has to follow
	# the spacing up or the surface reconstructs full of holes.
	_radius = RADIUS * (sph_solver.spacing / 0.12)
	# Keeps the MultiMesh from being frustum-culled as a whole while fluid orbits.
	domain_origin = sph_solver.grid_origin
	domain_size = Vector3.ONE * planet_field_world_size


func _configure_solver() -> void:
	sph_solver.material = mode
	sph_solver.scene_id = scenario
	# Everything that distinguishes one liquid from another comes from the
	# FluidMaterial spec; nothing below re-derives per-material numbers.
	var spec := FluidMaterial.for_kind(mode)
	sph_solver.material_density_kg_m3 = spec.density_kg_m3
	sph_solver.stiffness_scale = spec.stiffness_scale
	sph_solver.cohesion_kernel_scale = spec.cohesion_kernel_scale
	sph_solver.collision_inflation = spec.collision_inflation
	sph_solver.foam_enabled = _foam_active()
	var basin_pour := scenario == Scenario.BASIN
	sph_solver.emitter_enabled = scenario != Scenario.POOL and not planet_mode()
	sph_solver.emitter_width = 4 if basin_pour else 6
	sph_solver.recycle_emission = not (basin_pour and mode == FluidKind.WATER_OIL)
	sph_solver.emission_cycle_seconds = spec.emission_cycle_seconds
	set_flow(flow_rate)
	sph_solver.emitter_origin = emitter_origin_for_scene(scenario)
	var launch_speed := 6.0 if basin_pour else 2.0
	sph_solver.emitter_velocity = Vector3(0.0, -launch_speed, 0.0)
	sph_solver.set_scene_obstacles(obstacles_for_scene(scenario))
	if planet_mode():
		_configure_planet_solver()
		sph_solver.viscosity_strength = 0.14 if mode != FluidKind.LAVA else 0.3
		sph_solver.cohesion_strength = 0.0
		sph_solver.extension_strength = 0.0
		return
	_radius = spec.radius
	# Tuning sliders ride the preset: a material or scene switch yields the
	# documented defaults rather than whatever the previous liquid was dialled
	# to -- the same rule viscosity and cohesion already followed. The menu
	# resyncs its widgets from the solver right after a switch.
	sph_solver.pressure_mult = SphFluidSolver.DEFAULT_PRESSURE_MULT
	sph_solver.near_pressure_mult = SphFluidSolver.DEFAULT_NEAR_PRESSURE_MULT
	sph_solver.substeps = SphFluidSolver.DEFAULT_SUBSTEPS
	# Flat tank: SebLague's spawn structure with thresholds re-fit to OUR scene.
	# His absolute windows do not transfer: his pool is ~12h deep (wave celerity
	# ~4.9 m/s) while ours is ~3.5h (celerity 2.94 m/s, so KE tops out at 8.7),
	# and our measured trapped-air distribution peaks at 32 with p99 = 10. With
	# his (15, 25)/(15, 30) and a 12 floor, the triple gate multiplies to ~zero
	# at churn — the foam famine of 2026-09-23. These values follow SPlisHSPlasH's
	# auto ramp (0.1*max..max ≈ [3, 32] here; the paper's own trapped-air ramp is
	# 5..20 and 2..8 is wave-crest) and FLIP Fluids' low energy floor
	# (|v| = 0.63): the
	# lower ramp edges sit INSIDE the measured distribution, the density gate
	# (Ihmsen 2011's surface test) keeps interior/wall spawn at zero.
	sph_solver.foam_spawn_rate = 90.0
	sph_solver.foam_spawn_fade_start = 0.2
	sph_solver.foam_spawn_fade_time = 0.35
	sph_solver.foam_trapped_min = 2.0
	sph_solver.foam_trapped_max = 12.0
	sph_solver.foam_surface_gate = 0.9
	sph_solver.foam_ke_min = 2.25
	sph_solver.foam_ke_max = 9.0
	sph_solver.foam_life_min = 5.0
	sph_solver.foam_life_max = 15.0
	sph_solver.extension_strength = spec.extension_strength
	sph_solver.viscosity_strength = spec.viscosity
	sph_solver.collision_damping = spec.collision_damping
	sph_solver.cohesion_strength = spec.cohesion


## SebLague's Earth.unity: foam render scale 4, applied as scale * 0.01 * 2, i.e.
## 0.08 world units against his smoothing radius of 0.2. The flat-world demo keeps
## the smaller sprite of his "Fluid ScreenSpace 2" scene.
func _foam_billboard_size() -> float:
	return sph_solver.h * 0.4 if planet_mode() else 0.05


func emitter_origin_for_scene(value: Scenario) -> Vector3:
	return Vector3(-2.4, 7.0, 0.0) if value == Scenario.BASIN else Vector3(-2.4, 13.6, 0.0)


func _rebuild() -> void:
	if active_solver != null:
		_initialize_runtime()


func _initialize_runtime() -> void:
	var first_start := renderer == null
	if not first_start:
		_teardown()
	active_solver.particle_count = _solver_particle_capacity()
	if scenario != Scenario.POOL and not planet_mode():
		config.texture_width = _base_texture_width
	_ensure_texture_capacity(active_solver.particle_count)
	_configure_solver()
	if first_start:
		_setup_renderer()
	renderer.set_mode(mode)
	renderer.set_radius(_radius)
	renderer.set_particle_count(active_solver.particle_count)
	renderer.set_texture_width(config.texture_width)
	renderer.set_foam_visible(_foam_active())
	active_solver.set_seed_positions(_build_seed())
	if first_start:
		RenderingServer.call_on_render_thread(_render_init.bind(active_solver))
	else:
		_queue_init()


# --- Render-thread lifecycle ----------------------------------------------

# The solver is captured at queue time: the render thread drains the queue
# later, after the main thread may have nulled or reassigned active_solver.
func _queue_init() -> void:
	# Read the generation BEFORE queueing: the render thread is parallel and may
	# run the whole init (bumping the generation) before the next main-thread
	# line executes, which would make the expected value unreachable.
	var expected: int = active_solver.init_generation + 1
	RenderingServer.call_on_render_thread(_render_init.bind(active_solver))
	_expected_init_generation = expected
	_pending_init = true


func _render_init(solver) -> void:
	solver.init_render()
	# The main thread polls this to learn the queued free+init pair has run;
	# bumping here (not in the setters) makes the signal deterministic even
	# when both execute between two main-thread frames.
	solver.init_generation += 1


func _render_free(solver) -> void:
	solver.free_render()


func _render_step(solver, dt: float) -> void:
	solver.step_render(dt)


# --- Seeding ---------------------------------------------------------------

func _build_seed() -> PackedFloat32Array:
	if planet_mode():
		# The planet starts dry: every slot is seeded (the buffers have to hold
		# something) but none is live until fluid is poured in.
		var seed := PackedFloat32Array()
		seed.resize(active_solver.particle_count * 4)
		var inner := planet_radius * 1.05
		_write_cap(seed, 0, active_solver.particle_count, spawn_axis, spawn_cap_degrees,
			inner, inner + planet_radius * spawn_height)
		_pour_cursor = 0
		sph_solver.active_count = 0
		if renderer != null:
			renderer.set_visible_count(0)
		return seed
	if scenario != Scenario.POOL:
		return _build_cascade_seed()
	sph_solver.active_count = -1
	return _build_pool_seed()



func obstacles_for_scene(value: Scenario) -> Array[Dictionary]:
	var obstacles: Array[Dictionary] = []
	if value == Scenario.CASCADE:
		_add_cascade_obstacles(obstacles)
	elif value == Scenario.BASIN:
		obstacles.append(_cascade_box(Vector3(0.0, -0.12, 0.0), Vector3(7.1, 0.36, 7.1)))
		for side in [-1.0, 1.0]:
			obstacles.append(_cascade_box(Vector3(side * 3.25, 2.9, 0.0),
				Vector3(0.6, 6.2, 7.1)))
			obstacles.append(_cascade_box(Vector3(0.0, 2.9, side * 3.25),
				Vector3(7.1, 6.2, 0.6)))
	return obstacles


func _add_cascade_obstacles(obstacles: Array[Dictionary]) -> void:
	_add_ramp(obstacles, Vector3(-2.0, 9.4, 0.0), Vector3(7.0, 0.35, 3.8), -0.30)
	_add_ramp_stop(obstacles, Vector3(-2.0, 9.4, 0.0), Vector3(7.0, 0.35, 3.8),
		-0.30, -1.0)
	_add_ramp(obstacles, Vector3(1.5, 5.0, 0.0), Vector3(8.5, 0.45, 3.8), 0.28)
	_add_ramp_stop(obstacles, Vector3(1.5, 5.0, 0.0), Vector3(8.5, 0.45, 3.8),
		0.28, 1.0)
	obstacles.append(_cascade_box(Vector3(0.0, 0.3, 0.0), Vector3(12.6, 0.6, 7.6)))
	obstacles.append(_cascade_box(Vector3(-6.0, 2.15, 0.0), Vector3(0.7, 4.7, 7.6)))
	obstacles.append(_cascade_box(Vector3(6.0, 2.15, 0.0), Vector3(0.7, 4.7, 7.6)))
	obstacles.append(_cascade_box(Vector3(0.0, 2.15, -3.5), Vector3(12.6, 4.7, 0.7)))
	obstacles.append(_cascade_box(Vector3(0.0, 2.15, 3.5), Vector3(12.6, 4.7, 0.7)))


func _add_ramp(obstacles: Array[Dictionary], center: Vector3, size: Vector3,
		angle: float) -> void:
	var basis := Basis(Vector3.BACK, angle)
	obstacles.append({transform = Transform3D(basis, center), size = size, retention = 0.985})
	for side in [-1.0, 1.0]:
		var rail_center := center + basis * Vector3(0.0, 0.48, side * (size.z * 0.5 + 0.08))
		obstacles.append({
			transform = Transform3D(basis, rail_center),
			size = Vector3(size.x, 0.8, 0.18),
			retention = 0.985,
		})


func _cascade_box(center: Vector3, size: Vector3) -> Dictionary:
	return {transform = Transform3D(Basis.IDENTITY, center), size = size, retention = 0.985}


func _add_ramp_stop(obstacles: Array[Dictionary], center: Vector3, size: Vector3,
		angle: float, side: float) -> void:
	var basis := Basis(Vector3.BACK, angle)
	var stop_center := center + basis * Vector3(side * size.x * 0.5, 0.8, 0.0)
	obstacles.append({
		transform = Transform3D(basis, stop_center),
		size = Vector3(0.35, 1.8, size.z),
		retention = 0.96,
	})


func _build_cascade_seed() -> PackedFloat32Array:
	var n: int = active_solver.particle_count
	var seed := PackedFloat32Array()
	seed.resize(n * 4)
	for i in n:
		seed[i * 4 + 3] = 1.0 if mode == FluidKind.LAVA else 0.0
	sph_solver.active_count = 0
	if renderer != null:
		renderer.set_visible_count(0)
	return seed


## Drops a blob of fluid above `point`, taking the next slice of the particle
## buffer. Slices are live from the moment they are poured, so the planet fills up
## pour by pour; once the whole buffer is live it wraps and recycles the oldest
## fluid, which is what keeps this to one buffer write and no emitter kernel.
func pour_at(point: Vector3) -> void:
	if not planet_mode() or not active_solver.initialized:
		return
	# Two blobs spawned into the same volume overlap at several times the rest
	# density, and the pressure solver answers that by firing both across the
	# system. Poured fluid needs time to fall clear before the next blob lands.
	var now := Time.get_ticks_msec()
	if now - _last_pour_ms < POUR_COOLDOWN_MS:
		return
	_last_pour_ms = now
	var n: int = active_solver.particle_count
	var count := clampi(int(float(n) * pour_fraction), 1, n)
	if _pour_cursor + count > n:
		_pour_cursor = 0
	var from := _pour_cursor
	_pour_cursor += count
	sph_solver.active_count = maxi(sph_solver.active_count, _pour_cursor)
	renderer.set_visible_count(sph_solver.live_count())
	var blob := PackedFloat32Array()
	blob.resize(count * 4)
	# Pour at the height it was aimed at, so fluid lands on the peak the crosshair
	# is over rather than inside it.
	var inner := (point - planet_centre).length()
	# Thickness follows from the particle count, so the blob always spawns at
	# roughly rest density. Fixing the shell thickness instead lets a large pour
	# spawn several times over-dense, and the pressure solver answers that by
	# firing the whole blob off the planet.
	var cap_solid_angle := TAU * (1.0 - cos(deg_to_rad(pour_cap_degrees)))
	var volume := float(count) * pow(active_solver.spacing, 3.0)
	var thickness := volume / maxf(cap_solid_angle * inner * inner, 1e-4)
	_write_cap(blob, 0, count, (point - planet_centre).normalized(), pour_cap_degrees,
		inner, inner + thickness)
	RenderingServer.call_on_render_thread(sph_solver.respawn_range.bind(from, blob))


## Fills seed[from, to) with points on a spherical cap of half-angle `half_deg`
## about `axis`, hovering above the terrain. Directions come from a Fibonacci
## sphere and radii from a t^(1/3) remap so the shell is volume-uniform, as in
## SebLague's Spawner3D. `seed` is xyzw per particle, w = material attribute
## (lava heat; 0 for materials without one).
func _write_cap(seed: PackedFloat32Array, from: int, to: int, axis: Vector3,
		half_deg: float, inner_r: float, outer_r: float) -> void:
	var count := to - from
	if count <= 0:
		return
	var dir := axis.normalized()
	var tangent := dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.UP).normalized()
	var bitangent := dir.cross(tangent)
	# Nothing may spawn outside the grid: cell_of() clamps stray positions into the
	# edge cells, and a whole spawn landing in a handful of cells turns the neighbour
	# loop quadratic and hangs the GPU.
	var box_limit := planet_field_world_size * 0.485
	var inner := minf(inner_r, box_limit)
	var outer := minf(maxf(outer_r, inner), box_limit)
	var cos_min := cos(deg_to_rad(minf(half_deg, 180.0)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var golden := PI * (3.0 - sqrt(5.0))
	for k in count:
		var t := (float(k) + 0.5) / float(count)
		# Uniform in solid angle over the cap, so a small cap is not denser at its rim.
		var cz := lerpf(1.0, cos_min, t)
		var sz := sqrt(maxf(1.0 - cz * cz, 0.0))
		var phi := golden * float(k)
		var d := dir * cz + (tangent * cos(phi) + bitangent * sin(phi)) * sz
		var r := lerpf(inner, outer, pow(rng.randf(), 1.0 / 3.0))
		var p := planet_centre + d * r
		var i := from + k
		seed[i * 4] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		seed[i * 4 + 3] = 1.0 if mode == FluidKind.LAVA else 0.0


func _build_pool_seed() -> PackedFloat32Array:
	var capacity: int = active_solver.particle_count
	var initial_count: int = particle_count * POOL_START_MULTIPLIER
	var s: float = active_solver.spacing
	var w := ceili(pow(float(initial_count), 1.0 / 3.0))
	var seed := PackedFloat32Array()
	seed.resize(capacity * 4)
	for i in initial_count:
		var x := i % w
		@warning_ignore("integer_division")
		var y := (i / w) % w
		@warning_ignore("integer_division")
		var z := i / (w * w)
		var p := seed_origin + Vector3(x, y, z) * s
		seed[i * 4] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		var phase := 1.0 if mode == FluidKind.LAVA else 0.0
		if mode == FluidKind.WATER_OIL:
			@warning_ignore("integer_division")
			phase = float((i / 216) % 2)
		seed[i * 4 + 3] = phase
	sph_solver.active_count = initial_count
	if renderer != null:
		renderer.set_visible_count(initial_count)
	return seed


# --- Per-frame -------------------------------------------------------------

func _process(delta: float) -> void:
	if active_solver == null or not active_solver.initialized:
		return
	if _pending_init:
		# A teardown+re-init pair is queued on the render thread. Until its init
		# has returned (generation observed), update() would re-bind the position
		# RID being freed. The generation bump makes the clear deterministic even
		# when free+init execute entirely between two main-thread frames.
		if active_solver.init_generation < _expected_init_generation:
			return
		_pending_init = false
	renderer.update(active_solver.get_position_tex_rid(), sph_solver.live_count(),
			sph_solver.get_foam_tex_rid())
	for i in _step_clock.advance(delta):
		RenderingServer.call_on_render_thread(_render_step.bind(active_solver, 1.0 / 60.0))


func _teardown() -> void:
	if renderer != null:
		renderer.rebind()
	var solver = active_solver
	if solver == null:
		return
	RenderingServer.call_on_render_thread(solver.free_render)


func stop() -> void:
	if active_solver == null:
		return
	_teardown()
	active_solver = null


func _exit_tree() -> void:
	stop()
