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
@export_range(4.0, 120.0, 0.1) var radius_m := 23.0
@export_range(1, 8, 1) var layer_count := 8
@export_range(1.0, 3.0, 0.01) var lacunarity := 1.48
@export_range(0.1, 0.9, 0.01) var persistence := 0.68
@export_range(0.5, 8.0, 0.01) var noise_scale := 2.86
@export_range(0.0, 6.0, 0.01) var noise_strength := 2.41
@export_range(-1.5, 1.5, 0.01) var noise_offset := -0.28
@export_range(0.0, 1.0, 0.01) var continent_strength := 0.0
@export_range(0.0, 2.0, 0.01) var mountain_strength := 1.0
@export_range(0.0, 1.0, 0.01) var warp_strength := 0.0
@export_enum("Continental", "Asteroid") var terrain_style: int = PlanetConfig.TerrainStyle.CONTINENTAL

@export_group("Interior")
@export_enum("Cavities", "Shattered shell") var opening_style: int = PlanetConfig.OpeningStyle.CAVITIES
@export_range(0.0, 1.0, 0.01) var opening_strength := 0.0
@export_range(1, 8, 1) var opening_count := 3
@export_range(0.0, 0.3, 0.01) var fragment_separation_ratio := 0.14
@export_range(0.15, 0.55, 0.01) var core_fraction := 0.32
@export_range(0.65, 0.95, 0.01) var crust_fraction := 0.82
@export_range(0.0, 8.0, 0.01) var core_emission := 3.0
@export var col_mantle := Color(0.34, 0.075, 0.025)
@export var col_core := Color(1.0, 0.34, 0.035)

@export_group("Rings")
@export var ring_enabled := false
@export_range(1.5, 2.6, 0.01) var ring_inner_ratio := 1.7
@export_range(2.8, 5.0, 0.01) var ring_outer_ratio := 2.9
@export_range(-75.0, 75.0, 1.0) var ring_tilt_deg := 25.0
@export_range(0.0, 1.0, 0.01) var ring_density := 0.7
@export_range(0.0, 1.0, 0.01) var ring_rocks := 0.7

@export_group("Satellites")
@export_range(0, 3, 1) var moon_count := 0
@export_range(3.0, 8.0, 0.01) var moon_distance_ratio := 4.6
@export_range(0.06, 0.3, 0.01) var moon_size_ratio := 0.16
@export_range(0.0, 0.25, 0.01) var moon_eccentricity := 0.1
@export_range(0.0, 3.0, 0.01) var orbit_speed := 1.0

@export_group("Volcanoes")
@export_range(0, 8, 1) var volcano_count := 0
@export_range(0.12, 0.4, 0.01) var volcano_size_ratio := 0.22
@export_range(0.05, 0.35, 0.01) var volcano_height_ratio := 0.22
@export_range(0.0, 1.0, 0.01) var volcano_activity := 1.0
@export_range(0.0, 8.0, 0.01) var lava_glow := 4.0
@export_range(0.0, 8.0, 0.1) var eruption_rate_hz := 4.0

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
	var shape := PlanetConfig.new()
	_apply_config_to(shape)
	var error := shape.validate()
	if error != "":
		return error
	if layer_count < 1 or layer_count > 8:
		return "layer_count must be between 1 and 8"
	if (lacunarity < 1.0 or lacunarity > 3.0
			or persistence < 0.1 or persistence > 0.9
			or noise_scale < 0.5 or noise_scale > 8.0
			or noise_strength < 0.0 or noise_strength > 6.0
			or noise_offset < -1.5 or noise_offset > 1.5):
		return "terrain noise parameters are invalid"
	if core_emission < 0.0 or core_emission > 8.0 or height_bands < 1.0 or height_bands > 24.0:
		return "surface parameters are invalid"
	if height_max_m <= height_min_m:
		return "height_max_m (%f) must exceed height_min_m (%f)" % [height_max_m, height_min_m]
	if wavelengths_nm.x <= 0.0 or wavelengths_nm.y <= 0.0 or wavelengths_nm.z <= 0.0:
		return "wavelengths_nm must all be positive"
	if scattering_strength < 0.0 or scattering_strength > 60.0:
		return "scattering_strength must be between 0 and 60"
	return ""


func apply_shape_to(generator: PlanetGenerator) -> void:
	generator.radius = radius_m
	generator.num_layers = layer_count
	generator.lacunarity = lacunarity
	generator.persistence = persistence
	generator.noise_scale = noise_scale
	generator.noise_strength = noise_strength
	generator.noise_offset = noise_offset
	_apply_config_to(generator.config)


func _apply_config_to(config: PlanetConfig) -> void:
	config.radius_m = radius_m
	config.max_layers = layer_count
	config.reference_radius_m = radius_m
	config.continent_strength = continent_strength
	config.mountain_strength = mountain_strength
	config.warp_strength = warp_strength
	config.terrain_style = terrain_style
	config.opening_style = opening_style
	config.opening_strength = opening_strength
	config.opening_count = opening_count
	config.fragment_separation_ratio = fragment_separation_ratio
	config.core_fraction = core_fraction
	config.crust_fraction = crust_fraction
	config.ring_enabled = ring_enabled
	config.ring_inner_ratio = ring_inner_ratio
	config.ring_outer_ratio = ring_outer_ratio
	config.ring_tilt_deg = ring_tilt_deg
	config.ring_density = ring_density
	config.ring_rocks = ring_rocks
	config.moon_count = moon_count
	config.moon_distance_ratio = moon_distance_ratio
	config.moon_size_ratio = moon_size_ratio
	config.moon_eccentricity = moon_eccentricity
	config.orbit_speed = orbit_speed
	config.volcano_count = volcano_count
	config.volcano_size_ratio = volcano_size_ratio
	config.volcano_height_ratio = volcano_height_ratio
	config.volcano_activity = volcano_activity
	config.lava_glow = lava_glow
	config.eruption_rate_hz = eruption_rate_hz


## Colours and band count only: the height range depends on the live radius, so
## the host owns it.
func apply_palette_to(material: ShaderMaterial) -> void:
	material.set_shader_parameter("col_flat", col_flat)
	material.set_shader_parameter("col_flat_deep", col_flat_deep)
	material.set_shader_parameter("col_steep", col_steep)
	material.set_shader_parameter("col_steep_deep", col_steep_deep)
	material.set_shader_parameter("col_ambient", col_ambient)
	material.set_shader_parameter("height_bands", height_bands)
	material.set_shader_parameter("col_mantle", col_mantle)
	material.set_shader_parameter("col_core", col_core)
	material.set_shader_parameter("core_emission", core_emission)
