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
## set_frozen, throw_crate, clear_crates, set_foam_distance,
## set_detail_distance, set_spray_amount, set_sun_elevation,
## set_sun_azimuth, set_render_scale and a SimQualityState named quality.
var host: Node

var _preset_option: OptionButton
var _look_option: OptionButton
var _wind_direction: HSlider
var _wind_speed: HSlider
var _fetch: HSlider
var _swell: HSlider
var _spread: HSlider
var _detail: HSlider
var _jonswap_gamma: HSlider
var _choppiness: HSlider
var _height_gain: HSlider
var _crest_bias: HSlider
var _crest_gain: HSlider
var _whitecap: HSlider
var _foam_amount: HSlider
var _foam_persistence: HSlider
var _spray_amount: HSlider
var _foam_strength: HSlider
var _foam_distance: HSlider
var _foam_layout: Label
var _detail_distance: HSlider
var _sun_glitter_intensity: HSlider
var _mood: HSlider
var _sun_elevation: HSlider
var _sun_azimuth: HSlider
var _updating := false
## Set once the user moves "Foam strength": presets stop overwriting it from
## then on (docs/ocean_foam_injection_fix.md §5.3).
var _foam_strength_override := false
var _foam_distance_override := false
var _detail_distance_override := false


func build(menu: SimMenu, presets: Array, looks: Array, sun_elevation: float, sun_azimuth: float,
		time_scale: float) -> void:
	var names: Array = []
	for preset in presets:
		var typed: OceanPreset = preset
		names.append(typed.display_name)

	menu.add_section("Sea state")
	_preset_option = menu.add_option_button("Preset", names, 1, host.apply_preset)
	_wind_direction = _spectrum_slider(menu, "Wind direction", 0.0, TAU, solver.wind_direction,
		func(v: float): solver.wind_direction = v)
	_wind_speed = _spectrum_slider(menu, "Wind speed (m/s)", 0.5, 35.0, solver.wind_speed,
		func(v: float): solver.wind_speed = v)
	_fetch = _spectrum_slider(menu, "Fetch (km)", 5.0, 1000.0, solver.fetch_km,
		func(v: float): solver.fetch_km = v)
	_swell = _spectrum_slider(menu, "Swell", 0.0, 2.0, solver.swell,
		func(v: float): solver.swell = v)
	_spread = _spectrum_slider(menu, "Spread", 0.0, 1.0, solver.spread,
		func(v: float): solver.spread = v)
	_detail = _spectrum_slider(menu, "Detail", 0.5, 1.0, solver.detail,
		func(v: float): solver.detail = v)
	_detail.step = 0.01
	_jonswap_gamma = _spectrum_slider(menu, "Peak enhancement (γ)", 1.0, 7.0,
		solver.jonswap_gamma, func(v: float): solver.jonswap_gamma = v)
	_jonswap_gamma.step = 0.1
	menu.add_separator()

	menu.add_section("Waves")
	_choppiness = menu.add_slider("Choppiness", 0.0, OceanSolver.JONSWAP_MAX_CHOPPINESS,
		solver.choppiness,
		func(v: float):
			solver.choppiness = v
			solver.request_render_refresh())
	_height_gain = _spectrum_slider(menu, "Wave height", 0.0,
		OceanSolver.JONSWAP_MAX_HEIGHT_GAIN, solver.height_gain,
		func(v: float): solver.height_gain = v)
	_crest_bias = menu.add_slider("Crest threshold", 0.0, 0.8, solver.crest_bias,
		func(v: float):
			solver.crest_bias = v
			solver.request_render_refresh())
	_crest_gain = menu.add_slider("Crest gain", 0.1, 8.0, solver.crest_gain,
		func(v: float):
			solver.crest_gain = v
			solver.request_render_refresh())
	menu.add_slider("Time scale", 0.0, 2.0, time_scale, host.set_time_scale)
	menu.add_separator()

	menu.add_action("🌊", "Sea", cycle_preset)
	menu.add_action("📦", "Throw", host.throw_crate)
	menu.add_action("🧹", "Clear", host.clear_crates)
	menu.add_action_toggle("⏸", "Freeze", false, host.set_frozen)

	menu.add_section("Foam")
	_whitecap = menu.add_slider("Breaking threshold", 0.05, 0.95, solver.whitecap,
		func(v: float):
			solver.whitecap = v
			solver.request_render_refresh())
	_foam_amount = menu.add_slider("Foam amount", 0.0, 10.0, solver.foam_amount,
		func(v: float): solver.foam_amount = v)
	_foam_persistence = menu.add_slider("Foam persistence", 0.1, 15.0,
		solver.foam_persistence, func(v: float): solver.foam_persistence = v)
	_spray_amount = menu.add_slider("Spray amount", 0.0, 2.0, 0.1, host.set_spray_amount)
	_foam_strength = menu.add_slider("Foam strength", 0.0, 3.0, 1.0,
		func(v: float):
			_foam_strength_override = true
			surface_mat.set_shader_parameter("foam_strength", v))
	_foam_distance = menu.add_slider("Fine foam radius (m)", 16.0, 512.0,
		solver.foam_near_domain * 0.5, func(v: float):
			_foam_distance_override = true
			host.set_foam_distance(v))
	_foam_distance.step = 1.0
	_foam_layout = menu.add_label("")
	sync_foam_layout()
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
	host.quality.attach_menu_option(menu)
	_detail_distance = menu.add_slider("Detail distance (m)", 250.0, 4000.0,
		host.detail_distance_m, func(v: float):
			_detail_distance_override = true
			host.set_detail_distance(v))
	_detail_distance.step = 50.0
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, host.set_render_scale)


