class_name ExplosionMenu extends RefCounted

const SCENES := ["Fireball range", "Barrels", "Mushroom cloud"]
const DETONATE_LABELS := ["Detonate aim", "Detonate barrel", "Detonate"]
## Per scene: what a click does.
const HINTS := [
	"Click to throw a fireball at the cursor (drag orbits); right-click also throws",
	"Click to throw a ball at a barrel (drag orbits); right-click also throws",
	"Press Detonate to set off the charge (drag orbits)",
]
## Per scene: whether a click and the Throw action launch a ball (the mushroom has one charge, Detonate).
const THROW_ENABLED := [true, true, false]
const SCENE_BARRELS := 1
const SCENE_MUSHROOM := 2
const CHARGE_SCALE_MIN := 0.5
const CHARGE_SCALE_MAX := 1.5
## Largest charge factor per scene whose tile sweep leaves the pool unexhausted.
const CHARGE_SCALE_LIMITS: Array[float] = [1.2, 1.25, 1.25]
const CHARGE_SCALE_STEP := 0.05

var scene_option: OptionButton
var charge_slider: HSlider
var throw_action: Button
var detonate_action: Button
var scene_action: Button
var slow_action: Button
var settings := ExplosionSettings.new()
var blast_slider: HSlider
var darkness_slider: HSlider
var wind_slider: HSlider
var wind_dir_slider: HSlider
var quality_option: OptionButton
var detail_slider: HSlider
var hint_label: Label

var _menu: SimMenu


static func charge_scale_max(scene: int) -> float:
	return CHARGE_SCALE_LIMITS[clampi(scene, 0, CHARGE_SCALE_LIMITS.size() - 1)]


static func slow_label(scale: float) -> String:
	return "Slow " + String.num(scale) + "×"


## [param controller] must provide set_scene, next_scene, set_charge_scale, throw_ball, detonate_scene, clear_smoke,
## set_paused, cycle_slow and reset_simulation.
func build(menu: SimMenu, controller: Node) -> void:
	_menu = menu
	throw_action = menu.add_action("💥", "Throw", controller.throw_ball)
	detonate_action = menu.add_action("🧨", DETONATE_LABELS[0], controller.detonate_scene)
	menu.add_action("🌫", "Clear smoke", controller.clear_smoke)
	scene_action = menu.add_action("🎬", SCENES[0], controller.next_scene)
	menu.add_action("↺", "Reset", controller.reset_simulation)
	menu.add_action_toggle("⏸", "Pause", false, controller.set_paused)
	slow_action = menu.add_action("🐢", slow_label(1.0), controller.cycle_slow)
	menu.add_section("Explosions")
	scene_option = menu.add_option_button("Scene", SCENES, 0, controller.set_scene, false)
	charge_slider = menu.add_slider("Charge size × (next)", CHARGE_SCALE_MIN, CHARGE_SCALE_MAX, 1.0,
		controller.set_charge_scale, false, CHARGE_SCALE_STEP)
	blast_slider = menu.add_slider("Blast force × (next)", ExplosionSettings.BLAST_FORCE_MIN,
		ExplosionSettings.BLAST_FORCE_MAX, settings.blast_force, _set_blast_force, false, ExplosionSettings.BLAST_FORCE_STEP)
	darkness_slider = menu.add_slider("Smoke darkness", 0.0, 1.0, settings.darkness, settings.set_darkness, false, 0.05)
	wind_slider = menu.add_slider("Wind m/s", 0.0, ExplosionSettings.wind_max(0), settings.wind_mps,
		settings.set_wind_speed, false, ExplosionSettings.WIND_STEP_MPS)
	wind_dir_slider = menu.add_slider("Wind dir °", 0.0, 359.0, settings.wind_deg, settings.set_wind_direction, false, 1.0)
	quality_option = menu.add_option_button("Quality", ExplosionSettings.QUALITY_NAMES, settings.quality,
		_set_quality, false)
	detail_slider = menu.add_slider("Surface detail", 0.0, 1.0, settings.detail, settings.set_detail, false, 0.05)
	hint_label = menu.add_label(HINTS[0])
	menu.add_button("Reset", controller.reset_simulation)


func _set_blast_force(value: float) -> void:
	settings.blast_force = value
	settings.apply_force()


func _set_quality(index: int) -> void:
	settings.quality = index
	settings.apply_quality()


func set_slow_label(scale: float) -> void:
	_menu.set_action_label(slow_action, slow_label(scale))


func show_scene(index: int) -> void:
	scene_option.select(index)
	_menu.set_action_label(detonate_action, DETONATE_LABELS[index])
	_menu.set_action_label(scene_action, SCENES[index])
	throw_action.visible = THROW_ENABLED[index]
	hint_label.text = HINTS[index]
	_menu.set_slider_value(darkness_slider, settings.darkness)
	blast_slider.get_parent().visible = ExplosionSettings.force_acts(index)
	wind_slider.max_value = ExplosionSettings.wind_max(index)
	_menu.set_slider_value(wind_slider, settings.wind_mps)
