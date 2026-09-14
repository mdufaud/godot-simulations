extends SceneTree

## Runtime boot probe: instantiates the tornado demo the way a player run
## does (no capture harness, no apply_look call) and prints the material
## colors that were historically diverging between capture and runtime.

var _frames := 0
var _demo: Node


func _initialize() -> void:
	_demo = (load("res://scenes/tornado_demo.tscn") as PackedScene).instantiate()
	root.add_child(_demo)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	var funnel_mat: ShaderMaterial = _demo.get_node("Tornado/FunnelVolume").material_override
	var cloud_mat: ShaderMaterial = _demo.get_node("Tornado/CloudDeck").material_override
	var dust_mat: ShaderMaterial = _demo.get_node("Tornado/DustParticles").process_material
	var skirt_mat: ShaderMaterial = _demo.get_node("Tornado/SkirtParticles").process_material
	var ground_mat: ShaderMaterial = _demo.get_node("Ground/MeshInstance3D").material_override \
		if _demo.get_node("Ground/MeshInstance3D").material_override != null \
		else _demo.get_node("Ground/MeshInstance3D").get_surface_override_material(0)
	print("PROBE funnel_dust_color=", funnel_mat.get_shader_parameter("dust_color"))
	print("PROBE funnel_deck_color=", funnel_mat.get_shader_parameter("deck_color"))
	print("PROBE cloud_dust_color=", cloud_mat.get_shader_parameter("dust_color"))
	print("PROBE dust_particle_color=", dust_mat.get_shader_parameter("particle_color"))
	print("PROBE skirt_particle_color=", skirt_mat.get_shader_parameter("particle_color"))
	print("PROBE ground_shader=", ground_mat != null and ground_mat.shader != null
		and ground_mat.shader.resource_path)
	print("PROBE storm_type=", _demo.storm_type)
	print("PROBE DONE")
	return true
