class_name ProjectilePreset extends Resource
## One thing to shoot walls with: how heavy and fast it is, how big a hole it
## makes, and what it looks like.
##
## Presets live in [code]resources/destruction/presets/[/code].

@export var display_name := "Bullet"

@export_group("Ballistics")
@export_range(0.01, 200.0, 0.01) var mass_kg := 0.4
@export_range(0.01, 1.0, 0.001) var radius_m := 0.06
@export_range(1.0, 400.0, 0.1) var speed_mps := 95.0

@export_group("Blast")
@export_range(0.1, 20.0, 0.01) var blast_radius_m := 0.7
## Ejection speed at the crater centre, in m/s: scaled by each cell's mass, so a
## pebble and a boulder leave at the same speed the way a real blast throws them.
@export_range(0.1, 200.0, 0.1) var blast_impulse := 13.0
## Adds a light flash and consumes the projectile on impact.
@export var explodes := false

@export_group("Look")
@export var color := Color(0.75, 0.7, 0.45)
@export_range(0.0, 1.0, 0.01) var metallic := 0.9
@export_range(0.0, 1.0, 0.01) var roughness := 0.25
@export var emission := Color.BLACK


func validate() -> String:
	if mass_kg <= 0.0:
		return "mass_kg must be positive"
	if radius_m <= 0.0:
		return "radius_m must be positive"
	if blast_radius_m <= 0.0:
		return "blast_radius_m must be positive"
	return ""
