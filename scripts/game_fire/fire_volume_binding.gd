class_name FireVolumeBinding extends RefCounted
## Shared plumbing for putting the Fire-X solver's display volume on screen:
## binds the display/indirection/visual-activity textures into the sparse
## raymarcher and tracks the march proxy box that follows the resident tiles.
## Used by the hero-fire presentation and the flipbook bake tool; the fire demo
## keeps its own richer FirePresentation (half-res pass, water surface).

const FIRE_TILE_POOL := preload("res://scripts/fire/fire_tile_pool.gd")

## Wrapper textures whose RIDs the host must clear before freeing the solver.
const BOUND_PARAMETERS: Array[String] = ["volume_tex", "volume_tex_prev",
	"indir_tex", "indir_tex_prev", "visual_activity_tex",
	"visual_activity_tex_prev"]


static func bind(material: ShaderMaterial, solver: FireGpuSolver) -> void:
	material.set_shader_parameter("cell_size", solver.cell_size)
	material.set_shader_parameter("atlas_cells", Vector3(FIRE_TILE_POOL.ATLAS_CELLS))
	material.set_shader_parameter("atlas_tiles", FIRE_TILE_POOL.ATLAS_TILES)
	material.set_shader_parameter("virtual_tiles", FIRE_TILE_POOL.VTILES)
	# The march runs in VIRTUAL cell coordinates over the whole sparse domain,
	# so the origin is half the virtual map — not the dense pin region.
	var virtual_size := Vector3(solver.sim_dims()) * solver.cell_size
	material.set_shader_parameter("virtual_origin",
		Vector3(-virtual_size.x * 0.5, 0.0, -virtual_size.z * 0.5))
	material.set_shader_parameter("blue_height", solver.dense_domain_size_m().y)
	material.set_shader_parameter("ambient_temperature", solver.ambient_temperature)
	material.set_shader_parameter("display_temperature", solver.display_temperature)
	var bindings := {
		"volume_tex": solver.get_display_tex_rid(),
		"volume_tex_prev": solver.get_previous_display_tex_rid(),
		"indir_tex": solver.indirection_bytes_rid(),
		"indir_tex_prev": solver.previous_indirection_bytes_rid(),
		"visual_activity_tex": solver.get_visual_activity_tex_rid(),
		"visual_activity_tex_prev": solver.get_previous_visual_activity_tex_rid(),
	}
	for parameter in bindings:
		var wrapper := Texture3DRD.new()
		wrapper.texture_rd_rid = bindings[parameter]
		material.set_shader_parameter(parameter, wrapper)


static func unbind(material: ShaderMaterial) -> void:
	for parameter in BOUND_PARAMETERS:
		var wrapper: Texture3DRD = material.get_shader_parameter(parameter)
		if wrapper != null:
			wrapper.texture_rd_rid = RID()


## Mirror FirePresentation's proxy tracking: resize the march box so rays stop
## where nothing is resident.
static func track_proxy(material: ShaderMaterial, volume_node: MeshInstance3D,
		box: BoxMesh, solver: FireGpuSolver) -> void:
	var proxy := solver.display_clip_box()
	var extent := proxy.size
	if extent.x <= 0.0 or extent.y <= 0.0 or extent.z <= 0.0:
		return
	box.size = extent
	volume_node.position = proxy.position + extent * 0.5
	material.set_shader_parameter("box_size", extent)
	material.set_shader_parameter("volume_origin", proxy.position)
	material.set_shader_parameter("volume_extent", extent)
