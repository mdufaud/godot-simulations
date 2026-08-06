class_name PlanetPreset extends Resource
## A whole planet: the shape the density field takes, the palette its bands are
## painted with, and the air around it.
##
## Presets live in [code]resources/planet/presets/[/code]. Terra is SebLague's
## tuned original; the others are variations on the same generator.
##
## [codeblock]
## var preset: PlanetPreset = preload("res://resources/planet/presets/terra.tres")
## preset.apply_shape_to(generator)
## preset.apply_palette_to(surface_material)
## [/codeblock]

@export var display_name := "Terra"

@export_group("Shape")
@export_range(8.0, 30.0, 0.1) var radius_m := 23.0
@export_range(1, 8, 1) var layer_count := 8
@export_range(1.0, 3.0, 0.01) var lacunarity := 1.48
@export_range(0.1, 0.9, 0.01) var persistence := 0.68
@export_range(0.5, 8.0, 0.01) var noise_scale := 2.86
@export_range(0.0, 6.0, 0.01) var noise_strength := 2.41
@export_range(-1.5, 1.5, 0.01) var noise_offset := -0.28

@export_group("Surface")
@export var col_flat := Color(0.670, 0.465, 0.281)
@export var col_flat_deep := Color(0.434, 0.180, 0.166)
@export var col_steep := Color(0.368, 0.270, 0.227)
@export var col_steep_deep := Color(0.208, 0.153, 0.179)
@export var col_ambient := Color(0.500, 0.390, 0.389)
@export_range(1.0, 24.0, 0.1) var height_bands := 5.2
## Bottom of the colour gradient, quoted at [member radius_m]; the host rescales
## both bounds when the radius slider moves, or a small planet falls entirely
## below the gradient and renders in one flat colour.
@export var height_min_m := 16.2
@export var height_max_m := 28.3

@export_group("Atmosphere")
## Rayleigh scattering is wavelength dependent, so the air colour is set by these
## three, not by a colour picker.
@export var wavelengths_nm := Vector3(700.0, 530.0, 460.0)
@export_range(0.0, 60.0, 0.1) var scattering_strength := 20.3


func validate() -> String:
	if radius_m <= 0.0:
		return "radius_m must be positive"
	if layer_count < 1:
		return "layer_count must be at least 1"
	if height_max_m <= height_min_m:
		return "height_max_m (%f) must exceed height_min_m (%f)" % [height_max_m, height_min_m]
	if wavelengths_nm.x <= 0.0 or wavelengths_nm.y <= 0.0 or wavelengths_nm.z <= 0.0:
		return "wavelengths_nm must all be positive"
	return ""


func apply_shape_to(generator: PlanetGenerator) -> void:
	generator.radius = radius_m
	generator.num_layers = layer_count
	generator.lacunarity = lacunarity
	generator.persistence = persistence
	generator.noise_scale = noise_scale
	generator.noise_strength = noise_strength
	generator.noise_offset = noise_offset


## Colours and band count only: the height range depends on the live radius, so
## the host owns it.
func apply_palette_to(material: ShaderMaterial) -> void:
	material.set_shader_parameter("col_flat", col_flat)
	material.set_shader_parameter("col_flat_deep", col_flat_deep)
	material.set_shader_parameter("col_steep", col_steep)
	material.set_shader_parameter("col_steep_deep", col_steep_deep)
	material.set_shader_parameter("col_ambient", col_ambient)
	material.set_shader_parameter("height_bands", height_bands)
