class_name SandScenery extends RefCounted
## Everything the sand demo draws around the solver: the displaced sheet and its
## material, the floor, the sandbox rim, the brush marker and the dust puff.
## Built once from the domain size, then only written through.

var sand_mat: ShaderMaterial
var terrain: MeshInstance3D
var walls: Node3D
var marker: MeshInstance3D
var dust: GPUParticles3D

var _world_size := 4.0


## [param mesh_n] is the vertex grid of the displaced sheet, independent of the
## solver's cell count: grain-scale detail is the surface shader's job.
func build(host: Node3D, world_size: float, mesh_n: int) -> void:
	_world_size = world_size

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(world_size * 3.0, world_size * 3.0)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.30, 0.28, 0.26)
	gm.roughness = 1.0
	plane.material = gm
	ground.mesh = plane
	ground.position.y = -0.002
	host.add_child(ground)

	sand_mat = ShaderMaterial.new()
	sand_mat.shader = load("res://shaders/sand/sand_surface.gdshader")
	sand_mat.set_shader_parameter("world_size", world_size)
	terrain = MeshInstance3D.new()
	terrain.mesh = _build_terrain_mesh(mesh_n)
	terrain.material_override = sand_mat
	terrain.custom_aabb = AABB(
		Vector3(-world_size * 0.5, -0.1, -world_size * 0.5), Vector3(world_size, 3.0, world_size)
	)
	host.add_child(terrain)

	walls = Node3D.new()
	host.add_child(walls)
	_build_box_walls()

	marker = _build_marker()
	host.add_child(marker)

	dust = _build_dust()
	host.add_child(dust)


func set_marker_radius(radius_m: float) -> void:
	marker.scale = Vector3(radius_m, 1.0, radius_m)


## Replaces the displaced sheet's vertex grid (a quality-tier change); the
## height binding, walls and helpers stay untouched.
func rebuild_terrain(mesh_n: int) -> void:
	terrain.mesh = _build_terrain_mesh(mesh_n)


# Flat vertex grid displaced by the shader. One extra ring around the border
# sits on the domain edge with COLOR.r = 0, so its verts stay on the floor and
# the border quads become the sheet's side walls — no open underside visible.
func _build_terrain_mesh(n: int) -> ArrayMesh:
	var side := n + 2
	var verts := PackedVector3Array()
	verts.resize(side * side)
	var uvs := PackedVector2Array()
	uvs.resize(side * side)
	var colors := PackedColorArray()
	colors.resize(side * side)
	var cell := _world_size / float(n)
	for j in range(-1, n + 1):
		for i in range(-1, n + 1):
			var ci := clampi(i, 0, n - 1)
			var cj := clampi(j, 0, n - 1)
			var inner := i == ci and j == cj
			var x := (float(ci) + 0.5) * cell - _world_size * 0.5
			var z := (float(cj) + 0.5) * cell - _world_size * 0.5
			if not inner:
				x += signf(float(i - ci)) * 0.5 * cell
				z += signf(float(j - cj)) * 0.5 * cell
			var idx := (j + 1) * side + (i + 1)
			verts[idx] = Vector3(x, 0.0, z)
			uvs[idx] = Vector2((float(ci) + 0.5) / float(n), (float(cj) + 0.5) / float(n))
			colors[idx] = Color.WHITE if inner else Color.BLACK
	var quads := side - 1
	var indices := PackedInt32Array()
	indices.resize(quads * quads * 6)
	var k := 0
	for j in quads:
		for i in quads:
			var a := j * side + i
			indices[k] = a
			indices[k + 1] = a + side
			indices[k + 2] = a + side + 1
			indices[k + 3] = a
			indices[k + 4] = a + side + 1
			indices[k + 5] = a + 1
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Low sandbox rim on the domain boundary the flow already treats as a wall.
func _build_box_walls() -> void:
	var thickness := 0.1
	var height := 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.32, 0.22)
	mat.roughness = 0.95
	var half := _world_size * 0.5
	var sides := [
		[Vector3(0, height * 0.5, half + thickness * 0.5), Vector3(_world_size + thickness * 2.0, height, thickness)],
		[Vector3(0, height * 0.5, -half - thickness * 0.5), Vector3(_world_size + thickness * 2.0, height, thickness)],
		[Vector3(half + thickness * 0.5, height * 0.5, 0), Vector3(thickness, height, _world_size)],
		[Vector3(-half - thickness * 0.5, height * 0.5, 0), Vector3(thickness, height, _world_size)],
	]
	for s in sides:
		var box := BoxMesh.new()
		box.size = s[1]
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = s[0]
		walls.add_child(mi)


func _build_marker() -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.2
	cyl.radial_segments = 32
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.9, 0.45, 0.2, 0.15)
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.no_depth_test = false
	cyl.material = mm
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = 0.6
	return mi


func _build_dust() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 220
	p.lifetime = 1.1
	p.emitting = false
	p.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.2
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 0.15
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3(0, -1.2, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.4
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.85, 0.72, 0.52, 0.0))
	ramp.add_point(0.15, Color(0.85, 0.72, 0.52, 0.30))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.85, 0.72, 0.52, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.05, 0.05)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color.WHITE
	# Soft radial falloff — an untextured quad reads as a hard square.
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(0.5, 0.0)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	soft.gradient = g
	dm.albedo_texture = soft
	dm.vertex_color_use_as_albedo = true
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material = dm
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p
