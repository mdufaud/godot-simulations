class_name SimMenu
extends Control
## Shared control panel for every simulation demo. A gear button (top-right) opens
## a translucent, touch-friendly options panel with collapsible category sections,
## a live FPS readout, a factory-reset button and a Back button. Debug toggles live
## in an always-visible icon strip under the gear (add_debug_toggle), and demo
## actions (fire, pour, throw, reset) in a bottom-right strip (add_action /
## add_action_toggle) so they stay usable while the options panel is open. Every
## value widget persists to UserSettings and restores on load; actions never do.

signal panel_toggled(open: bool)

@export var title: String = "":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value

@onready var _back_button: Button = $TopRight/BackButton
@onready var _gear_button: Button = $TopRight/GearButton
@onready var _debug_strip: VBoxContainer = $TopRight/DebugStrip
@onready var _action_lane: ScrollContainer = $BottomRight
@onready var _action_bar: VBoxContainer = $BottomRight/ActionBar
@onready var _panel: PanelContainer = $Panel
@onready var _title_label: Label = $Panel/VBox/Header/TitleLabel
@onready var _close_button: Button = $Panel/VBox/Header/CloseButton
@onready var _fps_label: Label = $Panel/VBox/FPSLabel
@onready var _content: VBoxContainer = $Panel/VBox/Scroll/Margin/Content
@onready var _reset_button: Button = $Panel/VBox/Footer/ResetButton

## Widgets are appended to _current (open group), else _section_body (open section),
## else _content.
var _current: Control = null
var _section_body: Control = null

## Section under which widget values are stored. Defaults to the running demo key.
@export var persist_id: String = ""

## persist key -> {node, cb, kind, default}. Keys are "<section>/<label>".
var _entries: Dictionary = {}
var _section: String = "General"
var _restored := false
var _reset_dialog: ConfirmationDialog = null

# Cached styleboxes so SimMenu's flat look doesn't inherit the chunky main-menu theme.
var _sb_section: StyleBoxFlat
var _sb_section_hover: StyleBoxFlat
var _sb_section_open: StyleBoxFlat
var _sb_track: StyleBoxFlat
var _sb_fill: StyleBoxFlat
var _sb_empty: StyleBoxEmpty


