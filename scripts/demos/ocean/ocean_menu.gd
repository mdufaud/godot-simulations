class_name OceanMenu extends RefCounted
## SimMenu panel of the ocean demo. Every widget writes one named field, so the
## sea-state sliders are the single path a preset travels through: applying a
## preset moves the sliders, and the sliders move the solver.

var solver: OceanSolver
var surface_mat: ShaderMaterial
var world_env: WorldEnvironment
var storm: OceanStorm
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, apply_look, current_look_index, set_time_scale,
## set_frozen, throw_crate, clear_crates, set_quality_profile,
## quality_profile_label, quality_requested, quality_effective, set_backend,
## set_spray_amount, set_sun_elevation, set_sun_azimuth and set_render_scale.
var host: Node

var _preset_option: OptionButton
var _look_option: OptionButton
var _profile_option: OptionButton
var _spectral_group: VBoxContainer
var _art_group: VBoxContainer
var _wind_speed: HSlider
var _fetch: HSlider
var _swell: HSlider
var _spread: HSlider
var _choppiness: HSlider
var _height_gain: HSlider
var _long_height: HSlider
var _long_length: HSlider
var _mid_height: HSlider
var _mid_length: HSlider
var _mid_spread: HSlider
var _wind_height: HSlider
var _wind_length: HSlider
var _ripple_strength: HSlider
var _crosswind_ratio: HSlider
var _crest_bias: HSlider
var _crest_gain: HSlider
var _whitecap: HSlider
var _foam_amount: HSlider
var _foam_persistence: HSlider
var _spray_amount: HSlider
var _foam_strength: HSlider
var _sun_glitter_intensity: HSlider
var _mood: HSlider
var _sun_elevation: HSlider
var _sun_azimuth: HSlider
var _updating := false
## Set once the user moves "Foam strength": presets stop overwriting it from
## then on (docs/ocean_foam_injection_fix.md §5.3).
var _foam_strength_override := false


