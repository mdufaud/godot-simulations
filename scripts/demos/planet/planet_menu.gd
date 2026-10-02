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
var _options := {}
var _toggles := {}
var _preset_option: OptionButton
var _sun_action: Button
var _pour_action: Button
var _reset_action: Button
## Set while a preset pushes its values into the widgets, so their callbacks do not
## write the quantised slider value back over the preset.
var _updating := false


func build(menu: SimMenu, presets: Array) -> void:
	assert(generator != null and surface != null and atmosphere != null, "PlanetMenu: contract unset")
	assert(fluid != null and orbit_cam != null and atmosphere_quad != null and host != null,
		"PlanetMenu: contract unset")

	menu.add_section("Shape")
	_preset_option = menu.add_option_button(
		"Preset",
		presets.map(func(p: PlanetPreset) -> String: return p.display_name),
		0,
		func(index: int) -> void:
			host.apply_preset(index)
	)

	_sliders["radius"] = menu.add_slider("Radius", 4.0, 120.0, generator.radius,
		func(v: float) -> void:
			if _updating:
				return
			generator.radius = v
			host.queue_regen()
	, false, 0.1)
	_sliders["noise_strength"] = _shape_slider(menu, "Relief", 0.0, 6.0, generator.noise_strength,
		func(v: float) -> void: generator.noise_strength = v)
	generator.config.seed = clampi(int(menu.stored_value("Shape", "Seed", 0)), 0, 999999)
	_sliders["seed"] = menu.add_slider("Seed", 0.0, 999999.0, generator.config.seed,
		func(v: float) -> void:
			generator.config.seed = int(v)
			host.queue_regen()
	, true, 1.0)
	menu.add_action("🎲", "Seed", func() -> void:
		_sliders["seed"].value = randi_range(1, 999999)
	)

	menu.add_section("Terrain detail")
	_options["terrain_style"] = menu.add_option_button("Terrain", ["Continental", "Asteroid"],
		generator.config.terrain_style, func(index: int) -> void:
			if _updating:
				return
			generator.config.terrain_style = index
			host.queue_regen()
	)
	_sliders["continent_strength"] = _shape_slider(menu, "Continents", 0.0, 1.0,
		generator.config.continent_strength, func(v: float) -> void: generator.config.continent_strength = v)
	_sliders["mountain_strength"] = _shape_slider(menu, "Mountains", 0.0, 2.0,
		generator.config.mountain_strength, func(v: float) -> void: generator.config.mountain_strength = v)
	_sliders["warp_strength"] = _shape_slider(menu, "Warp", 0.0, 1.0,
		generator.config.warp_strength, func(v: float) -> void: generator.config.warp_strength = v)
	_sliders["layer_count"] = menu.add_slider("Layers", 1.0, 8.0, float(generator.num_layers),
		func(v: float) -> void:
			if _updating:
				return
			generator.num_layers = int(v)
			host.queue_regen()
	, false, 1.0)
	_sliders["lacunarity"] = menu.add_slider("Lacunarity", 1.0, 3.0, generator.lacunarity,
		func(v: float) -> void:
			if _updating:
				return
			generator.lacunarity = v
			host.queue_regen()
	, false, 0.01)
	_sliders["persistence"] = menu.add_slider("Persistence", 0.1, 0.9, generator.persistence,
		func(v: float) -> void:
			if _updating:
				return
			generator.persistence = v
			host.queue_regen()
	, false, 0.01)
	_sliders["noise_scale"] = menu.add_slider("Noise scale", 0.5, 8.0, generator.noise_scale,
		func(v: float) -> void:
			if _updating:
				return
			generator.noise_scale = v
			host.queue_regen()
	, false, 0.01)
	_sliders["noise_offset"] = menu.add_slider("Offset", -1.5, 1.5, generator.noise_offset,
		func(v: float) -> void:
			if _updating:
				return
			generator.noise_offset = v
			host.queue_regen()
	, false, 0.01)

	menu.add_section("Interior")
	_options["opening_style"] = menu.add_option_button("Structure", ["Cavities", "Shattered shell"],
		generator.config.opening_style, func(index: int) -> void:
			if _updating:
				return
			generator.config.opening_style = index
			var minimum := 3.0 if index == PlanetConfig.OpeningStyle.SHATTERED_SHELL else 1.0
			var opening_count: int = maxi(generator.config.opening_count, int(minimum))
			_updating = true
			_sliders["opening_count"].min_value = minimum
			_sliders["opening_count"].value = float(opening_count)
			var count_label: Label = _sliders["opening_count"].get_parent().get_child(0)
			count_label.text = "Regions" if index == PlanetConfig.OpeningStyle.SHATTERED_SHELL else "Openings"
			generator.config.opening_count = opening_count
			_updating = false
			host.update_interior()
			host.queue_regen()
	)
	_sliders["opening_strength"] = _shape_slider(menu, "Opening", 0.0, 1.0,
		generator.config.opening_strength, func(v: float) -> void: generator.config.opening_strength = v)
	_sliders["core_fraction"] = _shape_slider(menu, "Core size", 0.15, 0.55,
		generator.config.core_fraction, func(v: float) -> void: generator.config.core_fraction = v)
	_sliders["opening_count"] = _shape_slider(menu, "Openings", 1.0, 8.0,
		generator.config.opening_count, func(v: float) -> void: generator.config.opening_count = int(v), 1.0)
	_sliders["fragment_separation_ratio"] = _shape_slider(menu, "Fragment separation", 0.0, 0.3,
		generator.config.fragment_separation_ratio,
		func(v: float) -> void: generator.config.fragment_separation_ratio = v)
	_sliders["crust_fraction"] = _shape_slider(menu, "Crust boundary", 0.65, 0.95,
		generator.config.crust_fraction, func(v: float) -> void: generator.config.crust_fraction = v)
	_sliders["core_emission"] = menu.add_slider("Core glow", 0.0, 8.0, host.core_emission,
		func(v: float) -> void:
			if _updating:
				return
			host.core_emission = v
			host.update_interior()
	, false, 0.01)

	menu.add_section("Rings")
	_toggles["ring_enabled"] = menu.add_toggle("Enabled", generator.config.ring_enabled,
		func(on: bool) -> void:
			if _updating:
				return
			generator.config.ring_enabled = on
			host.update_orbits()
	, false)
	_sliders["ring_inner_ratio"] = _orbit_slider(menu, "Inner radius / planet", 1.5, 2.6,
		generator.config.ring_inner_ratio, func(v: float) -> void: generator.config.ring_inner_ratio = v)
	_sliders["ring_outer_ratio"] = _orbit_slider(menu, "Outer radius / planet", 2.8, 5.0,
		generator.config.ring_outer_ratio, func(v: float) -> void: generator.config.ring_outer_ratio = v)
	_sliders["ring_tilt_deg"] = _orbit_slider(menu, "Tilt", -75.0, 75.0,
		generator.config.ring_tilt_deg, func(v: float) -> void: generator.config.ring_tilt_deg = v, 1.0)
	_sliders["ring_density"] = _orbit_slider(menu, "Dust", 0.0, 1.0,
		generator.config.ring_density, func(v: float) -> void: generator.config.ring_density = v)
	_sliders["ring_rocks"] = _orbit_slider(menu, "Rocks", 0.0, 1.0,
		generator.config.ring_rocks, func(v: float) -> void: generator.config.ring_rocks = v)

	menu.add_section("Satellites")
	_sliders["moon_count"] = _orbit_slider(menu, "Count", 0.0, 3.0,
		generator.config.moon_count, func(v: float) -> void: generator.config.moon_count = int(v), 1.0)
	_sliders["moon_distance_ratio"] = _orbit_slider(menu, "Orbit radius / planet", 3.0, 8.0,
		generator.config.moon_distance_ratio, func(v: float) -> void: generator.config.moon_distance_ratio = v)
	_sliders["moon_size_ratio"] = _orbit_slider(menu, "Moon radius / planet", 0.06, 0.3,
		generator.config.moon_size_ratio, func(v: float) -> void: generator.config.moon_size_ratio = v)
	_sliders["moon_eccentricity"] = _orbit_slider(menu, "Eccentricity", 0.0, 0.25,
		generator.config.moon_eccentricity, func(v: float) -> void: generator.config.moon_eccentricity = v)
	_sliders["orbit_speed"] = _orbit_slider(menu, "Orbit speed", 0.0, 3.0,
		generator.config.orbit_speed, func(v: float) -> void: generator.config.orbit_speed = v)

	menu.add_section("Volcanoes")
	_sliders["volcano_count"] = _shape_slider(menu, "Count", 0.0, 8.0,
		generator.config.volcano_count, func(v: float) -> void: generator.config.volcano_count = int(v), 1.0)
	_sliders["volcano_size_ratio"] = _shape_slider(menu, "Width / planet", 0.12, 0.4,
		generator.config.volcano_size_ratio, func(v: float) -> void: generator.config.volcano_size_ratio = v)
	_sliders["volcano_height_ratio"] = _shape_slider(menu, "Height / planet", 0.05, 0.35,
		generator.config.volcano_height_ratio, func(v: float) -> void: generator.config.volcano_height_ratio = v)
	_sliders["volcano_activity"] = _volcano_slider(menu, "Activity", 0.0, 1.0,
		generator.config.volcano_activity, func(v: float) -> void: generator.config.volcano_activity = v)
	_sliders["lava_glow"] = _volcano_slider(menu, "Lava glow", 0.0, 8.0,
		generator.config.lava_glow, func(v: float) -> void: generator.config.lava_glow = v)
	_sliders["eruption_rate_hz"] = _volcano_slider(menu, "Fragments/s per vent", 0.0, 8.0,
		generator.config.eruption_rate_hz, func(v: float) -> void: generator.config.eruption_rate_hz = v, 0.1)

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
		, false)
	_sliders["height_bands"] = menu.add_slider("Height bands", 1.0, 24.0, 5.2, func(v: float) -> void:
		if _updating:
			return
		surface.set_shader_parameter("height_bands", v)
	, false, 0.1)
	menu.add_slider("Steepness", 0.0, 1.0, 0.76, func(v: float) -> void:
		surface.set_shader_parameter("flat_threshold", v)
	)
	menu.add_slider("Steep blend", 0.0, 0.4, 0.01, func(v: float) -> void:
		surface.set_shader_parameter("flat_blend", v)
	, true, 0.001)
	menu.add_slider("Shade power", 0.5, 4.0, 1.5, func(v: float) -> void:
		surface.set_shader_parameter("shade_pow", v)
	, true, 0.01)

	menu.add_section("Atmosphere")
	menu.add_slider("Intensity", 0.0, 2.0, atmosphere.intensity, func(v: float) -> void:
		atmosphere.intensity = v
		atmosphere.refresh()
	, true, 0.01)
	_sliders["scattering"] = menu.add_slider("Scattering", 0.0, 60.0, atmosphere.scattering_strength, func(v: float) -> void:
		if _updating:
			return
		atmosphere.scattering_strength = v
		atmosphere.refresh()
	, false, 0.1)
	menu.add_slider("Falloff", 0.5, 12.0, atmosphere.density_falloff, func(v: float) -> void:
		atmosphere.density_falloff = v
		atmosphere.refresh()
		RenderingServer.call_on_render_thread(atmosphere.bake_render)
	, true, 0.01)
	menu.add_slider("Thickness", 0.05, 1.0, atmosphere.shell_fraction, func(v: float) -> void:
		atmosphere.shell_fraction = v
		atmosphere.refresh()
		RenderingServer.call_on_render_thread(atmosphere.bake_render)
	, true, 0.001)
	_sliders["red_nm"] = menu.add_slider("Red nm", 500.0, 780.0, atmosphere.wavelengths_nm.x, func(v: float) -> void:
		if _updating:
			return
		atmosphere.wavelengths_nm.x = v
		atmosphere.refresh()
	, false, 1.0)
	_sliders["green_nm"] = menu.add_slider("Green nm", 450.0, 650.0, atmosphere.wavelengths_nm.y, func(v: float) -> void:
		if _updating:
			return
		atmosphere.wavelengths_nm.y = v
		atmosphere.refresh()
	, false, 1.0)
	_sliders["blue_nm"] = menu.add_slider("Blue nm", 380.0, 560.0, atmosphere.wavelengths_nm.z, func(v: float) -> void:
		if _updating:
			return
		atmosphere.wavelengths_nm.z = v
		atmosphere.refresh()
	, false, 1.0)

	menu.add_section("Sun")
	_sliders["sun_yaw"] = menu.add_slider("Yaw", 0.0, 360.0, host.sun_yaw, func(v: float) -> void:
		if _updating:
			return
		host.sun_yaw = v
		host.sun_auto_rotate = false
		_sun_action.set_pressed_no_signal(false)
	, false, 0.1)

	_sun_action = menu.add_action_toggle("☀", "Sun", false, func(on: bool) -> void:
		host.sun_auto_rotate = on
	)

	# Fluid actions are hidden until the fluid is enabled: without a solver they do nothing.
	_pour_action = menu.add_action("💧", "Pour", func() -> void:
		fluid.pour_at(host.aim_point())
	)
	_reset_action = menu.add_action("↺", "Reset", fluid.reset)
	_pour_action.visible = false
	_reset_action.visible = false
	menu.add_action_toggle("🌊", "Fluid", false, func(on: bool) -> void:
		_pour_action.visible = on
		_reset_action.visible = on
		host.set_fluid_enabled(on)
	)

	menu.add_debug_toggle("🌈", "Atmosphere", true, func(on: bool) -> void:
		atmosphere_quad.visible = on
		fluid.atmosphere_enabled = on
		fluid.apply_atmosphere(atmosphere.params())
	)

	menu.add_section("Fluid")
	menu.add_slider("Pour amount", 0.02, FluidSystem.PLANET_MAX_POUR_FRACTION,
		fluid.pour_fraction, fluid.set_pour_fraction, true, 0.01)
	menu.add_slider("Gravity", 0.5, 8.0, fluid.gravity, fluid.set_gravity, true, 0.01)
	menu.add_slider("Viscosity", 0.0, 1.0, fluid.viscosity, fluid.set_viscosity, true, 0.01)
	menu.add_slider("Slip", 0.5, 1.0, fluid.slip, fluid.set_slip, true, 0.001)

	menu.add_section("Performance")
	var resolution_option := menu.add_option_button(
		"Resolution",
		PlanetQualityProfile.RESOLUTIONS.map(func(r: int) -> String: return "%d³" % r),
		PlanetQualityProfile.RESOLUTIONS.find(generator.resolution),
		func(index: int) -> void:
			generator.resolution = PlanetQualityProfile.RESOLUTIONS[index]
			host.queue_regen()
	)
	host.quality.bind("resolution", resolution_option,
		func(res: int) -> void:
			generator.resolution = res
			host.queue_regen(),
		func(res: int) -> int: return PlanetQualityProfile.RESOLUTIONS.find(res))
	host.quality.attach_menu_option(menu)
	menu.add_slider("Render scale", 0.4, 1.0, host.render_scale,
		host.set_render_scale, true, 0.01)
	var detail_slider := menu.add_slider("Surface detail", 0.0, 8.0,
		float(surface.get_shader_parameter("detail_octaves")),
		func(v: float) -> void:
			surface.set_shader_parameter("detail_octaves", int(v))
	, true, 1.0)
	host.quality.bind("detail_octaves", detail_slider,
		func(v: float) -> void:
			surface.set_shader_parameter("detail_octaves", int(v)))
	_status = menu.add_label("Generating…")


