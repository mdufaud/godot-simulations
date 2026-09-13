extends "res://tests/test_case.gd"
## Value-only gate for the shared quality-tier mechanism: every profile's tier
## tables (key sets, ranges, hardware caps, monotony), the GameManager seeds
## the persistence restore depends on, and the SimQualityState state machine
## (degradation, mobile fallback, widget pushes, persistence) — all headless,
## no GPU, no window.

const QUALITY_KEYS := [
	"ocean_quality_profile", "terrain_quality_profile", "nbody_quality_profile",
	"planet_quality_profile", "fluid_quality_profile", "tornado_quality_profile",
	"cloth_quality_profile", "destruction_quality_profile", "grass_quality_profile",
	"mixwell_quality_profile", "fractal_quality_profile", "non_euclidean_quality_profile",
	"ssr_quality_profile", "ambient_fluid_quality_profile", "parallax_quality_profile",
]

## Profile script → the exact key set values(tier) must return for every tier.
## Built at runtime: class references are not constant expressions.
var _profiles := {}


func _profile_table() -> void:
	_profiles = {
		OceanQualityProfile: ["fft_size", "foam_near_size", "foam_near_distance",
			"detail_distance_m", "amortize", "foam_near_stride", "short_cascade_half_rate"],
		TerrainQualityProfile: ["grid_n", "mesh_n", "iterations", "render_scale"],
		NBodyQualityProfile: ["particle_count", "self_gravity", "self_gravity_max",
			"render_scale"],
		FluidQualityProfile: ["particle_count", "texture_width", "water_scale",
			"render_scale"],
		PlanetQualityProfile: ["resolution", "detail_octaves", "render_scale"],
		TornadoQualityProfile: ["render_scale", "raymarch_steps", "dust_amount",
			"debris_cap"],
		ClothQualityProfile: ["iterations", "substeps", "render_scale"],
		DestructionQualityProfile: ["chunk_count", "render_scale"],
		GrassQualityProfile: ["density", "shadows", "shadow_distance_m", "render_scale"],
		MixwellQualityProfile: ["target_spp", "preview_scale", "final_scale",
			"gpu_budget_ms"],
		FractalQualityProfile: ["aa_quality", "interaction_cap", "refine_band_rows"],
		NonEuclideanQualityProfile: ["portal_views", "portal_view_scale", "render_scale"],
		SsrQualityProfile: ["render_scale", "msaa", "ssr_steps", "max_objects",
			"ssao", "ssil", "glow"],
		AmbientFluidQualityProfile: ["max_objects", "render_scale", "msaa"],
		ParallaxQualityProfile: ["min_factor", "max_factor", "self_shadow",
			"render_scale"],
	}


func _initialize() -> void:
	_profile_table()
	_test_base_class()
	_test_profile_tables()
	_test_game_manager_seeds()
	_test_state_machine()
	_test_widget_pushes()
	_finish("quality_profiles")


func _test_base_class() -> void:
	_check(SimQualityProfile.TIER_NAMES == ["Low", "Medium", "High", "Ultra"],
		"tier names must be the four shared labels")
	_check(SimQualityProfile.tier_count() == 4, "four tiers")
	_check(SimQualityProfile.default_tier() == SimQualityProfile.Tier.MEDIUM,
		"shared default tier is Medium")
	for tier in 4:
		_check(SimQualityProfile.values(tier).is_empty(),
			"base values() stays empty so demos fill every key")
		_check(SimQualityProfile.tier_supported(tier), "base supports every tier")
	_check(SimQualityProfile.label(2, 2) == "High",
		"undegraded label is the tier name")
	_check(SimQualityProfile.label(3, 1) == "Ultra requested / Medium active",
		"degraded label shows requested and active")


func _test_profile_tables() -> void:
	for profile_script: GDScript in _profiles:
		var keys: Array = _profiles[profile_script]
		for tier in 4:
			var values: Dictionary = profile_script.values(tier)
			_check(values.size() == keys.size(),
				"%s tier %d: %d values, expected %d" % [
					profile_script.get_class(), tier, values.size(), keys.size()])
			for key in keys:
				_check(values.has(key), "%s tier %d misses key '%s'" % [
					profile_script.get_class(), tier, key])
		# Render scale is a shared lever: within [0.4, 1] and never decreases
		# with the tier (more quality = no smaller framebuffer).
		if profile_script.values(0).has("render_scale"):
			var previous := -1.0
			for tier in 4:
				var scale: float = profile_script.values(tier).render_scale
				_check(scale >= 0.4 and scale <= 1.0,
					"%s tier %d render scale %s out of [0.4, 1]" % [
						profile_script.get_class(), tier, scale])
				_check(scale >= previous,
					"%s render scale shrinks at tier %d" % [
						profile_script.get_class(), tier])
				previous = scale
	_test_ocean_tables()
	_test_lever_caps()


