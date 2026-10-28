class_name TornadoRenderer extends RefCounted

var funnel: ShaderMaterial
var cloud: ShaderMaterial
var wind_materials: Array[ShaderMaterial] = []


## Field revision whose constant uniforms the materials hold; -1 forces a push.
var _pushed_revision := -1


func setup(funnel_material: ShaderMaterial, cloud_material: ShaderMaterial,
		particle_materials: Array[ShaderMaterial]) -> void:
	funnel = funnel_material
	cloud = cloud_material
	wind_materials = [funnel, cloud]
	wind_materials.append_array(particle_materials)
	_pushed_revision = -1


## The centerline moves every frame; everything else only changes with the field
## parameters, so it is re-sent only when the field's revision moved.
func push_wind(field: TornadoWindField) -> void:
	var centerline := field.get_shader_centerline()
	var constants_stale := _pushed_revision != field.revision
	for material in wind_materials:
		if constants_stale:
			material.set_shader_parameter("wind_model", field.model)
			material.set_shader_parameter("u_max", field.u_max)
			material.set_shader_parameter("r_core0", field.r_core0)
			material.set_shader_parameter("funnel_height", field.height)
			material.set_shader_parameter("flare", field.flare)
			material.set_shader_parameter("a_bar", field.a_bar)
			material.set_shader_parameter("swirl_sign", field.swirl_sign)
			material.set_shader_parameter("sullivan_curve", field.get_sullivan_texture())
		material.set_shader_parameter("centerline", centerline)
	_pushed_revision = field.revision