## Drives the shape widgets from [param preset] without letting their callbacks run
## the quantised value back into the generator.
func sync_to_preset(preset: PlanetPreset, index: int) -> void:
	_updating = true
	_preset_option.select(index)
	_sliders["radius"].value = preset.radius_m
	_sliders["layer_count"].value = float(preset.layer_count)
	_sliders["lacunarity"].value = preset.lacunarity
	_sliders["persistence"].value = preset.persistence
	_sliders["noise_scale"].value = preset.noise_scale
	_sliders["noise_strength"].value = preset.noise_strength
	_sliders["noise_offset"].value = preset.noise_offset
	_options["terrain_style"].select(preset.terrain_style)
	_sliders["continent_strength"].value = preset.continent_strength
	_sliders["mountain_strength"].value = preset.mountain_strength
	_sliders["warp_strength"].value = preset.warp_strength
	_options["opening_style"].select(preset.opening_style)
	_sliders["opening_count"].min_value = 3.0 if preset.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL else 1.0
	var count_label: Label = _sliders["opening_count"].get_parent().get_child(0)
	count_label.text = "Regions" if preset.opening_style == PlanetConfig.OpeningStyle.SHATTERED_SHELL else "Openings"
	_sliders["opening_strength"].value = preset.opening_strength
	_sliders["opening_count"].value = preset.opening_count
	_sliders["fragment_separation_ratio"].value = preset.fragment_separation_ratio
	_sliders["core_fraction"].value = preset.core_fraction
	_sliders["crust_fraction"].value = preset.crust_fraction
	_sliders["core_emission"].value = preset.core_emission
	_toggles["ring_enabled"].set_pressed_no_signal(preset.ring_enabled)
	for key in ["ring_inner_ratio", "ring_outer_ratio", "ring_tilt_deg", "ring_density",
			"ring_rocks", "moon_count", "moon_distance_ratio", "moon_size_ratio",
			"moon_eccentricity", "orbit_speed"]:
		_sliders[key].value = preset.get(key)
	for key in ["volcano_count", "volcano_size_ratio", "volcano_height_ratio", "volcano_activity",
			"lava_glow", "eruption_rate_hz"]:
		_sliders[key].value = preset.get(key)
	_sliders["height_bands"].value = preset.height_bands
	_sliders["scattering"].value = preset.scattering_strength
	_sliders["red_nm"].value = preset.wavelengths_nm.x
	_sliders["green_nm"].value = preset.wavelengths_nm.y
	_sliders["blue_nm"].value = preset.wavelengths_nm.z
	_pickers["col_flat"].color = preset.col_flat
	_pickers["col_flat_deep"].color = preset.col_flat_deep
	_pickers["col_steep"].color = preset.col_steep
	_pickers["col_steep_deep"].color = preset.col_steep_deep
	_updating = false


