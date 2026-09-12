class_name DestructionMenu extends RefCounted
## SimMenu panel of the destruction demo.

var launcher: ProjectileLauncher
## The controller. Duck-typed to keep this file out of its type graph; it must
## provide rebuild, fire_at_centre, arm_projectile, set_chunk_count, set_bias,
## set_render_scale and quality (SimQualityState).
var host: Node

var _status: Label


func build(menu: SimMenu, projectiles: Array, projectile_idx: int, chunk_count: int,
		bias: float) -> void:
	menu.add_action("↺", "Rebuild", host.rebuild)
	menu.add_action("💥", "Fire", host.fire_at_centre)
	menu.add_action("🧹", "Clear", launcher.clear)

	menu.add_section("Walls")
	var chunk_slider: HSlider = menu.add_slider("Chunks / wall", 40.0, 250.0,
		float(chunk_count), host.set_chunk_count)
	host.quality.bind("chunk_count", chunk_slider, host.set_chunk_count)
	menu.add_slider("Shard bias", 0.0, 1.0, bias, host.set_bias)
	_status = menu.add_label("")
	menu.add_separator()

	var names: Array = []
	for preset in projectiles:
		var typed: ProjectilePreset = preset
		names.append(typed.display_name)

	menu.add_section("Weapon")
	menu.add_option_button("Projectile", names, projectile_idx, host.arm_projectile)
	menu.add_label("Right-click to shoot at the cursor")
	menu.add_slider("Blast radius ×", 0.3, 2.5, launcher.radius_scale,
		func(v: float): launcher.radius_scale = v)
	menu.add_slider("Blast power ×", 0.2, 3.0, launcher.power_scale,
		func(v: float): launcher.power_scale = v)
	menu.add_separator()

	menu.add_section("Performance")
	var scale_slider: HSlider = menu.add_slider("Render scale", 0.4, 1.0,
		host.render_scale(), host.set_render_scale)
	host.quality.bind("render_scale", scale_slider, host.set_render_scale)
	host.quality.attach_menu_option(menu)


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text
