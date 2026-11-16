class_name ExplosionMenu extends RefCounted

const SCENES := ["Fireball range", "Barrels", "Mushroom cloud"]
const SCENE_BARRELS := 1
const SCENE_MUSHROOM := 2
const CHARGE_SCALE_MIN := 0.5
const CHARGE_SCALE_MAX := 1.5
const CHARGE_SCALE_STEP := 0.05

var scene_option: OptionButton
var charge_slider: HSlider


## [param controller] must provide set_scene, set_charge_scale, throw_ball, detonate_barrel and reset_simulation.
func build(menu: SimMenu, controller: Node) -> void:
	menu.add_action("💥", "Throw", controller.throw_ball)
	menu.add_section("Explosions")
	scene_option = menu.add_option_button("Scene", SCENES, 0, controller.set_scene, false)
	charge_slider = menu.add_slider("Charge size ×", CHARGE_SCALE_MIN, CHARGE_SCALE_MAX, 1.0,
		controller.set_charge_scale, false, CHARGE_SCALE_STEP)
	menu.add_button("Detonate barrel", controller.detonate_barrel)
	menu.add_label("Right-click to throw a fireball at the cursor")
	menu.add_button("Reset", controller.reset_simulation)
