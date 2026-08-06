class_name WallMaterials extends RefCounted
## Procedural surfaces for the demo's walls, one per [enum WallPreset.Surface].
## Fracture faces are tagged by vertex colour, so the standard materials multiply
## it in as grime and the brick shader keys on it.


static func build(surface: WallPreset.Surface) -> Material:
	match surface:
		WallPreset.Surface.BRICK:
			var mat := ShaderMaterial.new()
			mat.shader = load("res://shaders/destruction/brick_wall.gdshader")
			return mat
		WallPreset.Surface.GLASS:
			var mat := StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(0.72, 0.85, 0.88, 0.42)
			mat.roughness = 0.06
			mat.metallic = 0.1
			mat.metallic_specular = 0.8
			return mat
		WallPreset.Surface.STONE:
			return _rough_stone(Color(0.52, 0.48, 0.42), 0.03, 0.45, 0.6, 1.0)
		_:
			return _rough_stone(Color(0.68, 0.67, 0.64), 0.015, 0.6, 0.35, 0.95)


static func _rough_stone(albedo: Color, frequency: float, dark: float, uv_scale: float,
		roughness: float) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.frequency = frequency
	var ramp := Gradient.new()
	ramp.set_color(0, Color(dark, dark, dark))
	ramp.set_color(1, Color.WHITE)
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.color_ramp = ramp

	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.albedo_texture = tex
	mat.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	mat.roughness = roughness
	mat.vertex_color_use_as_albedo = true
	return mat
