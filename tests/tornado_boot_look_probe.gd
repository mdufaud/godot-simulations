extends "res://tests/test_case.gd"

## Boot-parity probe: instantiates the tornado demo the way a player run does
## (no capture harness, no apply_look call) and asserts the look state
## _apply_storm_type(0) must apply at boot. The funnel/particles historically
## kept their brown shader-default dust when the boot call was missing, which
## capture-only validation masked because the harness always calls apply_look.

const GROUND_SHADER_PATH := "res://shaders/tornado/tornado_ground.gdshader"

var _frames := 0
var _demo: Node


func _initialize() -> void:
	_demo = (load("res://scenes/tornado_demo.tscn") as PackedScene).instantiate()
	root.add_child(_demo)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	_check_boot_look()
	_finish("tornado_boot_look")
	return true


func _check_boot_look() -> void:
	_check(_demo.get("storm_type") == 0,
		"boot did not leave storm_type at the Normal default")
	var funnel_mat: ShaderMaterial = _demo.get_node("Tornado/FunnelVolume").material_override
	var cloud_mat: ShaderMaterial = _demo.get_node("Tornado/CloudDeck").material_override
	var dust_mat: ShaderMaterial = _demo.get_node("Tornado/DustParticles").process_material
	var skirt_mat: ShaderMaterial = _demo.get_node("Tornado/SkirtParticles").process_material
	var ground_mesh: MeshInstance3D = _demo.get_node("Ground/MeshInstance3D")
	var ground_mat: Material = ground_mesh.material_override \
		if ground_mesh.material_override != null \
		else ground_mesh.get_surface_override_material(0)
	_check(ground_mat is ShaderMaterial
		and (ground_mat as ShaderMaterial).shader != null
		and (ground_mat as ShaderMaterial).shader.resource_path == GROUND_SHADER_PATH,
		"ground does not use %s at boot" % GROUND_SHADER_PATH)
	_check(_param(funnel_mat, "storm_type") == 0
		and _param(cloud_mat, "storm_type") == 0
		and _param(ground_mat as ShaderMaterial, "storm_type") == 0,
		"boot did not push storm_type into the funnel/cloud/ground materials")
	var storm_color: Color = _demo.get("storm_color")
	_check(_param_color(funnel_mat, "funnel_color", storm_color),
		"boot funnel_color %s does not match the storm color %s" % [
			_param(funnel_mat, "funnel_color"), storm_color])
	var deck_tone: Color = storm_color.lerp(Color(0.5, 0.52, 0.57), 0.22)
	_check(_param_color(funnel_mat, "deck_color", deck_tone),
		"boot deck_color %s does not match the derived deck tone %s" % [
			_param(funnel_mat, "deck_color"), deck_tone])
	_check(_param_color(cloud_mat, "cloud_color", deck_tone),
		"boot cloud_color %s does not match the derived deck tone %s" % [
			_param(cloud_mat, "cloud_color"), deck_tone])
	var dust_color := Color(0.46, 0.46, 0.48)
	_check(_param_color(funnel_mat, "dust_color", dust_color)
		and _param_color(cloud_mat, "dust_color", dust_color),
		"boot kept the shader-default dust color on the funnel/cloud")
	_check(_param_color(dust_mat, "particle_color", dust_color)
		and _param_color(skirt_mat, "particle_color", dust_color),
		"boot kept the shader-default particle color on the dust/skirt particles")
	_check(_param_color(ground_mat as ShaderMaterial, "ground_a", Color(0.27, 0.235, 0.19))
		and _param_color(ground_mat as ShaderMaterial, "ground_b", Color(0.185, 0.17, 0.15))
		and _param_color(ground_mat as ShaderMaterial, "ground_accent", Color(0.14, 0.135, 0.13))
		and _paramf(ground_mat as ShaderMaterial, "ground_glow", 0.0),
		"boot did not apply the Normal ground palette")
	var env: Environment = _demo.get_node("WorldEnvironment").environment
	_check(_color_near(env.background_color, Color(0.45, 0.47, 0.52))
		and _color_near(env.fog_light_color, Color(0.3, 0.32, 0.37))
		and _color_near(env.ambient_light_color, Color(0.5, 0.52, 0.57)),
		"boot did not apply the Normal environment palette")


func _param(material: Material, parameter: StringName) -> Variant:
	return (material as ShaderMaterial).get_shader_parameter(parameter)


func _param_color(material: ShaderMaterial, parameter: StringName,
		expected: Color) -> bool:
	var value: Variant = material.get_shader_parameter(parameter)
	return value is Color and _color_near(value, expected)


func _paramf(material: ShaderMaterial, parameter: StringName, expected: float) -> bool:
	var value: Variant = material.get_shader_parameter(parameter)
	return value is float and absf(value - expected) < 1.0e-4


func _color_near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 1.0e-4 and absf(a.g - b.g) < 1.0e-4 \
		and absf(a.b - b.b) < 1.0e-4 and absf(a.a - b.a) < 1.0e-4
