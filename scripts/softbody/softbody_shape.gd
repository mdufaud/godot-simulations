class_name SoftBodyShape extends Resource
## One soft body: its analytic shape (the lattice fills its SDF), stiffness,
## friction, colour and rest pose.

enum Kind { BOX, SPHERE, CAPSULE, TORUS }

@export var kind: Kind = Kind.BOX
## BOX: full size. SPHERE: x = radius. CAPSULE: x = radius, y = full height.
## TORUS: x = ring radius, y = tube radius; the ring lies in the XZ plane.
@export var size_m := Vector3(0.5, 0.5, 0.5)
@export var position_m := Vector3(0.0, 1.0, 0.0)
@export var rotation_deg := Vector3.ZERO
@export_range(1000.0, 10000000.0, 1.0, "exp") var youngs_modulus_pa := 50000.0
@export_range(0.0, 2.0, 0.01) var friction := 0.6
@export var color := Color(0.85, 0.2, 0.3)


func validate() -> String:
	match kind:
		Kind.BOX:
			if size_m.x <= 0.0 or size_m.y <= 0.0 or size_m.z <= 0.0:
				return "box size must be positive"
		Kind.SPHERE:
			if size_m.x <= 0.0:
				return "sphere radius must be positive"
		Kind.CAPSULE:
			if size_m.x <= 0.0 or size_m.y < 2.0 * size_m.x:
				return "capsule needs a positive radius and a height of at least two radii"
		Kind.TORUS:
			if size_m.y <= 0.0 or size_m.x <= size_m.y:
				return "torus ring radius must exceed its positive tube radius"
	if youngs_modulus_pa <= 0.0 or friction < 0.0:
		return "youngs_modulus_pa must be positive and friction not negative"
	return ""


## Half size of the local bounding box.
func extent_m() -> Vector3:
	match kind:
		Kind.SPHERE:
			return Vector3.ONE * size_m.x
		Kind.CAPSULE:
			return Vector3(size_m.x, size_m.y * 0.5, size_m.x)
		Kind.TORUS:
			return Vector3(size_m.x + size_m.y, size_m.y, size_m.x + size_m.y)
	return size_m * 0.5


## Signed distance in the local frame, negative inside.
func sdf(p: Vector3) -> float:
	match kind:
		Kind.SPHERE:
			return p.length() - size_m.x
		Kind.CAPSULE:
			var half := size_m.y * 0.5 - size_m.x
			return Vector3(p.x, p.y - clampf(p.y, -half, half), p.z).length() - size_m.x
		Kind.TORUS:
			return Vector2(Vector2(p.x, p.z).length() - size_m.x, p.y).length() - size_m.y
	var q := p.abs() - size_m * 0.5
	return q.max(Vector3.ZERO).length() + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


func analytic_volume_m3() -> float:
	match kind:
		Kind.SPHERE:
			return 4.0 / 3.0 * PI * pow(size_m.x, 3.0)
		Kind.CAPSULE:
			var r := size_m.x
			return PI * r * r * (size_m.y - 2.0 * r) + 4.0 / 3.0 * PI * r * r * r
		Kind.TORUS:
			return 2.0 * PI * PI * size_m.x * size_m.y * size_m.y
	return size_m.x * size_m.y * size_m.z


func rest_transform() -> Transform3D:
	var euler := Vector3(deg_to_rad(rotation_deg.x), deg_to_rad(rotation_deg.y),
		deg_to_rad(rotation_deg.z))
	return Transform3D(Basis.from_euler(euler), position_m)


## Render surface, embedded in the lattice.
func make_mesh() -> PrimitiveMesh:
	match kind:
		Kind.SPHERE:
			var sphere := SphereMesh.new()
			sphere.radius = size_m.x
			sphere.height = size_m.x * 2.0
			sphere.radial_segments = 48
			sphere.rings = 24
			return sphere
		Kind.CAPSULE:
			var capsule := CapsuleMesh.new()
			capsule.radius = size_m.x
			capsule.height = size_m.y
			capsule.radial_segments = 40
			capsule.rings = 12
			return capsule
		Kind.TORUS:
			var torus := TorusMesh.new()
			torus.inner_radius = size_m.x - size_m.y
			torus.outer_radius = size_m.x + size_m.y
			torus.rings = 48
			torus.ring_segments = 20
			return torus
	var box := BoxMesh.new()
	box.size = size_m
	box.subdivide_width = 12
	box.subdivide_height = 12
	box.subdivide_depth = 12
	return box
