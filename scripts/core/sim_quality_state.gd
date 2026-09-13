class_name SimQualityState
extends RefCounted
## Runtime side of the shared quality tiers: the requested/effective pair, the
## GameManager persistence, and the widget bindings that make a tier move the
## visible controls — a tier and a hand-moved slider go down the same path, so
## the panel always shows what is running.
##
## [codeblock]
## var quality := SimQualityState.new()
## quality.setup(TerrainQualityProfile, "terrain_quality_profile", _apply_quality, _rebuild)
## quality.restore()                    # in _ready(), before the menu is built
## quality.bind("grid", _grid_option, _set_grid_index)
## quality.attach_menu_option(menu)     # inside the Performance section
## [/codeblock]
##
## Keys bound to a widget are pushed through it (the widget callback applies the
## value, exactly like a user drag); unbound keys land in the apply callable.

## The SimQualityProfile subclass (class reference, not an instance): its
## statics carry the tier tables. Held as a reference because base-class
## statics would resolve the base constants, not the subclass ones.
var profile: GDScript

## GameManager.settings key persisting the requested tier across launches.
var settings_key := ""

## Tier the user asked for, and the tier actually running after degradation.
var requested := 0
var effective := 0

## Optional hardware cap (< 0 disables): the effective tier never climbs above
## it, e.g. a mobile fallback. Unlike tier_supported() degradation it does not
## warn — the machine class is known, not a GPU limitation to report.
var fallback_tier := -1

var _apply := Callable()
var _rebuild := Callable()
var _controls := {}
var _tier_names: Array = []
var _option: OptionButton = null


## [param profile_script] is the SimQualityProfile subclass; [param apply]
## receives the tier values minus the widget-bound keys; [param rebuild] tears
## down and recreates GPU resources after an explicit tier change (optional).
func setup(profile_script: GDScript, key: String, apply: Callable,
		rebuild: Callable = Callable()) -> void:
	profile = profile_script
	settings_key = key
	_apply = apply
	_rebuild = rebuild
	requested = profile.default_tier()
	effective = profile.default_tier()
	_tier_names = profile.TIER_NAMES


## Read the persisted tier and apply it. Call before building the menu, so the
## widget defaults and SimMenu's later restore land on a coherent simulation.
func restore() -> void:
	var manager := _manager()
	if manager != null:
		requested = clampi(int(manager.get_setting(settings_key, profile.default_tier())),
			0, profile.tier_count() - 1)
	_apply_tier(false)


## Select a tier from the menu: apply, persist, rebuild GPU resources. No-op
## when the tier is already the requested one, so SimMenu's deferred restore
## never rebuilds resources that were set up in _ready().
func set_tier(tier: int) -> void:
	if tier == requested:
		return
	requested = clampi(tier, 0, profile.tier_count() - 1)
	_apply_tier(true)


## Label for menus, profiler overlays and capture metadata; a degraded pick
## reads e.g. "Ultra requested / High active".
func label() -> String:
	return profile.label(requested, effective)


## Re-runs the current effective tier through the bindings without persisting
## or rebuilding: call after something else overwrote tier-owned fields, e.g. a
## content preset that carries its own values for them.
func reapply() -> void:
	_apply_tier(false)


## Bind a tier key to the widget carrying it, so tiers move the visible control
## instead of bypassing it (same pattern as FireQuality.register). [param node]
## may be null for a callback-only binding. For OptionButton bindings,
## [param to_index] translates the raw tier value into the item index (a
## particle count into its position in the count list, say); the callback
## always receives the raw tier value, the same number the tier table carries.
func bind(key: String, node: Control, callback: Callable,
		to_index: Callable = Callable()) -> void:
	_controls[key] = {node = node, callback = callback, to_index = to_index}


## Add the "Quality profile" option to the open section. The label matches the
## ocean menu's, so persisted widget keys stay stable across the migration.
## Returns the OptionButton for demos that want to refresh it themselves.
func attach_menu_option(menu: SimMenu) -> OptionButton:
	_option = menu.add_option_button("Quality profile", _tier_names, requested,
		func(tier_idx: int):
			set_tier(tier_idx)
			refresh_option(_option))
	refresh_option(_option)
	return _option


## Keeps the selector honest: a degraded pick (e.g. Ultra on a GPU below the
## texture limit) reads "requested / active" instead of silently lying.
func refresh_option(option: OptionButton) -> void:
	if option == null:
		return
	for i in option.item_count:
		if i == requested and requested != effective:
			option.set_item_text(i, label())
		else:
			option.set_item_text(i, _tier_names[i])


func _apply_tier(persist: bool) -> void:
	effective = _resolve_effective()
	if profile.is_degraded(requested, effective):
		push_warning("%s quality: %s requested / %s active" % [
			settings_key.trim_suffix("_quality_profile"),
			profile.tier_name(requested), profile.tier_name(effective)])
	var unbound := {}
	var bound: Array[String] = []
	var tier_values: Dictionary = profile.values(effective)
	for key in tier_values:
		if _controls.has(key):
			bound.append(key)
		else:
			unbound[key] = tier_values[key]
	# Unbound keys land before the widget pushes: a push may rebuild from them
	# (the fluid particle count re-allocates its impostor texture at the tier's
	# width, so texture_width must already be in place).
	if not unbound.is_empty() and _apply.is_valid():
		_apply.call(unbound)
	for key in bound:
		_push(key, tier_values[key])
	if persist:
		var manager := _manager()
		if manager != null:
			manager.set_setting(settings_key, requested)
		if _rebuild.is_valid():
			_rebuild.call()


## Highest tier at or below [member requested] the machine supports. Called
## through the subclass reference on purpose: statics resolve lexically inside
## a function body, so only this dynamic dispatch sees a subclass override of
## tier_supported. A degraded pick is never silent — _apply_tier warns.
func _resolve_effective() -> int:
	var tier := requested
	if fallback_tier >= 0:
		tier = mini(tier, fallback_tier)
	while tier > 0 and not profile.tier_supported(tier):
		tier -= 1
	return tier


## Push one value into its bound widget, re-emitting so the callback runs
## (mirrors the widget kinds; falls through to a direct callback otherwise).
func _push(key: String, value: Variant) -> void:
	var entry: Dictionary = _controls[key]
	var node: Control = entry.node
	var callback: Callable = entry.callback
	if node is HSlider:
		var slider := node as HSlider
		if is_equal_approx(slider.value, float(value)):
			callback.call(float(value))
		else:
			slider.value = float(value)  # emits value_changed -> callback + label
	elif node is OptionButton:
		var option := node as OptionButton
		var index := int(value)
		var to_index: Callable = entry.to_index
		if to_index.is_valid():
			index = int(to_index.call(value))
		if index >= 0 and index < option.item_count and index != option.selected:
			option.select(index)
		callback.call(value)
	elif node is CheckButton:
		var toggle := node as CheckButton
		toggle.set_pressed_no_signal(bool(value))
		callback.call(bool(value))
	elif node is Button and (node as Button).toggle_mode:
		var toggle := node as Button  # add_debug_toggle's flat icon switch
		toggle.set_pressed_no_signal(bool(value))
		callback.call(bool(value))
	else:
		callback.call(value)


static func _manager() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null(^"GameManager")
	return null
