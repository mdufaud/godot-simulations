class_name PlanetAtmosphere extends RefCounted
## Rayleigh atmosphere shell around a planet: owns the optical-depth LUT and the
## uniform block that describes the air.
##
## The block is published through [signal changed] rather than pushed to one
## material, because several full-screen passes may need it at once (the atmosphere
## quad, and the fluid composite when the host runs one).
##
## The host must call [method init_render] and [method bake_render] through
## [method RenderingServer.call_on_render_thread], and [method free_render] the same
## way when it leaves.
##
## [codeblock]
## var air := PlanetAtmosphere.new()
## air.changed.connect(func(p: Dictionary) -> void: material.set_shader_parameter(...))
## air.start()
## RenderingServer.call_on_render_thread(air.init_render)
## RenderingServer.call_on_render_thread(air.bake_render)
## [/codeblock]

## The parameter block was rebuilt. Carries the whole block, not a delta.
signal changed(params: Dictionary)

const LUT_STEPS := 100
const DITHER_SIZE := 64

## Shell thickness as a fraction of the planet radius.
var shell_fraction := 0.405
var density_falloff := 4.6
var scattering_strength := 20.3
## The original writes straight to an LDR target; Godot tonemaps, so the same
## radiance reads as a milky ball. A quarter of it restores the thin blue limb.
var intensity := 0.25
var wavelengths_nm := Vector3(700.0, 530.0, 460.0)
var planet_radius_m := 23.0
var sun_direction := Vector3.RIGHT
## Halves the raymarch step count. Assign before [method start].
var mobile := false

var _lut := AtmosphereLut.new()
var _params := {}


func start() -> void:
	_params["num_in_scattering_points"] = 6 if mobile else 10
	_params["dither_tex"] = _make_dither_texture()
	refresh()


## The current block, for a consumer that arrives after the last [signal changed].
func params() -> Dictionary:
	return _params


## Recomputes the derived uniforms and republishes. Call after touching any field.
func refresh() -> void:
	_params["planet_radius"] = planet_radius_m
	_params["atmosphere_radius"] = planet_radius_m * (1.0 + shell_fraction)
	_params["density_falloff"] = density_falloff
	_params["intensity"] = intensity
	_params["dir_to_sun"] = sun_direction
	# Rayleigh scattering goes as 1/wavelength^4, normalised at 400 nm.
	_params["scattering_coefficients"] = Vector3(
		pow(400.0 / wavelengths_nm.x, 4.0),
		pow(400.0 / wavelengths_nm.y, 4.0),
		pow(400.0 / wavelengths_nm.z, 4.0),
	) * scattering_strength
	changed.emit(_params)


func init_render() -> void:
	_lut.init_render()


## Rebake after a change to [member shell_fraction] or [member density_falloff]:
## the table is a function of those two alone.
func bake_render() -> void:
	_lut.bake(1.0 + shell_fraction, density_falloff, LUT_STEPS)
	_params["baked_optical_depth"] = _lut.texture
	changed.emit(_params)


func free_render() -> void:
	_lut.free_render()


## White-noise dither. The original ships a blue-noise PNG; at this amplitude the
## difference is not visible and this costs no asset.
func _make_dither_texture() -> ImageTexture:
	var image := Image.create(DITHER_SIZE, DITHER_SIZE, false, Image.FORMAT_R8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for y in DITHER_SIZE:
		for x in DITHER_SIZE:
			image.set_pixel(x, y, Color(rng.randf(), 0.0, 0.0))
	return ImageTexture.create_from_image(image)
