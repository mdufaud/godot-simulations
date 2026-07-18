class_name NBodySceneDef
extends RefCounted
## Interface for an N-body initial condition. Add a scene by subclassing this
## and appending it to NBodyController.SCENES — the sim menu picks it up.


func title() -> String:
	return ""


## Solver parameters this scene needs. Called before seed(), so seed() can read
## them back from the solver instead of duplicating the values.
func apply_defaults(_solver: NBodySolver) -> void:
	pass


## Tweakable fields of this scene, turned into sliders by the controller:
## [{key: String, label: String, min: float, max: float}, ...]. Changing one
## re-seeds the scene, so they are applied on slider release.
func params() -> Array:
	return []


## Render tuning applied on preset switch: a dense thin ring needs far dimmer,
## smaller sprites than a puffy disk or additive blending blows out to white.
func star_size() -> float:
	return 0.09


func brightness() -> float:
	return 1.0


## Preferred initial camera distance; 0 keeps the current one.
func view_distance() -> float:
	return 0.0


## [{pos: Vector3, vel: Vector3, mass: float, radius: float}, ...], radius = absorb radius.
func attractors() -> Array:
	return []


## Returns {positions: PackedFloat32Array, velocities: PackedFloat32Array},
## 4 floats per particle: position + mass, velocity + colour seed.
func seed(_count: int, _solver: NBodySolver) -> Dictionary:
	return {}


## CPU-side attractor motion. Mutate list in place, return true if it moved.
func update_attractors(_t: float, _list: Array) -> bool:
	return false


## Called every frame before the GPU step: push time-varying solver fields
## (e.g. a precessing jet axis) here.
func update_frame(_t: float, _solver: NBodySolver) -> void:
	pass