func _test_ocean_tables() -> void:
	for tier in 4:
		var values: Dictionary = OceanQualityProfile.values(tier)
		_check(values.fft_size in [256, 512, 1024],
			"ocean FFT %s exceeds the workgroup-size ceiling" % values.fft_size)
		_check(values.foam_near_size in [512, 1024, 2048],
			"ocean foam near size %s outside the calibrated set" % values.foam_near_size)
	_check(OceanQualityProfile.default_tier() == OceanQualityProfile.Tier.HIGH,
		"ocean ships with High (its original configuration)")
	# Ultra keeps High's calibrated foam pipeline (density, not size, is the
	# contract) and distinguishes itself by full-rate short cascade + distance.
	var high: Dictionary = OceanQualityProfile.values(2)
	var ultra: Dictionary = OceanQualityProfile.values(3)
	_check(ultra.foam_near_size == high.foam_near_size
		and ultra.foam_near_distance == high.foam_near_distance,
		"Ultra foam near must stay on High's calibrated config")
	_check(not ultra.short_cascade_half_rate and high.short_cascade_half_rate,
		"Ultra runs the short cascade at full rate")
	_check(ultra.detail_distance_m > high.detail_distance_m,
		"Ultra pushes the detail distance further")
	_check(OceanQualityProfile.tier_supported(3),
		"desktop-class GPU supports Ultra")


func _test_lever_caps() -> void:
	var fluid := FluidQualityProfile
	for tier in 4:
		var values: Dictionary = fluid.values(tier)
		_check(values.particle_count <= values.texture_width * values.texture_width,
			"fluid tier %d: count exceeds impostor texture capacity" % tier)
		_check(values.texture_width in [256, 512],
			"fluid tier %d texture width outside supported set" % tier)
	var nbody := NBodyQualityProfile
	for tier in 4:
		var values: Dictionary = nbody.values(tier)
		if values.self_gravity:
			_check(values.particle_count <= values.self_gravity_max,
				"nbody tier %d: gravity count above the O(N²) ceiling" % tier)
		else:
			_check(values.self_gravity_max == 16384,
				"nbody attractor-mode gravity ceiling stays at 16384")
	var mixwell := MixwellQualityProfile
	for tier in 4:
		var values: Dictionary = mixwell.values(tier)
		_check(values.target_spp in MixwellConfig.SPP_TARGETS,
			"mixwell tier %d spp outside SPP_TARGETS" % tier)
		_check(values.preview_scale > 0.0 and values.preview_scale <= 1.0,
			"mixwell tier %d preview scale out of range" % tier)
	var fractal := FractalQualityProfile
	for tier in 4:
		var values: Dictionary = fractal.values(tier)
		_check(values.interaction_cap <= 10000,
			"fractal tier %d cap above FractalConfig range" % tier)
		_check(values.refine_band_rows <= 4096,
			"fractal tier %d band above FractalConfig range" % tier)
		_check(values.aa_quality in [1, 2, 3], "fractal AA level out of shader range")
	var non_euclidean: Dictionary = NonEuclideanQualityProfile.values(3)
	_check(non_euclidean.portal_views <= 4,
		"portal views above the pool constant (PortalRenderManager)")
	var tornado := TornadoQualityProfile
	for tier in 4:
		var values: Dictionary = tornado.values(tier)
		_check(values.raymarch_steps in [24, 48, 96, 160],
			"tornado tier %d steps outside the menu range" % tier)
	var terrain := TerrainQualityProfile
	for tier in 4:
		var values: Dictionary = terrain.values(tier)
		_check(values.mesh_n <= values.grid_n,
			"terrain tier %d: visual mesh finer than the solver grid" % tier)
	var planet := PlanetQualityProfile
	for tier in 4:
		_check(planet.values(tier).resolution <= 256,
			"planet tier %d: resolution in the readback-stall zone" % tier)


func _test_game_manager_seeds() -> void:
	var manager := _manager()
	if manager == null:
		# Script-mode runs may not register autoloads; the keys themselves are
		# still asserted wherever the manager exists (full gate, editor runs).
		print("NOTE quality_profiles: no GameManager autoload, seeds unchecked")
		return
	for key in QUALITY_KEYS:
		_check(manager.settings.has(key),
			"GameManager.settings misses '%s' (UserSettings only restores seeded keys)" % key)
		var value = manager.settings.get(key, -1)
		_check(typeof(value) == TYPE_INT and value >= 0 and value <= 3,
			"'%s' seed %s is not a tier index" % [key, value])
	_check(manager.settings.get("ocean_quality_profile") == 2,
		"ocean ships on High")
	for key in QUALITY_KEYS:
		if key != "ocean_quality_profile":
			_check(manager.settings.get(key) == 1,
				"'%s' ships on Medium" % key)


## A profile whose Ultra is unsupported, to drive the degradation paths. One
## distinct key per widget kind plus one callback-only key.
class TestProfile extends SimQualityProfile:
	static func values(tier: int) -> Dictionary:
		return {
			strength = float(tier + 1),
			count = (tier + 1) * 16,
			enabled = tier % 2 == 1,
			render_scale = 1.0,
		}

	static func tier_supported(tier: int) -> bool:
		return tier <= SimQualityProfile.Tier.HIGH


