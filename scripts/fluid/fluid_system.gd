class_name FluidSystem
extends Node3D
## Reusable GPU fluid: a screen-space liquid surface driven by either a PBF or a
## dual-density SPH solver (switchable at runtime for A/B comparison), plus an
## optional white-particle (foam/spray/bubble) layer. Self-contained — instance it
## in any scene, assign a `camera`, call start(). Water/lava via `mode`. The scene
## owns the camera rig, environment and ground; this node owns the simulation and
## its surface/foam rendering.
##
## Both solvers expose the same interface (init_render/step_render/free_render/
## get_position_tex_rid/set_seed_positions/get_timings) and publish the same
## position texture (xyz = world pos, w = speed for water / temperature for lava),
## so the surface render chain is solver-agnostic. Foam is not: spawning needs the
## per-neighbour relative velocities of the SPH pressure pass, so it lives inside
## SphFluidSolver and is available in SPH water mode only.

enum Method { PBF, SPH }

const LAYER_DEPTH := 2
const LAYER_THICK := 4
const LAYER_FOAM := 8
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

var _radius := RADIUS[Method.SPH]
var pos_texture: Texture2DRD
var foam_pos_texture: Texture2DRD
var _tex_bound := false
var _foam_bound := false
var _pour_cursor := 0
var _last_pour_ms := -POUR_COOLDOWN_MS

var mm: MultiMesh
var foam_mm: MultiMesh
var foam_mmi: MultiMeshInstance3D
var depth_cam: Camera3D
var thick_cam: Camera3D
var foam_cam: Camera3D
var depth_vp: SubViewport
var thick_vp: SubViewport
var foam_vp: SubViewport
var filter_h_vp: SubViewport
var filter_v_vp: SubViewport
var depth_mat: ShaderMaterial
var thick_mat: ShaderMaterial
var filter_h_mat: ShaderMaterial
var filter_v_mat: ShaderMaterial
var composite_mat: ShaderMaterial
var foam_mat: ShaderMaterial


func active() -> Object:
	return active_solver


func _foam_active() -> bool:
	return method == Method.SPH and foam_enabled and mode < 0.5


func start() -> void:
	assert(camera != null, "FluidSystem.camera must be set before start()")
	camera.cull_mask = 0xFFFFF & ~(LAYER_DEPTH | LAYER_THICK | LAYER_FOAM)
	active_solver = sph_solver if method == Method.SPH else pbf_solver
	_radius = RADIUS[method]
	active_solver.particle_count = particle_count
	_configure_solver()
	mm = _build_multimesh()
	_setup_prepass()
	_setup_filters()
	_setup_foam_render()
	_setup_composite()
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


# --- Runtime control -------------------------------------------------------

func set_method(m: Method) -> void:
	if m == method:
		return
	_teardown()
	method = m
	active_solver = sph_solver if method == Method.SPH else pbf_solver
	_radius = RADIUS[method]
	active_solver.particle_count = particle_count
	_apply_radius()
	_configure_solver()
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func set_mode(m: float) -> void:
	mode = m
	_teardown()
	_configure_solver()
	composite_mat.set_shader_parameter("mode", mode)
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


func set_particle_count(n: int) -> void:
	if n == active_solver.particle_count:
		return
	_teardown()
	active_solver.particle_count = n
	particle_count = n
	_fill_mm(mm)
	active_solver.set_seed_positions(_build_seed())
	RenderingServer.call_on_render_thread(_render_init)


# The pool is allocated with the solver, so toggling only gates the foam stages
# and hides the billboards — no GPU resources are created or destroyed here.
func set_foam_enabled(on: bool) -> void:
	foam_enabled = on
	sph_solver.foam_enabled = _foam_active()
	if foam_mmi != null:
		foam_mmi.visible = _foam_active() and _foam_bound


## Planet mode: the composite draws after the atmosphere quad and both read the
## same pre-transparent screen copy, so the atmosphere cannot fog the water from
## outside. Feeding it the same parameters lets it scatter its own output.
func set_atmosphere(params: Dictionary) -> void:
	composite_mat.set_shader_parameter("atmosphere_enabled", not params.is_empty())
	for key in params:
		composite_mat.set_shader_parameter(key, params[key])


func set_render_scale(v: float) -> void:
	render_scale = v
	var scaled := _scaled_size()
	depth_vp.size = scaled
	thick_vp.size = _thick_size(scaled)
	filter_h_vp.size = scaled
	filter_v_vp.size = scaled
	var proj_scale := _proj_scale(scaled)
	filter_h_mat.set_shader_parameter("proj_scale", proj_scale)
	filter_v_mat.set_shader_parameter("proj_scale", proj_scale)


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
	return [depth_vp, thick_vp, filter_h_vp, filter_v_vp, foam_vp]


# --- Solver tuning ---------------------------------------------------------

func planet_mode() -> bool:
	return method == Method.SPH and planet_gravity > 0.0 and planet_field.is_valid()


