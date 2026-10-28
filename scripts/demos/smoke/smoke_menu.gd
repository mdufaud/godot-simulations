class_name SmokeMenu extends RefCounted
## Smoke demo panel and action lane. Air and Look rows and the scene action belong
## to the preset (not persisted, rewritten by [method refresh]); Emitters, Push and
## Time rows belong to the user; Solver and Graphics rows are driven by the quality
## tier.

const SHADOW_VOLUME_LABELS := ["Quarter", "Half", "Full"]
const MSAA_LABELS := ["Off", "2×", "4×"]

var _menu: SimMenu
var _preset_option: OptionButton
var _scene_action: Button
var _hint: Label
var _wind_speed: HSlider
var _wind_direction: HSlider
var _buoyancy: HSlider
var _weight: HSlider
var _vorticity: HSlider
var _density_decay: HSlider
var _temperature_decay: HSlider
var _velocity_decay: HSlider
var _extinction: HSlider
var _albedo: HSlider
var _phase: HSlider
var _color: ColorPickerButton
var _ambient: HSlider
var _sun_elevation: HSlider
var _sun_azimuth: HSlider
var _sun_energy: HSlider


func build(menu: SimMenu, host, presets: Array[SmokePreset]) -> void:
	_menu = menu
	var quality: SimQualityState = host.quality
	var config: SmokeConfig = host.solver.config
	var names: Array[String] = []
	for preset in presets:
		names.append(preset.display_name)

	menu.add_section("Scene")
	menu.add_action("🎬", "Scene", host.next_preset)
	menu.add_action("↺", "Reset", host.reset_scene)
	menu.add_action_toggle("⏸", "Pause", false, host.set_paused)
	_scene_action = menu.add_action("", "", host.scene_action)
	menu.add_action("🧨", "Flare", host.throw_flare)
	menu.add_action_toggle("✋", "Blow", false, func(on: bool) -> void: host.pointer.blow = on)
	menu.add_action_toggle("🔦", "Torch", false, func(on: bool) -> void: host.torch.visible = on)
	menu.add_action_toggle("🏭", "Sources", true, host.set_emitters_on)
	_preset_option = menu.add_option_button("Preset", names, host.preset_idx, host.apply_preset)
	_hint = menu.add_label("")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_separator()

	menu.add_section("Emitters")
	menu.add_slider("Rate ×", 0.0, 3.0, 1.0, func(v: float) -> void: host.rate_scale = v)
	menu.add_slider("Heat ×", 0.0, 3.0, 1.0, func(v: float) -> void: host.heat_scale = v)
	menu.add_slider("Speed ×", 0.0, 3.0, 1.0, func(v: float) -> void: host.speed_scale = v)
	menu.add_separator()

	menu.add_section("Air")
	_wind_speed = menu.add_slider("Wind m/s", 0.0, 8.0, config.wind_speed_mps,
		func(v: float) -> void: host.solver.config.wind_speed_mps = v, false, 0.05)
	_wind_direction = menu.add_slider("Wind direction °", 0.0, 360.0, config.wind_direction_deg,
		func(v: float) -> void: host.solver.config.wind_direction_deg = v, false, 1.0)
	_buoyancy = menu.add_slider("Buoyancy", 0.0, 0.2, config.buoyancy_mps2_per_k,
		func(v: float) -> void: host.solver.config.buoyancy_mps2_per_k = v, false, 0.001)
	_weight = menu.add_slider("Smoke weight", 0.0, 5.0, config.smoke_weight_mps2,
		func(v: float) -> void: host.solver.config.smoke_weight_mps2 = v, false, 0.05)
	_vorticity = menu.add_slider("Vorticity", 0.0, 2.0, config.vorticity_confinement,
		func(v: float) -> void: host.solver.config.vorticity_confinement = v, false, 0.01)
	_density_decay = menu.add_slider("Smoke fade /s", 0.0, 0.5, config.density_decay_hz,
		func(v: float) -> void: host.solver.config.density_decay_hz = v, false, 0.005)
	_temperature_decay = menu.add_slider("Cooling /s", 0.0, 3.0, config.temperature_decay_hz,
		func(v: float) -> void: host.solver.config.temperature_decay_hz = v, false, 0.01)
	_velocity_decay = menu.add_slider("Air drag /s", 0.0, 1.0, config.velocity_decay_hz,
		func(v: float) -> void: host.solver.config.velocity_decay_hz = v, false, 0.005)
	menu.add_separator()

	menu.add_section("Push")
	menu.add_slider("Radius m", 0.1, 1.5, host.pointer.radius_m,
		func(v: float) -> void: host.pointer.radius_m = v)
	menu.add_slider("Push m/s", 0.5, 15.0, host.pointer.push_mps,
		func(v: float) -> void: host.pointer.push_mps = v)
	menu.add_separator()

	menu.add_section("Look")
	_extinction = menu.add_slider("Density", 0.0, 30.0, config.extinction_per_m,
		func(v: float) -> void: host.solver.config.extinction_per_m = v, false, 0.1)
	_albedo = menu.add_slider("Albedo", 0.0, 1.0, config.scattering_albedo,
		func(v: float) -> void: host.solver.config.scattering_albedo = v, false, 0.01)
	_phase = menu.add_slider("Forward glow", -0.5, 0.9, config.phase_g,
		func(v: float) -> void: host.solver.config.phase_g = v, false, 0.01)
	_color = menu.add_color_picker("Smoke color", config.smoke_color,
		func(c: Color) -> void: host.solver.config.smoke_color = c, false)
	_ambient = menu.add_slider("Ambient", 0.0, 1.5, config.ambient_strength,
		func(v: float) -> void: host.solver.config.ambient_strength = v, false, 0.01)
	_sun_elevation = menu.add_slider("Sun elevation °", 2.0, 90.0, host.sun_elevation_deg,
		host.set_sun_elevation, false, 0.5)
	_sun_azimuth = menu.add_slider("Sun azimuth °", 0.0, 360.0, host.sun_azimuth_deg,
		host.set_sun_azimuth, false, 1.0)
	_sun_energy = menu.add_slider("Sun energy", 0.0, 6.0, host.sun.light_energy,
		func(v: float) -> void: host.sun.light_energy = v, false, 0.05)
	menu.add_separator()

	menu.add_section("Time")
	menu.add_slider("Time scale", 0.1, 2.0, 1.0, func(v: float) -> void: host.time_scale = v)
	menu.add_separator()

	menu.add_section("Solver")
	var grid_labels := SmokeQualityProfile.GRID_CELL_BUDGETS.map(func(cells: int) -> String:
		return "%.1fM cells" % (cells / 1e6) if cells >= 1000000 else "%dk cells" % (cells / 1000.0))
	var grid := menu.add_option_button("Grid", grid_labels,
		SmokeQualityProfile.GRID_CELL_BUDGETS.find(config.grid_cell_budget),
		func(i: int) -> void: host.set_quality_value("grid_cell_budget",
			SmokeQualityProfile.GRID_CELL_BUDGETS[i]), false)
	quality.bind("grid_cell_budget", grid,
		func(v: int) -> void: host.set_quality_value("grid_cell_budget", v),
		func(v: int) -> int: return SmokeQualityProfile.GRID_CELL_BUDGETS.find(v))
	var rate := menu.add_option_button("Simulation rate",
		SmokeQualityProfile.SIM_RATES_HZ.map(func(hz: float) -> String: return "%d Hz" % hz),
		SmokeQualityProfile.SIM_RATES_HZ.find(config.sim_rate_hz),
		func(i: int) -> void: host.set_quality_value("sim_rate_hz",
			SmokeQualityProfile.SIM_RATES_HZ[i]), false)
	quality.bind("sim_rate_hz", rate,
		func(v: float) -> void: host.set_quality_value("sim_rate_hz", v),
		func(v: float) -> int: return SmokeQualityProfile.SIM_RATES_HZ.find(v))
	var vcycles := menu.add_slider("V-cycles", 1.0, 6.0, float(config.pressure_vcycles),
		func(v: float) -> void: host.set_quality_value("pressure_vcycles", v), false, 1.0)
	quality.bind("pressure_vcycles", vcycles,
		func(v: float) -> void: host.set_quality_value("pressure_vcycles", v))
	var maccormack := menu.add_toggle("MacCormack advection", config.maccormack,
		func(on: bool) -> void: host.set_quality_value("maccormack", on), false)
	quality.bind("maccormack", maccormack,
		func(on: bool) -> void: host.set_quality_value("maccormack", on))
	menu.add_toggle("Flow maps (high-end GPU)", config.flow_maps,
		func(on: bool) -> void: host.set_quality_value("flow_maps", on), false)
	menu.add_debug_toggle("📊", "Profiler overlay", false, host.profiler.set_enabled)
	menu.add_separator()

	menu.add_section("Graphics")
	quality.attach_menu_option(menu)
	menu.add_slider("Render scale", 0.4, 1.0, host.render_scale(), host.set_render_scale)
	var march := menu.add_slider("March step", 0.25, 2.0, config.march_step_cells,
		func(v: float) -> void: host.set_quality_value("march_step_cells", v), false, 0.05)
	quality.bind("march_step_cells", march,
		func(v: float) -> void: host.set_quality_value("march_step_cells", v))
	var shadow := menu.add_option_button("Shadow volume", SHADOW_VOLUME_LABELS,
		SmokeQualityProfile.LIGHT_DOWNSAMPLES.find(config.light_downsample),
		func(i: int) -> void: host.set_quality_value("light_downsample",
			SmokeQualityProfile.LIGHT_DOWNSAMPLES[i]), false)
	quality.bind("light_downsample", shadow,
		func(v: int) -> void: host.set_quality_value("light_downsample", v),
		func(v: int) -> int: return SmokeQualityProfile.LIGHT_DOWNSAMPLES.find(v))
	var msaa := menu.add_option_button("MSAA", MSAA_LABELS, host.msaa_mode(),
		func(i: int) -> void: host.set_quality_value("msaa", i), false)
	quality.bind("msaa", msaa, func(v: int) -> void: host.set_quality_value("msaa", v))
	var shadows := menu.add_toggle("Sun shadows", host.sun.shadow_enabled,
		func(on: bool) -> void: host.set_quality_value("scene_shadows", on), false)
	quality.bind("scene_shadows", shadows,
		func(on: bool) -> void: host.set_quality_value("scene_shadows", on))


