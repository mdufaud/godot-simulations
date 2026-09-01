class_name GripBall extends PortalRigidBody3D
## A portal rigid body that can be held: the grab controller freezes it
## kinematically, slides it along the view ray and commits a new size at the
## discrete events only (grab, contact, release) — never per frame on a free
## body, which would loop collisions.
##
## Size changes go through [method commit_scale], the single door that keeps
## mesh, collision sphere and mass consistent. The portal preview mesh does not
## inherit the child scale (known MVP gap, harmless while the grip room holds no
## portals).

const RADIUS_MIN := 0.2
const RADIUS_MAX := 2.0

## Mass at [member base_radius]; [method commit_scale] scales it cubically.
var base_mass := 1.0

var _base_radius := 0.0
var _mesh_child: MeshInstance3D
var _collision: CollisionShape3D


func _ready() -> void:
	super._ready()
	_mesh_child = _find_mesh(self)
	for child in get_children():
		if child is CollisionShape3D:
			_collision = child as CollisionShape3D
			break
	var shape := _collision.shape as SphereShape3D
	_base_radius = shape.radius
	base_mass = mass


## Radius the ball was built with. The committed bounds and the mass law are
## relative to it.
func base_radius() -> float:
	return _base_radius


## Current visual (and last committed) radius.
func display_radius() -> float:
	return _base_radius * _mesh_child.scale.x


func begin_hold() -> void:
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## Hands the body back to physics with explicitly zeroed velocities, so the
## drop is calm regardless of physics-server sync timing.
func end_hold() -> void:
	freeze = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false


## Kinematic hold: direct positioning is allowed, the lerp smooths the slide.
func hold_to(target: Vector3) -> void:
	global_position = global_position.lerp(target, 0.55)


## Exact kinematic placement — the size resolution must not lerp.
func place_at(target: Vector3) -> void:
	global_position = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## Mesh child only — the collision sphere follows at [method commit_scale].
func set_display_radius(radius: float) -> void:
	_mesh_child.scale = Vector3.ONE * (radius / _base_radius)


## The discrete size event: mesh, collision sphere, mass and CCD move together.
func commit_scale(radius: float) -> void:
	var committed := ApparentScale.commit_radius(radius, RADIUS_MIN, RADIUS_MAX)
	set_display_radius(committed)
	(_collision.shape as SphereShape3D).radius = committed
	mass = ApparentScale.mass_for(committed, _base_radius, base_mass)
	continuous_cd = committed > 1.0
