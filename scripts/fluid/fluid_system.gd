class_name FluidSystem
extends Node3D
## Reusable GPU fluid: a screen-space liquid surface driven by either a PBF or a
## dual-density SPH solver (switchable at runtime for A/B comparison), plus an
## optional white-particle (foam/spray/bubble) layer. Self-contained — instance it
## in any scene, assign a `camera`, call start(). Water/lava via `mode`. The scene
## owns the camera rig, environment and ground; this node owns the simulation and
## drives a ScreenSpaceFluidRenderer for its surface/foam rendering.
##
## Both solvers expose the same interface (init_render/step_render/free_render/
## get_position_tex_rid/set_seed_positions/get_timings) and publish the same
## position texture (xyz = world pos, w = speed for water / temperature for lava),
## so the surface render chain is solver-agnostic. Foam is not: spawning needs the
## per-neighbour relative velocities of the SPH pressure pass, so it lives inside
## SphFluidSolver and is available in SPH water mode only.

enum Method { PBF, SPH }

const RADIUS := {Method.PBF: 0.12, Method.SPH: 0.16}
const POUR_COOLDOWN_MS := 400

# --- Public configuration (set before start(); use the setters afterwards). ---
var method: Method = Method.SPH
var mode := 0.0 # 0 = water, 1 = lava
var particle_count := 65536
var foam_enabled := true
var render_scale := 0.5
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

# Both solvers are kept alive so UI sliders can bind to the concrete one; only the
# active solver holds GPU resources at a time. Foam runs only in SPH water mode.
var pbf_solver := PbfFluidSolver.new()
var sph_solver := SphFluidSolver.new()
var active_solver # PbfFluidSolver | SphFluidSolver

var renderer: ScreenSpaceFluidRenderer
var _radius := RADIUS[Method.SPH]
var _pour_cursor := 0
var _last_pour_ms := -POUR_COOLDOWN_MS


func active() -> Object:
	return active_solver


func _foam_active() -> bool:
	return method == Method.SPH and foam_enabled and mode < 0.5


func start() -> void:
	assert(camera != null, "FluidSystem.camera must be set before start()")
	active_solver = sph_solver if method == Method.SPH else pbf_solver
	_radius = RADIUS[method]
	active_solver.particle_count = particle_count
	_configure_solver()
	_setup_renderer()
	renderer.set_foam_visible(_foam_active())
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func _setup_renderer() -> void:
	renderer = ScreenSpaceFluidRenderer.new()
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

func set_method(m: Method) -> void:
	if m == method:
		return
	_teardown()
	method = m
	active_solver = sph_solver if method == Method.SPH else pbf_solver
	_radius = RADIUS[method]
	active_solver.particle_count = particle_count
	renderer.set_radius(_radius)
	_configure_solver()
	renderer.set_foam_visible(_foam_active())
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func set_mode(m: float) -> void:
	mode = m
	_teardown()
	_configure_solver()
	renderer.set_mode(mode)
	renderer.set_foam_visible(_foam_active())
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func set_particle_count(n: int) -> void:
	if n == active_solver.particle_count:
		return
	_teardown()
	active_solver.particle_count = n
	particle_count = n
	renderer.set_particle_count(n)
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


# The pool is allocated with the solver, so toggling only gates the foam stages
# and hides the billboards — no GPU resources are created or destroyed here.
func set_foam_enabled(on: bool) -> void:
	foam_enabled = on
	sph_solver.foam_enabled = _foam_active()
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
	_teardown()
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func set_profiling(on: bool) -> void:
	pbf_solver.profiling = on
	sph_solver.profiling = on


func get_timings() -> Dictionary:
	return active_solver.get_timings() if active_solver != null else {}


func profiled_viewports() -> Array:
	return renderer.profiled_viewports()


# --- Solver tuning ---------------------------------------------------------

func planet_mode() -> bool:
	return method == Method.SPH and planet_gravity > 0.0 and planet_field.is_valid()


