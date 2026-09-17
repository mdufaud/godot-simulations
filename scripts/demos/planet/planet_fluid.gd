class_name PlanetFluid extends RefCounted
## Optional water layer for the planet demo: builds a [FluidSystem] against the
## generator's live density field, and tears it down whenever that field is about to
## be rewritten.
##
## Kept out of the controller because the planet stands on its own without it; the
## whole coupling is [member PlanetGenerator.density_texture] plus a radius.

## Nodes and objects the host owns, all asserted in [method rebuild].
var host: Node3D
var camera: Camera3D
var generator: PlanetGenerator

var enabled := false
var mobile := false
## Surface gravity. SebLague's planet works out to ~2.6 at this scale; the terrain
## is what the fluid has to negotiate, so weak gravity keeps streams readable.
var gravity := 2.6

## True once the system has been built against a generated density field.
var started := false

var _system: FluidSystem


func rebuild(atmosphere: Dictionary) -> void:
	teardown()
	if not enabled:
		return
	assert(host != null and camera != null and generator != null, "PlanetFluid: host contract unset")
	if not generator.density_texture().is_valid():
		return
	_system = FluidSystem.new()
	_system.camera = camera
	_system.method = FluidSystem.Method.SPH
	# start() resets particle_count from config.default_particle_count, so the
	# mobile budget must land in the config, not on the field alone.
	_system.config.default_particle_count = 16384 if mobile else 65536
	_system.particle_count = 16384 if mobile else 65536
	_system.foam_enabled = not mobile
	_system.planet_field = generator.density_texture()
	_system.planet_field_world_size = generator.world_size()
	_system.planet_radius = generator.radius
	_system.planet_gravity = gravity
	_system.planet_grid_dim = 96 if mobile else 144
	host.add_child(_system)
	_system.start()
	# Both the atmosphere and the fluid composite are full-screen quads reading
	# SCREEN_TEXTURE, and they share one pre-transparent copy of it -- so whichever
	# draws last paints over the other entirely. The fluid has to be last or it is
	# invisible. The cost is that the atmosphere is not applied over water, which
	# barely shows: the water sits on the surface, under the whole air column.
	_system.set_composite_priority(1)
	started = true
	apply_atmosphere(atmosphere)


## Freed immediately rather than queued: a resolution change reallocates the density
## texture on the render thread, and freeing a texture invalidates every uniform set
## that references it. queue_free() defers past that point, so the solver would keep
## dispatching against dead sets. Freeing now keeps the render-thread order
## free_render -> reallocate.
func teardown() -> void:
	if _system == null:
		return
	host.remove_child(_system)
	_system.free()
	_system = null
	started = false


func pour_at(point: Vector3) -> void:
	if started:
		_system.pour_at(point)


## The planet has no fixed up, so the sky gradient follows the viewer's radius.
func track_sky(viewer_position: Vector3) -> void:
	if started:
		_system.set_sky_up_axis(viewer_position.normalized())


func apply_atmosphere(params: Dictionary) -> void:
	if started:
		_system.set_atmosphere(params)


func set_pour_fraction(value: float) -> void:
	if started:
		_system.pour_fraction = value


func set_gravity(value: float) -> void:
	gravity = value
	if started:
		_system.sph_solver.planet_gravity = value


func set_viscosity(value: float) -> void:
	if started:
		_system.sph_solver.viscosity_strength = value


## How much tangential speed survives a hit with the terrain: the normal component is
## removed outright, so near 1 sheets across rock and low values stick.
func set_slip(value: float) -> void:
	if started:
		_system.sph_solver.collision_damping = value
