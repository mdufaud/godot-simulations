class_name OceanMenu extends RefCounted
## SimMenu panel of the ocean demo. Every widget writes one named field, so the
## sea-state sliders are the single path a preset travels through: applying a
## preset moves the sliders, and the sliders move the solver.

const MAP_SIZES: Array[int] = [128, 256, 512]

var solver: OceanSolver
var surface_mat: ShaderMaterial
var world_env: WorldEnvironment
var storm: OceanStorm
var profiler: SimProfiler
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide apply_preset, set_time_scale, set_frozen, throw_crate, clear_crates,
## set_map_size, set_sun_elevation, set_sun_azimuth and set_render_scale.
var host: Node

var _preset_option: OptionButton
var _wind_speed: HSlider
var _fetch: HSlider
var _swell: HSlider
var _spread: HSlider
var _choppiness: HSlider
var _height_gain: HSlider
var _whitecap: HSlider
var _foam_amount: HSlider
var _mood: HSlider
var _updating := false


func build(menu: SimMenu, presets: Array, sun_elevation: float, sun_azimuth: float,
		time_scale: float) -> void:
	var names: Array = []
	for preset in presets:
		var typed: OceanPreset = preset
		names.append(typed.display_name)

	menu.add_section("Sea state")
	_preset_option = menu.add_option_button("Preset", names, 1, host.apply_preset)
	_wind_speed = _spectrum_slider(menu, "Wind speed (m/s)", 0.5, 35.0, solver.wind_speed,
		func(v: float): solver.wind_speed = v)
	_spectrum_slider(menu, "Wind direction", 0.0, TAU, solver.wind_direction,
		func(v: float): solver.wind_direction = v)
	_fetch = _spectrum_slider(menu, "Fetch (km)", 5.0, 1000.0, solver.fetch_km,
		func(v: float): solver.fetch_km = v)
	_swell = _spectrum_slider(menu, "Swell", 0.0, 2.0, solver.swell,
		func(v: float): solver.swell = v)
	_spread = _spectrum_slider(menu, "Spread", 0.0, 1.0, solver.spread,
		func(v: float): solver.spread = v)
	_spectrum_slider(menu, "Detail", 0.5, 1.0, solver.detail,
		func(v: float): solver.detail = v)
	menu.add_separator()

	menu.add_section("Waves")
	_choppiness = menu.add_slider("Choppiness", 0.0, 1.8, solver.choppiness,
		func(v: float): solver.choppiness = v)
	_height_gain = _spectrum_slider(menu, "Wave height", 0.0, 5.0, solver.height_gain,
		func(v: float): solver.height_gain = v)
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
	menu.add_slider("Foam strength", 0.0, 3.0, 1.0,
		func(v: float): surface_mat.set_shader_parameter("foam_strength", v))
	menu.add_separator()

	menu.add_section("Environment")
	_mood = menu.add_slider("Storm mood", 0.0, 1.0, storm.mood_target,
		func(v: float): storm.mood_target = v)
	menu.add_slider("Sun elevation", 2.0, 80.0, sun_elevation, host.set_sun_elevation)
	menu.add_slider("Sun azimuth", 0.0, 360.0, sun_azimuth, host.set_sun_azimuth)
	menu.add_separator()

	menu.add_section("Performance")
	menu.add_debug_toggle("🔮", "SSR", false,
		func(on: bool): world_env.environment.ssr_enabled = on)
	menu.add_debug_toggle("🐢", "Amortize cascades", false,
		func(on: bool): solver.amortize = on)
	menu.add_debug_toggle("📊", "Profiler overlay", false, profiler.set_enabled)
	menu.add_label("FFT map size")
	for size in MAP_SIZES:
		menu.add_button(str(size), host.set_map_size.bind(size))
	menu.add_slider("Render scale", 0.4, 1.0, 1.0, host.set_render_scale)


## Moves every slider a preset carries, so the panel shows what is running. The
## sliders snap to their own step, so the host still applies the preset to the
## solver afterwards for the exact values; the guard keeps these nine callbacks
## from marking the spectrum dirty nine times on the way.
func sync_to_preset(preset: OceanPreset) -> void:
	_updating = true
	_wind_speed.value = preset.wind_speed_mps
	_fetch.value = preset.fetch_km
	_swell.value = preset.swell
	_spread.value = preset.spread
	_choppiness.value = preset.choppiness
	_height_gain.value = preset.height_gain
	_whitecap.value = preset.whitecap
	_foam_amount.value = preset.foam_amount
	_mood.value = preset.storm_mood
	_updating = false


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
