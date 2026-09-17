class_name NonEuclideanHud extends RefCounted
## Every control of the non-Euclidean demo: the settings panel, the corner
## readout, the crosshair, the portal debug overlay and the touch buttons.

const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")

var _menu: SimMenu
var _case_option: OptionButton
var _status_label: Label
var _debug_label: Label
var _touch_controls: Control
var _jump_button: Button
var _sprint_button: Button


## [param host] is the non-Euclidean controller: untyped, because the callbacks
## reach for its own methods and a static Node type would reject them.
func build(host, exhibit_names: Array) -> void:
	_menu = host.menu
	_menu.title = "Non-Euclidean Laboratory"
	_menu.panel_toggled.connect(host._on_menu_panel_toggled)
	_menu.add_section("Navigation")
	_case_option = _menu.add_option_button("Area", exhibit_names, 0, host._go_to_case)
	_menu.add_action("➡", "Area", host._next_case)
	_menu.add_action("↺", "Reset", host._reset_current_case)
	_menu.add_separator()
	_menu.add_section("Impossible Storage")
	_menu.add_label("Portal views render to dedicated HDR targets; the quality tier scales their count and resolution")
	_menu.add_debug_toggle("🧊", "Debug crossing volume", false,
		func(enabled: bool) -> void:
			host.render_manager.set_debug_enabled(enabled)
			_debug_label.visible = enabled
	)
	_menu.add_separator()
	_menu.add_section("Performance")
	var scale_slider: HSlider = _menu.add_slider("Render scale", 0.4, 1.0,
		host._viewport.render_scale(), host._set_render_scale)
	host.quality.bind("render_scale", scale_slider, host._set_render_scale)
	var views_slider: HSlider = _menu.add_slider("Portal views", 1.0, 4.0,
		float(host.render_manager.max_views),
		func(v: float) -> void: host.render_manager.set_max_views(int(v)))
	host.quality.bind("portal_views", views_slider,
		func(v: float) -> void: host.render_manager.set_max_views(int(v)))
	var view_scale_slider: HSlider = _menu.add_slider("Portal view scale", 0.4, 1.0,
		host.render_manager.portal_view_scale, host.render_manager.set_portal_view_scale)
	host.quality.bind("portal_view_scale", view_scale_slider,
		host.render_manager.set_portal_view_scale)
	host.quality.attach_menu_option(_menu)

	_build_overlay(host.ui_layer)
	_build_touch_controls(host)


func select_case(index: int) -> void:
	_case_option.select(index)


## Selects and re-emits, so the panel dropdown and its persisted value follow a
## teleport triggered from the strip button.
func choose_case(index: int) -> void:
	_case_option.select(index)
	_case_option.item_selected.emit(index)


func set_status(text: String) -> void:
	_status_label.text = text


func is_debug_visible() -> bool:
	return _debug_label.visible


func set_debug_text(text: String) -> void:
	_debug_label.text = text


## Hides the touch buttons while the settings panel covers them.
func set_touch_visible(visible: bool) -> void:
	if _jump_button != null:
		_jump_button.visible = visible
	if _sprint_button != null:
		_sprint_button.visible = visible


func _build_overlay(ui_layer: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(18.0, 18.0)
	panel.custom_minimum_size = Vector2(430.0, 72.0)
	ui_layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_status_label)
	var hint := Label.new()
	hint.text = "Joystick + drag to look · Jump, sprint and menu on screen" \
		if VirtualJoystickScript.is_touch_ui() else "WASD/ZQSD · Space jump · Shift sprint · F1 settings"
	hint.modulate = Color(1.0, 1.0, 1.0, 0.62)
	box.add_child(hint)

	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 24)
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-12.0, -18.0)
	crosshair.size = Vector2(24.0, 36.0)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(crosshair)

	_debug_label = Label.new()
	_debug_label.position = Vector2(18.0, 102.0)
	_debug_label.add_theme_font_size_override("font_size", 15)
	_debug_label.modulate = Color(0.55, 0.9, 1.0)
	_debug_label.visible = false
	ui_layer.add_child(_debug_label)


func _build_touch_controls(host) -> void:
	if not VirtualJoystickScript.is_touch_ui():
		return
	var player: NonEuclideanPlayer = host.player
	_touch_controls = Control.new()
	_touch_controls.name = "TouchActions"
	_touch_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_controls.theme = load("res://resources/themes/main_theme.tres")
	host.ui_layer.add_child(_touch_controls)
	# The connection targets this RefCounted HUD: drop it with the controls
	# instead of relying on engine teardown to clean it up.
	host.get_viewport().size_changed.connect(_layout_touch_controls)
	_touch_controls.tree_exiting.connect(func() -> void:
		if host.get_viewport().size_changed.is_connected(_layout_touch_controls):
			host.get_viewport().size_changed.disconnect(_layout_touch_controls))

	_jump_button = Button.new()
	_jump_button.text = "Jump"
	_jump_button.pressed.connect(player.request_touch_jump)
	_touch_controls.add_child(_jump_button)

	_sprint_button = Button.new()
	_sprint_button.text = "Sprint"
	_sprint_button.button_down.connect(func() -> void: player.set_touch_sprinting(true))
	_sprint_button.button_up.connect(func() -> void: player.set_touch_sprinting(false))
	_touch_controls.add_child(_sprint_button)
	_layout_touch_controls()


func _layout_touch_controls() -> void:
	if not is_instance_valid(_touch_controls):
		return
	_touch_controls.size = _touch_controls.get_viewport().get_visible_rect().size
	_jump_button.position = Vector2(_touch_controls.size.x - 152.0,
		_touch_controls.size.y - 104.0)
	_jump_button.size = Vector2(128.0, 72.0)
	_sprint_button.position = Vector2(_touch_controls.size.x - 152.0,
		_touch_controls.size.y - 192.0)
	_sprint_button.size = Vector2(128.0, 72.0)