func update_controls(aim_valid: bool) -> void:
	_pour_action.disabled = not aim_valid or not fluid.can_pour()
	_reset_action.disabled = not fluid.is_ready()
	if host.sun_auto_rotate:
		_updating = true
		_sliders["sun_yaw"].value = host.sun_yaw
		_updating = false


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func _shape_slider(menu: SimMenu, label: String, lower: float, upper: float,
		value: float, apply: Callable, step: float = 0.01) -> HSlider:
	return menu.add_slider(label, lower, upper, value, func(v: float) -> void:
		if _updating:
			return
		apply.call(v)
		host.queue_regen()
	, false, step)


func _orbit_slider(menu: SimMenu, label: String, lower: float, upper: float,
		value: float, apply: Callable, step: float = 0.01) -> HSlider:
	return menu.add_slider(label, lower, upper, value, func(v: float) -> void:
		if _updating:
			return
		apply.call(v)
		host.update_orbits()
	, false, step)


func _volcano_slider(menu: SimMenu, label: String, lower: float, upper: float,
		value: float, apply: Callable, step: float = 0.01) -> HSlider:
	return menu.add_slider(label, lower, upper, value, func(v: float) -> void:
		if _updating:
			return
		apply.call(v)
		host.update_volcanoes()
	, false, step)
