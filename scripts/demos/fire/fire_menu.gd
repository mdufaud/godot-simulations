class_name FireMenu extends RefCounted
## Builds the fire demo's SimMenu and owns every widget in it.
##
## The host passes itself to [method build] and the callbacks call back into it;
## in return the menu keeps the widget handles, so fuel-mode visibility, the
## weapon radio group and the stat bars are refreshed from here rather than from
## the controller.

var fuel_bar: ProgressBar
var oxygen_bar: ProgressBar
var temp_bar: ProgressBar
var wood_bar: ProgressBar
var wood_label: Label
var preset_status_label: Label

var _wood_group: VBoxContainer
var _gas_group: VBoxContainer
var _flamethrower_group: VBoxContainer
var _wood_section: Button
var _gas_section: Button
var _flamethrower_section: Button
var _mode_button: Button
var _log_button: Button
var _gas_reinjection_button: Button
var _ignite_button: Button
var _flamethrower_button: Button
var _water_buttons := {}


## [param host] is the fire controller: untyped, because the callbacks reach for
## its own properties and a static Node type would reject them.
func build(host) -> void:
	var menu: SimMenu = host.menu
	var solver: FireGpuSolver = host.solver
	var water: FireWater = host.water
	var wood_pile: WoodPile = host.wood_pile
	var quality: FireQuality = host.quality

	fuel_bar = menu.add_progress_bar("Fuel", 100.0)
	oxygen_bar = menu.add_progress_bar("Oxygen", 100.0)
	temp_bar = menu.add_progress_bar("Temperature", 100.0)

	menu.add_separator()
	menu.add_section("Quality")
	menu.add_option_button("Performance preset",
		FireQuality.PRESET_NAMES, quality.preset, quality.set_preset)
	preset_status_label = menu.add_label("")
	preset_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var pool_quality_names: Array[String] = []
	for budget in FireGpuSolver.POOL_BUDGETS:
		pool_quality_names.append("%d tiles" % budget)
	menu.add_option_button("Pool budget", pool_quality_names,
		FireGpuSolver.POOL_BUDGETS.find(solver.pool_budget), host.set_pool_budget)

	menu.add_separator()
	_wood_section = menu.add_section("Wood")
	_wood_group = menu.add_group()
	wood_label = menu.add_label("0 logs")
	wood_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wood_bar = menu.add_progress_bar("Volatiles left", 100.0)
	menu.add_slider("Log fuel (kg)", 0.2, 12.0, wood_pile.log_fuel,
		func(v: float): wood_pile.log_fuel = v)
	# NON-PAPER: how hard the bed shelters its flame base from the wind (see
	# wood_shelter_rate). Higher keeps the flame anchored in a stronger breeze.
	menu.add_slider("Bed shelter (1/s)", 0.0, 20.0, solver.wood_shelter_rate,
		func(v: float): solver.wood_shelter_rate = v)
	menu.end_group()

	menu.add_separator()
	_flamethrower_section = menu.add_section("Flamethrower")
	_flamethrower_group = menu.add_group()
	menu.add_slider("Reach (m)", 1.0, 12.0, solver.torch_length,
		func(v: float): solver.torch_length = v)
	menu.add_slider("Fuel rate", 0.0, 5.0, solver.torch_rate,
		func(v: float): solver.torch_rate = v)
	menu.add_slider("Gas temperature (K)", 300.0, 1500.0, solver.torch_temperature,
		func(v: float): solver.torch_temperature = v)
	menu.add_slider("Jet speed (m/s)", 1.0, 20.0, solver.torch_speed,
		func(v: float): solver.torch_speed = v)
	menu.end_group()

	menu.add_separator()
	_gas_section = menu.add_section("Gas")
	_gas_group = menu.add_group()
	var fuel_names := []
	for f in FireGpuSolver.FUELS:
		fuel_names.append(f["name"])
	menu.add_option_button("Gas", fuel_names, solver.fuel_index, host.set_gas_fuel)
	menu.add_option_button("A units", ["CGS (Westbrook-Dryer)", "SI as printed"],
		solver.units_convention,
		func(idx: int) -> void: solver.units_convention = idx)
	menu.add_slider("Fuel supply", 0.0, 5.0, host.emitter_rate,
		func(v: float): host.emitter_rate = v)
	menu.end_group()

	_mode_button = menu.add_action_toggle("⛽", "Gas / Wood", true, host.set_fuel_mode)
	menu.add_action("↺", "Reset", host.reset_simulation)
	_log_button = menu.add_action("🪵", "Log", host.drop_log)
	_gas_reinjection_button = menu.add_action_toggle("🫧", "Continuous gas",
		host.gas_reinjection_enabled, host.set_gas_reinjection)
	_ignite_button = menu.add_action("🔥", "Ignite", host.ignite_gas)
	_flamethrower_button = menu.add_action_toggle("🔥", "Flamethrower", false,
		host.set_flamethrower)
	var water_icons := ["💧", "💦", "🌊"]
	for level in [1, 2, 3]:
		var level_name: String = ["Light", "Med", "Heavy"][level - 1]
		_water_buttons[level] = menu.add_action_toggle(water_icons[level - 1], level_name,
			false, func(on: bool) -> void: host.set_water_level(level, on))
	menu.add_action("🪣", "Pour", host.pour_water)
	menu.add_action_toggle("🌬", "Wind", false, host.set_wind_enabled)
	menu.add_action_toggle("🧯", "Smother", false, host.set_smothering)
	menu.add_debug_toggle("🐛", "Debug info", host.debug_info, host.set_debug_info)

	# Ranges below are the paper's own (Fire-X Tab. 3) wherever it gives one.
	menu.add_separator()
	menu.add_section("Combustion")
	menu.add_slider("Heat efficiency φ", 0.0, 1.0, solver.heat_efficiency,
		func(v: float): solver.heat_efficiency = v)
	menu.add_slider("Radiation coeff", 0.0, 6.0, solver.radiation_coefficient,
		func(v: float): solver.radiation_coefficient = v)
	menu.add_slider("CO₂ coeff", 0.0, 10.0, solver.co2_coefficient,
		func(v: float): solver.co2_coefficient = v)
	menu.add_slider("Water vapor coeff", 0.0, 10.0, solver.h2o_coefficient,
		func(v: float): solver.h2o_coefficient = v)
	menu.add_slider("Residual coeff", 0.0, 10.0, solver.residual_coefficient,
		func(v: float): solver.residual_coefficient = v)
	menu.add_slider("Emitter temp (K)", 300.0, 1500.0, solver.emitter_temperature,
		func(v: float): solver.emitter_temperature = v)

	menu.add_separator()
	menu.add_section("Evaporation")
	menu.add_toggle("Evaporation", solver.evaporation_enabled, func(on: bool) -> void:
		solver.evaporation_enabled = on
		water.evaporation_active = on)
	menu.add_slider("Droplet diameter (mm)", 0.5, 5.0,
		solver.droplet_diameter * 1000.0,
		func(v: float): solver.droplet_diameter = v * 0.001)
	# UNDEFINED IN PAPER: Eq. 10's k, read as a heat transfer coefficient.
	menu.add_slider("Droplet heat transfer", 0.0, 500.0, solver.droplet_heat_transfer,
		func(v: float): solver.droplet_heat_transfer = v)
	# NON-PAPER: wet-cell combustion suppression. Below ~20 water makes the fire
	# spread instead of die; see FireGpuSolver.water_suppression.
	menu.add_slider("Water suppression", 0.0, 100.0, solver.water_suppression,
		func(v: float): solver.water_suppression = v)
	# NON-PAPER: how fast a cold puddle drains away so the fire can recover; 0 keeps
	# the old behaviour where water pooled forever and half-smothered the flame.
	menu.add_slider("Water drain (1/s)", 0.0, 1.0, solver.liquid_drain_rate,
		func(v: float):
			solver.liquid_drain_rate = v
			water.drain_rate = v)
	# Manual overrides cover the gameplay jet presets above.
	menu.add_slider("Jet velocity (m/s)", 0.0, 20.0, water.jet_velocity,
		func(v: float): water.jet_velocity = v)
	menu.add_slider("Jet frequency (Hz)", 10.0, 4000.0, water.jet_frequency,
		func(v: float): water.jet_frequency = v)

	menu.add_separator()
	menu.add_section("Flow")
	menu.add_slider("Vorticity strength", 0.0, 50.0, solver.vorticity_strength,
		func(v: float): solver.vorticity_strength = v)
	menu.add_slider("Turbulence Cs", 0.0, 0.4, solver.smagorinsky_cs,
		func(v: float): solver.smagorinsky_cs = v)
	menu.add_slider("Buoyancy g", 0.0, 20.0, solver.gravity,
		func(v: float): solver.gravity = v)
	# Free stream at the 10 m reference height; the fire sits deep in the boundary
	# layer under it (see wind_profile in fire_forces.comp).
	menu.add_slider("Wind X @10 m", -5.0, 5.0, host.wind_vector.x, host.set_wind_x)
	menu.add_slider("Wind Z @10 m", -5.0, 5.0, host.wind_vector.z, host.set_wind_z)

	_build_performance_section(host, menu, solver, quality)