func build(menu: SimMenu, presets: Array, looks: Array, sun_elevation: float, sun_azimuth: float,
		time_scale: float) -> void:
	var names: Array = []
	for preset in presets:
		var typed: OceanPreset = preset
		names.append(typed.display_name)

	menu.add_section("Sea state")
	# The spectrum flavour is a production-only choice.
	menu.add_option_button("Spectrum", ["JONSWAP / TMA", "Art-directed (SoT)"],
		solver.backend, _backend_selected)
	_preset_option = menu.add_option_button("Preset", names, 1, host.apply_preset)
	_spectrum_slider(menu, "Wind direction", 0.0, TAU, solver.wind_direction,
		func(v: float): solver.wind_direction = v)
	_spectral_group = menu.add_group()
	_wind_speed = _spectrum_slider(menu, "Wind speed (m/s)", 0.5, 35.0, solver.wind_speed,
		func(v: float): solver.wind_speed = v)
	_fetch = _spectrum_slider(menu, "Fetch (km)", 5.0, 1000.0, solver.fetch_km,
		func(v: float): solver.fetch_km = v)
	_swell = _spectrum_slider(menu, "Swell", 0.0, 2.0, solver.swell,
		func(v: float): solver.swell = v)
	_spread = _spectrum_slider(menu, "Spread", 0.0, 1.0, solver.spread,
		func(v: float): solver.spread = v)
	_spectrum_slider(menu, "Detail", 0.5, 1.0, solver.detail,
		func(v: float): solver.detail = v)
	menu.end_group()
	_art_group = menu.add_group()
	_long_height = _spectrum_slider(menu, "Long wave height (m)", 0.0, 10.0,
		solver.long_wave_height_m, func(v: float): solver.long_wave_height_m = v)
	_long_length = _spectrum_slider(menu, "Long wavelength (m)", 5.0, 200.0,
		solver.long_wave_length_m, func(v: float): solver.long_wave_length_m = v)
	_mid_height = _spectrum_slider(menu, "Mid wave height (m)", 0.0, 5.0,
		solver.mid_wave_height_m, func(v: float): solver.mid_wave_height_m = v)
	_mid_length = _spectrum_slider(menu, "Mid wavelength (m)", 5.0, 100.0,
		solver.mid_wave_length_m, func(v: float): solver.mid_wave_length_m = v)
	_mid_spread = _spectrum_slider(menu, "Mid wave spread", 0.0, 1.0,
		solver.mid_wave_spread, func(v: float): solver.mid_wave_spread = v)
	_wind_height = _spectrum_slider(menu, "Wind wave height (m)", 0.0, 5.0,
		solver.wind_wave_height_m, func(v: float): solver.wind_wave_height_m = v)
	_wind_length = _spectrum_slider(menu, "Wind wavelength (m)", 1.0, 30.0,
		solver.wind_wave_length_m, func(v: float): solver.wind_wave_length_m = v)
	_ripple_strength = _spectrum_slider(menu, "Ripple strength", 0.0, 3.0,
		solver.ripple_strength, func(v: float): solver.ripple_strength = v)
	_crosswind_ratio = _spectrum_slider(menu, "Crosswind energy", 0.0, 0.65,
		solver.crosswind_ratio, func(v: float): solver.crosswind_ratio = v)
	menu.end_group()
	_update_backend_visibility()
	menu.add_separator()

	menu.add_section("Waves")
	_choppiness = menu.add_slider("Choppiness", 0.0, 1.8, solver.choppiness,
		func(v: float): solver.choppiness = v)
	_height_gain = _spectrum_slider(menu, "Wave height", 0.0, 5.0, solver.height_gain,
		func(v: float): solver.height_gain = v)
	_crest_bias = menu.add_slider("Crest threshold", 0.0, 0.8, solver.crest_bias,
		func(v: float): solver.crest_bias = v)
	_crest_gain = menu.add_slider("Crest gain", 0.1, 8.0, solver.crest_gain,
		func(v: float): solver.crest_gain = v)
	menu.add_slider("Time scale", 0.0, 2.0, time_scale, host.set_time_scale)
	menu.add_separator()

	menu.add_action("🌊", "Sea", cycle_preset)
	menu.add_action("📦", "Throw", host.throw_crate)
	menu.add_action("🧹", "Clear", host.clear_crates)
	menu.add_action_toggle("⏸", "Freeze", false, host.set_frozen)

	menu.add_section("Foam")
	_whitecap = menu.add_slider("Whitecap", 0.0, 2.0, solver.whitecap,
		func(v: float): solver.whitecap = v)
	_foam_amount = menu.add_slider("Foam amount", 0.0, 10.0, solver.foam_amount,
		func(v: float): solver.foam_amount = v)
	_foam_persistence = menu.add_slider("Foam persistence", 0.1, 15.0,
		solver.foam_persistence, func(v: float): solver.foam_persistence = v)
	_spray_amount = menu.add_slider("Spray amount", 0.0, 2.0, 0.1, host.set_spray_amount)
	_foam_strength = menu.add_slider("Foam strength", 0.0, 3.0, 1.0,
		func(v: float):
			_foam_strength_override = true
			surface_mat.set_shader_parameter("foam_strength", v))
	menu.add_separator()

	menu.add_section("Environment")
	var look_names: Array = []
	for look in looks:
		look_names.append((look as OceanLookPreset).display_name)
	_look_option = menu.add_option_button("Environment", look_names, 0, host.apply_look)
	_mood = menu.add_slider("Storm mood", 0.0, 1.0, storm.mood_target,
		func(v: float): storm.mood_target = v)
	_sun_elevation = menu.add_slider("Sun elevation", 2.0, 80.0, sun_elevation,
		host.set_sun_elevation)
	_sun_azimuth = menu.add_slider("Sun azimuth", 0.0, 360.0, sun_azimuth,
		host.set_sun_azimuth)
	_sun_glitter_intensity = menu.add_slider("Sun glitter intensity", 0.0, 2.0, 0.7,
		func(v: float): surface_mat.set_shader_parameter("sun_glitter_strength", v))
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("🔮", "SSR", false,
		func(on: bool): world_env.environment.ssr_enabled = on)
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	_profile_option = menu.add_option_button("Quality profile",
		OceanQualityProfile.TIER_NAMES, host.quality_requested,
		func(tier_idx: int):
			host.set_quality_profile(tier_idx)
			_refresh_profile_option(_profile_option))
	_refresh_profile_option(_profile_option)
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, host.set_render_scale)