func _flat(color: Color, radius: int, mh: int, mv: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = mh
	sb.content_margin_right = mh
	sb.content_margin_top = mv
	sb.content_margin_bottom = mv
	return sb


func _build_styles() -> void:
	_sb_section = _flat(Color(0.14, 0.17, 0.22, 0.85), 6, 10, 7)
	_sb_section_hover = _flat(Color(0.19, 0.23, 0.30, 0.95), 6, 10, 7)
	_sb_section_open = _flat(Color(0.18, 0.24, 0.33, 1.0), 6, 10, 7)
	_sb_section_open.border_width_left = 3
	_sb_section_open.border_color = Color(0.32, 0.6, 0.95, 1.0)
	# 2px top/bottom content margin gives the otherwise-flat track a slim visible band.
	_sb_track = _flat(Color(0.24, 0.27, 0.33, 1.0), 2, 0, 2)
	_sb_fill = _flat(Color(0.30, 0.56, 0.92, 1.0), 2, 0, 2)
	_sb_empty = StyleBoxEmpty.new()


## Center the card in the free area left of the icon lane, capped so it never becomes a
## full-bleed strip on wide/landscape screens.
func _layout_panel() -> void:
	var vp := get_viewport_rect().size
	var lane := 76.0        # reserved right column: back / gear / debug icons
	var margin := 20.0
	var avail := vp.x - lane
	var w: float = minf(560.0, avail - margin * 2.0)
	var left: float = margin + maxf(0.0, (avail - margin * 2.0 - w) * 0.5)
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.offset_left = left
	_panel.offset_right = left + w
	_panel.anchor_top = 0.0
	_panel.offset_top = 20.0
	_panel.anchor_bottom = 1.0
	_panel.offset_bottom = -20.0


## The action lane shares the right column with the back/gear/debug strip: it spans
## whatever is left under that strip, so a long action list scrolls instead of
## sliding under the gear.
func _layout_action_lane() -> void:
	var top_strip: Control = $TopRight
	var top: float = top_strip.position.y + top_strip.size.y + 12.0
	_action_lane.offset_top = -maxf(120.0, get_viewport_rect().size.y - top)
	# More actions than the lane can show: keep the bottom of the strip in view (it is
	# the anchored edge), the overflow scrolls up.
	_action_lane.scroll_vertical = int(_action_bar.get_combined_minimum_size().y)


func _host() -> Node:
	if _current != null:
		return _current
	if _section_body != null:
		return _section_body
	return _content


func _ready() -> void:
	_build_styles()
	_title_label.text = title
	_gear_button.pressed.connect(_on_gear_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_back_button.pressed.connect(_on_back_pressed)
	# Fat, grabbable scrollbar for touch; drag-to-scroll still works too. Content keeps a
	# 30px right margin (tscn) so the bar sits in its own lane, not over the sliders.
	($Panel/VBox/Scroll as ScrollContainer).get_v_scroll_bar().custom_minimum_size.x = 22
	# Centered, width-capped card (reserves the right icon lane); re-run on rotation/resize.
	_layout_panel()
	_layout_action_lane.call_deferred()
	get_viewport().size_changed.connect(_layout_panel)
	get_viewport().size_changed.connect(_layout_action_lane)
	if persist_id.is_empty():
		persist_id = GameManager.current_demo
	if persist_id.is_empty():
		var current_scene := get_tree().current_scene
		if current_scene != null:
			persist_id = current_scene.scene_file_path.get_file().get_basename()
	_restore_all.call_deferred()


## Widgets are built from the controller's _ready(), which runs after ours, so the
## first restore is deferred. Anything registered later restores immediately.
func _restore_all() -> void:
	_restored = true
	for key in _entries:
		_restore_one(key)


func _restore_one(key: String) -> void:
	if not UserSettings.has_sim_value(persist_id, key):
		return
	var stored: Variant = UserSettings.get_sim_value(persist_id, key, null)
	var entry: Dictionary = _entries[key]
	_apply_value(entry, stored)


## Push a value into a widget, re-emitting so the callback runs (mirrors the kinds).
func _apply_value(entry: Dictionary, value: Variant) -> void:
	var node: Control = entry.node
	match entry.kind:
		"slider":
			node.value = float(value)  # emits value_changed -> callback + label
		"toggle":
			node.button_pressed = bool(value)  # emits toggled -> callback
		"option":
			var index := int(value)
			if index >= 0 and index < node.item_count and index != node.selected:
				node.select(index)
				entry.cb.call(index)
		"color":
			var color: Color = value
			if color != node.color:
				node.color = color
				entry.cb.call(color)


func _register(label_text: String, node: Control, cb: Callable, kind: String, default_val: Variant) -> String:
	var base := "%s/%s" % [_section, label_text]
	var key := base
	var suffix := 2
	while _entries.has(key):
		key = "%s#%d" % [base, suffix]
		suffix += 1
	_entries[key] = {node = node, cb = cb, kind = kind, default = default_val}
	if _restored:
		_restore_one(key)
	return key


func _process(_delta: float) -> void:
	_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _on_gear_pressed() -> void:
	toggle_panel()


func _on_close_pressed() -> void:
	if _panel.visible:
		toggle_panel()


## Show/hide the options panel (also driven by the gear button). Emits panel_toggled.
func toggle_panel() -> void:
	_panel.visible = not _panel.visible
	panel_toggled.emit(_panel.visible)


func is_panel_open() -> bool:
	return _panel.visible


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# --- Factory reset -------------------------------------------------------------

func _on_reset_pressed() -> void:
	if _reset_dialog == null:
		_reset_dialog = ConfirmationDialog.new()
		_reset_dialog.title = "Reset settings"
		_reset_dialog.dialog_text = "Reset all settings to factory defaults?"
		_reset_dialog.confirmed.connect(_do_reset)
		add_child(_reset_dialog)
	_reset_dialog.popup_centered()


func _do_reset() -> void:
	for key in _entries:
		var entry: Dictionary = _entries[key]
		_apply_value(entry, entry.default)
	# Wipe persisted values last, after the per-widget writes triggered above.
	UserSettings.clear_sim(persist_id)


# --- Sections & layout ---------------------------------------------------------

## Collapsible category. Widgets added after this land in the section body until the
## next add_section(). Open/closed state is remembered per demo (default collapsed).
func add_section(text: String) -> Button:
	_section = text
	_current = null
	var open_key := "__open/" + text
	var open := bool(UserSettings.get_sim_value(persist_id, open_key, false))

	var header := Button.new()
	header.toggle_mode = true
	header.button_pressed = open
	header.text = ("▾ " if open else "▸ ") + text
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.custom_minimum_size.y = 40
	header.add_theme_font_size_override("font_size", 17)
	header.add_theme_stylebox_override("normal", _sb_section)
	header.add_theme_stylebox_override("hover", _sb_section_hover)
	header.add_theme_stylebox_override("pressed", _sb_section_open)
	header.add_theme_stylebox_override("hover_pressed", _sb_section_open)
	header.add_theme_stylebox_override("focus", _sb_empty)
	_content.add_child(header)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.visible = open
	_content.add_child(body)
	_section_body = body

	header.toggled.connect(func(on: bool) -> void:
		body.visible = on
		header.text = ("▾ " if on else "▸ ") + text
		UserSettings.set_sim_value(persist_id, open_key, on)
	)
	return header


func add_separator() -> void:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 10)
	_host().add_child(sep)


func add_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	_host().add_child(label)
	return label


func add_slider(label_text: String, min_val: float, max_val: float, default_val: float, cb: Callable) -> HSlider:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.custom_minimum_size.y = 30
	_host().add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 96
	hbox.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = (max_val - min_val) / 100.0
	slider.value = default_val
	slider.scrollable = false
	slider.custom_minimum_size = Vector2(60, 18)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.add_theme_stylebox_override("slider", _sb_track)
	slider.add_theme_stylebox_override("grabber_area", _sb_fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", _sb_fill)
	hbox.add_child(slider)

	var value_label := Label.new()
	value_label.text = "%.2f" % default_val
	value_label.custom_minimum_size.x = 52
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(value_label)

	slider.value_changed.connect(func(value: float) -> void:
		cb.call(value)
		value_label.text = "%.2f" % value
	)
	var key := _register(label_text, slider, cb, "slider", default_val)
	slider.value_changed.connect(func(value: float) -> void:
		UserSettings.set_sim_value(persist_id, key, value)
	)
	return slider


func add_toggle(label_text: String, default_val: bool, cb: Callable) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = label_text
	toggle.button_pressed = default_val
	# Flat row: keep the on/off switch graphic, drop the chunky button box.
	for s in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		toggle.add_theme_stylebox_override(s, _sb_empty)
	toggle.toggled.connect(cb)
	_host().add_child(toggle)
	var key := _register(label_text, toggle, cb, "toggle", default_val)
	toggle.toggled.connect(func(on: bool) -> void:
		UserSettings.set_sim_value(persist_id, key, on)
	)
	return toggle


## Debug/visualisation toggle placed in the always-visible icon strip under the gear,
## outside the options panel (for on-device debugging). `icon` is a short glyph.
func add_debug_toggle(icon: String, tooltip: String, default_val: bool, cb: Callable) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.text = icon
	button.tooltip_text = tooltip
	button.button_pressed = default_val
	button.custom_minimum_size = Vector2(56, 56)
	button.add_theme_font_size_override("font_size", 24)
	button.toggled.connect(cb)
	_debug_strip.add_child(button)

	var prev_section := _section
	_section = "Debug"
	var key := _register(tooltip, button, cb, "toggle", default_val)
	_section = prev_section
	button.toggled.connect(func(on: bool) -> void:
		UserSettings.set_sim_value(persist_id, key, on)
	)
	_layout_action_lane.call_deferred()
	return button


## Icon + caption pill for the action strip. The caption is a child label rather than
## a second text line because Button renders its own text on one line.
func _make_action_button(icon: String, label_text: String) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(56, 52)
	button.tooltip_text = label_text
	button.clip_contents = true

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	button.add_child(box)

	var glyph := Label.new()
	glyph.text = icon
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 22)
	box.add_child(glyph)

	var caption := Label.new()
	caption.text = label_text
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 10)
	box.add_child(caption)

	_action_bar.add_child(button)
	_layout_action_lane.call_deferred()
	return button


