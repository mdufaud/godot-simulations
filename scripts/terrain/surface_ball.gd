class_name SurfaceBall extends RigidBody3D
## A prop resting on the GPU heightfield. The solver's query pass samples the
## surface under the ball's five probes (centre + rim) with one frame of
## latency; this body turns the results into a spring-damper support force
## applied at the contact point (so slopes make it roll), lateral friction,
## and a roll-torque that matches the contact-point velocity. While it moves,
## the owner reads [method contact] to drag a DIG or PACK brush through the
## surface — the furrow or packed trail a ball leaves behind.

## Rim probe offsets as a fraction of the radius, xz.
const PROBE_OFFSETS := [Vector2.ZERO, Vector2(0.6, 0.0), Vector2(-0.6, 0.0),
	Vector2(0.0, 0.6), Vector2(0.0, -0.6)]
const PROBE_COUNT := 5

const GRAVITY := 9.8
const SUPPORT_SPRING := 250.0
## 2·sqrt(SUPPORT_SPRING): critically damped, so the ball settles instead of
## bouncing — the one-frame-stale query results would otherwise pump energy.
const SUPPORT_DAMPING := 31.0
const SUPPORT_FORCE_CAP := 8.0
const FRICTION := 1.0
const ROLL_GAIN := 4.0

var radius := 0.22
## TerrainBrush mode the owner applies under this ball (DIG / PACK / NONE).
var track_mode := 0

var _contact := {}


func _init(p_radius: float = 0.22, p_color: Color = Color(0.72, 0.45, 0.28)) -> void:
	radius = p_radius
	mass = 0.6 + radius * 4.0
	linear_damp = 0.05
	angular_damp = 0.05
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	add_child(shape)
	var mesh := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = radius
	sphere_mesh.height = radius * 2.0
	sphere_mesh.radial_segments = 32
	sphere_mesh.rings = 16
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p_color
	mat.roughness = 0.55
	sphere_mesh.material = mat
	mesh.mesh = sphere_mesh
	add_child(mesh)
	var phys := PhysicsMaterial.new()
	phys.bounce = 0.35
	phys.friction = 0.9
	physics_material_override = phys
	# A thrown ball must not tunnel through ball-vs-ball contacts in one tick.
	continuous_cd = true


## World xz of the five probe points, in [method query_points] order.
func query_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	var p := global_position
	for off in PROBE_OFFSETS:
		out.append(Vector2(p.x + off.x * radius, p.z + off.y * radius))
	return out


## Feed one frame of query results ([param base] is this ball's first slot).
## Returns the contact descriptor for the owner's track brush, or {} when the
## ball is airborne over invalid data.
func apply_surface(results: PackedVector4Array, base: int) -> Dictionary:
	_contact = {}
	if base + PROBE_COUNT > results.size() or results[base].w < 0.5:
		return _contact
	var centre := results[base]
	var pen := (centre.x + radius) - global_position.y
	if pen <= 0.0:
		return _contact
	pen = minf(pen, radius * 1.5)
	var n := _surface_normal(results, base)
	# Penalty contact along the surface normal: gravity is carried by the
	# spring inside the contact, damping acts both ways so the ball neither
	# bounces nor sticks. Push-only: no pulling when leaving the ground.
	var vy := linear_velocity.dot(n)
	var support := mass * (GRAVITY + SUPPORT_SPRING * pen - SUPPORT_DAMPING * vy)
	support = clampf(support, 0.0, mass * GRAVITY * SUPPORT_FORCE_CAP)
	# Applied at the contact point so an inclined normal rolls the ball.
	apply_force(n * support, Vector3(0.0, -radius, 0.0))

	var v := linear_velocity
	var v_tangent := v - n * v.dot(n)
	apply_central_force(-v_tangent * mass * FRICTION)

	# Roll to match: contact-point velocity should vanish (w = (n × v)/r).
	var omega_target := n.cross(v) / radius
	apply_torque((omega_target - angular_velocity) * mass * radius * radius * ROLL_GAIN)

	_contact = {
		pos = Vector2(global_position.x, global_position.z),
		radius = radius,
		pen = pen,
		speed = v_tangent.length(),
		score = pen * 3.0 + v_tangent.length() * 0.5,
	}
	return _contact


## The last contact descriptor written by [method apply_surface].
func contact() -> Dictionary:
	return _contact


# Least-squares plane through the four rim heights.
func _surface_normal(results: PackedVector4Array, base: int) -> Vector3:
	var d := radius * 1.2
	var slope_x := (results[base + 1].x - results[base + 2].x) / (2.0 * d)
	var slope_z := (results[base + 3].x - results[base + 4].x) / (2.0 * d)
	return Vector3(-slope_x, 1.0, -slope_z).normalized()