## Keeps the profile selector honest: a degraded pick (e.g. Ultra on a GPU
## whose 2D limit is below 1024) reads "Ultra requested / High active".
func _refresh_profile_option(option: OptionButton) -> void:
	for i in option.item_count:
		if i == host.quality_requested \
				and host.quality_requested != host.quality_effective:
			option.set_item_text(i, host.quality_profile_label())
		else:
			option.set_item_text(i, OceanQualityProfile.TIER_NAMES[i])


## Moves every slider a preset carries, so the panel shows what is running. The
## sliders snap to their own step, so the host still applies the preset to the
## solver afterwards for the exact values; the guard keeps the 14 spectrum
## sliders from marking the spectrum dirty on every assignment.
func sync_to_preset(preset: OceanPreset) -> void:
	_updating = true
	_wind_speed.value = preset.wind_speed_mps
	_fetch.value = preset.fetch_km
	_swell.value = preset.swell
	_spread.value = preset.spread
	_choppiness.value = preset.choppiness
	_height_gain.value = preset.height_gain
	_long_height.value = preset.long_wave_height_m
	_long_length.value = preset.long_wave_length_m
	_mid_height.value = preset.mid_wave_height_m
	_mid_length.value = preset.mid_wave_length_m
	_mid_spread.value = preset.mid_wave_spread
	_wind_height.value = preset.wind_wave_height_m
	_wind_length.value = preset.wind_wave_length_m
	_ripple_strength.value = preset.ripple_strength
	_crosswind_ratio.value = preset.crosswind_ratio
	_crest_bias.value = preset.crest_bias
	_crest_gain.value = preset.crest_gain
	_whitecap.value = preset.whitecap
	_foam_amount.value = preset.foam_amount
	_foam_persistence.value = preset.foam_persistence
	_spray_amount.value = preset.spray_amount
	_updating = false


func sync_to_look(look: OceanLookPreset) -> void:
	if _look_option == null:
		return
	_look_option.select(host.current_look_index)
	_sun_elevation.set_value_no_signal(look.sun_elevation)
	_sun_azimuth.set_value_no_signal(look.sun_azimuth)
	_sun_glitter_intensity.set_value_no_signal(look.sun_glitter_strength)


## Push the preset-derived foam strength to the slider and report whether the
## host should apply it. Once the user has touched "Foam strength" the slider is
## an override: the value keeps running but presets no longer rewrite it.
func sync_foam_strength(value: float) -> bool:
	if _foam_strength == null or _foam_strength_override:
		return false
	_foam_strength.set_value_no_signal(value)
	return true


## Emitting item_selected keeps the panel dropdown and the persisted value in sync.
func cycle_preset() -> void:
	if _preset_option == null:
		return
	var next := (_preset_option.selected + 1) % _preset_option.item_count
	_preset_option.select(next)
	_preset_option.item_selected.emit(next)


func _backend_selected(index: int) -> void:
	host.set_backend(index)
	_update_backend_visibility()


func _update_backend_visibility() -> void:
	if _spectral_group != null:
		_spectral_group.visible = solver.backend == OceanSolver.Backend.JONSWAP_TMA
	if _art_group != null:
		_art_group.visible = solver.backend == OceanSolver.Backend.SEA_OF_THIEVES_INSPIRED_FFT


## Spectrum-shaping sliders flip the dirty flag: regeneration is one cheap
## dispatch per cascade and the fixed seeds keep phases continuous.
func _spectrum_slider(menu: SimMenu, label: String, lo: float, hi: float, value: float,
		setter: Callable) -> HSlider:
	return menu.add_slider(label, lo, hi, value, func(v: float):
		setter.call(v)
		if not _updating:
			solver.mark_spectrum_dirty()
	)