## Moves every slider a preset carries, so the panel shows what is running. The
## sliders snap to their own step, so the host still applies the preset to the
## solver afterwards for the exact values; the guard keeps the spectrum sliders
## from marking the spectrum dirty on every assignment.
func sync_to_preset(preset: OceanPreset) -> void:
	_updating = true
	_wind_speed.value = preset.wind_speed_mps
	_fetch.value = preset.fetch_km
	_swell.value = preset.swell
	_spread.value = preset.spread
	_detail.value = preset.detail
	_jonswap_gamma.value = preset.jonswap_gamma
	_choppiness.value = preset.choppiness
	_height_gain.value = preset.height_gain
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


func sync_foam_layout() -> void:
	if _foam_layout != null:
		_foam_layout.text = "Foam resolution: %.1f cm/texel | Reach: %.0f m" % [
			solver.foam_near_domain / solver.foam_near_size * 100.0,
			solver.foam_field_domains().z * 0.5]


func sync_foam_distance(value: float) -> bool:
	if _foam_distance_override:
		return false
	if _foam_distance != null:
		_foam_distance.set_value_no_signal(value)
	return true


func sync_detail_distance(value: float) -> bool:
	if _detail_distance_override:
		return false
	if _detail_distance != null:
		_detail_distance.value = value
		_detail_distance_override = false
	return true


## Emitting item_selected keeps the panel dropdown and the persisted value in sync.
func cycle_preset() -> void:
	if _preset_option == null:
		return
	var next := (_preset_option.selected + 1) % _preset_option.item_count
	_preset_option.select(next)
	_preset_option.item_selected.emit(next)


## Spectrum-shaping sliders flip the dirty flag: regeneration is one cheap
## dispatch per cascade and the fixed seeds keep phases continuous.
func _spectrum_slider(menu: SimMenu, label: String, lo: float, hi: float, value: float,
		setter: Callable) -> HSlider:
	return menu.add_slider(label, lo, hi, value, func(v: float):
		setter.call(v)
		if not _updating:
			solver.mark_spectrum_dirty()
	)
