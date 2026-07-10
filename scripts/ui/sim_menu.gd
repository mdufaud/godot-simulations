class_name SimMenu
extends PanelContainer
## Shared scrollable control panel for every simulation demo.
## Provides a title, live FPS readout, a Back button, and helpers to append
## touch-friendly widgets (sliders/toggles/buttons/labels/bars) to a scrolling
## content area. Sliders are non-scrollable so drag/wheel scrolls the panel.

@export var title: String = "":
	set(value):
		title = value
		if is_node_ready():
			_title_label.text = value

@onready var _title_label: Label = $VBox/Header/TitleLabel
@onready var _fps_label: Label = $VBox/FPSLabel
@onready var _back_button: Button = $VBox/Header/BackButton
@onready var _content: VBoxContainer = $VBox/Scroll/Content

## Widgets are appended to _current when a group is open, else to _content.
var _current: Control = null


func _host() -> Node:
	return _current if _current != null else _content


func _ready() -> void:
	_title_label.text = title
	_back_button.pressed.connect(_on_back_pressed)


func _process(_delta: float) -> void:
	_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func add_section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	_host().add_child(label)
	return label


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
	_host().add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = (max_val - min_val) / 100.0
	slider.value = default_val
	slider.scrollable = false
	slider.custom_minimum_size.x = 80
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(slider)

	var value_label := Label.new()
	value_label.text = "%.2f" % default_val
	value_label.custom_minimum_size.x = 46
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(value_label)

	slider.value_changed.connect(func(value: float) -> void:
		cb.call(value)
		value_label.text = "%.2f" % value
	)
	return slider


func add_toggle(label_text: String, default_val: bool, cb: Callable) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = label_text
	toggle.button_pressed = default_val
	toggle.toggled.connect(cb)
	_host().add_child(toggle)
	return toggle


func add_button(label_text: String, cb: Callable) -> Button:
	var button := Button.new()
	button.text = label_text
	button.pressed.connect(cb)
	_host().add_child(button)
	return button


func add_color_picker(label_text: String, default_val: Color, cb: Callable) -> ColorPickerButton:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	_host().add_child(hbox)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 100
	hbox.add_child(label)

	var picker := ColorPickerButton.new()
	picker.color = default_val
	picker.custom_minimum_size = Vector2(60, 28)
	picker.edit_alpha = false
	hbox.add_child(picker)

	picker.color_changed.connect(cb)
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


## Begin a collapsible/hideable group. Widgets added after this land inside the
## returned VBoxContainer until end_group(). Toggle the container's .visible to
## show/hide a whole param group (used for per-fractal parameter scoping).
func add_group() -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 4)
	_content.add_child(group)
	_current = group
	return group


func end_group() -> void:
	_current = null


func add_option_button(label_text: String, items: Array, default_idx: int, cb: Callable) -> OptionButton:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
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
	return option
