class_name SmokeRenderer extends MeshInstance3D
## Raymarched proxy box over a SmokeSolver grid. [method configure] sizes it to the
## config's grid, [method bind] wraps the solver textures once the solver is
## ready, [method release] drops them before the solver frees them.

const VOLUME_SHADER := preload("res://shaders/smoke/smoke_volume.gdshader")

var material := ShaderMaterial.new()
var _density_texture: Texture3DRD
var _light_texture: Texture3DRD


func configure(config: SmokeConfig) -> void:
	release()
	material.shader = VOLUME_SHADER
	material_override = material
	var extent := config.grid_extent_m()
	var box := BoxMesh.new()
	box.size = extent
	mesh = box
	position = config.domain_origin_m + extent * 0.5
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	material.set_shader_parameter("volume_extent", extent)
	material.set_shader_parameter("cell_size_m", config.cell_size_m())


func bind(solver: SmokeSolver) -> void:
	_density_texture = Texture3DRD.new()
	_density_texture.texture_rd_rid = solver.density_texture_rid()
	_light_texture = Texture3DRD.new()
	_light_texture.texture_rd_rid = solver.light_texture_rid()
	material.set_shader_parameter("density_tex", _density_texture)
	material.set_shader_parameter("light_tex", _light_texture)
	visible = true


func is_bound() -> bool:
	return _density_texture != null


func release() -> void:
	visible = false
	for texture in [_density_texture, _light_texture]:
		if texture != null:
			texture.texture_rd_rid = RID()
	_density_texture = null
	_light_texture = null
	material.set_shader_parameter("density_tex", null)
	material.set_shader_parameter("light_tex", null)


## [param sun_direction] points toward the sun.
func sync(config: SmokeConfig, sun_direction: Vector3, sun_radiance: Color,
		ambient_radiance: Color) -> void:
	material.set_shader_parameter("march_step_cells", config.march_step_cells)
	material.set_shader_parameter("extinction_per_m", config.extinction_per_m)
	material.set_shader_parameter("scattering_albedo", config.scattering_albedo)
	material.set_shader_parameter("phase_g", config.phase_g)
	material.set_shader_parameter("smoke_color", config.smoke_color)
	material.set_shader_parameter("sun_direction", sun_direction)
	material.set_shader_parameter("sun_radiance", Vector3(sun_radiance.r, sun_radiance.g, sun_radiance.b))
	material.set_shader_parameter("ambient_radiance",
		Vector3(ambient_radiance.r, ambient_radiance.g, ambient_radiance.b) * config.ambient_strength)
