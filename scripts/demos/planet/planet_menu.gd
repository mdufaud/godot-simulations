class_name PlanetMenu extends RefCounted
## Builds the planet demo's options panel and keeps its widgets in step with the
## active preset.
##
## Registration order is load-bearing: SimMenu keys persisted values on
## "<section>/<label>" and replays them in registration order after _ready.

## Assigned by the controller before [method build].
var generator: PlanetGenerator
var surface: ShaderMaterial
var atmosphere: PlanetAtmosphere
var fluid: PlanetFluid
var orbit_cam: OrbitCamera
var atmosphere_quad: MeshInstance3D
## The controller. Must answer: apply_preset(int), queue_regen(), start_generation(),
## set_render_scale(float), set_fluid_enabled(bool), rebuild_fluid(), aim_point(),
## carry sun_yaw / sun_auto_rotate, and expose the SimQualityState named quality.
var host: Node

var _status: Label
var _sliders := {}
var _pickers := {}
## Set while a preset pushes its values into the widgets, so their callbacks do not
## write the quantised slider value back over the preset.
var _updating := false


func build(menu: SimMenu, presets: Array) -> void:
	assert(generator != null and surface != null and atmosphere != null, "PlanetMenu: contract unset")
	assert(fluid != null and orbit_cam != null and atmosphere_quad != null and host != null,
		"PlanetMenu: contract unset")

	menu.add_section("Shape")
	menu.add_option_button(
		"Preset",
		presets.map(func(p: PlanetPreset) -> String: return p.display_name),
		0,
		func(index: int) -> void:
			host.apply_preset(index)
			host.queue_regen()
	)

	_sliders["radius"] = menu.add_slider("Radius", 8.0, 30.0, generator.radius,
		func(v: float) -> void:
			if _updating:
				return
			generator.radius = v
			host.update_height_range()
			atmosphere.planet_radius_m = v
			atmosphere.refresh()
			orbit_cam.min_distance = generator.max_surface_radius() * 1.15
			host.queue_regen()
	)
	_sliders["layer_count"] = menu.add_slider("Layers", 1.0, 8.0, float(generator.num_layers),
		func(v: float) -> void:
			if _updating:
				return
			generator.num_layers = int(v)
			host.queue_regen()
	)
	_sliders["lacunarity"] = menu.add_slider("Lacunarity", 1.0, 3.0, generator.lacunarity,
		func(v: float) -> void:
			if _updating:
				return
			generator.lacunarity = v
			host.queue_regen()
	)
	_sliders["persistence"] = menu.add_slider("Persistence", 0.1, 0.9, generator.persistence,
		func(v: float) -> void:
			if _updating:
				return
			generator.persistence = v
			host.queue_regen()
	)
	_sliders["noise_scale"] = menu.add_slider("Noise scale", 0.5, 8.0, generator.noise_scale,
		func(v: float) -> void:
			if _updating:
				return
			generator.noise_scale = v
			host.queue_regen()
	)
	_sliders["noise_strength"] = menu.add_slider("Strength", 0.0, 6.0, generator.noise_strength,
		func(v: float) -> void:
			if _updating:
				return
			generator.noise_strength = v
			host.queue_regen()
	)
	_sliders["noise_offset"] = menu.add_slider("Offset", -1.5, 1.5, generator.noise_offset,
		func(v: float) -> void:
			if _updating:
				return
			generator.noise_offset = v
			host.queue_regen()
	)

	menu.add_action("🎲", "Seed", func() -> void:
		generator.noise_position_offset = Vector3(
			randf_range(-500.0, 500.0), randf_range(-500.0, 500.0), randf_range(-500.0, 500.0)
		)
		host.queue_regen()
	)

	menu.add_section("Surface")
	var first: PlanetPreset = presets[0]
	for entry in [
		["Flat high", "col_flat", first.col_flat],
		["Flat low", "col_flat_deep", first.col_flat_deep],
		["Steep high", "col_steep", first.col_steep],
		["Steep low", "col_steep_deep", first.col_steep_deep],
	]:
		var param: String = entry[1]
		_pickers[param] = menu.add_color_picker(entry[0], entry[2],
			func(color: Color) -> void:
				surface.set_shader_parameter(param, color)
		)
	_sliders["height_bands"] = menu.add_slider("Height bands", 1.0, 24.0, 5.2, func(v: float) -> void:
		surface.set_shader_parameter("height_bands", v)
	)
	menu.add_slider("Steepness", 0.0, 1.0, 0.76, func(v: float) -> void:
		surface.set_shader_parameter("flat_threshold", v)
	)
	menu.add_slider("Steep blend", 0.0, 0.4, 0.01, func(v: float) -> void:
		surface.set_shader_parameter("flat_blend", v)
	)
	menu.add_slider("Shade power", 0.5, 4.0, 1.5, func(v: float) -> void:
		surface.set_shader_parameter("shade_pow", v)
	)

	menu.add_section("Atmosphere")
	menu.add_slider("Intensity", 0.0, 2.0, atmosphere.intensity, func(v: float) -> void:
		atmosphere.intensity = v
		atmosphere.refresh()
	)
	menu.add_slider("Scattering", 0.0, 60.0, atmosphere.scattering_strength, func(v: float) -> void:
		atmosphere.scattering_strength = v
		atmosphere.refresh()
	)
	menu.add_slider("Falloff", 0.5, 12.0, atmosphere.density_falloff, func(v: float) -> void:
		atmosphere.density_falloff = v
		atmosphere.refresh()
		RenderingServer.call_on_render_thread(atmosphere.bake_render)
	)
	menu.add_slider("Thickness", 0.05, 1.0, atmosphere.shell_fraction, func(v: float) -> void:
		atmosphere.shell_fraction = v
		atmosphere.refresh()
		RenderingServer.call_on_render_thread(atmosphere.bake_render)
	)
	menu.add_slider("Red nm", 500.0, 780.0, atmosphere.wavelengths_nm.x, func(v: float) -> void:
		atmosphere.wavelengths_nm.x = v
		atmosphere.refresh()
	)
	menu.add_slider("Green nm", 450.0, 650.0, atmosphere.wavelengths_nm.y, func(v: float) -> void:
		atmosphere.wavelengths_nm.y = v
		atmosphere.refresh()
	)
	menu.add_slider("Blue nm", 380.0, 560.0, atmosphere.wavelengths_nm.z, func(v: float) -> void:
		atmosphere.wavelengths_nm.z = v
		atmosphere.refresh()
	)

	menu.add_section("Sun")
	menu.add_slider("Yaw", 0.0, 360.0, host.sun_yaw, func(v: float) -> void:
		host.sun_yaw = v
	)

	menu.add_action_toggle("☀", "Sun", false, func(on: bool) -> void:
		host.sun_auto_rotate = on
	)

	# Fluid actions are hidden until the fluid is enabled: without a solver they do nothing.
	var pour_action: Button = menu.add_action("💧", "Pour", func() -> void:
		fluid.pour_at(host.aim_point())
	)
	var reset_action: Button = menu.add_action("↺", "Reset", host.rebuild_fluid)
	pour_action.visible = false
	reset_action.visible = false
	menu.add_action_toggle("🌊", "Fluid", false, func(on: bool) -> void:
		pour_action.visible = on
		reset_action.visible = on
		host.set_fluid_enabled(on)
	)

	menu.add_debug_toggle("🌈", "Atmosphere", true, func(on: bool) -> void:
		atmosphere_quad.visible = on
	)

	menu.add_section("Fluid")
	menu.add_slider("Pour amount", 0.02, 0.5, 0.15, fluid.set_pour_fraction)
	menu.add_slider("Gravity", 0.5, 8.0, fluid.gravity, fluid.set_gravity)
	menu.add_slider("Viscosity", 0.0, 1.0, 0.14, fluid.set_viscosity)
	menu.add_slider("Slip", 0.5, 1.0, 0.999, fluid.set_slip)

	menu.add_section("Performance")
	var resolution_option := menu.add_option_button(
		"Resolution",
		PlanetQualityProfile.RESOLUTIONS.map(func(r: int) -> String: return "%d³" % r),
		PlanetQualityProfile.RESOLUTIONS.find(generator.resolution),
		func(index: int) -> void:
			generator.resolution = PlanetQualityProfile.RESOLUTIONS[index]
			host.start_generation()
	)
	host.quality.bind("resolution", resolution_option,
		func(res: int) -> void:
			generator.resolution = res
			host.start_generation(),
		func(res: int) -> int: return PlanetQualityProfile.RESOLUTIONS.find(res))
	host.quality.attach_menu_option(menu)
	var scale_slider := menu.add_slider("Render scale", 0.4, 1.0, host.render_scale,
		host.set_render_scale)
	host.quality.bind("render_scale", scale_slider, host.set_render_scale)
	var detail_slider := menu.add_slider("Surface detail", 0.0, 8.0,
		float(surface.get_shader_parameter("detail_octaves")),
		func(v: float) -> void:
			surface.set_shader_parameter("detail_octaves", int(v))
	)
	host.quality.bind("detail_octaves", detail_slider,
		func(v: float) -> void:
			surface.set_shader_parameter("detail_octaves", int(v)))
	_status = menu.add_label("Generating…")


## Drives the shape widgets from [param preset] without letting their callbacks run
## the quantised value back into the generator.
func sync_to_preset(preset: PlanetPreset) -> void:
	_updating = true
	_sliders["radius"].value = preset.radius_m
	_sliders["layer_count"].value = float(preset.layer_count)
	_sliders["lacunarity"].value = preset.lacunarity
	_sliders["persistence"].value = preset.persistence
	_sliders["noise_scale"].value = preset.noise_scale
	_sliders["noise_strength"].value = preset.noise_strength
	_sliders["noise_offset"].value = preset.noise_offset
	_sliders["height_bands"].value = preset.height_bands
	_pickers["col_flat"].color = preset.col_flat
	_pickers["col_flat_deep"].color = preset.col_flat_deep
	_pickers["col_steep"].color = preset.col_steep
	_pickers["col_steep_deep"].color = preset.col_steep_deep
	_updating = false


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text