## Rewrites the preset-owned rows from the live config and scene.
func refresh(host, preset: SmokePreset) -> void:
	var config: SmokeConfig = host.solver.config
	_preset_option.select(host.preset_idx)
	_menu.store_value("Scene", "Preset", host.preset_idx)
	_hint.text = "%s\nDrag a body to move it · Blow, or right drag: push the air" % preset.hint
	_menu.set_action_icon(_scene_action, preset.action_icon)
	_menu.set_action_label(_scene_action, preset.action_label)
	_scene_action.visible = preset.action_label != ""
	_menu.set_slider_value(_wind_speed, config.wind_speed_mps)
	_menu.set_slider_value(_wind_direction, config.wind_direction_deg)
	_menu.set_slider_value(_buoyancy, config.buoyancy_mps2_per_k)
	_menu.set_slider_value(_weight, config.smoke_weight_mps2)
	_menu.set_slider_value(_vorticity, config.vorticity_confinement)
	_menu.set_slider_value(_density_decay, config.density_decay_hz)
	_menu.set_slider_value(_temperature_decay, config.temperature_decay_hz)
	_menu.set_slider_value(_velocity_decay, config.velocity_decay_hz)
	_menu.set_slider_value(_extinction, config.extinction_per_m)
	_menu.set_slider_value(_albedo, config.scattering_albedo)
	_menu.set_slider_value(_phase, config.phase_g)
	_color.color = config.smoke_color
	_menu.set_slider_value(_ambient, config.ambient_strength)
	_menu.set_slider_value(_sun_elevation, host.sun_elevation_deg)
	_menu.set_slider_value(_sun_azimuth, host.sun_azimuth_deg)
	_menu.set_slider_value(_sun_energy, host.sun.light_energy)


func profiler_lines(host) -> PackedStringArray:
	var solver: SmokeSolver = host.solver
	var t := solver.get_timings()
	return PackedStringArray([
		"smoke GPU %.2f ms · grid %s · %s" % [t.get("total", 0.0), solver.grid_dims(),
			host.quality.label()],
		"  advect %.2f | vorticity %.2f | pressure %.2f | project %.2f | light %.2f" % [
			t.get("advect", 0.0), t.get("vorticity", 0.0), t.get("pressure", 0.0),
			t.get("project", 0.0), t.get("light", 0.0)],
	])
