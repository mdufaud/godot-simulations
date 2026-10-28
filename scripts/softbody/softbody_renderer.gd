class_name SoftBodyRenderer extends Node3D
## One MeshInstance3D per solver body: the shape's primitive mesh embedded in the
## body's lattice (TetLattice.embed) and moved in its vertex stage from the
## solver's position texture. Bodies sharing a lattice share one mesh. Inactive
## pool bodies stay hidden.

const SURFACE_SHADER := preload("res://shaders/softbody/softbody_surface.gdshader")
const CUSTOM_FLAGS := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
	| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
	| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)

var _instances: Array[MeshInstance3D] = []
var _material: ShaderMaterial
var _texture: Texture2DRD


func build(solver: SoftBodySolver) -> void:
	release()
	for instance in _instances:
		instance.queue_free()
	_instances.clear()
	_material = ShaderMaterial.new()
	_material.shader = SURFACE_SHADER
	_material.set_shader_parameter("texture_width", SoftBodySolver.TEXTURE_WIDTH)
	var meshes := {}
	for body in solver.body_count():
		var lattice := solver.body_lattice(body)
		if not meshes.has(lattice):
			meshes[lattice] = embedded_mesh(solver.body_shape(body), lattice)
		var instance := MeshInstance3D.new()
		instance.mesh = meshes[lattice]
		instance.material_override = _material
		instance.custom_aabb = AABB(Vector3(-50.0, -5.0, -50.0), Vector3(100.0, 60.0, 100.0))
		instance.visible = false
		add_child(instance)
		instance.set_instance_shader_parameter("vertex_offset", float(solver.body_offset(body)))
		instance.set_instance_shader_parameter("body_color", solver.body_shape(body).color)
		_instances.append(instance)


## Binds the position texture once the solver is ready; shows active bodies.
func sync(solver: SoftBodySolver) -> void:
	if _texture == null and solver.is_ready():
		_texture = Texture2DRD.new()
		_texture.texture_rd_rid = solver.position_texture_rid()
		_material.set_shader_parameter("position_tex", _texture)
	for body in _instances.size():
		_instances[body].visible = _texture != null and solver.is_body_active(body)


func is_bound() -> bool:
	return _texture != null


func release() -> void:
	if _texture != null:
		_texture.texture_rd_rid = RID()
		_texture = null
	for instance in _instances:
		instance.visible = false


static func embedded_mesh(shape: SoftBodyShape, lattice: TetLattice) -> ArrayMesh:
	var arrays := shape.make_mesh().get_mesh_arrays()
	var custom := lattice.embed(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = arrays[Mesh.ARRAY_VERTEX]
	out[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
	out[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
	out[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
	out[Mesh.ARRAY_CUSTOM0] = custom[0]
	out[Mesh.ARRAY_CUSTOM1] = custom[1]
	out[Mesh.ARRAY_CUSTOM2] = custom[2]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, CUSTOM_FLAGS)
	return mesh
