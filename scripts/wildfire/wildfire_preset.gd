class_name WildfirePreset extends Resource
## Look of one fire emitter family (torch, campfire, bonfire).
## Values are per fire at full intensity; the billboard system scales them by
## the live intensity envelope.

@export_group("Flame")
@export_range(0.05, 10.0, 0.05) var flame_height_m := 1.6
@export_range(0, 64, 1) var flame_count := 12
@export_range(0.1, 5.0, 0.05) var flame_lifetime_s := 0.8
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
## The light casts shadows once the system's shadow level reaches this rank
## (1 = first to get shadows); 0 never casts.
@export_range(0, 3, 1) var shadow_rank := 0
@export_range(0.5, 8.0, 0.1) var haze_radius_m := 2.0


func validate() -> String:
	if flame_count < 0 or smoke_rate_hz < 0.0:
		return "particle counts and rates must be >= 0"
	if flame_lifetime_s <= 0.0 or smoke_lifetime_s <= 0.0:
		return "lifetimes must be positive"
	if emitter_radius_m <= 0.0 or flame_height_m <= 0.0:
		return "flame geometry must be positive"
	return ""
