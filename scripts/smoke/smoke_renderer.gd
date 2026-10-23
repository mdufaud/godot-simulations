class_name SmokeRenderer extends MeshInstance3D
## Raymarched proxy box over a SmokeSolver grid. [method configure] sizes it to the
## config's grid, [method bind] wraps the solver textures once the solver is
## ready, [method release] drops them before the solver frees them.
## [member shadow_material] is a next_pass for any surface the smoke should shade
## from the sun; [method set_lights] adds omni and spot lights to the smoke.

const VOLUME_SHADER := preload("res://shaders/smoke/smoke_volume.gdshader")
const SHADOW_SHADER := preload("res://shaders/smoke/smoke_shadow.gdshader")
const JITTER_NOISE := preload("res://resources/smoke/blue_noise_64.png")
const MAX_VOLUME_LIGHTS := 4
## Texels per light row of the light table.
const LIGHT_TEXELS := 4

var material := ShaderMaterial.new()
var shadow_material := ShaderMaterial.new()
var _density_texture: Texture3DRD
var _light_texture: Texture3DRD
var _dye_texture: Texture3DRD
var _light_table := Image.create_empty(LIGHT_TEXELS, MAX_VOLUME_LIGHTS, false, Image.FORMAT_RGBAF)
var _light_table_texture := ImageTexture.create_from_image(_light_table)


func configure(config: SmokeConfig) -> void:
	release()
	material.shader = VOLUME_SHADER
	material_override = material
	shadow_material.shader = SHADOW_SHADER
	var extent := config.grid_extent_m()
	var box := BoxMesh.new()
	box.size = extent
	mesh = box
	position = config.domain_origin_m + extent * 0.5
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	material.set_shader_parameter("volume_extent", extent)
	material.set_shader_parameter("cell_size_m", config.cell_size_m())
	material.set_shader_parameter("jitter_noise", JITTER_NOISE)
	material.set_shader_parameter("light_table", _light_table_texture)
	shadow_material.set_shader_parameter("domain_origin_m", config.domain_origin_m)
	shadow_material.set_shader_parameter("domain_extent_m", extent)


func bind(solver: SmokeSolver) -> void:
	_density_texture = Texture3DRD.new()
	_density_texture.texture_rd_rid = solver.density_texture_rid()
	_light_texture = Texture3DRD.new()
	_light_texture.texture_rd_rid = solver.light_texture_rid()
	_dye_texture = Texture3DRD.new()
	_dye_texture.texture_rd_rid = solver.dye_texture_rid()
	material.set_shader_parameter("density_tex", _density_texture)
	material.set_shader_parameter("light_tex", _light_texture)
	material.set_shader_parameter("dye_tex", _dye_texture)
	shadow_material.set_shader_parameter("light_tex", _light_texture)
	visible = true


func is_bound() -> bool:
	return _density_texture != null


func release() -> void:
	visible = false
	for texture in [_density_texture, _light_texture, _dye_texture]:
		if texture != null:
			texture.texture_rd_rid = RID()
	_density_texture = null
	_light_texture = null
	_dye_texture = null
	material.set_shader_parameter("density_tex", null)
	material.set_shader_parameter("light_tex", null)
	material.set_shader_parameter("dye_tex", null)
	shadow_material.set_shader_parameter("light_tex", null)


## [param sun_direction] points toward the sun.
func sync(config: SmokeConfig, sun_direction: Vector3, sun_radiance: Color,
		ambient_radiance: Color) -> void:
	var sun := Vector3(sun_radiance.r, sun_radiance.g, sun_radiance.b)
	var ambient := Vector3(ambient_radiance.r, ambient_radiance.g, ambient_radiance.b)
	material.set_shader_parameter("march_step_cells", config.march_step_cells)
	material.set_shader_parameter("extinction_per_m", config.extinction_per_m)
	material.set_shader_parameter("scattering_albedo", config.scattering_albedo)
	material.set_shader_parameter("phase_g", config.phase_g)
	material.set_shader_parameter("smoke_color", config.smoke_color)
	material.set_shader_parameter("sun_direction", sun_direction)
	material.set_shader_parameter("sun_radiance", sun)
	material.set_shader_parameter("ambient_radiance", ambient * config.ambient_strength)
	shadow_material.set_shader_parameter("sun_direction", sun_direction)
	shadow_material.set_shader_parameter("sun_radiance", sun)
	shadow_material.set_shader_parameter("ambient_radiance", ambient)


## The first MAX_VOLUME_LIGHTS visible lights light the smoke, unshadowed inside it.
func set_lights(lights: Array[Light3D]) -> void:
	var count := 0
	for light in lights:
		if count == MAX_VOLUME_LIGHTS:
			break
		if not light.is_visible_in_tree():
			continue
		var row := pack_light(light, light.global_transform.translated(-position))
		for texel in LIGHT_TEXELS:
			_light_table.set_pixel(texel, count, row[texel])
		count += 1
	_light_table_texture.update(_light_table)
	material.set_shader_parameter("light_count", count)


## One light table row for a light placed at [param local] in the proxy's object
## space: position and range, radiance and distance decay, spot axis and cone
## cosine (-2 for an omni light), cone edge exponent.
static func pack_light(light: Light3D, local: Transform3D) -> Array[Color]:
	var at := local.origin
	var radiance := light.light_color * light.light_energy
	if light is SpotLight3D:
		var spot := light as SpotLight3D
		var axis := -local.basis.z.normalized()
		return [Color(at.x, at.y, at.z, spot.spot_range),
			Color(radiance.r, radiance.g, radiance.b, spot.spot_attenuation),
			Color(axis.x, axis.y, axis.z, cos(deg_to_rad(spot.spot_angle))),
			Color(spot.spot_angle_attenuation, 0.0, 0.0, 0.0)]
	var omni := light as OmniLight3D
	return [Color(at.x, at.y, at.z, omni.omni_range),
		Color(radiance.r, radiance.g, radiance.b, omni.omni_attenuation),
		Color(0.0, -1.0, 0.0, -2.0), Color(1.0, 0.0, 0.0, 0.0)]