## One-shot demo action, shown in the always-visible bottom-right strip so it stays
## usable while the options panel is open. Never persisted.
func add_action(icon: String, label_text: String, cb: Callable) -> Button:
	var button := _make_action_button(icon, label_text)
	button.pressed.connect(cb)
	return button


## Sticky action (ignite, wind, water jet). Like add_action it lives outside the panel
## and is never persisted: it starts at default_val on every launch.
func add_action_toggle(icon: String, label_text: String, default_val: bool, cb: Callable) -> Button:
	var button := _make_action_button(icon, label_text)
	button.toggle_mode = true
	button.button_pressed = default_val
	button.toggled.connect(cb)
	return button


func add_button(label_text: String, cb: Callable) -> Button:
	var button := Button.new()
	button.text = label_text
	button.custom_minimum_size.y = 40
	button.pressed.connect(cb)
	_host().add_child(button)
	return button


func add_color_picker(label_text: String, default_val: Color, cb: Callable) -> ColorPickerButton:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.custom_minimum_size.y = 40
	_host().add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)

	var picker := ColorPickerButton.new()
	picker.color = default_val
	picker.custom_minimum_size = Vector2(60, 32)
	picker.edit_alpha = false
	hbox.add_child(picker)

	picker.color_changed.connect(cb)
	var key := _register(label_text, picker, cb, "color", default_val)
	picker.color_changed.connect(func(color: Color) -> void:
		UserSettings.set_sim_value(persist_id, key, color)
	)
	return picker


func add_progress_bar(label_text: String, max_val: float) -> ProgressBar:
	var label := Label.new()
	label.text = label_text
	_host().add_child(label)

	var bar := ProgressBar.new()
	bar.max_value = max_val
	bar.value = 0.0
	_host().add_child(bar)
	return bar


## Begin a hideable group. Widgets added after this land inside the returned
## VBoxContainer until end_group(). Toggle the container's .visible to show/hide a
## whole param group (used for per-fractal / per-solver parameter scoping).
func add_group() -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 6)
	_host().add_child(group)
	_current = group
	return group


func end_group() -> void:
	_current = null


func add_option_button(label_text: String, items: Array, default_idx: int, cb: Callable) -> OptionButton:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.custom_minimum_size.y = 40
	_host().add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)

	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in items.size():
		option.add_item(str(items[i]), i)
	if default_idx >= 0 and default_idx < items.size():
		option.select(default_idx)
	option.item_selected.connect(cb)
	hbox.add_child(option)
	var key := _register(label_text, option, cb, "option", default_idx)
	option.item_selected.connect(func(index: int) -> void:
		UserSettings.set_sim_value(persist_id, key, index)
	)
	return option
