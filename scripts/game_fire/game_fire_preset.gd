class_name GameFirePreset extends Resource
## Look of one fire emitter family (torch, campfire, bonfire, burning grass).
## Values are per fire at full intensity; the billboard system scales them by
## the live intensity envelope.

@export_group("Flame")
@export_range(0.05, 6.0, 0.05) var flame_width_m := 0.9
@export_range(0.05, 10.0, 0.05) var flame_height_m := 1.6
@export_range(0.0, 200.0, 0.5) var flame_rate_hz := 40.0
@export_range(0.1, 5.0, 0.05) var flame_lifetime_s := 0.8
@export var flame_tint_hot := Color(1.0, 0.92, 0.75)
@export var flame_tint_cool := Color(1.0, 0.45, 0.16)
@export_range(0.05, 4.0, 0.05) var emitter_radius_m := 0.7

@export_group("Smoke")
@export_range(0.0, 100.0, 0.5) var smoke_rate_hz := 7.0
@export_range(0.5, 10.0, 0.1) var smoke_lifetime_s := 3.5
@export_range(0.2, 8.0, 0.1) var smoke_size_m := 1.8
@export var smoke_tint := Color(0.14, 0.13, 0.13)

@export_group("Embers")
@export_range(0, 128, 1) var ember_count := 20
@export_range(0.5, 6.0, 0.1) var ember_speed_m := 2.4

@export_group("Light & haze")
@export_range(0.0, 12.0, 0.1) var light_energy := 2.2
@export_range(1.0, 40.0, 0.5) var light_range_m := 9.0
@export var light_color := Color(1.0, 0.55, 0.18)
@export_range(0.5, 8.0, 0.1) var haze_radius_m := 2.0


func validate() -> String:
	if flame_rate_hz < 0.0 or smoke_rate_hz < 0.0:
		return "particle rates must be >= 0"
	if flame_lifetime_s <= 0.0 or smoke_lifetime_s <= 0.0:
		return "lifetimes must be positive"
	if emitter_radius_m <= 0.0 or flame_height_m <= 0.0:
		return "flame geometry must be positive"
	return ""


## Hot-to-cool ramp across the flame's lifetime, hottest (whitest) at birth.
func flame_tint(age_norm: float) -> Color:
	return flame_tint_hot.lerp(flame_tint_cool, pow(clampf(age_norm, 0.0, 1.0), 0.7))