func set_sky_up_axis(up: Vector3) -> void:
	renderer.composite_material().set_shader_parameter("sky_up_axis", up)


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
	sph_solver.foam_trapped_max = 15.0
	sph_solver.foam_ke_min = 9.0
	sph_solver.foam_ke_max = 20.0
	# The impostor radius is tuned against the default spacing, so it has to follow
	# the spacing up or the surface reconstructs full of holes.
	_radius = RADIUS[Method.SPH] * (sph_solver.spacing / 0.12)
	# Keeps the MultiMesh from being frustum-culled as a whole while fluid orbits.
	domain_origin = sph_solver.grid_origin
	domain_size = Vector3.ONE * planet_field_world_size


func _configure_solver() -> void:
	pbf_solver.mode = mode
	sph_solver.mode = mode
	sph_solver.foam_enabled = _foam_active()
	if planet_mode():
		_configure_planet_solver()
		sph_solver.viscosity_strength = 0.14 if mode < 0.5 else 0.3
		return
	# Flat tank: SebLague's "Fluid ScreenSpace 2". Set explicitly rather than left to
	# the solver defaults, because the planet path above overwrites the same fields.
	sph_solver.foam_spawn_rate = 120.0
	sph_solver.foam_spawn_fade_start = 0.2
	sph_solver.foam_spawn_fade_time = 0.35
	sph_solver.foam_trapped_max = 25.0
	sph_solver.foam_ke_min = 15.0
	sph_solver.foam_ke_max = 30.0
	if mode > 0.5:
		pbf_solver.xsph_c = 0.35
		pbf_solver.vorticity_eps = 0.0
		sph_solver.viscosity_strength = 0.3
		sph_solver.collision_damping = 0.1
	else:
		pbf_solver.xsph_c = 0.05
		pbf_solver.vorticity_eps = 0.02
		sph_solver.viscosity_strength = 0.14
		sph_solver.collision_damping = 0.15


## SebLague's Earth.unity: foam render scale 4, applied as scale * 0.01 * 2, i.e.
## 0.08 world units against his smoothing radius of 0.2. The flat-world demo keeps
## the smaller sprite of his "Fluid ScreenSpace 2" scene.
func _foam_billboard_size() -> float:
	return sph_solver.h * 0.4 if planet_mode() else 0.05


# --- Render-thread lifecycle ----------------------------------------------

func _render_init() -> void:
	active_solver.init_render()


func _render_free() -> void:
	active_solver.free_render()


func _render_step(dt: float) -> void:
	active_solver.step_render(dt)


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
	return _build_dam_seed()


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
## SebLague's Spawner3D. `seed` is xyzw per particle, w = mode.
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
		seed[i * 4 + 3] = mode


func _build_dam_seed() -> PackedFloat32Array:
	var n: int = active_solver.particle_count
	var s: float = active_solver.spacing
	var w := ceili(pow(float(n), 1.0 / 3.0))
	var seed := PackedFloat32Array()
	seed.resize(n * 4)
	for i in n:
		var x := i % w
		@warning_ignore("integer_division")
		var y := (i / w) % w
		@warning_ignore("integer_division")
		var z := i / (w * w)
		var p := seed_origin + Vector3(x, y, z) * s
		seed[i * 4] = p.x
		seed[i * 4 + 1] = p.y
		seed[i * 4 + 2] = p.z
		seed[i * 4 + 3] = mode
	return seed


# --- Per-frame -------------------------------------------------------------

func _process(_delta: float) -> void:
	if active_solver == null or not active_solver.initialized:
		return
	var visible: int = sph_solver.live_count() if planet_mode() else active_solver.particle_count
	var foam_rid: RID = sph_solver.get_foam_tex_rid() if method == Method.SPH else RID()
	renderer.update(active_solver.get_position_tex_rid(), visible, foam_rid)
	RenderingServer.call_on_render_thread(_render_step.bind(1.0 / 60.0))


func _teardown() -> void:
	renderer.rebind()
	RenderingServer.call_on_render_thread(_render_free)


func _exit_tree() -> void:
	RenderingServer.call_on_render_thread(_render_free)