func _build_performance_section(host, menu: SimMenu, solver: FireGpuSolver,
		quality: FireQuality) -> void:
	var presentation: FirePresentation = host.presentation
	menu.add_separator()
	menu.add_section("Performance")
	var pressure_slider := menu.add_slider("Pressure iterations", 16.0, 128.0,
		float(solver.pressure_iterations),
		func(v: float): solver.pressure_iterations = int(v))
	pressure_slider.step = 2.0
	quality.register("pressure", pressure_slider,
		func(v: float): solver.pressure_iterations = int(v))
	# Entry order is the enum order, not the quality order: the third mode was
	# appended so that a preset storing 0 or 1 keeps meaning what it meant.
	var advection_option := menu.add_option_button("Advection",
		["MacCormack", "Semi-Lagrangian", "MacCormack (scalars)"],
		solver.advection_mode, host.set_advection_mode)
	quality.register("advection", advection_option, host.set_advection_mode)
	var vorticity_option := menu.add_option_button("Vorticity mode",
		["Full", "Reduced", "Off"], solver.vorticity_mode, host.set_vorticity_mode)
	quality.register("vorticity_mode", vorticity_option, host.set_vorticity_mode)
	var vorticity_frequency := menu.add_slider("Vorticity frequency", 1.0, 4.0,
		float(solver.vorticity_interval),
		func(v: float): solver.vorticity_interval = int(v))
	vorticity_frequency.step = 1.0
	quality.register("vorticity_frequency", vorticity_frequency,
		func(v: float): solver.vorticity_interval = int(v))
	var simulation_rate_names := ["5 Hz", "10 Hz", "15 Hz", "30 Hz", "60 Hz", "120 Hz"]
	var simulation_rate := menu.add_option_button("Simulation rate", simulation_rate_names,
		FireQuality.SIMULATION_RATES.find(solver.simulation_hz), host.set_simulation_hz)
	quality.register("simulation_hz", simulation_rate, host.set_simulation_hz)
	var temporal_interpolation := menu.add_toggle("Temporal interpolation",
		presentation.temporal_interpolation, presentation.set_temporal_interpolation)
	quality.register("temporal", temporal_interpolation,
		presentation.set_temporal_interpolation)
	var catchup := menu.add_slider("Max catch-up substeps", 1.0, 4.0,
		float(solver.max_catchup_steps), host.set_max_catchup_steps)
	catchup.step = 1.0
	quality.register("catchup", catchup, host.set_max_catchup_steps)
	var water_substeps := menu.add_slider("Water SPH substeps", 4.0, 16.0,
		float(host.water_substeps), host.set_water_substeps)
	water_substeps.step = 1.0
	quality.register("water_substeps", water_substeps, host.set_water_substeps)
	var water_adaptive := menu.add_toggle("Adaptive water substeps",
		host.water_adaptive_substeps, host.set_water_adaptive_substeps)
	quality.register("water_adaptive", water_adaptive, host.set_water_adaptive_substeps)
	var water_cap := menu.add_slider("Water particle cap", 1024.0, 16384.0,
		float(host.water_particle_cap), host.set_water_particle_cap)
	water_cap.step = 1024.0
	quality.register("water_cap", water_cap, host.set_water_particle_cap)
	var march_step := menu.add_slider("Volume march step", 0.25, 4.0, 0.75,
		func(v: float): presentation.set_volume_parameter("march_step", v))
	march_step.step = 0.05
	quality.register("march_step", march_step,
		func(v: float): presentation.set_volume_parameter("march_step", v))
	var march_budget := menu.add_slider("Volume march budget", 64.0, 512.0, 320.0,
		func(v: float): presentation.set_volume_parameter("march_budget", int(v)))
	march_budget.step = 8.0
	quality.register("march_budget", march_budget,
		func(v: float): presentation.set_volume_parameter("march_budget", int(v)))
	var march_distance := menu.add_slider("Volume max distance", 16.0, 128.0, 80.0,
		func(v: float): presentation.set_volume_parameter("max_distance", v))
	march_distance.step = 1.0
	quality.register("march_distance", march_distance,
		func(v: float): presentation.set_volume_parameter("max_distance", v))
	var water_scale := menu.add_slider("Water render scale", 0.25, 1.0, 1.0,
		presentation.set_water_render_scale)
	water_scale.step = 0.05
	quality.register("water_scale", water_scale, presentation.set_water_render_scale)
	var render_scale := menu.add_slider("Global render scale", 0.4, 1.0, 1.0,
		host.set_render_scale)
	render_scale.step = 0.05
	quality.register("render_scale", render_scale, host.set_render_scale)
	var msaa := menu.add_option_button("Anti-aliasing", FireQuality.MSAA_NAMES,
		FireQuality.MSAA_MODES.find(host.viewport_guard.msaa()), host.set_msaa)
	quality.register("msaa", msaa, host.set_msaa)
	var volume_half := menu.add_toggle("Half-res volume pass", false,
		presentation.set_half_res)
	quality.register("volume_half", volume_half, presentation.set_half_res)
	# Apply the default preset rather than only labelling it. Every slider above was
	# built with the Reference value baked into its constructor, so a demo that never
	# applied its own default ran the reference configuration whatever the preset
	# selector said it was.
	quality.set_preset(quality.preset)