class RecordingSink:
	var slider: HSlider
	var option: OptionButton
	var toggle: CheckButton
	var last_slider_value := -1.0
	var last_option_value := -1
	var last_toggle_state := false

	func _init() -> void:
		slider = HSlider.new()
		slider.min_value = 1.0
		slider.max_value = 8.0
		option = OptionButton.new()
		for label in ["16k", "32k", "48k", "64k"]:
			option.add_item(label)
		toggle = CheckButton.new()


var _apply_seen := {}


func _test_state_machine() -> void:
	var state := _make_counting_state("test_quality_profile")
	state.restore()
	_check(state.requested == SimQualityProfile.Tier.MEDIUM
		and state.effective == SimQualityProfile.Tier.MEDIUM,
		"unseeded restore lands on the default tier")
	_check(_apply_seen.strength == 2.0,
		"restore applies the tier values through the apply callable")

	state.set_tier(SimQualityProfile.Tier.MEDIUM)
	_check(_apply_count == 1, "set_tier to the requested tier is a no-op")

	state.set_tier(SimQualityProfile.Tier.ULTRA)
	_check(state.requested == SimQualityProfile.Tier.ULTRA,
		"requested keeps the user's pick")
	_check(state.effective == SimQualityProfile.Tier.HIGH,
		"unsupported Ultra degrades to High")
	_check(state.label() == "Ultra requested / High active",
		"degraded state labels itself")
	_check(_apply_seen.strength == 3.0, "degraded tier applies High's values")
	var manager := _manager()
	if manager != null:
		_check(manager.settings.get("test_quality_profile") == 3,
			"set_tier persists the requested tier")

	var count := _apply_count
	state.fallback_tier = SimQualityProfile.Tier.LOW
	state.reapply()
	_check(state.effective == SimQualityProfile.Tier.LOW,
		"fallback_tier caps the effective tier")
	_check(_apply_count == count + 1,
		"reapply() re-runs the tier without changing it")


## The apply callable also counts invocations, so no-op and bypass paths are
## observable. [param key] keeps states from inheriting each other's persisted
## tiers through GameManager.
func _make_counting_state(key: String) -> SimQualityState:
	var state := SimQualityState.new()
	state.setup(TestProfile, key,
		func(values: Dictionary) -> void:
			_apply_seen = values
			_apply_count += 1)
	return state


var _apply_count := 0


func _test_widget_pushes() -> void:
	_apply_count = 0
	var state := _make_counting_state("test_quality_profile_widgets")
	state.restore()  # MEDIUM: strength 2, count 32, enabled true
	var sink := RecordingSink.new()
	# Wire the widgets the way SimMenu does: value_changed / item_selected /
	# toggled handlers observe the pushes. (The emitted-signal leg is exercised
	# by the UI smoke on a real display; here the slider check is the value the
	# widget lands on.)
	sink.slider.value_changed.connect(
		func(value: float) -> void: sink.last_slider_value = value)
	sink.option.item_selected.connect(
		func(index: int) -> void: sink.last_option_value = index)
	sink.toggle.toggled.connect(
		func(pressed: bool) -> void: sink.last_toggle_state = pressed)

	state.bind("strength", sink.slider,
		func(value: float) -> void: sink.last_slider_value = value)
	state.bind("count", sink.option,
		func(count: int) -> void: sink.last_option_value = count,
		func(count: float) -> int: return int(count / 16.0) - 1)
	state.bind("enabled", sink.toggle,
		func(pressed: bool) -> void: sink.last_toggle_state = pressed)

	# A real move first: the fresh slider already sits on LOW's strength.
	state.set_tier(SimQualityProfile.Tier.ULTRA)  # degrades to HIGH
	_check(sink.slider.value == 3.0,
		"tier switch moves the bound slider to the tier value")
	_check(sink.option.selected == 2 and sink.last_option_value == 48,
		"to_index selects the item and the callback receives the raw tier value")
	_check(sink.toggle.button_pressed == false and sink.last_toggle_state == false,
		"tier switch flips the bound toggle without a signal loop")

	state.set_tier(SimQualityProfile.Tier.MEDIUM)
	_check(sink.slider.value == 2.0, "tier down moves the slider back")
	_check(sink.toggle.button_pressed == true and sink.last_toggle_state == true,
		"odd tier enables the bound toggle")

	# Callback-only binding of the last unbound key: every key is now widget-
	# routed, so the apply callable must be bypassed entirely.
	state.bind("render_scale", null,
		func(value) -> void: pass)
	var count := _apply_count
	state.set_tier(SimQualityProfile.Tier.ULTRA)
	_check(_apply_count == count,
		"fully-bound key sets bypass the apply callable")
	sink.slider.free()
	sink.option.free()
	sink.toggle.free()


func _manager() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null(^"GameManager")
	return null
