extends RefCounted

const CLOUD_SHADER := preload("res://shaders/ocean/ocean_clouds.gdshader")


static func build(host: Node3D, height: float, cover: float, cloud_color: Color, set_cloud_color: bool) -> Array:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.02
	var noise_texture := NoiseTexture3D.new()
	noise_texture.noise = noise
	noise_texture.width = 128
	noise_texture.height = 128
	noise_texture.depth = 32
	noise_texture.seamless = true

	var material := ShaderMaterial.new()
	material.shader = CLOUD_SHADER
	material.set_shader_parameter("noise_tex", noise_texture)
	material.set_shader_parameter("cover", cover)
	if set_cloud_color:
		material.set_shader_parameter("cloud_color", cloud_color)

	var plane := PlaneMesh.new()
	plane.size = Vector2(10000, 10000)
	plane.subdivide_width = 48
	plane.subdivide_depth = 48
	var deck := MeshInstance3D.new()
	deck.mesh = plane
	deck.material_override = material
	deck.position = Vector3(0, height, 0)
	deck.extra_cull_margin = 2000.0
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(deck)
	return [material, deck]
