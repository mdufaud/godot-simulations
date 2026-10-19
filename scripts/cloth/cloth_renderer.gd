class_name ClothRenderer extends MeshInstance3D

const FABRIC_TEXTURE := preload("res://resources/generated/materials/canvas_coarse_tile.png")

var material: ShaderMaterial
var position_texture: Texture2DRD


func setup(solver: ClothSolver, preset: ClothPreset, surface_shader: Shader,
		rest_spacing: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = surface_shader
	mat.set_shader_parameter("grid_size", Vector2(solver.grid_w, solver.grid_h))
	mat.set_shader_parameter("cloth_color", preset.color)
	mat.set_shader_parameter("stripe_mix", 1.0 if preset.stripes else 0.0)
	mat.set_shader_parameter("fabric_tex", FABRIC_TEXTURE)
	material = mat
	material_override = mat
	mesh = _build_grid_mesh(solver.grid_w, solver.grid_h, rest_spacing)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	custom_aabb = AABB(Vector3(-30, -1, -30), Vector3(60, 30, 60))


func bind_texture(solver: ClothSolver) -> void:
	if position_texture != null:
		return
	position_texture = Texture2DRD.new()
	position_texture.texture_rd_rid = solver.get_position_tex_rid()
	material.set_shader_parameter("position_tex", position_texture)


func release() -> void:
	if position_texture != null:
		position_texture.texture_rd_rid = RID()
		position_texture = null


func _build_grid_mesh(w: int, h: int, rest_spacing: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(w * h)
	uvs.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			verts[i] = Vector3(x, -y, 0) * rest_spacing
			uvs[i] = Vector2(float(x) / (w - 1), float(y) / (h - 1))
	for y in h - 1:
		for x in w - 1:
			var i := y * w + x
			indices.append_array([i, i + w, i + 1, i + 1, i + w, i + w + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