func set_sky_up_axis(up: Vector3) -> void:
	composite_mat.set_shader_parameter("sky_up_axis", up)


## Draw order for the full-screen composite quad. Any other transparent full-screen
## quad reading SCREEN_TEXTURE (the planet's atmosphere) shares the same screen copy,
## so the two do not blend -- the later one overwrites the earlier. Raise this to keep
## the fluid visible alongside one.
func set_composite_priority(p: int) -> void:
	composite_mat.render_priority = p


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
		if mm != null:
			mm.visible_instance_count = 0
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
	mm.visible_instance_count = sph_solver.live_count()
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


# --- Render chain (built once) --------------------------------------------

func _build_multimesh() -> MultiMesh:
	var m := MultiMesh.new()
	m.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	m.mesh = quad
	m.custom_aabb = AABB(domain_origin, domain_size)
	_fill_mm(m)
	return m


func _fill_mm(m: MultiMesh) -> void:
	m.instance_count = active_solver.particle_count
	if planet_mode():
		m.visible_instance_count = sph_solver.live_count()
	var buf := PackedFloat32Array()
	buf.resize(active_solver.particle_count * 12)
	for i in active_solver.particle_count:
		buf[i * 12] = 1.0
		buf[i * 12 + 5] = 1.0
		buf[i * 12 + 10] = 1.0
	m.buffer = buf


func _make_prepass_cam(mask: int) -> Camera3D:
	var cam := Camera3D.new()
	cam.cull_mask = mask
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	cam.environment = env
	return cam


func _setup_prepass() -> void:
	depth_mat = ShaderMaterial.new()
	depth_mat.shader = load("res://shaders/fluid/fluid_impostor.gdshader")
	depth_mat.set_shader_parameter("tex_width", active_solver.tex_width)
	depth_mat.set_shader_parameter("particle_radius", _radius)
	thick_mat = ShaderMaterial.new()
	thick_mat.shader = load("res://shaders/fluid/fluid_thickness.gdshader")
	thick_mat.set_shader_parameter("tex_width", active_solver.tex_width)
	thick_mat.set_shader_parameter("particle_radius", _radius)

	var depth_mmi := MultiMeshInstance3D.new()
	depth_mmi.multimesh = mm
	depth_mmi.material_override = depth_mat
	depth_mmi.layers = LAYER_DEPTH
	depth_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(depth_mmi)
	var thick_mmi := MultiMeshInstance3D.new()
	thick_mmi.multimesh = mm
	thick_mmi.material_override = thick_mat
	thick_mmi.layers = LAYER_THICK
	thick_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(thick_mmi)

	var scaled := _scaled_size()
	depth_vp = SubViewport.new()
	depth_vp.size = scaled
	depth_vp.use_hdr_2d = true
	depth_vp.own_world_3d = false
	depth_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	depth_vp.positional_shadow_atlas_size = 0
	depth_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(depth_vp)
	depth_cam = _make_prepass_cam(LAYER_DEPTH)
	depth_vp.add_child(depth_cam)
	depth_cam.current = true

	thick_vp = SubViewport.new()
	thick_vp.size = _thick_size(scaled)
	thick_vp.use_hdr_2d = true
	thick_vp.own_world_3d = false
	thick_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	thick_vp.positional_shadow_atlas_size = 0
	thick_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(thick_vp)
	thick_cam = _make_prepass_cam(LAYER_THICK)
	thick_vp.add_child(thick_cam)
	thick_cam.current = true


func _make_filter_vp(vp_size: Vector2i, dir: Vector2, src: Texture2D, proj_scale: float) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = vp_size
	vp.disable_3d = true
	vp.use_hdr_2d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/fluid/fluid_depth_filter.gdshader")
	mat.set_shader_parameter("depth_tex", src)
	mat.set_shader_parameter("direction", dir)
	mat.set_shader_parameter("particle_radius", _radius)
	mat.set_shader_parameter("proj_scale", proj_scale)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)
	return vp


func _setup_filters() -> void:
	var scaled := _scaled_size()
	var proj_scale := _proj_scale(scaled)
	filter_h_vp = _make_filter_vp(scaled, Vector2(1, 0), depth_vp.get_texture(), proj_scale)
	filter_v_vp = _make_filter_vp(scaled, Vector2(0, 1), filter_h_vp.get_texture(), proj_scale)
	filter_h_mat = (filter_h_vp.get_child(0) as ColorRect).material
	filter_v_mat = (filter_v_vp.get_child(0) as ColorRect).material


func _setup_composite() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	composite_mat = ShaderMaterial.new()
	composite_mat.shader = load("res://shaders/fluid/fluid_composite.gdshader")
	composite_mat.set_shader_parameter("fluid_depth_tex", filter_v_vp.get_texture())
	composite_mat.set_shader_parameter("thickness_tex", thick_vp.get_texture())
	composite_mat.set_shader_parameter("foam_tex", foam_vp.get_texture())
	composite_mat.set_shader_parameter("mode", mode)
	quad.material = composite_mat
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	add_child(mi)


