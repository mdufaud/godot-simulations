extends RefCounted
## Backdrop for the grass field: a ring of far ground around the near plane,
## shaded by the same ground material, swelling into a fake steppe and rising
## into a mountain range near the horizon. Demo-only; the field itself never
## reaches it.

const INNER_RADIUS_M := 99.0
const OUTER_RADIUS_M := 17000.0
const RINGS := 110
const SECTORS := 384
# The ring overlaps the square near plane; its inner edge hangs below so the
# coarser ring never pokes through, and rejoins the true height past it.
const SKIRT_DROP_M := 1.2
const SKIRT_END_M := 150.0
const PLAIN_SWELL_M := 46.0
const MOUNTAIN_HEIGHT_M := 1500.0
const MOUNTAIN_RANGE_M := Vector2(3200.0, 11000.0)
const FOG_DENSITY := 0.00016
const CAMERA_FAR_M := 19000.0


static func build_far_ground(material: ShaderMaterial) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var growth := pow(OUTER_RADIUS_M / INNER_RADIUS_M, 1.0 / float(RINGS))
	for ring in RINGS + 1:
		var radius := INNER_RADIUS_M * pow(growth, float(ring))
		var drop := SKIRT_DROP_M * (1.0 - smoothstep(INNER_RADIUS_M, SKIRT_END_M, radius))
		for sector in SECTORS:
			var angle := TAU * float(sector) / float(SECTORS)
			vertices.append(Vector3(cos(angle) * radius, -drop, sin(angle) * radius))
			normals.append(Vector3.UP)
	for ring in RINGS:
		for sector in SECTORS:
			var next := (sector + 1) % SECTORS
			var a := ring * SECTORS + sector
			var b := ring * SECTORS + next
			var c := (ring + 1) * SECTORS + sector
			var d := (ring + 1) * SECTORS + next
			indices.append_array([a, c, b, b, c, d])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = "FarGround"
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(
		Vector3(-OUTER_RADIUS_M, -PLAIN_SWELL_M, -OUTER_RADIUS_M),
		Vector3(OUTER_RADIUS_M * 2.0, MOUNTAIN_HEIGHT_M + PLAIN_SWELL_M * 2.0, OUTER_RADIUS_M * 2.0))
	material.set_shader_parameter("plain_swell_m", PLAIN_SWELL_M)
	material.set_shader_parameter("mountain_height_m", MOUNTAIN_HEIGHT_M)
	material.set_shader_parameter("mountain_range_m", MOUNTAIN_RANGE_M)
	return instance
