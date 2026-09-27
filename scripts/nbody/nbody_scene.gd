class_name NBodySceneDef
extends RefCounted
## Interface for an N-body initial condition. Add a scene by subclassing this
## and appending it to NBodyController.SCENE_TYPES — the sim menu picks it up.


func title() -> String:
	return ""


## Solver parameters this scene needs. Called before seed(), so seed() can read
## them back from the solver instead of duplicating the values.
func apply_defaults(_solver: NBodySolver) -> void:
	pass


func normalize_params() -> void:
	pass


func supports_self_gravity() -> bool:
	return false


func default_self_gravity() -> bool:
	return false


## Tweakable fields of this scene, turned into sliders by the controller:
## [{key: String, label: String, min: float, max: float}, ...]. Changing one
## re-seeds the scene, so they are applied on slider release.
func params() -> Array:
	return []


func advanced_params() -> Array:
	return []


## Preferred initial camera distance; 0 keeps the current one.
func view_distance(_solver: NBodySolver) -> float:
	return 0.0


func view_target(_solver: NBodySolver, _sim_time: float = 0.0) -> Vector3:
	return Vector3.ZERO


## [{pos: Vector3, vel: Vector3, mass: float, radius: float}, ...], radius = absorb radius.
func attractors(_solver: NBodySolver) -> Array:
	return []


func attractor_emission(_index: int) -> Color:
	return Color.BLACK


func render_bounds(solver: NBodySolver, sources: Array) -> AABB:
	var extent := Vector3.ONE * maxf(solver.escape_radius, solver.disk_r_max)
	var local_extent := Vector3(solver.disk_r_max, solver.disk_thickness, solver.disk_r_max)
	for source: Dictionary in sources:
		var source_extent: Vector3 = source.pos.abs() + local_extent
		extent = Vector3(maxf(extent.x, source_extent.x),
			maxf(extent.y, source_extent.y), maxf(extent.z, source_extent.z))
	extent += Vector3.ONE * maxf(2.0, solver.dt * maxf(2.0 * solver.v_ref, 1.0))
	return AABB(-extent, extent * 2.0)


## Returns {positions: PackedFloat32Array, velocities: PackedFloat32Array},
## 4 floats per particle: position + mass, velocity + colour seed.
func seed(_count: int, _solver: NBodySolver, _seed_value: int = 0) -> Dictionary:
	return {}


## CPU-side attractor motion. Mutate list in place, return true if it moved.
func update_attractors(_t: float, _list: Array, _solver: NBodySolver) -> bool:
	return false


## Called every frame before the GPU step: push time-varying solver fields
## (e.g. a precessing jet axis) here.
func update_frame(_t: float, _solver: NBodySolver) -> void:
	pass