func _setup_foam_render() -> void:
	foam_mm = MultiMesh.new()
	foam_mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	foam_mm.mesh = quad
	foam_mm.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	var cap := sph_solver.foam_cap()
	foam_mm.instance_count = cap
	# A per-instance loop takes seconds at a million instances: build one identity
	# transform and double the byte pattern instead (memcpy speed).
	var one := PackedFloat32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]).to_byte_array()
	var bytes := one
	while bytes.size() < cap * 48:
		bytes.append_array(bytes.duplicate())
	bytes.resize(cap * 48)
	foam_mm.buffer = bytes.to_float32_array()

	foam_mat = ShaderMaterial.new()
	foam_mat.shader = load("res://shaders/foam/foam_billboard.gdshader")
	foam_mat.set_shader_parameter("foam_tex_width", sph_solver.foam_tex_width)
	foam_mat.set_shader_parameter("billboard_size", _foam_billboard_size())

	foam_mmi = MultiMeshInstance3D.new()
	foam_mmi.multimesh = foam_mm
	foam_mmi.material_override = foam_mat
	foam_mmi.layers = LAYER_FOAM
	foam_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	foam_mmi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	foam_mmi.visible = false
	add_child(foam_mmi)

	# Foam renders to its own coverage buffer instead of over the finished image,
	# so the composite can treat it as opaque white and occlude it correctly.
	# Hiding foam_mmi leaves this viewport clearing to black, i.e. no coverage.
	foam_vp = SubViewport.new()
	foam_vp.size = _foam_size()
	foam_vp.use_hdr_2d = true
	foam_vp.own_world_3d = false
	foam_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	foam_vp.positional_shadow_atlas_size = 0
	foam_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(foam_vp)
	foam_cam = _make_prepass_cam(LAYER_FOAM)
	foam_vp.add_child(foam_cam)
	foam_cam.current = true


# --- Sizing helpers --------------------------------------------------------

func _scaled_size() -> Vector2i:
	var s := Vector2(camera.get_viewport().size) * render_scale
	return Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))


# Foam sprites are small and high-frequency, so the coverage buffer stays at full
# resolution regardless of render_scale — at half res they magnify into squares.
func _foam_size() -> Vector2i:
	var s := Vector2(camera.get_viewport().size)
	return Vector2i(maxi(int(s.x), 1), maxi(int(s.y), 1))


# Thickness is low-frequency and sampled with filter_linear: half the prepass res.
func _thick_size(scaled: Vector2i) -> Vector2i:
	return Vector2i(maxi(scaled.x / 2, 1), maxi(scaled.y / 2, 1))


func _proj_scale(scaled: Vector2i) -> float:
	return float(scaled.y) * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)


## SebLague's Earth.unity: foam render scale 4, applied as scale * 0.01 * 2, i.e.
## 0.08 world units against his smoothing radius of 0.2. The flat-world demo keeps
## the smaller sprite of his "Fluid ScreenSpace 2" scene.
func _foam_billboard_size() -> float:
	return sph_solver.h * 0.4 if planet_mode() else 0.05


func _apply_radius() -> void:
	depth_mat.set_shader_parameter("particle_radius", _radius)
	thick_mat.set_shader_parameter("particle_radius", _radius)
	filter_h_mat.set_shader_parameter("particle_radius", _radius)
	filter_v_mat.set_shader_parameter("particle_radius", _radius)


# --- Per-frame -------------------------------------------------------------

func _sync_cams() -> void:
	for cam in [depth_cam, thick_cam, foam_cam]:
		cam.global_transform = camera.global_transform
		cam.fov = camera.fov
		cam.near = camera.near
		cam.far = camera.far


func _process(_delta: float) -> void:
	if active_solver == null or not active_solver.initialized:
		return
	if not _tex_bound:
		pos_texture = Texture2DRD.new()
		pos_texture.texture_rd_rid = active_solver.get_position_tex_rid()
		depth_mat.set_shader_parameter("position_tex", pos_texture)
		thick_mat.set_shader_parameter("position_tex", pos_texture)
		_tex_bound = true
		return
	if method == Method.SPH and not _foam_bound:
		foam_pos_texture = Texture2DRD.new()
		foam_pos_texture.texture_rd_rid = sph_solver.get_foam_tex_rid()
		foam_mat.set_shader_parameter("foam_tex", foam_pos_texture)
		_foam_bound = true
		foam_mmi.visible = _foam_active()
		return
	_sync_cams()
	RenderingServer.call_on_render_thread(_render_step.bind(1.0 / 60.0))


func _teardown() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	if foam_pos_texture != null:
		foam_pos_texture.texture_rd_rid = RID()
	_tex_bound = false
	_foam_bound = false
	if foam_mmi != null:
		foam_mmi.visible = false
	RenderingServer.call_on_render_thread(_render_free)


func _exit_tree() -> void:
	if pos_texture != null:
		pos_texture.texture_rd_rid = RID()
	if foam_pos_texture != null:
		foam_pos_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_render_free)
