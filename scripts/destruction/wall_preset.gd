class_name WallPreset extends Resource
## One buildable wall: its geometry, where it stands, and how the material it is
## made of behaves when hit.
##
## Presets live in [code]resources/destruction/presets/[/code].

enum Surface { CONCRETE, BRICK, GLASS, STONE }

@export var display_name := "Concrete"
@export var surface: Surface = Surface.CONCRETE

@export_group("Geometry")
@export var size_m := Vector3(5.6, 4.0, 0.7)
## Position of the wall's base centre; the wall is built upward from there.
@export var position_m := Vector3(-4.6, 0.0, 1.4)
@export_range(-180.0, 180.0, 0.1) var yaw_deg := 14.0

@export_group("Material")
@export_range(100.0, 8000.0, 1.0) var density_kg_m3 := 2300.0
## Minimum blast impulse, after distance falloff, that tears a frozen cell out of
## the wall. This is the whole difference between glass and stone.
@export_range(0.0, 40.0, 0.1) var toughness := 9.0
## Spends the chunk budget where it reads best: glass splinters fine, stone
## breaks into a few heavy blocks.
@export_range(0.2, 3.0, 0.01) var count_scale := 1.0


func validate() -> String:
	if size_m.x <= 0.0 or size_m.y <= 0.0 or size_m.z <= 0.0:
		return "size_m must be positive on every axis"
	if density_kg_m3 <= 0.0:
		return "density_kg_m3 must be positive"
	if count_scale <= 0.0:
		return "count_scale must be positive"
	return ""


## Transform of the wall's frame: yaw around its own base, at [member position_m].
func frame() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), position_m)
