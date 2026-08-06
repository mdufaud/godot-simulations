class_name ParallaxConfig extends Resource
## Live shader state of a parallax surface, and the format of the presets in
## [code]resources/parallax/presets/[/code].
##
## A preset [code].tres[/code] only fills the surface tuning; the three view
## fields below it (render mode, self-shadowing, computed normals) stay under
## user control and are left out of [method adopt_surface].
##
## [codeblock]
## var settings: ParallaxConfig = preload("res://resources/parallax/presets/rock.tres").duplicate()
## settings.apply_to(shader_material)
## [/codeblock]

## Which procedural material [ParallaxTextureFactory] generates for this surface.
enum Surface { ROCK, BRICKS, COBBLESTONE, DUNES }

@export var display_name := "Rock"
@export var surface: Surface = Surface.ROCK

@export_group("Surface")
## Apparent depth, as a fraction of the mesh size. Tuned per preset because the
## shader scales it by [member uv_scale].
@export_range(0.005, 0.4, 0.005) var height_scale := 0.04
## Raymarch steps at grazing angles.
@export_range(4, 64, 1) var min_layer_count := 8
## Raymarch steps head-on.
@export_range(8, 128, 1) var max_layer_count := 32
## Texture repetitions across the mesh.
@export_range(0.5, 8.0, 0.1) var uv_scale := 2.0
@export_range(0.0, 2.0, 0.05) var normal_strength := 1.0
@export_range(0.0, 1.0, 0.01) var roughness := 0.8
@export_range(0.0, 2.0, 0.05) var shadow_strength := 0.8

@export_group("View")
## 0 = flat, 1 = normal map only, 2 = parallax occlusion.
@export_range(0, 2, 1) var display_mode := 2
@export var self_shadow_enabled := true
## Derive normals from the height map instead of sampling the normal map.
@export var computed_normals := false


func validate() -> String:
	if min_layer_count > max_layer_count:
		return "min_layer_count (%d) exceeds max_layer_count (%d)" % [
			min_layer_count, max_layer_count]
	if height_scale <= 0.0:
		return "height_scale must be positive"
	if uv_scale <= 0.0:
		return "uv_scale must be positive"
	return ""


## Copies the surface tuning of [param preset], keeping the view fields.
func adopt_surface(preset: ParallaxConfig) -> void:
	display_name = preset.display_name
	surface = preset.surface
	height_scale = preset.height_scale
	min_layer_count = preset.min_layer_count
	max_layer_count = preset.max_layer_count
	uv_scale = preset.uv_scale
	normal_strength = preset.normal_strength
	roughness = preset.roughness
	shadow_strength = preset.shadow_strength


func apply_to(material: ShaderMaterial) -> void:
	material.set_shader_parameter("display_mode", display_mode)
	material.set_shader_parameter("height_scale", height_scale)
	material.set_shader_parameter("min_layers", min_layer_count)
	material.set_shader_parameter("max_layers", max_layer_count)
	material.set_shader_parameter("uv_scale", uv_scale)
	material.set_shader_parameter("normal_strength", normal_strength)
	material.set_shader_parameter("roughness", roughness)
	material.set_shader_parameter("shadow_strength", shadow_strength)
	material.set_shader_parameter("self_shadow_enabled", self_shadow_enabled)
	material.set_shader_parameter("use_computed_normals", computed_normals)
