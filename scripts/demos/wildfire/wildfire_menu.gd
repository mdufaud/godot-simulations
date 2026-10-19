class_name FireGameMenu extends RefCounted
## Builds the wildfire demo's SimMenu: wind, the propagation grid's spread
## budget, billboard flame density, and the hero campfire's A/B renderer.


## [param host] is the fire game controller: untyped, because the callbacks
## reach for its own properties and a static Node type would reject them.
func build(host) -> void:
	var menu: SimMenu = host.menu

	menu.add_section("Wind")
	menu.add_action_toggle("🌬", "Wind", host.wind_enabled, host.set_wind_enabled)
	menu.add_slider("Angle (°)", 0.0, 360.0, host.wind_angle, host.set_wind_angle)
	menu.add_slider("Strength (m/s)", 0.0, 8.0, host.wind_strength,
		host.set_wind_strength)

	menu.add_separator()
	menu.add_section("Wildfire")
	menu.add_slider("Spread budget", 0.0, 3000.0, float(host.grid.points_left),
		host.set_spread_budget)
	menu.add_slider("Flame density", 0.2, 2.0, host.system.rate_scale,
		host.set_flame_density)

	menu.add_separator()
	menu.add_section("Hero campfire")
	menu.add_option_button("Renderer",
		["Billboard (flipbook)", "Fire-X (volumetric)"], 0, host.set_hero_mode)

	menu.add_separator()
	menu.add_action("💧", "Rain / reset", host.reset_simulation)
	menu.add_action_toggle("🔥", "Flamethrower", false, host.set_flamethrower)
	menu.add_debug_toggle("🐛", "Debug info", false, host.set_debug_info)