## Shows the widgets that belong to the active fuel and hides the others.
func refresh_fuel_mode(menu: SimMenu, gas_mode: bool, gas_reinjection: bool) -> void:
	if _mode_button == null:
		return
	menu.title = "🔥 Campfire — Gas (Fire-X)" if gas_mode else "🔥 Campfire — Wood (Fire-X)"
	_mode_button.text = "⛽" if gas_mode else "🪵"
	_mode_button.set_pressed_no_signal(gas_mode)
	_log_button.visible = not gas_mode
	_gas_reinjection_button.visible = gas_mode
	_gas_reinjection_button.set_pressed_no_signal(gas_reinjection)
	_ignite_button.visible = gas_mode
	_flamethrower_button.visible = not gas_mode
	for level in _water_buttons:
		_water_buttons[level].visible = true
	_wood_group.visible = not gas_mode
	_wood_section.visible = not gas_mode
	_flamethrower_group.visible = not gas_mode
	_flamethrower_section.visible = not gas_mode
	_gas_group.visible = gas_mode
	_gas_section.visible = gas_mode


## The weapon buttons are a radio group over the interaction state, so they are
## restated from it rather than toggled one by one at each call site.
func sync_weapon_buttons(interaction: FireInteraction) -> void:
	if _flamethrower_button == null:
		return
	_flamethrower_button.set_pressed_no_signal(interaction.flamethrower_firing)
	for level in _water_buttons:
		_water_buttons[level].set_pressed_no_signal(
			interaction.jet_enabled and interaction.water_level == level)


func update_stats(stats: Dictionary, temp_norm: float) -> void:
	fuel_bar.value = stats["avg_fuel"] * 100.0
	oxygen_bar.value = stats["avg_oxygen"] * 100.0
	temp_bar.value = clampf(temp_norm * 100.0, 0.0, 100.0)


func refresh_wood(wood_pile: WoodPile) -> void:
	if wood_label == null:
		return
	wood_bar.value = wood_pile.total_fuel() / maxf(wood_pile.initial_fuel(), 1e-4) * 100.0
	wood_label.text = "%d logs, %d burning, %.2f kg volatiles left" % [
		wood_pile.log_count(), wood_pile.burning_count(), wood_pile.total_fuel()]
