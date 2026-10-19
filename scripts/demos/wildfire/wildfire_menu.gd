class_name WildfireMenu extends RefCounted
## Builds the wildfire demo's SimMenu: wind, the quality profile and flame
## density, reset and the flamethrower.

var flamethrower_button: Button


## [param host] is the wildfire controller: untyped, because the callbacks
## reach for its own properties and a static Node type would reject them.
func build(host) -> void:
	var menu: SimMenu = host.menu

	menu.add_section("Wind")
	menu.add_action_toggle("🌬", "Wind", host.wind_enabled, host.set_wind_enabled)
	menu.add_slider("Angle (°)", 0.0, 360.0, host.wind_angle_deg, host.set_wind_angle)
	menu.add_slider("Strength (m/s)", 0.0, 8.0, host.wind_strength,
		host.set_wind_strength)

	menu.add_separator()
	menu.add_section("Performance")
	host.quality.attach_menu_option(menu)
	var density: HSlider = menu.add_slider("Flame density", 0.2, 2.0,
		host.system.rate_scale, host.set_flame_density)
	host.quality.bind("flame_density", density, host.set_flame_density)

	menu.add_separator()
	menu.add_action("↺", "Reset", host.reset_simulation)
	flamethrower_button = menu.add_action_toggle("🔥", "Flamethrower", false,
		host.set_flamethrower)
	menu.add_debug_toggle("🐛", "Debug info", false, host.set_debug_info)
